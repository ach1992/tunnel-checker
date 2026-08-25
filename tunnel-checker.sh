#!/usr/bin/env bash
set -uo pipefail

VERSION="0.1.0"
REPO="ach1992/tunnel-checker"
INSTALL_DIR="/usr/local/lib/tunnel-checker"
INSTALL_PATH="$INSTALL_DIR/tunnel-checker.sh"
BIN_PATH="/usr/local/bin/tunnel-checker"
STATE_DIR="/var/lib/tunnel-checker"
LOG_DIR="/var/log/tunnel-checker"
PID_FILE="$STATE_DIR/iperf3.pid"
PORT_FILE="$STATE_DIR/iperf3.port"
SERVER_LOG="$LOG_DIR/iperf3.log"
LAST_REPORT="$LOG_DIR/last-report.txt"
RAW_URL="https://raw.githubusercontent.com/$REPO/main/tunnel-checker.sh"
CDN_URL="https://cdn.jsdelivr.net/gh/$REPO@main/tunnel-checker.sh"
DEFAULT_PORT=5201
DEFAULT_MBPS=50

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  R=$'\033[0m'; B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; E=$'\033[31m'; C=$'\033[36m'
else R=''; B=''; G=''; Y=''; E=''; C=''; fi

TMP_DIR=""
declare -a NAMES=() FWD=() REV=() STATES=() RECS=() DETAILS=()
PING_FWD_LOSS=""; PING_FWD_AVG=""; PING_FWD_MDEV=""; PING_REV_LOSS=""
LOAD_UP_DELTA=""; LOAD_DOWN_DELTA=""
TCP_SINGLE_FWD=""; TCP_SINGLE_REV=""; TCP_PAR_FWD=""; TCP_PAR_REV=""
TCP_RETRANS_FWD=""; TCP_RETRANS_REV=""
UDP_MAX_FWD_LOSS=""; UDP_MAX_REV_LOSS=""; UDP_MAX_FWD_JITTER=""; UDP_MAX_REV_JITTER=""
PMTU_VALUE=""; TRACEPATH_PMTU=""
IFACE_RX_ERR_DELTA=0; IFACE_RX_DROP_DELTA=0; IFACE_TX_ERR_DELTA=0; IFACE_TX_DROP_DELTA=0
IPERF_REACHABLE=0; EXPECTED_MBPS=$DEFAULT_MBPS; TEST_MODE=full
PEER_HOST=""; PEER_IP=""; IPERF_PORT=$DEFAULT_PORT; LOCAL_IFACE=""; LOCAL_SRC=""

