#!/bin/bash
# couch: keep strawn (:3004 on the mini, over tailscale) and the backends its browser code calls
# forwarded to the same ports here, across laptop sleep and wifi changes. Alongside, a SOCKS proxy on
# localhost:1337 that leaves through the aws box, for sites that insist on seeing the same IP every time.
#
#   couch              live view of the tunnel, each service and recent events; starts it if needed
#   couch status       print that once; exits 1 unless the tunnel is up
#   couch start        run in the background as a launchd agent, now and at every login
#   couch stop         stop it, and stop starting it at login
#   couch restart      restart it, e.g. after editing this file
#   couch reconnect    drop the ssh connection and dial again now, rather than wait out a dead one
#   couch logs [-f]    what changed and when; -f keeps following
#   couch run          run in the foreground instead, printing events; ctrl-c stops it (launchd runs this)
#   couch awake [8h]   keep the Mac awake (caffeinate -dimsu) that long, apart from the tunnel; off ends it
#
# One `ssh -N` holds every forward and is redialed with backoff when it drops. Next to it, each service
# is checked on the mini directly (curl over a separate ssh), so the answer doesn't depend on the
# tunnel. Both keep small state files and an event log in $STATE_DIR for the live view and status to
# read; the live view's keys signal the running copy (USR1 reconnects, USR2 checks now).
#
# The proxy is a second `ssh -N`, to $PROXY's host with -D, redialed the same way by the same running
# copy. It starts, stops and reconnects with the tunnel, but each stays up or drops on its own.
#
# ssh's per-connection "channel N: open failed" lines are silenced (LogLevel=ERROR), because a browser
# retrying one dead backend prints hundreds of them; events are logged only when something changes.
set -u

HOST=${COUCH_HOST:-mini}
# name:port forwards the mini's port to the same one here; name:local:remote forwards it to another
SERVICES=${COUCH_SERVICES:-strawn:3004 api:8000 rig:8080 flow:3002}
# host:port for the SOCKS proxy (point the browser at SOCKS v5, localhost, that port); off for none
PROXY=${COUCH_PROXY:-tailscale:1337}
[ "$PROXY" = off ] && PROXY=""
PROXY_HOST=${PROXY%:*}
PROXY_PORT=${PROXY##*:}
POLL_SECONDS=15
MAX_BACKOFF=30
AGENT=${COUCH_LABEL:-local.couch} # the launchd label
STATE_DIR=${COUCH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/couch}

PLIST="$HOME/Library/LaunchAgents/$AGENT.plist"
PIDFILE="$STATE_DIR/pid"
TUNNEL_FILE="$STATE_DIR/tunnel"
PROXY_FILE="$STATE_DIR/proxy" # the proxy's state, in the same form
LINK=tunnel                   # which of the two this copy of tunnel_loop holds: tunnel or proxy
HEALTH_FILE="$STATE_DIR/health"
LOG="$STATE_DIR/events.log"
SSH_ERR="$STATE_DIR/ssh.err"
AWAKE_FILE="$STATE_DIR/awake"
AWAKE_DEFAULT=${COUCH_AWAKE:-8h} # how long `couch awake` and the live view's a key keep the Mac up
SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

# Runs on the mini, once per check: "<port> <curl exit code> <seconds>" per service. Any HTTP response
# counts as up; 404 from a bare / is still a server answering. The curls run side by side, so one hung
# service costs 8s rather than 8s each.
# shellcheck disable=SC2016  # expanded on the mini
PROBE='for p in "$@"; do
  (t=$(curl -s -o /dev/null -m 8 -w "%{time_total}" "http://localhost:$p/"); echo "$p $? $t") &
done
wait'

NAMES=()
LPORTS=()
RPORTS=()
FORWARDS=()
for s in $SERVICES; do
  NAMES+=("${s%%:*}")
  s=${s#*:}
  LPORTS+=("${s%%:*}")
  RPORTS+=("${s##*:}")
  FORWARDS+=(-L "${s%%:*}:localhost:${s##*:}")
done
NAME_W=8 # the name column: the longest name ("tunnel" included) and two spaces
for s in "${NAMES[@]}"; do [ $((${#s} + 2)) -gt "$NAME_W" ] && NAME_W=$((${#s} + 2)); done

ssh_pid="" nap_pid="" watch_pid="" proxy_pid="" WANT_RECONNECT=0 CHECK_NOW=0

# ---- output ------------------------------------------------------------------------------------

use_color() { # fd: color when it's a terminal and NO_COLOR isn't set; COUCH_COLOR=1 forces it
  if [ -n "${COUCH_COLOR:-}" ] || { [ -t "$1" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; }; then
    BOLD=$'\e[1m' DIM=$'\e[2m' OFF=$'\e[0m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m'
  else
    BOLD="" DIM="" OFF="" RED="" GREEN="" YELLOW=""
  fi
}
use_color 1

glyph() { # kind → GLYPH
  case $1 in
    up) GLYPH="${GREEN}●${OFF}" ;;
    down) GLYPH="${RED}✕${OFF}" ;;
    warn) GLYPH="${YELLOW}▲${OFF}" ;;
    wait) GLYPH="${YELLOW}◌${OFF}" ;;
    off) GLYPH="${DIM}○${OFF}" ;;
    *) GLYPH="${DIM}·${OFF}" ;;
  esac
}

dur() { # var seconds → "45s", "3m 05s", "2h 41m", "3d 4h"
  local s=$2
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  if [ "$s" -lt 60 ]; then
    printf -v "$1" '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf -v "$1" '%dm %02ds' $((s / 60)) $((s % 60))
  elif [ "$s" -lt 86400 ]; then
    printf -v "$1" '%dh %02dm' $((s / 3600)) $((s % 3600 / 60))
  else
    printf -v "$1" '%dd %dh' $((s / 86400)) $((s % 86400 / 3600))
  fi
}

pad() { # var text width: text, then spaces out to width (counting characters; printf counts bytes)
  local n=$(($3 - ${#2}))
  [ "$n" -gt 0 ] || n=1
  printf -v "$1" '%s%*s' "$2" "$n" ""
}

fit() { # var text width: text, cut to width with an ellipsis
  if [ "${#2}" -le "$3" ] || [ "$3" -lt 2 ]; then
    printf -v "$1" '%s' "$2"
  else
    printf -v "$1" '%s…' "${2:0:$(($3 - 1))}"
  fi
}

clock_of() { printf -v "$1" '%s' "$(date -r "$2" +%H:%M 2>/dev/null)"; } # var epoch → "14:02"

# The event log is one line per change: "2026-11-14 14:02:11 <kind> <message>", where kind picks the
# glyph (up, down, warn, off, or info).
emit() { # kind message: log an event, and print it too when running in a terminal
  local line
  line="$(date '+%F %T') $1 ${*:2}"
  printf '%s\n' "$line" >>"$LOG"
  [ -t 1 ] && print_event "$line"
}

parse_event() { # log line → EV_DAY EV_TIME EV_KIND EV_MSG
  local l=$1
  EV_DAY=${l%% *} l=${l#* }
  EV_TIME=${l%% *} l=${l#* }
  EV_KIND=${l%% *} EV_MSG=${l#* }
}

print_event() { # log line → "14:02:11  ● message"
  parse_event "$1"
  glyph "$EV_KIND"
  printf '%s%s%s  %s %s\n' "$DIM" "$EV_TIME" "$OFF" "$GLYPH" "$EV_MSG"
}

day_name() { # YYYY-MM-DD today → DAY_NAME: "today", or e.g. "Thu Nov 12"
  if [ "$1" = "$2" ]; then
    DAY_NAME=today
  else
    DAY_NAME=$(date -j -f %F "$1" '+%a %b %e' 2>/dev/null) || DAY_NAME=$1
    DAY_NAME=${DAY_NAME//  / }
  fi
}

print_events() { # log lines on stdin, with the day above them whenever it changes
  local line last="" today
  today=$(date +%F)
  while IFS= read -r line; do
    parse_event "$line"
    if [ "$EV_DAY" != "$last" ]; then
      if [ -n "$last" ] || [ "$EV_DAY" != "$today" ]; then
        day_name "$EV_DAY" "$today"
        printf '%s%s%s\n' "$BOLD" "$DAY_NAME" "$OFF"
      fi
      last=$EV_DAY
    fi
    print_event "$line"
  done
}

# ---- state shared between the running copy and everything that looks at it ----------------------

save_tunnel() {
  printf 'state=%s\nsince=%s\nstarted=%s\nmode=%s\nattempt=%s\ndown_since=%s\nretry_at=%s\ndrops=%s\nreason=%s\n' \
    "$T_STATE" "$T_SINCE" "$T_STARTED" "$T_MODE" "$T_ATTEMPT" "$T_DOWN_SINCE" "$T_RETRY_AT" "$T_DROPS" "$T_REASON" \
    >"$TUNNEL_FILE.$$" && mv -f "$TUNNEL_FILE.$$" "$TUNNEL_FILE"
}

load_tunnel() { # [file, e.g. the proxy's] → T_*; returns 1 when nothing has run yet
  local k v file=${1:-$TUNNEL_FILE}
  T_STATE=none T_SINCE=0 T_STARTED=0 T_MODE="" T_ATTEMPT=0 T_DOWN_SINCE=0 T_RETRY_AT=0 T_DROPS=0 T_REASON=""
  [ -f "$file" ] || return 1
  while IFS='=' read -r k v; do
    case $k in
      state) T_STATE=$v ;;
      since) T_SINCE=$v ;;
      started) T_STARTED=$v ;;
      mode) T_MODE=$v ;;
      attempt) T_ATTEMPT=$v ;;
      down_since) T_DOWN_SINCE=$v ;;
      retry_at) T_RETRY_AT=$v ;;
      drops) T_DROPS=$v ;;
      reason) T_REASON=$v ;;
    esac
  done <"$file"
}

