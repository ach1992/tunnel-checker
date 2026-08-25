#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/tunnel-checker.sh"
bash -n "$ROOT/install.sh"

export TUNNEL_CHECKER_SOURCE_ONLY=1
# shellcheck source=../tunnel-checker.sh
source "$ROOT/tunnel-checker.sh"

sample_ping="$(mktemp)"
stale_pid="$(mktemp)"
trap 'rm -f "$sample_ping" "$stale_pid"' EXIT
cat >"$sample_ping" <<'PING'
50 packets transmitted, 50 received, 0% packet loss, time 9820ms
rtt min/avg/max/mdev = 45.120/47.250/55.800/2.430 ms
PING

parsed="$(parse_ping "$sample_ping")"
[[ "$parsed" == "0|47.250|2.430" ]]
[[ "$(combine_status GOOD WARN)" == WARN ]]
[[ "$(combine_status WARN BAD)" == BAD ]]

original_pid_file=$PID_FILE
PID_FILE=$stale_pid
printf '%s\n' "$$" >"$PID_FILE"
! server_running
PID_FILE=$original_pid_file

TEST_MODE=full
PING_FWD_LOSS=0.1
PING_FWD_MDEV=3
LOAD_UP_DELTA=5
LOAD_DOWN_DELTA=8
UDP_MAX_FWD_LOSS=0.1
UDP_MAX_REV_LOSS=0.2
UDP_MAX_FWD_JITTER=2
UDP_MAX_REV_JITTER=3
TCP_PAR_FWD=55
TCP_PAR_REV=52
EXPECTED_MBPS=50
PMTU_VALUE=1500
IFACE_RX_ERR_DELTA=0
IFACE_TX_ERR_DELTA=0
IFACE_RX_DROP_DELTA=0
IFACE_TX_DROP_DELTA=0
[[ "$(compute_score)" == "100|EXCELLENT" ]]

PING_FWD_LOSS=2.5
PING_FWD_MDEV=25
LOAD_UP_DELTA=100
LOAD_DOWN_DELTA=80
UDP_MAX_FWD_LOSS=3
UDP_MAX_REV_LOSS=5
UDP_MAX_FWD_JITTER=30
UDP_MAX_REV_JITTER=40
TCP_PAR_FWD=12
TCP_PAR_REV=4
EXPECTED_MBPS=50
PMTU_VALUE=1280
IFACE_RX_ERR_DELTA=1
IFACE_RX_DROP_DELTA=2
score_result="$(compute_score)"
score="${score_result%%|*}"
verdict="${score_result#*|}"
(( score < 55 ))
[[ "$verdict" == "POOR" ]]

printf '%s\n' 'Smoke tests passed.'
