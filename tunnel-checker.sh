#!/usr/bin/env bash
set -uo pipefail

VERSION="0.4.0"
REPO="ach1992/tunnel-checker"
REPO_URL="https://github.com/$REPO"
INSTALL_DIR="/usr/local/lib/tunnel-checker"
INSTALL_PATH="$INSTALL_DIR/tunnel-checker.sh"
BIN_PATH="/usr/local/bin/tunnel-checker"
STATE_DIR="/var/lib/tunnel-checker"
LOG_DIR="/var/log/tunnel-checker"
ROLE_FILE="$STATE_DIR/role"
PORT_FILE="$STATE_DIR/target.port"
TCP_PID_FILE="$STATE_DIR/target-tcp.pid"
UDP_PID_FILE="$STATE_DIR/target-udp.pid"
TCP_LOG="$LOG_DIR/target-tcp.log"
UDP_LOG="$LOG_DIR/target-udp.log"
LAST_REPORT="$LOG_DIR/last-report.txt"
LEGACY_PORT_FILE="$STATE_DIR/iperf3.port"
LEGACY_PID_FILE="$STATE_DIR/iperf3.pid"
LEGACY_TCP_PID_FILE="$STATE_DIR/tcp-diag.pid"
LEGACY_UDP_PID_FILE="$STATE_DIR/udp-diag.pid"
LEGACY_SERVER_LOG="$LOG_DIR/iperf3.log"
LEGACY_TCP_LOG="$LOG_DIR/tcp-diag.log"
LEGACY_UDP_LOG="$LOG_DIR/udp-diag.log"
API_URL="https://api.github.com/repos/$REPO/contents/tunnel-checker.sh?ref=main"
RAW_URL="https://raw.githubusercontent.com/$REPO/main/tunnel-checker.sh"
CDN_URL="https://cdn.jsdelivr.net/gh/$REPO@main/tunnel-checker.sh"
DEFAULT_PORT=5201
DEFAULT_MBPS=50

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; E=$'\033[31m'; C=$'\033[36m'; BL=$'\033[34m'
else
  R=''; B=''; DIM=''; G=''; Y=''; E=''; C=''; BL=''
fi

ROLE=""; PEER_ROLE=""; PEER_HOST=""; PEER_IP=""; LOCAL_IFACE=""; LOCAL_SRC=""
TEST_PORT=$DEFAULT_PORT; UDP_PORT=$((DEFAULT_PORT+1)); EXPECTED_MBPS=$DEFAULT_MBPS; TEST_MODE=readiness; TMP_DIR=""
PING_LOSS=""; PING_RTT=""; PING_VAR=""
TCP_STATE=""; TCP_BYTES_SENT=0; TCP_BYTES_RECV=0; TCP_MBPS=""; TCP_STALLED=0
UDP_SENT=0; UDP_RECV=0; UDP_PROBE_LOSS=""; UDP_LOSS=""; UDP_PACKET_BYTES=1200; UDP_BULK_SENT=0; UDP_BULK_RECV=0; UDP_BULK_LOSS=""
PMTU_VALUE=""
IFACE_PACKETS=0; IFACE_ERRORS=0; IFACE_DROPS=0; IFACE_DROP_RATE=""
FINAL_SCORE=0; FINAL_VERDICT=""; FINAL_CONFIDENCE=""; FINAL_RECOMMENDATION=""; FINAL_REASON=""

cleanup(){ [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT
info(){ printf '%b[INFO]%b %s\n' "$C" "$R" "$*"; }
warn(){ printf '%b[WARN]%b %s\n' "$Y" "$R" "$*"; }
err(){ printf '%b[ERROR]%b %s\n' "$E" "$R" "$*" >&2; }
ok(){ printf '%b[OK]%b %s\n' "$G" "$R" "$*"; }
pause(){ [[ -r /dev/tty ]] && read -r -p "Press Enter to continue..." </dev/tty || true; }
is_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]]; }
root(){ if is_root; then "$@"; elif command -v sudo >/dev/null; then sudo "$@"; else err "Root privileges are required."; return 1; fi; }
ask(){ local p=$1 d=${2:-} v=""; [[ -r /dev/tty ]] && read -r -p "$p${d:+ [$d]}: " v </dev/tty || true; printf '%s' "${v:-$d}"; }
ask_int(){ local p=$1 d=$2 min=$3 max=$4 v; while :; do v=$(ask "$p" "$d"); [[ $v =~ ^[0-9]+$ ]] && ((v>=min && v<=max)) && { printf '%s' "$v"; return; }; warn "Enter $min-$max."; done; }
fcompare(){ awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN{if(op=="<")exit !(a<b);if(op=="<=")exit !(a<=b);if(op==">")exit !(a>b);if(op==">=")exit !(a>=b);exit 1}'; }
fmt(){ [[ -z ${1:-} ]] && printf 'N/A' || awk -v v="$1" -v d="${2:-2}" 'BEGIN{printf "%.*f",d,v}'; }
role_name(){ [[ ${1:-} == iran ]] && printf IRAN || printf FOREIGN; }
set_peer_role(){ [[ $ROLE == iran ]] && PEER_ROLE=foreign || PEER_ROLE=iran; }
forward_label(){ printf '%s->%s' "$(role_name "$ROLE")" "$(role_name "$PEER_ROLE")"; }

local_ipv4(){
  local rt ip=""
  rt=$(ip -4 route get 1.1.1.1 2>/dev/null | head -1 || true)
  ip=$(awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' <<<"$rt")
  if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/){print $i;exit}}' || true)
  fi
  printf '%s' "${ip:-N/A}"
}
header_line(){ printf '%b| %-86.86s |%b\n' "$BL$B" "$1" "$R"; }
banner(){
  printf '%b+----------------------------------------------------------------------------------------+%b\n' "$BL$B" "$R"
  header_line "Tunnel Checker v$VERSION"
  header_line "Fast server-pair tunnel readiness"
  header_line "Repo: $REPO_URL"
  printf '%b+----------------------------------------------------------------------------------------+%b\n' "$BL$B" "$R"
  if [[ -n $ROLE ]]; then
    printf ' Endpoint: %b%s%b    Local IPv4: %b%s%b    Peer: %b%s%b\n' "$B$C" "$(role_name "$ROLE")" "$R" "$B$C" "$(local_ipv4)" "$R" "$B$C" "$(role_name "$PEER_ROLE")" "$R"
    printf ' Direction: %b%s%b\n' "$B" "$(forward_label)" "$R"
  fi
}

