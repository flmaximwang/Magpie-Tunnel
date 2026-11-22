#!/bin/bash
# Automated acceptance channel for the menu-bar app's windows.
#
# It answers two questions without a human clicking anything:
#   1. is the app's main thread still responsive?
#   2. did the window actually draw content, or is it blank?
#
# Exit codes: 0 pass, 1 blank window or wedged main thread, 2 could not drive
# the UI, 3 environment problem.
#
# Everything runs out of a temp directory with isolated paths; the production
# app (~/Applications/Magpie-WebUI-Tunnel.app) and its daemon are never touched.
#
# Usage:
#   Tests/manual-ui/ui_acceptance.sh [--app <bundle>] [--window config|logs|both]
#                                    [--keep] [--control] [--json]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APP="${REPO}/dist/Magpie-WebUI-Tunnel.app"
WANT="both"
KEEP=0
CONTROL=0
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --window) WANT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --control) CONTROL=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done

# Diagnostics go to stderr so that functions whose stdout is captured as
# JSON (open_window_via_button, shot_window) stay parseable.
say() { echo "$@" >&2; }
fail_env() { echo "ENV: $*" >&2; exit 3; }

[ -d "$APP" ] || fail_env "app bundle not found: $APP"
BIN="$APP/Contents/MacOS/MagpieTunnelStatus"
[ -x "$BIN" ] || fail_env "executable not found: $BIN"

command -v jq >/dev/null || fail_env "jq is required (brew install jq)"
command -v xcrun >/dev/null || fail_env "xcrun not found (install Xcode command line tools)"

TMPBASE="${TMPDIR:-/tmp}"
TMPBASE="${TMPBASE%/}"
WORK="$(mktemp -d "$TMPBASE/magpie-ui-accept.XXXXXX")"
PROBE="$WORK/ui-probe"
RUN="$WORK/run"

