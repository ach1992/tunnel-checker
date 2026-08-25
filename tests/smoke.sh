#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/tunnel-checker.sh"
bash -n "$ROOT/install.sh"
[[ "$(bash "$ROOT/tunnel-checker.sh" --version)" == "0.4.0" ]]

grep -Fq 'server-pair readiness tester' "$ROOT/PROJECT-SPEC.md"
grep -Fq 'tested pair, direction, and ports' "$ROOT/README.md"
grep -Fq 'protocol-specific filtering may differ' "$ROOT/tunnel-checker.sh"
grep -Fq 'TRY ANOTHER SERVER' "$ROOT/README.md"
grep -Fq 'if [ "$(id -u)" -eq 0 ]; then bash;' "$ROOT/README.md"
grep -Fq 'sudo is unavailable' "$ROOT/README.md"
grep -Fq 'SUDO_USER' "$ROOT/install.sh"
grep -Fq 'Run: tunnel-checker' "$ROOT/install.sh"
grep -Fq 'Run: sudo tunnel-checker' "$ROOT/install.sh"
! grep -Eq '(^|[[:space:]])mtr([[:space:]]|$)' "$ROOT/tunnel-checker.sh"
! grep -Eq '(^|[[:space:]])tracepath([[:space:]]|$)' "$ROOT/tunnel-checker.sh"
! grep -Eq 'iperf3[[:space:]]+-c' "$ROOT/tunnel-checker.sh"
! grep -q 'mtr-tiny' "$ROOT/install.sh"
! grep -q 'iputils-tracepath' "$ROOT/install.sh"
! grep -q 'jq' "$ROOT/install.sh"
grep -q 'socat' "$ROOT/install.sh"
grep -Fq 'GOOD|EXCELLENT|USE|HIGH|RUNNING|READY' "$ROOT/tunnel-checker.sh"
grep -Fq 'LEGACY_SERVER_LOG="$LOG_DIR/iperf3.log"' "$ROOT/tunnel-checker.sh"
grep -Fq 'LEGACY_TCP_LOG="$LOG_DIR/tcp-diag.log"' "$ROOT/tunnel-checker.sh"
grep -Fq 'LEGACY_UDP_LOG="$LOG_DIR/udp-diag.log"' "$ROOT/tunnel-checker.sh"

export NO_COLOR=1
export TUNNEL_CHECKER_SOURCE_ONLY=1
# shellcheck source=../tunnel-checker.sh
source "$ROOT/tunnel-checker.sh"

ROLE=iran
set_peer_role
[[ "$(forward_label)" == "IRAN->FOREIGN" ]]
[[ $UDP_PACKET_BYTES -eq 1200 ]]

banner_out="$({ ip(){ printf '%s\n' '1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.55 uid 0'; }; banner; })"
grep -Fq 'Fast server-pair tunnel readiness' <<<"$banner_out"
grep -Fq 'Repo: https://github.com/ach1992/tunnel-checker' <<<"$banner_out"
grep -Fq 'Local IPv4: 192.0.2.55' <<<"$banner_out"
while IFS= read -r line; do [[ ${#line} -eq 90 ]]; done < <(grep -E '^[+|]' <<<"$banner_out")

TEST_MODE=readiness
EXPECTED_MBPS=50
PING_LOSS=0
PING_RTT=85
PING_VAR=1
TCP_STATE=HEALTHY
TCP_BYTES_SENT=3125000
TCP_BYTES_RECV=3125000
TCP_MBPS=50
UDP_SENT=20
UDP_RECV=20
UDP_PROBE_LOSS=0
UDP_BULK_SENT=240000
UDP_BULK_RECV=240000
UDP_BULK_LOSS=0
UDP_LOSS=0
PMTU_VALUE=1500
IFACE_PACKETS=5000
IFACE_ERRORS=0
IFACE_DROPS=0
IFACE_DROP_RATE=0
compute_score
[[ $FINAL_SCORE -eq 100 ]]
[[ $FINAL_VERDICT == EXCELLENT ]]
[[ $FINAL_CONFIDENCE == HIGH ]]
[[ $FINAL_RECOMMENDATION == USE ]]
[[ "$(signal_state_udp)" == GOOD ]]

TCP_STATE=STALL
TCP_BYTES_RECV=8192
TCP_MBPS=""
compute_score
[[ $FINAL_SCORE -le 49 ]]
[[ $FINAL_VERDICT == POOR ]]
[[ $FINAL_CONFIDENCE == HIGH ]]
[[ $FINAL_RECOMMENDATION == 'TRY ANOTHER SERVER' ]]
grep -Fq 'Sustained TCP data stalled' <<<"$FINAL_REASON"

TCP_STATE=HEALTHY
TCP_BYTES_RECV=$TCP_BYTES_SENT
TCP_MBPS=50
UDP_RECV=0
UDP_PROBE_LOSS=100
UDP_BULK_LOSS=""
UDP_LOSS=100
compute_score
[[ $FINAL_SCORE -le 69 ]]
[[ $FINAL_VERDICT == CAUTION ]]
[[ $FINAL_RECOMMENDATION == CAUTION ]]
[[ "$(signal_state_udp)" == BAD ]]

UDP_RECV=20
UDP_PROBE_LOSS=0
UDP_BULK_LOSS=12
UDP_LOSS=12
compute_score
[[ $FINAL_SCORE -le 69 ]]
[[ $FINAL_RECOMMENDATION == CAUTION ]]
[[ "$(signal_state_udp)" == BAD ]]

TEST_MODE=quick
PING_LOSS=0
PING_RTT=85
PING_VAR=1
TCP_STATE=HEALTHY
TCP_MBPS=50
UDP_SENT=5
UDP_RECV=5
UDP_PROBE_LOSS=0
UDP_BULK_SENT=0
UDP_BULK_RECV=0
UDP_BULK_LOSS=""
UDP_LOSS=0
PMTU_VALUE=""
IFACE_PACKETS=1000
IFACE_ERRORS=0
IFACE_DROPS=0
IFACE_DROP_RATE=0
compute_score
[[ $FINAL_CONFIDENCE == MEDIUM ]]
[[ "$(payload_bytes)" == 262144 ]]

TEST_MODE=readiness
EXPECTED_MBPS=50
[[ "$(payload_bytes)" == 3125000 ]]
EXPECTED_MBPS=1000
[[ "$(payload_bytes)" == 8388608 ]]

printf '%s\n' 'Smoke tests passed.'
