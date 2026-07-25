# Design Spec: Preflight + Verification Layer ("Flight Framework")

**Status:** Proposed — for review before implementation
**Audience:** Framework operators and maintainers
**Goal:** Every lifecycle action checks state *before* acting, verifies *after* acting,
skips unsafe hosts cleanly, and records everything on the Ansible control node —
using one shared pattern so all playbooks look and behave the same.

---

## 1. Design principles

1. **One pattern, everywhere.** Every playbook follows the same five-phase shape.
   If you've read one, you've read them all.
2. **Checks are data, logic is shared.** What to check (service names, log paths,
   log patterns, process markers) lives in **config files**. How to check lives in
   **one small shared role**. Moving to a new contract = edit config, not code.
3. **Skip, don't fail.** A host that isn't safe to touch is *skipped with a recorded
   reason* and the run continues to the next server. Failure is reserved for real errors.
4. **Evidence, not vibes.** Verification produces recorded evidence (service state,
   log line matched, process argument found), stored on the control node in the run folder.
5. **Plain Ansible only.** No custom Python modules in this phase — every check is a
   standard module (`stat`, `command`, `win_service_info`, `slurp`, `uri`). Easy to
   read, easy to review, easy to trust.
6. **API-ready, not API-dependent.** Controller API checks are a defined, disabled-by-
   default plug-in point. Enabling them later changes config, not playbooks.

---

## 2. The five-phase "flight" pattern

Every lifecycle playbook (`configure`, `install`, `upgrade`, `uninstall`) — and, once
adopted, the utility playbooks too — runs the same shape:

```
┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐
│ 1. START   │→ │ 2. PREFLIGHT│→ │ 3. ACTION  │→ │ 4. POSTFLIGHT│→ │ 5. REPORT │
│ run folder │  │ assess host │  │ (guarded:  │  │ verify the  │  │ HTML + log │
│ + metadata │  │ set go/skip │  │ only if GO)│  │ outcome     │  │ + email    │
└────────────┘  └────────────┘  └────────────┘  └────────────┘  └────────────┘
   localhost       per host        per host        per host        localhost
```

Phases 1 and 5 already exist (`appd_accountability`: start / report / notify).
This design adds **2 and 4** and threads their results into 5.

### New role: `appd_flight`

```
roles/appd_flight/
  tasks/
    preflight.yml        # dispatcher: runs common checks + per-agent checks
    postflight.yml       # dispatcher: runs per-agent verification
    checks/
      service_state.yml  # OS-aware: is service X active? (shared)
      log_pattern.yml    # OS-aware: does log file Y contain pattern Z recently? (shared)
      process_marker.yml # OS-aware: is a process running with marker W? (shared)
      api_node_status.yml# controller API: is node reporting? (DISABLED by default)
  defaults/main.yml      # check timeouts, retry counts, defaults
```

Three generic check primitives + one API hook. Each per-agent preflight/postflight
is just a short list of calls into these primitives with parameters from config.
**No agent role contains check logic** — they only *declare* their checks.

---

## 3. Configuration model (portability)

All environment-specific values live in config, in this precedence order
(lowest → highest):

| Layer | File | Holds |
|---|---|---|
| Framework defaults | `roles/*/defaults/main.yml` | Timeouts, retries, generic paths derived from `appd_home` |
| Agent-type config | `inventory/group_vars/<type>_agents.yml` | **Check definitions**: service names, log paths, log patterns, process markers |
| Contract config | `client_config/<client>.yml` | Controller, API base/creds, email, artifacts base, feature switches |
| Run overrides | `-e` on the command line | `appd_force=true`, `appd_action`, etc. |

New keys added to each `group_vars/<type>_agents.yml` (example, Java):

```yaml
# ---- flight checks (data only; logic lives in appd_flight) -------------------
java_agent_checks:
  log_file: "{{ java_agent_home }}/ver{{ java_agent_version }}/logs/{{ java_agent_node_name }}/agent.log"
  registered_pattern: "Started AppDynamics Java Agent|registered with the controller"
  process_marker: "-javaagent:.*javaagent\\.jar"     # proves the app loaded the agent
  in_use_blocks: [uninstall, upgrade]                # actions blocked while marker is live
```

