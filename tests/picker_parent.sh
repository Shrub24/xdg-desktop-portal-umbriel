#!/usr/bin/env bash
# Opens the real share picker from ScreenCast Start and interactive Screenshot in a private headless compositor and
# checks which window the compositor reports as its parent. A picker that was not handed the xdg-foreign handle has
# no parent, so the relation only holds when the portal handle reached GTK and the compositor honoured it.
set -euo pipefail

readonly BUILD=$(realpath "${1:?usage: picker_parent.sh UMBRIEL_BUILD PORTAL_BUILD}")
readonly PORTAL_BUILD=$(realpath "${2:?portal build directory required}")
readonly UMBRIEL=$BUILD/umbriel
readonly PORTAL=$PORTAL_BUILD/xdg-desktop-portal-umbriel
readonly PICKER=$PORTAL_BUILD/umbriel-share-picker
readonly OBSERVER=$BUILD/tests/seat-log-client
readonly RUNTIME=$(mktemp -d "${TMPDIR:-/tmp}/umbriel-picker-parent.XXXXXXXX")
chmod 700 "$RUNTIME"
PIDS=()
SUCCESS=0
cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
  if ((SUCCESS)) && [[ ${UMBRIEL_PICKER_KEEP_LOGS:-0} != 1 ]]; then
    rm -rf "$RUNTIME"
  else
    echo "Picker parent logs retained in $RUNTIME"
  fi
}
trap cleanup EXIT

for executable in "$UMBRIEL" "$PORTAL" "$PICKER" "$OBSERVER"; do
  [[ -x $executable ]] || {
    echo "Missing executable: $executable"
    exit 2
  }
done
for command in dbus-daemon busctl jq; do
  command -v "$command" >/dev/null || {
    echo "Missing test command: $command"
    exit 2
  }
done
export XDG_RUNTIME_DIR=$RUNTIME
export XDG_CONFIG_HOME=$RUNTIME/config
export XDG_CACHE_HOME=$RUNTIME/cache
export XDG_DATA_HOME=$RUNTIME/data
export XDG_STATE_HOME=$RUNTIME/state
export XDG_CONFIG_DIRS=$RUNTIME/config-dirs
export XDG_DATA_DIRS=$RUNTIME/data-dirs
export DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME/bus
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$RUNTIME/no-system-bus
export XDG_SESSION_TYPE=wayland
export GDK_BACKEND=wayland
unset DISPLAY WAYLAND_SOCKET NOTIFY_SOCKET SYSTEMD_EXEC_PID
mkdir -p "$XDG_CONFIG_HOME/xdg-desktop-portal-umbriel" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

readonly PICKER_TITLE='Share a screen or window'

cat >"$RUNTIME/compositor.toml" <<CONFIG
[general]
xwayland = false
show_cheatsheet = false
autostart = []
[animation]
enabled = false
[appearance]
border_width = 0
outer_border_width = 0
corner_radius = 0
[appearance.shadow]
enabled = false
[appearance.blur]
enabled = false
[output.HEADLESS-1]
mode = "1280x720"
scale = 1
hdr = "off"
CONFIG
WAYLAND_DISPLAY=picker-isolated-parent WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 \
  "$UMBRIEL" -c "$RUNTIME/compositor.toml" >"$RUNTIME/compositor.log" 2>&1 &
PIDS+=("$!")
export WAYLAND_DISPLAY=wayland-0
export UMBRIEL_SOCKET=$RUNTIME/umbriel-wayland-0.sock
for _ in $(seq 200); do
  [[ -S $UMBRIEL_SOCKET ]] && break
  sleep 0.025
done
[[ -S $UMBRIEL_SOCKET ]] || {
  cat "$RUNTIME/compositor.log"
  exit 1
}

EXPORT_TOPLEVEL=1 "$OBSERVER" picker-parent >"$RUNTIME/parent.log" 2>&1 &
PIDS+=("$!")
handle=
for _ in $(seq 240); do
  handle=$(sed -n 's/^exported handle=//p' "$RUNTIME/parent.log")
  [[ -n $handle ]] && break
  sleep 0.025
done
[[ -n $handle ]] || {
  echo "The parent never exported an xdg-foreign handle"
  cat "$RUNTIME/parent.log"
  exit 1
}

