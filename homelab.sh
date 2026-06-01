#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Homelab installer — local network edition
# Services: Authentik, Matrix/MAS/Element, LiveKit, Mailcow, Caddy
# HTTPS via Caddy internal CA. Import ~/caddy-ca.crt into browsers once.
# DNS via /etc/hosts on the VM. Add same entries to other devices manually.
# Idempotent — safe to rerun.
# Requires: Debian/Ubuntu with Docker Engine + Compose plugin.
# =============================================================================

# Install dependencies
for pkg in jq curl; do
  command -v "$pkg" &>/dev/null || sudo apt-get install -y "$pkg"
done

# Free up port 53 for dnsmasq (systemd-resolved may be using it)
if sudo ss -ulnp | grep -q ':53 '; then
  sudo systemctl disable --now systemd-resolved 2>/dev/null || true
  sudo rm -f /etc/resolv.conf
  echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf >/dev/null
fi
NETWORK_NAME="edge_net"

# Prompt for domain only if running interactively
if [ -t 0 ]; then
  read -rp "Domain [home.arpa]: " _domain
  DOMAIN_BASE="${_domain:-home.arpa}"
else
  DOMAIN_BASE="home.arpa"
fi

AUTH_DIR="$HOME/authentik-stack"
MATRIX_DIR="$HOME/matrix-stack"
CADDY_DIR="$HOME/caddy-stack"
MAILCOW_DIR="$HOME/mailcow-stack"
ENV_FILE="$HOME/homelab.env"

AUTH_DOMAIN="auth.${DOMAIN_BASE}"
MATRIX_DOMAIN="matrix.${DOMAIN_BASE}"
ELEMENT_DOMAIN="element.${DOMAIN_BASE}"
MAS_DOMAIN="mas.${DOMAIN_BASE}"
LIVEKIT_DOMAIN="livekit.${DOMAIN_BASE}"
MAIL_DOMAIN="mail.${DOMAIN_BASE}"

AUTH_URL="https://${AUTH_DOMAIN}"
MATRIX_URL="https://${MATRIX_DOMAIN}"
ELEMENT_URL="https://${ELEMENT_DOMAIN}"
MAIL_URL="https://${MAIL_DOMAIN}"
MAS_URL="https://${MAS_DOMAIN}"

rand_b64() { openssl rand -base64 "$1" | tr -d '\n/+='; }
rand_hex() { openssl rand -hex "$1" | tr -d '\n'; }

# =============================================================================
# PRE-FLIGHT: Cache sudo credentials upfront so we never get prompted mid-run
# =============================================================================
echo "==> This script needs sudo for file ownership changes."
echo "    Please enter your password once now."
sudo -v
# Keep sudo alive in the background for the duration of the script
( while true; do sudo -n true; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# =============================================================================
# STEP 0: Caddy reverse proxy
# =============================================================================
echo ""
echo "[0/5] Caddy"

# Detect VM's LAN IP (first non-loopback, non-docker IPv4)
VM_IP="$(ip -4 addr show scope global | grep -v 'docker\|br-\|veth' | \
  grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1)"
[ -z "$VM_IP" ] && VM_IP="$(hostname -I | awk '{print $1}')"
echo ""

mkdir -p "$CADDY_DIR"

# Pre-load saved secrets so re-runs don't re-prompt.
# shellcheck disable=SC1090
set +u
[ -f "$ENV_FILE" ] && source "$ENV_FILE" || true
set -u

# ---------------------------------------------------------------------------
# Caddy reverse proxy config
# ---------------------------------------------------------------------------
cat > "$CADDY_DIR/Caddyfile" <<CADDYEOF
{
  http_port 8080
  https_port 8443
  acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}

${AUTH_DOMAIN} {
  tls internal
  reverse_proxy authentik-server:9000
}

${MATRIX_DOMAIN} {
  tls internal
  reverse_proxy synapse:8008
}

${MAS_DOMAIN} {
  tls internal
  reverse_proxy mas:8080
}

${ELEMENT_DOMAIN} {
  tls internal
  reverse_proxy element:80
}

${LIVEKIT_DOMAIN} {
  tls internal
  reverse_proxy livekit-nginx:7890
}

${MAIL_DOMAIN} {
  tls internal
  reverse_proxy https://172.17.0.1:8444 {
    transport http {
      tls_insecure_skip_verify
    }
  }
}
CADDYEOF

cat > "$CADDY_DIR/docker-compose.yml" <<EOF
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:8080"
      - "443:8443"
    volumes:
      - ${CADDY_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - ${NETWORK_NAME}

  dnsmasq:
    image: andyshinn/dnsmasq:latest
    container_name: dnsmasq
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    ports:
      - "53:53/udp"
      - "53:53/tcp"
    volumes:
      - ${CADDY_DIR}/dnsmasq.conf:/etc/dnsmasq.conf:ro
    networks:
      - ${NETWORK_NAME}

volumes:
  caddy_data:
  caddy_config:

networks:
  ${NETWORK_NAME}:
    external: true
EOF

cat > "$CADDY_DIR/dnsmasq.conf" <<EOF
address=/.${DOMAIN_BASE}/${VM_IP}
local=/${DOMAIN_BASE}/
server=1.1.1.1
server=1.0.0.1
interface=*
bind-interfaces
EOF


docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 \
  || docker network create "$NETWORK_NAME"

echo "Starting Caddy and dnsmasq"
if docker inspect caddy >/dev/null 2>&1; then
  docker rm -f caddy 2>/dev/null || true
fi
if docker inspect dnsmasq >/dev/null 2>&1; then
  docker rm -f dnsmasq 2>/dev/null || true
fi
(cd "$CADDY_DIR" && docker compose up -d) || true

# Export Caddy's internal CA cert for browser import
echo "Generating Caddy CA cert ~/caddy-ca.crt"
sleep 5
CADDY_CA_EXPORTED=0
for i in $(seq 1 12); do
  if docker exec caddy cat /data/caddy/pki/authorities/local/root.crt \
    > "$HOME/caddy-ca.crt" 2>/dev/null; then
    CADDY_CA_EXPORTED=1
    echo "==> Caddy CA cert exported to ~/caddy-ca.crt"
    break
  fi
  sleep 5
done
[ "$CADDY_CA_EXPORTED" = "0" ] && \
  echo "WARNING: Could not export Caddy CA cert yet — run: docker exec caddy cat /data/caddy/pki/authorities/local/root.crt > ~/caddy-ca.crt"

# =============================================================================
# STEP 2: Directories + /etc/hosts
# =============================================================================
echo ""
echo ""

mkdir -p "$AUTH_DIR" "$MATRIX_DIR/synapse-config" "$CADDY_DIR" "$HOME/livekit-stack"
sudo chown -R "$USER:$USER" "$MATRIX_DIR/synapse-config" 2>/dev/null || true


for svc in auth matrix mas element livekit mail; do
  sudo sed -i "/${svc}.${DOMAIN_BASE}/d" /etc/hosts
  echo "${VM_IP} ${svc}.${DOMAIN_BASE}" | sudo tee -a /etc/hosts >/dev/null
done

# =============================================================================
# STEP 3: Generate/load secrets
# =============================================================================
echo ""


if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  echo "==> Loaded existing secrets from ${ENV_FILE}"
fi

AUTHENTIK_PG_PASS="${AUTHENTIK_PG_PASS:-$(rand_b64 36)}"
AUTHENTIK_SECRET_KEY="${AUTHENTIK_SECRET_KEY:-$(rand_b64 60)}"

AUTHENTIK_BOOTSTRAP_EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL:-akadmin@${DOMAIN_BASE}}"
AUTHENTIK_BOOTSTRAP_PASSWORD="${AUTHENTIK_BOOTSTRAP_PASSWORD:-$(rand_hex 16)}"
AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-$(rand_hex 32)}"

SYNAPSE_DB_USER="${SYNAPSE_DB_USER:-synapse}"
SYNAPSE_DB_PASS="${SYNAPSE_DB_PASS:-$(rand_hex 24)}"
SYNAPSE_DB_NAME="${SYNAPSE_DB_NAME:-synapse}"
MACAROON_SECRET="${MACAROON_SECRET:-$(rand_hex 32)}"
REGISTRATION_SHARED_SECRET="${REGISTRATION_SHARED_SECRET:-$(rand_hex 32)}"
FORM_SECRET="${FORM_SECRET:-$(rand_hex 32)}"
LIVEKIT_API_KEY="${LIVEKIT_API_KEY:-$(rand_b64 16)}"
LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET:-$(rand_b64 32)}"