load_health() { # → H_CHECKED, H_REACH (ok, lost or unknown) since H_REACH_SINCE, and per service H_KEY H_SINCE H_MS
  local i tag a b c d
  H_CHECKED=0 H_REACH=unknown H_REACH_SINCE=0
  for i in "${!NAMES[@]}"; do H_KEY[i]=unknown H_SINCE[i]=0 H_MS[i]=-; done
  [ -f "$HEALTH_FILE" ] || return 1
  while read -r tag a b c d; do
    case $tag in
      checked) H_CHECKED=$a ;;
      reach) H_REACH=$a H_REACH_SINCE=$b ;;
      svc)
        for i in "${!NAMES[@]}"; do
          [ "${NAMES[i]}" = "$a" ] && H_KEY[i]=$b H_SINCE[i]=$c H_MS[i]=$d
        done
        ;;
    esac
  done <"$HEALTH_FILE"
}

running_pid() { # → the running copy's pid
  local pid=""
  [ -f "$PIDFILE" ] && read -r pid <"$PIDFILE"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -o command= -p "$pid" | grep -q couch && echo "$pid"
}

# ---- checking each service on the mini ---------------------------------------------------------

probe() { ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none -o LogLevel=ERROR "$HOST" sh -s -- "${RPORTS[@]}" <<<"$PROBE" 2>/dev/null; }

key_of() { # curl exit code → KEY
  case $1 in
    0) KEY=up ;;
    7) KEY=off ;;
    28) KEY=slow ;;
    *) KEY=wedged ;;
  esac
}

describe() { # key → SVC_KIND, SVC_TEXT, and SVC_WHY when the text needs it
  case $1 in
    up) SVC_KIND=up SVC_TEXT=up SVC_WHY="" ;;
    off) SVC_KIND=off SVC_TEXT="not running" SVC_WHY="" ;;
    slow) SVC_KIND=warn SVC_TEXT="not answering" SVC_WHY="accepted the connection, no reply within 8s" ;;
    wedged) SVC_KIND=down SVC_TEXT="dropping connections" SVC_WHY="listening but resetting them, likely wedged" ;;
    *) SVC_KIND=unknown SVC_TEXT=unknown SVC_WHY="" ;;
  esac
}