load_role(){ ROLE=""; [[ -r $ROLE_FILE ]] && ROLE=$(tr -d '[:space:]' <"$ROLE_FILE" 2>/dev/null || true); [[ $ROLE == iran || $ROLE == foreign ]] || ROLE=""; [[ -n $ROLE ]] && set_peer_role; }
save_role(){ root mkdir -p "$STATE_DIR" >/dev/null 2>&1 || return 1; printf '%s\n' "$ROLE" | root tee "$ROLE_FILE" >/dev/null; }
choose_role(){
  [[ -r /dev/tty ]] || { err "Interactive role selection requires a terminal."; return 1; }
  while :; do
    clear 2>/dev/null || true
    printf 'Which endpoint is this server?\n\n  1) Iran server\n  2) Foreign server\n\n'
    local c; read -r -p 'Select [1-2]: ' c </dev/tty || return 1
    case $c in 1) ROLE=iran; break;; 2) ROLE=foreign; break;; *) warn "Invalid option.";; esac
  done
  set_peer_role; save_role || warn "Could not persist endpoint role."
}
ensure_role(){ load_role; [[ -n $ROLE ]] || choose_role; }

missing_packages(){
  local -a p=()
  command -v curl >/dev/null || p+=(curl)
  command -v ping >/dev/null || p+=(iputils-ping)
  command -v ip >/dev/null || p+=(iproute2)
  command -v ss >/dev/null || p+=(iproute2)
  command -v socat >/dev/null || p+=(socat)
  command -v timeout >/dev/null || p+=(coreutils)
  command -v ps >/dev/null || p+=(procps)
  command -v pkill >/dev/null || p+=(procps)
  printf '%s\n' "${p[@]}" | awk 'NF&&!s[$0]++'
}
ensure_deps(){
  local m; m=$(missing_packages); [[ -z $m ]] && return 0
  [[ -r /etc/os-release ]] || { err "Missing tools and unsupported package environment."; return 1; }
  . /etc/os-release
  [[ ${ID:-} == ubuntu || ${ID:-} == debian || ${ID_LIKE:-} == *debian* ]] || { err "Auto-install supports Debian/Ubuntu only."; return 1; }
  local a=y; [[ -r /dev/tty ]] && read -r -p "Install missing packages? [Y/n]: " a </dev/tty || true
  [[ $a =~ ^[Nn]$ ]] && return 1
  local -a p=(); while IFS= read -r x; do [[ -n $x ]] && p+=("$x"); done <<<"$m"
  root env DEBIAN_FRONTEND=noninteractive apt-get update && root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${p[@]}"
}
resolve4(){ getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
prepare(){
  ensure_role || return 1
  PEER_HOST=$(ask "$(role_name "$PEER_ROLE") peer IP/hostname" ""); [[ -n $PEER_HOST ]] || { err "Peer is required."; return 1; }
  PEER_IP=$(resolve4 "$PEER_HOST"); [[ $PEER_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { err "No usable IPv4 address."; return 1; }
  TEST_PORT=$(ask_int "Test TCP port" "$DEFAULT_PORT" 1 65534); UDP_PORT=$((TEST_PORT+1))
  EXPECTED_MBPS=$(ask_int "Expected tunnel bandwidth (Mbps)" "$DEFAULT_MBPS" 1 100000)
  local rt; rt=$(ip -4 route get "$PEER_IP" 2>/dev/null | head -1 || true)
  LOCAL_IFACE=$(awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}' <<<"$rt")
  LOCAL_SRC=$(awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' <<<"$rt")
}

parse_ping(){
  local f=$1 loss avg="" var="" r vals
  loss=$(grep -Eo '[0-9]+([.][0-9]+)?% packet loss' "$f" 2>/dev/null | tail -1 | cut -d% -f1 || true)
  r=$(grep -E '(^rtt |^round-trip ).*=.* ms' "$f" 2>/dev/null | tail -1 || true)
  if [[ -n $r ]]; then vals=$(sed -E 's/.*= *([^ ]+) ms.*/\1/' <<<"$r"); avg=$(cut -d/ -f2 <<<"$vals"); var=$(cut -d/ -f4 <<<"$vals"); fi
  printf '%s|%s|%s' "$loss" "$avg" "$var"
}
ping_test(){
  local count=$1 f="$TMP_DIR/ping.txt" p
  info "Checking packet loss and latency..."
  LC_ALL=C ping -4 -n -q -c "$count" -i .2 -W 2 "$PEER_IP" >"$f" 2>&1 || true
  p=$(parse_ping "$f"); IFS='|' read -r PING_LOSS PING_RTT PING_VAR <<<"$p"
}

payload_bytes(){
  if [[ $TEST_MODE == quick ]]; then printf '%s' 262144; return; fi
  local b=$((EXPECTED_MBPS * 62500)); ((b<524288)) && b=524288; ((b>8388608)) && b=8388608; printf '%s' "$b"
}
tcp_data_test(){
  local bytes payload out er token pid start end elapsed rc=0 last=0 current=0 stalled=0
  bytes=$(payload_bytes); payload="$TMP_DIR/tcp.payload"; out="$TMP_DIR/tcp.out"; er="$TMP_DIR/tcp.err"
  token="TC04-${RANDOM}-${RANDOM}-"
  { printf '%s' "$token"; dd if=/dev/zero bs=1024 count=$(((bytes-${#token}+1023)/1024)) status=none; } | head -c "$bytes" >"$payload"
  TCP_BYTES_SENT=$(stat -c %s "$payload")
  info "Checking sustained TCP data..."
  start=$(date +%s%3N)
  timeout 12 socat STDIO,ignoreeof "TCP4:$PEER_IP:$TEST_PORT,connect-timeout=4" <"$payload" >"$out" 2>"$er" & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    current=$(stat -c %s "$out" 2>/dev/null || printf 0)
    if ((current>last)); then stalled=0; else stalled=$((stalled+1)); fi
    last=$current
    if ((current>=TCP_BYTES_SENT)); then kill -TERM "$pid" 2>/dev/null || true; break; fi
  done
  wait "$pid" 2>/dev/null || rc=$?
  end=$(date +%s%3N); elapsed=$((end-start)); ((elapsed<1)) && elapsed=1
  TCP_BYTES_RECV=$(stat -c %s "$out" 2>/dev/null || printf 0); TCP_STALLED=$stalled
  if ((TCP_BYTES_RECV>=${#token})) && ! cmp -n "${#token}" "$payload" "$out" >/dev/null 2>&1; then TCP_BYTES_RECV=0; fi
  if ((TCP_BYTES_RECV>=TCP_BYTES_SENT)); then
    TCP_STATE=HEALTHY
    TCP_MBPS=$(awk -v b="$TCP_BYTES_RECV" -v ms="$elapsed" 'BEGIN{printf "%.2f",b*8/(ms*1000)}')
  elif ((TCP_BYTES_RECV>0 && (rc==124 || stalled>=15))); then TCP_STATE=STALL
  elif ((TCP_BYTES_RECV>0)); then TCP_STATE=DEGRADED
  else TCP_STATE=BLOCKED
  fi
}

udp_data_test(){
  local count=$1 i token payload out er good=0 pid step batch bulkout bulkerr
  info "Checking UDP data path..."
  UDP_SENT=$count
  for ((i=1;i<=count;i++)); do
    token="TU04-${i}-${RANDOM}-${RANDOM}-"
    payload="$TMP_DIR/udp-$i.payload"; out="$TMP_DIR/udp-$i.out"; er="$TMP_DIR/udp-$i.err"
    { printf '%s' "$token"; dd if=/dev/zero bs=1200 count=1 status=none; } | head -c "$UDP_PACKET_BYTES" >"$payload"
    timeout 1 socat -T1 - "UDP4-DATAGRAM:$PEER_IP:$UDP_PORT" <"$payload" >"$out" 2>"$er" & pid=$!
    for ((step=0;step<100;step++)); do
      if cmp -s "$payload" "$out" 2>/dev/null; then
        good=$((good+1))
        kill -TERM "$pid" 2>/dev/null || true
        break
      fi
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.01
    done
    wait "$pid" 2>/dev/null || true
  done
  UDP_RECV=$good
  UDP_PROBE_LOSS=$(awk -v s="$UDP_SENT" -v r="$UDP_RECV" 'BEGIN{if(s>0)printf "%.2f",100*(s-r)/s;else print "100.00"}')
  UDP_LOSS=$UDP_PROBE_LOSS

  # A small sustained sample complements the probes without turning the readiness
  # check into a bandwidth benchmark. 200 datagrams gives 0.5% loss resolution
  # while keeping target process churn and generated traffic bounded.
  if [[ $TEST_MODE == readiness && $good -gt 0 ]]; then
    UDP_BULK_SENT=$((UDP_PACKET_BYTES*200))
    bulkout="$TMP_DIR/udp-bulk.out"; bulkerr="$TMP_DIR/udp-bulk.err"
    (
      for ((batch=0;batch<20;batch++)); do
        dd if=/dev/zero bs="$UDP_PACKET_BYTES" count=10 status=none
        sleep 0.025
      done
    ) | timeout 5 socat -b"$UDP_PACKET_BYTES" STDIO "UDP4-DATAGRAM:$PEER_IP:$UDP_PORT" >"$bulkout" 2>"$bulkerr" || true
    UDP_BULK_RECV=$(stat -c %s "$bulkout" 2>/dev/null || printf 0)
    ((UDP_BULK_RECV>UDP_BULK_SENT)) && UDP_BULK_RECV=$UDP_BULK_SENT
    UDP_BULK_LOSS=$(awk -v s="$UDP_BULK_SENT" -v r="$UDP_BULK_RECV" 'BEGIN{if(s>0)printf "%.2f",100*(s-r)/s;else print "100.00"}')
    fcompare "$UDP_BULK_LOSS" '>' "$UDP_LOSS" && UDP_LOSS=$UDP_BULK_LOSS
  fi
  return 0
}

pmtu_test(){
  [[ $TEST_MODE == quick ]] && { PMTU_VALUE=""; return 0; }
  info "Checking path MTU..."
  if ping -4 -n -M do -s 1472 -c 1 -W 1 "$PEER_IP" >/dev/null 2>&1; then PMTU_VALUE=1500; return 0; fi
  local lo=1172 hi=1472 mid best=0
  while ((lo<=hi)); do
    mid=$(((lo+hi)/2))
    if ping -4 -n -M do -s "$mid" -c 1 -W 1 "$PEER_IP" >/dev/null 2>&1; then best=$mid; lo=$((mid+1)); else hi=$((mid-1)); fi
  done
  ((best>0)) && PMTU_VALUE=$((best+28)) || PMTU_VALUE=""
}

iface_stats(){
  local d=$1 x p e dr
  [[ -n $LOCAL_IFACE && -d /sys/class/net/$LOCAL_IFACE/statistics ]] || { printf '0|0|0'; return; }
  d="/sys/class/net/$LOCAL_IFACE/statistics"
  p=$(( $(cat "$d/rx_packets" 2>/dev/null || printf 0) + $(cat "$d/tx_packets" 2>/dev/null || printf 0) ))
  e=$(( $(cat "$d/rx_errors" 2>/dev/null || printf 0) + $(cat "$d/tx_errors" 2>/dev/null || printf 0) ))
  dr=$(( $(cat "$d/rx_dropped" 2>/dev/null || printf 0) + $(cat "$d/tx_dropped" 2>/dev/null || printf 0) ))
  printf '%s|%s|%s' "$p" "$e" "$dr"
}
iface_delta(){
  local before=$1 after=$2 bp be bd ap ae ad
  IFS='|' read -r bp be bd <<<"$before"; IFS='|' read -r ap ae ad <<<"$after"
  IFACE_PACKETS=$((ap-bp)); IFACE_ERRORS=$((ae-be)); IFACE_DROPS=$((ad-bd)); ((IFACE_PACKETS<0)) && IFACE_PACKETS=0
  if ((IFACE_PACKETS>0)); then IFACE_DROP_RATE=$(awk -v d="$IFACE_DROPS" -v p="$IFACE_PACKETS" 'BEGIN{printf "%.4f",100*d/p}'); else IFACE_DROP_RATE=""; fi
}

ping_points(){
  local p=0
  if [[ -n $PING_LOSS ]]; then
    if fcompare "$PING_LOSS" '<=' 0; then p=$((p+12)); elif fcompare "$PING_LOSS" '<=' .2; then p=$((p+11)); elif fcompare "$PING_LOSS" '<=' 1; then p=$((p+8)); elif fcompare "$PING_LOSS" '<=' 2; then p=$((p+5)); elif fcompare "$PING_LOSS" '<=' 5; then p=$((p+2)); fi
  fi
  if [[ -n $PING_VAR ]]; then if fcompare "$PING_VAR" '<=' 5; then p=$((p+4)); elif fcompare "$PING_VAR" '<=' 10; then p=$((p+3)); elif fcompare "$PING_VAR" '<=' 20; then p=$((p+1)); fi; fi
  if [[ -n $PING_RTT ]]; then if fcompare "$PING_RTT" '<=' 120; then p=$((p+4)); elif fcompare "$PING_RTT" '<=' 180; then p=$((p+3)); elif fcompare "$PING_RTT" '<=' 250; then p=$((p+1)); fi; fi
  printf '%s' "$p"
}
tcp_points(){
  case $TCP_STATE in
    HEALTHY)
      local p=20 ratio=0
      [[ -n $TCP_MBPS ]] && ratio=$(awk -v m="$TCP_MBPS" -v e="$EXPECTED_MBPS" 'BEGIN{if(e>0)print m/e;else print 0}')
      if fcompare "$ratio" '>=' .8; then p=$((p+15)); elif fcompare "$ratio" '>=' .5; then p=$((p+11)); elif fcompare "$ratio" '>=' .25; then p=$((p+6)); else p=$((p+2)); fi
      printf '%s' "$p";;
    DEGRADED) printf 8;;
    STALL) printf 2;;
    *) printf 0;;
  esac
}
udp_points(){
  [[ -z $UDP_LOSS ]] && { printf 0; return; }
  if fcompare "$UDP_LOSS" '<=' 0; then printf 25; elif fcompare "$UDP_LOSS" '<=' 5; then printf 20; elif fcompare "$UDP_LOSS" '<=' 10; then printf 14; elif fcompare "$UDP_LOSS" '<=' 25; then printf 7; elif fcompare "$UDP_LOSS" '<' 100; then printf 2; else printf 0; fi
}
mtu_points(){
  [[ -z $PMTU_VALUE ]] && { [[ $TEST_MODE == quick ]] && printf 7 || printf 0; return; }
  if ((PMTU_VALUE>=1450)); then printf 10; elif ((PMTU_VALUE>=1400)); then printf 9; elif ((PMTU_VALUE>=1350)); then printf 7; elif ((PMTU_VALUE>=1300)); then printf 5; elif ((PMTU_VALUE>=1200)); then printf 2; else printf 0; fi
}
iface_points(){
  ((IFACE_ERRORS>0)) && { printf 0; return; }
  if ((IFACE_PACKETS<200)); then [[ -z $IFACE_DROP_RATE || $IFACE_DROPS -eq 0 ]] && printf 8 || printf 5; return; fi
  if [[ -z $IFACE_DROP_RATE ]] || fcompare "$IFACE_DROP_RATE" '<=' .01; then printf 10; elif fcompare "$IFACE_DROP_RATE" '<=' .1; then printf 7; elif fcompare "$IFACE_DROP_RATE" '<=' .5; then printf 3; else printf 0; fi
}

signal_state_ping(){ [[ -z $PING_LOSS ]] && { printf UNKNOWN; return; }; if fcompare "$PING_LOSS" '>' 2 || { [[ -n $PING_VAR ]] && fcompare "$PING_VAR" '>' 20; }; then printf BAD; elif fcompare "$PING_LOSS" '>' .2 || { [[ -n $PING_VAR ]] && fcompare "$PING_VAR" '>' 10; }; then printf WARN; else printf GOOD; fi; }
signal_state_tcp(){ case $TCP_STATE in HEALTHY) if [[ -n $TCP_MBPS ]] && fcompare "$TCP_MBPS" '<' "$(awk -v e="$EXPECTED_MBPS" 'BEGIN{print e*.5}')"; then printf WARN; else printf GOOD; fi;; DEGRADED) printf WARN;; STALL|BLOCKED) printf BAD;; *) printf UNKNOWN;; esac; }
signal_state_udp(){ [[ -z $UDP_LOSS ]] && { printf UNKNOWN; return; }; if fcompare "$UDP_LOSS" '>' 10; then printf BAD; elif fcompare "$UDP_LOSS" '>' 2; then printf WARN; else printf GOOD; fi; }
signal_state_mtu(){ [[ -z $PMTU_VALUE ]] && { printf UNKNOWN; return; }; if ((PMTU_VALUE<1300)); then printf BAD; elif ((PMTU_VALUE<1400)); then printf WARN; else printf GOOD; fi; }
signal_state_iface(){ ((IFACE_ERRORS>0)) && { printf BAD; return; }; [[ -z $IFACE_DROP_RATE ]] && { printf GOOD; return; }; if fcompare "$IFACE_DROP_RATE" '>' .5; then printf BAD; elif fcompare "$IFACE_DROP_RATE" '>' .1; then printf WARN; else printf GOOD; fi; }

compute_score(){
  local s pp tp up mp ip coverage=0
  pp=$(ping_points); tp=$(tcp_points); up=$(udp_points); mp=$(mtu_points); ip=$(iface_points)
  s=$((pp+tp+up+mp+ip))
  [[ -n $PING_LOSS && -n $PING_RTT ]] && coverage=$((coverage+1))
  [[ -n $TCP_STATE ]] && coverage=$((coverage+1))
  [[ -n $UDP_LOSS ]] && coverage=$((coverage+1))
  [[ -n $PMTU_VALUE || $TEST_MODE == quick ]] && coverage=$((coverage+1))
  ((IFACE_PACKETS>0 || IFACE_ERRORS>0 || IFACE_DROPS>0)) && coverage=$((coverage+1))

  if [[ $TCP_STATE == DEGRADED ]]; then ((s>64)) && s=64; fi
  if [[ $TCP_STATE == STALL ]]; then ((s>49)) && s=49; fi
  if [[ $TCP_STATE == BLOCKED ]]; then ((s>39)) && s=39; fi
  [[ -n $UDP_LOSS ]] && fcompare "$UDP_LOSS" '>' 10 && ((s>69)) && s=69
  [[ -n $PING_LOSS ]] && fcompare "$PING_LOSS" '>' 5 && ((s>49)) && s=49
  if [[ $TCP_STATE == STALL || $TCP_STATE == BLOCKED ]]; then [[ -n $UDP_LOSS ]] && fcompare "$UDP_LOSS" '>' 50 && ((s>29)) && s=29; fi
  ((s<0)) && s=0; ((s>100)) && s=100
  FINAL_SCORE=$s
  if ((s>=85)); then FINAL_VERDICT=EXCELLENT; elif ((s>=70)); then FINAL_VERDICT=GOOD; elif ((s>=50)); then FINAL_VERDICT=CAUTION; else FINAL_VERDICT=POOR; fi
  if ((coverage>=5)); then FINAL_CONFIDENCE=HIGH; elif ((coverage>=3)); then FINAL_CONFIDENCE=MEDIUM; else FINAL_CONFIDENCE=LOW; fi
  [[ $TEST_MODE == quick && $FINAL_CONFIDENCE == HIGH ]] && FINAL_CONFIDENCE=MEDIUM

  if [[ $TCP_STATE == STALL || $TCP_STATE == BLOCKED ]]; then FINAL_RECOMMENDATION="TRY ANOTHER SERVER"
  elif [[ -n $UDP_LOSS ]] && fcompare "$UDP_LOSS" '>' 10; then FINAL_RECOMMENDATION="CAUTION"
  elif ((s>=70)); then FINAL_RECOMMENDATION="USE"
  elif ((s>=50)); then FINAL_RECOMMENDATION="CAUTION"
  else FINAL_RECOMMENDATION="TRY ANOTHER SERVER"; fi

  if [[ $TCP_STATE == STALL ]]; then FINAL_REASON="Sustained TCP data stalled although basic connectivity may look healthy."
  elif [[ $TCP_STATE == BLOCKED ]]; then FINAL_REASON="TCP data could not pass to the test target."
  elif [[ -n $PING_LOSS ]] && fcompare "$PING_LOSS" '>' 2; then FINAL_REASON="Packet loss is too high for a stable server pair."
  elif [[ -n $UDP_LOSS ]] && fcompare "$UDP_LOSS" '>' 10; then FINAL_REASON="UDP packet loss is high on this server pair."
  elif [[ -n $IFACE_DROP_RATE ]] && fcompare "$IFACE_DROP_RATE" '>' .1; then FINAL_REASON="Local interface drops increased during the test."
  elif [[ $TCP_STATE == HEALTHY && -n $TCP_MBPS ]] && fcompare "$TCP_MBPS" '<' "$(awk -v e="$EXPECTED_MBPS" 'BEGIN{print e*.5}')"; then FINAL_REASON="TCP data passes, but effective transfer rate is well below the requested target."
  else FINAL_REASON="Core path checks completed without a major blocker."; fi
}
paint(){ local s=$1 c=$R; case $s in GOOD|EXCELLENT|USE|HIGH|RUNNING|READY) c=$G;; WARN|CAUTION|MEDIUM) c=$Y;; BAD|POOR|BLOCKED|STALL|"TRY ANOTHER SERVER") c=$E;; *) c=$DIM;; esac; printf '%b%s%b' "$B$c" "$s" "$R"; }
result_row(){ printf ' %-16s %-45.45s ' "$1" "$2"; paint "$3"; printf '\n'; }
print_report(){
  local ping_result tcp_result udp_result mtu_result iface_result
  ping_result="${PING_LOSS:-N/A}% loss | $(fmt "$PING_RTT" 1) ms | var $(fmt "$PING_VAR" 1) ms"
  case $TCP_STATE in HEALTHY) tcp_result="$(fmt "$TCP_MBPS" 1) Mbps effective | $TCP_BYTES_RECV/$TCP_BYTES_SENT B";; STALL) tcp_result="$TCP_BYTES_RECV/$TCP_BYTES_SENT B | stalled";; DEGRADED) tcp_result="$TCP_BYTES_RECV/$TCP_BYTES_SENT B | partial";; *) tcp_result="no verified data";; esac
  udp_result="$UDP_RECV/$UDP_SENT | ${UDP_LOSS:-N/A}% loss | bulk $((UDP_BULK_RECV/1000))/$((UDP_BULK_SENT/1000)) KB"
  mtu_result="${PMTU_VALUE:+$PMTU_VALUE bytes}"; [[ -z $mtu_result ]] && mtu_result="not sampled in quick mode"
  iface_result="${IFACE_DROP_RATE:-N/A}% drops | $IFACE_ERRORS errors | $IFACE_PACKETS packets"

  printf '\n%bTUNNEL READINESS - %s%b\n' "$B$C" "$(forward_label)" "$R"
  printf '%s\n' '------------------------------------------------------------------------------------------'
  printf ' Pair: %s -> %s\n' "${LOCAL_SRC:-$(local_ipv4)}" "$PEER_IP"
  printf ' Score: '; paint "$FINAL_SCORE/100"; printf '    Verdict: '; paint "$FINAL_VERDICT"; printf '    Confidence: '; paint "$FINAL_CONFIDENCE"; printf '\n'
  printf ' Recommendation: '; paint "$FINAL_RECOMMENDATION"; printf '\n\n'
  printf ' %-16s %-45s %s\n' SIGNAL RESULT STATUS
  printf '%s\n' '------------------------------------------------------------------------------------------'
  result_row "Ping" "$ping_result" "$(signal_state_ping)"
  result_row "TCP data" "$tcp_result" "$(signal_state_tcp)"
  result_row "UDP data" "$udp_result" "$(signal_state_udp)"
  result_row "Path MTU" "$mtu_result" "$(signal_state_mtu)"
  result_row "Local interface" "$iface_result" "$(signal_state_iface)"
  printf '\n Main reason: %s\n' "$FINAL_REASON"
  printf ' Scope: this score covers this pair/direction on TCP %s + UDP %s; protocol-specific filtering may differ.\n' "$TEST_PORT" "$UDP_PORT"
  printf ' Opposite direction: run the same readiness test from the peer if you need both initiation perspectives.\n'
}

