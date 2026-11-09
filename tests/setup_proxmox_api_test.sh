#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir "$test_dir/bin"

cat > "$test_dir/bin/id" <<'MOCK'
#!/usr/bin/env bash
printf '0\n'
MOCK

cat > "$test_dir/bin/pvesh" <<'MOCK'
#!/usr/bin/env bash
set -eu
if [[ $2 == /version ]]; then
    printf '{"version":"%s"}\n' "$TEST_VERSION"
fi
MOCK

cat > "$test_dir/bin/pveum" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TEST_CALLS"
case "$1 $2" in
    'role list') printf '%s\n' "$TEST_ROLES" ;;
    'user list') printf '[{"userid":"talos@pve"}]\n' ;;
    'user token')
        if [[ $3 == add ]]; then
            printf '{"full-tokenid":"%s!%s","value":"test-secret"}\n' "$4" "$5"
        fi
        ;;
    'role add'|'role modify'|'acl modify'|'user permissions') ;;
    *) printf 'Unexpected pveum call: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK

chmod +x "$test_dir/bin/id" "$test_dir/bin/pvesh" "$test_dir/bin/pveum"
export PATH="$test_dir/bin:$PATH"
export PROXMOX_API_USER='talos@pve'
export PROXMOX_API_TOKEN_ID='provisioning'
export PROXMOX_API_TOKEN_EXPIRE_DAYS=30
export PROXMOX_NODE='pve-01'
export PROXMOX_STORAGE='isos'
export PROXMOX_VM_STORAGE='disks'
export K8S_VMBR='vmbr0'
export TEST_CALLS="$test_dir/calls"
export TEST_VERSION TEST_ROLES

base_privileges='VM.Allocate VM.Audit VM.Config.CDROM VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt Datastore.Audit Datastore.AllocateTemplate Datastore.AllocateSpace Sys.Audit SDN.Use'
modern_roles='[{"roleid":"PVEAdmin","privs":["Sys.AccessNetwork"]}]'

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    cat "$test_dir/output" >&2
    exit 1
}

run_case() {
    local name=$1 expected=$2 input=${3:-} status=0
    : > "$TEST_CALLS"
    bash "$project_dir/setup_proxmox_api.sh" > "$test_dir/output" 2>&1 <<< "$input" || status=$?
    if [[ $expected == success ]]; then
        [[ $status == 0 ]] || fail "$name: expected success, got $status"
    else
        [[ $status != 0 ]] || fail "$name: expected failure"
        if grep -Eq '^(role (add|modify)|user token add|acl modify|user add) ' "$TEST_CALLS"; then
            fail "$name: changed state on preflight failure"
        fi
    fi
    printf 'PASS: %s\n' "$name"
}

assert_call() {
    grep -Fq -- "$1" "$TEST_CALLS" || fail "Missing call: $1"
}

assert_no_call() {
    if grep -Fq -- "$1" "$TEST_CALLS"; then
        fail "Unexpected call: $1"
    fi
}

TEST_VERSION=9.0.11
TEST_ROLES=$modern_roles
run_case 'PVE 9 fresh setup' success
assert_call 'VM.GuestAgent.Audit'
assert_no_call 'VM.Monitor'
assert_no_call 'VM.GuestAgent.Unrestricted'
assert_no_call 'Sys.Modify'
assert_call 'user token add talos@pve provisioning-'
assert_call '--privsep 1 --expire '
for path in /vms /storage/isos /storage/disks /nodes/pve-01 /sdn/zones/localnetwork/vmbr0; do
    assert_call "acl modify $path --users talos@pve --roles TalosInstaller --propagate 1"
    assert_call "acl modify $path --tokens talos@pve!provisioning-"
done

TEST_VERSION=8.4.1
run_case 'PVE 8 with Sys.AccessNetwork' success
assert_call 'VM.Monitor'
assert_no_call 'VM.GuestAgent.Audit'
assert_no_call 'Sys.Modify'

TEST_ROLES='[]'
run_case 'PVE 8 legacy grant declined' failure no
run_case 'PVE 8 legacy grant approved' success yes
assert_call 'role add TalosInstallerDownload --privs Sys.Audit Sys.Modify'
assert_call 'acl modify / --users talos@pve --roles TalosInstallerDownload'

TEST_VERSION=9.0.11
run_case 'PVE 9 never falls back to Sys.Modify' failure yes
TEST_VERSION=10.0.1
run_case 'Unsupported PVE version' failure
TEST_VERSION=invalid
run_case 'Invalid PVE version' failure

TEST_VERSION=9.0.11
TEST_ROLES="[{\"roleid\":\"PVEAdmin\",\"privs\":\"Sys.AccessNetwork\"},{\"roleid\":\"TalosInstaller\",\"privs\":\"$base_privileges Sys.AccessNetwork VM.Monitor\"}]"
run_case 'PVE 9 migration declined' failure no
run_case 'PVE 9 migration approved' success yes
assert_call "role modify TalosInstaller --privs"
assert_call 'VM.GuestAgent.Audit'
assert_no_call 'VM.Monitor'

TEST_ROLES="[{\"roleid\":\"PVEAdmin\",\"privs\":\"Sys.AccessNetwork\"},{\"roleid\":\"TalosInstaller\",\"privs\":\"$base_privileges Sys.AccessNetwork\"}]"
run_case 'PVE 9 migration after VM.Monitor removed' success yes
assert_call 'role modify TalosInstaller --privs'

TEST_ROLES="[{\"roleid\":\"PVEAdmin\",\"privs\":\"Sys.AccessNetwork\"},{\"roleid\":\"TalosInstaller\",\"privs\":\"$base_privileges Sys.AccessNetwork VM.GuestAgent.Audit\"}]"
run_case 'Matching PVE 9 role reused without confirmation' success
assert_no_call 'role modify'
assert_no_call 'role add'

TEST_VERSION=8.4.1
TEST_ROLES="[{\"roleid\":\"PVEAdmin\",\"privs\":\"Sys.AccessNetwork\"},{\"roleid\":\"TalosInstaller\",\"privs\":\"$base_privileges Sys.AccessNetwork VM.Monitor\"}]"
run_case 'Matching PVE 8 role reused' success
assert_no_call 'role modify'

TEST_VERSION=9.0.11
TEST_ROLES="[{\"roleid\":\"PVEAdmin\",\"privs\":\"Sys.AccessNetwork\"},{\"roleid\":\"TalosInstaller\",\"privs\":\"$base_privileges Sys.AccessNetwork VM.Monitor Sys.Modify\"}]"
run_case 'Unrelated shared-role difference rejected' failure yes

TEST_ROLES=$modern_roles
PROXMOX_VM_STORAGE=isos
run_case 'Same ISO and VM storage' success
[[ $(grep -c '^acl modify /storage/isos ' "$TEST_CALLS") == 2 ]] ||
    fail 'Same storage should have exactly one user and one token grant'

PROXMOX_API_TOKEN_EXPIRE_DAYS=0
run_case 'Invalid token lifetime' failure
printf 'All setup script tests passed.\n'