cleanup(){ [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT
info(){ printf '%b[INFO]%b %s\n' "$C" "$R" "$*"; }
warn(){ printf '%b[WARN]%b %s\n' "$Y" "$R" "$*"; }
err(){ printf '%b[ERROR]%b %s\n' "$E" "$R" "$*" >&2; }
ok(){ printf '%b[OK]%b %s\n' "$G" "$R" "$*"; }
banner(){ printf '%bTunnel Checker v%s%b\nBidirectional tunnel-link diagnostics for Linux servers\n' "$B$C" "$VERSION" "$R"; }
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
status_speed(){ [[ -z ${1:-} ]] && { printf N/A; return; }; local r; r=$(awk -v m="$1" -v e="$2" 'BEGIN{print m/e}'); if fcompare "$r" '>=' .8; then printf GOOD; elif fcompare "$r" '>=' .5; then printf WARN; else printf BAD; fi; }

missing_packages(){
  local -a p=(); command -v curl >/dev/null||p+=(curl); command -v iperf3 >/dev/null||p+=(iperf3)
  command -v mtr >/dev/null||p+=(mtr-tiny); command -v ping >/dev/null||p+=(iputils-ping)
  command -v tracepath >/dev/null||p+=(iputils-tracepath); command -v ip >/dev/null||p+=(iproute2)
  command -v nc >/dev/null||p+=(netcat-openbsd); command -v jq >/dev/null||p+=(jq)
  command -v timeout >/dev/null||p+=(coreutils); command -v ssh >/dev/null||p+=(openssh-client)
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
  PEER_HOST=$(ask "Peer server IP/hostname" ""); [[ -n $PEER_HOST ]]||{ err "Peer is required."; return 1; }
  PEER_IP=$(resolve4 "$PEER_HOST"); [[ $PEER_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]||{ err "No usable IPv4 address."; return 1; }
  IPERF_PORT=$(ask_int "iperf3 port" "$DEFAULT_PORT" 1 65535)
  EXPECTED_MBPS=$(ask_int "Expected tunnel bandwidth (Mbps)" "$DEFAULT_MBPS" 1 100000)
  local rt; rt=$(ip -4 route get "$PEER_IP" 2>/dev/null|head -1||true)
  LOCAL_IFACE=$(awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'<<<"$rt")
  LOCAL_SRC=$(awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'<<<"$rt")
  info "Peer: $PEER_HOST -> $PEER_IP"; info "Route: ${rt:-unavailable}"
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
  row "ICMP avg RTT" "$(fmt "$PING_FWD_AVG" 2) ms" N/A "$(status_jit "$PING_FWD_MDEV")"
  row "ICMP RTT variation" "$(fmt "$PING_FWD_MDEV" 2) ms" N/A "$(status_jit "$PING_FWD_MDEV")"
  [[ -n $PING_FWD_LOSS ]]&&fcompare "$PING_FWD_LOSS" '>' 1&&rec "Packet loss is above 1%; expect retransmissions, stalls, or unstable tunnel latency."
}
iperf_ok(){ nc -z -w 4 "$PEER_IP" "$IPERF_PORT" >/dev/null 2>&1; }
tcp_once(){
  local rev=$1 streams=$2 seconds=$3 f=$4; local -a c=(iperf3 -c "$PEER_IP" -p "$IPERF_PORT" -P "$streams" -t "$seconds" -J)
  [[ $rev == 1 ]]&&c+=(-R); timeout $((seconds+15)) "${c[@]}" >"$f" 2>"$f.err"||return 1; jq -e .end "$f" >/dev/null 2>&1
}
tcp_mbps(){ jq -r '(.end.sum_received.bits_per_second//.end.sum.bits_per_second//.end.sum_sent.bits_per_second//empty)/1000000' "$1" 2>/dev/null; }
tcp_ret(){ jq -r '.end.sum_sent.retransmits//empty' "$1" 2>/dev/null; }
tcp_tests(){
  local s=$1 f r; if ! iperf_ok; then row "iperf3 control port" "Blocked/closed" - BAD; rec "Start the temporary iperf3 server on the peer and allow TCP/UDP $IPERF_PORT from this server."; return; fi
  IPERF_REACHABLE=1; row "iperf3 control port" Reachable - GOOD
  f="$TMP_DIR/t1f"; r="$TMP_DIR/t1r"; info "TCP single-stream both directions..."
  tcp_once 0 1 "$s" "$f"&&{ TCP_SINGLE_FWD=$(tcp_mbps "$f"); TCP_RETRANS_FWD=$(tcp_ret "$f"); }
  tcp_once 1 1 "$s" "$r"&&{ TCP_SINGLE_REV=$(tcp_mbps "$r"); TCP_RETRANS_REV=$(tcp_ret "$r"); }
  row "TCP single stream" "$(fmt "$TCP_SINGLE_FWD" 1) Mbps" "$(fmt "$TCP_SINGLE_REV" 1) Mbps" "$(status_speed "${TCP_SINGLE_FWD:-0}" "$EXPECTED_MBPS")"
  [[ $TEST_MODE == full ]]||return
  f="$TMP_DIR/t4f"; r="$TMP_DIR/t4r"; info "TCP 4-stream both directions..."
  tcp_once 0 4 "$s" "$f"&&TCP_PAR_FWD=$(tcp_mbps "$f"); tcp_once 1 4 "$s" "$r"&&TCP_PAR_REV=$(tcp_mbps "$r")
  local st=GOOD; [[ $(status_speed "${TCP_PAR_FWD:-0}" "$EXPECTED_MBPS") == BAD || $(status_speed "${TCP_PAR_REV:-0}" "$EXPECTED_MBPS") == BAD ]]&&st=BAD
  row "TCP 4 parallel" "$(fmt "$TCP_PAR_FWD" 1) Mbps" "$(fmt "$TCP_PAR_REV" 1) Mbps" "$st"
  row "TCP retransmits" "${TCP_RETRANS_FWD:-N/A}" "${TCP_RETRANS_REV:-N/A}" N/A
  if [[ -n $TCP_PAR_FWD && -n $TCP_PAR_REV ]]; then local hi lo ratio; if fcompare "$TCP_PAR_FWD" '>=' "$TCP_PAR_REV"; then hi=$TCP_PAR_FWD;lo=$TCP_PAR_REV;else hi=$TCP_PAR_REV;lo=$TCP_PAR_FWD;fi; ratio=$(awk -v l="$lo" -v h="$hi" 'BEGIN{print l/h}'); fcompare "$ratio" '<' .5&&rec "TCP is strongly asymmetric; inspect provider routing, congestion, or shaping in the slower direction."; fi
}

loaded_latency(){
  [[ $TEST_MODE == full && $IPERF_REACHABLE -eq 1 && -n $PING_FWD_AVG ]]||return
  local rev label lf pf pid p loss avg md delta st up=N/A down=N/A overall=N/A
  for rev in 0 1; do [[ $rev == 0 ]]&&label=upload||label=download; lf="$TMP_DIR/load-$label"; pf="$TMP_DIR/lping-$label"
    local -a c=(iperf3 -c "$PEER_IP" -p "$IPERF_PORT" -P 4 -t 10 -J); [[ $rev == 1 ]]&&c+=(-R)
    info "RTT under $label load..."; timeout 25 "${c[@]}" >"$lf" 2>&1 & pid=$!; sleep 2; LC_ALL=C ping -4 -n -q -c 25 -i .2 -W 2 "$PEER_IP" >"$pf" 2>&1||true; wait "$pid" 2>/dev/null||true
    p=$(parse_ping "$pf"); IFS='|' read -r loss avg md<<<"$p"; [[ -z $avg ]]&&continue; delta=$(awk -v a="$avg" -v b="$PING_FWD_AVG" 'BEGIN{d=a-b;if(d<0)d=0;print d}')
    if [[ $rev == 0 ]];then LOAD_UP_DELTA=$delta;up="+$(fmt "$delta" 1) ms";else LOAD_DOWN_DELTA=$delta;down="+$(fmt "$delta" 1) ms";fi
  done
  local worst=0 v; for v in "${LOAD_UP_DELTA:-}" "${LOAD_DOWN_DELTA:-}";do [[ -n $v ]]&&fcompare "$v" '>' "$worst"&&worst=$v;done
  if fcompare "$worst" '<=' 15;then overall=GOOD;elif fcompare "$worst" '<=' 40;then overall=WARN;else overall=BAD;fi
  row "Loaded RTT increase" "$up" "$down" "$overall"; [[ $overall == BAD ]]&&rec "Latency rises sharply under load; queueing/bufferbloat or congestion can break tunnel responsiveness despite good idle ping."
}

udp_once(){ local rev=$1 rate=$2 f=$3; local -a c=(iperf3 -c "$PEER_IP" -p "$IPERF_PORT" -u -b "${rate}M" -t 7 -J); [[ $rev == 1 ]]&&c+=(-R); timeout 22 "${c[@]}" >"$f" 2>&1||return 1; jq -e .end.sum "$f" >/dev/null 2>&1; }
udp_field(){ case $2 in mbps) jq -r '(.end.sum.bits_per_second//empty)/1000000' "$1";;loss) jq -r '.end.sum.lost_percent//empty' "$1";;jit) jq -r '.end.sum.jitter_ms//empty' "$1";;esac 2>/dev/null; }
udp_tests(){
  [[ $TEST_MODE == full && $IPERF_REACHABLE -eq 1 ]]||return; local rate f r fm rm fl rl fj rj st
  local -a rates=($((EXPECTED_MBPS/4)) $((EXPECTED_MBPS/2)) "$EXPECTED_MBPS"); ((rates[0]<1))&&rates[0]=1;((rates[1]<1))&&rates[1]=1
  for rate in "${rates[@]}";do f="$TMP_DIR/uf$rate";r="$TMP_DIR/ur$rate"; info "UDP ${rate} Mbps both directions..."
    fm="";rm="";fl="";rl="";fj="";rj=""; udp_once 0 "$rate" "$f"&&{ fm=$(udp_field "$f" mbps);fl=$(udp_field "$f" loss);fj=$(udp_field "$f" jit); }; udp_once 1 "$rate" "$r"&&{ rm=$(udp_field "$r" mbps);rl=$(udp_field "$r" loss);rj=$(udp_field "$r" jit); }
    st=GOOD; [[ $(status_loss "$fl") == BAD || $(status_loss "$rl") == BAD || $(status_jit "$fj") == BAD || $(status_jit "$rj") == BAD ]]&&st=BAD
    row "UDP ${rate}M loss/jitter" "$(fmt "$fl" 2)% / $(fmt "$fj" 2)ms" "$(fmt "$rl" 2)% / $(fmt "$rj" 2)ms" "$st"
    if ((rate==EXPECTED_MBPS));then UDP_MAX_FWD_LOSS=$fl;UDP_MAX_REV_LOSS=$rl;UDP_MAX_FWD_JITTER=$fj;UDP_MAX_REV_JITTER=$rj;fi
  done
  local w=0 v;for v in "${UDP_MAX_FWD_LOSS:-}" "${UDP_MAX_REV_LOSS:-}";do [[ -n $v ]]&&fcompare "$v" '>' "$w"&&w=$v;done; fcompare "$w" '>' 1&&rec "UDP loss exceeds 1% at the intended rate; lower the target load or prefer another route/server."
}

iface_stats(){ local j; [[ -n $LOCAL_IFACE ]]||{ printf '0|0|0|0';return;}; j=$(ip -j -s link show dev "$LOCAL_IFACE" 2>/dev/null||true); jq -r '.[0].stats64 as $s|[($s.rx.errors//0),($s.rx.dropped//0),($s.tx.errors//0),($s.tx.dropped//0)]|@tsv'<<<"$j" 2>/dev/null|tr '\t' '|'||printf '0|0|0|0'; }
iface_delta(){ local b=$1 a=$2 br bd bt btd ar ad at atd;IFS='|' read -r br bd bt btd<<<"$b";IFS='|' read -r ar ad at atd<<<"$a";IFACE_RX_ERR_DELTA=$((ar-br));IFACE_RX_DROP_DELTA=$((ad-bd));IFACE_TX_ERR_DELTA=$((at-bt));IFACE_TX_DROP_DELTA=$((atd-btd));local st=GOOD;((IFACE_RX_ERR_DELTA+IFACE_TX_ERR_DELTA>0))&&st=BAD;((IFACE_RX_DROP_DELTA+IFACE_TX_DROP_DELTA>0))&&[[ $st == GOOD ]]&&st=WARN;row "Local interface err/drop" "RX $IFACE_RX_ERR_DELTA/$IFACE_RX_DROP_DELTA" "TX $IFACE_TX_ERR_DELTA/$IFACE_TX_DROP_DELTA" "$st"; [[ $st != GOOD ]]&&rec "Local interface counters increased; inspect NIC/vNIC, host load, qdisc, and provider limits."; }

path_tests(){
  [[ $TEST_MODE == full ]]||return; local f="$TMP_DIR/tracepath.txt"; info "tracepath and PMTU..."; timeout 45 tracepath -4 -n -p "$IPERF_PORT" "$PEER_IP" >"$f" 2>&1||true; TRACEPATH_PMTU=$(grep -Eo 'pmtu[[:space:]]+[0-9]+' "$f"|tail -1|awk '{print $2}'||true); detail TRACEPATH "$f"
  if ping -4 -n -M do -s 56 -c 1 -W 1 "$PEER_IP" >/dev/null 2>&1;then local mtu=1500 d lo=0 hi mid; [[ -n $LOCAL_IFACE ]]&&d=$(ip -o link show "$LOCAL_IFACE"|awk '{for(i=1;i<=NF;i++)if($i=="mtu"){print $(i+1);exit}}');[[ ${d:-} =~ ^[0-9]+$ ]]&&mtu=$d;((mtu>9000))&&mtu=9000;hi=$((mtu-28));while ((lo<hi));do mid=$(((lo+hi+1)/2));if ping -4 -n -M do -s "$mid" -c 1 -W 1 "$PEER_IP" >/dev/null 2>&1;then lo=$mid;else hi=$((mid-1));fi;done;PMTU_VALUE=$((lo+28)); local st=GOOD;((PMTU_VALUE<1300))&&st=BAD;((PMTU_VALUE>=1300&&PMTU_VALUE<1400))&&st=WARN;row "Path MTU (ICMP DF)" "$PMTU_VALUE bytes" N/A "$st";((PMTU_VALUE<1400))&&rec "Path MTU is low; account for tunnel overhead to avoid fragmentation or stalled large transfers.";else row "Path MTU (ICMP DF)" N/A N/A N/A;fi
  [[ -n $TRACEPATH_PMTU ]]&&row "Path MTU (tracepath)" "$TRACEPATH_PMTU bytes" N/A "$([[ $TRACEPATH_PMTU -ge 1400 ]]&&printf GOOD||printf WARN)"
  local type cmd out;for type in ICMP TCP UDP;do out="$TMP_DIR/mtr-$type.txt";case $type in ICMP)cmd="mtr -4 -n -r -w -c 20 $PEER_IP";;TCP)cmd="mtr -4 -n -r -w -c 20 -T -P $IPERF_PORT $PEER_IP";;UDP)cmd="mtr -4 -n -r -w -c 20 -u -P $IPERF_PORT $PEER_IP";;esac;info "MTR $type path...";timeout 50 bash -c "$cmd" >"$out" 2>&1||true;detail "MTR $type" "$out";done
}

