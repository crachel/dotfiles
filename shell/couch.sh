#!/bin/bash
# couch: keep strawn (:3004 on the mini, over tailscale) and the backends its browser code calls
# forwarded to the same ports here, across laptop sleep and wifi changes.
#
#   couch          run in the foreground; ctrl-c to stop
#   couch status   say what each service on the mini is doing, and whether a tunnel is up
#
# Reconnects by itself. ssh's per-connection "channel N: open failed" lines are silenced, because a
# browser retrying one dead backend prints hundreds of them; instead each service is checked on the
# mini directly and a line is printed only when its state changes.
set -u

HOST=${COUCH_HOST:-mini}
SERVICES="strawn:3004 api:8000 rig:8080 flow:3002"
POLL_SECONDS=15
MAX_BACKOFF=30
PIDFILE="${TMPDIR:-/tmp}/couch.pid"

ssh_pid="" watch_pid="" sleep_pid=""

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

# Prints "<port> <curl exit code>" per service, as seen from the mini, so the answer doesn't depend on
# the tunnel. Any HTTP response counts as up; 404 from a bare / is still a server answering.
probe() {
  local ports="" s
  for s in $SERVICES; do ports="$ports ${s#*:}"; done
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none -o LogLevel=ERROR "$HOST" \
    "for p in$ports; do curl -s -o /dev/null -m 8 http://localhost:\$p/; echo \"\$p \$?\"; done" 2>/dev/null
}

describe() {
  case $1 in
    0) echo up ;;
    7) echo "not running" ;;
    28) echo "NOT ANSWERING: accepted the connection, no reply within 8s" ;;
    *) echo "DROPPING CONNECTIONS: listening but resetting them, likely wedged" ;;
  esac
}

name_of() {
  local s
  for s in $SERVICES; do
    [ "${s#*:}" = "$1" ] && { echo "${s%:*}"; return; }
  done
}

watch_health() {
  local out port rc var state
  while :; do
    if out=$(probe) && [ -n "$out" ]; then
      while read -r port rc; do
        var="seen_$port"
        # Compare the description, not the code: a wedged server alternates between curl 55 and 56.
        state=$(describe "$rc")
        if [ "${!var:-}" != "$state" ]; then
          printf -v "$var" '%s' "$state"
          log "$(name_of "$port") :$port $state"
        fi
      done <<<"$out"
    fi
    sleep "$POLL_SECONDS"
  done
}

running_pid() {
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -o command= -p "$pid" | grep -q couch && echo "$pid"
}

status() {
  local pid out port rc
  if pid=$(running_pid); then echo "tunnel: running (pid $pid)"; else echo "tunnel: not running"; fi
  if ! out=$(probe) || [ -z "$out" ]; then
    echo "$HOST: unreachable over ssh"
    return 1
  fi
  while read -r port rc; do
    printf '%-7s :%-5s %s\n' "$(name_of "$port")" "$port" "$(describe "$rc")"
  done <<<"$out"
}

# ssh reports a taken port as a bare bind failure; say who has it, since retrying can't fix that.
report_taken_ports() {
  local s port owner
  for s in $SERVICES; do
    port=${s#*:}
    owner=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" (pid "$2")"}')
    [ -n "$owner" ] && log "local :$port is already taken by $owner"
  done
}

cleanup() {
  trap - INT TERM HUP EXIT
  if [ -n "$watch_pid" ]; then
    local kids
    kids=$(pgrep -P "$watch_pid")
    kill "$watch_pid" 2>/dev/null
    # shellcheck disable=SC2086  # one pid per word
    [ -n "$kids" ] && kill $kids 2>/dev/null
  fi
  [ -n "$ssh_pid" ] && kill "$ssh_pid" 2>/dev/null
  [ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null
  rm -f "$PIDFILE"
  log "stopped"
  exit 0
}

run() {
  local pid forwards="" s port delay=1 started rc ran
  if pid=$(running_pid); then
    echo "couch is already running (pid $pid); try: couch status" >&2
    exit 1
  fi
  echo $$ >"$PIDFILE"
  trap cleanup INT TERM HUP EXIT

  for s in $SERVICES; do
    port=${s#*:}
    forwards="$forwards -L $port:localhost:$port"
  done

  watch_health &
  watch_pid=$!
  disown "$watch_pid"

  while :; do
    report_taken_ports
    log "connecting to $HOST"
    started=$SECONDS
    # shellcheck disable=SC2086  # $forwards is meant to split into separate -L flags
    ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 \
      -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ControlPath=none -o LogLevel=ERROR \
      -o PermitLocalCommand=yes -o "LocalCommand=date '+%%H:%%M:%%S  tunnel up'" \
      $forwards "$HOST" </dev/null &
    ssh_pid=$!
    wait "$ssh_pid"
    rc=$?
    ssh_pid=""
    ran=$((SECONDS - started))

    # A tunnel that held for a while dropped for a new reason, so start the backoff over.
    [ "$ran" -ge 60 ] && delay=1
    log "tunnel down (ssh exit $rc after ${ran}s); retrying in ${delay}s"
    sleep "$delay" &
    sleep_pid=$!
    wait "$sleep_pid"
    sleep_pid=""
    delay=$((delay * 2))
    [ "$delay" -gt "$MAX_BACKOFF" ] && delay=$MAX_BACKOFF
  done
}

case ${1:-} in
  "") run ;;
  status) status ;;
  *)
    echo "usage: couch [status]" >&2
    exit 2
    ;;
esac
