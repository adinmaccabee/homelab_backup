#!/usr/bin/env bash
# =============================================================================
# israel.sh — Create the 12 Tribes of Israel + clans in Authentik
#             and Matrix rooms per tribe.
#
# Run ONCE after homelab.sh to set up Authentik users/groups.
# Run AGAIN after users have logged in to Element to populate rooms.
#
# Usage: ./israel.sh [domain]
# =============================================================================
set -euo pipefail

DOMAIN=""
if [ -n "${1:-}" ]; then
  DOMAIN="$1"
elif [ -f "$HOME/homelab.env" ]; then
  DOMAIN=$(grep "^DOMAIN_BASE=" "$HOME/homelab.env" | cut -d= -f2 || true)
fi
DOMAIN="${DOMAIN:-home.arpa}"
echo "Using domain: ${DOMAIN}"

# =============================================================================
# 1. Authentik users and groups
# =============================================================================
echo ""
echo "Setting up Authentik users and groups..."

docker exec authentik-server ak shell -c "
from authentik.core.models import User, Group
from django.db import transaction

DOMAIN = '${DOMAIN}'

TRIBES = {
    'Reuben':   [('hanoch','Hanoch'),('pallu','Pallu'),('hezron_r','Hezron'),('carmi','Carmi')],
    'Simeon':   [('jemuel','Jemuel'),('jamin','Jamin'),('ohad','Ohad'),('jakin','Jakin'),('zohar','Zohar'),('shaul','Shaul')],
    'Levi':     [('gershon','Gershon'),('kohath','Kohath'),('merari','Merari')],
    'Judah':    [('er','Er'),('onan','Onan'),('shelah','Shelah'),('perez','Perez'),('zerah','Zerah')],
    'Dan':      [('hushim','Hushim')],
    'Naphtali': [('jahzeel','Jahzeel'),('guni','Guni'),('jezer','Jezer'),('shillem','Shillem')],
    'Gad':      [('zephon','Zephon'),('haggi','Haggi'),('shuni','Shuni'),('ezbon','Ezbon'),('eri','Eri'),('arodi','Arodi'),('areli','Areli')],
    'Asher':    [('imnah','Imnah'),('ishvi','Ishvi'),('beriah','Beriah'),('serah','Serah')],
    'Issachar': [('tola','Tola'),('puah','Puah'),('jashub','Jashub'),('shimron','Shimron')],
    'Zebulun':  [('sered','Sered'),('elon','Elon'),('jahleel','Jahleel')],
    'Joseph':   [('manasseh','Manasseh'),('ephraim','Ephraim')],
    'Benjamin': [('bela','Bela'),('beker','Beker'),('ashbel','Ashbel'),('gera','Gera'),('naaman','Naaman'),('ehi','Ehi'),('rosh','Rosh'),('muppim','Muppim'),('huppim','Huppim'),('ard','Ard')],
}
SONS = [
    ('reuben','Reuben'),('simeon','Simeon'),('levi','Levi'),('judah','Judah'),
    ('dan','Dan'),('naphtali','Naphtali'),('gad','Gad'),('asher','Asher'),
    ('issachar','Issachar'),('zebulun','Zebulun'),('joseph','Joseph'),('benjamin','Benjamin'),
]

with transaction.atomic():
    israel_group, _ = Group.objects.get_or_create(name='Israel')
    jacob, created = User.objects.get_or_create(
        username='jacob',
        defaults={'name':'Jacob','email':f'jacob@{DOMAIN}','is_active':True}
    )
    if created:
        jacob.set_password('ChangeMeNow!')
        jacob.save()
        print(f'Created: jacob@{DOMAIN}')
    israel_group.users.add(jacob)
    try:
        from authentik.rbac.models import Role
        admin_role = Role.objects.get(name='authentik Admins')
        admin_role.users.add(jacob)
    except Exception as e:
        print(f'Note: {e}')

    for username, name in SONS:
        tribe_group, _ = Group.objects.get_or_create(
            name=f'Tribe of {name}', defaults={'parent': israel_group}
        )
        if tribe_group.parent != israel_group:
            tribe_group.parent = israel_group
            tribe_group.save()
        user, created = User.objects.get_or_create(
            username=username,
            defaults={'name':name,'email':f'{username}@{DOMAIN}','is_active':True}
        )
        if created:
            user.set_password('ChangeMeNow!')
            user.save()
            print(f'Created: {username}@{DOMAIN}')
        tribe_group.users.add(user)
        israel_group.users.add(user)
        for cu, cn in TRIBES.get(name, []):
            clan_user, created = User.objects.get_or_create(
                username=cu,
                defaults={'name':cn,'email':f'{cu}@{DOMAIN}','is_active':True}
            )
            if created:
                clan_user.set_password('ChangeMeNow!')
                clan_user.save()
                print(f'  Created: {cu}@{DOMAIN}')
            tribe_group.users.add(clan_user)
            israel_group.users.add(clan_user)
