#!/usr/bin/env bash
# =============================================================================
# israel.sh — Create the 12 Tribes of Israel + clans in Authentik
#             and Matrix rooms per tribe
# Run on the VM after homelab.sh has completed.
# Usage: ./israel.sh [domain]
# =============================================================================
set -euo pipefail

# Get domain from argument, homelab.env, or default
DOMAIN=""
if [ -n "${1:-}" ]; then
  DOMAIN="$1"
elif [ -f "$HOME/homelab.env" ]; then
  DOMAIN=$(grep "^DOMAIN_BASE=" "$HOME/homelab.env" | cut -d= -f2 || true)
fi
DOMAIN="${DOMAIN:-home.arpa}"

echo "Using domain: ${DOMAIN}"
echo "Creating Jacob, the 12 Tribes, and their clans in Authentik..."

docker exec authentik-server ak shell -c "
from authentik.core.models import User, Group
from django.db import transaction

DOMAIN = '${DOMAIN}'

# Tribe name -> list of (username, display_name) clan members
TRIBES = {
    'Reuben':   [('hanoch','Hanoch'), ('pallu','Pallu'), ('hezron_r','Hezron'), ('carmi','Carmi')],
    'Simeon':   [('jemuel','Jemuel'), ('jamin','Jamin'), ('ohad','Ohad'), ('jakin','Jakin'), ('zohar','Zohar'), ('shaul','Shaul')],
    'Levi':     [('gershon','Gershon'), ('kohath','Kohath'), ('merari','Merari')],
    'Judah':    [('er','Er'), ('onan','Onan'), ('shelah','Shelah'), ('perez','Perez'), ('zerah','Zerah')],
    'Dan':      [('hushim','Hushim')],
    'Naphtali': [('jahzeel','Jahzeel'), ('guni','Guni'), ('jezer','Jezer'), ('shillem','Shillem')],
    'Gad':      [('zephon','Zephon'), ('haggi','Haggi'), ('shuni','Shuni'), ('ezbon','Ezbon'), ('eri','Eri'), ('arodi','Arodi'), ('areli','Areli')],
    'Asher':    [('imnah','Imnah'), ('ishvi','Ishvi'), ('beriah','Beriah'), ('serah','Serah')],
    'Issachar': [('tola','Tola'), ('puah','Puah'), ('jashub','Jashub'), ('shimron','Shimron')],
    'Zebulun':  [('sered','Sered'), ('elon','Elon'), ('jahleel','Jahleel')],
    'Joseph':   [('manasseh','Manasseh'), ('ephraim','Ephraim')],
    'Benjamin': [('bela','Bela'), ('beker','Beker'), ('ashbel','Ashbel'), ('gera','Gera'), ('naaman','Naaman'), ('ehi','Ehi'), ('rosh','Rosh'), ('muppim','Muppim'), ('huppim','Huppim'), ('ard','Ard')],
}

SONS = [
    ('reuben','Reuben'), ('simeon','Simeon'), ('levi','Levi'), ('judah','Judah'),
    ('dan','Dan'), ('naphtali','Naphtali'), ('gad','Gad'), ('asher','Asher'),
    ('issachar','Issachar'), ('zebulun','Zebulun'), ('joseph','Joseph'), ('benjamin','Benjamin'),
]

