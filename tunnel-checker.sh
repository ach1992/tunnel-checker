#!/usr/bin/env bash
set -uo pipefail

VERSION="0.3.0"
REPO="ach1992/tunnel-checker"
INSTALL_DIR="/usr/local/lib/tunnel-checker"
INSTALL_PATH="$INSTALL_DIR/tunnel-checker.sh"
BIN_PATH="/usr/local/bin/tunnel-checker"
STATE_DIR="/var/lib/tunnel-checker"
LOG_DIR="/var/log/tunnel-checker"
ROLE_FILE="$STATE_DIR/role"
PID_FILE="$STATE_DIR/iperf3.pid"
PORT_FILE="$STATE_DIR/iperf3.port"
TCP_DIAG_PID_FILE="$STATE_DIR/tcp-diag.pid"
UDP_DIAG_PID_FILE="$STATE_DIR/udp-diag.pid"
SERVER_LOG="$LOG_DIR/iperf3.log"
TCP_DIAG_LOG="$LOG_DIR/tcp-diag.log"
UDP_DIAG_LOG="$LOG_DIR/udp-diag.log"
LAST_REPORT="$LOG_DIR/last-report.txt"
API_URL="https://api.github.com/repos/$REPO/contents/tunnel-checker.sh?ref=main"
RAW_URL="https://raw.githubusercontent.com/$REPO/main/tunnel-checker.sh"
CDN_URL="https://cdn.jsdelivr.net/gh/$REPO@main/tunnel-checker.sh"
DEFAULT_PORT=5201
DEFAULT_MBPS=50

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; E=$'\033[31m'; C=$'\033[36m'; BL=$'\033[34m'
else R=''; B=''; DIM=''; G=''; Y=''; E=''; C=''; BL=''; fi

TMP_DIR=""
declare -a NAMES=() FWD=() REV=() STATES=() RECS=() DETAILS=()
ROLE=""; PEER_ROLE=""
PING_FWD_LOSS=""; PING_FWD_AVG=""; PING_FWD_MDEV=""
LOAD_UP_DELTA=""; LOAD_DOWN_DELTA=""
TCP_SINGLE_FWD=""; TCP_SINGLE_REV=""; TCP_PAR_FWD=""; TCP_PAR_REV=""
TCP_RETRANS_FWD=""; TCP_RETRANS_REV=""; TCP_ERROR_FWD=""; TCP_ERROR_REV=""
UDP_MAX_FWD_LOSS=""; UDP_MAX_REV_LOSS=""; UDP_MAX_FWD_JITTER=""; UDP_MAX_REV_JITTER=""
UDP_ERROR_FWD=""; UDP_ERROR_REV=""; LOAD_ERROR_UP=""; LOAD_ERROR_DOWN=""
PMTU_VALUE=""; TRACEPATH_PMTU=""; MTR_ICMP_LOSS=""; MTR_TCP_LOSS=""; MTR_UDP_LOSS=""
IFACE_RX_ERR_DELTA=0; IFACE_RX_DROP_DELTA=0; IFACE_TX_ERR_DELTA=0; IFACE_TX_DROP_DELTA=0; IFACE_DROP_RATE=""; IFACE_PACKET_DELTA=0; IFACE_SAMPLE_ADEQUATE=0
IPERF_REACHABLE=0; EXPECTED_MBPS=$DEFAULT_MBPS; TEST_MODE=full
TCP_PATH_CLASS=""; TCP_DIAG_BYTES=""; TCP_DIAG_PEER=0; UDP_DIAG_STATE=""; UDP_DIAG_RECEIVED=""; UDP_DIAG_PEER=0
PEER_HOST=""; PEER_IP=""; IPERF_PORT=$DEFAULT_PORT; TCP_DIAG_PORT=$((DEFAULT_PORT+1)); UDP_DIAG_PORT=$((DEFAULT_PORT+2)); LOCAL_IFACE=""; LOCAL_SRC=""

cleanup(){ [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT
info(){ printf '%b[INFO]%b %s\n' "$C" "$R" "$*"; }
warn(){ printf '%b[WARN]%b %s\n' "$Y" "$R" "$*"; }
err(){ printf '%b[ERROR]%b %s\n' "$E" "$R" "$*" >&2; }
ok(){ printf '%b[OK]%b %s\n' "$G" "$R" "$*"; }
section(){ printf '\n%b%s%b\n%b%s%b\n' "$B$C" "$1" "$R" "$DIM" '------------------------------------------------------------------------------------------' "$R"; }
pause(){ [[ -r /dev/tty ]] && read -r -p "Press Enter to continue..." </dev/tty || true; }
is_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]]; }
root(){ if is_root; then "$@"; elif command -v sudo >/dev/null; then sudo "$@"; else err "Root privileges are required."; return 1; fi; }
ask(){ local p=$1 d=${2:-} v=""; [[ -r /dev/tty ]] && read -r -p "$p${d:+ [$d]}: " v </dev/tty || true; printf '%s' "${v:-$d}"; }
ask_int(){ local p=$1 d=$2 min=$3 max=$4 v; while :; do v=$(ask "$p" "$d"); [[ $v =~ ^[0-9]+$ ]] && ((v>=min && v<=max)) && { printf '%s' "$v"; return; }; warn "Enter $min-$max."; done; }
fcompare(){ awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN{if(op=="<")exit !(a<b);if(op=="<=")exit !(a<=b);if(op==">")exit !(a>b);if(op==">=")exit !(a>=b);exit 1}'; }
fmt(){ [[ -z "${1:-}" || "${1:-}" == null ]] && printf 'N/A' || awk -v v="$1" -v d="${2:-2}" 'BEGIN{printf "%.*f",d,v}'; }
row(){ NAMES+=("$1"); FWD+=("$2"); REV+=("$3"); STATES+=("$4"); }
rec(){ local x=$1 r; for r in "${RECS[@]:-}"; do [[ $r == "$x" ]] && return; done; RECS+=("$x"); }
detail(){ DETAILS+=("$1|$2"); }
status_loss(){ [[ -z ${1:-} ]] && { printf N/A; return; }; if fcompare "$1" '<=' .2; then printf GOOD; elif fcompare "$1" '<=' 1; then printf WARN; else printf BAD; fi; }
status_jit(){ [[ -z ${1:-} ]] && { printf N/A; return; }; if fcompare "$1" '<=' 5; then printf GOOD; elif fcompare "$1" '<=' 15; then printf WARN; else printf BAD; fi; }
status_rtt(){ [[ -z ${1:-} ]] && { printf N/A; return; }; if fcompare "$1" '<=' 100; then printf GOOD; elif fcompare "$1" '<=' 180; then printf WARN; else printf BAD; fi; }
status_speed(){ [[ -z ${1:-} ]] && { printf N/A; return; }; local r; r=$(awk -v m="$1" -v e="$2" 'BEGIN{print m/e}'); if fcompare "$r" '>=' .8; then printf GOOD; elif fcompare "$r" '>=' .5; then printf WARN; else printf BAD; fi; }
combine_status(){ local a=$1 b=$2; if [[ $a == BAD || $b == BAD || $a == FAILED || $b == FAILED ]];then printf BAD;elif [[ $a == WARN || $b == WARN ]];then printf WARN;elif [[ $a == N/A || $b == N/A ]];then printf N/A;else printf GOOD;fi; }
paint_state(){ local s=$1 c=$R; case $s in GOOD|SUITABLE|EXCELLENT|RUNNING) c=$G;; WARN|CAUTION|MARGINAL|INCOMPLETE) c=$Y;; BAD|FAILED|UNSUITABLE|POOR) c=$E;; N/A|UNKNOWN|STOPPED) c=$DIM;; esac; printf '%b%-11s%b' "$c$B" "$s" "$R"; }
role_name(){ [[ ${1:-} == iran ]] && printf IRAN || printf FOREIGN; }
set_peer_role(){ [[ $ROLE == iran ]] && PEER_ROLE=foreign || PEER_ROLE=iran; }
forward_label(){ printf '%s->%s' "$(role_name "$ROLE")" "$(role_name "$PEER_ROLE")"; }
reverse_label(){ printf '%s->%s' "$(role_name "$PEER_ROLE")" "$(role_name "$ROLE")"; }

