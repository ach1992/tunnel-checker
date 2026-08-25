#!/usr/bin/env bash

set -euo pipefail

REPO="ach1992/tunnel-checker"
INSTALL_DIR="/usr/local/lib/tunnel-checker"
INSTALL_PATH="${INSTALL_DIR}/tunnel-checker.sh"
BIN_PATH="/usr/local/bin/tunnel-checker"
STATE_DIR="/var/lib/tunnel-checker"
LOG_DIR="/var/log/tunnel-checker"
API_URL="https://api.github.com/repos/${REPO}/contents/tunnel-checker.sh?ref=main"
RAW_URL="https://raw.githubusercontent.com/${REPO}/main/tunnel-checker.sh"
CDN_URL="https://cdn.jsdelivr.net/gh/${REPO}@main/tunnel-checker.sh"

say() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run the installer as root, for example: curl ... | sudo bash"
[[ -r /etc/os-release ]] || fail "Cannot identify this Linux distribution."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]] || fail "Automatic installation currently supports Debian/Ubuntu only."

command -v curl >/dev/null 2>&1 || fail "curl is required to bootstrap Tunnel Checker."

packages=(
    ca-certificates
    curl
    iperf3
    mtr-tiny
    iputils-ping
    iputils-tracepath
    iproute2
    netcat-openbsd
    jq
    coreutils
)

missing=()
command -v iperf3 >/dev/null 2>&1 || missing+=(iperf3)
command -v mtr >/dev/null 2>&1 || missing+=(mtr-tiny)
command -v ping >/dev/null 2>&1 || missing+=(iputils-ping)
command -v tracepath >/dev/null 2>&1 || missing+=(iputils-tracepath)
command -v ip >/dev/null 2>&1 || missing+=(iproute2)
command -v ss >/dev/null 2>&1 || missing+=(iproute2)
command -v nc >/dev/null 2>&1 || missing+=(netcat-openbsd)
command -v jq >/dev/null 2>&1 || missing+=(jq)
command -v timeout >/dev/null 2>&1 || missing+=(coreutils)

if (( ${#missing[@]} > 0 )); then
    say "Installing required packages: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "${packages[@]}"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

success=0
for source in api raw cdn; do
    : >"$tmp"
    case "$source" in
        api)
            say "Downloading Tunnel Checker from GitHub API"
            curl -fsSL --connect-timeout 8 --max-time 30 \
                -H 'Accept: application/vnd.github.raw+json' \
                -H 'X-GitHub-Api-Version: 2022-11-28' \
                -H 'User-Agent: tunnel-checker' \
                "$API_URL" -o "$tmp" || continue
            ;;
        raw)
            say "Downloading Tunnel Checker from GitHub Raw"
            curl -fsSL --connect-timeout 8 --max-time 30 "$RAW_URL" -o "$tmp" || continue
            ;;
        cdn)
            say "Downloading Tunnel Checker from jsDelivr"
            curl -fsSL --connect-timeout 8 --max-time 30 "$CDN_URL" -o "$tmp" || continue
            ;;
    esac
    if [[ -s "$tmp" ]] && bash -n "$tmp"; then
        success=1
        break
    fi
done

(( success == 1 )) || fail "Could not download a valid Tunnel Checker script from GitHub API, GitHub Raw, or jsDelivr."

install -d -m 0755 "$INSTALL_DIR" "$STATE_DIR" "$LOG_DIR"
install -m 0755 "$tmp" "$INSTALL_PATH"
ln -sfn "$INSTALL_PATH" "$BIN_PATH"

version="$($BIN_PATH --version 2>/dev/null || true)"
say "Tunnel Checker ${version:-installed} is ready."
say "Run: sudo tunnel-checker"
say "The tool never opens firewall ports automatically."