with transaction.atomic():
    # Israel parent group
    israel_group, _ = Group.objects.get_or_create(name='Israel')
    print('Group: Israel')

    # Jacob superadmin
    jacob, created = User.objects.get_or_create(
        username='jacob',
        defaults={'name': 'Jacob (Israel)', 'email': f'jacob@{DOMAIN}', 'is_active': True}
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

    # Sons + their clans
    for username, name in SONS:
        # Tribe group under Israel
        tribe_group, _ = Group.objects.get_or_create(
            name=f'Tribe of {name}',
            defaults={'parent': israel_group}
        )
        if tribe_group.parent != israel_group:
            tribe_group.parent = israel_group
            tribe_group.save()

        # Son user
        user, created = User.objects.get_or_create(
            username=username,
            defaults={'name': name, 'email': f'{username}@{DOMAIN}', 'is_active': True}
        )
        if created:
            user.set_password('ChangeMeNow!')
            user.save()
            print(f'Created: {username}@{DOMAIN}')
        tribe_group.users.add(user)
        israel_group.users.add(user)

        # Clan members
        for clan_username, clan_name in TRIBES.get(name, []):
            clan_user, created = User.objects.get_or_create(
                username=clan_username,
                defaults={'name': clan_name, 'email': f'{clan_username}@{DOMAIN}', 'is_active': True}
            )
            if created:
                clan_user.set_password('ChangeMeNow!')
                clan_user.save()
                print(f'  Created: {clan_username}@{DOMAIN} (clan of {name})')
            tribe_group.users.add(clan_user)
            israel_group.users.add(clan_user)

print('Authentik setup complete.')
" 2>/dev/null | grep -v '^{'

echo ""
echo "Creating Matrix rooms..."

# Get Jacob's Matrix access token
JACOB_TOKEN=""
JACOB_TOKEN=$(curl -sk -X POST "https://matrix.${DOMAIN}/_matrix/client/v3/login" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "m.login.password",
    "identifier": {"type": "m.id.user", "user": "jacob"},
    "password": "ChangeMeNow!"
  }' 2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)

if [ -z "$JACOB_TOKEN" ]; then
  echo "WARNING: Could not get Jacob's Matrix token — skipping room creation."
  echo "         Log in to Element as jacob first, then rerun this script."
else
  TRIBES="Reuben Simeon Levi Judah Dan Naphtali Gad Asher Issachar Zebulun Joseph Benjamin"
  for TRIBE in $TRIBES; do
    ALIAS="tribe-of-$(echo "$TRIBE" | tr '[:upper:]' '[:lower:]')"
    RESULT=$(curl -sk -X POST "https://matrix.${DOMAIN}/_matrix/client/v3/createRoom" \
      -H "Authorization: Bearer ${JACOB_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"room_alias_name\": \"${ALIAS}\",
        \"name\": \"Tribe of ${TRIBE}\",
        \"topic\": \"The tribe of ${TRIBE}\",
        \"preset\": \"private_chat\",
        \"visibility\": \"private\"
      }" 2>/dev/null)
    ROOM_ID=$(echo "$RESULT" | grep -o '"room_id":"[^"]*"' | cut -d'"' -f4 || true)
    if [ -n "$ROOM_ID" ]; then
      echo "  Created room: #${ALIAS}:matrix.${DOMAIN} (${ROOM_ID})"
    else
      echo "  Note: #${ALIAS} may already exist or creation failed"
    fi
  done

  # Israel room
  RESULT=$(curl -sk -X POST "https://matrix.${DOMAIN}/_matrix/client/v3/createRoom" \
    -H "Authorization: Bearer ${JACOB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"room_alias_name\": \"israel\",
      \"name\": \"Israel\",
      \"topic\": \"All the tribes of Israel\",
      \"preset\": \"private_chat\",
      \"visibility\": \"private\"
    }" 2>/dev/null)
  ROOM_ID=$(echo "$RESULT" | grep -o '"room_id":"[^"]*"' | cut -d'"' -f4 || true)
  [ -n "$ROOM_ID" ] && echo "  Created room: #israel:matrix.${DOMAIN}" || echo "  Note: #israel may already exist"

  echo ""
  echo "Matrix rooms created. Invite members via Element or rerun after users log in."
fi

echo ""
echo "Done."
echo "  Superadmin : jacob@${DOMAIN}  (password: ChangeMeNow!)"
echo "  Tribes     : 12 sons + clans, all in Israel > Tribe of X"
echo "  Rooms      : one per tribe + #israel"
echo ""
echo "Change passwords at: https://auth.${DOMAIN}"