# LDAP / mailcow OIDC
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=ldap,dc=goauthentik,dc=io}"
MAILCOW_OIDC_CLIENT_ID="${MAILCOW_OIDC_CLIENT_ID:-}"
MAILCOW_OIDC_CLIENT_SECRET="${MAILCOW_OIDC_CLIENT_SECRET:-}"

# MAS secrets
MAS_DB_USER="${MAS_DB_USER:-mas}"
MAS_DB_PASS="${MAS_DB_PASS:-$(rand_hex 24)}"
MAS_DB_NAME="${MAS_DB_NAME:-mas}"
MAS_ENCRYPTION_SECRET="${MAS_ENCRYPTION_SECRET:-$(rand_hex 32)}"
MAS_SYNAPSE_ADMIN_TOKEN="${MAS_SYNAPSE_ADMIN_TOKEN:-$(rand_hex 32)}"
MAS_SYNAPSE_CLIENT_SECRET="${MAS_SYNAPSE_CLIENT_SECRET:-$(rand_hex 32)}"

MAS_UPSTREAM_ID="${MAS_UPSTREAM_ID:-01HWKP3BXYZ00000000000MAS1}"
MAS_OIDC_CLIENT_ID="${MAS_OIDC_CLIENT_ID:-}"
MAS_OIDC_CLIENT_SECRET="${MAS_OIDC_CLIENT_SECRET:-}"

cat > "$ENV_FILE" <<EOF
DOMAIN_BASE=${DOMAIN_BASE}
VM_IP=${VM_IP}
AUTH_DOMAIN=${AUTH_DOMAIN}
MATRIX_DOMAIN=${MATRIX_DOMAIN}
ELEMENT_DOMAIN=${ELEMENT_DOMAIN}
MAS_DOMAIN=${MAS_DOMAIN}
AUTH_URL=${AUTH_URL}
MATRIX_URL=${MATRIX_URL}
ELEMENT_URL=${ELEMENT_URL}
MAS_URL=${MAS_URL}
AUTHENTIK_PG_PASS=${AUTHENTIK_PG_PASS}
AUTHENTIK_SECRET_KEY=${AUTHENTIK_SECRET_KEY}
AUTHENTIK_BOOTSTRAP_EMAIL=${AUTHENTIK_BOOTSTRAP_EMAIL}
AUTHENTIK_BOOTSTRAP_PASSWORD=${AUTHENTIK_BOOTSTRAP_PASSWORD}
AUTHENTIK_BOOTSTRAP_TOKEN=${AUTHENTIK_BOOTSTRAP_TOKEN}
SYNAPSE_DB_USER=${SYNAPSE_DB_USER}
SYNAPSE_DB_PASS=${SYNAPSE_DB_PASS}
SYNAPSE_DB_NAME=${SYNAPSE_DB_NAME}
MACAROON_SECRET=${MACAROON_SECRET}
REGISTRATION_SHARED_SECRET=${REGISTRATION_SHARED_SECRET}
FORM_SECRET=${FORM_SECRET}
LIVEKIT_API_KEY=${LIVEKIT_API_KEY}
LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET}
MAS_DB_USER=${MAS_DB_USER}
MAS_DB_PASS=${MAS_DB_PASS}
MAS_DB_NAME=${MAS_DB_NAME}
MAS_ENCRYPTION_SECRET=${MAS_ENCRYPTION_SECRET}
MAS_SYNAPSE_ADMIN_TOKEN=${MAS_SYNAPSE_ADMIN_TOKEN}
MAS_SYNAPSE_CLIENT_SECRET=${MAS_SYNAPSE_CLIENT_SECRET}
MAS_UPSTREAM_ID=${MAS_UPSTREAM_ID}
MAS_OIDC_CLIENT_ID=${MAS_OIDC_CLIENT_ID}
MAS_OIDC_CLIENT_SECRET=${MAS_OIDC_CLIENT_SECRET}
LDAP_BASE_DN=${LDAP_BASE_DN}
MAILCOW_OIDC_CLIENT_ID=${MAILCOW_OIDC_CLIENT_ID}
MAILCOW_OIDC_CLIENT_SECRET=${MAILCOW_OIDC_CLIENT_SECRET}
EOF

chmod 600 "$ENV_FILE"

# =============================================================================
# STEP 4: Authentik stack
# =============================================================================
echo ""
echo "[1/5] Authentik"

cat > "$AUTH_DIR/docker-compose.yml" <<EOF
services:
  authentik-postgresql:
    image: postgres:16-alpine
    container_name: authentik-postgresql
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U authentik -d authentik"]
      interval: 10s
      timeout: 5s
      retries: 10
    environment:
      POSTGRES_PASSWORD: ${AUTHENTIK_PG_PASS}
      POSTGRES_USER: authentik
      POSTGRES_DB: authentik
    volumes:
      - authentik_database:/var/lib/postgresql/data
    networks:
      - ${NETWORK_NAME}

  authentik-redis:
    image: redis:7-alpine
    container_name: authentik-redis
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - ${NETWORK_NAME}

  authentik-server:
    image: ghcr.io/goauthentik/server:latest
    container_name: authentik-server
    restart: unless-stopped
    command: server
    depends_on:
      authentik-postgresql:
        condition: service_healthy
      authentik-redis:
        condition: service_healthy
    environment:
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY}
      AUTHENTIK_POSTGRESQL__HOST: authentik-postgresql
      AUTHENTIK_POSTGRESQL__USER: authentik
      AUTHENTIK_POSTGRESQL__NAME: authentik
      AUTHENTIK_POSTGRESQL__PASSWORD: ${AUTHENTIK_PG_PASS}
      AUTHENTIK_REDIS__HOST: authentik-redis
      AUTHENTIK_BOOTSTRAP_EMAIL: ${AUTHENTIK_BOOTSTRAP_EMAIL}
      AUTHENTIK_BOOTSTRAP_PASSWORD: ${AUTHENTIK_BOOTSTRAP_PASSWORD}
      AUTHENTIK_BOOTSTRAP_TOKEN: ${AUTHENTIK_BOOTSTRAP_TOKEN}
      AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS: "0.0.0.0/0,::/0"
      AUTHENTIK_DEFAULT_HTTP_PROTOCOL: https
      AUTHENTIK_DOMAIN: ${AUTH_DOMAIN}
    networks:
      ${NETWORK_NAME}:
        aliases:
          - authentik-server

  authentik-worker:
    image: ghcr.io/goauthentik/server:latest
    container_name: authentik-worker
    restart: unless-stopped
    command: worker
    depends_on:
      authentik-postgresql:
        condition: service_healthy
      authentik-redis:
        condition: service_healthy
    environment:
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY}
      AUTHENTIK_POSTGRESQL__HOST: authentik-postgresql
      AUTHENTIK_POSTGRESQL__USER: authentik
      AUTHENTIK_POSTGRESQL__NAME: authentik
      AUTHENTIK_POSTGRESQL__PASSWORD: ${AUTHENTIK_PG_PASS}
      AUTHENTIK_REDIS__HOST: authentik-redis
      AUTHENTIK_BOOTSTRAP_EMAIL: ${AUTHENTIK_BOOTSTRAP_EMAIL}
      AUTHENTIK_BOOTSTRAP_PASSWORD: ${AUTHENTIK_BOOTSTRAP_PASSWORD}
      AUTHENTIK_BOOTSTRAP_TOKEN: ${AUTHENTIK_BOOTSTRAP_TOKEN}
      AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS: "0.0.0.0/0,::/0"
      AUTHENTIK_DEFAULT_HTTP_PROTOCOL: https
      AUTHENTIK_DOMAIN: ${AUTH_DOMAIN}
    networks:
      - ${NETWORK_NAME}

volumes:
  authentik_database:

networks:
  ${NETWORK_NAME}:
    external: true
EOF

