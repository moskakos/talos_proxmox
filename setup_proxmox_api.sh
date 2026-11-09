#!/usr/bin/env bash
set -euo pipefail
umask 077

# Proxmox connection variables match the Ansible inventory; token lifetime is configured in days (1-36500).
# Run this script on a Proxmox VE 8 or 9 node as root.
# Modify the variables below as needed for your environment or run:
# PROXMOX_API_USER="user@pve" PROXMOX_API_TOKEN_ID="token" PROXMOX_API_TOKEN_EXPIRE_DAYS=10 PROXMOX_STORAGE="local" PROXMOX_VM_STORAGE="local-lvm" PROXMOX_NODE="proxmox" K8S_VMBR="vmbr0" ./setup_proxmox_api.sh
PROXMOX_API_USER="${PROXMOX_API_USER:-ansible@pve}"
PROXMOX_API_TOKEN_ID="${PROXMOX_API_TOKEN_ID:-provisioning}"
PROXMOX_API_TOKEN_EXPIRE_DAYS="${PROXMOX_API_TOKEN_EXPIRE_DAYS:-}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-local}"
PROXMOX_VM_STORAGE="${PROXMOX_VM_STORAGE:-local-lvm}"
PROXMOX_NODE="${PROXMOX_NODE:-proxmox}"
K8S_VMBR="${K8S_VMBR:-vmbr0}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $(id -u) -eq 0 ]] || fail "Run this script as root on a Proxmox node."
for dependency in pveum pvesh python3; do
    command -v "$dependency" >/dev/null || fail "Required command not found: $dependency"
done
python3 -c '
import re, sys
value = sys.argv[1]
sys.exit(0 if re.fullmatch(r"[0-9]{1,5}", value) and 1 <= int(value) <= 36500 else 1)
' "$PROXMOX_API_TOKEN_EXPIRE_DAYS" ||
    fail "Set PROXMOX_API_TOKEN_EXPIRE_DAYS to a whole number from 1 to 36500."
[[ $PROXMOX_API_USER =~ ^[^[:space:]@\!/:]+@pve$ ]] ||
    fail "Set PROXMOX_API_USER to a complete username in the local pve realm (user@pve)."
