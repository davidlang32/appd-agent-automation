#!/usr/bin/env bash
# =============================================================================
# download_collections.sh - fetch Ansible collections for an AIR-GAPPED site.
# Run this on an INTERNET-CONNECTED machine BEFORE packaging. It writes the
# collection tarballs + a requirements.yml into packaging/offline-collections/,
# which the packager then includes in the zip. bootstrap.sh installs from there.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"
OUT="packaging/offline-collections"
mkdir -p "$OUT"
echo "==> Downloading collections from requirements.yml into $OUT"
ansible-galaxy collection download -r requirements.yml -p "$OUT"
echo "[ok] Done. Include $OUT/ in the package (the packager does this automatically)."