if docker inspect authentik-server >/dev/null 2>&1 \
   && [ "$(docker inspect -f '{{.State.Health.Status}}' authentik-server 2>/dev/null)" = "healthy" ]; then
  echo "==> authentik-server already healthy, skipping."
else
  echo "==> Starting Authentik stack..."
  (cd "$AUTH_DIR" && docker compose up -d)
fi

echo "==> Waiting for Authentik to become ready (up to 6 minutes)..."
READY=0
for i in $(seq 1 120); do
  if docker exec authentik-server \
       python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:9000/-/health/ready/')" \
       >/dev/null 2>&1; then
    echo "    Ready after ~$((i * 3)) seconds."
    READY=1
    break
  fi
  printf "."
  sleep 3
done
echo ""
if [ "$READY" = "0" ]; then
  echo "ERROR: Authentik did not become ready in time."
  docker logs authentik-server --tail=80 || true
  exit 1
fi

# =============================================================================
# STEP 5: Configure Authentik OIDC provider for MAS
# =============================================================================
echo ""
echo ""

# Get an Authentik API token for credential verification on re-runs.
# Best-effort only — if it fails, we just regenerate credentials.
docker exec authentik-server ak shell -c "
from authentik.core.models import Token, TokenIntents, User
u = User.objects.filter(username='akadmin').first()
t, _ = Token.objects.get_or_create(
    identifier='homelab-setup-token',
    defaults={'user': u, 'intent': TokenIntents.INTENT_API, 'expiring': False}
)
open('/tmp/ak_token.txt', 'w').write(t.key)
" >/dev/null 2>&1 || true
docker cp authentik-server:/tmp/ak_token.txt /tmp/ak_token.txt 2>/dev/null || true
AK_TOKEN="$(cat /tmp/ak_token.txt 2>/dev/null | tr -d '\n' || true)"

# Check if saved credentials actually exist in the live Authentik DB.
OIDC_CREDS_VALID=0
if [ -n "$MAS_OIDC_CLIENT_ID" ] && [ -n "$MAS_OIDC_CLIENT_SECRET" ]; then
  if [ -n "$AK_TOKEN" ]; then
    DB_CLIENT_ID="$(curl -sk "http://localhost:9000/api/v3/providers/oauth2/?name=Matrix+MAS" \
      -H "Authorization: Bearer ${AK_TOKEN}" 2>/dev/null \
      | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4 | head -1 || true)"
    if [ "$DB_CLIENT_ID" = "$MAS_OIDC_CLIENT_ID" ] && [ -n "$DB_CLIENT_ID" ]; then
      OIDC_CREDS_VALID=1
    else
      echo "==> Saved MAS OIDC credentials don't match Authentik DB — regenerating."
      MAS_OIDC_CLIENT_ID=""
      MAS_OIDC_CLIENT_SECRET=""
    fi
  else
    # Can't verify — assume valid to avoid unnecessary regeneration on re-runs
    OIDC_CREDS_VALID=1
  fi
fi

if [ "$OIDC_CREDS_VALID" = "1" ]; then
  echo "==> MAS OIDC credentials already present and verified, skipping provider creation."
  # Even if creds exist, ensure the redirect URI in Authentik matches
  # current MAS_UPSTREAM_ID (handles re-runs after ID change)
  REDIRECT_URI="${MAS_URL}/upstream/callback/${MAS_UPSTREAM_ID}"
  OIDC_FIXUP_SCRIPT="$(mktemp)"
  cat > "$OIDC_FIXUP_SCRIPT" <<PYEOF
from authentik.providers.oauth2.models import OAuth2Provider, RedirectURI, RedirectURIMatchingMode
import sys
REDIRECT = sys.argv[1]
try:
    p = OAuth2Provider.objects.get(name='Matrix MAS')
    existing = [getattr(u, 'url', None) for u in (p.redirect_uris or [])]
    if REDIRECT not in existing:
        p.redirect_uris = [RedirectURI(matching_mode=RedirectURIMatchingMode.STRICT, url=REDIRECT)]
        p.save()
        print("REDIRECT_UPDATED")
    else:
        print("REDIRECT_OK")
except Exception as e:
    print(f"REDIRECT_ERROR: {e}")
PYEOF
  FIXUP_WRAPPER="$(mktemp)"
  cat > "$FIXUP_WRAPPER" <<WRAPEOF
import sys
sys.argv = ['', '${REDIRECT_URI}']
exec(open('/tmp/oidc_fixup.py').read())
WRAPEOF
  docker cp "$OIDC_FIXUP_SCRIPT" authentik-server:/tmp/oidc_fixup.py
  docker cp "$FIXUP_WRAPPER"     authentik-server:/tmp/oidc_fixup_wrapper.py
  rm -f "$OIDC_FIXUP_SCRIPT" "$FIXUP_WRAPPER"
  FIXUP_RESULT="$(docker exec authentik-server \
    ak shell -c "exec(open('/tmp/oidc_fixup_wrapper.py').read())" 2>/tmp/ak_fixup_stderr.txt \
    | grep -E '^REDIRECT_' | tail -1 || true)"
  echo "==> Redirect URI check: ${FIXUP_RESULT:-no output}"
else
  OIDC_SCRIPT="$(mktemp)"
  cat > "$OIDC_SCRIPT" <<'PYEOF'
from authentik.core.models import Application
from authentik.providers.oauth2.models import (
    OAuth2Provider, ClientTypes, RedirectURI, RedirectURIMatchingMode, ScopeMapping
)
from authentik.crypto.models import CertificateKeyPair
from authentik.flows.models import Flow
import secrets, sys

REDIRECT = sys.argv[1]

slug = "matrix-mas"
auth_flow = Flow.objects.filter(slug="default-provider-authorization-explicit-consent").first()

inv_flow = Flow.objects.filter(slug="default-provider-invalidation-flow").first()
if not auth_flow:
    raise RuntimeError("Could not find authorization flow — is Authentik fully initialized?")

signing_key = (
    CertificateKeyPair.objects.filter(name="authentik Self-signed Certificate").first()
    or CertificateKeyPair.objects.first()
)


defaults = {
    "client_type":        ClientTypes.CONFIDENTIAL,
    "client_id":          secrets.token_urlsafe(24),
    "client_secret":      secrets.token_urlsafe(48),
    "authorization_flow": auth_flow,
    "signing_key":        signing_key,
}
if inv_flow:
    defaults["invalidation_flow"] = inv_flow

provider, _ = OAuth2Provider.objects.get_or_create(name="Matrix MAS", defaults=defaults)

changed = False
for attr, val in [
    ("client_type",        ClientTypes.CONFIDENTIAL),
    ("authorization_flow", auth_flow),
    ("signing_key",        signing_key),
]:
    if val is not None and getattr(provider, attr) != val:
        setattr(provider, attr, val); changed = True

if inv_flow is not None and getattr(provider, "invalidation_flow", None) != inv_flow:
    provider.invalidation_flow = inv_flow; changed = True

if not provider.client_id:
    provider.client_id = secrets.token_urlsafe(24); changed = True
if not provider.client_secret:
    provider.client_secret = secrets.token_urlsafe(48); changed = True


provider.redirect_uris = [
    RedirectURI(matching_mode=RedirectURIMatchingMode.STRICT, url=REDIRECT)
]
changed = True

if changed:
    provider.save()

scopes = ScopeMapping.objects.filter(name__regex=r"'(openid|profile|email)'")
if scopes.count() < 3:
    scopes = (
        ScopeMapping.objects.filter(name__icontains="openid") |
        ScopeMapping.objects.filter(name__icontains="profile") |
        ScopeMapping.objects.filter(name__icontains="email")
    )
for scope in scopes:
    provider.property_mappings.add(scope)
provider.save()
print(f"SCOPES_ADDED={','.join(scopes.values_list('name', flat=True))}")

app, _ = Application.objects.get_or_create(
    slug=slug, defaults={"name": "Matrix MAS", "provider": provider}
)
if app.provider_id != provider.pk:
    app.provider = provider; app.save()


with open('/tmp/mas_oidc_result.txt', 'w') as f:
    f.write(f"CLIENT_ID={provider.client_id}\n")
    f.write(f"CLIENT_SECRET={provider.client_secret}\n")
