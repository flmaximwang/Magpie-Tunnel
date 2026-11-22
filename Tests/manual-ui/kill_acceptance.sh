#!/bin/bash
#
# Force-quit acceptance for the menu-bar app.
#
# A SIGKILLed app cannot run its own cleanup, so this run checks the daemon's
# owner watchdog instead: <lock-dir>/daemon.owner names the app PID, the daemon
# polls it every 2 s, and when the owner dies it must take every ssh child down,
# write `down|<epoch>|守护退出` to each status file and exit. Relaunching the same
# bundle with the same arguments must then rebuild everything under a NEW daemon.
#
# Exit codes: 0 pass, 1 a check failed, 3 environment problem.
#
# Usage:
#   Tests/manual-ui/kill_acceptance.sh [--app <bundle>] [--keep] [--json]
#
# Isolation: the bundle is copied into a temp dir and every path it uses
# (config, status, logs, lock, mock ssh) lives inside that directory. Every
# process lookup is anchored to that directory's absolute path, never to a bare
# name such as `mock-ssh`: a global pattern also matches the production app and
# the other isolated instances running on this machine, and a false match either
# kills a stranger or fails this run for nothing.
#
# The mock ssh differs from ui_acceptance.sh's copy on purpose. That one is a
# plain `exit 1`, enough to render a `down` row; this run has to reach `up`, so
# the mock binds the -L local port the daemon probes, and exits on SIGTERM the
# way a real ssh does.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APP="${REPO}/dist/Magpie-WebUI-Tunnel.app"
KEEP=0
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done

# Diagnostics go to stderr, so --json keeps stdout parseable.
say() { echo "$@" >&2; }

RESULT="pass"
REPORT="[]"
CHECKS=0
FAILS=0
CLEANED=0
WORK=""
APP_PID=""
APP_PID_2=""

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

# MARK: - environment

[ -d "$APP" ] || { echo "ENV: app bundle not found: $APP" >&2; exit 3; }
APP_BIN_SRC="$APP/Contents/MacOS/MagpieTunnelStatus"
[ -x "$APP_BIN_SRC" ] || { echo "ENV: executable not found: $APP_BIN_SRC" >&2; exit 3; }
for tool in jq nc codesign ps; do
  command -v "$tool" >/dev/null || { echo "ENV: '$tool' not found" >&2; exit 3; }
done

TMPBASE="${TMPDIR:-/tmp}"
TMPBASE="${TMPBASE%/}"
WORK="$(mktemp -d "$TMPBASE/magpie-kill-accept.XXXXXX")"
RUN="$WORK/run"
APPDIR="$RUN/App.app"
APPBIN="$APPDIR/Contents/MacOS/MagpieTunnelStatus"
N1="kill-one"
N2="kill-two"

# MARK: - process lookups

# Every process whose command line contains <pattern>, one pid per line.
#
# Callers pass absolute paths inside this run's temp dir on purpose. Matching a
# bare `mock-ssh` would also select /tmp/ac5, /tmp/ac6, /tmp/ac7 and the user's
# production daemon; cleanup driven by such a match kills other people's
# tunnels. The matcher tools themselves are excluded because the pattern string
# appears in their own argv. Shells are NOT excluded: the mock ssh is a bash
# script, so `ps` reports it as `/bin/bash <work>/mock-ssh -N …` and dropping
# every `bash` would hide the very children this script is looking for.
pids_matching() {
  local pattern="$1"
  ps -axww -o pid=,command= | awk -v pat="$pattern" '
    {
      pid = $1
      cmd = $0
      sub(/^[ \t]*[0-9]+[ \t]+/, "", cmd)
      if (index(cmd, pat) == 0) next
      base = cmd
      sub(/[ \t].*/, "", base)
      n = split(base, parts, "/")
      if (n > 0 && (parts[n] == "awk" || parts[n] == "ps" || parts[n] == "grep" ||
                    parts[n] == "pgrep" || parts[n] == "egrep" || parts[n] == "fgrep" ||
                    parts[n] == "sed" || parts[n] == "comm" || parts[n] == "sort" ||
                    parts[n] == "head" || parts[n] == "cut" || parts[n] == "tr")) next
      print pid
    }'
}