load_role(){ ROLE=""; [[ -r $ROLE_FILE ]] && ROLE=$(tr -d '[:space:]' <"$ROLE_FILE" 2>/dev/null || true); [[ $ROLE == iran || $ROLE == foreign ]] || ROLE=""; [[ -n $ROLE ]] && set_peer_role; }
save_role(){ root mkdir -p "$STATE_DIR" >/dev/null 2>&1 || return 1; printf '%s\n' "$ROLE" | root tee "$ROLE_FILE" >/dev/null || return 1; }
choose_role(){
  [[ -r /dev/tty ]] || { err "Interactive role selection requires a terminal."; return 1; }
  while :; do
    clear 2>/dev/null || true
    printf '%b+------------------------------------------------------------+%b\n' "$BL$B" "$R"
    printf '%b| Tunnel Checker %-42s |%b\n' "$BL$B" "v$VERSION" "$R"
    printf '%b+------------------------------------------------------------+%b\n' "$BL$B" "$R"
    printf '\nWhich endpoint is this server?\n\n  %b1)%b Iran server\n  %b2)%b Foreign server\n\n' "$C$B" "$R" "$C$B" "$R"
    local c; read -r -p 'Select [1-2]: ' c </dev/tty || return 1
    case $c in 1)ROLE=iran;break;;2)ROLE=foreign;break;;*)warn "Invalid option.";sleep 1;;esac
  done
  set_peer_role
  save_role || warn "Could not persist role; it will be requested again later."
  ok "Endpoint role set to $(role_name "$ROLE")."
}
ensure_role(){ load_role; [[ -n $ROLE ]] || choose_role; }
banner(){
  printf '%b+----------------------------------------------------------------------------------------+%b\n' "$BL$B" "$R"
  printf '%b| Tunnel Checker v%-70s |%b\n' "$BL$B" "$VERSION" "$R"
  printf '%b| Two-sided tunnel-link diagnostics %-49s |%b\n' "$BL$B" '' "$R"
  printf '%b+----------------------------------------------------------------------------------------+%b\n' "$BL$B" "$R"
  if [[ -n $ROLE ]]; then printf ' Endpoint: %b%s%b    Peer: %b%s%b    Test direction: %b%s%b\n' "$B$C" "$(role_name "$ROLE")" "$R" "$B$C" "$(role_name "$PEER_ROLE")" "$R" "$B" "$(forward_label)" "$R"; fi
}

missing_packages(){
  local -a p=(); command -v curl >/dev/null||p+=(curl); command -v iperf3 >/dev/null||p+=(iperf3)
  command -v mtr >/dev/null||p+=(mtr-tiny); command -v ping >/dev/null||p+=(iputils-ping)
  command -v tracepath >/dev/null||p+=(iputils-tracepath); command -v ip >/dev/null||p+=(iproute2)
  command -v socat >/dev/null||p+=(socat); command -v jq >/dev/null||p+=(jq)
  command -v timeout >/dev/null||p+=(coreutils)
  printf '%s\n' "${p[@]}" | awk 'NF&&!s[$0]++'
}
ensure_deps(){
  local m; m=$(missing_packages); [[ -z $m ]] && return 0
  [[ -r /etc/os-release ]] || { err "Missing tools and unsupported package environment."; return 1; }
  . /etc/os-release
  [[ ${ID:-} == ubuntu || ${ID:-} == debian || ${ID_LIKE:-} == *debian* ]] || { err "Auto-install supports Debian/Ubuntu only."; return 1; }
  local a=y; [[ -r /dev/tty ]] && read -r -p "Install missing packages? [Y/n]: " a </dev/tty || true
  [[ $a =~ ^[Nn]$ ]] && return 1
  local -a p=(); while IFS= read -r x; do [[ -n $x ]]&&p+=("$x"); done <<<"$m"
  root env DEBIAN_FRONTEND=noninteractive apt-get update && root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${p[@]}"
}