[[ $PROXMOX_API_TOKEN_ID =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] ||
    fail "Set PROXMOX_API_TOKEN_ID to the token name only, without user@realm!."
for resource in "$PROXMOX_STORAGE" "$PROXMOX_VM_STORAGE" "$PROXMOX_NODE" "$K8S_VMBR"; do
    [[ $resource =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Invalid resource name: $resource"
done

has_entry() {
    python3 -c '
import json, sys
entries = json.load(sys.stdin)
sys.exit(0 if any(entry.get(sys.argv[1]) == sys.argv[2] for entry in entries) else 1)
' "$1" "$2"
}

pvesh get "/nodes/$PROXMOX_NODE/status" --output-format json >/dev/null
pvesh get "/nodes/$PROXMOX_NODE/storage/$PROXMOX_STORAGE/status" --output-format json >/dev/null
pvesh get "/nodes/$PROXMOX_NODE/storage/$PROXMOX_VM_STORAGE/status" --output-format json >/dev/null

version_info=$(pvesh get /version --output-format json)
pve_major=$(python3 -c '
import json, sys
print(json.load(sys.stdin)["version"].split(".")[0])
' <<< "$version_info")
case "$pve_major" in
    8) guest_agent_privilege="VM.Monitor" ;;
    9) guest_agent_privilege="VM.GuestAgent.Audit" ;;
    *) fail "Unsupported Proxmox VE major version: $pve_major (expected 8 or 9)." ;;
esac
printf 'Detected Proxmox VE %s; guest-agent privilege: %s\n' "$pve_major" "$guest_agent_privilege"

roles=$(pveum role list --output-format json)
if python3 -c '
import json, re, sys
def privileges(value):
    return set(re.split(r"[\s,]+", value)) if isinstance(value, str) else set(value)
sys.exit(0 if any("Sys.AccessNetwork" in privileges(role.get("privs", []))
                  for role in json.load(sys.stdin)) else 1)
' <<< "$roles"; then
    network_privileges="Sys.AccessNetwork"
else
    [[ $pve_major == 8 ]] ||
        fail "Sys.AccessNetwork is missing on PVE 9; check installed packages before retrying."
    printf '%s\n' \
        'Sys.AccessNetwork was not found in the available roles.' \
        'The legacy PVE 8 download-url endpoint requires Sys.Audit and Sys.Modify on /.' \
        'This grants broad system configuration permissions to the user and token.'
    read -r -p 'Type yes to grant these legacy permissions: ' confirmation ||
        fail "Legacy permissions were not approved; no changes made."
    [[ $confirmation == yes ]] || fail "Legacy permissions were not approved; no changes made."
    network_privileges=""
fi

provision_privileges="VM.Allocate VM.Audit VM.Config.CDROM VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options $guest_agent_privilege VM.PowerMgmt Datastore.Audit Datastore.AllocateTemplate Datastore.AllocateSpace Sys.Audit SDN.Use"
if [[ -n $network_privileges ]]; then
    provision_privileges+=" $network_privileges"
fi
role_definitions=("TalosInstaller|$provision_privileges")
grants=(
    "TalosInstaller|/vms"
    "TalosInstaller|/storage/$PROXMOX_STORAGE"
    "TalosInstaller|/nodes/$PROXMOX_NODE"
    "TalosInstaller|/sdn/zones/localnetwork/$K8S_VMBR"
)
if [[ $PROXMOX_VM_STORAGE != "$PROXMOX_STORAGE" ]]; then
    grants+=("TalosInstaller|/storage/$PROXMOX_VM_STORAGE")
fi
if [[ -z $network_privileges ]]; then
    role_definitions+=("TalosInstallerDownload|Sys.Audit Sys.Modify")
    grants+=("TalosInstallerDownload|/")
fi

role_to_update=""
for definition in "${role_definitions[@]}"; do
    IFS='|' read -r role privileges <<< "$definition"
    if has_entry roleid "$role" <<< "$roles"; then
        if python3 -c '
import json, re, sys
role = next(entry for entry in json.load(sys.stdin) if entry["roleid"] == sys.argv[1])
actual = role.get("privs", [])
actual = set(re.split(r"[\s,]+", actual)) if isinstance(actual, str) else set(actual)
sys.exit(0 if actual == set(sys.argv[2].split()) else 1)
' "$role" "$privileges" <<< "$roles"; then
            continue
        fi
        if [[ $pve_major == 9 && $role == TalosInstaller ]] && python3 -c '
import json, re, sys
role = next(entry for entry in json.load(sys.stdin) if entry["roleid"] == sys.argv[1])
actual = role.get("privs", [])
actual = set(re.split(r"[\s,]+", actual)) if isinstance(actual, str) else set(actual)
expected = set(sys.argv[2].split()) - {"VM.GuestAgent.Audit"}
sys.exit(0 if actual in (expected, expected | {"VM.Monitor"}) else 1)
' "$role" "$privileges" <<< "$roles"; then
            printf '%s\n' \
                "Existing $role needs the PVE 9 guest-agent privilege migration." \
                'This replaces VM.Monitor (if still present) with VM.GuestAgent.Audit.' \
                'The change affects EVERY user and token assigned this shared role.'
            read -r -p "Type yes to migrate $role: " confirmation ||
                fail "Role migration was not approved; no changes made."
            [[ $confirmation == yes ]] || fail "Role migration was not approved; no changes made."
            role_to_update="$role"
        else
            fail "Existing role $role has different privileges; refusing to modify a shared role. Review it with: pveum role list"
        fi
    fi
done

users=$(pveum user list --output-format json)
if has_entry userid "$PROXMOX_API_USER" <<< "$users"; then
    printf 'Reusing existing user: %s\n' "$PROXMOX_API_USER"
else
    pveum user add "$PROXMOX_API_USER" --enable 1
fi

for definition in "${role_definitions[@]}"; do
    IFS='|' read -r role privileges <<< "$definition"
    if ! has_entry roleid "$role" <<< "$roles"; then
        pveum role add "$role" --privs "$privileges"
    elif [[ $role_to_update == "$role" ]]; then
        pveum role modify "$role" --privs "$privileges"
    fi
done

PROXMOX_API_TOKEN_ID="${PROXMOX_API_TOKEN_ID}-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
expiration=$(python3 -c '
import datetime, sys, time
timestamp = int(time.time()) + int(sys.argv[1]) * 86400
formatted = datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(timestamp, formatted)
' "$PROXMOX_API_TOKEN_EXPIRE_DAYS")
read -r expiration_timestamp expiration_utc <<< "$expiration"
credentials=$(pveum user token add "$PROXMOX_API_USER" "$PROXMOX_API_TOKEN_ID" --privsep 1 --expire "$expiration_timestamp" --output-format json)
printf '\nNew API credentials (the secret is shown only once):\n'
printf 'PROXMOX_API_USER: %s\nPROXMOX_API_TOKEN_ID: %s\n' "$PROXMOX_API_USER" "$PROXMOX_API_TOKEN_ID"
printf 'Token lifetime (days): %s\nExpires at (UTC): %s\n' "$PROXMOX_API_TOKEN_EXPIRE_DAYS" "$expiration_utc"
python3 -c '
import json, sys
credentials = json.load(sys.stdin)
print("Full token ID:", credentials["full-tokenid"])
print("proxmox_api_token_secret:", credentials["value"])
' <<< "$credentials"
unset credentials
printf '%s\n' 'Store the secret securely. If a later step fails, keep it before retrying.'

for grant in "${grants[@]}"; do
    IFS='|' read -r role path <<< "$grant"
    pveum acl modify "$path" --users "$PROXMOX_API_USER" --roles "$role" --propagate 1
    pveum acl modify "$path" --tokens "$PROXMOX_API_USER!$PROXMOX_API_TOKEN_ID" --roles "$role" --propagate 1
done

printf '\nUser: %s\nToken: %s!%s\nPrivilege separation: enabled\n' \
    "$PROXMOX_API_USER" "$PROXMOX_API_USER" "$PROXMOX_API_TOKEN_ID"
printf 'Token lifetime (days): %s\nExpires at (UTC): %s\n' "$PROXMOX_API_TOKEN_EXPIRE_DAYS" "$expiration_utc"
printf '\nConfigured roles:\n'
for definition in "${role_definitions[@]}"; do
    IFS='|' read -r role privileges <<< "$definition"
    printf '%s\n  Privileges: %s\n' "$role" "$privileges"
done
printf '\nACL assignments (applied to both user and token):\n'
for grant in "${grants[@]}"; do
    IFS='|' read -r role path <<< "$grant"
    printf '%s\n  Role: %s\n' "$path" "$role"
done
printf '\nEffective user permissions:\n'
pveum user permissions "$PROXMOX_API_USER"
printf '\nEffective token permissions:\n'
pveum user token permissions "$PROXMOX_API_USER" "$PROXMOX_API_TOKEN_ID"
printf '\nExisting unrelated ACL entries were preserved. /vms grants cover all VMs.\n'
printf 'The combined role grants both disk allocation and ISO upload permissions on each selected storage.\n'
