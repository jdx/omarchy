#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
real_mise=$(command -v mise || true)

# A mise that records its arguments. `dot capture` runs the wrapped command
# unless told to fail first, as a mise that cannot read its configuration would.
cat >"$stub_bin/mise" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_MISE_CALLS"
case "$1 $2" in
  "dot capture")
    [[ -z ${TEST_MISE_CAPTURE_FAILS:-} ]] || exit 1
    while [[ $1 != "--" ]]; do shift; done
    shift
    "$@"
    exit
    ;;
  "dot track")
    [[ -n ${TEST_OLD_MISE:-} ]] || echo "--machine"
    ;;
  "bootstrap --help")
    [[ -n ${TEST_OLD_MISE:-} ]] || echo "--take-remote-all"
    ;;
  "dot sync")
    [[ -n ${TEST_OLD_MISE:-} || -n ${TEST_NO_SECRET_SCAN:-} ]] || echo "--allow-plaintext-history  versions that look like they contain secrets"
    ;;
esac
exit 0
SH
cat >"$stub_bin/systemctl" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$stub_bin/mise" "$stub_bin/systemctl"

new_home() {
  home="$test_tmp/home-$1"
  mkdir -p "$home/.config"
  : >"$test_tmp/mise-$1"
  calls="$test_tmp/mise-$1"
}

run() {
  HOME="$home" \
  OMARCHY_PATH="$ROOT" \
  PATH="$stub_bin:$ROOT/bin:$PATH" \
  TEST_MISE_CALLS="$calls" \
    "$@"
}

link_of() {
  readlink "$home/.config/mise/conf.d/omarchy-dots.toml"
}

# ---- capture

new_home off
run omarchy-dots-capture "label" -- bash -c 'echo ran >>"$0"' "$test_tmp/ran-off"
[[ $(cat "$test_tmp/ran-off") == "ran" ]] || fail "capture runs the command when dots are off"
[[ ! -s $calls ]] || fail "capture leaves mise alone when dots are off"
pass "capture runs the command directly when dots are off"

new_home on
run omarchy-dots-enable >/dev/null
grep -q '^dot save --label omarchy dots enabled --best-effort$' "$calls" ||
  fail "enable saves the first snapshot"
: >"$calls"
run omarchy-dots-capture "omarchy refresh hyprland" -- bash -c 'echo ran >>"$0"' "$test_tmp/ran-on"
[[ $(cat "$test_tmp/ran-on") == "ran" ]] || fail "capture runs the command once"
grep -q '^dot capture --label omarchy refresh hyprland -- ' "$calls" || fail "capture labels the snapshots"
pass "capture runs the command once between labeled snapshots"

: >"$calls"
TEST_MISE_CAPTURE_FAILS=1 run omarchy-dots-capture "label" -- bash -c 'echo ran >>"$0"' "$test_tmp/ran-fallback" 2>/dev/null
[[ $(cat "$test_tmp/ran-fallback") == "ran" ]] || fail "capture runs the command when mise cannot"
pass "capture runs the command exactly once when mise cannot start it"

if run omarchy-dots-capture "label" -- bash -c 'exit 7'; then
  fail "capture keeps the command's failure"
else
  status=$?
  (( status == 7 )) || fail "capture keeps the command's exit status (got $status)"
fi
pass "capture keeps the command's exit status"

: >"$calls"
OMARCHY_DOTS_CAPTURED=1 run omarchy-dots-capture "label" -- true
[[ ! -s $calls ]] || fail "a nested capture belongs to the running one"
pass "a command inside a capture is not captured again"

# ---- migrations

mkdir -p "$test_tmp/omarchy/migrations"
echo 'echo migrated >>"$TEST_MIGRATED"' >"$test_tmp/omarchy/migrations/100-test.sh"
: >"$calls"
HOME="$home" OMARCHY_PATH="$test_tmp/omarchy" PATH="$stub_bin:$ROOT/bin:$PATH" \
  TEST_MISE_CALLS="$calls" TEST_MIGRATED="$test_tmp/migrated" \
  "$ROOT/bin/omarchy-migrate" >/dev/null
[[ $(cat "$test_tmp/migrated") == "migrated" ]] || fail "migrations run once inside the capture"
grep -q '^dot capture --label omarchy update -- ' "$calls" || fail "pending migrations are captured as one update"
: >"$calls"
HOME="$home" OMARCHY_PATH="$test_tmp/omarchy" PATH="$stub_bin:$ROOT/bin:$PATH" \
  TEST_MISE_CALLS="$calls" TEST_MIGRATED="$test_tmp/migrated" \
  "$ROOT/bin/omarchy-migrate" >/dev/null