cleanup() {
  # Only processes whose command line mentions this run's temp directory may be
  # killed: that is what keeps the user's production app and daemon safe.
  if [ -f "$RUN/app.pid" ]; then
    APPPID="$(cat "$RUN/app.pid")"
    if [ -n "$APPPID" ] && kill -0 "$APPPID" 2>/dev/null; then
      kill -TERM "$APPPID" 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$APPPID" 2>/dev/null || break; sleep 0.5; done
      kill -KILL "$APPPID" 2>/dev/null
    fi
  fi
  # Reap the isolated daemon too. Current builds pass the isolated paths on its
  # command line, but an older build only gets --owner-pid, so its children are
  # matched by parent pid as well. Both can only ever hit this run's own app.
  pkill -TERM -f "$WORK" 2>/dev/null
  if [ -n "${APPPID:-}" ]; then pkill -TERM -P "$APPPID" 2>/dev/null; fi
  sleep 0.3
  pkill -KILL -f "$WORK" 2>/dev/null
  if [ -n "${APPPID:-}" ]; then pkill -KILL -P "$APPPID" 2>/dev/null; fi
  if [ "$KEEP" -eq 1 ]; then
    echo "artifacts kept in $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$RUN/paths/status" "$RUN/paths/logs" "$RUN/paths/lock" "$RUN/shots"

# MARK: - probe helper

# `xcrun swiftc` rather than the toolchain path directly: calling swiftc by
# absolute path loses SDKROOT and fails to load the standard library.
xcrun swiftc -O "$HERE/UIProbe.swift" -o "$PROBE" 2>"$RUN/build.log" \
  || fail_env "could not compile UIProbe.swift (see $RUN/build.log)"

probe() { "$PROBE" "$@"; }

# A mock ssh keeps the daemon from ever opening a real connection; the config
# below points at example.invalid, so nothing can reach the network anyway.
mock_ssh() { printf '#!/bin/sh\nexit 1\n' > "$RUN/mock-ssh"; chmod +x "$RUN/mock-ssh"; }
mock_ssh

# Line format: name|local_port|ssh_target|remote_port|web_key. A row is needed:
# the config window's table only builds a row view when there is a target, and
# that row view is exactly what regressed.
cat > "$RUN/targets.conf" <<'CONF'
# Isolated test configuration: unreachable host, no real credentials.
accept-one|15430|ubuntu@example.invalid|443|test-secret
accept-two|15431|ubuntu@example.invalid|8080|
CONF

# MARK: - isolated app bundle

cp -R "$APP" "$RUN/App.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.maxim.magpie-web-tunnel.uitest.acceptance" \
  "$RUN/App.app/Contents/Info.plist" 2>/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleName Magpie-UIAcceptance" \
  "$RUN/App.app/Contents/Info.plist" 2>/dev/null
codesign --force --sign - "$RUN/App.app" >/dev/null 2>&1 || say "WARN: ad-hoc signing failed"
APPBIN="$RUN/App.app/Contents/MacOS/MagpieTunnelStatus"

# MARK: - launch

LAUNCH_ENV=(
  "MAGPIE_TUNNEL_CONFIG=$RUN/targets.conf"
  "MAGPIE_TUNNEL_STATUS_DIR=$RUN/paths/status"
  "MAGPIE_TUNNEL_LOG_DIR=$RUN/paths/logs"
  "MAGPIE_TUNNEL_LOCK_DIR=$RUN/paths/lock"
  "MAGPIE_TUNNEL_SSH_BIN=$RUN/mock-ssh"
)

env "${LAUNCH_ENV[@]}" "$APPBIN" \
  --config "$RUN/targets.conf" \
  --status-dir "$RUN/paths/status" \
  --log-dir "$RUN/paths/logs" \
  --lock-dir "$RUN/paths/lock" \
  --refresh-interval 2 \
  > "$RUN/app.log" 2>&1 &
PID=$!
echo "$PID" > "$RUN/app.pid"

for _ in $(seq 1 40); do
  kill -0 "$PID" 2>/dev/null || fail_env "app exited during launch (see $RUN/app.log)"
  ITEM="$(probe statusitem "$PID" 2>/dev/null)"
  if [ "$(echo "$ITEM" | jq -r '.found // false')" = "true" ]; then break; fi
  sleep 0.25
done

APP_PID="$PID"
say "app:       $APPBIN"
say "pid:       $APP_PID"
say "isolation: $RUN (targets/status/log/lock/ssh all inside this temp dir)"

AX_TRUSTED="$(probe trusted | jq -r '.axTrusted')"
# Set by testing this script's own fallback path; a real -25211 looks the same.
if [ "${MAGPIE_UI_FORCE_HEADLESS:-0}" = "1" ]; then AX_TRUSTED="false"; fi
say "ax-trusted: $AX_TRUSTED"

RESULT="pass"
REPORT="[]"
add_result() { REPORT="$(echo "$REPORT" | jq -c --argjson item "$1" '. + [$item]')"; }

# MARK: - screenshot + verdict

# A window that failed to draw is *transparent* (opaqueRatio 0) or a single flat
# colour, not white — this app is dark-mode. So the verdict looks at coverage,
# colour variety and contrast, and reports the white ratio only as a side note.
verdict_for() {
  local png="$1"
  local stats
  stats="$(probe image "$png")"
  echo "$stats" | jq -c '
    def v:
      if (.error? != null) then "capture-failed"
      elif (.opaqueRatio < 0.5) then "transparent-not-drawn"
      elif (.distinctColorBuckets <= 2) then "flat-single-colour"
      elif (.lumaStdDev < 3) then "nearly-empty"
      elif (.distinctColorBuckets < 12) then "sparse"
      else "drawn" end;
    { verdict: v, opaqueRatio, nearWhiteRatio, meanLuma, lumaStdDev,
      distinctColorBuckets, pixels }'
}

shot_window() { # shot_window <name> <windowid>
  local name="$1" winid="$2"
  local png="$RUN/shots/$name.png"
  rm -f "$png"
  screencapture -x -o -l "$winid" "$png" >/dev/null 2>&1
  if [ ! -s "$png" ]; then
    echo '{"verdict":"capture-failed","error":"screencapture-failed"}'
  else
    verdict_for "$png"
  fi
}

# MARK: - window discovery

windows_json() { probe windows "$APP_PID" --all; }

# A window that never laid out stays in the list at 0x0 with onscreen=false —
# that is itself the failure signature, so it must not be filtered out here.
window_by_name() { # window_by_name <substring>
  windows_json | jq -c --arg n "$1" \
    '[.windows[] | select(.name | contains($n))]
     | sort_by(-(.w * .h)) | .[0] // {}'
}

# The CG window list reports a brand-new window as 0x0 for a moment before its
# frame settles, and screencapture -l already works at that point. So: wait for
# a positive size, require it to be stable for two polls, and only fall back to
# the degenerate entry when no real size ever appears (which is the failure).
wait_window() { # wait_window <substring> <timeout-ticks>
  local sub="$1" ticks="$2" candidate="{}" previous="$RUN/.prev-window.json"
  rm -f "$previous"
  for _ in $(seq 1 "$ticks"); do
    candidate="$(window_by_name "$sub")"
    local area
    area="$(echo "$candidate" | jq -r '((.w // 0) * (.h // 0)) // 0')"
    if [ "$area" -gt 0 ] 2>/dev/null; then
      if [ -f "$previous" ] && cmp -s "$previous" <(echo "$candidate"); then
        echo "$candidate"
        return 0
      fi
      echo "$candidate" > "$previous"
    fi
    sleep 0.2
  done
  # No stable size: report what was found (possibly a 0x0 window) so the
  # failure is visible instead of silently timing out.
  echo "$(window_by_name "$sub")"
}

# MARK: - main-thread health

sample_health() { # sample_health -> json
  local raw="$RUN/sample.raw"
  rm -f "$raw"
  # `sample` can block forever if the OS decides to raise a Developer Tools
  # authorization prompt; alarm() bounds it, and the run continues without it.
  perl -e 'alarm 25; exec @ARGV' /usr/bin/sample "$APP_PID" 1 -file "$raw" >/dev/null 2>&1
  if [ ! -s "$raw" ]; then
    echo '{"verdict":"sample-unavailable","note":"sample did not return (authorization prompt, SIP, or sandbox)"}'
    return
  fi
  probe classify "$raw"
}

evaluate_model() { # evaluate_model <label> <windowjson>
  local label="$1" win="$2"
  local id name
  id="$(echo "$win" | jq -r '.id // empty')"
  if [ -z "$id" ]; then
    add_result "$(jq -n --arg l "$label" '{window:$l, appeared:false, verdict:"no-window"}')"
    say "$label: NO WINDOW appeared"
    RESULT="fail"
    return
  fi
  name="$(echo "$win" | jq -r '.name // ""')"
  local shot verdict width height
  width="$(echo "$win" | jq -r .w)"
  height="$(echo "$win" | jq -r .h)"
  shot="$(shot_window "$label" "$id")"
  if [ "$(echo "$shot" | jq -r .verdict)" = "capture-failed" ] && { [ "$width" = "0" ] || [ "$height" = "0" ]; }; then
    shot="$(echo "$shot" | jq -c '. + {verdict:"zero-sized-window-never-laid-out"}')"
  fi
  verdict="$(echo "$shot" | jq -r '.verdict')"
  local onscreen size
  onscreen="$(echo "$win" | jq -r '.onscreen')"
  size="$(echo "$win" | jq -r '"\(.w)x\(.h)"')"
  say "$label: window id=$id onscreen=$onscreen size=$size name=$name"
  say "  capture: $shot"
  local health
  health="$(sample_health)"
  say "  main-thread: $(echo "$health" | jq -c '{verdict,idleFrames,layoutFrames,deepestFrame}')"
  local ax
  ax="$(probe axhealth "$APP_PID" "$name" 2>/dev/null || echo '{"found":false}')"
  say "  ax: $ax"
  add_result "$(jq -n --arg l "$label" --argjson w "$win" --argjson s "$shot" --argjson h "$health" --argjson a "$ax" \
    '{window:$l, appeared:true, id:$w.id, onscreen:$w.onscreen, width:$w.w, height:$w.h,
     capture:$s, mainThread:$h, ax:$a}')"
  case "$verdict" in
    drawn) ;;
    *) RESULT="fail" ;;
  esac
  case "$(echo "$health" | jq -r '.verdict')" in
    thrashing-in-layout|not-in-event-loop) RESULT="fail" ;;
    responsive-idle|responsive-busy) ;;
    *) [ "$RESULT" = "pass" ] && RESULT="inconclusive" ;;
  esac
}