to_ms() { # curl's seconds, e.g. 0.023456 → MS=23, or - when it isn't a number
  local whole frac
  case $1 in
    "" | *[!0-9.]* | *.*.* | .* | *.) MS=- && return ;;
    *.*) whole=${1%.*} frac=${1#*.}000 ;;
    *) whole=$1 frac=000 ;;
  esac
  MS=$((10#$whole * 1000 + 10#${frac:0:3}))
}

fmt_ms() { if [ "$1" -lt 1000 ]; then MS_TEXT="${1}ms"; else MS_TEXT="$(($1 / 1000)).$(($1 % 1000 / 100))s"; fi; }

save_health() { # checked-at: what the watcher knows, for the live view and status (it's the only writer)
  local i
  {
    echo "checked $1"
    echo "reach $reach $reach_since"
    for i in "${!NAMES[@]}"; do echo "svc ${NAMES[i]} ${key[i]} ${since[i]} ${ms[i]}"; done
  } >"$HEALTH_FILE.tmp" && mv -f "$HEALTH_FILE.tmp" "$HEALTH_FILE"
}

# Runs next to the tunnel for as long as the copy that started it does.
watch_health() {
  local -a key since ms
  local i out port rc secs now fails=0 told=0 reach=unknown reach_since
  trap 'CHECK_NOW=1; [ -n "$nap_pid" ] && kill "$nap_pid" 2>/dev/null' USR1
  now=$(date +%s)
  reach_since=$now
  load_health
  for i in "${!NAMES[@]}"; do
    key[i]=unknown since[i]=$now ms[i]=-
    # A copy that stopped moments ago (a restart) knew these; keep them, so "up for 3d" survives it.
    if [ $((now - H_CHECKED)) -le $((POLL_SECONDS * 2)) ]; then key[i]=${H_KEY[i]} since[i]=${H_SINCE[i]}; fi
  done
  while kill -0 "$SUPERVISOR" 2>/dev/null; do
    CHECK_NOW=0
    if out=$(probe) && [ -n "$out" ]; then
      now=$(date +%s)
      fails=0
      [ "$reach" = ok ] || reach=ok reach_since=$now
      [ "$told" = 1 ] && told=0 && emit info "$HOST answering again"
      while read -r port rc secs; do
        for i in "${!RPORTS[@]}"; do
          [ "${RPORTS[i]}" = "$port" ] || continue
          to_ms "$secs"
          ms[i]=$MS
          key_of "$rc"
          # Compare the key, not the code: a wedged server alternates between curl 55 and 56.
          if [ "${key[i]}" != "$KEY" ]; then
            key[i]=$KEY since[i]=$now
            describe "$KEY"
            emit "$SVC_KIND" "${NAMES[i]} :${LPORTS[i]} $SVC_TEXT${SVC_WHY:+: $SVC_WHY}"
          fi
        done
      done <<<"$out"
    else
      now=$(date +%s)
      fails=$((fails + 1))
      [ "$reach" = lost ] || reach=lost reach_since=$now
      # One miss is often just the wifi coming back after sleep; say so once it persists.
      if [ "$fails" -eq 2 ]; then
        told=1
        emit warn "can't reach $HOST over ssh to check on services"
      fi
    fi
    save_health "$now"
    [ "$CHECK_NOW" = 1 ] && continue
    nap "$POLL_SECONDS"
  done
}

# ---- the tunnel --------------------------------------------------------------------------------

# Who already listens on the ports we forward. ssh reports a taken port as a bare bind failure and
# retrying can't fix it, so name the owner; usually it's another couch's tunnel.
ports_taken() {
  local args=() i cmd pid ports parent out=""
  for i in "${!LPORTS[@]}"; do args+=("-iTCP:${LPORTS[i]}"); done
  while read -r cmd pid ports; do
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null)
    parent=${parent// /}
    if [ "$cmd" = ssh ] && [ -n "$parent" ] && ps -o command= -p "$parent" 2>/dev/null | grep -q couch; then
      out="$out${out:+; }local $ports already forwarded by another couch (pid $parent)"
    else
      out="$out${out:+; }local $ports in use by $cmd (pid $pid)"
    fi
  done < <(lsof -b -w -nP -sTCP:LISTEN "${args[@]}" 2>/dev/null | awk '
    NR > 1 { n = split($9, a, ":"); k = $1 " " $2; if (!((k, a[n]) in seen)) { seen[k, a[n]] = 1; p[k] = p[k] " :" a[n] } }
    END { for (k in p) print k p[k] }')
  printf '%s' "$out"
}

# Waits for a child, riding out traps: wait returns early (over 128) whenever a trapped signal lands,
# like a reconnect or check-now request, though the child is still running. The braces keep bash from
# printing "Terminated" about a child we killed.
wait_child() { # pid → WAITED, its exit code
  local rc
  while :; do
    { wait "$1"; } 2>/dev/null
    rc=$?
    [ "$rc" -gt 128 ] && kill -0 "$1" 2>/dev/null && continue
    break
  done
  WAITED=$rc
}

nap() { # seconds; a trap can cut it short by killing nap_pid
  sleep "$1" &
  nap_pid=$!
  wait_child "$nap_pid"
  nap_pid=""
}

ssh_reason() { # ssh's exit code → REASON: the first thing it said, or what the code means
  local line=""
  [ -s "$SSH_ERR" ] && IFS= read -r line <"$SSH_ERR"
  line=${line#ssh: }
  case $line in
    "")
      if [ "$1" = 255 ]; then
        REASON="connection lost"
      elif [ "$1" -gt 128 ]; then
        REASON="ssh was killed (signal $(($1 - 128)))"
      else
        REASON="ssh exited with status $1"
      fi
      ;;
    bind*) REASON=$(ports_taken) && [ -n "$REASON" ] || REASON=$line ;;
    *) REASON=$line ;;
  esac
}

