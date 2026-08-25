#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/tunnel-checker.sh"
bash -n "$ROOT/install.sh"
[[ "$(bash "$ROOT/tunnel-checker.sh" --version)" == "0.3.0" ]]
! grep -q 'openssh-client' "$ROOT/tunnel-checker.sh"
! grep -Eq 'nc[[:space:]].*-z' "$ROOT/tunnel-checker.sh"
! grep -q 'iperf_ok' "$ROOT/tunnel-checker.sh"
! grep -Eq 'mtr .*\$IPERF_PORT' "$ROOT/tunnel-checker.sh"
grep -q 'iperf3 protocol reachability' "$ROOT/tunnel-checker.sh"
grep -q 'TCP_DIAG_PORT' "$ROOT/tunnel-checker.sh"
grep -q 'UDP_DIAG_PORT' "$ROOT/tunnel-checker.sh"
grep -q 'api.github.com/repos/$REPO/contents/tunnel-checker.sh?ref=main' "$ROOT/tunnel-checker.sh"
grep -q 'application/vnd.github.raw+json' "$ROOT/tunnel-checker.sh"
grep -q 'api.github.com/repos/${REPO}/contents/tunnel-checker.sh?ref=main' "$ROOT/install.sh"
grep -q 'application/vnd.github.raw+json' "$ROOT/install.sh"
grep -q '^    socat$' "$ROOT/install.sh"
! grep -q 'netcat-openbsd' "$ROOT/install.sh"

export NO_COLOR=1
export TUNNEL_CHECKER_SOURCE_ONLY=1
# shellcheck source=../tunnel-checker.sh
source "$ROOT/tunnel-checker.sh"

sample_ping="$(mktemp)"
sample_mtr="$(mktemp)"
sample_err="$(mktemp)"
stale_pid="$(mktemp)"
stale_port="$(mktemp)"
fake_bin="$(mktemp -d)"
probe_tmp="$(mktemp -d)"
trap 'rm -f "$sample_ping" "$sample_mtr" "$sample_err" "$sample_err.err" "$stale_pid" "$stale_port"; rm -rf "$fake_bin" "$probe_tmp"' EXIT

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

cat >"$fake_bin/iperf3" <<'IPERF'
#!/usr/bin/env bash
printf '%s\n' '[  5] local 192.0.2.10 port 40000 connected to 203.0.113.10 port 5201'
exit 1
IPERF
chmod +x "$fake_bin/iperf3"
old_path=$PATH
PATH="$fake_bin:$PATH"
TMP_DIR=$probe_tmp
PEER_IP=203.0.113.10
IPERF_PORT=5201
NAMES=();FWD=();REV=();STATES=();RECS=();IPERF_REACHABLE=0
iperf_probe
[[ $IPERF_REACHABLE -eq 1 ]]
[[ ${NAMES[0]} == 'iperf3 protocol session' ]]
[[ ${STATES[0]} == GOOD ]]
PATH=$old_path

[[ "$(classify_tcp_continuity 524288 524288 143 0)" == HEALTHY ]]
[[ "$(classify_tcp_continuity 524288 76000 124 4)" == SUSTAINED_STALL ]]
[[ "$(classify_tcp_continuity 524288 120000 124 0)" == DEGRADED ]]
[[ "$(classify_tcp_continuity 524288 120000 1 5)" == DEGRADED ]]
[[ "$(classify_tcp_continuity 524288 0 124 10)" == UNAVAILABLE ]]

original_pid_file=$PID_FILE
original_port_file=$PORT_FILE
PID_FILE=$stale_pid
PORT_FILE=$stale_port
printf '%s\n' "$$" >"$PID_FILE"
printf '%s\n' 5201 >"$PORT_FILE"
! server_running

(
  ps(){
    if [[ ${1:-} == -p ]];then printf '%s\n' 'timeout --signal=TERM 60 iperf3 -s -p 5201'
    elif [[ ${1:-} == --ppid ]];then printf '%s\n' '4242 iperf3 iperf3 -s -p 5201'
    else command ps "$@";fi
  }
  socket_owned_by_pid(){ [[ "$1|$2|$3" == 'tcp|5201|4242' ]]; }
  server_running
  socket_owned_by_pid(){ return 1; }
  ! server_running
)

(
  socket_busy(){ return 1; }
  check_target_ports 5201 >/dev/null 2>&1
)

(
  socket_busy(){ [[ "$1|$2" == 'tcp|5201' ]]; }
  ! check_target_ports 5201 >/dev/null 2>&1
)

PID_FILE=$original_pid_file
PORT_FILE=$original_port_file

NAMES=();FWD=();REV=();STATES=();RECS=()
iface_delta '100|0|0|100|0|0' '110|0|1|110|0|0'
[[ $IFACE_PACKET_DELTA -eq 20 ]]
[[ $IFACE_SAMPLE_ADEQUATE -eq 0 ]]
[[ ${NAMES[0]} == 'Local interface packets' ]]
[[ ${STATES[0]} == N/A ]]
[[ ${STATES[1]} == N/A ]]

NAMES=();FWD=();REV=();STATES=();RECS=()
iface_delta '1000|0|0|1000|0|0' '2000|0|2|2000|0|0'
[[ $IFACE_PACKET_DELTA -eq 2000 ]]
[[ $IFACE_SAMPLE_ADEQUATE -eq 1 ]]
[[ $IFACE_DROP_RATE == 0.10000 ]]
[[ ${STATES[1]} == WARN ]]

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
IFACE_SAMPLE_ADEQUATE=1
[[ "$(compute_score)" == "100|EXCELLENT|HIGH" ]]

TCP_SINGLE_FWD=""
[[ "$(compute_score)" == "N/A|INCOMPLETE|LOW" ]]

TCP_SINGLE_REV=""
TCP_PAR_FWD=""
TCP_PAR_REV=""
TCP_PATH_CLASS=SUSTAINED_STALL
TCP_DIAG_BYTES='76000/524288 B'
UDP_MAX_FWD_LOSS=""
UDP_MAX_REV_LOSS=""
UDP_MAX_FWD_JITTER=""
UDP_MAX_REV_JITTER=""
UDP_DIAG_STATE=""
out="$(use_cases N/A INCOMPLETE)"
grep -Eq 'TCP tunnels / proxies[[:space:]]+UNSUITABLE' <<<"$out"
grep -Eq 'UDP tunnels \(e.g. WG\)[[:space:]]+UNKNOWN' <<<"$out"
grep -Eq 'Overall endpoint pair[[:space:]]+UNKNOWN' <<<"$out"

UDP_DIAG_STATE=GOOD
out="$(use_cases N/A INCOMPLETE)"
grep -Eq 'UDP tunnels \(e.g. WG\)[[:space:]]+CAUTION' <<<"$out"
UDP_DIAG_STATE=BAD
out="$(use_cases N/A INCOMPLETE)"
grep -Eq 'UDP tunnels \(e.g. WG\)[[:space:]]+UNSUITABLE' <<<"$out"

printf '%s\n' 'Smoke tests passed.'