app_pids()    { pids_matching "$APPBIN"; }
daemon_pids() { pids_matching "$APPDIR/Contents/MacOS/magpie-tunneld"; }
# Only the ssh children carry `mock-ssh -N`; the app and the daemon pass
# `--ssh-bin <mock-ssh>` and must not be counted here.
ssh_pids()    { pids_matching "$RUN/mock-ssh -N"; }

line_count() { # line_count <newline-separated list>
  local n
  n="$(printf '%s\n' "$1" | grep -c . || true)"
  echo "${n:-0}"
}

instance_pids() { # every pid belonging to this run, one line
  { app_pids; daemon_pids; ssh_pids; } | grep . || true
}

no_instance_processes() {
  [ -z "$(app_pids)" ] && [ -z "$(daemon_pids)" ] && [ -z "$(ssh_pids)" ]
}

pid_alive() { kill -0 "$1" 2>/dev/null; }

# MARK: - status files

status_line() { # status_line <target name>
  local f="$RUN/status/$1"
  [ -f "$f" ] || return 0
  head -1 "$f" | tr -d '\n'
}
status_state()  { status_line "$1" | cut -d'|' -f1; }
status_detail() { status_line "$1" | cut -d'|' -f3-; }

both_up_on_expected_ports() {
  [ "$(status_state "$N1")" = "up" ] &&
  [ "$(status_state "$N2")" = "up" ] &&
  [ "$(status_detail "$N1")" = "port=$P1" ] &&
  [ "$(status_detail "$N2")" = "port=$P2" ]
}

both_down_shutdown() {
  [ "$(status_state "$N1")" = "down" ] &&
  [ "$(status_state "$N2")" = "down" ] &&
  [ "$(status_detail "$N1")" = "守护退出" ] &&
  [ "$(status_detail "$N2")" = "守护退出" ]
}

wait_until() { # wait_until <seconds> <predicate>
  local limit="$1" predicate="$2" start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    if "$predicate"; then return 0; fi
    sleep 0.25
  done
  "$predicate"
}

# MARK: - sandbox

mkdir -p "$RUN/status" "$RUN/logs" "$RUN/lock" "$RUN/shots"

# A local port nobody is listening on. `nc -z` is a plain connect to
# 127.0.0.1: refused instantly when free, accepted when already taken.
port_free() { ! nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }
pick_port() { # pick_port <port to avoid>
  local avoid="${1:-}" base=$((15000 + ($$ % 3000))) i candidate
  for i in $(seq 0 80); do
    candidate=$((base + i))
    [ "$candidate" != "$avoid" ] || continue
    if port_free "$candidate"; then echo "$candidate"; return 0; fi
  done
  return 1
}
P1="$(pick_port ""    )" || { echo "ENV: no free local port for tunnel 1" >&2; exit 3; }
P2="$(pick_port "$P1" )" || { echo "ENV: no free local port for tunnel 2" >&2; exit 3; }

cat > "$RUN/targets.conf" <<CONF
# Isolated force-quit configuration: unreachable host, no real credentials.
$N1|$P1|ubuntu@example.invalid|443|
$N2|$P2|ubuntu@example.invalid|8080|
CONF

cat > "$RUN/mock-ssh" <<'MOCK'
#!/bin/bash
# Mock ssh: accepts the daemon's hardened argument list
#   -N -o … -L 127.0.0.1:<local>:127.0.0.1:<remote> <target>
# and holds <local> open so the daemon probes it and writes up|…|port=<local>.
set -u
local_port=""
while [ $# -gt 0 ]; do
  case "$1" in
    -L)
      [ $# -ge 2 ] || { echo "mock-ssh: -L without value" >&2; exit 2; }
      spec="$2"
      case "$spec" in
        127.0.0.1:*:127.0.0.1:*)
          local_port="${spec#127.0.0.1:}"
          local_port="${local_port%%:*}" ;;
        *) echo "mock-ssh: unexpected -L spec: $spec" >&2; exit 2 ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$local_port" ] || { echo "mock-ssh: no -L 127.0.0.1:<port>:… argument" >&2; exit 2; }
