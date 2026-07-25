# AppDynamics Agent Automation (Ansible)

Config-file-driven Ansible automation for maintaining AppDynamics agents installed
under `/opt/appdynamics` (Linux) and `C:\opt\appdynamics` (Windows). Agent types
in scope: **Java APM**, **.NET**, **Machine Agent** (+ extensions), and **Database Agent**.

All configuration is declared as variables in `inventory/group_vars/` (and optional
`host_vars/`). Roles render the on-disk config files from those variables, so the
desired state lives in source control, not on the servers.

## Directory layout

```
ansible.cfg
requirements.yml                 # Galaxy collections to install
.gitignore                       # keeps client_config/*.yml and artifacts/ out of git
client_config/
  example.client.yml             # PORTABLE: all client-specific values (template)
  README.md
artifacts/                       # per-run logs + HTML reports (gitignored)
inventory/
  hosts.yml                      # OS groups (connection) + agent-type groups (roles)
  group_vars/
    all.yml                      # controller connection, API client, global switches
    java_agents.yml
    dotnet_agents.yml
    machine_agents.yml           # incl. the 4 extension config blocks
    db_agents.yml                # incl. DatabaseAgentService.vmoptions
    vault.yml.example            # secrets template (encrypt with ansible-vault)
  host_vars/
    app01.example.com.yml.example
playbooks/
  site.yml                       # master; -e appd_action=configure|install|upgrade|uninstall
  configure.yml install.yml upgrade.yml uninstall.yml
  validate.yml                   # health checks
  drift_detection.yml            # --check --diff wrapper
  discover.yml                   # what's actually installed
  backup_config.yml              # snapshot configs
  collect_logs.yml               # FUTURE IDEA (stub)
roles/
  appd_common/                   # OS detection + shared service/backup/template helpers
  appd_accountability/           # run dir, per-host records, HTML report, email
  appd_java_agent/
  appd_dotnet_agent/
  appd_machine_agent/
  appd_db_agent/
```

## Quick start

```bash
ansible-galaxy collection install -r requirements.yml

# 1) client-specific values live OUTSIDE the repo (see Portability below):
cp client_config/example.client.yml client_config/active.yml   # then edit
# 2) fill in inventory/hosts.yml; create+encrypt inventory/group_vars/vault.yml

# preview changes (no edits, shows diffs):
ansible-playbook playbooks/configure.yml --check --diff

# apply config to everything:
ansible-playbook playbooks/configure.yml

# just the machine agents:
ansible-playbook playbooks/configure.yml --limit machine_agents

# use a specific client file instead of active.yml:
ansible-playbook playbooks/configure.yml -e client_config_file=client_config/acme.yml
```

Each run writes a timestamped folder under `artifacts/` containing the log, an
HTML report, and per-host records. See **Accountability** below.

`appd_action` selects the verb: `configure` (default), `install`, `upgrade`,
`uninstall`. `install`/`upgrade`/`uninstall` are starter stubs — wire them to your
artifact source (Nexus/Artifactory/file share) and version strategy.

## OS handling — one server list, mixed Linux/Windows

You feed in a flat list of servers; the automation figures out the OS and acts
accordingly. How it works:

- **Connection method** (ssh vs. psrp/winrm) must be known *before* connecting, so a
  host's OS is declared once by putting it in the `linux` or `windows` group in
  `inventory/hosts.yml`. Those groups carry the connection vars and base paths.
- **Everything after connect is automatic.** The `appd_common` role gathers facts and
  sets `appd_is_windows` plus normalized `appd_path_sep` / `appd_home_resolved`. Every
  task branches on those facts — no per-playbook OS logic. A single `site.yml` run
  handles a mixed inventory in one pass.

**Fully OS-agnostic option:** install OpenSSH Server on the Windows hosts and use a
dynamic inventory (from your CMDB/vCenter) that auto-tags each host's OS into the
`linux`/`windows` group. Then adding a server is just adding its name — the OS tag and
connection are resolved for you.

## What each agent role manages today

| Role | Config file(s) rendered from variables |
|------|----------------------------------------|
| `appd_java_agent` | `conf/controller-info.xml` (+ optional app-agent-config.xml, logging) |
| `appd_dotnet_agent` | `%ProgramData%\AppDynamics\DotNetAgent\Config\config.xml` + profiler env vars |
| `appd_machine_agent` | `conf/controller-info.xml` and the four extension YAMLs below |
| `appd_db_agent` | `bin/DatabaseAgentService.vmoptions` |

Machine-agent extension files (under `extensions/<Ext>/conf/`), each toggled and
driven by its block in `group_vars/machine_agents.yml`:

- `ServerMonitoring/conf/ServerMonitoring.yml`
- `DockerMonitoring/conf/DockerMonitoring.yml`
- `CrashGuard/conf/crashGuardConfig.yml`
- `AgentServer/conf/agentServerConfig.yml`

