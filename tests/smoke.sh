#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/tunnel-checker.sh"
bash -n "$ROOT/install.sh"
[[ "$($ROOT/tunnel-checker.sh --version)" == "0.2.0" ]]
! grep -q 'openssh-client' "$ROOT/tunnel-checker.sh"

export NO_COLOR=1
export TUNNEL_CHECKER_SOURCE_ONLY=1
# shellcheck source=../tunnel-checker.sh
source "$ROOT/tunnel-checker.sh"

sample_ping="$(mktemp)"
sample_mtr="$(mktemp)"
sample_err="$(mktemp)"
stale_pid="$(mktemp)"
trap 'rm -f "$sample_ping" "$sample_mtr" "$sample_err" "$sample_err.err" "$stale_pid"' EXIT

cat >"$sample_ping" <<'PING'
50 packets transmitted, 50 received, 0% packet loss, time 9820ms
rtt min/avg/max/mdev = 45.120/47.250/55.800/2.430 ms
PING
[[ "$(parse_ping "$sample_ping")" == "0|47.250|2.430" ]]
[[ "$(status_rtt 85)" == GOOD ]]
[[ "$(combine_status GOOD WARN)" == WARN ]]

ROLE=iran
set_peer_role
[[ "$(forward_label)" == "IRAN->FOREIGN" ]]
[[ "$(reverse_label)" == "FOREIGN->IRAN" ]]

PEER_IP=203.0.113.10
cat >"$sample_mtr" <<'MTR'
  1.|-- 192.0.2.1       70.0% 20 1.0 1.0 1.0 1.0 0.0
  2.|-- 203.0.113.10     0.0% 20 80.0 80.0 79.0 82.0 0.5
MTR
[[ "$(mtr_dest_loss "$sample_mtr")" == "0.0" ]]

cat >"$sample_err" <<'JSON'
{"error":"the server is busy running a test"}
JSON
[[ "$(iperf_error "$sample_err")" == "the server is busy running a test" ]]

original_pid_file=$PID_FILE
PID_FILE=$stale_pid
printf '%s\n' "$$" >"$PID_FILE"
! server_running
PID_FILE=$original_pid_file

TEST_MODE=full
PING_FWD_LOSS=0.1
PING_FWD_AVG=85
PING_FWD_MDEV=3
LOAD_UP_DELTA=5
LOAD_DOWN_DELTA=8
UDP_MAX_FWD_LOSS=0.1
UDP_MAX_REV_LOSS=0.2
UDP_MAX_FWD_JITTER=2
UDP_MAX_REV_JITTER=3
TCP_SINGLE_FWD=55
TCP_SINGLE_REV=52
TCP_PAR_FWD=55
TCP_PAR_REV=52
EXPECTED_MBPS=50
PMTU_VALUE=1500
MTR_ICMP_LOSS=0
MTR_TCP_LOSS=0
MTR_UDP_LOSS=0
IFACE_RX_ERR_DELTA=0
IFACE_TX_ERR_DELTA=0
IFACE_DROP_RATE=0
[[ "$(compute_score)" == "100|EXCELLENT|HIGH" ]]

TCP_SINGLE_FWD=""
[[ "$(compute_score)" == "N/A|INCOMPLETE|LOW" ]]

printf '%s\n' 'Smoke tests passed.'