PYEOF

  REDIRECT_URI="${MAS_URL}/upstream/callback/${MAS_UPSTREAM_ID}"
  docker cp "$OIDC_SCRIPT" authentik-server:/tmp/configure_mas_oidc.py
  rm -f "$OIDC_SCRIPT"

  WRAPPER="$(mktemp)"
  cat > "$WRAPPER" <<WRAPEOF
import sys
sys.argv = ['', '${REDIRECT_URI}']
exec(open('/tmp/configure_mas_oidc.py').read())
WRAPEOF
  docker cp "$WRAPPER" authentik-server:/tmp/run_mas_oidc.py
  rm -f "$WRAPPER"

  
  # and read credentials from the file the Python script wrote instead.
  docker exec authentik-server \
    ak shell -c "exec(open('/tmp/run_mas_oidc.py').read())" \
    >/dev/null 2>&1 || true

  # Try docker cp first (cleanest — no stdout pollution)
  CREDS_FILE="$(mktemp)"
  docker cp authentik-server:/tmp/mas_oidc_result.txt "$CREDS_FILE" 2>/dev/null || true
  CLIENT_ID="$(grep '^CLIENT_ID=' "$CREDS_FILE" | cut -d= -f2- | tr -d '\n' || true)"
  CLIENT_SECRET="$(grep '^CLIENT_SECRET=' "$CREDS_FILE" | cut -d= -f2- | tr -d '\n' || true)"
  rm -f "$CREDS_FILE"

  # Fallback: REST API if we have a token and docker cp gave nothing
  if [ -z "$CLIENT_ID" ] && [ -n "$AK_TOKEN" ]; then
    sleep 2
    API_RESP="$(curl -sk "http://localhost:9000/api/v3/providers/oauth2/?name=Matrix+MAS" \
      -H "Authorization: Bearer ${AK_TOKEN}" 2>/dev/null)"
    CLIENT_ID="$(echo "$API_RESP" | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4 | head -1 || true)"
    CLIENT_SECRET="$(echo "$API_RESP" | grep -o '"client_secret":"[^"]*"' | cut -d'"' -f4 | head -1 || true)"
  fi

  if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
    echo "ERROR: Failed to extract MAS OIDC credentials from Authentik."
    echo "       Run manually: curl -sk http://localhost:9000/api/v3/providers/oauth2/ | grep client"
    echo "       Then set MAS_OIDC_CLIENT_ID and MAS_OIDC_CLIENT_SECRET in ~/homelab.env and rerun."
    exit 1
  fi

  MAS_OIDC_CLIENT_ID="$CLIENT_ID"
  MAS_OIDC_CLIENT_SECRET="$CLIENT_SECRET"

  grep -v '^MAS_OIDC_CLIENT_ID=' "$ENV_FILE" \
    | grep -v '^MAS_OIDC_CLIENT_SECRET=' > "$ENV_FILE.tmp"
  printf 'MAS_OIDC_CLIENT_ID=%s\nMAS_OIDC_CLIENT_SECRET=%s\n' \
    "$MAS_OIDC_CLIENT_ID" "$MAS_OIDC_CLIENT_SECRET" >> "$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  echo "==> MAS OIDC credentials saved."
fi

# =============================================================================
# =============================================================================
# STEP 6: Matrix / MAS / Element
# =============================================================================
echo ""
echo "[2/5] Matrix"

# Chrome extension — hides Legacy Call, auto-selects Element Call
EXT_DIR="$MATRIX_DIR/element-call-extension"
mkdir -p "$EXT_DIR"
cat > "$EXT_DIR/manifest.json" <<'EXTEOF'
{
  "manifest_version": 3,
  "name": "Element Hide Legacy Calls",
  "version": "1.1",
  "description": "Auto-selects Element Call, hiding the legacy call option",
  "content_scripts": [{
    "matches": ["https://element.home.arpa/*"],
    "css": ["hide-calls.css"],
    "js": ["auto-call.js"]
  }]
}
EXTEOF
cat > "$EXT_DIR/hide-calls.css" <<'EXTEOF'
button[aria-label="Legacy Call"] { display: none !important; }
EXTEOF
cat > "$EXT_DIR/auto-call.js" <<'EXTEOF'
(function() {
  const observer = new MutationObserver(() => {
    document.querySelectorAll('button[aria-label="Legacy Call"]').forEach(el => el.remove());
    const ec = document.querySelector('button[aria-label="Element Call"]');
    const lc = document.querySelector('button[aria-label="Legacy Call"]');
    if (ec && lc) setTimeout(() => ec.click(), 50);
  });
  observer.observe(document.body, { childList: true, subtree: true });
})();
EXTEOF
echo "Writing chrome extension ${EXT_DIR}"


cat > "$MATRIX_DIR/element-config.json" <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "${MATRIX_URL}",
      "server_name": "${MATRIX_DOMAIN}"
    }
  },
  "disable_custom_urls": false,
  "disable_guests": true,
  "features": {
    "feature_group_calls": true
  },
  "element_call": {
    "url": "https://call.element.io",
    "participant_limit": 8,
    "brand": "Element Call"
  },
  "setting_defaults": {
    "fallbackICEServerAllowed": false,
    "feature_disable_call_per_sender_encryption": false
  }
}
EOF