> The extension YAMLs are rendered from variable maps via a generic template. Align the
> keys to each extension's documented schema before enabling in production.

## Other APM/agent configs worth considering

You asked what else to manage beyond the files above. Common candidates:

**Java agent** — beyond `controller-info.xml`:
- JVM startup args (`-javaagent`, `-Dappdynamics.*`) — managed where the app is launched
  (systemd unit, Tomcat `setenv.sh`, `JAVA_OPTS`), not just in agent files.
- `app-agent-config.xml` (agent-level tuning), `custom-interceptors.xml` /
  `transactions.xml` (custom instrumentation), and the logging config under
  `<ver>/conf/logging/log4j2.xml`. Hooks for the first two are stubbed in `java_agents.yml`.

**.NET agent**:
- `config.xml` (handled). For .NET Core/5+, instrumentation is driven by the
  `CORECLR_*` / `COR_*` profiler environment variables (handled, machine scope).
- App pool / service recycling is required for changes to take effect.

**Machine agent**:
- Its own JVM memory settings, plus any *custom extensions* you drop in beyond the four
  above (each is just another `conf/*.yml` — add a block + an entry in the role's
  `machine_agent_extensions` map).
- `analytics-agent.properties` if the Analytics Agent is co-deployed.

**Database agent**:
- `DatabaseAgentService.vmoptions` (handled). Note: DB **collectors** (the actual
  monitored databases) are configured in the Controller UI / via API, not in host files.

**Cross-cutting**:
- TLS truststore / custom certs for controllers behind private CAs.
- Access-key rotation (a dedicated playbook is a good next addition).

## Accountability (logging, reporting, email)

Every `site.yml` run is bracketed by the `appd_accountability` role:

- **Logging** — `ansible.cfg` writes `artifacts/ansible-latest.log` each run; the
  report step archives a copy into the run folder as `ansible.log`. Run with
  `--diff` to capture line-level config changes in that log.
- **Run record** — a localhost "start" play creates
  `artifacts/<timestamp>/` and writes `run_metadata.json` (who ran it, when,
  action, controller, check-mode, limit). Each host writes a JSON snapshot of its
  managed config files (path / exists / sha1 / mtime / changed).
- **HTML report** — `artifacts/<timestamp>/report.html`: KPI cards (hosts, agents
  touched, changed) and a per-host/per-file table. Open it in a browser or attach
  to a change ticket.
- **Email** — `notify.yml` emails the report via SMTP (`community.general.mail`).
  **Disabled by default** (`email_enabled: false`) since SMTP creds aren't set up
  yet. Configure in your client file and flip the switch. Trigger modes
  (`email_mode`): `always`, `on_change` (≥1 agent changed), or `on_failure` (a
  managed file is missing after the run).

> Email caveat: `on_failure` uses "managed file missing after run" as its proxy.
> For mail triggered by a hard task failure/unreachable host, add a play-level
> error handler — noted as a future enhancement.

To enable email later: set `email_enabled: true` and fill `email_smtp_*`,
`email_from`, `email_to` in `client_config/<client>.yml`; put the SMTP password in
Vault as `vault_email_smtp_password`. Nothing else changes.

## Portability across contracts

Everything proprietary to one client lives in a single external file,
`client_config/<client>.yml`, loaded at run time. It holds the controller
connection, account, secret references, email/SMTP, reporting, and client identity.

- The repo's `group_vars/all.yml` ships only **safe placeholders**; the start play
  asserts the real controller host was loaded and **fails fast** otherwise.
- `client_config/*.yml` is **gitignored** (only `example.client.yml` is tracked).
- To reuse on a new contract: hand over the repo **without** your client file. The
  new team copies the example, fills in their values, and runs — no prior client's
  details travel with the project.

## Secrets

Controller access key, API client credentials, and the SMTP password come from
Ansible Vault — see `inventory/group_vars/vault.yml.example`. The client file
references them by name (e.g. `{{ vault_appd_access_key }}`). Never commit
plaintext keys.

## Controller API client (relationship to this repo)

Per the design discussion: build the API client as a **standalone library/CLI** (usable
outside Ansible), then have Ansible consume it through thin custom modules, a dynamic
inventory plugin (pull tiers/nodes from the controller), or `uri` tasks. `group_vars/all.yml`
already exposes `appd_api_base_url` and API credential vars for that integration. You can
also seed `group_vars` from a **Controller → Agent Management** export to capture the
authoritative current settings.

## Future ideas

- **Agent log collection** (`playbooks/collect_logs.yml`, stubbed): one command to pull
  agent logs from all servers, OS-agnostic. Open questions before building: destination
  (control node / object store), time-window vs. whole dir, compression, and redaction of
  secrets before logs leave the host.
- Access-key rotation playbook.
- API-backed validation (confirm a node is reporting to the controller after a change).
```
