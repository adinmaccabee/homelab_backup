#!/usr/bin/env bash
# =============================================================================
# israel.sh — Create the 12 Tribes of Israel + clans in Authentik,
#             pre-create Matrix accounts, create rooms, and invite everyone.
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
# 1. Create users and groups in Authentik
# =============================================================================
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
        defaults={'name':'Jacob (Israel)','email':f'jacob@{DOMAIN}','is_active':True}
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
        print('Jacob granted admin role')
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

        for clan_username, clan_name in TRIBES.get(name, []):
            clan_user, created = User.objects.get_or_create(
                username=clan_username,
                defaults={'name':clan_name,'email':f'{clan_username}@{DOMAIN}','is_active':True}
            )
            if created:
                clan_user.set_password('ChangeMeNow!')
                clan_user.save()
                print(f'  Created: {clan_username}@{DOMAIN}')
            tribe_group.users.add(clan_user)
            israel_group.users.add(clan_user)

print('Authentik done.')
" 2>/dev/null | grep -v '^{'

# =============================================================================
# 2. Get Jacob's Matrix admin token
# =============================================================================
echo ""
echo "Getting Jacob's Matrix token..."

# Force Jacob's Matrix account creation via MAS
docker exec mas mas-cli manage provision-user jacob 2>/dev/null || true
sleep 2

JACOB_TOKEN=$(docker exec mas mas-cli manage issue-compatibility-token \
  --yes-i-want-to-grant-synapse-admin-privileges jacob 2>&1 | \
  grep -o 'mct_[A-Za-z0-9_-]*' | head -1 || true)

if [ -z "$JACOB_TOKEN" ]; then
  echo "ERROR: Could not get Jacob's Matrix token. Aborting Matrix setup."
  exit 1
fi
echo "  Token obtained."

# =============================================================================
# Helper functions
# =============================================================================
matrix_post() {
  local path="$1" data="$2"
  local result retries=5
  for i in $(seq 1 $retries); do
    result=$(curl -sk -X POST "https://matrix.${DOMAIN}${path}" \
      -H "Authorization: Bearer ${JACOB_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$data" 2>/dev/null)
    if echo "$result" | grep -q 'M_LIMIT_EXCEEDED'; then
      local wait_ms
      wait_ms=$(echo "$result" | grep -o '"retry_after_ms":[0-9]*' | cut -d: -f2 || echo 3000)
      sleep $(( (wait_ms / 1000) + 2 ))
    else
      echo "$result"
      return 0
    fi
  done
  echo "$result"
}

get_room_id() {
  local alias="$1"
  curl -sk "https://matrix.${DOMAIN}/_matrix/client/v3/directory/room/%23${alias}:${DOMAIN}" \
    -H "Authorization: Bearer ${JACOB_TOKEN}" 2>/dev/null | \
    grep -o '"room_id":"[^"]*"' | cut -d'"' -f4 || true
}

create_room() {
  local alias="$1" name="$2"
  local existing
  existing=$(get_room_id "$alias")
  if [ -n "$existing" ]; then
    echo "  Exists: #${alias} (${existing})" >&2
    echo "$existing"
    return 0
  fi
  local result
  result=$(matrix_post "/_matrix/client/v3/createRoom" \
    "{\"room_alias_name\":\"${alias}\",\"name\":\"${name}\",\"preset\":\"private_chat\"}")
  local room_id
  room_id=$(echo "$result" | grep -o '"room_id":"[^"]*"' | cut -d'"' -f4 || true)
  if [ -n "$room_id" ]; then
    echo "  Created: #${alias} (${room_id})" >&2
    echo "$room_id"
  else
    echo "  Failed: ${alias} — $(echo "$result" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)" >&2
    echo ""
  fi
}

invite_user() {
  local room_id="$1" username="$2"
  [ -z "$room_id" ] && return 0
  local result
  result=$(matrix_post "/_matrix/client/v3/rooms/${room_id}/invite" \
    "{\"user_id\":\"@${username}:${DOMAIN}\"}")
  if echo "$result" | grep -qE '"errcode"|"error"'; then
    local err
    err=$(echo "$result" | grep -o '"errcode":"[^"]*"' | cut -d'"' -f4)
    # M_FORBIDDEN = already in room, ignore
    [ "$err" = "M_FORBIDDEN" ] || echo "    Note: ${username} — ${err}"
  fi
}

pre_create_account() {
  local username="$1"
  docker exec mas mas-cli manage provision-user "$username" 2>/dev/null || true
  sleep 1
}

# =============================================================================
# 3. Pre-create all Matrix accounts
# =============================================================================
echo ""
echo "Pre-creating Matrix accounts..."

ALL_USERS="reuben simeon levi judah dan naphtali gad asher issachar zebulun joseph benjamin
hanoch pallu hezron_r carmi
jemuel jamin ohad jakin zohar shaul
gershon kohath merari
er onan shelah perez zerah
hushim
jahzeel guni jezer shillem
zephon haggi shuni ezbon eri arodi areli
imnah ishvi beriah serah
tola puah jashub shimron
sered elon jahleel
manasseh ephraim
bela beker ashbel gera naaman ehi rosh muppim huppim ard"

for USER in $ALL_USERS; do
  pre_create_account "$USER"
  printf "  %s\n" "$USER"
done

# =============================================================================
# 4. Create rooms and invite members
# =============================================================================
echo ""
echo "Creating rooms and inviting members..."

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

ISRAEL_ROOM_ID=""
ISRAEL_ROOM_ID=$(create_room "israel" "Israel")

for TRIBE in Reuben Simeon Levi Judah Dan Naphtali Gad Asher Issachar Zebulun Joseph Benjamin; do
  ALIAS="tribe-of-$(echo "$TRIBE" | tr '[:upper:]' '[:lower:]')"
  SON="$(echo "$TRIBE" | tr '[:upper:]' '[:lower:]')"
  ROOM_ID=$(create_room "$ALIAS" "Tribe of ${TRIBE}")

  if [ -n "$ROOM_ID" ]; then
    # Invite the son
    invite_user "$ROOM_ID" "$SON"
    # Give son admin power level in their tribe room
    matrix_post "/_matrix/client/v3/rooms/${ROOM_ID}/state/m.room.power_levels" \
      "{\"users\":{\"@jacob:${DOMAIN}\":100,\"@${SON}:${DOMAIN}\":100}}" >/dev/null
    # Invite clan members
    for CLAN_MEMBER in ${TRIBE_CLANS[$TRIBE]}; do
      invite_user "$ROOM_ID" "$CLAN_MEMBER"
    done
    # Invite everyone to Israel room
    invite_user "$ISRAEL_ROOM_ID" "$SON"
    for CLAN_MEMBER in ${TRIBE_CLANS[$TRIBE]}; do
      invite_user "$ISRAEL_ROOM_ID" "$CLAN_MEMBER"
    done
  fi
done

echo ""
echo "Done."
echo "  Superadmin : jacob@${DOMAIN}  (password: ChangeMeNow!)"
echo "  Sons       : 12 tribes + clans, grouped under Israel > Tribe of X"
echo "  Rooms      : #tribe-of-X and #israel — all members invited"
echo ""
echo "Change passwords at: https://auth.${DOMAIN}"