save_report(){
  local tmp="$TMP_DIR/report"
  {
    printf 'Tunnel Checker v%s\n' "$VERSION"
    printf 'Direction: %s\nPair: %s -> %s\nPorts: TCP %s, UDP %s\nExpected: %s Mbps\nScore: %s/100\nVerdict: %s\nConfidence: %s\nRecommendation: %s\nReason: %s\n\n' "$(forward_label)" "${LOCAL_SRC:-$(local_ipv4)}" "$PEER_IP" "$TEST_PORT" "$UDP_PORT" "$EXPECTED_MBPS" "$FINAL_SCORE" "$FINAL_VERDICT" "$FINAL_CONFIDENCE" "$FINAL_RECOMMENDATION" "$FINAL_REASON"
    printf 'Ping: %s%% loss, %s ms RTT, %s ms variation\n' "${PING_LOSS:-N/A}" "${PING_RTT:-N/A}" "${PING_VAR:-N/A}"
    printf 'TCP: %s, %s/%s bytes, %s Mbps effective\n' "$TCP_STATE" "$TCP_BYTES_RECV" "$TCP_BYTES_SENT" "${TCP_MBPS:-N/A}"
    printf 'UDP: %s/%s probes, %s%% probe loss, %s/%s bulk bytes, %s%% bulk loss, %s%% effective loss, %s-byte packets\n' "$UDP_RECV" "$UDP_SENT" "${UDP_PROBE_LOSS:-N/A}" "$UDP_BULK_RECV" "$UDP_BULK_SENT" "${UDP_BULK_LOSS:-N/A}" "${UDP_LOSS:-N/A}" "$UDP_PACKET_BYTES"
    printf 'PMTU: %s\n' "${PMTU_VALUE:-N/A}"
    printf 'Interface: %s packets, %s errors, %s drops, %s%% drop rate\n' "$IFACE_PACKETS" "$IFACE_ERRORS" "$IFACE_DROPS" "${IFACE_DROP_RATE:-N/A}"
    printf 'Scope: pair/direction and tested ports only; protocol-specific filtering may differ.\n'
  } >"$tmp"
  root mkdir -p "$LOG_DIR" >/dev/null 2>&1 || return 0
  root cp "$tmp" "$LAST_REPORT" 2>/dev/null || true
}
reset_results(){ PING_LOSS="";PING_RTT="";PING_VAR="";TCP_STATE="";TCP_BYTES_SENT=0;TCP_BYTES_RECV=0;TCP_MBPS="";TCP_STALLED=0;UDP_SENT=0;UDP_RECV=0;UDP_PROBE_LOSS="";UDP_LOSS="";UDP_BULK_SENT=0;UDP_BULK_RECV=0;UDP_BULK_LOSS="";PMTU_VALUE="";IFACE_PACKETS=0;IFACE_ERRORS=0;IFACE_DROPS=0;IFACE_DROP_RATE="";FINAL_SCORE=0;FINAL_VERDICT="";FINAL_CONFIDENCE="";FINAL_RECOMMENDATION="";FINAL_REASON=""; }
run_test(){
  TEST_MODE=$1
  ensure_deps || { pause; return 1; }
  reset_results; TMP_DIR=$(mktemp -d)
  prepare || { pause; return 1; }
  banner
  printf '\nRunning %s test for %s ...\n\n' "$([[ $TEST_MODE == quick ]] && printf quick || printf readiness)" "$(forward_label)"
  local before after; before=$(iface_stats before)
  if [[ $TEST_MODE == quick ]]; then ping_test 8; tcp_data_test; udp_data_test 5; else ping_test 20; tcp_data_test; udp_data_test 20; pmtu_test; fi
  after=$(iface_stats after); iface_delta "$before" "$after"
  compute_score; print_report; save_report
  printf '\nLast summary: %s\n' "$LAST_REPORT"
  pause
}

