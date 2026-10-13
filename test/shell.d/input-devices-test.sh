#!/bin/bash

# Hyprland raises no event when a keyboard arrives or leaves, so the shell
# learns of it from /dev/input instead: a change signal once a device's burst of
# nodes settles and one more a few seconds on, for a device udev is slow to
# finish with, and none while nothing changes. The keyboard layout
# widget reads the seat again on that signal rather than asking on a timer.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_compositor "input device change signal"
require_command quickshell
require_command inotifywait

stage=$(mktemp -d)
QS_PID=""
# Quickshell restarts a watcher killed under it, and leaves one running when it
# is stopped itself, so stop the shell first and then what it had started.
stop_shell() {
  local children=()

  if [[ -n $QS_PID ]]; then
    mapfile -t children < <(pgrep -P "$QS_PID" 2>/dev/null || true)
    kill "$QS_PID" 2>/dev/null || true
    for _ in {1..30}; do
      kill -0 "$QS_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$QS_PID" 2>/dev/null || true
    wait "$QS_PID" 2>/dev/null || true
    (( ${#children[@]} == 0 )) || kill "${children[@]}" 2>/dev/null || true
  fi
  QS_PID=""
}

cleanup() {
  stop_shell
  rm -rf "$stage"
}
trap cleanup EXIT

mkdir -p "$stage/root/dev/input" "$stage/root/run/udev/data"
ln -s "$ROOT/shell/Commons" "$stage/Commons"
cp "$SHELL_TEST_DIR/fixtures/input-devices/shell.qml" "$stage/shell.qml"

OMARCHY_INPUT_ROOT="$stage/root" quickshell -p "$stage" --no-color >"$stage/log" 2>&1 &
QS_PID=$!

watching=0
for _ in {1..100}; do
  if pgrep -P "$QS_PID" -f "inotifywait .*$stage/root/dev/input" >/dev/null; then
    watching=1
    break
  fi
  kill -0 "$QS_PID" 2>/dev/null || fail "the fixture shell starts" "$(cat "$stage/log")"
  sleep 0.1
done
(( watching )) || fail "the shell watches /dev/input" "$(cat "$stage/log")"

# Counted from a baseline, so each check sees only what came after it.
base=0
changes() {
  local total
  total=$(grep -c 'CHANGED' "$stage/log" || true)
  echo $(( total - base ))
}

# Anything that changed before the watch was up went unseen, so the seat is
# read once the watch is set up, and again a few seconds on.
sleep 4
(( $(changes) == 2 )) || fail "the seat is read once the watch is up, and again after" "$(cat "$stage/log")"
pass "the seat is read once the watch is up, and again after"
base=$(( base + 2 ))

sleep 1
(( $(changes) == 0 )) || fail "a seat that does not change raises no signal" "$(cat "$stage/log")"
pass "a seat that does not change raises no signal"

# A keyboard arrives as an event node and its handler links, closer together
# than the settle delay, so a signal only lands once the last of them has: the
# first signal is logged after the last node, however slow the machine.
touch "$stage/root/dev/input/event40"
sleep 0.4
touch "$stage/root/dev/input/event41"
sleep 0.4
last_node_ms=$(date +%s%3N)
mkdir "$stage/root/dev/input/js9"
sleep 1.5
(( $(changes) == 1 )) || fail "a device arriving raises one change signal once it settles" "$(cat "$stage/log")"
first_signal_ms=$(grep -o 'CHANGED [0-9]*' "$stage/log" | sed -n "$(( base + 1 ))p" | cut -d' ' -f2)
(( first_signal_ms >= last_node_ms )) ||
  fail "a device's burst of nodes raises nothing until the last has settled" "signal at $first_signal_ms, last node at $last_node_ms"
sleep 3
(( $(changes) == 2 )) || fail "a device arriving raises one more change signal a few seconds on" "$(cat "$stage/log")"
pass "a device arriving raises a change signal as its burst settles and once more after"

rm -rf "$stage/root/dev/input/event40" "$stage/root/dev/input/event41" "$stage/root/dev/input/js9"
sleep 4.5
(( $(changes) == 4 )) || fail "a device leaving raises the same two change signals" "$(cat "$stage/log")"
pass "a device leaving raises the same two change signals"

# The last device going can take /dev/input with it. A device coming back
# brings a new directory, which has to be watched again.
rm -rf "$stage/root/dev/input"
sleep 4
mkdir "$stage/root/dev/input"
# Past both signals for the directory itself, so only the node can count.
sleep 4.5
before=$(changes)
touch "$stage/root/dev/input/event42"
sleep 1.5
(( $(changes) > before )) || fail "a recreated /dev/input is watched again" "$(cat "$stage/log")"
pass "a recreated /dev/input is watched again"

# udev records an input device (character major 13) once it has finished with
# it, which is when Hyprland gets it, and that can trail the node. Its records
# for anything else are no input device.
sleep 4
before=$(changes)
touch "$stage/root/run/udev/data/+power_supply:BAT0" "$stage/root/run/udev/data/c189:3"
sleep 1.5
(( $(changes) == before )) || fail "udev records of other devices raise nothing" "$(cat "$stage/log")"
touch "$stage/root/run/udev/data/c13:70"
sleep 1.5
(( $(changes) > before )) || fail "udev finishing with an input device raises a change signal" "$(cat "$stage/log")"
pass "udev finishing with an input device raises a change signal, and other records nothing"

# A device that comes while the watch is down goes unseen, so the seat is read
# again once the watch is back.
sleep 4
before=$(changes)
pkill -P "$QS_PID" -f inotifywait
touch "$stage/root/dev/input/event43"
sleep 2
(( $(changes) > before )) || fail "the seat is read again once a lost watch is back" "$(cat "$stage/log")"
pass "the seat is read again once a lost watch is back"

# A watch that cannot be set up at all (no /dev here, an exhausted inotify
# limit on a real machine) keeps failing at once. Its retries must not each
# make every bar ask Hyprland: past the first reading, the keyboard widget's
# own fallback timer covers it.
stop_shell
mkdir -p "$stage/broken"
OMARCHY_INPUT_ROOT="$stage/broken" quickshell -p "$stage" --no-color >"$stage/broken.log" 2>&1 &
QS_PID=$!
sleep 7
kill -0 "$QS_PID" 2>/dev/null || fail "the fixture shell runs without a watchable /dev" "$(cat "$stage/broken.log")"
broken_changes=$(grep -c 'CHANGED' "$stage/broken.log" || true)
(( broken_changes <= 2 )) ||
  fail "a watch that keeps failing does not read the seat on every retry" "$broken_changes change signals in 7s"
pass "a watch that keeps failing does not read the seat on every retry"