Machine/DB agents declare `service_name`; .NET declares the coordinator service +
profiler marker. **Moving to a new contract or a nonstandard install layout means
editing these values only.**

Feature switches (in `client_config`, defaults shown):

```yaml
flight_preflight_enabled: true
flight_postflight_enabled: true
flight_api_checks_enabled: false     # flip when the API client exists
appd_force: false                     # override skip decisions (use deliberately)
```

---

## 4. Preflight: checks and skip logic

Preflight runs **per host, per agent type**, before any action task. It never
changes the host. Output: two facts + a recorded JSON.

```
appd_flight_go: true|false
appd_flight_reason: "ok" | "agent in use by running application" | ...
```

Every action task in the agent roles gains one guard line:

```yaml
when: appd_flight_go | bool or appd_force | bool
```

A skipped host is **not a failure** — the play continues to the next server, and the
skip + reason lands in the HTML report.

### 4.1 Common preflight (all agent types, all actions)

| # | Check | Primitive | Skip when |
|---|---|---|---|
| C1 | Agent home exists (for upgrade/uninstall/configure) | `stat` | Missing → skip "agent not installed" |
| C2 | Snapshot service state (recorded for the report) | `service_state` | never skips — evidence only |
| C3 | Sufficient disk space at `appd_home` (install/upgrade) | `shell df` / `win_shell` | Below threshold → skip "insufficient disk" |

### 4.2 Per-agent preflight

**Java APM** — the agent lives inside the customer's JVM, so the key question is
*"is a running application currently using this agent?"*

| Check | Primitive | Behavior |
|---|---|---|
| App process carries `-javaagent:...javaagent.jar` | `process_marker` | If found **and** action ∈ `in_use_blocks` (uninstall/upgrade) → **skip**: "agent in use by running application — schedule app restart window". Configure is allowed (files can be staged; takes effect on restart). |
| Agent log shows recent registration | `log_pattern` | Evidence only (feeds report + postflight baseline). |

**.NET** — same idea, Windows-flavored:

| Check | Primitive | Behavior |
|---|---|---|
| Coordinator service exists/state | `service_state` | Evidence. |
| Instrumented processes running (w3wp / listed apps) | `process_marker` | If running and action ∈ `in_use_blocks` → **skip**: "instrumented application running". |

**Machine Agent / DB Agent** — self-contained services, so preflight is simple:

| Check | Primitive | Behavior |
|---|---|---|
| Service state | `service_state` | Evidence; uninstall proceeds (we stop it ourselves). |

### 4.3 Force override

`-e appd_force=true` proceeds despite a skip verdict, and the report marks the host
**FORCED** with the original reason preserved. Deliberate, visible, auditable.

---

## 5. Postflight: verification per action

Postflight runs after the action, per host, and records a verdict + evidence:

```
verified: pass | fail | pending | skipped
evidence: [ "service active", "log matched 'Started AppDynamics...' at 14:02Z", ... ]
```

`pending` exists specifically for APM agents: config is correctly staged but takes
effect only when the application restarts. That's a truthful state, not a failure.

| Action | Machine / DB agent | Java / .NET APM |
|---|---|---|
| **configure** | Files rendered + service restarted + `service_state` = active → **pass** | Files rendered → **pending** ("awaiting app restart"). If app restarted and `log_pattern` matches after change → **pass** |
| **install** | Dir + binaries present, service installed + active | Dir + binaries present; instrumentation proof = `process_marker` after app restart → else **pending** |
| **upgrade** | New version dir present + service active + (optional) log shows new version string | New version present; **pass** only when `process_marker` shows the new agent path post-restart → else **pending** |
| **uninstall** | Service absent/stopped **and** agent home absent → **pass** | Same, **plus** `process_marker` must be absent (no running app still carrying the agent) |
| **validate** (refit) | Becomes: `service_state` + `log_pattern` (registered recently) | `process_marker` + `log_pattern` — real APM health, not just service state |