print('Authentik done.')
" 2>/dev/null | grep -v '^{' || true

# =============================================================================
# 2. Matrix rooms and members
# =============================================================================
echo ""
echo "Getting Matrix admin token..."

ADMIN_TOKEN=$(docker exec synapse cat /data/homeserver.yaml 2>/dev/null | \
  grep 'admin_token' | head -1 | awk '{print $2}' | tr -d '"' || true)

if [ -z "$ADMIN_TOKEN" ]; then
  echo "ERROR: Could not get Synapse admin token."
  exit 1
fi
echo "  Token obtained."

# =============================================================================
# Helpers
# =============================================================================
matrix_api() {
  local method="$1" path="$2" data="${3:-}"
  local result retries=5
  for i in $(seq 1 $retries); do
    if [ -n "$data" ]; then
      result=$(curl -sk -X "$method" "https://matrix.${DOMAIN}${path}" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$data" 2>/dev/null)
    else
      result=$(curl -sk -X "$method" "https://matrix.${DOMAIN}${path}" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null)
    fi
    if echo "$result" | grep -q 'M_LIMIT_EXCEEDED'; then
      local ms
      ms=$(echo "$result" | grep -o '"retry_after_ms":[0-9]*' | cut -d: -f2 || echo 3000)
      sleep $(( (ms / 1000) + 2 ))
    else
      echo "$result"; return 0
    fi
  done
  echo "$result"
}

get_room_id() {
  local alias="$1"
  # Try Synapse admin API first
  local result
  result=$(matrix_api GET "/_synapse/admin/v1/room_aliases?limit=1&from=0&search_term=${alias}")
  echo "$result" | grep -o '"room_id":"[^"]*"' | head -1 | cut -d'"' -f4 || true
}

create_room() {
  local alias="$1" name="$2"
  # Try to get existing room ID via Synapse admin API
  local existing
  existing=$(curl -sk \
    "https://matrix.${DOMAIN}/_synapse/admin/v1/rooms?search_term=${alias}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null | \
    grep -o '"room_id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  if [ -n "$existing" ]; then
    echo "  Exists: #${alias}" >&2
    echo "$existing"
    return 0
  fi
  local result room_id
  result=$(matrix_api POST "/_matrix/client/v3/createRoom" \
    "{\"room_alias_name\":\"${alias}\",\"name\":\"${name}\",\"preset\":\"private_chat\"}")
  room_id=$(echo "$result" | grep -o '"room_id":"[^"]*"' | cut -d'"' -f4 || true)
  if [ -n "$room_id" ]; then
    echo "  Created: #${alias}" >&2
    echo "$room_id"
    sleep 3
  else
    echo "  Failed: ${alias} — $(echo "$result" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)" >&2
    echo ""
  fi
}

force_join() {
  local room_id="$1" username="$2"
  [ -z "$room_id" ] && return 0
  local result err
  result=$(matrix_api POST "/_synapse/admin/v1/join/${room_id}" \
    "{\"user_id\":\"@${username}:${DOMAIN}\"}")
  if echo "$result" | grep -q '"errcode"'; then
    err=$(echo "$result" | grep -o '"errcode":"[^"]*"' | cut -d'"' -f4)
    [ "$err" != "M_UNKNOWN" ] && [ "$err" != "M_FORBIDDEN" ] && echo "    Note: ${username} — ${err}" >&2
  fi
}

set_power_level() {
  local room_id="$1" son="$2"
  [ -z "$room_id" ] && return 0
  matrix_api PUT "/_matrix/client/v3/rooms/${room_id}/state/m.room.power_levels" \
    "{\"users\":{\"@jacob:${DOMAIN}\":100,\"@${son}:${DOMAIN}\":100}}" >/dev/null 2>/dev/null || true
}

# =============================================================================
# 3. Pre-create all Matrix accounts via MAS register-user
#    account_linking_policy: allow in mas-config means Authentik login will
#    link to these accounts instead of failing.
# =============================================================================
echo ""
echo "Pre-creating Matrix accounts..."

ALL_USERS="jacob reuben simeon levi judah dan naphtali gad asher issachar zebulun joseph benjamin
hanoch pallu hezron_r carmi jemuel jamin ohad jakin zohar shaul
gershon kohath merari er onan shelah perez zerah hushim
jahzeel guni jezer shillem zephon haggi shuni ezbon eri arodi areli
imnah ishvi beriah serah tola puah jashub shimron
sered elon jahleel manasseh ephraim
bela beker ashbel gera naaman ehi rosh muppim huppim ard"

for USER in $ALL_USERS; do
  docker exec mas mas-cli manage register-user --yes "$USER" 2>/dev/null || true
  printf "  %s\n" "$USER"
done

# Issue compatibility tokens for all users to register them in Synapse
echo ""
echo "Registering all users in Synapse..."
for USER in $ALL_USERS; do
  docker exec mas mas-cli manage issue-compatibility-token "$USER" \
    2>/dev/null | grep -o 'mct_[A-Za-z0-9_-]*' >/dev/null || true
done
echo "Waiting for Synapse to process..."
sleep 15

# =============================================================================
# 4. Create rooms and add members
# =============================================================================
echo ""
echo "Creating rooms and adding members..."

declare -A TRIBE_CLANS
TRIBE_CLANS[Reuben]="hanoch pallu hezron_r carmi"
TRIBE_CLANS[Simeon]="jemuel jamin ohad jakin zohar shaul"
TRIBE_CLANS[Levi]="gershon kohath merari"
TRIBE_CLANS[Judah]="er onan shelah perez zerah"
TRIBE_CLANS[Dan]="hushim"
TRIBE_CLANS[Naphtali]="jahzeel guni jezer shillem"
TRIBE_CLANS[Gad]="zephon haggi shuni ezbon eri arodi areli"
TRIBE_CLANS[Asher]="imnah ishvi beriah serah"
TRIBE_CLANS[Issachar]="tola puah jashub shimron"
TRIBE_CLANS[Zebulun]="sered elon jahleel"
TRIBE_CLANS[Joseph]="manasseh ephraim"
TRIBE_CLANS[Benjamin]="bela beker ashbel gera naaman ehi rosh muppim huppim ard"

ISRAEL_ROOM_ID=$(create_room "israel" "Israel")
# Always join jacob to Israel room
force_join "$ISRAEL_ROOM_ID" "jacob" || true

for TRIBE in Reuben Simeon Levi Judah Dan Naphtali Gad Asher Issachar Zebulun Joseph Benjamin; do
  ALIAS="tribe-of-$(echo "$TRIBE" | tr '[:upper:]' '[:lower:]')"
  SON="$(echo "$TRIBE" | tr '[:upper:]' '[:lower:]')"
  ROOM_ID=$(create_room "$ALIAS" "Tribe of ${TRIBE}")

  if [ -n "$ROOM_ID" ]; then
    force_join "$ROOM_ID" "jacob" || true
    force_join "$ROOM_ID" "$SON" || true
    set_power_level "$ROOM_ID" "$SON" || true
    for CLAN_MEMBER in ${TRIBE_CLANS[$TRIBE]}; do
      force_join "$ROOM_ID" "$CLAN_MEMBER" || true
    done
    force_join "$ISRAEL_ROOM_ID" "$SON" || true
    for CLAN_MEMBER in ${TRIBE_CLANS[$TRIBE]}; do
      force_join "$ISRAEL_ROOM_ID" "$CLAN_MEMBER" || true
    done
    sleep 2
  fi
done

echo ""
echo "Done."
echo "  Superadmin : jacob@${DOMAIN}  (password: ChangeMeNow!)"
echo "  Sons       : 12 tribes + clans, grouped under Israel > Tribe of X"
echo "  Rooms      : #tribe-of-X and #israel created"
echo "               Members will be joined automatically when they first log in,"
echo "               or rerun this script after users have logged in to Element."
echo ""
echo "Change passwords at: https://auth.${DOMAIN}"