resolve4(){ getent ahostsv4 "$1" 2>/dev/null|awk 'NR==1{print $1}'; }
prepare(){
  ensure_role || return 1
  PEER_HOST=$(ask "$(role_name "$PEER_ROLE") peer IP/hostname" ""); [[ -n $PEER_HOST ]]||{ err "Peer is required."; return 1; }
  PEER_IP=$(resolve4 "$PEER_HOST"); [[ $PEER_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]||{ err "No usable IPv4 address."; return 1; }
  IPERF_PORT=$(ask_int "iperf3 port" "$DEFAULT_PORT" 1 65533); TCP_DIAG_PORT=$((IPERF_PORT+1)); UDP_DIAG_PORT=$((IPERF_PORT+2))
  EXPECTED_MBPS=$(ask_int "Expected tunnel bandwidth (Mbps)" "$DEFAULT_MBPS" 1 100000)
  local rt; rt=$(ip -4 route get "$PEER_IP" 2>/dev/null|head -1||true)
  LOCAL_IFACE=$(awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'<<<"$rt")
  LOCAL_SRC=$(awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'<<<"$rt")
  info "Perspective: $(role_name "$ROLE") -> $(role_name "$PEER_ROLE")"
  info "Peer: $PEER_HOST -> $PEER_IP"
  info "Route: ${rt:-unavailable}"
}

parse_ping(){
  local f=$1 loss avg="" md="" r vals
  loss=$(grep -Eo '[0-9]+([.][0-9]+)?% packet loss' "$f" 2>/dev/null|tail -1|cut -d% -f1||true)
  r=$(grep -E '(^rtt |^round-trip ).*=.* ms' "$f" 2>/dev/null|tail -1||true)
  if [[ -n $r ]]; then vals=$(sed -E 's/.*= *([^ ]+) ms.*/\1/'<<<"$r"); avg=$(cut -d/ -f2<<<"$vals"); md=$(cut -d/ -f4<<<"$vals"); fi
  printf '%s|%s|%s\n' "$loss" "$avg" "$md"
}
ping_test(){
  local n=$1 f="$TMP_DIR/ping.txt" p; info "ICMP latency/loss ($n probes)..."
  LC_ALL=C ping -4 -n -q -c "$n" -i .2 -W 2 "$PEER_IP" >"$f" 2>&1||true
  p=$(parse_ping "$f"); IFS='|' read -r PING_FWD_LOSS PING_FWD_AVG PING_FWD_MDEV<<<"$p"
  row "ICMP packet loss" "${PING_FWD_LOSS:+$PING_FWD_LOSS%}" N/A "$(status_loss "$PING_FWD_LOSS")"
  row "ICMP avg RTT" "$(fmt "$PING_FWD_AVG" 2) ms" N/A "$(status_rtt "$PING_FWD_AVG")"
  row "ICMP RTT variation" "$(fmt "$PING_FWD_MDEV" 2) ms" N/A "$(status_jit "$PING_FWD_MDEV")"
  [[ -n $PING_FWD_LOSS ]]&&fcompare "$PING_FWD_LOSS" '>' 1&&rec "Packet loss is above 1%; expect retransmissions, stalls, or unstable tunnel latency."
}

iperf_probe(){
  local f="$TMP_DIR/iperf-probe.txt"
  info "iperf3 protocol reachability..."
  timeout 8 stdbuf -oL -eL iperf3 -c "$PEER_IP" -p "$IPERF_PORT" -P 1 -t 1 -i 1 >"$f" 2>&1||true
  if grep -Eqi '(^|[[:space:]])connected to[[:space:]]' "$f";then IPERF_REACHABLE=1;row "iperf3 protocol session" Reachable - GOOD;return 0;fi
  IPERF_REACHABLE=0
  row "iperf3 protocol session" "Unavailable" - BAD
  rec "A real iperf3 session could not establish protocol reachability on TCP $IPERF_PORT; the active service port was not probed with nc."
  return 1
}
iperf_error(){
  local f=$1 x=""
  [[ -s $f ]] && x=$(jq -r '.error // empty' "$f" 2>/dev/null|head -1||true)
  [[ -z $x && -s $f.err ]] && x=$(tr '\n\r' '  ' <"$f.err" | sed -E 's/[[:space:]]+/ /g;s/^ //;s/ $//' | cut -c1-180)
  printf '%s' "${x:-unknown iperf3 failure}"
}
classify_tcp_continuity(){
  local sent=$1 recv=$2 rc=$3 stalled=$4
  if ((recv==sent && sent>0));then printf HEALTHY
  elif ((recv>0 && rc==124 && stalled>=3));then printf SUSTAINED_STALL
  elif ((recv>0 && recv<sent));then printf DEGRADED
  else printf UNAVAILABLE;fi
}
tcp_continuity_diag(){
  [[ $TEST_MODE == full ]]||return
  [[ -n $TCP_PATH_CLASS ]]&&return
  local payload="$TMP_DIR/tcp-diag.payload" out="$TMP_DIR/tcp-diag.out" er="$TMP_DIR/tcp-diag.err" token pid rc=0 sent recv st elapsed=0 last=0 current=0 stalled=0
  token="TCV03-${RANDOM}-${RANDOM}-"
  { printf '%s' "$token"; dd if=/dev/zero bs=1024 count=512 status=none; } >"$payload"
  sent=$(stat -c %s "$payload")
  info "Independent TCP continuity on port $TCP_DIAG_PORT..."
  timeout 10 socat STDIO,ignoreeof "TCP4:$PEER_IP:$TCP_DIAG_PORT,connect-timeout=4" <"$payload" >"$out" 2>"$er" & pid=$!
  while kill -0 "$pid" 2>/dev/null && ((elapsed<10));do
    sleep 1;elapsed=$((elapsed+1));current=$(stat -c %s "$out" 2>/dev/null||printf 0)
    if ((current>last));then stalled=0;else stalled=$((stalled+1));fi
    last=$current
    if ((current>=sent));then kill -TERM "$pid" 2>/dev/null||true;break;fi
  done
  wait "$pid" 2>/dev/null||rc=$?
  recv=$(stat -c %s "$out" 2>/dev/null||printf 0)
  ((recv>last))&&stalled=0
  if ((recv>=${#token})) && cmp -n "${#token}" "$payload" "$out" >/dev/null 2>&1;then TCP_DIAG_PEER=1;fi
  TCP_PATH_CLASS=$(classify_tcp_continuity "$sent" "$recv" "$rc" "$stalled")
  TCP_DIAG_BYTES="$recv/$sent B"
  case $TCP_PATH_CLASS in
    HEALTHY) st=GOOD;rec "Independent TCP continuity completed on the isolated diagnostic socket; if iperf3 failed, the failure may be iperf3/control-specific rather than a general TCP data-path failure.";;
    SUSTAINED_STALL) st=BAD;rec "Sustained TCP data stall confirmed independently of iperf3: some echoed bytes arrived, then progress stopped until timeout.";;
    DEGRADED) st=WARN;rec "Independent TCP continuity transferred only part of the bounded payload; sustained TCP data is degraded or incomplete.";;
    *) st=N/A;rec "Independent TCP continuity was unavailable; peer v0.3 diagnostic support or TCP $TCP_DIAG_PORT reachability could not be confirmed.";;
  esac
  row "Independent TCP continuity" "$TCP_DIAG_BYTES" N/A "$st"
}
udp_continuity_diag(){
  [[ $TEST_MODE == full ]]||return
  [[ -n $UDP_DIAG_STATE ]]&&return
  local i token out er good=0 st
  if ((TCP_DIAG_PEER==0));then tcp_continuity_diag;fi
  info "Independent UDP continuity on port $UDP_DIAG_PORT..."
  for i in 1 2 3 4 5;do
    token="TCU03-${i}-${RANDOM}-${RANDOM}"
    out="$TMP_DIR/udp-diag-$i.out";er="$TMP_DIR/udp-diag-$i.err"
    printf '%s' "$token" | timeout 3 socat -T1 - "UDP4-DATAGRAM:$PEER_IP:$UDP_DIAG_PORT" >"$out" 2>"$er"||true
    [[ $(cat "$out" 2>/dev/null||true) == "$token" ]]&&good=$((good+1))
  done
  UDP_DIAG_RECEIVED="$good/5 echoes"
  if ((good==5));then UDP_DIAG_STATE=GOOD;UDP_DIAG_PEER=1;st=GOOD
  elif ((good>0));then UDP_DIAG_STATE=WARN;UDP_DIAG_PEER=1;st=WARN
  elif ((TCP_DIAG_PEER==1));then UDP_DIAG_STATE=BAD;UDP_DIAG_PEER=1;st=BAD
  else UDP_DIAG_STATE=UNKNOWN;st=N/A;fi
  row "Independent UDP continuity" "$UDP_DIAG_RECEIVED" N/A "$st"
  case $UDP_DIAG_STATE in
    GOOD) rec "Independent UDP echo continuity succeeded; target-rate UDP loss/jitter still require a successful iperf3 UDP run.";;
    WARN) rec "Independent UDP echo continuity was partial; treat UDP tunnel suitability cautiously and repeat from the peer.";;
    BAD) rec "Peer v0.3 diagnostics were confirmed over TCP but no UDP echo returned; this is UDP-specific negative evidence independent of iperf3's TCP control channel.";;
    UNKNOWN) rec "UDP-specific evidence is unavailable; an iperf3 UDP failure alone is not used to reject UDP/WireGuard suitability.";;
  esac
}
tcp_once(){
  local rev=$1 streams=$2 seconds=$3 f=$4 rc=0; local -a c=(iperf3 -c "$PEER_IP" -p "$IPERF_PORT" -P "$streams" -t "$seconds" -J)
  [[ $rev == 1 ]]&&c+=(-R); timeout $((seconds+15)) "${c[@]}" >"$f" 2>"$f.err"||rc=$?
  ((rc==0)) || return 1
  jq -e '.end and (((.end.sum_received.bits_per_second//.end.sum.bits_per_second//.end.sum_sent.bits_per_second//0)|tonumber) > 0)' "$f" >/dev/null 2>&1
}
tcp_mbps(){ jq -r '(.end.sum_received.bits_per_second//.end.sum.bits_per_second//.end.sum_sent.bits_per_second//empty)/1000000' "$1" 2>/dev/null; }
tcp_ret(){ jq -r '.end.sum_sent.retransmits//empty' "$1" 2>/dev/null; }
tcp_tests(){
  local s=$1 f r st
  if ! iperf_probe;then
    [[ $TEST_MODE == full ]]&&tcp_continuity_diag
    return
  fi
  f="$TMP_DIR/t1f"; r="$TMP_DIR/t1r"; info "TCP single-stream both directions..."
  if tcp_once 0 1 "$s" "$f";then TCP_SINGLE_FWD=$(tcp_mbps "$f");TCP_RETRANS_FWD=$(tcp_ret "$f");else TCP_ERROR_FWD=$(iperf_error "$f");rec "TCP $(forward_label) test failed: $TCP_ERROR_FWD";fi
  if tcp_once 1 1 "$s" "$r";then TCP_SINGLE_REV=$(tcp_mbps "$r");TCP_RETRANS_REV=$(tcp_ret "$r");else TCP_ERROR_REV=$(iperf_error "$r");rec "TCP $(reverse_label) test failed: $TCP_ERROR_REV";fi
  if [[ -n $TCP_SINGLE_FWD && -n $TCP_SINGLE_REV ]];then st=$(combine_status "$(status_speed "$TCP_SINGLE_FWD" "$EXPECTED_MBPS")" "$(status_speed "$TCP_SINGLE_REV" "$EXPECTED_MBPS")");else st=FAILED;fi
  row "TCP single stream" "$([[ -n $TCP_SINGLE_FWD ]]&&printf '%s Mbps' "$(fmt "$TCP_SINGLE_FWD" 1)"||printf FAILED)" "$([[ -n $TCP_SINGLE_REV ]]&&printf '%s Mbps' "$(fmt "$TCP_SINGLE_REV" 1)"||printf FAILED)" "$st"
  [[ $TEST_MODE == full ]]||return
  if [[ -z $TCP_SINGLE_FWD || -z $TCP_SINGLE_REV ]];then tcp_continuity_diag;fi
  f="$TMP_DIR/t4f"; r="$TMP_DIR/t4r"; info "TCP 4-stream both directions..."
  tcp_once 0 4 "$s" "$f"&&TCP_PAR_FWD=$(tcp_mbps "$f")||true
  tcp_once 1 4 "$s" "$r"&&TCP_PAR_REV=$(tcp_mbps "$r")||true
  if [[ -n $TCP_PAR_FWD && -n $TCP_PAR_REV ]];then st=$(combine_status "$(status_speed "$TCP_PAR_FWD" "$EXPECTED_MBPS")" "$(status_speed "$TCP_PAR_REV" "$EXPECTED_MBPS")");else st=FAILED;fi
  row "TCP 4 parallel" "$([[ -n $TCP_PAR_FWD ]]&&printf '%s Mbps' "$(fmt "$TCP_PAR_FWD" 1)"||printf FAILED)" "$([[ -n $TCP_PAR_REV ]]&&printf '%s Mbps' "$(fmt "$TCP_PAR_REV" 1)"||printf FAILED)" "$st"
  row "TCP retransmits" "${TCP_RETRANS_FWD:-N/A}" "${TCP_RETRANS_REV:-N/A}" N/A
  if [[ -n $TCP_PAR_FWD && -n $TCP_PAR_REV ]]; then local hi lo ratio; if fcompare "$TCP_PAR_FWD" '>=' "$TCP_PAR_REV"; then hi=$TCP_PAR_FWD;lo=$TCP_PAR_REV;else hi=$TCP_PAR_REV;lo=$TCP_PAR_FWD;fi; ratio=$(awk -v l="$lo" -v h="$hi" 'BEGIN{print l/h}'); fcompare "$ratio" '<' .5&&rec "TCP is strongly asymmetric; inspect provider routing, congestion, or shaping in the slower direction."; fi
}