# -k keeps listening: the daemon probes the port repeatedly, and a single accept
# would flip the tunnel back to down.
/usr/bin/nc -k -l 127.0.0.1 "$local_port" >/dev/null 2>&1 &
listener=$!
cleanup() { kill -TERM "$listener" 2>/dev/null || true; }
trap 'cleanup; exit 0' TERM INT HUP
trap cleanup EXIT
wait "$listener" 2>/dev/null || true
MOCK
chmod +x "$RUN/mock-ssh"

cp -R "$APP" "$APPDIR"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.maxim.magpie-web-tunnel.uitest.killaccept" \
  "$APPDIR/Contents/Info.plist" >/dev/null 2>&1 || say "WARN: could not rewrite CFBundleIdentifier"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Magpie-KillAcceptance" \
  "$APPDIR/Contents/Info.plist" >/dev/null 2>&1 || true
codesign --force --sign - "$APPDIR" >/dev/null 2>&1 || say "WARN: ad-hoc signing failed"
[ -x "$APPBIN" ] || { echo "ENV: copied executable missing: $APPBIN" >&2; exit 3; }

LAUNCH_ENV=(
  "MAGPIE_TUNNEL_CONFIG=$RUN/targets.conf"
  "MAGPIE_TUNNEL_STATUS_DIR=$RUN/status"
  "MAGPIE_TUNNEL_LOG_DIR=$RUN/logs"
  "MAGPIE_TUNNEL_LOCK_DIR=$RUN/lock"
  "MAGPIE_TUNNEL_SSH_BIN=$RUN/mock-ssh"
)

launch_app() { # launch_app <log file> -> sets APP_PID
  local logfile="$1" pidfile="$RUN/app.pid"
  # Direct exec, not `open -n -a`: `open` hands back no pid, and this script has
  # to SIGKILL the exact process it started. The launch happens inside a
  # short-lived subshell so the app is not this script's job: a background job
  # that gets SIGKILLed makes bash print "Killed: 9" into the middle of the
  # output, and an unreaped child would keep answering kill -0 after death.
  (
    env "${LAUNCH_ENV[@]}" "$APPBIN" \
      --config "$RUN/targets.conf" \
      --status-dir "$RUN/status" \
      --log-dir "$RUN/logs" \
      --lock-dir "$RUN/lock" \
      --ssh-bin "$RUN/mock-ssh" \
      --refresh-interval 2 \
      >> "$logfile" 2>&1 &
    echo $! > "$pidfile"
  )
  APP_PID="$(cat "$pidfile")"
}

wait_app_dead() { # wait_app_dead <seconds> <pid>
  local limit="$1" pid="$2" start=$SECONDS
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    pid_alive "$pid" || return 0
    sleep 0.2
  done
  ! pid_alive "$pid"
}

cleanup() {
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  trap - EXIT INT TERM
  local pid
  for pid in ${APP_PID} ${APP_PID_2}; do
    [ -n "$pid" ] || continue
    pid_alive "$pid" || continue
    kill -TERM "$pid" 2>/dev/null || true
    wait_app_dead 5 "$pid" || kill -KILL "$pid" 2>/dev/null || true
  done
  # Last resort: anything still carrying this run's absolute paths.
  for pid in $(daemon_pids) $(ssh_pids); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.4
  for pid in $(daemon_pids) $(ssh_pids); do
    kill -KILL "$pid" 2>/dev/null || true
  done
  if [ "$RESULT" = "pass" ] && [ "$KEEP" -eq 0 ]; then
    rm -rf "$WORK"
  else
    say "artifacts kept in $WORK"
  fi
}
trap cleanup EXIT INT TERM