reverse_ssh(){
  [[ $TEST_MODE == full ]]||return; local a=n;[[ -r /dev/tty ]]&&read -r -p "Run true reverse-path diagnostics over existing SSH? [y/N]: " a </dev/tty||true;[[ $a =~ ^[Yy]$ ]]||{ row "True reverse route" - "Not measured" N/A;return; }
  local target callback out p avg md;target=$(ask "SSH target" "root@$PEER_HOST");callback=$(ask "Local IP for peer to probe" "$LOCAL_SRC");[[ $callback =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]||{ row "True reverse route" - "Invalid callback" N/A;return; }
  ssh -o ConnectTimeout=7 "$target" 'printf ok' 2>/dev/null|grep -q ok||{ row "True reverse route" - "SSH unavailable" N/A;return; }
  out="$TMP_DIR/reverse.txt";ssh -o ConnectTimeout=7 "$target" "LC_ALL=C ping -4 -n -q -c 30 -i .2 -W 2 '$callback'; echo '--- ROUTE ---'; ip -4 route get '$callback'; echo '--- MTR ICMP ---'; mtr -4 -n -r -w -c 20 '$callback' 2>&1||true; echo '--- MTR TCP ---'; mtr -4 -n -r -w -c 20 -T -P '$IPERF_PORT' '$callback' 2>&1||true; echo '--- MTR UDP ---'; mtr -4 -n -r -w -c 20 -u -P '$IPERF_PORT' '$callback' 2>&1||true" >"$out" 2>&1||true
  p=$(parse_ping "$out");IFS='|' read -r PING_REV_LOSS avg md<<<"$p";row "Reverse ICMP loss" - "${PING_REV_LOSS:+$PING_REV_LOSS%}" "$(status_loss "$PING_REV_LOSS")";detail "TRUE REVERSE PATH (SSH)" "$out"
}

score_loss(){ [[ -z ${1:-} ]]&&{ echo 0;return;};if fcompare "$1" '<=' .2;then echo 0;elif fcompare "$1" '<=' .5;then echo 4;elif fcompare "$1" '<=' 1;then echo 8;elif fcompare "$1" '<=' 2;then echo 15;else echo 25;fi; }
score_jit(){ [[ -z ${1:-} ]]&&{ echo 0;return;};if fcompare "$1" '<=' 5;then echo 0;elif fcompare "$1" '<=' 10;then echo 3;elif fcompare "$1" '<=' 20;then echo 7;elif fcompare "$1" '<=' 40;then echo 12;else echo 18;fi; }
compute_score(){
  local s=100 d v worst=0;d=$(score_loss "$PING_FWD_LOSS");s=$((s-d));d=$(score_jit "$PING_FWD_MDEV");s=$((s-d))
  if [[ $TEST_MODE == full ]];then for v in "${UDP_MAX_FWD_LOSS:-}" "${UDP_MAX_REV_LOSS:-}";do [[ -n $v ]]&&fcompare "$v" '>' "$worst"&&worst=$v;done;d=$(score_loss "$worst");s=$((s-d));worst=0;for v in "${UDP_MAX_FWD_JITTER:-}" "${UDP_MAX_REV_JITTER:-}";do [[ -n $v ]]&&fcompare "$v" '>' "$worst"&&worst=$v;done;d=$(score_jit "$worst");s=$((s-d));fi
  local tf=${TCP_PAR_FWD:-$TCP_SINGLE_FWD} tr=${TCP_PAR_REV:-$TCP_SINGLE_REV} complete=1
  if [[ -n $tf && -n $tr ]];then local slow hi ratio asym;if fcompare "$tf" '<' "$tr";then slow=$tf;hi=$tr;else slow=$tr;hi=$tf;fi;ratio=$(awk -v m="$slow" -v e="$EXPECTED_MBPS" 'BEGIN{print m/e}');if fcompare "$ratio" '<' .3;then s=$((s-20));elif fcompare "$ratio" '<' .5;then s=$((s-14));elif fcompare "$ratio" '<' .7;then s=$((s-8));elif fcompare "$ratio" '<' .9;then s=$((s-3));fi;asym=$(awk -v l="$slow" -v h="$hi" 'BEGIN{print l/h}');fcompare "$asym" '<' .3&&s=$((s-10));fcompare "$asym" '>=' .3&&fcompare "$asym" '<' .5&&s=$((s-6));else complete=0;s=$((s-30));fi
  worst=0;for v in "${LOAD_UP_DELTA:-}" "${LOAD_DOWN_DELTA:-}";do [[ -n $v ]]&&fcompare "$v" '>' "$worst"&&worst=$v;done;fcompare "$worst" '>' 80&&s=$((s-10));fcompare "$worst" '<=' 80&&fcompare "$worst" '>' 40&&s=$((s-6));fcompare "$worst" '<=' 40&&fcompare "$worst" '>' 15&&s=$((s-3))
  [[ -n $PMTU_VALUE ]]&&((PMTU_VALUE<1300))&&s=$((s-10));[[ -n $PMTU_VALUE ]]&&((PMTU_VALUE>=1300&&PMTU_VALUE<1400))&&s=$((s-5));((IFACE_RX_ERR_DELTA+IFACE_TX_ERR_DELTA>0))&&s=$((s-8));((IFACE_RX_DROP_DELTA+IFACE_TX_DROP_DELTA>0))&&s=$((s-4));((s<0))&&s=0
  local vrd;if ((complete==0));then vrd=INCOMPLETE;elif ((s>=90));then vrd=EXCELLENT;elif ((s>=75));then vrd=GOOD;elif ((s>=55));then vrd=MARGINAL;else vrd=POOR;fi;printf '%s|%s' "$s" "$vrd"
}

print_report(){
  local sv=$1 verdict=$2 i d title file;printf '\n%-29s %-24s %-24s %-10s\n' METRIC FORWARD REVERSE STATUS;printf '%s\n' '------------------------------------------------------------------------------------------'
  for((i=0;i<${#NAMES[@]};i++));do printf '%-29.29s %-24.24s %-24.24s %-10.10s\n' "${NAMES[i]}" "${FWD[i]}" "${REV[i]}" "${STATES[i]}";done
  printf '\n%bTunnel suitability: %s/100 — %s%b\n' "$B" "$sv" "$verdict" "$R";printf '%bRecommendations%b\n' "$B" "$R";if((${#RECS[@]}==0));then printf '%s\n' '- No major issue was detected in measured signals.';else for d in "${RECS[@]}";do printf -- '- %s\n' "$d";done;fi
  if [[ $TEST_MODE == full ]];then for d in "${DETAILS[@]}";do title=${d%%|*};file=${d#*|};printf '\n%b=== %s ===%b\n' "$B" "$title" "$R";[[ -s $file ]]&&cat "$file"||printf 'Unavailable/blocked.\n';done;fi
}
save_report(){ root mkdir -p "$LOG_DIR" >/dev/null 2>&1||return; local tmp="$TMP_DIR/report";{ printf 'Tunnel Checker v%s\nPeer: %s (%s)\nExpected: %s Mbps\n\n' "$VERSION" "$PEER_HOST" "$PEER_IP" "$EXPECTED_MBPS";for((i=0;i<${#NAMES[@]};i++));do printf '%s | %s | %s | %s\n' "${NAMES[i]}" "${FWD[i]}" "${REV[i]}" "${STATES[i]}";done;} >"$tmp";root cp "$tmp" "$LAST_REPORT"; }
reset_state(){ NAMES=();FWD=();REV=();STATES=();RECS=();DETAILS=();PING_FWD_LOSS="";PING_FWD_AVG="";PING_FWD_MDEV="";PING_REV_LOSS="";LOAD_UP_DELTA="";LOAD_DOWN_DELTA="";TCP_SINGLE_FWD="";TCP_SINGLE_REV="";TCP_PAR_FWD="";TCP_PAR_REV="";TCP_RETRANS_FWD="";TCP_RETRANS_REV="";UDP_MAX_FWD_LOSS="";UDP_MAX_REV_LOSS="";UDP_MAX_FWD_JITTER="";UDP_MAX_REV_JITTER="";PMTU_VALUE="";TRACEPATH_PMTU="";IFACE_RX_ERR_DELTA=0;IFACE_RX_DROP_DELTA=0;IFACE_TX_ERR_DELTA=0;IFACE_TX_DROP_DELTA=0;IPERF_REACHABLE=0; }
run_test(){ TEST_MODE=$1;ensure_deps||{ pause;return 1;};reset_state;TMP_DIR=$(mktemp -d);prepare||{ pause;return 1;};local before after;before=$(iface_stats);[[ $TEST_MODE == quick ]]&&ping_test 15||ping_test 50;[[ $TEST_MODE == quick ]]&&tcp_tests 5||tcp_tests 10;loaded_latency;udp_tests;after=$(iface_stats);iface_delta "$before" "$after";path_tests;reverse_ssh;local sc score verdict;sc=$(compute_score);IFS='|' read -r score verdict<<<"$sc";[[ $verdict == INCOMPLETE ]]&&rec "Bidirectional iperf3 data was incomplete, so the score has low confidence.";print_report "$score" "$verdict";save_report;printf '\nLast summary: %s\n' "$LAST_REPORT";pause; }

server_running(){ [[ -f $PID_FILE ]]||return 1;local p;p=$(cat "$PID_FILE" 2>/dev/null||true);[[ $p =~ ^[0-9]+$ ]]&&kill -0 "$p" 2>/dev/null; }
server_status(){ if server_running;then printf 'Status: RUNNING\nPID: %s\nPort: %s TCP/UDP\n' "$(cat "$PID_FILE")" "$(cat "$PORT_FILE" 2>/dev/null||echo '?')";else printf 'Status: STOPPED\n';fi; }
start_server(){ ensure_deps||{ pause;return 1;};server_running&&{ server_status;pause;return;};local port mins sec;port=$(ask_int "iperf3 server port" "$DEFAULT_PORT" 1 65535);mins=$(ask_int "Automatic shutdown after minutes" 30 1 240);ss -ltnH "sport = :$port" 2>/dev/null|grep -q .&&{ err "TCP port $port is already in use.";pause;return 1;};root mkdir -p "$STATE_DIR" "$LOG_DIR"||return;warn "iperf3 has no authentication. Restrict TCP/UDP $port to the testing peer when possible.";warn "Tunnel Checker does not change firewall rules.";sec=$((mins*60));if is_root;then nohup timeout --signal=TERM "$sec" iperf3 -s -p "$port" >"$SERVER_LOG" 2>&1 & printf '%s\n' $! >"$PID_FILE";printf '%s\n' "$port" >"$PORT_FILE";else sudo bash -c "nohup timeout --signal=TERM '$sec' iperf3 -s -p '$port' >'$SERVER_LOG' 2>&1 & echo \$! >'$PID_FILE'; echo '$port' >'$PORT_FILE'";fi;sleep 1;server_running&&ok "Temporary iperf3 server started for up to $mins minutes."||err "Server failed to start; check $SERVER_LOG";pause; }
stop_server(){ if server_running;then local p;p=$(cat "$PID_FILE");root pkill -TERM -P "$p" 2>/dev/null||true;root kill -TERM "$p" 2>/dev/null||true;fi;root rm -f "$PID_FILE" "$PORT_FILE";ok "Test server stopped.";pause; }

update_self(){ ensure_deps||{ pause;return 1;};TMP_DIR=$(mktemp -d);local f="$TMP_DIR/main" u good=0;for u in "$RAW_URL" "$CDN_URL";do info "Trying $u";if curl -fsSL --connect-timeout 10 --max-time 30 "$u" -o "$f"&&[[ -s $f ]]&&bash -n "$f";then good=1;break;fi;done;((good))||{ err "Could not download a valid update.";pause;return 1;};root mkdir -p "$INSTALL_DIR";root install -m 0755 "$f" "$INSTALL_PATH";root ln -sfn "$INSTALL_PATH" "$BIN_PATH";ok "Tunnel Checker updated.";pause; }
uninstall_self(){ local a=n;warn "This removes Tunnel Checker files/reports but leaves shared OS packages installed.";[[ -r /dev/tty ]]&&read -r -p "Uninstall Tunnel Checker? [y/N]: " a </dev/tty||true;[[ $a =~ ^[Yy]$ ]]||return;server_running&&{ local p;p=$(cat "$PID_FILE");root pkill -TERM -P "$p" 2>/dev/null||true;root kill -TERM "$p" 2>/dev/null||true;};root rm -f "$BIN_PATH";root rm -rf "$INSTALL_DIR" "$STATE_DIR" "$LOG_DIR";printf 'Tunnel Checker uninstalled. Shared packages were not removed.\n';exit 0; }

menu(){ while :;do clear 2>/dev/null||true;banner;printf '\n1) Full tunnel-link test\n2) Quick test\n3) Start temporary iperf3 test server\n4) Stop test server\n5) Test server status\n6) Update Tunnel Checker\n7) Uninstall Tunnel Checker\n8) Exit\n\n';local c;read -r -p 'Select: ' c </dev/tty||c=8;case $c in 1)run_test full;;2)run_test quick;;3)start_server;;4)stop_server;;5)server_status;pause;;6)update_self;;7)uninstall_self;;8)return;;*)warn 'Invalid option.';sleep 1;;esac;done; }
usage(){ cat <<EOF2
Tunnel Checker v$VERSION
Usage: tunnel-checker [--full|--quick|--server|--stop|--status|--update|--uninstall|--version|--help]
EOF2
}
main(){ case ${1:-} in '')menu;;--full)banner;run_test full;;--quick)banner;run_test quick;;--server)banner;start_server;;--stop)stop_server;;--status)server_status;;--update)update_self;;--uninstall)uninstall_self;;--version)printf '%s\n' "$VERSION";;-h|--help)usage;;*)usage;return 1;;esac; }
[[ ${TUNNEL_CHECKER_SOURCE_ONLY:-0} == 1 ]]||main "$@"