tunnel_loop() {
  local delay=1 started ran reason="" last="" taken now d lc who=""
  [ "$LINK" = tunnel ] || who="$LINK "
  # ssh runs this once its listeners are up; % would be one of its tokens
  printf -v lc '%q _up %s' "$SELF" "$LINK"
  lc=${lc//%/%%}
  # the proxy's copy has no one to stop it if the copy that started it is killed outright
  while kill -0 "$SUPERVISOR" 2>/dev/null; do
    T_ATTEMPT=$((T_ATTEMPT + 1))
    UP_SINCE=0 ran=0
    taken=$(ports_taken)
    if [ -n "$taken" ]; then
      reason=$taken
    else
      T_STATE=connecting T_SINCE=$(date +%s)
      save_tunnel
      started=$SECONDS
      ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ControlPath=none -o LogLevel=ERROR \
        -o PermitLocalCommand=yes -o "LocalCommand=$lc" \
        "${FORWARDS[@]}" "$HOST" </dev/null 2>"$SSH_ERR" &
      ssh_pid=$!
      wait_child "$ssh_pid"
      ssh_pid=""
      ran=$((SECONDS - started))
      read_up
      ssh_reason "$WAITED"
      reason=$REASON
    fi
    now=$(date +%s)

    if [ "$WANT_RECONNECT" = 1 ]; then
      WANT_RECONNECT=0 delay=1 last="" T_ATTEMPT=0 T_DOWN_SINCE=$now
      continue
    fi
    if [ "$UP_SINCE" -gt 0 ]; then
      T_DROPS=$((T_DROPS + 1)) T_ATTEMPT=0 T_DOWN_SINCE=$now
      dur d $((now - UP_SINCE))
      emit down "$LINK dropped after $d: $reason"
      last=$reason
    elif [ "$reason" != "$last" ]; then
      # the same failure again and again is one event, not one per retry
      if [ -n "$taken" ]; then emit warn "${who}can't forward: $reason"; else emit warn "${who}can't connect: $reason"; fi
      last=$reason
    fi

    # A tunnel that held for a while dropped for a new reason, so start the backoff over.
    [ "$ran" -ge 60 ] && delay=1
    T_STATE=down T_SINCE=$T_DOWN_SINCE T_REASON=$reason T_RETRY_AT=$((now + delay))
    save_tunnel
    nap "$delay"
    delay=$((delay * 2))
    [ "$delay" -gt "$MAX_BACKOFF" ] && delay=$MAX_BACKOFF
  done
}

read_up() { # → UP_SINCE: when _up marked this connection up, or 0 if it never came up
  local k v
  UP_SINCE=0
  [ -f "$TUNNEL_FILE" ] || return 0
  while IFS='=' read -r k v; do
    case $k in
      state) [ "$v" = up ] || return 0 ;;
      since) UP_SINCE=$v ;;
    esac
  done <"$TUNNEL_FILE"
}

tunnel_up() { # [proxy]: ssh's LocalCommand: every forward is listening now
  local now d
  [ "${1:-}" = proxy ] && LINK=proxy TUNNEL_FILE=$PROXY_FILE
  load_tunnel || return 0
  now=$(date +%s)
  if [ "$T_ATTEMPT" -gt 1 ]; then
    dur d $((now - T_DOWN_SINCE))
    emit up "$LINK up, after $d and $T_ATTEMPT tries"
  else
    emit up "$LINK up"
  fi
  T_STATE=up T_SINCE=$now T_REASON="" T_RETRY_AT=0
  save_tunnel
}

redial() { # drop the connection, or the wait before the next try, and dial again now
  WANT_RECONNECT=1
  [ -n "$ssh_pid" ] && kill "$ssh_pid" 2>/dev/null
  [ -n "$nap_pid" ] && kill "$nap_pid" 2>/dev/null
}

on_reconnect() {
  emit info "reconnecting, as asked"
  redial
  [ -n "$proxy_pid" ] && kill -USR1 "$proxy_pid" 2>/dev/null
}

# The proxy: tunnel_loop again, in a subshell where the proxy's host, port and files stand in for the
# tunnel's. -C because what crosses it is web pages.
proxy_loop() {
  trap redial USR1
  LINK=proxy HOST=$PROXY_HOST TUNNEL_FILE=$PROXY_FILE SSH_ERR="$STATE_DIR/proxy.err"
  LPORTS=("$PROXY_PORT") FORWARDS=(-C -D "$PROXY_PORT")
  tunnel_loop
}

on_check() { [ -n "$watch_pid" ] && kill -USR1 "$watch_pid" 2>/dev/null; }

cleanup() { # exit code: 0 when told to stop, otherwise that of the error that ended the script
  local rc=$1 kids p i=0 see="the message above"
  # launchd and `couch stop` can both send TERM; a second one mustn't cut this short
  trap '' INT TERM HUP USR1 USR2
  trap - EXIT
  for p in $watch_pid $proxy_pid; do # and what each is waiting on: a check, a nap, the proxy's ssh
    kids=$(pgrep -P "$p")
    kill "$p" 2>/dev/null
    # shellcheck disable=SC2086  # one pid per word
    [ -n "$kids" ] && kill $kids 2>/dev/null
  done
  [ -n "$nap_pid" ] && kill "$nap_pid" 2>/dev/null
  if [ -n "$ssh_pid" ]; then
    kill "$ssh_pid" 2>/dev/null
    # let it close its listeners, so a start right after this finds the ports free
    while kill -0 "$ssh_pid" 2>/dev/null && [ "$i" -lt 20 ]; do
      sleep 0.1
      i=$((i + 1))
    done
  fi
  T_STATE=stopped T_SINCE=$(date +%s)
  save_tunnel
  rm -f "$PIDFILE"
  if [ "$rc" = 0 ]; then
    emit off "stopped"
  else
    [ "$T_MODE" = launchd ] && see="$STATE_DIR/launchd.log"
    emit down "stopped by an error in couch.sh (exit $rc); see $see"
  fi
  # exiting with the error's code is what makes launchd start it again
  exit "$rc"
}

cmd_run() {
  local pid
  # Until the handlers are in place, an early reconnect or check request is ignored rather than fatal.
  trap '' USR1 USR2
  if pid=$(running_pid); then
    where_running "$pid"
    echo "couch is already running $WHERE; see: couch status" >&2
    # under launchd, a clean exit means don't restart me
    [ "${COUCH_LAUNCHD:-}" = 1 ] && exit 0
    exit 1
  fi
  mkdir -p "$STATE_DIR" || exit 1
  echo $$ >"$PIDFILE"
  trap 'cleanup 0' INT TERM HUP
  trap 'cleanup $?' EXIT
  trap on_reconnect USR1
  trap on_check USR2
  trim_log
  # A clean stop leaves "stopped" behind; anything else means the last copy was killed or crashed.
  if load_tunnel && [ "$T_STATE" != stopped ]; then
    emit warn "the last run ended without stopping cleanly (killed, or the Mac lost power?)"
  fi
  export COUCH_STATE_DIR="$STATE_DIR" # for _up, which ssh runs
  SUPERVISOR=$$
  T_MODE=foreground
  [ "${COUCH_LAUNCHD:-}" = 1 ] && T_MODE=launchd
  T_STARTED=$(date +%s)
  T_STATE=connecting T_SINCE=$T_STARTED T_DOWN_SINCE=$T_STARTED T_ATTEMPT=0 T_RETRY_AT=0 T_DROPS=0 T_REASON=""
  save_tunnel
  local socks=${PROXY:+, socks proxy on :$PROXY_PORT through $PROXY_HOST}
  if [ "$T_MODE" = launchd ]; then
    emit info "started in the background, forwarding $(port_list) from $HOST$socks"
  else
    emit info "started, forwarding $(port_list) from $HOST$socks; ctrl-c stops it"
  fi

  watch_health &
  watch_pid=$!
  disown "$watch_pid"
  if [ -n "$PROXY" ]; then
    proxy_loop &
    proxy_pid=$!
    disown "$proxy_pid"
  fi
  tunnel_loop
}