# Both local ports free means no orphaned listener survived the kill. The mock
# ssh is a bash wrapper around nc, so nc's argv carries no path this run can
# match; a listener orphaned by a failed cleanup is only visible through the
# port it still holds.
ports_released() { port_free "$P1" && port_free "$P2"; }

ports_of() { # ports_of <pids> -> the -L local ports they were started with
  local pid args
  for pid in $1; do
    args="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    echo "$args" | sed -n 's/.*-L 127\.0\.0\.1:\([0-9][0-9]*\):127\.0\.0\.1:[0-9]*.*/\1/p'
  done | sort -n | tr '\n' ' '
}
expected_ports() { printf '%s\n' "$P1" "$P2" | sort -n | tr '\n' ' '; }

# MARK: - run

say ""
say "-- 1. sandbox --"
say "sandbox:   $WORK"
say "app:       $APPDIR (copy of $APP, ad-hoc signed)"
say "config:    $N1 -> 127.0.0.1:$P1, $N2 -> 127.0.0.1:$P2"
say "mock ssh:  $RUN/mock-ssh (binds the -L port, exits on SIGTERM)"
say "paths:     status=$RUN/status logs=$RUN/logs lock=$RUN/lock"

say ""
say "-- 2. launch --"
launch_app "$RUN/app-1.log"
if pid_alive "$APP_PID"; then
  pass "app launched (pid $APP_PID)"
else
  fail "app exited during launch (pid $APP_PID, see $RUN/app-1.log)"
fi

say ""
say "-- 3. wait for both tunnels to report up (max 15 s) --"
if wait_until 15 both_up_on_expected_ports; then
  say "  $N1: $(status_line "$N1")"
  say "  $N2: $(status_line "$N2")"
  pass "both tunnels reached up|…|port=<local> within 15 s"
else
  say "  $N1: $(status_line "$N1")"
  say "  $N2: $(status_line "$N2")"
  fail "tunnels did not both reach up|…|port=<local> within 15 s"
fi

say ""
say "-- 4. snapshot of the live instance --"
DAEMON_PID_1="$(head -1 "$RUN/lock/daemon.owner" 2>/dev/null | cut -d'|' -f1 || true)"
OWNER_APP_1="$(head -1 "$RUN/lock/daemon.owner" 2>/dev/null | cut -d'|' -f2 || true)"
SSH_PIDS_1="$(ssh_pids | sort -n)"
SSH_COUNT_1="$(line_count "$SSH_PIDS_1")"
SSH_PORTS_1="$(ports_of "$SSH_PIDS_1")"
say "daemon pid:   $DAEMON_PID_1 (lock/daemon.owner records app pid $OWNER_APP_1)"
say "ssh pids:     $(echo "$SSH_PIDS_1" | tr '\n' ' ')"
say "ssh -L ports: $SSH_PORTS_1"
say "lock dir:     $(ls -A "$RUN/lock" 2>/dev/null | tr '\n' ' ')"
if [ -n "$DAEMON_PID_1" ] && pid_alive "$DAEMON_PID_1"; then
  pass "daemon.owner names a live daemon (pid $DAEMON_PID_1)"
else
  fail "daemon.owner names no live daemon (got '$DAEMON_PID_1')"
fi
if [ "$OWNER_APP_1" = "$APP_PID" ]; then
  pass "daemon.owner records this app as its owner (app pid $APP_PID)"
else
  fail "daemon.owner records app pid '$OWNER_APP_1', expected '$APP_PID'"
fi
if [ "$SSH_COUNT_1" -eq 2 ]; then
  pass "2 ssh children under the daemon (one per tunnel)"
else
  fail "expected 2 ssh children before the kill, found $SSH_COUNT_1"