loaded_latency(){
  [[ $TEST_MODE == full && $IPERF_REACHABLE -eq 1 && -n $PING_FWD_AVG ]]||return
  if [[ -z $TCP_SINGLE_FWD || -z $TCP_SINGLE_REV ]];then row "Loaded RTT increase" N/A N/A N/A;rec "Loaded-latency test was skipped because the baseline iperf3 data test did not complete.";return;fi
  local rev label lf pf pid p loss avg md delta up=N/A down=N/A overall=N/A active=0 rc
  for rev in 0 1; do
    [[ $rev == 0 ]]&&label=upload||label=download; lf="$TMP_DIR/load-$label"; pf="$TMP_DIR/lping-$label"
    local -a c=(iperf3 -c "$PEER_IP" -p "$IPERF_PORT" -P 4 -t 10 -J); [[ $rev == 1 ]]&&c+=(-R)
    info "RTT under $label load..."; timeout 25 "${c[@]}" >"$lf" 2>"$lf.err" & pid=$!; sleep 2
    if ! kill -0 "$pid" 2>/dev/null;then wait "$pid" 2>/dev/null||true; [[ $rev == 0 ]]&&LOAD_ERROR_UP=$(iperf_error "$lf")||LOAD_ERROR_DOWN=$(iperf_error "$lf");continue;fi
    LC_ALL=C ping -4 -n -q -c 25 -i .2 -W 2 "$PEER_IP" >"$pf" 2>&1||true; rc=0;wait "$pid" 2>/dev/null||rc=$?
    if ((rc!=0)) || ! jq -e '.end and (((.end.sum_received.bits_per_second//.end.sum.bits_per_second//.end.sum_sent.bits_per_second//0)|tonumber) > 0)' "$lf" >/dev/null 2>&1;then [[ $rev == 0 ]]&&LOAD_ERROR_UP=$(iperf_error "$lf")||LOAD_ERROR_DOWN=$(iperf_error "$lf");continue;fi
    p=$(parse_ping "$pf"); IFS='|' read -r loss avg md<<<"$p"; [[ -z $avg ]]&&continue; delta=$(awk -v a="$avg" -v b="$PING_FWD_AVG" 'BEGIN{d=a-b;if(d<0)d=0;print d}')
    active=$((active+1)); if [[ $rev == 0 ]];then LOAD_UP_DELTA=$delta;up="+$(fmt "$delta" 1) ms";else LOAD_DOWN_DELTA=$delta;down="+$(fmt "$delta" 1) ms";fi
  done
  if ((active==0));then row "Loaded RTT increase" N/A N/A N/A;rec "Could not create a verified iperf3 load, so loaded latency was not scored.";return;fi
  local worst=0 v;for v in "${LOAD_UP_DELTA:-}" "${LOAD_DOWN_DELTA:-}";do [[ -n $v ]]&&fcompare "$v" '>' "$worst"&&worst=$v;done
  if ((active<2));then overall=N/A;elif fcompare "$worst" '<=' 15;then overall=GOOD;elif fcompare "$worst" '<=' 40;then overall=WARN;else overall=BAD;fi
  row "Loaded RTT increase" "$up" "$down" "$overall"; [[ $overall == BAD ]]&&rec "Latency rises sharply under load; queueing/bufferbloat or congestion can break tunnel responsiveness despite good idle ping."
}

udp_once(){ local rev=$1 rate=$2 f=$3 rc=0; local -a c=(iperf3 -c "$PEER_IP" -p "$IPERF_PORT" -u -b "${rate}M" -t 7 -J); [[ $rev == 1 ]]&&c+=(-R);timeout 22 "${c[@]}" >"$f" 2>"$f.err"||rc=$?;((rc==0))||return 1;jq -e '.end.sum and ((.end.sum.bits_per_second//0)>0)' "$f" >/dev/null 2>&1; }
udp_field(){ case $2 in mbps)jq -r '(.end.sum.bits_per_second//empty)/1000000' "$1";;loss)jq -r '.end.sum.lost_percent//empty' "$1";;jit)jq -r '.end.sum.jitter_ms//empty' "$1";;esac 2>/dev/null; }
udp_tests(){
  [[ $TEST_MODE == full ]]||return
  local rate f r fm rm fl rl fj rj st
  if ((IPERF_REACHABLE==1));then
    local -a rates=($((EXPECTED_MBPS/4)) $((EXPECTED_MBPS/2)) "$EXPECTED_MBPS");((rates[0]<1))&&rates[0]=1;((rates[1]<1))&&rates[1]=1
    for rate in "${rates[@]}";do
      f="$TMP_DIR/uf$rate";r="$TMP_DIR/ur$rate";info "UDP ${rate} Mbps both directions...";fm="";rm="";fl="";rl="";fj="";rj=""
      if udp_once 0 "$rate" "$f";then fm=$(udp_field "$f" mbps);fl=$(udp_field "$f" loss);fj=$(udp_field "$f" jit);elif ((rate==EXPECTED_MBPS));then UDP_ERROR_FWD=$(iperf_error "$f");fi
      if udp_once 1 "$rate" "$r";then rm=$(udp_field "$r" mbps);rl=$(udp_field "$r" loss);rj=$(udp_field "$r" jit);elif ((rate==EXPECTED_MBPS));then UDP_ERROR_REV=$(iperf_error "$r");fi
      if [[ -n $fl && -n $rl && -n $fj && -n $rj ]];then st=$(combine_status "$(combine_status "$(status_loss "$fl")" "$(status_loss "$rl")")" "$(combine_status "$(status_jit "$fj")" "$(status_jit "$rj")")");else st=FAILED;fi
      row "UDP ${rate}M loss/jitter" "$([[ -n $fl ]]&&printf '%s%% / %sms' "$(fmt "$fl" 2)" "$(fmt "$fj" 2)"||printf FAILED)" "$([[ -n $rl ]]&&printf '%s%% / %sms' "$(fmt "$rl" 2)" "$(fmt "$rj" 2)"||printf FAILED)" "$st"
      if ((rate==EXPECTED_MBPS));then UDP_MAX_FWD_LOSS=$fl;UDP_MAX_REV_LOSS=$rl;UDP_MAX_FWD_JITTER=$fj;UDP_MAX_REV_JITTER=$rj;fi
    done
  else
    row "UDP target-rate test" N/A N/A N/A
    rec "UDP iperf3 was not treated as UDP-path evidence because its TCP control session was unavailable."
  fi
  [[ -n $UDP_ERROR_FWD ]]&&rec "UDP $(forward_label) iperf3 test failed: $UDP_ERROR_FWD"
  [[ -n $UDP_ERROR_REV ]]&&rec "UDP $(reverse_label) iperf3 test failed: $UDP_ERROR_REV"
  if [[ -z $UDP_MAX_FWD_LOSS || -z $UDP_MAX_REV_LOSS || -z $UDP_MAX_FWD_JITTER || -z $UDP_MAX_REV_JITTER ]];then udp_continuity_diag;fi
  local w=0 v;for v in "${UDP_MAX_FWD_LOSS:-}" "${UDP_MAX_REV_LOSS:-}";do [[ -n $v ]]&&fcompare "$v" '>' "$w"&&w=$v;done;fcompare "$w" '>' 1&&rec "UDP loss exceeds 1% at the intended rate; lower the target load or prefer another route/server."
}

iface_stats(){
  local j;[[ -n $LOCAL_IFACE ]]||{ printf '0|0|0|0|0|0';return;};j=$(ip -j -s link show dev "$LOCAL_IFACE" 2>/dev/null||true)
  jq -r '.[0] | (.stats64 // .stats) as $s | [($s.rx.packets//0),($s.rx.errors//0),($s.rx.dropped//0),($s.tx.packets//0),($s.tx.errors//0),($s.tx.dropped//0)] | @tsv'<<<"$j" 2>/dev/null|tr '\t' '|'||printf '0|0|0|0|0|0'
}
iface_delta(){
  local b=$1 a=$2 brp bre brd btp bte btd arp are ard atp ate atd rxp txp totalp totald st=GOOD
  IFS='|' read -r brp bre brd btp bte btd<<<"$b";IFS='|' read -r arp are ard atp ate atd<<<"$a"
  IFACE_RX_ERR_DELTA=$((are-bre));IFACE_RX_DROP_DELTA=$((ard-brd));IFACE_TX_ERR_DELTA=$((ate-bte));IFACE_TX_DROP_DELTA=$((atd-btd));rxp=$((arp-brp));txp=$((atp-btp));totalp=$((rxp+txp));totald=$((IFACE_RX_DROP_DELTA+IFACE_TX_DROP_DELTA));IFACE_PACKET_DELTA=$totalp
  ((totalp>=1000))&&IFACE_SAMPLE_ADEQUATE=1||IFACE_SAMPLE_ADEQUATE=0
  if ((totalp>0));then IFACE_DROP_RATE=$(awk -v d="$totald" -v p="$totalp" 'BEGIN{printf "%.5f",d*100/p}');else IFACE_DROP_RATE="";fi
  ((IFACE_RX_ERR_DELTA+IFACE_TX_ERR_DELTA>0))&&st=BAD
  if [[ $st == GOOD && $IFACE_SAMPLE_ADEQUATE -eq 1 && -n $IFACE_DROP_RATE ]];then if fcompare "$IFACE_DROP_RATE" '>' .1;then st=BAD;elif fcompare "$IFACE_DROP_RATE" '>' .01;then st=WARN;fi;fi
  if [[ $st == GOOD && $IFACE_SAMPLE_ADEQUATE -eq 0 && $totald -gt 0 ]];then st=N/A;fi
  row "Local interface packets" "RX $rxp packets" "TX $txp packets" "$([[ $IFACE_SAMPLE_ADEQUATE -eq 1 ]]&&printf GOOD||printf N/A)"
  row "Local interface err/drop" "RX $IFACE_RX_ERR_DELTA/$IFACE_RX_DROP_DELTA" "TX $IFACE_TX_ERR_DELTA/$IFACE_TX_DROP_DELTA" "$st"
  if [[ $st == BAD || $st == WARN ]];then rec "Local interface errors/drops increased (${IFACE_DROP_RATE}% across $totalp observed packets); inspect host/vNIC queues and provider limits."
  elif [[ $st == N/A ]];then rec "Local interface drop sample was too small for a rate classification: $totald drops across $totalp observed packets."
  fi
}