# MARK: - driving the UI

# Clicks the status item and waits for the popover's buttons to become
# reachable. A click toggles the popover, so a click on a still-open popover
# closes it: the loop retries and reports what it saw either way.
#
# A synthetic CGEvent click lands on the topmost window under the pointer, so a
# screen-capture overlay, a window-manager strip or any window above the
# menu-bar level receives it instead and the status item never opens. That is an
# environment problem, not an app defect: the second path below AXPresses the
# same AXMenuBarItem, which never goes through hit-testing.
#
# Per attempt: click -> poll 10 x 0.2 s -> AXPress -> poll 10 x 0.2 s. Only when
# the click lost does the function ask `probe obstructors` what is above the
# status item.
#
# The returned JSON is the found-element object plus
#   method: "synthetic-click" | "AXPress" | "failed"
#   obstructed: bool, obstruction: the raw `probe obstructors` report
# A command substitution runs in a subshell, so the method has to travel back in
# the JSON itself - a global assignment inside open_popover would be lost.
POPOVER_OBSTRUCTION='{"obstructed":false}'
popover_covered() { [ "$(echo "$POPOVER_OBSTRUCTION" | jq -r '.obstructed // false' 2>/dev/null)" = "true" ]; }
popover_coverer() { echo "$POPOVER_OBSTRUCTION" | jq -c '(.windows // []) | sort_by(-.layer) | .[0] // {}'; }