fi
if [ "$SSH_PORTS_1" = "$(expected_ports)" ]; then
  pass "the 2 ssh children cover the configured local ports ($P1, $P2)"
else
  fail "ssh children cover '$SSH_PORTS_1', expected '$(expected_ports)'"
fi

say ""
say "-- 5. kill -9 the app (force quit) --"
kill -9 "$APP_PID" 2>/dev/null || true
if wait_app_dead 5 "$APP_PID"; then
  pass "app is gone after SIGKILL"
else
  fail "app survived SIGKILL (pid $APP_PID)"
fi

say ""
say "-- 6. daemon and ssh children must disappear (max 12 s) --"
START=$SECONDS
if wait_until 12 no_instance_processes; then
  pass "daemon and all ssh children disappeared $((SECONDS - START)) s after the SIGKILL"
else
  fail "instance processes still alive 12 s after the SIGKILL: $(instance_pids | tr '\n' ' ')"
fi
if [ -n "$DAEMON_PID_1" ] && ! pid_alive "$DAEMON_PID_1"; then
  pass "the daemon pid recorded before the kill ($DAEMON_PID_1) is gone"
else
  fail "the daemon pid recorded before the kill ($DAEMON_PID_1) is still alive"
fi
ALL_SSH_GONE=1
for pid in $SSH_PIDS_1; do
  pid_alive "$pid" && ALL_SSH_GONE=0
done
if [ "$ALL_SSH_GONE" -eq 1 ] && [ "$SSH_COUNT_1" -gt 0 ]; then
  pass "all ssh pids recorded before the kill are gone ($(echo "$SSH_PIDS_1" | tr '\n' ' '))"
else
  fail "an ssh child recorded before the kill survived: $(echo "$SSH_PIDS_1" | tr '\n' ' ')"
fi
# A leftover ssh keeps its -L port bound. The mock is a bash wrapper around nc,
# and nc's argv holds no path this run could match, so the port is what catches
# an orphaned listener that a name-based pattern would miss.
if wait_until 12 ports_released; then
  pass "local ports $P1 and $P2 are free again (no orphaned listener)"
else
  fail "a leftover listener still holds $P1 or $P2"
fi

say ""
say "-- 7. status files after the force quit --"
say "  $N1: $(status_line "$N1")"
say "  $N2: $(status_line "$N2")"
if both_down_shutdown; then
  pass "both status files say down|<epoch>|守护退出"
else
  fail "status files are not down|…|守护退出: $N1='$(status_line "$N1")' $N2='$(status_line "$N2")'"
fi
if [ ! -f "$RUN/lock/daemon.owner" ]; then
  pass "lock/daemon.owner was removed by the daemon on exit"
else
  fail "lock/daemon.owner still exists: $(head -1 "$RUN/lock/daemon.owner" | tr -d '\n')"
fi

say ""
say "-- 8. relaunch the same bundle with the same arguments --"
launch_app "$RUN/app-2.log"
APP_PID_2="$APP_PID"
say "app pid:   $APP_PID_2"
sleep 0.5
if wait_until 15 both_up_on_expected_ports; then
  say "  $N1: $(status_line "$N1")"
  say "  $N2: $(status_line "$N2")"
  pass "both tunnels came back up|…|port=<local> after the relaunch"
else
  say "  $N1: $(status_line "$N1")"
  say "  $N2: $(status_line "$N2")"
  fail "tunnels did not both come back up within 15 s of the relaunch"
fi

