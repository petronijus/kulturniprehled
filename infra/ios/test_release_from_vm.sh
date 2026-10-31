#!/usr/bin/env bash
# Tests for release-from-vm.sh's VM power management — no network, no VMs.
# Fake `ssh`, `op-cache` and `sleep` on PATH play Proxmox and the macOS VM;
# the fake ssh reads its stdin the way the real one does.
#
#   infra/ios/test_release_from_vm.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/release-from-vm.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0
ok() { pass=$((pass + 1)); echo "ok   - $*"; }
fail_test() { echo "FAIL - $*" >&2; exit 1; }

mkdir -p "$T/bin"
cat >"$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Like the real ssh: whatever is on stdin goes to the remote command.
cat >/dev/null
cmd="${*: -1}"
echo "$cmd" >>"$STATE/ssh.log"
case "$cmd" in
  "qm status 106") echo "status: $(cat "$STATE/win")" ;;
  "qm status 108") echo "status: $(cat "$STATE/mac")" ;;
  "qm shutdown 106"*) echo stopped >"$STATE/win" ;;
  "qm start 106") echo running >"$STATE/win" ;;
  "qm start 108") echo running >"$STATE/mac" ;;
  *"shutdown -h now"*)
    [[ -n "${MAC_IGNORES_SHUTDOWN:-}" ]] || echo stopped >"$STATE/mac"
    exit 255 ;;
  *"grep ^version"*) echo "version: 9.9.9+1" ;;
  "cat /tmp/kp_ios_build_exit") echo 0 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\necho secret\n' >"$T/bin/op-cache"
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sleep"
chmod +x "$T/bin/"*

# run <stdin> [args...]: Windows up, macOS down, as on a normal day.
run() {
  local input=$1
  shift
  export STATE="$T/state"
  rm -rf "$STATE"
  mkdir -p "$STATE"
  echo running >"$STATE/win"
  echo stopped >"$STATE/mac"
  set +e
  printf '%s' "$input" | PATH="$T/bin:$PATH" VM_STOP_TIMEOUT=30 \
    bash "$SCRIPT" "$@" >"$STATE/out" 2>&1
  status=$?
  set -e
}

# Regression: an answer piped to the final question was eaten by the first
# ssh, read hit EOF, and set -e ended the run with the VMs still swapped.
run $'y\n'
[[ $status -eq 0 ]] || fail_test "piped answer: exit $status: $(tail -3 "$STATE/out")"
[[ "$(cat "$STATE/mac")/$(cat "$STATE/win")" == stopped/running ]] \
  || fail_test "piped answer: VMs not swapped back"
ok "a piped answer reaches the final question; the VMs are swapped back"

run "" --swap-back
[[ $status -eq 0 && "$(cat "$STATE/win")" == running ]] || fail_test "--swap-back"
grep -q "sudo -S" "$STATE/ssh.log" || fail_test "--swap-back: macOS not stopped with sudo -S"
ok "--swap-back stops macOS from inside with the sudo password and starts Windows"

run "" --keep-mac
[[ $status -eq 0 && "$(cat "$STATE/mac")/$(cat "$STATE/win")" == running/stopped ]] \
  || fail_test "--keep-mac"
ok "--keep-mac leaves the macOS VM up"

run ""
[[ $status -eq 0 && "$(cat "$STATE/mac")" == running ]] || fail_test "no terminal, no flag"
grep -q "No terminal to ask on" "$STATE/out" || fail_test "no terminal: no warning"
ok "with no terminal and no flag it says so and leaves the VMs"

MAC_IGNORES_SHUTDOWN=1 run "" --swap-back
unset MAC_IGNORES_SHUTDOWN
[[ $status -ne 0 ]] || fail_test "a VM that never stops must fail the run"
grep -q "did not stop within" "$STATE/out" || fail_test "stuck VM: no message"
[[ "$(cat "$STATE/win")" == stopped ]] || fail_test "stuck VM: Windows started anyway"
ok "a VM that never stops fails loudly instead of waiting forever"

run "" --bogus
[[ $status -ne 0 ]] || fail_test "an unknown argument must fail"
ok "an unknown argument fails"

echo "all $pass passed"