# Tags the result object with the path that opened it and the obstruction report.
popover_tag() { # popover_tag <found-json> <method> <obstruction-json>
  local found="$1" method="$2" obstruction="$3"
  echo "$found" | jq -c --arg m "$method" --argjson o "$obstruction" \
    '. + {method:$m, obstructed:($o.obstructed // false), obstruction:$o}'
}

open_popover() {
  local item x y found attempt method checked=0 obstruction='{"obstructed":false}' coverer
  item="$(probe statusitem "$APP_PID")"
  if [ "$(echo "$item" | jq -r '.found')" != "true" ]; then
    say "status item is not exposed through AX"
    popover_tag '{}' "failed" "$obstruction"
    return 1
  fi
  x="$(echo "$item" | jq -r '.centerX')"
  y="$(echo "$item" | jq -r '.centerY')"
  for attempt in 1 2 3; do
    probe click "$x" "$y" >/dev/null
    method="synthetic-click"
    for _ in $(seq 1 10); do
      found="$(probe find "$APP_PID" "隧道配置")"
      if [ "$(echo "$found" | jq -r '.found')" = "true" ]; then
        popover_tag "$found" "$method" "$obstruction"
        return 0
      fi
      sleep 0.2
    done
    # First click failure only: is something sitting above the status item? One
    # check is enough (an overlay does not move between attempts), and it lands
    # exactly when the click path is known to have lost.
    if [ "$checked" -eq 0 ]; then
      checked=1
      obstruction="$(probe obstructors "$APP_PID" 2>/dev/null)"
      [ -n "$obstruction" ] || obstruction='{"obstructed":false}'
      POPOVER_OBSTRUCTION="$obstruction"
      coverer="$(popover_coverer)"
      if popover_covered; then
        say "  status item is covered by a full-screen overlay (pid=$(echo "$coverer" | jq -r '.pid') owner=$(echo "$coverer" | jq -r '.owner') layer=$(echo "$coverer" | jq -r '.layer') bounds=$(echo "$coverer" | jq -r '.bounds')); falling back to AXPress"
      else
        say "  no window covers the status item; falling back to AXPress anyway"
      fi
    else
      say "  popover not visible after click $attempt"
    fi
    # AXPress the status item itself: the element the click aimed at, but
    # activated through AX, so an overlay can no longer intercept it.
    probe pressitem "$APP_PID" >/dev/null 2>&1
    method="AXPress"
    for _ in $(seq 1 10); do
      found="$(probe find "$APP_PID" "隧道配置")"
      if [ "$(echo "$found" | jq -r '.found')" = "true" ]; then
        popover_tag "$found" "$method" "$obstruction"
        return 0
      fi
      sleep 0.2
    done
    say "  popover not visible after AXPress either (attempt $attempt)"
    # A leftover popover from an earlier run can swallow the next click; Escape
    # dismisses it without touching any app window.
    probe key 53 >/dev/null 2>&1
    sleep 0.4
  done
  say "popover never exposed its buttons (synthetic click and AXPress both failed)"
  POPOVER_OBSTRUCTION="$obstruction"
  popover_tag '{}' "failed" "$obstruction"
  return 1
}

