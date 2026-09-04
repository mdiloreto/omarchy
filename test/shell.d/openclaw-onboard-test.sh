#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
export TEST_LOG="$tmp_dir/log"
export PATH="$tmp_dir/bin:$PATH"
export HOME="$tmp_dir/home"
export OMARCHY_OPENCLAW_ONBOARD_SETTLE_SECONDS=0

# A wizard that configures OpenClaw, prints its outro, and then lingers forever
# on an open handle: the 2026.9.1 --skip-ui behaviour. It "installs the
# gateway" by writing the config a moment in, so the gateway only starts
# answering partway through, never at once.
cat >"$tmp_dir/bin/openclaw" <<'SCRIPT'
#!/bin/bash
printf 'openclaw:%s\n' "$*" >>"$TEST_LOG"
case $1 in
onboard)
  ( sleep 1; mkdir -p "$HOME/.openclaw"; touch "$HOME/.openclaw/openclaw.json" ) &
  trap 'echo terminated >>"$TEST_LOG"; exit 143' TERM
  while :; do sleep 0.2; done
  ;;
dashboard)
  [[ -f $HOME/.openclaw/openclaw.json ]] && echo '{"ok":true}' || { echo '{"ok":false}'; exit 1; }
  ;;
esac
SCRIPT
chmod +x "$tmp_dir/bin/openclaw"

start=$SECONDS
rc=0
"$ROOT/bin/omarchy-openclaw-onboard" </dev/null >/dev/null 2>&1 || rc=$?
elapsed=$((SECONDS - start))

grep -q '^openclaw:onboard --flow quickstart --install-daemon --skip-ui$' "$TEST_LOG" ||
  fail "onboarding runs the classic quickstart wizard with the service install" "$(grep '^openclaw:onboard' "$TEST_LOG" || true)"
pass "onboarding runs the classic quickstart wizard with the service install"

[[ $rc == 0 ]] || fail "a wizard that lingers after the gateway is up is stopped and counts as success" "rc=$rc"
grep -q '^terminated$' "$TEST_LOG" ||
  fail "a wizard that lingers after the gateway is up is stopped and counts as success" "wizard was never signalled"
(( elapsed < 30 )) || fail "a wizard that lingers after the gateway is up is stopped and counts as success" "took ${elapsed}s"
pass "a wizard that lingers after the gateway is up is stopped and counts as success"

# The wizard only starts being stopped once the gateway actually answers: a
# stub that never writes the config is left alone and must be ended by its own
# exit, not the watcher.
: >"$TEST_LOG"
rm -rf "$HOME/.openclaw"
cat >"$tmp_dir/bin/openclaw" <<'SCRIPT'
#!/bin/bash
printf 'openclaw:%s\n' "$*" >>"$TEST_LOG"
[[ $1 == onboard ]] && { echo "Skipped for now."; exit 3; }
echo '{"ok":false}'; exit 1
SCRIPT
chmod +x "$tmp_dir/bin/openclaw"
rc=0
"$ROOT/bin/omarchy-openclaw-onboard" </dev/null >/dev/null 2>&1 || rc=$?
[[ $rc == 3 ]] || fail "an abandoned wizard passes its exit code through" "rc=$rc"
[[ ! -f $HOME/.openclaw/openclaw.json ]] || fail "an abandoned wizard passes its exit code through" "config appeared"
! grep -q '^terminated$' "$TEST_LOG" || fail "an abandoned wizard passes its exit code through" "watcher signalled it anyway"
pass "an abandoned wizard passes its exit code through"

# A wizard that finishes and exits on its own is simply waited for.
: >"$TEST_LOG"
cat >"$tmp_dir/bin/openclaw" <<'SCRIPT'
#!/bin/bash
printf 'openclaw:%s\n' "$*" >>"$TEST_LOG"
[[ $1 == onboard ]] && { mkdir -p "$HOME/.openclaw"; touch "$HOME/.openclaw/openclaw.json"; exit 0; }
echo '{"ok":true}'
SCRIPT
chmod +x "$tmp_dir/bin/openclaw"
rc=0
"$ROOT/bin/omarchy-openclaw-onboard" </dev/null >/dev/null 2>&1 || rc=$?
[[ $rc == 0 ]] || fail "a wizard that exits cleanly is waited for" "rc=$rc"
pass "a wizard that exits cleanly is waited for"

# Input reaches the wizard: it runs in the foreground, not backgrounded (which
# would stop it on SIGTTIN the moment it read stdin).
: >"$TEST_LOG"
rm -rf "$HOME/.openclaw"
cat >"$tmp_dir/bin/openclaw" <<'SCRIPT'
#!/bin/bash
printf 'openclaw:%s\n' "$*" >>"$TEST_LOG"
case $1 in
onboard)
  read -r answer
  printf 'answer:%s\n' "$answer" >>"$TEST_LOG"
  mkdir -p "$HOME/.openclaw"; touch "$HOME/.openclaw/openclaw.json"
  exit 0
  ;;
dashboard) echo '{"ok":true}' ;;
esac
SCRIPT
chmod +x "$tmp_dir/bin/openclaw"
printf 'gpt-5\n' | "$ROOT/bin/omarchy-openclaw-onboard" >/dev/null 2>&1
grep -q '^answer:gpt-5$' "$TEST_LOG" ||
  fail "the wizard reads terminal input" "$(grep '^answer' "$TEST_LOG" || echo 'no input reached it')"
pass "the wizard reads terminal input"