cat > "$MATRIX_DIR/docker-compose.yml" <<EOF
services:
  matrix-postgres:
    image: postgres:16-alpine
    container_name: matrix-postgres
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${SYNAPSE_DB_USER} -d ${SYNAPSE_DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 10
    environment:
      POSTGRES_DB: ${SYNAPSE_DB_NAME}
      POSTGRES_USER: ${SYNAPSE_DB_USER}
      POSTGRES_PASSWORD: ${SYNAPSE_DB_PASS}
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
    volumes:
      - matrix_postgres_data:/var/lib/postgresql/data
    networks:
      ${NETWORK_NAME}:
        aliases:
          - matrix-postgres

  mas-postgres:
    image: postgres:16-alpine
    container_name: mas-postgres
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${MAS_DB_USER} -d ${MAS_DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 10
    environment:
      POSTGRES_DB: ${MAS_DB_NAME}
      POSTGRES_USER: ${MAS_DB_USER}
      POSTGRES_PASSWORD: ${MAS_DB_PASS}
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
    volumes:
      - mas_postgres_data:/var/lib/postgresql/data
    networks:
      ${NETWORK_NAME}:
        aliases:
          - mas-postgres

  mas:
    image: ghcr.io/element-hq/matrix-authentication-service:latest
    container_name: mas
    restart: unless-stopped
    depends_on:
      mas-postgres:
        condition: service_healthy
    extra_hosts:
      - "auth.${DOMAIN_BASE}:${VM_IP}"
      - "matrix.${DOMAIN_BASE}:${VM_IP}"
      - "mas.${DOMAIN_BASE}:${VM_IP}"
    environment:
      MAS_CONFIG: /config/config.yaml
      SSL_CERT_FILE: /etc/ssl/certs/caddy-ca.crt
    command: server
    volumes:
      - ./mas-config:/config:ro
      - ${HOME}/caddy-ca.crt:/etc/ssl/certs/caddy-ca.crt:ro
    networks:
      ${NETWORK_NAME}:
        aliases:
          - mas

  synapse:
    image: matrixdotorg/synapse:latest
    container_name: synapse
    restart: unless-stopped
    depends_on:
      matrix-postgres:
        condition: service_healthy
    extra_hosts:
      - "auth.${DOMAIN_BASE}:${VM_IP}"
      - "matrix.${DOMAIN_BASE}:${VM_IP}"
      - "mas.${DOMAIN_BASE}:${VM_IP}"
      - "element.${DOMAIN_BASE}:${VM_IP}"
      - "mail.${DOMAIN_BASE}:${VM_IP}"
    volumes:
      - ./synapse-config:/data
      - ${HOME}/caddy-ca.crt:/usr/local/share/ca-certificates/caddy-ca.crt:ro
    networks:
      ${NETWORK_NAME}:
        aliases:
          - synapse

  element:
    image: vectorim/element-web:latest
    container_name: element
    restart: unless-stopped
    volumes:
      - ./element-config.json:/app/config.json:ro
    networks:
      ${NETWORK_NAME}:
        aliases:
          - element

volumes:
  matrix_postgres_data:
  mas_postgres_data:

networks:
  ${NETWORK_NAME}:
    external: true
EOF

# ---------------------------------------------------------------------------
# MAS config + signing key
# ---------------------------------------------------------------------------
mkdir -p "$MATRIX_DIR/mas-config/keys"

sudo chown -R "$USER:$USER" "$MATRIX_DIR/mas-config" 2>/dev/null || true
if [ ! -f "$MATRIX_DIR/mas-config/keys/rsa.pem" ]; then
  echo "==> Generating MAS signing key..."
  sudo openssl genrsa -out "$MATRIX_DIR/mas-config/keys/rsa.pem" 4096
fi
sudo chmod 644 "$MATRIX_DIR/mas-config/keys/rsa.pem"
sudo chmod 755 "$MATRIX_DIR/mas-config/keys"


sudo chown -R "$USER:$USER" "$MATRIX_DIR/mas-config" 2>/dev/null || true

cat > "$MATRIX_DIR/mas-config/config.yaml" <<EOF
http:
  public_base: "${MAS_URL}/"
  issuer: "${MAS_URL}/"
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat
        - name: graphql
        - name: assets
          path: /usr/local/share/mas-cli/assets/
      binds:
        - address: "0.0.0.0:8080"

database:
  host: mas-postgres
  port: 5432
  username: "${MAS_DB_USER}"
  password: "${MAS_DB_PASS}"
  database: "${MAS_DB_NAME}"
  ssl_mode: disable

matrix:
  homeserver: "${MATRIX_DOMAIN}"
  secret: "${MAS_SYNAPSE_ADMIN_TOKEN}"
  endpoint: "http://synapse:8008"

clients:
  - client_id: 0000000000000000000SYNAPSE
    client_auth_method: client_secret_basic
    client_secret: "${MAS_SYNAPSE_CLIENT_SECRET}"

secrets:
  encryption: "${MAS_ENCRYPTION_SECRET}"
  keys:
    - key_file: /config/keys/rsa.pem

passwords:
  enabled: false

upstream_oauth2:
  providers:
    - id: "${MAS_UPSTREAM_ID}"
      human_name: Authentik
      issuer: "http://authentik-server:9000/application/o/matrix-mas/"
      client_id: "${MAS_OIDC_CLIENT_ID}"
      client_secret: "${MAS_OIDC_CLIENT_SECRET}"
      token_endpoint_auth_method: client_secret_basic
      scope: "openid profile email"
      discovery_mode: disabled
      authorization_endpoint: "${AUTH_URL}/application/o/authorize/"
      token_endpoint: "http://authentik-server:9000/application/o/token/"
      jwks_uri: "http://authentik-server:9000/application/o/matrix-mas/jwks/"
      userinfo_endpoint: "http://authentik-server:9000/application/o/userinfo/"
      introspection_endpoint: "http://authentik-server:9000/application/o/introspect/"
      claims_imports:
        localpart:
          action: require
          template: "{{ user.preferred_username }}"
        displayname:
          action: force
          template: "{{ user.name }}"
        email:
          action: force
          template: "{{ user.email }}"
EOF

# ---------------------------------------------------------------------------
# Synapse config
# ---------------------------------------------------------------------------
if [ ! -f "$MATRIX_DIR/synapse-config/${MATRIX_DOMAIN}.signing.key" ]; then
  echo "==> Generating Synapse config..."
  docker run --rm \
    -v "$MATRIX_DIR/synapse-config:/data" \
    -e SYNAPSE_SERVER_NAME="${MATRIX_DOMAIN}" \
    -e SYNAPSE_REPORT_STATS=no \
    matrixdotorg/synapse:latest generate
  sudo chown -R "$USER:$USER" "$MATRIX_DIR/synapse-config"
else
  echo "==> Synapse signing key already exists, skipping generation."
fi


PUBLIC_IP="$(curl -s --max-time 10 https://ifconfig.me || curl -s --max-time 10 https://api.ipify.org)"
if [ -z "$PUBLIC_IP" ]; then
  echo "ERROR: Could not detect public IP. Check your internet connection."
  exit 1
fi


cat > "$MATRIX_DIR/synapse-config/homeserver.yaml" <<EOF
server_name: "${MATRIX_DOMAIN}"
pid_file: /data/homeserver.pid
public_baseurl: "${MATRIX_URL}/"

# Serve /.well-known/matrix/server so lk-jwt can find Synapse on port 443
serve_server_wellknown: true

# Advertise LiveKit in /.well-known/matrix/client so Element Call can find it
extra_well_known_client_content:
  org.matrix.msc4143.rtc_foci:
    - type: "livekit"
      livekit_service_url: "https://livekit.${DOMAIN_BASE}"
      livekit_jwt_url: "https://livekit.${DOMAIN_BASE}/livekit/jwt"

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false

database:
  name: psycopg2
  args:
    user: ${SYNAPSE_DB_USER}
    password: ${SYNAPSE_DB_PASS}
    database: ${SYNAPSE_DB_NAME}
    host: matrix-postgres
    cp_min: 5
    cp_max: 10

log_config: "/data/${MATRIX_DOMAIN}.log.config"
media_store_path: /data/media_store
registration_shared_secret: "${REGISTRATION_SHARED_SECRET}"
report_stats: false
macaroon_secret_key: "${MACAROON_SECRET}"
form_secret: "${FORM_SECRET}"
signing_key_path: "/data/${MATRIX_DOMAIN}.signing.key"

trusted_key_servers:
  - server_name: "matrix.org"

# MAS (Matrix Authentication Service) + LiveKit Element Call integration
experimental_features:
  msc3861:
    enabled: true
    issuer: "http://mas:8080/"
    client_id: "0000000000000000000SYNAPSE"
    client_auth_method: client_secret_basic
    client_secret: "${MAS_SYNAPSE_CLIENT_SECRET}"
    admin_token: "${MAS_SYNAPSE_ADMIN_TOKEN}"
    account_management_url: "http://mas:8080/account"
    introspection_endpoint: "http://mas:8080/oauth2/introspect"
  msc3401:
    enabled: true
  msc4143:
    enabled: true

password_config:
  enabled: false
EOF

sudo chown -R 991:991 "$MATRIX_DIR/synapse-config"
sudo chmod 750 "$MATRIX_DIR/synapse-config"
sudo chmod 640 "$MATRIX_DIR/synapse-config/homeserver.yaml"
sudo chmod 600 "$MATRIX_DIR/synapse-config/"*.signing.key 2>/dev/null || true

# Set permissions first, then ownership
sudo chmod 644 "$MATRIX_DIR/mas-config/keys/rsa.pem"
sudo chmod 755 "$MATRIX_DIR/mas-config/keys"
sudo chmod 644 "$MATRIX_DIR/mas-config/config.yaml"
sudo chown -R 65532:65532 "$MATRIX_DIR/mas-config" 2>/dev/null || true

# Synapse is started AFTER LiveKit is provisioned so the config
# is in homeserver.yaml before Synapse first boots.
MATRIX_STACK_NEEDS_START=1
if docker inspect synapse >/dev/null 2>&1 \
   && [ "$(docker inspect -f '{{.State.Status}}' synapse 2>/dev/null)" = "running" ]; then
  MATRIX_STACK_NEEDS_START=0
fi
# =============================================================================
# STEP 7: LiveKit (SFU for Element Call — handles 1:1 and group calls)
# =============================================================================
echo ""
echo "[3/5] LiveKit"

LIVEKIT_DIR="$HOME/livekit-stack"
mkdir -p "$LIVEKIT_DIR"

DOCKER_HOST_IP="$(ip route | grep docker0 | awk '{print $9}')"
DOCKER_HOST_IP="${DOCKER_HOST_IP:-172.17.0.1}"

# Caddy already proxies livekit.home.arpa — nothing to do here

cat > "$LIVEKIT_DIR/livekit.yaml" <<EOF
port: 7880
rtc:
  tcp_port: 7881
  udp_port: 7882
  use_external_ip: true
keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}
logging:
  level: info
EOF

cat > "$LIVEKIT_DIR/nginx.conf" <<'NGINXEOF'
events {}
http {
  server {
    listen 7890;
    location /sfu/get {
      proxy_pass http://lk-jwt:8080/sfu/get;
    }
    location /livekit/jwt {
      proxy_pass http://lk-jwt:8080/livekit/jwt;
    }
    location / {
      proxy_pass http://172.17.0.1:7880;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
    }
  }
}
NGINXEOF

cat > "$LIVEKIT_DIR/docker-compose.yml" <<EOF
services:
  livekit:
    image: livekit/livekit-server:latest
    container_name: livekit
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${LIVEKIT_DIR}/livekit.yaml:/etc/livekit.yaml
    command: --config /etc/livekit.yaml

  lk-jwt:
    image: ghcr.io/element-hq/lk-jwt-service:latest-ci
    container_name: lk-jwt
    restart: unless-stopped
    environment:
      - LIVEKIT_URL=wss://livekit.${DOMAIN_BASE}
      - LIVEKIT_KEY=${LIVEKIT_API_KEY}
      - LIVEKIT_SECRET=${LIVEKIT_API_SECRET}
      - LIVEKIT_JWT_BIND=:8080
    networks:
      - ${NETWORK_NAME}

  livekit-nginx:
    image: nginx:alpine
    container_name: livekit-nginx
    restart: unless-stopped
    volumes:
      - ${LIVEKIT_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - ${NETWORK_NAME}

networks:
  ${NETWORK_NAME}:
    external: true
EOF

echo "Starting LiveKit stack"
(cd "$LIVEKIT_DIR" && docker compose up -d)


if [ "$MATRIX_STACK_NEEDS_START" = "1" ]; then
  echo "==> Starting Matrix stack..."
  (cd "$MATRIX_DIR" && docker compose up -d)
else
  echo "==> Restarting MAS and Synapse to pick up config changes..."
  (cd "$MATRIX_DIR" && docker compose up -d mas-postgres mas)
  docker restart mas synapse
fi

# Inject Caddy CA cert into Synapse's trust store (it needs to verify MAS's cert)
if docker exec synapse test -f /usr/local/share/ca-certificates/caddy-ca.crt 2>/dev/null; then
  docker exec synapse update-ca-certificates >/dev/null 2>&1 || true
fi

# Ensure the openid/profile/email scopes are assigned to the Matrix MAS provider.
# Authentik 5.x doesn't auto-assign scopes on provider creation so we force it here.

docker exec authentik-server ak shell -c "
from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping
p = OAuth2Provider.objects.filter(name='Matrix MAS').first()
if p:
    scopes = ScopeMapping.objects.filter(name__regex=r\"'(openid|profile|email)'\")
    for s in scopes:
        p.property_mappings.add(s)
    p.save()
    print('Scopes OK')
else:
    print('ERROR: Matrix MAS provider not found')
" 2>/dev/null | tail -1
docker restart mas >/dev/null 2>&1

# =============================================================================
# STEP 8: Mailcow + Authentik LDAP
# =============================================================================
echo ""
echo "[4/5] Mailcow"

echo "Checking mail prerequisites"
if ! timeout 5 bash -c "echo QUIT | nc -q1 gmail-smtp-in.l.google.com 25" >/dev/null 2>&1; then
  echo ""
  echo "WARNING: Cannot reach port 25 outbound. Your ISP may be blocking it."
  echo "         Mailcow will run but outbound mail will likely be rejected."
  echo "         Press Ctrl-C to abort, or wait 10 seconds to continue anyway."
  sleep 10
else
  echo "==> Port 25 outbound: OK"
fi

# ---------------------------------------------------------------------------
# 8b. Authentik LDAP outpost
# ---------------------------------------------------------------------------


LDAP_SCRIPT="$(mktemp)"
cat > "$LDAP_SCRIPT" <<'PYEOF'
from authentik.core.models import Application, Group
from authentik.providers.ldap.models import LDAPProvider
from authentik.outposts.models import Outpost, OutpostType
from authentik.core.models import Token, User
import json

mail_group, _ = Group.objects.get_or_create(name="mailcow-users")

# Create LDAP provider with correct fields for Authentik 5.x
provider, created = LDAPProvider.objects.get_or_create(
    name="Mailcow LDAP",
    defaults={"base_dn": "dc=ldap,dc=goauthentik,dc=io"},
)
print(f"Provider: {provider.pk} created={created}")

# Assign authorization flow — required by LDAPOutpostConfigSerializer
from authentik.flows.models import Flow
auth_flow = Flow.objects.filter(slug="default-authentication-flow").first()
if auth_flow and provider.authorization_flow != auth_flow:
    provider.authorization_flow = auth_flow
    provider.save()
    print(f"Set authorization_flow: {auth_flow.slug}")

app, _ = Application.objects.get_or_create(
    slug="mailcow-ldap",
    defaults={"name": "Mailcow LDAP", "provider": provider},
)
# Always ensure provider is linked — required for LDAPOutpostConfigViewSet queryset
app.provider = provider
app.save()

# Create outpost with config stored as dict (not JSON string)
outpost_config = {
    "log_level": "info",
    "authentik_host": "http://authentik-server:9000",
    "authentik_host_insecure": True,
    "authentik_host_browser": "",
    "object_naming_template": "ak-outpost-%(name)s",
    "docker_network": None,
    "docker_map_ports": True,
    "docker_labels": None,
    "container_image": None,
    "kubernetes_replicas": 1,
    "kubernetes_namespace": "authentik",
    "kubernetes_ingress_annotations": {},
    "kubernetes_ingress_secret_name": "authentik-outpost-tls",
    "kubernetes_service_type": "ClusterIP",
    "kubernetes_disabled_components": [],
    "kubernetes_image_pull_secrets": [],
    "refresh_interval": "minutes=5"
}

outpost, created = Outpost.objects.get_or_create(
    name="Mailcow LDAP Outpost",
    defaults={"type": OutpostType.LDAP, "_config": outpost_config},
)
if not created:
    outpost._config = outpost_config
    outpost.save()

outpost.providers.set([provider])

# Fix config type in DB if stored as string
from django.db import connection
with connection.cursor() as cursor:
    cursor.execute(
        "UPDATE authentik_outposts_outpost SET _config = %s::jsonb WHERE name = %s",
        [json.dumps(outpost_config), "Mailcow LDAP Outpost"]
    )

# Get the outpost token
token = Token.objects.filter(identifier__startswith=f"ak-outpost-{outpost.pk}").first()
with open('/tmp/ldap_result.txt', 'w') as f:
    f.write(f"LDAP_SETUP_OK\n")
    f.write(f"BASE_DN={provider.base_dn}\n")
    f.write(f"OUTPOST_PK={outpost.pk}\n")
    f.write(f"OUTPOST_TOKEN={token.key if token else ''}\n")
print("Done")
PYEOF

docker cp "$LDAP_SCRIPT" authentik-server:/tmp/configure_ldap.py
rm -f "$LDAP_SCRIPT"

docker exec authentik-server \
  ak shell -c "exec(open('/tmp/configure_ldap.py').read())" >/dev/null 2>&1 || true

LDAP_RAW="$(docker exec authentik-server cat /tmp/ldap_result.txt 2>/dev/null || true)"
LDAP_BASE_DN="$(echo "$LDAP_RAW" | grep '^BASE_DN=' | cut -d= -f2- | head -1 || true)"
LDAP_OUTPOST_PK="$(echo "$LDAP_RAW" | grep '^OUTPOST_PK=' | cut -d= -f2- | head -1 || true)"
LDAP_OUTPOST_TOKEN="$(echo "$LDAP_RAW" | grep '^OUTPOST_TOKEN=' | cut -d= -f2- | head -1 || true)"

[ -z "$LDAP_BASE_DN" ] && LDAP_BASE_DN="dc=ldap,dc=goauthentik,dc=io"

# Persist LDAP_BASE_DN so re-runs and the ldap-mailcow compose pick it up
grep -v '^LDAP_BASE_DN=' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
echo "LDAP_BASE_DN=${LDAP_BASE_DN}" >> "$ENV_FILE"



# Deploy the Authentik LDAP outpost container
if [ -n "$LDAP_OUTPOST_TOKEN" ]; then
  echo "==> Starting Authentik LDAP outpost container..."
  # Use same version tag as the server to avoid version mismatch panics
  AK_VERSION="$(docker exec authentik-server ak shell -c "
from authentik.lib.version import VERSION
import sys; sys.stdout.write(VERSION)
" 2>/dev/null | grep -v '^{' | tr -d '\n' || echo "latest")"
  [ -z "$AK_VERSION" ] && AK_VERSION="latest"
  echo "==> Using Authentik LDAP outpost version: ${AK_VERSION}"
  docker rm -f authentik-ldap 2>/dev/null || true
  docker run -d --name authentik-ldap \
    --restart unless-stopped \
    --network "${NETWORK_NAME}" \
    -e AUTHENTIK_HOST="http://authentik-server:9000" \
    -e AUTHENTIK_INSECURE="true" \
    -e AUTHENTIK_TOKEN="${LDAP_OUTPOST_TOKEN}" \
    "ghcr.io/goauthentik/ldap:${AK_VERSION}"
  sleep 5
  docker logs authentik-ldap --tail=3 2>/dev/null || true
else
  echo "WARNING: Could not get LDAP outpost token — skipping container deployment."
fi

# ---------------------------------------------------------------------------
# 8b2. Authentik OIDC provider for mailcow web UI SSO
# ---------------------------------------------------------------------------


MAILCOW_OIDC_CREDS_VALID=0
if [ -n "$MAILCOW_OIDC_CLIENT_ID" ] && [ -n "$MAILCOW_OIDC_CLIENT_SECRET" ]; then
  if [ -n "$AK_TOKEN" ]; then
    DB_MAILCOW_CLIENT_ID="$(curl -sk "http://localhost:9000/api/v3/providers/oauth2/?name=Mailcow" \
      -H "Authorization: Bearer ${AK_TOKEN}" 2>/dev/null \
      | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4 | head -1 || true)"
    if [ "$DB_MAILCOW_CLIENT_ID" = "$MAILCOW_OIDC_CLIENT_ID" ] && [ -n "$DB_MAILCOW_CLIENT_ID" ]; then
      MAILCOW_OIDC_CREDS_VALID=1
      echo "==> Mailcow OIDC credentials already present and verified, skipping."
    else
      echo "==> Saved mailcow OIDC credentials don't match Authentik DB — regenerating."
      MAILCOW_OIDC_CLIENT_ID=""
      MAILCOW_OIDC_CLIENT_SECRET=""
    fi
  fi
fi

if [ "$MAILCOW_OIDC_CREDS_VALID" = "0" ]; then
  MAILCOW_OIDC_SCRIPT="$(mktemp)"
  cat > "$MAILCOW_OIDC_SCRIPT" <<'PYEOF'
from authentik.core.models import Application
from authentik.providers.oauth2.models import (
    OAuth2Provider, ClientTypes, RedirectURI, RedirectURIMatchingMode, ScopeMapping
)
from authentik.crypto.models import CertificateKeyPair
from authentik.flows.models import Flow
import secrets, sys

MAIL_URL = sys.argv[1]
REDIRECT_URI = MAIL_URL  # mailcow uses the bare domain as redirect_uri

auth_flow = Flow.objects.filter(slug="default-provider-authorization-explicit-consent").first()
inv_flow  = Flow.objects.filter(slug="default-provider-invalidation-flow").first()
if not auth_flow:
    raise RuntimeError("Could not find authorization flow")

signing_key = (
    CertificateKeyPair.objects.filter(name="authentik Self-signed Certificate").first()
    or CertificateKeyPair.objects.first()
)

defaults = {
    "client_type":        ClientTypes.CONFIDENTIAL,
    "client_id":          secrets.token_urlsafe(24),
    "client_secret":      secrets.token_urlsafe(48),
    "authorization_flow": auth_flow,
    "signing_key":        signing_key,
}
if inv_flow:
    defaults["invalidation_flow"] = inv_flow

provider, _ = OAuth2Provider.objects.get_or_create(name="Mailcow", defaults=defaults)

# Ensure client_id/secret are populated on existing providers
changed = False
if not provider.client_id:
    provider.client_id = secrets.token_urlsafe(24); changed = True
if not provider.client_secret:
    provider.client_secret = secrets.token_urlsafe(48); changed = True

# Always update redirect URI to current MAIL_URL
provider.redirect_uris = [
    RedirectURI(matching_mode=RedirectURIMatchingMode.STRICT, url=REDIRECT_URI)
]
if auth_flow and provider.authorization_flow_id != auth_flow.pk:
    provider.authorization_flow = auth_flow; changed = True
if signing_key and provider.signing_key_id != signing_key.pk:
    provider.signing_key = signing_key; changed = True
provider.save()

# Assign openid/profile/email scopes
scopes = (
    ScopeMapping.objects.filter(name__icontains="openid") |
    ScopeMapping.objects.filter(name__icontains="profile") |
    ScopeMapping.objects.filter(name__icontains="email")
)
for scope in scopes:
    provider.property_mappings.add(scope)
provider.save()

app, _ = Application.objects.get_or_create(
    slug="mailcow",
    defaults={"name": "Mailcow", "provider": provider},
)
if app.provider_id != provider.pk:
    app.provider = provider; app.save()

with open('/tmp/mailcow_oidc_result.txt', 'w') as f:
    f.write(f"CLIENT_ID={provider.client_id}\n")
    f.write(f"CLIENT_SECRET={provider.client_secret}\n")
PYEOF

  MAILCOW_WRAPPER="$(mktemp)"
  cat > "$MAILCOW_WRAPPER" <<WRAPEOF
import sys
sys.argv = ['', '${MAIL_URL}']
exec(open('/tmp/configure_mailcow_oidc.py').read())
WRAPEOF

  docker cp "$MAILCOW_OIDC_SCRIPT" authentik-server:/tmp/configure_mailcow_oidc.py
  docker cp "$MAILCOW_WRAPPER"      authentik-server:/tmp/run_mailcow_oidc.py
  rm -f "$MAILCOW_OIDC_SCRIPT" "$MAILCOW_WRAPPER"

  docker exec authentik-server \
    ak shell -c "exec(open('/tmp/run_mailcow_oidc.py').read())" >/dev/null 2>&1 || true

  # Read credentials via docker cp (same reliable approach as MAS)
  MC_CREDS_FILE="$(mktemp)"
  docker cp authentik-server:/tmp/mailcow_oidc_result.txt "$MC_CREDS_FILE" 2>/dev/null || true
  MAILCOW_OIDC_CLIENT_ID="$(grep '^CLIENT_ID=' "$MC_CREDS_FILE" | cut -d= -f2- | tr -d '\n' || true)"
  MAILCOW_OIDC_CLIENT_SECRET="$(grep '^CLIENT_SECRET=' "$MC_CREDS_FILE" | cut -d= -f2- | tr -d '\n' || true)"
  rm -f "$MC_CREDS_FILE"

  if [ -z "$MAILCOW_OIDC_CLIENT_ID" ] || [ -z "$MAILCOW_OIDC_CLIENT_SECRET" ]; then
    echo "WARNING: Failed to extract mailcow OIDC credentials from Authentik."
    echo "         You will need to configure mailcow OIDC manually."
  else
    # Persist to ENV_FILE
    grep -v '^MAILCOW_OIDC_CLIENT_ID=' "$ENV_FILE" \
      | grep -v '^MAILCOW_OIDC_CLIENT_SECRET=' > "$ENV_FILE.tmp"
    printf 'MAILCOW_OIDC_CLIENT_ID=%s\nMAILCOW_OIDC_CLIENT_SECRET=%s\n' \
      "$MAILCOW_OIDC_CLIENT_ID" "$MAILCOW_OIDC_CLIENT_SECRET" >> "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
    echo "==> Mailcow OIDC credentials saved."
  fi
fi

# ---------------------------------------------------------------------------
# 8c. Clone / update Mailcow
# ---------------------------------------------------------------------------
if [ ! -d "$MAILCOW_DIR/mailcow-dockerized" ]; then
  echo "==> Cloning Mailcow..."
  git clone https://github.com/mailcow/mailcow-dockerized.git "$MAILCOW_DIR/mailcow-dockerized"
else
  echo "==> Mailcow already cloned, pulling latest..."
  (cd "$MAILCOW_DIR/mailcow-dockerized" && git pull --ff-only) || true
fi

cd "$MAILCOW_DIR/mailcow-dockerized"

# ---------------------------------------------------------------------------
# 8d. Generate mailcow.conf
# ---------------------------------------------------------------------------
if [ ! -f "mailcow.conf" ]; then
  echo "==> Generating Mailcow config..."
  export MAILCOW_HOSTNAME="${MAIL_DOMAIN}"
  export MAILCOW_TZ="Europe/London"
  printf '\n1\n' | ./generate_config.sh

  sed -i 's/^HTTP_PORT=.*/HTTP_PORT=8080/'         mailcow.conf
  sed -i 's/^HTTPS_PORT=.*/HTTPS_PORT=8443/'       mailcow.conf
  sed -i 's/^HTTP_BIND=.*/HTTP_BIND=127.0.0.1/'    mailcow.conf
  sed -i 's/^HTTPS_BIND=.*/HTTPS_BIND=127.0.0.1/'  mailcow.conf
  sed -i 's/^SKIP_LETS_ENCRYPT=.*/SKIP_LETS_ENCRYPT=y/' mailcow.conf
  sed -i 's/^SNAT_TO_SOURCE=.*/SNAT_TO_SOURCE=/'   mailcow.conf
else
  echo "==> mailcow.conf already exists, skipping generation."
fi

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 8g. Start Mailcow
# ---------------------------------------------------------------------------
# Override unbound healthcheck to use DNS lookup instead of ping
# (ping/ICMP is blocked on many networks)
cat > "$MAILCOW_DIR/mailcow-dockerized/docker-compose.override.yml" <<'OVERRIDE'
services:
  unbound-mailcow:
    healthcheck:
      test: ["CMD", "drill", "@127.0.0.1", "cloudflare.com"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
OVERRIDE

echo "Starting Mailcow (~20 images)"
docker compose pull --quiet
docker compose up -d

# Mailcow nginx binds to 127.0.0.1:8443 only — expose it via socat so Caddy can reach it
if ! docker inspect mailcow-proxy >/dev/null 2>&1; then
  echo "==> Starting Mailcow proxy..."
  docker run -d --name mailcow-proxy \
    --restart unless-stopped \
    --network host \
    alpine/socat \
    TCP-LISTEN:8444,fork,reuseaddr \
    TCP:127.0.0.1:8443
fi

# Connect Caddy to mailcow network now that it exists
docker network connect mailcowdockerized_mailcow-network caddy 2>/dev/null || true
docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true

# ---------------------------------------------------------------------------
# 8h. Auto-configure Mailcow API key and start LDAP sync
# ---------------------------------------------------------------------------
echo "Waiting for Mailcow"
for i in $(seq 1 60); do
  HTTP="$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/ 2>/dev/null || echo 0)"
  [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ] || [ "$HTTP" = "301" ] && break || true
  printf "."; sleep 5
done
echo ""

# Generate API key and insert directly into Mailcow's DB
DBPASS="$(grep ^DBPASS "$MAILCOW_DIR/mailcow-dockerized/mailcow.conf" | cut -d= -f2)"
MAILCOW_API_KEY="$(openssl rand -hex 24)"
docker exec mailcowdockerized-mysql-mailcow-1 mysql -u mailcow -p"${DBPASS}" mailcow \
  -e "INSERT INTO api (api_key, allow_from, skip_ip_check, access, active)
      VALUES ('${MAILCOW_API_KEY}', '', 1, 'rw', 1)
      ON DUPLICATE KEY UPDATE api_key='${MAILCOW_API_KEY}', skip_ip_check=1;" 2>/dev/null

# Persist so re-runs don't regenerate a different key
grep -v '^MAILCOW_API_KEY=' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
echo "MAILCOW_API_KEY=${MAILCOW_API_KEY}" >> "$ENV_FILE"

# Verify the key works — {} means no domains yet (that's fine), a non-JSON response means failure
TEST="$(curl -sk "https://127.0.0.1:8443/api/v1/get/domain/all" \
  -H "X-API-Key: ${MAILCOW_API_KEY}" 2>/dev/null)"

if echo "$TEST" | grep -qE '^\{|^\['; then
  echo "==> Mailcow API key verified."

  # Add the mail domain if it isn't already present
  if ! echo "$TEST" | grep -q '"domain_name"'; then
    echo "==> Adding mail domain ${DOMAIN_BASE} to Mailcow..."
    ADD_DOMAIN_RESULT="$(curl -sk -X POST "https://127.0.0.1:8443/api/v1/add/domain" \
      -H "X-API-Key: ${MAILCOW_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"domain\": \"${DOMAIN_BASE}\", \"description\": \"\", \"aliases\": 400, \"mailboxes\": 10, \"defquota\": 3072, \"maxquota\": 10240, \"quota\": 10240, \"active\": \"1\", \"relay_all_recipients\": \"0\"}" \
      2>/dev/null)"
    if echo "$ADD_DOMAIN_RESULT" | grep -qi '"type":"success"'; then
      echo "==> Domain ${DOMAIN_BASE} added to Mailcow."
    else
      echo "WARNING: Could not auto-add domain. Add it manually in the Mailcow admin."
      echo "         Response: ${ADD_DOMAIN_RESULT}"
    fi
  else
    echo "==> Domain already present in Mailcow."
  fi

  # Configure mailcow built-in LDAP
  # Connect authentik-ldap to mailcow network so mailcow PHP can reach it
  docker network connect mailcowdockerized_mailcow-network authentik-ldap 2>/dev/null || true

  MYSQL_PASS=$(grep "DBPASS=" "$MAILCOW_DIR/mailcow-dockerized/mailcow.conf" | cut -d= -f2)
  docker exec mailcowdockerized-mysql-mailcow-1 mysql -u mailcow -p"${MYSQL_PASS}" mailcow -e "
    DELETE FROM identity_provider;
    INSERT INTO identity_provider (\`key\`, \`value\`) VALUES
      ('authsource',        'LDAP'),
      ('host',              'authentik-ldap'),
      ('port',              '3389'),
      ('basedn',            '${LDAP_BASE_DN}'),
      ('username_field',    'mail'),
      ('filter',            '(memberOf=cn=mailcow-users,${LDAP_BASE_DN})'),
      ('attribute_field',   ''),
      ('binddn',            'cn=akadmin,${LDAP_BASE_DN}'),
      ('bindpass',          '${AUTHENTIK_BOOTSTRAP_PASSWORD}'),
      ('periodic_sync',     '1'),
      ('import_users',      '1'),
      ('sync_interval',     '15'),
      ('use_ssl',           '0'),
      ('use_tls',           '0'),
      ('ignore_ssl_error',  '0'),
      ('login_provisioning','0'),
      ('access_token',      '');
  " 2>/dev/null && echo "Mailcow LDAP configured." || \
    echo "WARNING: Mailcow LDAP DB insert failed — configure manually via ${MAIL_URL}/admin"
else
  echo "WARNING: Mailcow API key verification failed (unexpected response)."
  echo "         Response: ${TEST}"
  echo "         The API key is in: ${ENV_FILE}"
  echo "         Complete LDAP/OIDC setup manually — see summary at end of script."
fi

cd "$HOME"
echo ""




# =============================================================================
# Done
# =============================================================================
echo ""
echo "Done. VM: ${VM_IP}
"
echo ""
echo "URLs:"
echo "  ${AUTH_URL}"
echo "  ${ELEMENT_URL}"
echo "  ${MATRIX_URL}"
echo "  ${MAS_URL}"
echo "  ${MAIL_URL}"
echo "  https://${LIVEKIT_DOMAIN}"
echo ""
echo "Authentik: akadmin / ${AUTHENTIK_BOOTSTRAP_PASSWORD}"
echo "Mailcow:   ${MAIL_URL}/admin  (admin / moohoo)"
echo "           Users log in with LDAP credentials from Authentik."
echo ""
echo "CA cert: ~/caddy-ca.crt — install on each device to trust HTTPS"
echo "DNS:     set to ${VM_IP} on each device, or add to hosts file:"
for svc in auth matrix mas element livekit mail; do
  echo "           ${VM_IP}  ${svc}.${DOMAIN_BASE}"
done
echo ""
echo "Logs:"
echo "  docker logs caddy --tail=20"
echo "  docker logs mas --tail=40"
echo "  docker logs authentik-server --tail=20"
echo "  docker logs mailcowdockerized-postfix-mailcow-1 --tail=20"

rm -f "$ENV_FILE"