# Clicks a popover button and returns once its window exists. A synthetic mouse
# click is the primary path; AXPress is the fallback for the case where the
# popover dismissed itself before the click landed.
open_window_via_button() { # open_window_via_button <button title> <window title substring>
  local button="$1" window="$2" target x y found
  target="$(probe find "$APP_PID" "$button")"
  if [ "$(echo "$target" | jq -r '.found')" != "true" ]; then
    say "button '$button' not found in the popover"
    echo "{}"
    return
  fi
  x="$(echo "$target" | jq -r '.centerX')"
  y="$(echo "$target" | jq -r '.centerY')"
  probe click "$x" "$y" >/dev/null
  found="$(wait_window "$window" 24)"
  if [ "$(echo "$found" | jq -r '.id // empty')" = "" ]; then
    say "  click did not open '$window'; retrying with AXPress"
    probe press "$APP_PID" "$button" >/dev/null
    found="$(wait_window "$window" 24)"
  fi
  echo "$found"
}

# MARK: - controls: prove the capture path itself is sound

run_controls() {
  say "-- screenshot controls (same technique, windows that are known to be fine) --"
  for mode in element offorder occluded; do
    local log="$RUN/control-$mode.log"
    "$PROBE" control "$mode" > "$log" 2>&1 &
    local cpid=$!
    local winid=""
    for _ in $(seq 1 24); do
      winid="$(awk -F= '/^WINID=/{print $2}' "$log" 2>/dev/null)"
      [ -n "$winid" ] && break
      sleep 0.25
    done
    if [ -z "$winid" ]; then say "control $mode: no window id"; kill "$cpid" 2>/dev/null; continue; fi
    sleep 0.5
    local shot
    shot="$(shot_window "control-$mode" "$winid")"
    say "control $mode (winid $winid): $shot"
    add_result "$(jq -n --arg m "$mode" --argjson s "$shot" '{control:$m, capture:$s}')"
    kill "$cpid" 2>/dev/null
    wait "$cpid" 2>/dev/null
  done
}

# MARK: - run

if [ "$CONTROL" -eq 1 ]; then run_controls; fi

CAN_DRIVE=0
POPOVER_METHOD="skipped"
if [ "$AX_TRUSTED" = "true" ]; then
  POPOVER="$(open_popover)"
  POPOVER_METHOD="$(echo "$POPOVER" | jq -r '.method // "failed"')"
  POPOVER_OBSTRUCTION="$(echo "$POPOVER" | jq -c '.obstruction // {"obstructed":false}')"
  if [ "$(echo "$POPOVER" | jq -r '.found')" = "true" ]; then
    CAN_DRIVE=1
    if [ "$POPOVER_METHOD" = "AXPress" ]; then
      say "popover:   opened via AXPress (click was swallowed), buttons reachable at $(echo "$POPOVER" | jq -r '[.centerX,.centerY] | join(",")')"
    else
      say "popover:   opened via synthetic-click, buttons reachable at $(echo "$POPOVER" | jq -r '[.centerX,.centerY] | join(",")')"
    fi
  else
    # Both paths failed. If a window above the status item swallowed the click,
    # that is the environment, not the app - report it as such.
    if popover_covered; then
      coverer="$(echo "$POPOVER_OBSTRUCTION" | jq -c '(.windows // []) | sort_by(-.layer) | .[0] // {}')"
      say "ENV: status item click is being swallowed by $(echo "$coverer" | jq -r '.owner') (layer $(echo "$coverer" | jq -r '.layer'))"
      say "popover:   could not open — the status item is covered, UI automation is impossible here"
      RESULT="inconclusive"
      add_result "$(jq -cn --argjson o "$coverer" --argjson all "$POPOVER_OBSTRUCTION" \
        '{error:"click-swallowed-by-overlay", owner:$o.owner, layer:$o.layer, pid:$o.pid, bounds:$o.bounds, obstructors:$all}')"
    else
      say "popover:   could not open"
      add_result '{"error":"popover-stuck","detail":"status item click and AXPress both failed to open the popover"}'
    fi
    POPOVER_METHOD="failed"
  fi