trim_log() { # past 5000 events, keep the last 2000
  local n
  [ -f "$LOG" ] || return 0
  n=$(wc -l <"$LOG")
  [ "${n// /}" -gt 5000 ] && tail -n 2000 "$LOG" >"$LOG.$$" && mv -f "$LOG.$$" "$LOG"
  return 0
}

port_list() {
  local i out=""
  for i in "${!LPORTS[@]}"; do out="$out${out:+ }:${LPORTS[i]}"; done
  echo "$out"
}

where_running() { # pid → WHERE
  load_tunnel
  if [ "$T_MODE" = launchd ]; then WHERE="in the background"; else WHERE="in the foreground (pid $1)"; fi
}

# ---- launchd -----------------------------------------------------------------------------------

job_loaded() { launchctl print "gui/$UID/$AGENT" >/dev/null 2>&1; }

xml() {
  local s=${1//&/"&amp;"}
  s=${s//</"&lt;"}
  s=${s//>/"&gt;"}
  printf '%s' "$s"
}

write_plist() {
  local v env=""
  # launchd doesn't read shell startup files, so carry over any overrides set here
  for v in COUCH_HOST COUCH_SERVICES COUCH_PROXY COUCH_LABEL; do
    [ -n "${!v:-}" ] && env="$env
		<key>$v</key>
		<string>$(xml "${!v}")</string>"
  done
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- written by $(xml "$SELF"); \`couch stop\` removes it -->
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(xml "$AGENT")</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml "$SELF")</string>
		<string>run</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>COUCH_LAUNCHD</key>
		<string>1</string>
		<key>COUCH_STATE_DIR</key>
		<string>$(xml "$STATE_DIR")</string>$env
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$(xml "$STATE_DIR/launchd.log")</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$STATE_DIR/launchd.log")</string>
</dict>
</plist>
EOF
}

wait_unloaded() {
  local i=0
  while job_loaded && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

start_agent() { # → 0 once launchd has it; otherwise START_ERR says why not
  local taken err
  if [ "$(uname -s)" != Darwin ]; then
    START_ERR="running in the background needs launchd (macOS); try: couch run"
    return 1
  fi
  taken=$(ports_taken)
  if [ -n "$taken" ]; then
    START_ERR="can't start: $taken"
    return 1
  fi
  if ! { mkdir -p "$STATE_DIR" "${PLIST%/*}" && write_plist; }; then
    START_ERR="couldn't write $PLIST"
    return 1
  fi
  if job_loaded; then # loaded but not running, say after it gave up: load it fresh
    launchctl bootout "gui/$UID/$AGENT" 2>/dev/null
    wait_unloaded
  fi
  if ! err=$(launchctl bootstrap "gui/$UID" "$PLIST" 2>&1); then
    START_ERR="launchctl couldn't load $PLIST: $err"
    return 1
  fi
}

# Stops the running copy however it was started: launchd first, then the pidfile, which also catches
# a copy running in the foreground.
stop_running() { # → 0 if anything was running
  local pid i=0 was=1
  if [ "$(uname -s)" = Darwin ] && job_loaded; then
    launchctl bootout "gui/$UID/$AGENT" 2>/dev/null
    was=0
  fi
  if pid=$(running_pid); then
    kill "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    was=0
  fi
  return $was
}

stop_all() { # → 0 if anything was running; also removes the agent, so login won't start it again
  local was=1
  stop_running && was=0
  [ "$(uname -s)" = Darwin ] && rm -f "$PLIST"
  return $was
}

# ---- keeping the Mac awake ---------------------------------------------------------------------

# caffeinate -dimsu: the display, the idle timer and the disk stay awake, the Mac doesn't sleep on AC,
# and you count as active, until -t runs out. It runs on its own, apart from the tunnel and launchd,
# so stopping or restarting couch leaves it be. A subshell waits on it to log when its time is up;
# $AWAKE_FILE holds "<caffeinate's pid> <when it ends>" while it runs.

awake_pid() { # → AWAKE_PID and AWAKE_UNTIL of the caffeinate couch started; returns 1 if none is running
  local pid="" until=0
  AWAKE_PID="" AWAKE_UNTIL=0
  [ -f "$AWAKE_FILE" ] && read -r pid until <"$AWAKE_FILE"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  case $(ps -o comm= -p "$pid") in *caffeinate) ;; *) return 1 ;; esac
  AWAKE_PID=$pid AWAKE_UNTIL=$until
}

span_of() { # "8h", "90m", or "8" meaning hours → SPAN seconds; returns 1 for anything else
  [[ $1 =~ ^([0-9]+)([hm]?)$ ]] || return 1
  SPAN=$((10#${BASH_REMATCH[1]} * 60))
  [ "${BASH_REMATCH[2]}" = m ] || SPAN=$((SPAN * 60))
  [ "$SPAN" -gt 0 ]
}

until_text() { # var epoch → "18:30" today, otherwise "Sat 02:30"
  if [ "$(date -r "$2" +%F)" = "$(date +%F)" ]; then
    clock_of "$1" "$2"
  else
    printf -v "$1" '%s' "$(date -r "$2" '+%a %H:%M')"
  fi
}

awake_on() { # span ("8h", "90m"): keep the Mac awake that long from now, replacing an earlier one
  local until u d
  span_of "$1" || { AWAKE_ERR="couch awake takes a time like 8h, 90m or 4 (hours), or off"; return 1; }
  command -v caffeinate >/dev/null || { AWAKE_ERR="caffeinate is macOS's; there's none here"; return 1; }
  mkdir -p "$STATE_DIR" || return 1
  awake_off quiet
  until=$(($(date +%s) + SPAN))
  dur d "$SPAN"
  # Ignoring HUP and INT, which caffeinate inherits, outlives the terminal it was started from.
  (
    trap '' HUP INT
    trap - EXIT TERM WINCH
    caffeinate -dimsu -t "$SPAN" &
    pid=$!
    echo "$pid $until" >"$AWAKE_FILE"
    # only a run that ran its full time exits 0; awake_off kills it and logs that itself
    if wait "$pid"; then
      read -r k _ <"$AWAKE_FILE" 2>/dev/null && [ "$k" = "$pid" ] && rm -f "$AWAKE_FILE"
      emit off "awake time's up after $d; the Mac can sleep again"
    fi
  ) </dev/null >/dev/null 2>&1 &
  # wait (briefly) for the subshell to write down caffeinate's pid, so it shows straight away
  for _ in 1 2 3 4 5 6 7 8 9 10; do awake_pid && break; sleep 0.05; done
  until_text u "$until"
  AWAKE_SAID="keeping the Mac awake until $u ($d)"
  emit info "$AWAKE_SAID" >/dev/null
  return 0
}

awake_off() { # [quiet]: end couch's caffeinate; returns 1 if none was running
  awake_pid || return 1
  rm -f "$AWAKE_FILE" # first, so the subshell waiting on it doesn't take this for its time running out
  kill "$AWAKE_PID" 2>/dev/null
  [ "${1:-}" = quiet ] || emit off "the Mac can sleep again, as asked" >/dev/null
  return 0
}

cmd_awake() {
  case ${1:-$AWAKE_DEFAULT} in
    off | stop)
      if awake_off; then echo "the Mac can sleep again"; else echo "wasn't keeping the Mac awake"; fi
      ;;
    *)
      awake_on "${1:-$AWAKE_DEFAULT}" || { echo "couch: $AWAKE_ERR" >&2; exit 2; }
      echo "$AWAKE_SAID; couch awake off lets it sleep"
      ;;
  esac
}

# ---- what you see ------------------------------------------------------------------------------

link_row() { # name host note now pid width → ROWS: the tunnel's line or the proxy's, from T_*, and why it's down
  local name host=$2 note=$3 now=$4 pid=$5 d text indent
  if [ -z "$pid" ]; then
    glyph off
    text="not running"
  else
    case $T_STATE in
      up)
        glyph up
        dur d $((now - T_SINCE))
        text="up for $d"
        ;;
      down)
        glyph down
        dur d $((now - T_DOWN_SINCE))
        text="down for $d, retrying"
        [ "$T_RETRY_AT" -gt "$now" ] && text="$text in $((T_RETRY_AT - now))s"
        ;;
      none) # the running copy has never held this one: it predates the proxy, or was started without it
        glyph off
        text="not started; couch restart starts it"
        ;;
      *)
        glyph wait
        text="connecting to $host"
        if [ "$T_ATTEMPT" -gt 1 ]; then
          dur d $((now - T_DOWN_SINCE))
          text="$text, down for $d"
        fi
        ;;
    esac
    if [ "$T_DROPS" -gt 0 ]; then
      clock_of d "$T_STARTED"
      note="$note${note:+, }dropped ${T_DROPS}× since $d"
    fi
  fi
  pad name "$1" "$NAME_W"
  ROWS+=(" $GLYPH $BOLD$name$OFF$text${note:+$DIM · $note$OFF}")
  if [ -n "$pid" ] && [ "$T_STATE" != up ] && [ -n "$T_REASON" ]; then
    printf -v indent '%*s' $((NAME_W + 3)) ""
    fit d "$T_REASON" $(($6 - NAME_W - 4))
    ROWS+=("$indent$DIM$d$OFF")
  fi
}

# ROWS: the tunnel's line and the proxy's (and why they're down), one per service, and when they were
# checked. Leaves T_* the tunnel's.
#   $1 now, $2 the running copy's pid or "", $3 width for the long bits,
#   $4 "always" shows the checked line even when everything's fine (the live view)
build_rows() {
  local now=$1 pid=$2 i d text note="" name port label lc="" age fresh=1 stale=0 indent
  ROWS=()
  printf -v indent '%*s' $((NAME_W + 3)) ""

  if [ -n "$pid" ]; then
    if [ "$T_MODE" = launchd ]; then note="in the background"; else note="in the foreground, pid $pid"; fi
  fi
  link_row tunnel "$HOST" "$note" "$now" "$pid" "$3"
  if [ -n "$PROXY" ]; then
    load_tunnel "$PROXY_FILE"
    link_row proxy "$PROXY_HOST" "socks :$PROXY_PORT through $PROXY_HOST" "$now" "$pid" "$3"
    load_tunnel
  fi
  pad name awake "$NAME_W"
  if awake_pid; then
    glyph up
    until_text d "$AWAKE_UNTIL"
    text="until $d"
    dur d $((AWAKE_UNTIL - now))
    ROWS+=(" $GLYPH $BOLD$name$OFF$text$DIM · $d left$OFF")
  elif [ "${4:-}" = always ]; then
    glyph off
    ROWS+=(" $GLYPH $BOLD$name$OFF${DIM}no, the Mac sleeps as usual$OFF")
  fi
  [ "${4:-}" = always ] && ROWS+=("")

  age=$((now - H_CHECKED))
  # Older than a few checks means nothing is watching any more: these are only the last word.
  if [ "$H_CHECKED" -eq 0 ] || [ "$age" -gt $((POLL_SECONDS * 3 + 20)) ]; then fresh=0; fi
  # stale: nothing current to go on, so show the last word dimmed, without how long it held
  if [ "$fresh" = 0 ] || [ "$H_REACH" = lost ]; then stale=1 lc=$DIM; fi
  for i in "${!NAMES[@]}"; do
    describe "${H_KEY[i]}"
    if [ "$stale" = 1 ]; then glyph unknown; else glyph "$SVC_KIND"; fi
    label=$SVC_TEXT
    if [ "${H_KEY[i]}" = up ] && [ "${H_MS[i]}" != - ]; then
      fmt_ms "${H_MS[i]}"
      label="up · $MS_TEXT"
    fi
    text=""
    if [ "$stale" = 0 ] && [ "${H_SINCE[i]}" -gt 0 ]; then
      dur d $((now - ${H_SINCE[i]}))
      text="for $d"
      pad label "$label" 22
    fi
    pad name "${NAMES[i]}" "$NAME_W"
    pad port ":${LPORTS[i]}" 8
    ROWS+=(" $GLYPH $BOLD$name$OFF$port$lc$label$OFF$DIM$text$OFF")
  done

  if [ "$H_CHECKED" -eq 0 ]; then
    [ -n "$pid" ] && ROWS+=("$indent${DIM}checking…$OFF")
  elif [ "$H_REACH" = lost ] && [ -z "$pid" ]; then
    ROWS+=("$indent${YELLOW}can't reach $HOST over ssh$OFF")
  elif [ "$H_REACH" = lost ]; then
    clock_of d "$H_REACH_SINCE"
    ROWS+=("$indent${YELLOW}can't reach $HOST over ssh since $d$OFF$DIM; showing what it said last$OFF")
  elif [ "$fresh" = 0 ]; then
    dur d "$age"
    if [ -n "$pid" ]; then
      ROWS+=("$indent${YELLOW}last checked $d ago$OFF")
    else
      ROWS+=("$indent${DIM}last checked $d ago, while it was running$OFF")
    fi
  elif [ "${4:-}" = always ]; then
    dur d "$age"
    ROWS+=("$indent${DIM}checked $d ago$OFF")
  fi
}

probe_into_health() { # H_*, from a check made right here, for when nothing's running to ask
  local out port rc secs i
  load_health
  H_CHECKED=$(date +%s) H_REACH=lost H_REACH_SINCE=$H_CHECKED
  for i in "${!NAMES[@]}"; do H_KEY[i]=unknown H_SINCE[i]=0 H_MS[i]=-; done
  out=$(probe) && [ -n "$out" ] || return 0
  H_REACH=ok
  while read -r port rc secs; do
    for i in "${!RPORTS[@]}"; do
      [ "${RPORTS[i]}" = "$port" ] || continue
      key_of "$rc"
      to_ms "$secs"
      H_KEY[i]=$KEY H_MS[i]=$MS
    done
  done <<<"$out"
}

fresh_health() { # pid: have the running copy check now, and wait (briefly) until it has
  local t0 i=0
  t0=$(date +%s)
  kill -USR2 "$1" 2>/dev/null || return 1
  # up to 20s: when the mini doesn't answer, the check waits out ssh's 8s connect timeout
  while [ "$i" -lt 80 ]; do
    load_health
    [ "$H_CHECKED" -ge "$t0" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

wait_up() { # since seconds: wait until the tunnel is up and came up at or after since
  local i=0
  while [ "$i" -lt $(($2 * 4)) ]; do
    load_tunnel
    [ "$T_STATE" = up ] && [ "$T_SINCE" -ge "$1" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

cmd_status() {
  local pid=""
  pid=$(running_pid) || pid=""
  if [ -n "$pid" ]; then fresh_health "$pid"; else probe_into_health; fi
  load_tunnel
  build_rows "$(date +%s)" "$pid" 1000
  printf '%s\n' "${ROWS[@]}"
  [ -n "$pid" ] && [ "$T_STATE" = up ]
}

cmd_start() {
  local pid t0
  if pid=$(running_pid); then
    where_running "$pid"
    echo "already running $WHERE"
    cmd_status
    return 0
  fi
  t0=$(date +%s)
  start_agent || { echo "couch: $START_ERR" >&2; exit 1; }
  echo "started in the background; it starts at login too, until: couch stop"
  if ! wait_up "$t0" 15; then
    if running_pid >/dev/null; then
      echo "the tunnel isn't up yet; it keeps trying (couch logs shows why)"
    else
      echo "launchd hasn't run it; is couch.sh allowed under System Settings > General > Login Items?" >&2
    fi
  fi
  cmd_status
  return 0
}

cmd_stop() {
  if stop_all; then echo "stopped; it won't start at login until: couch start"; else echo "wasn't running"; fi
}

# Stops and loads the agent afresh, rewriting it on the way, so a changed path or override is picked up.
cmd_restart() {
  local pid t0 said="started in the background; it starts at login too, until: couch stop"
  if pid=$(running_pid); then
    where_running "$pid"
    if [ "$T_MODE" != launchd ]; then
      echo "couch: it's running $WHERE; restart it there" >&2
      exit 1
    fi
  fi
  t0=$(date +%s)
  stop_running && said="restarted"
  start_agent || { echo "couch: $START_ERR" >&2; exit 1; }
  echo "$said"
  wait_up "$t0" 15 || echo "the tunnel isn't up yet; it keeps trying (couch logs shows why)"
  cmd_status
  return 0
}

cmd_reconnect() {
  local pid t0
  pid=$(running_pid) || { echo "couch: not running; start it with: couch start" >&2; exit 1; }
  t0=$(date +%s)
  kill -USR1 "$pid"
  if wait_up "$t0" 20; then echo "reconnected"; else echo "not back up yet; it keeps trying (couch logs shows why)"; fi
  cmd_status
}

cmd_logs() {
  local follow=0 n=40
  while [ $# -gt 0 ]; do
    case $1 in
      -f | --follow) follow=1 ;;
      -n) n=${2:-40} && shift ;;
      -n*) n=${1#-n} ;;
      *) echo "usage: couch logs [-f] [-n count]" >&2 && exit 2 ;;
    esac
    shift
  done
  if [ "$follow" = 1 ]; then
    tail -n "$n" -F "$LOG" 2>/dev/null | print_events
  elif [ -s "$LOG" ]; then
    tail -n "$n" "$LOG" | print_events
  else
    echo "nothing yet; events go to $LOG"
  fi
}

# ---- the live view -----------------------------------------------------------------------------

flash() { # message seconds [color]: a note above the keys for a while
  FLASH="${3:-}$1${3:+$OFF}"
  FLASH_UNTIL=$(($(date +%s) + $2))
}

live_frame() {
  local now today clock pid rows cols k n line msg rule title gap last="" footer out="" verb=stop
  local -a ev shown
  set -- $(date '+%s %F %T')
  now=$1 today=$2 clock=$3
  [ -n "$LIVE_SIZE" ] || LIVE_SIZE=$(stty size 2>/dev/null) || LIVE_SIZE=""
  set -- $LIVE_SIZE
  rows=${1:-24} cols=${2:-80}
  pid=$(running_pid) || pid="" verb=start
  load_tunnel
  load_health

  title=" couch · $HOST"
  n=$((cols - ${#title} - ${#clock} - 1))
  [ "$n" -gt 0 ] || n=1
  printf -v gap '%*s' "$n" ""
  FRAME=("$BOLD couch$OFF$DIM · $HOST$OFF$gap$DIM$clock$OFF" "")
  build_rows "$now" "$pid" "$cols" always
  FRAME+=("${ROWS[@]}" "")

  # recent events: as many as fit between here and the note and keys at the bottom
  k=$((rows - ${#FRAME[@]} - 3))
  if [ "$k" -gt 0 ] && [ -s "$LOG" ]; then
    printf -v rule '%*s' $((cols - 10)) ""
    FRAME+=("$DIM recent ${rule// /─}$OFF")
    while IFS= read -r line; do ev+=("$line"); done < <(tail -n "$k" "$LOG")
    for line in ${ev[@]+"${ev[@]}"}; do
      parse_event "$line"
      if [ "$EV_DAY" != "$last" ]; then
        if [ -n "$last" ] || [ "$EV_DAY" != "$today" ]; then
          day_name "$EV_DAY" "$today"
          shown+=(" $BOLD$DAY_NAME$OFF")
        fi
        last=$EV_DAY
      fi
      glyph "$EV_KIND"
      fit msg "$EV_MSG" $((cols - 14))
      shown+=(" $DIM$EV_TIME$OFF  $GLYPH $msg")
    done
    n=${#shown[@]}
    [ "$n" -gt "$k" ] && shown=("${shown[@]:$((n - k))}")
    FRAME+=(${shown[@]+"${shown[@]}"})
  fi
  while [ "${#FRAME[@]}" -lt $((rows - 2)) ]; do FRAME+=(""); done

  if [ "$now" -lt "$FLASH_UNTIL" ]; then FRAME+=(" $FLASH"); else FRAME+=(""); fi
  if [ -n "$CONFIRM" ]; then
    footer=" ${YELLOW}stop the tunnel?$OFF  ${BOLD}y$OFF$DIM stops it, any other key keeps it$OFF"
  else
    footer=" ${BOLD}r$OFF$DIM reconnect  $OFF${BOLD}c$OFF$DIM check now  $OFF${BOLD}s$OFF$DIM $verb  $OFF"
    footer="$footer${BOLD}a$OFF$DIM awake  $OFF${BOLD}l$OFF$DIM log  $OFF${BOLD}q$OFF$DIM quit$OFF"
  fi
  for line in "${FRAME[@]}"; do out="$out$line"$'\e[K\n'; done
  printf '\e[H%s%s\e[K\e[J' "$out" "$footer"
}

# The live view draws on the alternate screen with the cursor hidden and line wrap off, so a line too
# long for a narrow window is cut at the edge instead of wrapping and scrolling the frame.
screen_on() {
  stty -echo
  printf '\e[?1049h\e[?25l\e[?7l'
}

screen_off() {
  printf '\e[?7h\e[?25h\e[?1049l'
  stty "$LIVE_STTY" 2>/dev/null
}

live_exit() {
  trap - INT TERM HUP EXIT WINCH
  screen_off
  exit 0
}

live_pager() {
  screen_off
  COUCH_COLOR=1 "$SELF" logs -n 2000 | less -R +G
  screen_on
  LIVE_SIZE=""
}

cmd_live() {
  local key pid
  if ! [ -t 0 ] || ! [ -t 1 ]; then
    cmd_status
    return
  fi
  FLASH="" FLASH_UNTIL=0 CONFIRM="" LIVE_SIZE=""
  if pid=$(running_pid); then
    kill -USR2 "$pid" 2>/dev/null # fresh checks for whoever just looked
  elif start_agent; then
    flash "started in the background; it starts at login too, until: couch stop" 10
  else
    flash "$START_ERR" 60 "$YELLOW"
  fi
  LIVE_STTY=$(stty -g)
  trap live_exit INT TERM HUP EXIT
  trap 'LIVE_SIZE=""' WINCH
  screen_on
  while :; do
    live_frame
    key=""
    IFS= read -rsn1 -t 1 key || continue
    if [ -n "$CONFIRM" ]; then
      CONFIRM=""
      [ "$key" = y ] && stop_all && flash "stopped; s starts it again" 10
      continue
    fi
    pid=$(running_pid) || pid=""
    case $key in
      q | Q) break ;;
      r | c)
        if [ -z "$pid" ]; then
          flash "not running; s starts it" 4
        elif [ "$key" = r ]; then
          kill -USR1 "$pid" && flash "reconnecting…" 3
        else
          kill -USR2 "$pid" && flash "checking…" 3
        fi
        ;;
      s)
        if [ -n "$pid" ]; then
          CONFIRM=stop
        elif start_agent; then
          flash "starting…" 4
        else
          flash "$START_ERR" 60 "$YELLOW"
        fi
        ;;
      a)
        if awake_off; then
          flash "the Mac can sleep again" 4
        elif awake_on "$AWAKE_DEFAULT"; then
          flash "$AWAKE_SAID; a again lets it sleep" 6
        else
          flash "$AWAKE_ERR" 10 "$YELLOW"
        fi
        ;;
      l) live_pager ;;
    esac
  done
}

usage() {
  local i list="" home='~'
  for i in "${!NAMES[@]}"; do list="$list${list:+, }${NAMES[i]} :${LPORTS[i]}"; done
  cat <<EOF
couch keeps $HOST's dev services forwarded here over ssh: $list
${PROXY:+and a SOCKS v5 proxy on localhost:$PROXY_PORT that leaves through $PROXY_HOST, for sites that want one IP
}
usage: couch [command]

  (none)            live view; starts the tunnel in the background if it isn't running
  status            the tunnel and each service, printed once; exits 1 unless the tunnel is up
  start             run in the background (a launchd agent), now and at every login
  stop              stop it, and stop starting it at login
  restart           restart it, e.g. after editing ${SELF/#$HOME/$home}
  reconnect         drop the ssh connection and dial again now
  logs [-f] [-n N]  recent events; -f keeps following
  run               run in the foreground instead, printing events; ctrl-c stops it
  awake [time|off]  keep the Mac awake (caffeinate -dimsu) for $AWAKE_DEFAULT, or e.g. 2h or 90m;
                    again starts the time over, off lets it sleep. Separate from the tunnel.

keys in the live view: r reconnect, c check now, s start or stop, a awake or not, l full log, q quit
state and log: ${STATE_DIR/#$HOME/$home}
COUCH_PROXY=host:port moves the proxy, COUCH_PROXY=off drops it (set it before couch start or restart)
EOF
}

case ${1:-} in
  "") cmd_live ;;
  status) cmd_status ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_restart ;;
  reconnect) cmd_reconnect ;;
  logs | log)
    shift
    cmd_logs "$@"
    ;;
  run) cmd_run ;;
  awake | caffeinate) cmd_awake "${2:-}" ;;
  _up) tunnel_up "${2:-}" ;;
  help | -h | --help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
