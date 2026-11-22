#!/bin/bash
#
# Appearance acceptance: is the window content legible in light *and* dark mode?
#
# The app is a plain AppKit app, so its appearance follows the system. This
# script must not flip the system setting (`defaults write -g AppleInterfaceStyle`
# changes every app on the machine and would outlive the run). Instead it drives
# a *copy* of the bundle whose appearance is pinned:
#
#   light -> Info.plist NSRequiresAquaSystemAppearance = YES, then re-sign.
#            That is the old "this app does not support Dark Mode" opt-out: AppKit
#            resolves NSAppearanceNameAqua for the whole process, which is exactly
#            the rendering a user gets on a light system, and it is independent of
#            the host's current appearance.
#
#            (NSRequiresAquaSystemAppearance = NO means "supports dark mode" and
#            therefore still follows the system - measured, it does not lighten a
#            dark system. The gate is the YES value, not the NO value.)
#
#   dark  -> no plist change at all: the copy renders in whatever appearance the
#            host currently uses. On a dark host that is the dark branch. On a
#            light host there is no per-bundle switch that forces dark, and this
#            script will NOT change the system just to test it: the run reports
#            `dark: not-covered (requires manual system appearance switch)`.
#
# The window itself is opened and captured by ui_acceptance.sh's driver
# (status-item popover -> 隧道配置 -> screencapture -l), so this script only adds
# the variant bundle and the appearance verdict.
#
# Exit codes: 0 pass, 1 window not drawn / not legible in the requested
# appearance, 2 inconclusive (UI could not be driven or the branch is
# not-covered), 3 environment problem.
#
# Usage:
#   Tests/manual-ui/appearance_check.sh --appearance light
#   Tests/manual-ui/appearance_check.sh --appearance dark --out /tmp/shots
#   Tests/manual-ui/appearance_check.sh --appearance auto --json
#   Tests/manual-ui/appearance_check.sh --appearance light --app /path/to/Other.app
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APP="${REPO}/dist/Magpie-WebUI-Tunnel.app"
WANT=""
OUT=""
KEEP=0
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --appearance) WANT="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done

case "$WANT" in
  light|dark|auto) ;;
  "") echo "ENV: --appearance light|dark|auto is required" >&2; exit 3 ;;
  *) echo "ENV: --appearance must be light, dark or auto (got '$WANT')" >&2; exit 3 ;;
esac

# Diagnostics go to stderr, so --json keeps stdout parseable.
say() { echo "$@" >&2; }
fail_env() { echo "ENV: $*" >&2; exit 3; }

[ -d "$APP" ] || fail_env "app bundle not found: $APP"
APP_BIN_SRC="$APP/Contents/MacOS/MagpieTunnelStatus"
[ -x "$APP_BIN_SRC" ] || fail_env "executable not found: $APP_BIN_SRC"
for tool in jq plutil codesign screencapture; do
  command -v "$tool" >/dev/null || fail_env "'$tool' not found"
done
command -v xcrun >/dev/null || fail_env "xcrun not found (install Xcode command line tools)"

TMPBASE="${TMPDIR:-/tmp}"
TMPBASE="${TMPBASE%/}"
WORK="$(mktemp -d "$TMPBASE/magpie-appearance.XXXXXX")"
RUN="$WORK/run"
VARIANT="$RUN/App.app"
SHOTS="$WORK/shots"
mkdir -p "$RUN" "$SHOTS"

RESULT="pass"
REPORT="[]"
CHECKS=0
FAILS=0
CLEANED=0
# Set before cleanup() can ever run: an early fail_env exits through the same
# trap, and `set -u` would turn an unset name into a confusing secondary error.
SHOTS_KEPT=0
TARGET=""
DRIVER_ARTIFACTS=""

add_result() { REPORT="$(echo "$REPORT" | jq -c --argjson item "$1" '. + [$item]')"; }
pass() {
  CHECKS=$((CHECKS + 1))
  say "  PASS  $*"
  add_result "$(jq -cn --arg check "$*" '{check:$check, result:"pass"}')"
}
fail() {
  CHECKS=$((CHECKS + 1))
  FAILS=$((FAILS + 1))
  RESULT="fail"
  say "  FAIL  $*"
  add_result "$(jq -cn --arg check "$*" '{check:$check, result:"fail"}')"
}
note() {
  CHECKS=$((CHECKS + 1))
  say "  NOTE  $*"
  add_result "$(jq -cn --arg check "$*" '{check:$check, result:"not-covered"}')"
}

