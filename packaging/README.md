# Packaging & on-site deployment (air-gapped)

Build a sanitized ZIP on Windows, transfer it, and unzip it on the Linux control
node. The **extraction location becomes the project root** — every path in the
framework is relative, so nothing needs editing after unzip.

## What's included / excluded

The package contains the framework (playbooks, roles, inventory templates,
`client_config/example.client.yml`) and the offline Ansible collection bundle.

It **excludes** all client-specific and secret material: `client_config/active.yml`,
`inventory/group_vars/vault.yml`, `artifacts/`, installed `collections/`, and build
cruft. Nothing proprietary travels in the package.

## Flow

```
[internet host]          [Windows packager]          [Linux control node]
download_collections.sh  Package-Framework.ps1       unzip + bootstrap.sh
   |  fetch tarballs         |  zip + LF-normalize       |  perms, offline
   v                         v  + bundle collections     v  collections, checks
packaging/offline-       appd-agent-automation-     ready to run playbooks
  collections/             <version>.zip
```

### 1. Fetch collections for offline install (internet-connected host)

```bash
bash packaging/download_collections.sh
# writes tarballs + requirements.yml into packaging/offline-collections/
```

### 2. Build the package (Windows)

```powershell
.\packaging\Package-Framework.ps1 -Version 1.0.0
# optional: -IncludeDocs  to bundle the runbook + decks under docs/
# output: dist\appd-agent-automation-1.0.0.zip (+ .sha256)
```

### 3. Transfer & unzip (Linux control node)

```bash
unzip appd-agent-automation-1.0.0.zip
cd appd-agent-automation
bash packaging/bootstrap.sh
```

`bootstrap.sh` normalizes line endings, restores executable bits, creates and
secures `artifacts/`, checks prerequisites (Ansible, Python, WinRM libs if you
manage Windows hosts), and installs the bundled collections offline. It then
prints the remaining configuration steps.

### 4. Configure & run

```bash
cp client_config/example.client.yml client_config/active.yml      # edit
cp inventory/group_vars/vault.yml.example inventory/group_vars/vault.yml
ansible-vault encrypt inventory/group_vars/vault.yml
# edit inventory/hosts.yml
ansible-playbook playbooks/configure.yml --check --diff            # preview
```

## Notes

- **Line endings**: the packager converts shell/YAML/config files to LF; bootstrap
  re-normalizes as a safety net. Keep `.gitattributes` in place so git doesn't
  reintroduce CRLF.
- **Permissions**: Windows ZIPs drop Unix exec bits — bootstrap restores them.
- **Windows targets**: managing Windows hosts requires `pywinrm`/`pypsrp` on the
  control node. On an air-gapped node, stage those pip wheels too (not included).