Retry: postflight service/log checks use `retries`/`delay` from `appd_flight`
defaults (e.g., 3 × 10s) so slow agent startups don't false-fail.

### 5.1 The API hook (future — designed now)

`checks/api_node_status.yml` is the single seam where the controller API plugs in:

- **Input:** node name / unique host id (already in config).
- **Question:** "Is this node reporting to the controller (availability metric within
  the last N minutes)?"
- **Today:** file exists, gated by `flight_api_checks_enabled: false`, body is a
  documented `uri`-module call against `appd_api_base_url` using the API client creds
  already defined in `client_config`.
- **Later:** the standalone API client replaces the `uri` call (custom module or CLI),
  and the same seam serves the bigger goal — API-driven discovery of servers, agents,
  and applications feeding a **dynamic inventory**. Playbooks don't change.

This is deliberately the *only* place API logic will live, so expanding automation
later is additive.

---

## 6. Logging & reporting (all on the control node)

No change to the principle — everything already lands on the Ansible server:

- `artifacts/ansible-latest.log` — every run, every task (already in `ansible.cfg`).
- `artifacts/<timestamp>/` — per-run folder with `ansible.log` archive, `report.html`,
  `run_metadata.json`, per-host records.

**Additions in this design:**

1. Preflight and postflight each write per-host JSON into the run folder:
   `preflight-<host>-<agent>.json`, `verify-<host>-<agent>.json` (same pattern as the
   existing `host-*.json` — one file per host avoids write collisions).
2. `report.html` gains three columns: **Preflight** (go / skip+reason / forced),
   **Changed** (exists today), **Verified** (pass / fail / pending+reason).
3. The email `on_failure` trigger upgrades from its current proxy ("file missing") to
   the real signal: any host with `verified: fail`.
4. The utility playbooks (`validate`, `discover`, `backup_config`) adopt the same
   start/report bracket so **every** playbook gets an archived, timestamped log —
   closing today's gap where only `site.yml` runs are archived.

---

## 7. What changes in the existing code (summary for review)

| Change | Size | Files touched |
|---|---|---|
| New role `appd_flight` (2 dispatchers + 3 check primitives + 1 API stub) | ~6 small task files | new |
| `check:` blocks added to agent group_vars | data only | 4 files |
| One preflight include + one postflight include + `when:` guards in agent roles | ~3 lines per action file | agent roles |
| Report template: 2 new columns + skip/forced styling | template edit | appd_accountability |
| Utility playbooks adopt the start/report bracket | ~10 lines each | 3 playbooks |
| `validate.yml` refit to use the same check primitives (covers APM properly) | rewrite of 1 playbook | 1 file |

Nothing about the existing configure/render logic changes. The framework wraps it.

---

## 8. Why this shape (talking points)

- **Reviewability:** check *logic* exists once, in three ~20-line task files. Everything
  else is declarative data. A reviewer reads the primitives once and then only reviews
  config diffs.
- **Idempotent + non-invasive:** preflight/postflight only read state; safe under
  `--check`; safe to run repeatedly.
- **Honest APM semantics:** `pending` acknowledges that APM agents activate on app
  restart instead of pretending a service check covers them.
- **Skip-and-continue:** matches real operational need — one integrated APM agent on
  one box shouldn't abort a 50-server run, and the report shows exactly who was
  skipped and why.
- **Portability:** new contract = new `client_config/<client>.yml` + adjusted check
  values in group_vars. Code base untouched.
- **Future API integration has one seam**, already parameterized by existing config.

---

## 9. Open questions before implementation

1. **Java log path layout** varies by agent version/node naming — confirm the actual
   on-disk layout at the site so `java_agent_checks.log_file` defaults are right.
2. **Disk-space threshold** for install/upgrade preflight (suggest 2× agent bundle size).
3. Should `configure` also be blocked (not just upgrade/uninstall) when an app is
   live, or is staging config while running acceptable? (Design assumes acceptable.)
4. Postflight retry budget (suggested 3 × 10s) — tune to the site's agent startup times.
5. Do we want the API check to *gate* verification when enabled, or only annotate it?
   (Design assumes annotate first, gate later.)