mtr_dest_loss(){ local f=$1;awk -v ip="$PEER_IP" '$2==ip{x=$3;gsub("%","",x);v=x}END{print v}' "$f" 2>/dev/null; }
path_tests(){
  [[ $TEST_MODE == full ]]||return;local f="$TMP_DIR/tracepath.txt";info "tracepath and PMTU...";timeout 45 tracepath -4 -n -p "$UDP_DIAG_PORT" "$PEER_IP" >"$f" 2>&1||true;TRACEPATH_PMTU=$(grep -Eo 'pmtu[[:space:]]+[0-9]+' "$f"|tail -1|awk '{print $2}'||true);detail TRACEPATH "$f"
  if ping -4 -n -M do -s 56 -c 1 -W 1 "$PEER_IP" >/dev/null 2>&1;then local mtu=1500 d lo=0 hi mid;[[ -n $LOCAL_IFACE ]]&&d=$(ip -o link show "$LOCAL_IFACE"|awk '{for(i=1;i<=NF;i++)if($i=="mtu"){print $(i+1);exit}}');[[ ${d:-} =~ ^[0-9]+$ ]]&&mtu=$d;((mtu>9000))&&mtu=9000;hi=$((mtu-28));while ((lo<hi));do mid=$(((lo+hi+1)/2));if ping -4 -n -M do -s "$mid" -c 1 -W 1 "$PEER_IP" >/dev/null 2>&1;then lo=$mid;else hi=$((mid-1));fi;done;PMTU_VALUE=$((lo+28));local st=GOOD;((PMTU_VALUE<1300))&&st=BAD;((PMTU_VALUE>=1300&&PMTU_VALUE<1400))&&st=WARN;row "Path MTU (ICMP DF)" "$PMTU_VALUE bytes" N/A "$st";((PMTU_VALUE<1400))&&rec "Path MTU is low; account for tunnel overhead to avoid fragmentation or stalled large transfers.";else row "Path MTU (ICMP DF)" N/A N/A N/A;fi
  [[ -n $TRACEPATH_PMTU ]]&&row "Path MTU (tracepath)" "$TRACEPATH_PMTU bytes" N/A "$([[ $TRACEPATH_PMTU -ge 1400 ]]&&printf GOOD||printf WARN)"
  local type cmd out loss;for type in ICMP TCP UDP;do out="$TMP_DIR/mtr-$type.txt";case $type in ICMP)cmd="mtr -4 -n -r -w -c 20 $PEER_IP";;TCP)cmd="mtr -4 -n -r -w -c 20 -T -P $TCP_DIAG_PORT $PEER_IP";;UDP)cmd="mtr -4 -n -r -w -c 20 -u -P $UDP_DIAG_PORT $PEER_IP";;esac;info "MTR $type path...";timeout 50 bash -c "$cmd" >"$out" 2>&1||true;detail "MTR $type" "$out";loss=$(mtr_dest_loss "$out");case $type in ICMP)MTR_ICMP_LOSS=$loss;;TCP)MTR_TCP_LOSS=$loss;;UDP)MTR_UDP_LOSS=$loss;;esac;row "MTR $type destination loss" "${loss:+$loss%}" N/A "$(status_loss "$loss")";done
  if [[ -n $MTR_ICMP_LOSS ]]&&fcompare "$MTR_ICMP_LOSS" '<=' .2;then rec "Intermediate MTR loss is not treated as end-to-end loss when the destination remains healthy; routers often rate-limit probe replies.";fi
}

score_loss(){ [[ -z ${1:-} ]]&&{ echo 0;return;};if fcompare "$1" '<=' .2;then echo 0;elif fcompare "$1" '<=' .5;then echo 4;elif fcompare "$1" '<=' 1;then echo 8;elif fcompare "$1" '<=' 2;then echo 15;else echo 25;fi; }
score_jit(){ [[ -z ${1:-} ]]&&{ echo 0;return;};if fcompare "$1" '<=' 5;then echo 0;elif fcompare "$1" '<=' 10;then echo 3;elif fcompare "$1" '<=' 20;then echo 7;elif fcompare "$1" '<=' 40;then echo 12;else echo 18;fi; }
evidence_complete(){ [[ -n $PING_FWD_LOSS && -n $PING_FWD_AVG && -n $TCP_SINGLE_FWD && -n $TCP_SINGLE_REV ]]||return 1;[[ $TEST_MODE == quick ]]&&return 0;[[ -n $UDP_MAX_FWD_LOSS && -n $UDP_MAX_REV_LOSS && -n $UDP_MAX_FWD_JITTER && -n $UDP_MAX_REV_JITTER ]]; }
compute_score(){
  evidence_complete||{ printf 'N/A|INCOMPLETE|LOW';return; }
  local s=100 d v worst=0;d=$(score_loss "$PING_FWD_LOSS");s=$((s-d));d=$(score_jit "$PING_FWD_MDEV");s=$((s-d));if fcompare "$PING_FWD_AVG" '>' 250;then s=$((s-10));elif fcompare "$PING_FWD_AVG" '>' 180;then s=$((s-6));elif fcompare "$PING_FWD_AVG" '>' 100;then s=$((s-3));fi
  if [[ $TEST_MODE == full ]];then for v in "$UDP_MAX_FWD_LOSS" "$UDP_MAX_REV_LOSS";do fcompare "$v" '>' "$worst"&&worst=$v;done;d=$(score_loss "$worst");s=$((s-d));worst=0;for v in "$UDP_MAX_FWD_JITTER" "$UDP_MAX_REV_JITTER";do fcompare "$v" '>' "$worst"&&worst=$v;done;d=$(score_jit "$worst");s=$((s-d));fi
  local tf=${TCP_PAR_FWD:-$TCP_SINGLE_FWD} tr=${TCP_PAR_REV:-$TCP_SINGLE_REV} slow hi ratio asym;if fcompare "$tf" '<' "$tr";then slow=$tf;hi=$tr;else slow=$tr;hi=$tf;fi;ratio=$(awk -v m="$slow" -v e="$EXPECTED_MBPS" 'BEGIN{print m/e}');if fcompare "$ratio" '<' .3;then s=$((s-20));elif fcompare "$ratio" '<' .5;then s=$((s-14));elif fcompare "$ratio" '<' .7;then s=$((s-8));elif fcompare "$ratio" '<' .9;then s=$((s-3));fi;asym=$(awk -v l="$slow" -v h="$hi" 'BEGIN{print l/h}');fcompare "$asym" '<' .3&&s=$((s-10));fcompare "$asym" '>=' .3&&fcompare "$asym" '<' .5&&s=$((s-6))
  worst=0;for v in "${LOAD_UP_DELTA:-}" "${LOAD_DOWN_DELTA:-}";do [[ -n $v ]]&&fcompare "$v" '>' "$worst"&&worst=$v;done;fcompare "$worst" '>' 80&&s=$((s-10));fcompare "$worst" '<=' 80&&fcompare "$worst" '>' 40&&s=$((s-6));fcompare "$worst" '<=' 40&&fcompare "$worst" '>' 15&&s=$((s-3))
  [[ -n $PMTU_VALUE ]]&&((PMTU_VALUE<1300))&&s=$((s-10));[[ -n $PMTU_VALUE ]]&&((PMTU_VALUE>=1300&&PMTU_VALUE<1400))&&s=$((s-5));((IFACE_RX_ERR_DELTA+IFACE_TX_ERR_DELTA>0))&&s=$((s-8));[[ -n $IFACE_DROP_RATE && $IFACE_SAMPLE_ADEQUATE -eq 1 ]]&&{ fcompare "$IFACE_DROP_RATE" '>' .1&&s=$((s-6));fcompare "$IFACE_DROP_RATE" '<=' .1&&fcompare "$IFACE_DROP_RATE" '>' .01&&s=$((s-3)); };((s<0))&&s=0
  local verdict confidence;if ((s>=90));then verdict=EXCELLENT;elif ((s>=75));then verdict=GOOD;elif ((s>=55));then verdict=MARGINAL;else verdict=POOR;fi
  confidence=MEDIUM;[[ $TEST_MODE == full && -n $PMTU_VALUE && -n $MTR_ICMP_LOSS && -n $MTR_TCP_LOSS && -n $MTR_UDP_LOSS ]]&&confidence=HIGH
  printf '%s|%s|%s' "$s" "$verdict" "$confidence"
}

