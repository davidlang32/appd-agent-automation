#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - prepare an extracted AppDynamics Agent Automation package
# on a Linux control node. Run ONCE, from the project root, after unzipping.
#
#   cd <extraction-dir>/appd-agent-automation
#   bash packaging/bootstrap.sh
#
# Idempotent: safe to re-run. The project root is wherever you extracted - all
# paths are relative, so no path editing is required.
# =============================================================================
set -euo pipefail

# Resolve project root = parent of this script's directory (the dir with ansible.cfg)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

say(){ printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[0;33m[!]\033[0m %s\n' "$*"; }
ok(){ printf '\033[0;32m[ok]\033[0m %s\n' "$*"; }

say "Project root: $ROOT"

# 1) Normalize line endings for shell + YAML (in case the zip carried CRLF) -----
if command -v sed >/dev/null; then
  say "Normalizing line endings (CRLF -> LF) on text assets"
  find . -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' -o -name '*.j2' -o -name '*.cfg' \) \
    -not -path './collections/*' -print0 | xargs -0 -r sed -i 's/\r$//'
  ok "line endings normalized"
fi

# 2) Restore executable bits (lost when zipped on Windows) ----------------------
say "Setting executable bits on scripts"
chmod +x packaging/*.sh 2>/dev/null || true
ok "scripts are executable"

# 3) Create + secure runtime directories ----------------------------------------
mkdir -p artifacts && chmod 0750 artifacts
ok "artifacts/ ready"
if [ -f inventory/group_vars/vault.yml ]; then chmod 600 inventory/group_vars/vault.yml; fi

# 4) Prerequisite checks --------------------------------------------------------
say "Checking prerequisites"
MISSING=0
if command -v python3 >/dev/null; then ok "python3: $(python3 --version 2>&1)"; else warn "python3 NOT found"; MISSING=1; fi
if command -v ansible-playbook >/dev/null; then
  ok "ansible: $(ansible --version 2>/dev/null | head -1)"
else
  warn "ansible-playbook NOT found - install Ansible (>=2.14) before running playbooks"; MISSING=1
fi
# Windows-target dependency (only needed if managing Windows hosts)
if python3 -c "import winrm" >/dev/null 2>&1 || python3 -c "import pypsrp" >/dev/null 2>&1; then
  ok "WinRM/PSRP python library present (Windows targets supported)"
else
  warn "No pywinrm/pypsrp found - REQUIRED only if you manage Windows hosts (pip install pywinrm pypsrp)"
fi

# 5) Install bundled Ansible collections OFFLINE --------------------------------
if [ -f packaging/offline-collections/requirements.yml ]; then
  say "Installing bundled collections (offline) into ./collections"
  ansible-galaxy collection install -r packaging/offline-collections/requirements.yml -p collections \
    && ok "collections installed from offline bundle" \
    || warn "offline collection install failed - check packaging/offline-collections/"
elif [ -f requirements.yml ]; then
  warn "No offline bundle found. On an internet-connected host run:"
  warn "    ansible-galaxy collection install -r requirements.yml -p collections"
fi

echo
say "Next steps:"
cat <<NEXT
  1) cp client_config/example.client.yml client_config/active.yml   # then edit
  2) cp inventory/group_vars/vault.yml.example inventory/group_vars/vault.yml
     ansible-vault encrypt inventory/group_vars/vault.yml
  3) edit inventory/hosts.yml  (add servers to OS + agent-type groups)
  4) preview:  ansible-playbook playbooks/configure.yml --check --diff
NEXT
[ "$MISSING" -eq 0 ] && ok "bootstrap complete" || warn "bootstrap complete with missing prerequisites (see above)"
