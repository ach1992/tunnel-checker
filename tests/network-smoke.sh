#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v socat >/dev/null
command -v ss >/dev/null

export NO_COLOR=1
export TUNNEL_CHECKER_SOURCE_ONLY=1
# shellcheck source=../tunnel-checker.sh
source "$ROOT/tunnel-checker.sh"

WORK=$(mktemp -d)
TCP_WRAPPER=""
UDP_WRAPPER=""
cleanup_network(){
  [[ -n $TCP_WRAPPER ]] && kill "$TCP_WRAPPER" 2>/dev/null || true
  [[ -n $UDP_WRAPPER ]] && kill "$UDP_WRAPPER" 2>/dev/null || true
  [[ -n $TCP_WRAPPER ]] && wait "$TCP_WRAPPER" 2>/dev/null || true
  [[ -n $UDP_WRAPPER ]] && wait "$UDP_WRAPPER" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup_network EXIT

# All listener processes belong to this test user, so privileged inspection is unnecessary.
root(){ "$@"; }

port_free(){
  local port=$1
  [[ -z $(ss -ltnH "sport = :$port" 2>/dev/null || true) && -z $(ss -lunH "sport = :$((port+1))" 2>/dev/null || true) ]]
}
BASE=""
for _ in $(seq 1 50); do
  candidate=$((20000 + RANDOM % 30000))
  if ((candidate < 65534)) && port_free "$candidate"; then BASE=$candidate; break; fi
done
[[ -n $BASE ]]

STATE_DIR="$WORK/state"
LOG_DIR="$WORK/log"
mkdir -p "$STATE_DIR" "$LOG_DIR"
PORT_FILE="$STATE_DIR/target.port"
TCP_PID_FILE="$STATE_DIR/target-tcp.pid"
UDP_PID_FILE="$STATE_DIR/target-udp.pid"
TCP_LOG="$LOG_DIR/target-tcp.log"
UDP_LOG="$LOG_DIR/target-udp.log"
printf '%s\n' "$BASE" >"$PORT_FILE"

timeout --signal=TERM 30 socat "TCP4-LISTEN:$BASE,reuseaddr,fork" EXEC:/bin/cat >"$TCP_LOG" 2>&1 &
TCP_WRAPPER=$!
printf '%s\n' "$TCP_WRAPPER" >"$TCP_PID_FILE"
timeout --signal=TERM 30 socat "UDP4-RECVFROM:$((BASE+1)),reuseaddr,fork" EXEC:/bin/cat >"$UDP_LOG" 2>&1 &
UDP_WRAPPER=$!
printf '%s\n' "$UDP_WRAPPER" >"$UDP_PID_FILE"

for _ in $(seq 1 50); do
  if listener_running tcp && listener_running udp; then break; fi
  sleep 0.1
done
listener_running tcp
listener_running udp
socket_busy tcp "$BASE"
socket_busy udp "$((BASE+1))"

TMP_DIR="$WORK/client"
mkdir -p "$TMP_DIR"
PEER_IP=127.0.0.1
TEST_PORT=$BASE
UDP_PORT=$((BASE+1))
TEST_MODE=readiness
EXPECTED_MBPS=10

tcp_data_test
[[ $TCP_STATE == HEALTHY ]]
[[ $TCP_BYTES_RECV -eq $TCP_BYTES_SENT ]]
udp_data_test 20
[[ $UDP_REFUSED -eq 0 ]]
[[ $UDP_RECV -eq 20 ]]
[[ $UDP_BULK_SENT -eq 240000 ]]
[[ $UDP_BULK_RECV -eq $UDP_BULK_SENT ]]
[[ $UDP_LOSS == 0.00 ]]

# Once the TCP listener is gone, a localhost refusal must not be classified as a bad path.
TCP_CHILD=$(child_pid_matching "$TCP_WRAPPER" "TCP4-LISTEN:$BASE" || true)
[[ -n $TCP_CHILD ]] && kill "$TCP_CHILD" 2>/dev/null || true
kill "$TCP_WRAPPER" 2>/dev/null || true
wait "$TCP_WRAPPER" 2>/dev/null || true
TCP_WRAPPER=""
for _ in $(seq 1 30); do
  socket_busy tcp "$BASE" || break
  sleep 0.1
done
! socket_busy tcp "$BASE"
rm -rf "$TMP_DIR"; TMP_DIR="$WORK/refused"; mkdir -p "$TMP_DIR"
tcp_data_test >/dev/null
[[ $TCP_STATE == REFUSED ]]

printf '%s\n' 'Network smoke tests passed.'