else
  say "popover:   skipped — this process is not accessibility-trusted"
  say "           (System Events would fail with -25211; see README for the --open-<window> hook)"
fi

if [ "$CAN_DRIVE" -eq 0 ]; then
  say "-- without UI automation the model is still checkable headlessly --"
  # Diagnostics belong on stderr: on stdout they would corrupt the --json report.
  env "${LAUNCH_ENV[@]}" "$APPBIN" --smoke-test 2>&1 | sed 's/^/smoke: /' >&2
  RESULT="inconclusive"
elif [ "$WANT" = "logs" ] || [ "$WANT" = "both" ]; then
  # Check the log window first: it exercises the same popover path but has no
  # table, so a config failure cannot mask it.
  evaluate_model "logs" "$(open_window_via_button "隧道日志" "隧道日志")"
fi

if [ "$CAN_DRIVE" -eq 1 ] && { [ "$WANT" = "config" ] || [ "$WANT" = "both" ]; }; then
  # Showing a window closes the popover, so reopen it for the second check.
  if [ "$(probe find "$APP_PID" "隧道配置" | jq -r '.found')" != "true" ]; then
    # stderr is left alone here: open_popover itself explains method / obstruction.
    REOPEN="$(open_popover)"
    POPOVER_METHOD="$(echo "$REOPEN" | jq -r '.method // "failed"')"
    POPOVER_OBSTRUCTION="$(echo "$REOPEN" | jq -c '.obstruction // {"obstructed":false}')"
    if [ "$(echo "$REOPEN" | jq -r '.found')" = "true" ]; then
      say "popover:   reopened via $POPOVER_METHOD for the config window"
    else
      say "popover:   could not be reopened after the previous window (app may be wedged)"
      # AXPress bypasses the overlay, so an overlay alone cannot explain this:
      # report it as context, not as the cause, and keep the original verdict.
      if [ "$(echo "$REOPEN" | jq -r '.obstructed')" = "true" ]; then
        coverer="$(echo "$POPOVER_OBSTRUCTION" | jq -c '(.windows // []) | sort_by(-.layer) | .[0] // {}')"
        say "           (the status item is also covered by $(echo "$coverer" | jq -r '.owner') layer $(echo "$coverer" | jq -r '.layer'), but AXPress failed too)"
      fi
      add_result '{"error":"popover-stuck","detail":"status item click no longer opens the popover"}'
      RESULT="fail"
    fi
  fi
  evaluate_model "config" "$(open_window_via_button "隧道配置" "隧道配置")"
fi

if [ "$CAN_DRIVE" -eq 1 ]; then
  LOGSCAN="$(probe logscan "$APP_PID")"
  say "log:       $LOGSCAN"
  add_result "$(jq -n --argjson l "$LOGSCAN" '{logscan:$l}')"
fi

say ""
say "result:    $RESULT"
if [ "$JSON" -eq 1 ]; then
  jq -cn --arg result "$RESULT" --arg app "$APPBIN" --argjson pid "$APP_PID" \
    --arg artifacts "$WORK" --argjson checks "$REPORT" \
    --arg method "$POPOVER_METHOD" --argjson obstruction "$POPOVER_OBSTRUCTION" \
    '{result:$result, app:$app, pid:$pid, artifacts:$artifacts,
      popover:{method:$method, obstructed:($obstruction.obstructed // false),
               windows:($obstruction.windows // [])},
      checks:$checks}'
fi

case "$RESULT" in
  pass) exit 0 ;;
  inconclusive) exit 2 ;;
  *) exit 1 ;;
esac