use_row(){ printf '%-27.27s ' "$1";paint_state "$2";printf '  %-48.48s\n' "$3"; }
use_cases(){
  local score=$1 verdict=$2 state reason tf tr slow ratio worst_loss worst_jit worst_load=0 v
  if [[ -z $TCP_SINGLE_FWD || -z $TCP_SINGLE_REV ]];then
    case $TCP_PATH_CLASS in
      SUSTAINED_STALL) use_row "TCP tunnels / proxies" UNSUITABLE "independent sustained TCP stall; $TCP_DIAG_BYTES";;
      DEGRADED) use_row "TCP tunnels / proxies" CAUTION "independent TCP continuity incomplete; $TCP_DIAG_BYTES";;
      HEALTHY) use_row "TCP tunnels / proxies" UNKNOWN "independent TCP passed; iperf3 throughput incomplete";;
      *) use_row "TCP tunnels / proxies" UNKNOWN "TCP data evidence did not complete";;
    esac
  else tf=${TCP_PAR_FWD:-$TCP_SINGLE_FWD};tr=${TCP_PAR_REV:-$TCP_SINGLE_REV};if fcompare "$tf" '<' "$tr";then slow=$tf;else slow=$tr;fi;ratio=$(awk -v m="$slow" -v e="$EXPECTED_MBPS" 'BEGIN{print m/e}');state=SUITABLE;reason="slow side $(fmt "$slow" 1) Mbps";if fcompare "$PING_FWD_LOSS" '>' 1||fcompare "$ratio" '<' .5;then state=UNSUITABLE;elif fcompare "$PING_FWD_LOSS" '>' .2||fcompare "$ratio" '<' .8;then state=CAUTION;fi;use_row "TCP tunnels / proxies" "$state" "$reason";fi
  if [[ -z $UDP_MAX_FWD_LOSS || -z $UDP_MAX_REV_LOSS || -z $UDP_MAX_FWD_JITTER || -z $UDP_MAX_REV_JITTER ]];then
    case $UDP_DIAG_STATE in
      BAD) use_row "UDP tunnels (e.g. WG)" UNSUITABLE "independent UDP echo failed with peer support confirmed";;
      WARN) use_row "UDP tunnels (e.g. WG)" CAUTION "independent UDP echo partial; target-rate metrics unknown";;
      GOOD) use_row "UDP tunnels (e.g. WG)" CAUTION "independent UDP echo passed; target-rate metrics unknown";;
      *) use_row "UDP tunnels (e.g. WG)" UNKNOWN "UDP-specific evidence is incomplete";;
    esac
  else worst_loss=$UDP_MAX_FWD_LOSS;fcompare "$UDP_MAX_REV_LOSS" '>' "$worst_loss"&&worst_loss=$UDP_MAX_REV_LOSS;worst_jit=$UDP_MAX_FWD_JITTER;fcompare "$UDP_MAX_REV_JITTER" '>' "$worst_jit"&&worst_jit=$UDP_MAX_REV_JITTER;state=SUITABLE;reason="loss $(fmt "$worst_loss" 2)%, jitter $(fmt "$worst_jit" 1) ms";if fcompare "$worst_loss" '>' 1||fcompare "$worst_jit" '>' 20;then state=UNSUITABLE;elif fcompare "$worst_loss" '>' .5||fcompare "$worst_jit" '>' 10;then state=CAUTION;fi;use_row "UDP tunnels (e.g. WG)" "$state" "$reason";fi
  if [[ -z $PING_FWD_AVG || -z $PING_FWD_MDEV || -z $PING_FWD_LOSS ]];then use_row "Interactive / realtime" UNKNOWN "ICMP quality was not measured";else for v in "${LOAD_UP_DELTA:-}" "${LOAD_DOWN_DELTA:-}";do [[ -n $v ]]&&fcompare "$v" '>' "$worst_load"&&worst_load=$v;done;state=SUITABLE;reason="RTT $(fmt "$PING_FWD_AVG" 1) ms, variation $(fmt "$PING_FWD_MDEV" 1) ms";if fcompare "$PING_FWD_LOSS" '>' 1||fcompare "$PING_FWD_AVG" '>' 180||fcompare "$PING_FWD_MDEV" '>' 20;then state=UNSUITABLE;elif [[ -z $LOAD_UP_DELTA || -z $LOAD_DOWN_DELTA ]];then state=CAUTION;reason="$reason; loaded RTT unknown";elif fcompare "$worst_load" '>' 40||fcompare "$PING_FWD_AVG" '>' 100||fcompare "$PING_FWD_MDEV" '>' 10;then state=CAUTION;fi;use_row "Interactive / realtime" "$state" "$reason";fi
  if [[ -z $TCP_PAR_FWD || -z $TCP_PAR_REV ]];then use_row "Bulk / high bandwidth" UNKNOWN "4-stream throughput is incomplete";else if fcompare "$TCP_PAR_FWD" '<' "$TCP_PAR_REV";then slow=$TCP_PAR_FWD;else slow=$TCP_PAR_REV;fi;ratio=$(awk -v m="$slow" -v e="$EXPECTED_MBPS" 'BEGIN{print m/e}');state=SUITABLE;fcompare "$ratio" '<' .5&&state=UNSUITABLE;fcompare "$ratio" '>=' .5&&fcompare "$ratio" '<' .8&&state=CAUTION;use_row "Bulk / high bandwidth" "$state" "slow side $(fmt "$slow" 1) / $EXPECTED_MBPS Mbps target";fi
  if [[ -z $PMTU_VALUE ]];then use_row "MTU-sensitive tunnels" UNKNOWN "PMTU not measured";else state=SUITABLE;((PMTU_VALUE<1300))&&state=UNSUITABLE;((PMTU_VALUE>=1300&&PMTU_VALUE<1400))&&state=CAUTION;use_row "MTU-sensitive tunnels" "$state" "path MTU $PMTU_VALUE bytes";fi
  if [[ $verdict == INCOMPLETE ]];then use_row "Overall endpoint pair" UNKNOWN "essential evidence is incomplete; per-protocol findings still apply";elif [[ $score != N/A ]]&&((score>=75));then use_row "Overall endpoint pair" SUITABLE "score $score/100; run Full Test from peer too";elif [[ $score != N/A ]]&&((score>=55));then use_row "Overall endpoint pair" CAUTION "score $score/100; inspect warnings";else use_row "Overall endpoint pair" UNSUITABLE "score $score/100; address bad signals";fi
}