cat >"$XDG_CONFIG_HOME/xdg-desktop-portal-umbriel/config.toml" <<CONFIG
[screencast]
chooser_cmd = "$PICKER"
CONFIG
dbus-daemon --session --nofork --address="$DBUS_SESSION_BUS_ADDRESS" >"$RUNTIME/bus.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 200); do
  [[ -S $RUNTIME/bus ]] && break
  sleep 0.025
done
"$PORTAL" >"$RUNTIME/portal.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 200); do
  if busctl --user status org.freedesktop.impl.portal.desktop.umbriel >/dev/null 2>&1; then break; fi
  sleep 0.025
done

readonly PATH_PREFIX=/org/freedesktop/portal/desktop
readonly APP=org.umbriel.PickerParentTest
call() {
  busctl --user --timeout=30 call org.freedesktop.impl.portal.desktop.umbriel "$PATH_PREFIX" "$@"
}

# Prints the compositor's parent window id for the open picker; empty when it has none.
picker_parent() {
  "$UMBRIEL" windows --json | jq -r --arg title "$PICKER_TITLE" '.[] | select(.title == $title) | .parent'
}

# Waits for the picker window and echoes its parent id.
await_picker() {
  local parent
  for _ in $(seq 400); do
    parent=$("$UMBRIEL" windows --json | jq -r --arg title "$PICKER_TITLE" 'first(.[] | select(.title == $title) | .parent) // "none"')
    [[ $parent != none ]] && {
      echo "$parent"
      return 0
    }
    sleep 0.025
  done
  echo "The share picker never mapped" >&2
  cat "$RUNTIME/portal.log" >&2
  return 1
}

# Ends the open picker and requires the portal request to answer.
dismiss() {
  local request_pid=$1
  pkill -KILL -f "^$PICKER\$"
  wait "$request_pid" || true
  [[ -z $("$UMBRIEL" windows --json | jq -r --arg title "$PICKER_TITLE" '.[] | select(.title == $title) | .id') ]] || {
    echo "The picker is still open after dismissal"
    return 1
  }
}

expect_parent() {
  local label=$1 want=$2 got=$3
  [[ $got == "$want" ]] || {
    echo "$label: expected parent '$want', got '$got'"
    "$UMBRIEL" windows --json
    return 1
  }
  echo "$label: parent '$got'"
}

session=0
screencast_picker() {
  local parent=$1 token
  session=$((session + 1))
  token=$PATH_PREFIX/session/test/s$session
  call org.freedesktop.impl.portal.ScreenCast CreateSession oosa{sv} \
    "$PATH_PREFIX/request/test/c$session" "$token" "$APP" 0 >/dev/null
  call org.freedesktop.impl.portal.ScreenCast SelectSources oosa{sv} \
    "$PATH_PREFIX/request/test/m$session" "$token" "$APP" 1 types u 1 >/dev/null
  call org.freedesktop.impl.portal.ScreenCast Start oossa{sv} \
    "$PATH_PREFIX/request/test/t$session" "$token" "$APP" "$parent" 0 >/dev/null &
  REQUEST_PID=$!
}

screenshot_picker() {
  local parent=$1
  session=$((session + 1))
  call org.freedesktop.impl.portal.Screenshot Screenshot ossa{sv} \
    "$PATH_PREFIX/request/test/s$session" "$APP" "$parent" 1 interactive b true >/dev/null &
  REQUEST_PID=$!
}

parent_id=$("$UMBRIEL" windows --json | jq -er '.[] | select(.title == "picker-parent") | .id')
for entry in screencast screenshot; do
  "${entry}_picker" "wayland:$handle"
  expect_parent "$entry with parent" "$parent_id" "$(await_picker)"
  dismiss "$REQUEST_PID"
done

# Controls: requests without a usable parent must still open the picker, with no parent.
for parent in '' 'x11:1234' 'wayland:no-such-handle'; do
  screencast_picker "$parent"
  expect_parent "screencast with parent '$parent'" '' "$(await_picker)"
  dismiss "$REQUEST_PID"
done

SUCCESS=1
echo 'Share picker is parented through xdg-foreign and still opens without a usable parent'