! grep -q '^dot capture' "$calls" || fail "nothing is captured without pending migrations"
pass "migrations are captured as one update, only when some are pending"

# ---- enable and disable

[[ $(link_of) == "$ROOT/default/mise/dots.toml" ]] || fail "enable links Omarchy's dots list"
pass "enable links the dots list and saves the first snapshot"

run omarchy-dots-disable >/dev/null
[[ ! -e $home/.config/mise/conf.d/omarchy-dots.toml ]] || fail "disable removes the link"
grep -q '^bootstrap services remove mise-history$' "$calls" || fail "disable stops the watcher"
run omarchy-dots-enable --auto >/dev/null
[[ ! -e $home/.config/mise/conf.d/omarchy-dots.toml ]] || fail "automatic enabling respects disable"
run omarchy-dots-enable >/dev/null
[[ -L $home/.config/mise/conf.d/omarchy-dots.toml ]] || fail "enabling by hand turns dots back on"
pass "disable stays off until enabled by hand"

new_home git
mkdir -p "$home/.git"
run omarchy-dots-enable --auto >"$test_tmp/git.out"
[[ ! -e $home/.config/mise/conf.d/omarchy-dots.toml ]] || fail "enable stands down for a home Git repository"
grep -q 'home directory is a Git repository' "$test_tmp/git.out" || fail "enable says why it stood down"
if run omarchy-dots-enable >/dev/null; then
  fail "enabling by hand reports that another manager keeps the files"
fi
run omarchy-dots-enable --force >/dev/null
[[ -L $home/.config/mise/conf.d/omarchy-dots.toml ]] || fail "--force enables dots anyway"
pass "enable stands down for another dotfile manager unless forced"

new_home stow
mkdir -p "$home/dotfiles" "$home/.config/hypr"
touch "$home/dotfiles/bindings.lua"
ln -s "$home/dotfiles/bindings.lua" "$home/.config/hypr/bindings.lua"
run omarchy-dots-enable --auto >/dev/null
[[ ! -e $home/.config/mise/conf.d/omarchy-dots.toml ]] || fail "enable stands down for linked configs"
pass "enable stands down for configs linked by Stow"

new_home old
TEST_OLD_MISE=1 run omarchy-dots-enable --auto >/dev/null
[[ ! -e $home/.config/mise/conf.d/omarchy-dots.toml ]] || fail "enable stands down for an older mise"
pass "enable stands down for a mise without machine variants"

new_home nosecretscan
TEST_NO_SECRET_SCAN=1 run omarchy-dots-enable --auto >/dev/null
[[ ! -e $home/.config/mise/conf.d/omarchy-dots.toml ]] || fail "enable stands down for a mise that publishes secrets"
pass "enable stands down for a mise without the secret check"

# ---- the dots list, read by a real mise

if [[ -z $real_mise ]] || ! "$real_mise" dot track --help 2>/dev/null | grep -q -- '--machine'; then
  skip "the dots list needs a mise with machine variants"
else
  home="$test_tmp/home-real"
  mkdir -p "$home/.config/mise/conf.d" "$home/.config/hypr"
  ln -s "$ROOT/default/mise/dots.toml" "$home/.config/mise/conf.d/omarchy-dots.toml"
  for file in bindings.lua monitors.lua input.lua; do
    echo "-- $file" >"$home/.config/hypr/$file"
  done
  echo "not a config" >"$home/.config/hypr/notes.txt"
  paths=$(cd "$home" && env -i PATH="$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    MISE_STATE_DIR="$home/.local/state/mise" MISE_DATA_DIR="$home/.local/share/mise" \
    MISE_CACHE_DIR="$home/.cache/mise" "$real_mise" dot paths --json)
  jq -e '.entries[] | select(.path == "~/.config/hypr/monitors.lua") | .variant | startswith("machine-")' <<<"$paths" >/dev/null ||
    fail "monitors.lua is kept per machine"
  jq -e '.entries[] | select(.path == "~/.bashrc")' <<<"$paths" >/dev/null ||
    fail "the dots list tracks ~/.bashrc"
  [[ $(jq '.invalid | length' <<<"$paths") == "0" ]] || fail "every dots entry is valid: $(jq -c .invalid <<<"$paths")"
  pass "a real mise reads the dots list, with monitors.lua per machine"
fi