pid_value(){ local f=$1 p=""; [[ -r $f ]] && p=$(cat "$f" 2>/dev/null || true); [[ $p =~ ^[0-9]+$ ]] && printf '%s' "$p"; }
child_pid_matching(){
  local parent=$1 marker=$2 p args
  while read -r p args; do [[ $args == *socat* && $args == *"$marker"* ]] && { printf '%s' "$p"; return 0; }; done < <(ps --ppid "$parent" -o pid=,args= 2>/dev/null)
  return 1
}
socket_owned_by_pid(){ local proto=$1 port=$2 pid=$3 out; if [[ $proto == tcp ]]; then out=$(root ss -ltnpH "sport = :$port" 2>/dev/null || true); else out=$(root ss -lunpH "sport = :$port" 2>/dev/null || true); fi; grep -Fq "pid=$pid," <<<"$out"; }
listener_running(){
  local kind=$1 pidfile port proto marker p args child
  if [[ $kind == tcp ]]; then pidfile=$TCP_PID_FILE; port=$(cat "$PORT_FILE" 2>/dev/null || printf 0); proto=tcp; marker="TCP4-LISTEN:$port"
  else pidfile=$UDP_PID_FILE; port=$(( $(cat "$PORT_FILE" 2>/dev/null || printf 0) + 1 )); proto=udp; marker="UDP4-RECVFROM:$port"; fi
  p=$(pid_value "$pidfile"); [[ -n $p && $port -gt 0 ]] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  args=$(ps -p "$p" -o args= 2>/dev/null || true); [[ $args == *timeout* && $args == *socat* && $args == *"$marker"* ]] || return 1
  child=$(child_pid_matching "$p" "$marker") || return 1
  socket_owned_by_pid "$proto" "$port" "$child"
}
socket_busy(){ local proto=$1 port=$2 out; if [[ $proto == tcp ]]; then out=$(ss -ltnH "sport = :$port" 2>/dev/null || true); else out=$(ss -lunH "sport = :$port" 2>/dev/null || true); fi; [[ -n $out ]]; }
launch_timeout(){
  local sec=$1 pidfile=$2 logfile=$3; shift 3; local cmd q
  printf -v cmd 'nohup timeout --signal=TERM %q' "$sec"
  for q in "$@"; do printf -v q '%q' "$q"; cmd+=" $q"; done
  printf -v q '%q' "$logfile"; cmd+=" >$q 2>&1 &"
  printf -v q '%q' "$pidfile"; cmd+=" echo \$! >$q"
  root bash -c "$cmd"
}
stop_owned_wrapper(){ local pidfile=$1 marker=$2 p args; p=$(pid_value "$pidfile"); [[ -n $p ]] || return 0; kill -0 "$p" 2>/dev/null || return 0; args=$(ps -p "$p" -o args= 2>/dev/null || true); [[ $args == *timeout* && $args == *"$marker"* ]] || return 0; root pkill -TERM -P "$p" 2>/dev/null || true; root kill -TERM "$p" 2>/dev/null || true; }
stop_legacy_target(){
  local port; port=$(cat "$LEGACY_PORT_FILE" 2>/dev/null || printf 0)
  if [[ $port =~ ^[0-9]+$ && $port -gt 0 ]]; then
    stop_owned_wrapper "$LEGACY_TCP_PID_FILE" "TCP4-LISTEN:$((port+1))"
    stop_owned_wrapper "$LEGACY_UDP_PID_FILE" "UDP4-RECVFROM:$((port+2))"
    stop_owned_wrapper "$LEGACY_PID_FILE" "iperf3 -s -p $port"
  fi
  root rm -f "$LEGACY_PID_FILE" "$LEGACY_PORT_FILE" "$LEGACY_TCP_PID_FILE" "$LEGACY_UDP_PID_FILE" "$LEGACY_SERVER_LOG" "$LEGACY_TCP_LOG" "$LEGACY_UDP_LOG" 2>/dev/null || true
}
stop_server_internal(){
  local port; port=$(cat "$PORT_FILE" 2>/dev/null || printf 0)
  if [[ $port =~ ^[0-9]+$ && $port -gt 0 ]]; then
    stop_owned_wrapper "$TCP_PID_FILE" "TCP4-LISTEN:$port"
    stop_owned_wrapper "$UDP_PID_FILE" "UDP4-RECVFROM:$((port+1))"
  fi
  root rm -f "$PORT_FILE" "$TCP_PID_FILE" "$UDP_PID_FILE" 2>/dev/null || true
  stop_legacy_target
}
start_server(){
  ensure_deps || { pause; return 1; }; ensure_role || return 1
  if listener_running tcp && listener_running udp; then server_status; pause; return 0; fi
  stop_server_internal
  local port mins sec; port=$(ask_int "Test TCP port" "$DEFAULT_PORT" 1 65534); mins=$(ask_int "Automatic shutdown after minutes" 30 1 240)
  socket_busy tcp "$port" && { err "TCP port $port is already in use."; pause; return 1; }
  socket_busy udp "$((port+1))" && { err "UDP port $((port+1)) is already in use."; pause; return 1; }
  root mkdir -p "$STATE_DIR" "$LOG_DIR" || return 1
  printf '%s\n' "$port" | root tee "$PORT_FILE" >/dev/null || return 1
  sec=$((mins*60))
  launch_timeout "$sec" "$TCP_PID_FILE" "$TCP_LOG" socat "TCP4-LISTEN:$port,reuseaddr,fork" EXEC:/bin/cat || true
  launch_timeout "$sec" "$UDP_PID_FILE" "$UDP_LOG" socat "UDP4-RECVFROM:$((port+1)),reuseaddr,fork" EXEC:/bin/cat || true
  sleep 1
  if listener_running tcp && listener_running udp; then
    warn "Temporary unauthenticated test listeners: TCP $port and UDP $((port+1)). Restrict them to the peer IP when practical."
    warn "Tunnel Checker does not change firewall rules."
    ok "$(role_name "$ROLE") endpoint is ready for up to $mins minutes."
  else
    err "Test target failed listener ownership verification."
    stop_server_internal; pause; return 1
  fi
  pause
}
server_status(){
  if listener_running tcp && listener_running udp; then
    local port; port=$(cat "$PORT_FILE")
    printf 'Status: '; paint RUNNING; printf '\nTCP test: %s (' "$port"; paint READY; printf ')\nUDP test: %s (' "$((port+1))"; paint READY; printf ')\n'
  else
    printf 'Status: '; paint STOPPED; printf '\n'
  fi
}
stop_server(){ stop_server_internal; ok "Test target stopped."; pause; }