print_report(){
  local score=$1 verdict=$2 confidence=$3 i d title file
  section "RESULT SUMMARY — $(forward_label) perspective"
  printf '%-29s %-24s %-24s %-11s\n' METRIC "$(forward_label)" "$(reverse_label)" STATUS
  printf '%s\n' '------------------------------------------------------------------------------------------'
  for((i=0;i<${#NAMES[@]};i++));do printf '%-29.29s %-24.24s %-24.24s ' "${NAMES[i]}" "${FWD[i]}" "${REV[i]}";paint_state "${STATES[i]}";printf '\n';done
  section "TUNNEL SUITABILITY"
  if [[ $score == N/A ]];then printf ' Score: %bN/A%b    Verdict: ' "$B$Y" "$R";paint_state "$verdict";printf '  Evidence confidence: ';paint_state "$confidence";printf '\n';else printf ' Score: %b%s/100%b    Verdict: ' "$B" "$score" "$R";paint_state "$verdict";printf '  Evidence confidence: ';paint_state "$confidence";printf '\n';fi
  printf '\n%-27s %-13s %-48s\n' 'USE CASE' 'ASSESSMENT' 'BASIS';printf '%s\n' '------------------------------------------------------------------------------------------';use_cases "$score" "$verdict"
  section "RECOMMENDATIONS"
  if((${#RECS[@]}==0));then printf '%s\n' '- No major issue was detected in measured signals.';else for d in "${RECS[@]}";do printf -- '- %s\n' "$d";done;fi
  printf '\n%bNext step:%b run a Full Test from the %s endpoint toward %s to measure the opposite path independently.\n' "$B$C" "$R" "$(role_name "$PEER_ROLE")" "$(role_name "$ROLE")"
  if [[ $TEST_MODE == full ]];then for d in "${DETAILS[@]}";do title=${d%%|*};file=${d#*|};printf '\n%b=== %s ===%b\n' "$B" "$title" "$R";[[ -s $file ]]&&cat "$file"||printf 'Unavailable/blocked.\n';done;fi
}
save_report(){
  local score=$1 verdict=$2 confidence=$3 tmp="$TMP_DIR/report" i d
  root mkdir -p "$LOG_DIR" >/dev/null 2>&1||return
  { printf 'Tunnel Checker v%s\nEndpoint: %s\nPeer role: %s\nDirection: %s\nPeer: %s (%s)\nExpected: %s Mbps\nScore: %s\nVerdict: %s\nConfidence: %s\n\n' "$VERSION" "$(role_name "$ROLE")" "$(role_name "$PEER_ROLE")" "$(forward_label)" "$PEER_HOST" "$PEER_IP" "$EXPECTED_MBPS" "$score" "$verdict" "$confidence";for((i=0;i<${#NAMES[@]};i++));do printf '%s | %s | %s | %s\n' "${NAMES[i]}" "${FWD[i]}" "${REV[i]}" "${STATES[i]}";done;printf '\nRecommendations:\n';for d in "${RECS[@]:-}";do printf -- '- %s\n' "$d";done;} >"$tmp"
  root cp "$tmp" "$LAST_REPORT"
}
reset_state(){ NAMES=();FWD=();REV=();STATES=();RECS=();DETAILS=();PING_FWD_LOSS="";PING_FWD_AVG="";PING_FWD_MDEV="";LOAD_UP_DELTA="";LOAD_DOWN_DELTA="";TCP_SINGLE_FWD="";TCP_SINGLE_REV="";TCP_PAR_FWD="";TCP_PAR_REV="";TCP_RETRANS_FWD="";TCP_RETRANS_REV="";TCP_ERROR_FWD="";TCP_ERROR_REV="";UDP_MAX_FWD_LOSS="";UDP_MAX_REV_LOSS="";UDP_MAX_FWD_JITTER="";UDP_MAX_REV_JITTER="";UDP_ERROR_FWD="";UDP_ERROR_REV="";PMTU_VALUE="";TRACEPATH_PMTU="";MTR_ICMP_LOSS="";MTR_TCP_LOSS="";MTR_UDP_LOSS="";IFACE_RX_ERR_DELTA=0;IFACE_RX_DROP_DELTA=0;IFACE_TX_ERR_DELTA=0;IFACE_TX_DROP_DELTA=0;IFACE_DROP_RATE="";IFACE_PACKET_DELTA=0;IFACE_SAMPLE_ADEQUATE=0;IPERF_REACHABLE=0;TCP_PATH_CLASS="";TCP_DIAG_BYTES="";TCP_DIAG_PEER=0;UDP_DIAG_STATE="";UDP_DIAG_RECEIVED="";UDP_DIAG_PEER=0; }
run_test(){ TEST_MODE=$1;ensure_deps||{ pause;return 1;};reset_state;TMP_DIR=$(mktemp -d);prepare||{ pause;return 1;};section "RUNNING $(printf '%s' "$TEST_MODE"|tr '[:lower:]' '[:upper:]') TEST — $(forward_label)";local before after;before=$(iface_stats);[[ $TEST_MODE == quick ]]&&ping_test 15||ping_test 50;[[ $TEST_MODE == quick ]]&&tcp_tests 5||tcp_tests 10;loaded_latency;udp_tests;after=$(iface_stats);iface_delta "$before" "$after";path_tests;local sc score verdict confidence;sc=$(compute_score);IFS='|' read -r score verdict confidence<<<"$sc";[[ $verdict == INCOMPLETE ]]&&rec "Essential data tests are incomplete; do not use this run alone to accept or reject the server pair.";print_report "$score" "$verdict" "$confidence";save_report "$score" "$verdict" "$confidence";printf '\nLast summary: %s\n' "$LAST_REPORT";pause; }

pid_value(){ local f=$1 p="";[[ -r $f ]]&&p=$(cat "$f" 2>/dev/null||true);[[ $p =~ ^[0-9]+$ ]]&&printf '%s' "$p"; }
child_pid_matching(){
  local parent=$1 comm=$2 marker=$3 p c args
  while read -r p c args;do [[ $c == "$comm" && $args == *"$marker"* ]]&&{ printf '%s' "$p";return 0;};done < <(ps --ppid "$parent" -o pid=,comm=,args= 2>/dev/null)
  return 1
}
socket_owned_by_pid(){
  local proto=$1 port=$2 pid=$3 out
  if [[ $proto == tcp ]];then out=$(root ss -ltnpH "sport = :$port" 2>/dev/null||true);else out=$(root ss -lunpH "sport = :$port" 2>/dev/null||true);fi
  grep -Fq "pid=$pid,"<<<"$out"
}
server_running(){
  [[ -r $PID_FILE && -r $PORT_FILE ]]||return 1
  local p port args child;p=$(pid_value "$PID_FILE");port=$(cat "$PORT_FILE" 2>/dev/null||true);[[ -n $p && $port =~ ^[0-9]+$ ]]||return 1
  kill -0 "$p" 2>/dev/null||return 1;args=$(ps -p "$p" -o args= 2>/dev/null||true);[[ $args == *timeout* && $args == *"iperf3 -s -p $port"* ]]||return 1
  child=$(child_pid_matching "$p" iperf3 "-s -p $port")||return 1
  socket_owned_by_pid tcp "$port" "$child"
}
diag_running(){
  local kind=$1 pidfile port proto marker p args child
  if [[ $kind == tcp ]];then pidfile=$TCP_DIAG_PID_FILE;port=$(( $(cat "$PORT_FILE" 2>/dev/null||printf 0) + 1 ));proto=tcp;marker="TCP4-LISTEN:$port"
  else pidfile=$UDP_DIAG_PID_FILE;port=$(( $(cat "$PORT_FILE" 2>/dev/null||printf 0) + 2 ));proto=udp;marker="UDP4-RECVFROM:$port";fi
  p=$(pid_value "$pidfile");[[ -n $p && $port -ge 1 ]]||return 1;kill -0 "$p" 2>/dev/null||return 1
  args=$(ps -p "$p" -o args= 2>/dev/null||true);[[ $args == *timeout* && $args == *socat* && $args == *"$marker"* ]]||return 1
  child=$(child_pid_matching "$p" socat "$marker")||return 1
  socket_owned_by_pid "$proto" "$port" "$child"
}
socket_busy(){ local proto=$1 port=$2 out;if [[ $proto == tcp ]];then out=$(ss -ltnH "sport = :$port" 2>/dev/null||true);else out=$(ss -lunH "sport = :$port" 2>/dev/null||true);fi;[[ -n $out ]]; }
check_target_ports(){
  local port=$1
  socket_busy tcp "$port"&&{ err "TCP port $port is already in use; choose another iperf3 base port.";return 1; }
  socket_busy udp "$port"&&{ err "UDP port $port is already in use; choose another iperf3 base port.";return 1; }
  socket_busy tcp "$((port+1))"&&{ err "TCP diagnostic port $((port+1)) is already in use; choose another base port.";return 1; }
  socket_busy udp "$((port+2))"&&{ err "UDP diagnostic port $((port+2)) is already in use; choose another base port.";return 1; }
  return 0
}
launch_timeout(){
  local sec=$1 pidfile=$2 logfile=$3;shift 3;local cmd q
  printf -v cmd 'nohup timeout --signal=TERM %q' "$sec"
  for q in "$@";do printf -v q '%q' "$q";cmd+=" $q";done
  printf -v q '%q' "$logfile";cmd+=" >$q 2>&1 &"
  printf -v q '%q' "$pidfile";cmd+=" echo \$! >$q"
  root bash -c "$cmd"
}
stop_owned_wrapper(){
  local pidfile=$1 marker=$2 p args;p=$(pid_value "$pidfile");[[ -n $p ]]||return 0;kill -0 "$p" 2>/dev/null||return 0
  args=$(ps -p "$p" -o args= 2>/dev/null||true);[[ $args == *timeout* && $args == *"$marker"* ]]||return 0
  root pkill -TERM -P "$p" 2>/dev/null||true;root kill -TERM "$p" 2>/dev/null||true
}
stop_server_internal(){
  local port;port=$(cat "$PORT_FILE" 2>/dev/null||printf 0)
  if [[ $port =~ ^[0-9]+$ && $port -gt 0 ]];then
    stop_owned_wrapper "$TCP_DIAG_PID_FILE" "TCP4-LISTEN:$((port+1))"
    stop_owned_wrapper "$UDP_DIAG_PID_FILE" "UDP4-RECVFROM:$((port+2))"
    stop_owned_wrapper "$PID_FILE" "iperf3 -s -p $port"
  fi
  root rm -f "$PID_FILE" "$PORT_FILE" "$TCP_DIAG_PID_FILE" "$UDP_DIAG_PID_FILE"
}
server_status(){
  if server_running;then
    local port tcp_state=NOT_READY udp_state=NOT_READY;port=$(cat "$PORT_FILE");diag_running tcp&&tcp_state=READY||true;diag_running udp&&udp_state=READY||true
    printf 'Status: ';paint_state RUNNING;printf '\nPID: %s\niperf3: TCP/UDP %s\nTCP diagnostic: %s (%s)\nUDP diagnostic: %s (%s)\n' "$(cat "$PID_FILE")" "$port" "$((port+1))" "$tcp_state" "$((port+2))" "$udp_state"
  else
    printf 'Status: ';paint_state STOPPED;printf '\n'
    [[ -e $PID_FILE || -e $PORT_FILE ]]&&printf 'Stored server state is stale or no longer owns the expected iperf3 listener; it is not treated as RUNNING.\n'
  fi
}
target_start_failure(){
  local logs=""
  [[ -r $SERVER_LOG ]]&&logs+=$(tail -n 8 "$SERVER_LOG" 2>/dev/null||true)
  [[ -r $TCP_DIAG_LOG ]]&&logs+=$'\n'$(tail -n 8 "$TCP_DIAG_LOG" 2>/dev/null||true)
  [[ -r $UDP_DIAG_LOG ]]&&logs+=$'\n'$(tail -n 8 "$UDP_DIAG_LOG" 2>/dev/null||true)
  if grep -Eqi 'address already in use|bind failed|unable to bind|bind\('<<<"$logs";then err "Temporary target bind failed because one of its ports became unavailable during startup."
  else err "Temporary target failed process/listener ownership verification; no unverified target is reported as RUNNING.";fi
}
start_server(){
  ensure_deps||{ pause;return 1;};ensure_role||return 1
  server_running&&{ server_status;pause;return;}
  stop_server_internal
  local port mins sec;port=$(ask_int "iperf3 server port" "$DEFAULT_PORT" 1 65533);mins=$(ask_int "Automatic shutdown after minutes" 30 1 240)
  check_target_ports "$port"||{ pause;return 1;}
  root mkdir -p "$STATE_DIR" "$LOG_DIR"||return
  printf '%s\n' "$port" | root tee "$PORT_FILE" >/dev/null||return 1
  warn "Temporary diagnostics use iperf3 $port, TCP $((port+1)), and UDP $((port+2)). Restrict them to the testing peer when possible."
  warn "Tunnel Checker does not change firewall rules."
  sec=$((mins*60))
  launch_timeout "$sec" "$PID_FILE" "$SERVER_LOG" iperf3 -s -p "$port"||true
  launch_timeout "$sec" "$TCP_DIAG_PID_FILE" "$TCP_DIAG_LOG" socat "TCP4-LISTEN:$((port+1)),reuseaddr,fork" EXEC:/bin/cat||true
  launch_timeout "$sec" "$UDP_DIAG_PID_FILE" "$UDP_DIAG_LOG" socat "UDP4-RECVFROM:$((port+2)),reuseaddr,fork" EXEC:/bin/cat||true
  sleep 1
  if server_running&&diag_running tcp&&diag_running udp;then ok "$(role_name "$ROLE") endpoint prepared as verified temporary test target for up to $mins minutes."
  else target_start_failure;err "Check $SERVER_LOG, $TCP_DIAG_LOG, and $UDP_DIAG_LOG.";stop_server_internal;pause;return 1;fi
  pause
}
stop_server(){ stop_server_internal;ok "Test server stopped.";pause; }

show_last_report(){ if [[ -r $LAST_REPORT ]];then cat "$LAST_REPORT";elif is_root;then [[ -r $LAST_REPORT ]]&&cat "$LAST_REPORT"||warn "No saved report yet.";elif command -v sudo >/dev/null;then sudo cat "$LAST_REPORT" 2>/dev/null||warn "No saved report yet.";else warn "No saved report yet.";fi;pause; }

download_main_script(){
  local dest=$1 source
  for source in api raw cdn; do
    : >"$dest"
    case $source in
      api)
        info "Trying GitHub API: $API_URL"
        curl -fsSL --connect-timeout 8 --max-time 30 \
          -H 'Accept: application/vnd.github.raw+json' \
          -H 'X-GitHub-Api-Version: 2022-11-28' \
          -H 'User-Agent: tunnel-checker' \
          "$API_URL" -o "$dest" || { warn "GitHub API download failed."; continue; }
        ;;
      raw)
        info "Trying GitHub Raw: $RAW_URL"
        curl -fsSL --connect-timeout 8 --max-time 30 "$RAW_URL" -o "$dest" || { warn "GitHub Raw download failed."; continue; }
        ;;
      cdn)
        info "Trying jsDelivr: $CDN_URL"
        curl -fsSL --connect-timeout 8 --max-time 30 "$CDN_URL" -o "$dest" || { warn "jsDelivr download failed."; continue; }
        ;;
    esac
    if [[ -s $dest ]] && bash -n "$dest"; then return 0; fi
    warn "Downloaded content from $source was empty or invalid."
  done
  return 1
}
update_self(){ ensure_deps||{ pause;return 1;};TMP_DIR=$(mktemp -d);local f="$TMP_DIR/main";download_main_script "$f"||{ err "Could not download a valid update from GitHub API, GitHub Raw, or jsDelivr.";pause;return 1;};root mkdir -p "$INSTALL_DIR";root install -m 0755 "$f" "$INSTALL_PATH";root ln -sfn "$INSTALL_PATH" "$BIN_PATH";ok "Tunnel Checker updated to $(bash "$f" --version 2>/dev/null||printf unknown).";pause; }
uninstall_self(){ local a=n;warn "This removes Tunnel Checker files/reports but leaves shared OS packages installed.";[[ -r /dev/tty ]]&&read -r -p "Uninstall Tunnel Checker? [y/N]: " a </dev/tty||true;[[ $a =~ ^[Yy]$ ]]||return;stop_server_internal;root rm -f "$BIN_PATH";root rm -rf "$INSTALL_DIR" "$STATE_DIR" "$LOG_DIR";printf 'Tunnel Checker uninstalled. Shared packages were not removed.\n';exit 0; }

menu(){
  ensure_role||return 1
  while :;do clear 2>/dev/null||true;banner;printf '\n %b1)%b Full test: %s\n %b2)%b Quick test: %s\n %b3)%b Prepare this %s server as test target\n %b4)%b Stop test server\n %b5)%b Test server status\n %b6)%b Change endpoint role\n %b7)%b Show last summary\n %b8)%b Update Tunnel Checker\n %b9)%b Uninstall Tunnel Checker\n %b0)%b Exit\n\n' "$C$B" "$R" "$(forward_label)" "$C$B" "$R" "$(forward_label)" "$C$B" "$R" "$(role_name "$ROLE")" "$C$B" "$R" "$C$B" "$R" "$C$B" "$R" "$C$B" "$R" "$C$B" "$R" "$C$B" "$R" "$C$B" "$R"
    printf '%bRecommended workflow:%b prepare one endpoint, run Full Test from the other, then swap sides.\n\n' "$DIM" "$R"
    local c;read -r -p 'Select: ' c </dev/tty||c=0;case $c in 1)run_test full;;2)run_test quick;;3)start_server;;4)stop_server;;5)server_status;pause;;6)ROLE="";choose_role;;7)show_last_report;;8)update_self;;9)uninstall_self;;0)return;;*)warn 'Invalid option.';sleep 1;;esac
  done
}
usage(){ cat <<EOF2
Tunnel Checker v$VERSION
Usage: tunnel-checker [--full|--quick|--server|--stop|--status|--role|--last|--update|--uninstall|--version|--help]
EOF2
}
main(){ case ${1:-} in '')menu;;--full)ensure_role&&banner&&run_test full;;--quick)ensure_role&&banner&&run_test quick;;--server)ensure_role&&banner&&start_server;;--stop)stop_server;;--status)server_status;;--role)choose_role;;--last)show_last_report;;--update)update_self;;--uninstall)uninstall_self;;--version)printf '%s\n' "$VERSION";;-h|--help)usage;;*)usage;return 1;;esac; }
[[ ${TUNNEL_CHECKER_SOURCE_ONLY:-0} == 1 ]]||main "$@"