DAEMON_PID_2="$(head -1 "$RUN/lock/daemon.owner" 2>/dev/null | cut -d'|' -f1 || true)"
OWNER_APP_2="$(head -1 "$RUN/lock/daemon.owner" 2>/dev/null | cut -d'|' -f2 || true)"
SSH_PIDS_2="$(ssh_pids | sort -n)"
SSH_COUNT_2="$(line_count "$SSH_PIDS_2")"
SSH_PORTS_2="$(ports_of "$SSH_PIDS_2")"
say "daemon pid:   $DAEMON_PID_2 (lock/daemon.owner records app pid $OWNER_APP_2)"
say "ssh pids:     $(echo "$SSH_PIDS_2" | tr '\n' ' ')"
say "ssh -L ports: $SSH_PORTS_2"
if [ -n "$DAEMON_PID_2" ] && pid_alive "$DAEMON_PID_2" && [ "$DAEMON_PID_2" != "$DAEMON_PID_1" ]; then
  pass "the relaunched instance runs under a NEW daemon ($DAEMON_PID_1 -> $DAEMON_PID_2)"
else
  fail "daemon pid after relaunch is '$DAEMON_PID_2', expected a live pid different from '$DAEMON_PID_1'"
fi
if [ "$OWNER_APP_2" = "$APP_PID_2" ]; then
  pass "the new daemon records the new app as its owner (app pid $APP_PID_2)"
else
  fail "the new daemon records app pid '$OWNER_APP_2', expected '$APP_PID_2'"
fi
if [ "$SSH_COUNT_2" -eq 2 ]; then
  pass "2 fresh ssh children under the new daemon"
else
  fail "expected 2 ssh children after the relaunch, found $SSH_COUNT_2"
fi
if [ "$SSH_PORTS_2" = "$(expected_ports)" ]; then
  pass "the fresh ssh children cover the configured local ports ($P1, $P2)"
else
  fail "fresh ssh children cover '$SSH_PORTS_2', expected '$(expected_ports)'"
fi
if [ -z "$(comm -12 <(echo "$SSH_PIDS_1") <(echo "$SSH_PIDS_2"))" ]; then
  pass "the ssh pids are new: nothing was reused from the killed instance"
else
  fail "an ssh pid survived the kill and is in use again: $(comm -12 <(echo "$SSH_PIDS_1") <(echo "$SSH_PIDS_2") | tr '\n' ' ')"
fi

say ""
say "-- 9. kill -TERM the app (normal quit) --"
kill -TERM "$APP_PID_2" 2>/dev/null || true
if wait_app_dead 10 "$APP_PID_2"; then
  pass "app is gone after SIGTERM"
else
  fail "app survived SIGTERM"
fi
START=$SECONDS
if wait_until 12 no_instance_processes; then
  pass "daemon and all ssh children disappeared $((SECONDS - START)) s after the SIGTERM"
else
  fail "instance processes still alive 12 s after the SIGTERM: $(instance_pids | tr '\n' ' ')"
fi
if wait_until 12 ports_released; then
  pass "local ports $P1 and $P2 are free again after the clean quit"
else
  fail "a leftover listener still holds $P1 or $P2 after the clean quit"
fi
say "  $N1: $(status_line "$N1")"
say "  $N2: $(status_line "$N2")"
if both_down_shutdown; then
  pass "both status files say down|<epoch>|守护退出 after the clean quit"
else
  fail "status files after the clean quit: $N1='$(status_line "$N1")' $N2='$(status_line "$N2")'"
fi

say ""
say "-- 10. summary --"
say "checks:    $CHECKS, failed: $FAILS"
say "result:    $RESULT"
say "artifacts: $WORK"
if [ "$JSON" -eq 1 ]; then
  jq -cn --arg result "$RESULT" --arg app "$APP" --arg artifacts "$WORK" \
    --argjson checks "$REPORT" \
    --arg daemon1 "${DAEMON_PID_1:-}" --arg daemon2 "${DAEMON_PID_2:-}" \
    --argjson ssh1 "$SSH_COUNT_1" --argjson ssh2 "${SSH_COUNT_2:-0}" \
    '{result:$result, app:$app, artifacts:$artifacts, checks:$checks,
      daemon:{first:$daemon1, second:$daemon2},
      sshChildren:{first:$ssh1, second:$ssh2}}'
fi

if [ "$RESULT" = "pass" ]; then exit 0; else exit 1; fi