show_last_report(){ if [[ -r $LAST_REPORT ]]; then cat "$LAST_REPORT"; elif is_root; then warn "No saved report yet."; elif command -v sudo >/dev/null; then sudo cat "$LAST_REPORT" 2>/dev/null || warn "No saved report yet."; else warn "No saved report yet."; fi; pause; }

download_main_script(){
  local dest=$1 source
  for source in api raw cdn; do
    : >"$dest"
    case $source in
      api) curl -fsSL --connect-timeout 8 --max-time 30 -H 'Accept: application/vnd.github.raw+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: tunnel-checker' "$API_URL" -o "$dest" || continue;;
      raw) curl -fsSL --connect-timeout 8 --max-time 30 "$RAW_URL" -o "$dest" || continue;;
      cdn) curl -fsSL --connect-timeout 8 --max-time 30 "$CDN_URL" -o "$dest" || continue;;
    esac
    [[ -s $dest ]] && bash -n "$dest" && return 0
  done
  return 1
}
update_self(){
  local tmp; tmp=$(mktemp)
  download_main_script "$tmp" || { rm -f "$tmp"; err "Could not download a valid update."; pause; return 1; }
  root install -d -m 0755 "$INSTALL_DIR" || return 1
  root install -m 0755 "$tmp" "$INSTALL_PATH" && root ln -sfn "$INSTALL_PATH" "$BIN_PATH"
  rm -f "$tmp"; ok "Tunnel Checker updated. Run it again to use the new version."; pause
}
uninstall_self(){
  local a=n; [[ -r /dev/tty ]] && read -r -p "Uninstall Tunnel Checker? [y/N]: " a </dev/tty || true
  [[ $a =~ ^[Yy]$ ]] || { warn "Cancelled."; pause; return 0; }
  stop_server_internal
  root rm -f "$BIN_PATH" "$INSTALL_PATH"
  root rm -rf "$STATE_DIR"
  root rm -f "$LAST_REPORT" "$TCP_LOG" "$UDP_LOG"
  root rmdir "$INSTALL_DIR" "$LOG_DIR" 2>/dev/null || true
  ok "Tunnel Checker removed. Shared OS packages were left installed."
}

