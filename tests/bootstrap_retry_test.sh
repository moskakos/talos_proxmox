#!/usr/bin/env bash
set -euo pipefail

role_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -f -- "$test_dir/talosctl" "$test_dir/playbook.yml" "$test_dir/calls" "$test_dir/output"; rmdir -- "$test_dir"' EXIT

cat > "$test_dir/talosctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo call >> "$TEST_CALLS"
case "$TEST_CASE" in
    ready) exit 0 ;;
    transient)
        if [[ $(wc -l < "$TEST_CALLS") -gt 1 ]]; then
            exit 0
        fi
        ;;
    permanent)
        echo 'rpc error: code = PermissionDenied desc = bootstrap is not available yet' >&2
        exit 1
        ;;
    unavailable) ;;
    *) exit 2 ;;
esac
echo 'error executing bootstrap: rpc error: code = FailedPrecondition desc = bootstrap is not available yet' >&2
exit 1
MOCK
chmod +x "$test_dir/talosctl"

cat > "$test_dir/playbook.yml" <<'PLAYBOOK'
---
- hosts: localhost
  gather_facts: false
  vars:
    talos_proxmox_masters:
      - ip: 192.0.2.1
  tasks:
PLAYBOOK
# Run the actual task with shorter retry settings to keep the test fast.
awk '
    /^    - name: Bootstrap Talos cluster on first master$/ { printing = 1 }
    /^    - name: Wait for Kubernetes API to be available$/ { printing = 0 }
    printing {
        sub(/^  /, "")
        if ($0 ~ /^    retries:/) $0 = "    retries: 2"
        if ($0 ~ /^    delay:/) $0 = "    delay: 1"
        print
    }
' "$role_dir/tasks/bootstrap_cluster.yml" >> "$test_dir/playbook.yml"

export PATH="$test_dir:$PATH"
export TEST_CALLS="$test_dir/calls"
export TEST_CASE

run_case() {
    local case_name=$1 expected_status=$2 expected_calls=$3 status=0
    TEST_CASE=$case_name
    : > "$TEST_CALLS"
    ansible-playbook -i localhost, -c local "$test_dir/playbook.yml" > "$test_dir/output" 2>&1 || status=$?
    if [[ ($expected_status == success && $status != 0) || ($expected_status == failure && $status == 0) ]]; then
        printf 'FAIL: %s returned status %s\n' "$case_name" "$status" >&2
        cat "$test_dir/output" >&2
        exit 1
    fi
    if [[ $(wc -l < "$TEST_CALLS" | tr -d ' ') != "$expected_calls" ]]; then
        printf 'FAIL: %s did not make %s attempts\n' "$case_name" "$expected_calls" >&2
        cat "$test_dir/output" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$case_name"
}

run_case ready success 1
run_case transient success 2
run_case permanent failure 1
run_case unavailable failure 3