cleanup() {
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  trap - EXIT INT TERM
  # Screenshots are copied out at capture time (see PNG above), but a run that
  # died early may still have shots here: copy them before the temp dir goes.
  if [ -n "$OUT" ] && [ -d "$SHOTS" ] && [ "$SHOTS_KEPT" -eq 0 ]; then
    mkdir -p "$OUT"
    cp "$SHOTS"/*.png "$OUT"/ 2>/dev/null || true
  fi
  if [ "$KEEP" -eq 1 ] || [ "$RESULT" != "pass" ]; then
    say "artifacts kept in $WORK"
    [ -n "${DRIVER_ARTIFACTS:-}" ] && say "driver artifacts kept in $DRIVER_ARTIFACTS"
  else
    rm -rf "$WORK"
  fi
  if [ -n "$OUT" ] && [ -f "$OUT/${TARGET}-config.png" ]; then
    say "screenshot: $OUT/${TARGET}-config.png"
  fi
  # The driver runs with --keep (its screenshot has to survive until it is copied
  # above), so its temp dir is ours to remove -- but only after a clean pass, so a
  # failed run still has the driver's logs. Only a directory this script saw the
  # driver create -- right prefix, still a directory -- is ever touched.
  if [ "$KEEP" -eq 0 ] && [ "$RESULT" = "pass" ] && [ -n "${DRIVER_ARTIFACTS:-}" ]; then
    case "$DRIVER_ARTIFACTS" in
      "$TMPBASE"/magpie-ui-accept.*)
        if [ -d "$DRIVER_ARTIFACTS" ]; then rm -rf "$DRIVER_ARTIFACTS"; fi ;;
    esac
  fi
}
trap cleanup EXIT INT TERM

# MARK: - host appearance

# Absent key means Light; the value is Dark on a dark system. The app's window
# would follow this unless a variant bundle pins something else.
host_appearance() {
  local style
  style="$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)"
  case "$style" in
    Dark*) echo "dark" ;;
    *) echo "light" ;;
  esac
}
HOST="$(host_appearance)"
HOST_SOURCE="system"
# Test hook, mirroring ui_acceptance.sh's MAGPIE_UI_FORCE_HEADLESS: without it the
# not-covered branch is unreachable on this machine (its system really is dark),
# and an untested branch is a branch that is broken. It never changes anything
# real, it only makes the script believe the host looks different, and the run
# says so in its output and in the report.
if [ -n "${MAGPIE_APPEARANCE_HOST:-}" ]; then
  case "$MAGPIE_APPEARANCE_HOST" in
    light|dark) HOST="$MAGPIE_APPEARANCE_HOST"; HOST_SOURCE="MAGPIE_APPEARANCE_HOST" ;;
    *) fail_env "MAGPIE_APPEARANCE_HOST must be light or dark" ;;
  esac
fi
TARGET="$WANT"
[ "$TARGET" = "auto" ] && TARGET="$HOST"

# MARK: - variant bundle

cp -R "$APP" "$VARIANT" || fail_env "could not copy $APP"
BUNDLE_ID_BASE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$VARIANT/Contents/Info.plist" 2>/dev/null || echo com.maxim.magpie-web-tunnel)"
VARIANT_ID="$BUNDLE_ID_BASE.uitest.appearance"
PLIST="$VARIANT/Contents/Info.plist"

# The copy gets its own identity so LaunchServices never confuses it with the
# installed app; the helper script that drives the window does the same.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $VARIANT_ID" "$PLIST" >/dev/null 2>&1 || say "WARN: could not rewrite CFBundleIdentifier"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Magpie-Appearance" "$PLIST" >/dev/null 2>&1 || true

PLISTEFFECTIVE="host-default"
if [ "$TARGET" = "light" ]; then
  # plutil -replace inserts the key when it is missing, so no -insert branch is
  # needed. The plist is edited before signing: changing it invalidates the
  # signature, and an invalid signature makes the app fail to launch.
  plutil -replace NSRequiresAquaSystemAppearance -bool YES "$PLIST" \
    || fail_env "could not set NSRequiresAquaSystemAppearance in $PLIST"
  PLISTEFFECTIVE="$(plutil -extract NSRequiresAquaSystemAppearance raw -o - "$PLIST")"
  [ "$PLISTEFFECTIVE" = "true" ] || fail_env "NSRequiresAquaSystemAppearance did not stick (got '$PLISTEFFECTIVE')"
  PLISTEFFECTIVE="YES"
fi

codesign --force --deep -s - "$VARIANT" >/dev/null 2>&1 || say "WARN: ad-hoc signing failed"
codesign --verify --deep "$VARIANT" >/dev/null 2>&1 || say "WARN: signature does not verify"

# MARK: - capture through the existing driver

# ui_acceptance.sh already knows how to open the config window without a human
# (status item -> popover -> 隧道配置) and how to screenshot it. Reusing it keeps
# both scripts on one capture path, so a "drawn" here means the same thing as a
# "drawn" there. It copies the bundle again; the plist key travels with the copy.
DRIVER="$HERE/ui_acceptance.sh"
[ -x "$DRIVER" ] || fail_env "driver not executable: $DRIVER"

DRIVER_JSON="$RUN/driver.json"
DRIVER_LOG="$RUN/driver.log"
rm -f "$DRIVER_JSON"
say ""
say "-- capture: $DRIVER --window config (appearance=$TARGET, host=$HOST) --"
"$DRIVER" --app "$VARIANT" --window config --keep --json > "$DRIVER_JSON" 2> "$DRIVER_LOG" || true
if [ ! -s "$DRIVER_JSON" ]; then
  say "driver produced no JSON; last lines of its log:"
  tail -8 "$DRIVER_LOG" >&2
  fail_env "driver failed (see $DRIVER_LOG)"
fi
DRIVER_RESULT="$(jq -r '.result // "unknown"' "$DRIVER_JSON")"
DRIVER_ARTIFACTS="$(jq -r '.artifacts // ""' "$DRIVER_JSON")"
say "driver result: $DRIVER_RESULT (artifacts $DRIVER_ARTIFACTS)"

CAPTURE="$(jq -c '.checks[] | select(.window == "config") | .capture // empty' "$DRIVER_JSON" | head -1)"
[ -n "$CAPTURE" ] || CAPTURE='{"verdict":"no-window"}'
WINDOW_ID="$(jq -r '.checks[] | select(.window == "config") | .id // empty' "$DRIVER_JSON" | head -1)"

PNG_SRC=""
for candidate in "$DRIVER_ARTIFACTS/run/shots/config.png" "$DRIVER_ARTIFACTS/shots/config.png"; do
  [ -f "$candidate" ] && { PNG_SRC="$candidate"; break; }
done
PNG=""
if [ -n "$PNG_SRC" ]; then
  cp "$PNG_SRC" "$SHOTS/${TARGET}-config.png" && PNG="$SHOTS/${TARGET}-config.png"
  # --out means "give me the PNG": copy it now, so it survives the temp-dir
  # cleanup, and report that path instead of a directory that is about to go.
  if [ -n "$OUT" ]; then
    mkdir -p "$OUT"
    if cp "$SHOTS/${TARGET}-config.png" "$OUT/${TARGET}-config.png"; then
      PNG="$OUT/${TARGET}-config.png"
      SHOTS_KEPT=1
    fi
  fi
fi

# The driver's verdict_for() keeps only the fields its own verdict needs; the
# full statistics (nearBlackRatio in particular) come from UIProbe directly.
PROBE="$WORK/ui-probe"
xcrun swiftc -O "$HERE/UIProbe.swift" -o "$PROBE" 2>"$RUN/probe-build.log" \
  || fail_env "could not compile UIProbe.swift (see $RUN/probe-build.log)"

STATS="$CAPTURE"
if [ -n "$PNG" ]; then
  STATS="$("$PROBE" image "$PNG" 2>/dev/null || echo "$CAPTURE")"
fi
# `probe image` returns raw statistics, not a verdict, so the verdict is derived
# here with exactly ui_acceptance.sh's thresholds. That keeps "drawn" meaning the
# same thing in both scripts instead of drifting apart.
VERDICT="$(echo "$STATS" | jq -r '
  if (.error? != null) then "capture-failed"
  elif (.opaqueRatio < 0.5) then "transparent-not-drawn"
  elif (.distinctColorBuckets <= 2) then "flat-single-colour"
  elif (.lumaStdDev < 3) then "nearly-empty"
  elif (.distinctColorBuckets < 12) then "sparse"
  else "drawn" end')"
DRIVER_VERDICT="$(echo "$CAPTURE" | jq -r '.verdict // "unknown"')"
MEAN_LUMA="$(echo "$STATS" | jq -r '.meanLuma // 0')"
STDDEV="$(echo "$STATS" | jq -r '.lumaStdDev // 0')"
BUCKETS="$(echo "$STATS" | jq -r '.distinctColorBuckets // 0')"
OPAQUE="$(echo "$STATS" | jq -r '.opaqueRatio // 0')"
NEAR_WHITE="$(echo "$STATS" | jq -r '.nearWhiteRatio // 0')"
NEAR_BLACK="$(echo "$STATS" | jq -r '.nearBlackRatio // 0')"

say ""
say "-- window --"
say "id:        ${WINDOW_ID:-none}"
say "png:       ${PNG:-none}"
say "stats:     $(echo "$STATS" | jq -c '{width,height,opaqueRatio,meanLuma,lumaStdDev,distinctColorBuckets,nearWhiteRatio,nearBlackRatio}')"

# MARK: - verdicts

# Legibility is not "some pixels exist": the window has to be opaque, contain
# many distinct colours and real luminance spread (text and borders), not one
# flat fill. Measurements on this app: light 233.9 mean / 29.4 std-dev, dark
# 49.9 mean / 19.7 std-dev; a blank window is one transparent colour.
legibility_ok() {
  echo "$STATS" | jq -e '
    (.opaqueRatio >= 0.5) and
    (.distinctColorBuckets >= 24) and
    (.lumaStdDev >= 8) and
    (.width > 0) and (.height > 0)' >/dev/null 2>&1
}

# Which appearance the pixels actually show. Light windows are dominated by the
# light background (meanLuma ≥ 170 with white text fields); dark windows sit
# below 110. Anything between is not clearly either.
observed_appearance() {
  echo "$STATS" | jq -r '
    if (.meanLuma >= 170 and .nearWhiteRatio >= 0.02) then "light"
    elif (.meanLuma <= 110) then "dark"
    else "ambiguous" end'
}

say ""
say "-- 1. window drew content --"
case "$VERDICT" in
  drawn) pass "config window is drawn (verdict 'drawn', $BUCKETS colour buckets, std-dev $STDDEV)" ;;
  *)     fail "config window is not drawn (verdict '$VERDICT'), nothing to judge appearance on" ;;
esac
if legibility_ok; then
  pass "content is legible by the capture metrics (opaque $OPAQUE, std-dev $STDDEV, $BUCKETS buckets)"
else
  fail "content is not legible by the capture metrics (opaque $OPAQUE, std-dev $STDDEV, $BUCKETS buckets)"
fi
if [ "$DRIVER_RESULT" = "pass" ]; then
  pass "driver run passed (popover and window automation worked)"
elif [ "$DRIVER_RESULT" = "inconclusive" ]; then
  note "driver run was inconclusive: the UI could not be driven on this machine"
  [ "$RESULT" = "pass" ] && RESULT="inconclusive"
else
  fail "driver run reported '$DRIVER_RESULT'"
fi

say ""
say "-- 2. the window shows the requested appearance --"
OBSERVED="$(observed_appearance)"
say "requested: $TARGET (host appearance: $HOST$([ "$HOST_SOURCE" != "system" ] && echo " (simulated by $HOST_SOURCE)"), plist override: $PLISTEFFECTIVE)"
say "observed:  $OBSERVED (meanLuma $MEAN_LUMA, nearWhite $NEAR_WHITE, nearBlack $NEAR_BLACK)"

# Coverage: can this script actually put the window into TARGET's appearance?
LIGHT_COVERAGE="not-covered in this run (request --appearance light)"
DARK_COVERAGE="not-covered in this run (request --appearance dark)"
COVERED=0
if [ "$TARGET" = "light" ]; then
  LIGHT_COVERAGE="covered (NSRequiresAquaSystemAppearance=YES, independent of the host)"
  COVERED=1
elif [ "$TARGET" = "dark" ] && [ "$HOST" = "dark" ] && [ "$HOST_SOURCE" = "system" ]; then
  DARK_COVERAGE="covered (the host itself is dark; the copy follows it)"
  COVERED=1
fi

if [ "$HOST_SOURCE" != "system" ] && [ "$TARGET" = "dark" ]; then
  # The dark branch *is* the host's appearance, and this simulation only rewires
  # the decision logic -- the pixels still come from the real display, so judging
  # them would be meaningless. The light branch is host-independent (the plist key
  # forces Aqua), so it is judged normally even under a simulated host.
  note "appearance verdict skipped — host appearance was simulated by $HOST_SOURCE=$HOST"
  [ "$RESULT" = "pass" ] && RESULT="inconclusive"
  add_result "$(jq -cn --arg t "$TARGET" --arg h "$HOST" --arg src "$HOST_SOURCE" \
    '{coverage:{appearance:$t, status:"not-covered", simulatedHost:$h, source:$src}}')"
elif [ "$COVERED" -eq 1 ] && [ "$TARGET" = "$OBSERVED" ]; then
  pass "the window renders in $TARGET appearance"
elif [ "$COVERED" -eq 0 ]; then
  note "$TARGET: not-covered (requires manual system appearance switch) — the host is $HOST and no per-bundle switch forces the opposite appearance"
  [ "$RESULT" = "pass" ] && RESULT="inconclusive"
  add_result "$(jq -cn --arg t "$TARGET" --arg h "$HOST" \
    '{coverage:{appearance:$t, status:"not-covered",
       reason:("host is " + $h + "; forcing the other appearance needs a system switch")}}')"
else
  fail "requested $TARGET but the window renders as '$OBSERVED' (meanLuma $MEAN_LUMA)"
fi

say ""
say "-- 3. coverage --"
if [ "$TARGET" = "light" ]; then
  pass "light: covered — NSRequiresAquaSystemAppearance=YES pins this copy to Aqua (the light appearance)"
  say "       (the copy is independent of the host, so the check works on a light or a dark system)"
elif [ "$COVERED" -eq 1 ]; then
  pass "dark: covered — the host itself is dark, and the copy inherits the system appearance"
else
  note "dark: not-covered (requires manual system appearance switch)"
  say "       no per-bundle plist key forces Dark: NSRequiresAquaSystemAppearance=NO means"
  say "       \"supports dark mode\" and keeps following the system (measured here)."
fi

say ""
say "-- 4. summary --"
say "checks:    $CHECKS, failed: $FAILS"
say "result:    $RESULT"
say ""
say "appearance coverage:"
say "  light: $LIGHT_COVERAGE"
say "  dark:  $DARK_COVERAGE"

if [ "$JSON" -eq 1 ]; then
  jq -cn --arg result "$RESULT" --arg requested "$WANT" --arg target "$TARGET" \
    --arg host "$HOST" --arg hostSource "$HOST_SOURCE" \
    --arg observed "$OBSERVED" --arg plist "$PLISTEFFECTIVE" \
    --arg png "$PNG" --arg driver "$DRIVER_RESULT" --argjson stats "$STATS" \
    --argjson checks "$REPORT" \
    '{result:$result, appearance:{requested:$requested, target:$target,
       host:$host, hostSource:$hostSource, observed:$observed, plistOverride:$plist},
      capture:$stats, screenshot:$png, driver:$driver, checks:$checks}'
fi

case "$RESULT" in
  pass) exit 0 ;;
  inconclusive) exit 2 ;;
  *) exit 1 ;;
esac