menu(){
  ensure_role || return 1
  while :; do
    clear 2>/dev/null || true; banner
    printf '\n  %b1)%b Tunnel readiness test: %s\n' "$C$B" "$R" "$(forward_label)"
    printf '  %b2)%b Quick connectivity check\n' "$C$B" "$R"
    printf '  %b3)%b Prepare this %s server as test target\n' "$C$B" "$R" "$(role_name "$ROLE")"
    printf '  %b4)%b Stop test target\n  %b5)%b Test target status\n  %b6)%b Change endpoint role\n  %b7)%b Show last summary\n  %b8)%b Update Tunnel Checker\n  %b9)%b Uninstall Tunnel Checker\n  %b0)%b Exit\n\n' "$C$B" "$R" "$C$B" "$R" "$C$B" "$R" "$C$B" "$R" "$C$B" "$R" "$C$B" "$R" "$C$B" "$R"
    local c; read -r -p 'Select: ' c </dev/tty || return 0
    case $c in
      1) run_test readiness;; 2) run_test quick;; 3) start_server;; 4) stop_server;; 5) server_status; pause;;
      6) choose_role; pause;; 7) show_last_report;; 8) update_self; return 0;; 9) uninstall_self; return 0;; 0) return 0;; *) warn "Invalid option."; sleep 1;;
    esac
  done
}

usage(){ cat <<USAGE
Tunnel Checker v$VERSION
Usage: tunnel-checker [--full|--quick|--server|--stop|--status|--role|--last|--update|--uninstall|--version]

--full     Run the practical tunnel-readiness test (default main test)
--quick    Run a shorter lower-confidence connectivity check
USAGE
}
main(){
  case ${1:-} in
    --full) run_test readiness;; --quick) run_test quick;; --server) start_server;; --stop) stop_server;; --status) load_role; server_status;;
    --role) choose_role;; --last) show_last_report;; --update) update_self;; --uninstall) uninstall_self;; --version) printf '%s\n' "$VERSION";; -h|--help) usage;; "") menu;; *) usage; return 1;;
  esac
}

if [[ ${TUNNEL_CHECKER_SOURCE_ONLY:-0} != 1 ]]; then main "$@"; fi
