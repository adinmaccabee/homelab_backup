#!/usr/bin/env bash
# =============================================================================
# import-cert.sh — Import Caddy CA cert into Firefox
# Run on the VM after homelab.sh has completed.
# =============================================================================
set -euo pipefail

CERT="${1:-$HOME/caddy-ca.crt}"

if [ ! -f "$CERT" ]; then
  echo "ERROR: Certificate not found at ${CERT}"
  echo "Usage: ./import-cert.sh [/path/to/cert.crt]"
  exit 1
fi

# Install certutil if needed
if ! command -v certutil &>/dev/null; then
  echo "Installing libnss3-tools..."
  sudo apt-get install -y libnss3-tools
fi

# Find all Firefox profiles
PROFILES=$(find ~/.mozilla/firefox -name "*.default*" -o -name "*.default-release*" 2>/dev/null | head -10)

if [ -z "$PROFILES" ]; then
  echo "No Firefox profiles found. Has Firefox been run at least once?"
  exit 1
fi

echo "Importing Caddy CA cert into Firefox profiles..."
while IFS= read -r PROFILE; do
  if certutil -A -n "Caddy Local CA" -t "CT,," -i "$CERT" -d "$PROFILE" 2>/dev/null; then
    echo "  Imported into: $PROFILE"
  else
    echo "  Failed: $PROFILE"
  fi
done <<< "$PROFILES"

echo ""
echo "Done. Restart Firefox for changes to take effect."
