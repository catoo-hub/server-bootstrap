#!/usr/bin/env bash
# ==============================================================================
#  server-bootstrap.sh — Production-ready server/node setup script
#  Supports: Debian 12+ / Ubuntu 22.04+  |  Requires: root
#  Modes: base | node | gate | relay | custom
#
#  Usage (interactive):   bash server-bootstrap.sh
#  Usage (non-interactive): bash server-bootstrap.sh --mode node [--options]
#
#  Author:  Kitsura VPN
#  Version: 1.0.3
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 · CONSTANTS & GLOBALS
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="1.0.4"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/server-bootstrap.log"
readonly CONFIG_FILE="/etc/server-bootstrap.conf"
readonly STATE_FILE="/etc/server-bootstrap.state"
readonly SYSCTL_FILE="/etc/sysctl.d/99-custom-network.conf"
readonly BACKUP_DIR="/var/backups/server-bootstrap"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# ── Runtime flags (set via CLI args) ─────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
NON_INTERACTIVE=false
SKIP_SELFSTEAL=false
SKIP_UPDATE=false
RESUME=false       # Resume interrupted install (skip already-OK steps)
UNINSTALL=false    # Uninstall mode
MODE=""         # base | node | gate | relay | custom
GATE_ADDRESS="" # used in relay mode
RELAY_ADDRESS=""  # Relay: this server's IP (auto-detected if empty)
RELAY_PORT="443"  # Relay: port haproxy binds on
GATE_PORT="9443"  # Relay: port on gate (recommended: NOT 443)
ALLOWED_LST_URL="https://raw.githubusercontent.com/catoo-hub/server-bootstrap/main/allowed.lst"  # Relay: URL to fetch allowed.lst; empty = use whois/RADB

# ── Auto-detect pipe mode (curl URL | bash kills stdin) ───────────────────────
# If stdin is NOT a terminal, force non-interactive to protect all `read` calls.
# Correct curl usage:  bash <(curl -Ls URL) [--args]   ← stdin = tty, OK
# Broken curl usage:   curl -Ls URL | bash              ← stdin = pipe, force -y
if [[ ! -t 0 ]]; then
    NON_INTERACTIVE=true
fi

# ── State tracking for summary ────────────────────────────────────────────────
declare -A STEP_STATUS=()

# ── Changelog (version → description of changes) ─────────────────────────────
# Used when version mismatch is detected to show what changed between installs.
declare -A CHANGELOG=(
    ["1.0.0"]="Initial release: base/node/gate/relay modes, HAProxy 2.8, UFW, fail2ban, remnanode, selfsteal, mobile443-filter"
    ["1.0.1"]="HAProxy relay mode: SNI-based routing, RELAY_ADDRESS/GATE_PORT params, PPA install chain"
    ["1.0.2"]="allowed.lst: URL fetch mode (GitHub raw) with If-Modified-Since, cron 3x daily + 10/16/22h refresh. State engine: resume interrupted installs, per-step tracking. Uninstall menu per component."
    ["1.0.3"]="Version tracking in logs (session header). Changelog display on upgrade. Soft-update mode: backup configs before re-running changed components, merge/restore on failure."
    ["1.0.4"]="HAProxy relay: silent-drop backends (no blackhole server), daemon+nbthread+tunnel timeout, stats HTTP page :8404, systemd Restart=always drop-in, graceful reload. Gate mode: HAProxy-native blocking replaces mobile443-filter (blocked.lst+allowed.lst on gate). Monitoring: Prometheus+Grafana Docker Compose stack with HAProxy+Node Exporter dashboards, provisioned at /opt/monitoring."
)

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 · COLOURS & LOGGING
# ─────────────────────────────────────────────────────────────────────────────

# Detect colour support
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null && [[ "$(tput colors)" -ge 8 ]]; then
    RED='\033[0;31m';    LRED='\033[1;31m'
    GREEN='\033[0;32m';  LGREEN='\033[1;32m'
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'
    CYAN='\033[0;36m';   MAGENTA='\033[0;35m'
    WHITE='\033[1;37m';  GRAY='\033[0;37m'
    BOLD='\033[1m';      RESET='\033[0m'
else
    RED=''; LRED=''; GREEN=''; LGREEN=''; YELLOW=''
    BLUE=''; CYAN=''; MAGENTA=''; WHITE=''; GRAY=''
    BOLD=''; RESET=''
fi

# ── Ensure log directory exists ───────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/server-bootstrap.log"

_log_raw() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
# Write a session header banner to the log file (called once in main)
_log_session_header() {
    printf '\n%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"
    printf '%s  [SESSION] server-bootstrap v%s | mode=%s | PID=%s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$SCRIPT_VERSION" \
        "${MODE:-unknown}" \
        "$$" \
        "$(uname -n 2>/dev/null || echo 'unknown')" >> "$LOG_FILE"
    printf '%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"
}

log_info()    { echo -e "  ${GREEN}[INFO]${RESET}  $*"; _log_raw "[INFO]  $*"; }
log_ok()      { echo -e "  ${LGREEN}[ OK ]${RESET}  $*"; _log_raw "[ OK ]  $*"; }
log_warn()    { echo -e "  ${YELLOW}[WARN]${RESET}  $*" >&2; _log_raw "[WARN]  $*"; }
log_error()   { echo -e "  ${LRED}[ERR ]${RESET}  $*" >&2; _log_raw "[ERR ]  $*"; }
log_step()    { echo -e "\n${BOLD}${CYAN}══ $* ${RESET}"; _log_raw "═══ $*"; }
log_debug()   { if [[ "$VERBOSE" == true ]]; then echo -e "  ${GRAY}[DBG ]${RESET}  $*"; fi; _log_raw "[DBG ]  $*"; }
log_dry()     { echo -e "  ${MAGENTA}[DRY ]${RESET}  $*"; _log_raw "[DRY ]  $*"; }

# Fancy header
print_header() {
    echo -e "${BOLD}${BLUE}"
    cat <<'EOF'
  ╔═══════════════════════════════════════════════════════╗
  ║         SERVER BOOTSTRAP  ·  v1.0.4                  ║
  ║         Debian 12+ / Ubuntu 22.04+  |  root only     ║
  ╚═══════════════════════════════════════════════════════╝
EOF
    echo -e "${RESET}"
}

print_separator() { echo -e "${GRAY}  ────────────────────────────────────────────────────${RESET}"; }

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 · TRAP & ERROR HANDLING
# ─────────────────────────────────────────────────────────────────────────────

_on_error() {
    local exit_code=$?
    local line_num=$1
    log_error "Script failed at line ${line_num} (exit code: ${exit_code})"
    log_error "Check log: ${LOG_FILE}"
    exit "$exit_code"
}

_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Abnormal exit (code ${exit_code}). Review ${LOG_FILE}"
    fi
}

trap '_on_error $LINENO' ERR
trap '_on_exit'          EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 · PREFLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root. Use: sudo bash ${SCRIPT_NAME}"
        exit 1
    fi
    log_debug "Running as root — OK"
}

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS: /etc/os-release not found"
        exit 1
    fi
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-0}"
    OS_PRETTY="${PRETTY_NAME:-unknown}"
    ARCH="$(uname -m)"

    log_info "Detected OS : ${OS_PRETTY}"
    log_info "Architecture: ${ARCH}"

    case "$OS_ID" in
        debian)
            if (( $(echo "$OS_VERSION_ID < 12" | bc -l) )); then
                log_error "Debian < 12 is not supported. Detected: ${OS_VERSION_ID}"
                exit 1
            fi
            PKG_MGR="apt-get"
            ;;
        ubuntu)
            # VERSION_ID is like "22.04"
            local major
            major="$(echo "$OS_VERSION_ID" | cut -d. -f1)"
            if (( major < 22 )); then
                log_error "Ubuntu < 22.04 is not supported. Detected: ${OS_VERSION_ID}"
                exit 1
            fi
            PKG_MGR="apt-get"
            ;;
        *)
            log_warn "Unsupported OS: ${OS_ID}. Proceeding anyway — use at your own risk."
            PKG_MGR="apt-get"
            ;;
    esac
}

detect_virtualization() {
    VIRT_TYPE="none"
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo 'none')"
    elif [[ -f /proc/1/environ ]]; then
        if grep -q 'container=' /proc/1/environ 2>/dev/null; then
            VIRT_TYPE="container"
        fi
    fi

    log_info "Virtualization: ${VIRT_TYPE}"

    case "$VIRT_TYPE" in
        openvz|lxc|lxc-libvirt)
            log_warn "⚠  Container-based virtualization detected (${VIRT_TYPE})."
            log_warn "   Docker, iptables/NAT, and some sysctl settings may NOT work."
            IS_CONTAINER=true
            ;;
        *)
            IS_CONTAINER=false
            ;;
    esac
}

check_internet() {
    log_debug "Checking internet connectivity..."
    if ! curl -fsS --max-time 10 https://google.com -o /dev/null 2>/dev/null; then
        log_error "No internet connectivity. Cannot proceed."
        return 1
    fi
    log_ok "Internet connectivity — OK"
}

preflight_checks() {
    log_step "Preflight checks"
    check_root

    # Warn if invoked via pipe (curl ... | bash) — stdin is not a tty
    if [[ ! -t 0 && "$NON_INTERACTIVE" == true ]]; then
        log_warn "stdin is not a terminal (pipe/redirect detected)."
        log_warn "Non-interactive mode was forced automatically."
        log_warn "Preferred usage: bash <(curl -Ls URL) [--mode node --args]"
        if [[ -z "$MODE" ]]; then
            log_error "No --mode specified. Cannot proceed non-interactively without a mode."
            log_error "Example: bash <(curl -Ls URL) --mode node --non-interactive"
            exit 1
        fi
    fi

    detect_os
    detect_virtualization
    check_internet
    mkdir -p "$BACKUP_DIR"
    log_ok "Preflight checks passed"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 · BACKUP HELPER
# ─────────────────────────────────────────────────────────────────────────────

# backup_file <path>
# Creates a timestamped backup in $BACKUP_DIR. Idempotent.
backup_file() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    local dest="${BACKUP_DIR}/$(basename "$src").${TIMESTAMP}.bak"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would backup: ${src} → ${dest}"
        return 0
    fi
    cp -a "$src" "$dest"
    log_debug "Backed up: ${src} → ${dest}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 · PACKAGE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

apt_update() {
    if [[ "$SKIP_UPDATE" == true ]]; then
        log_info "Skipping apt update (--skip-update)"
        return 0
    fi
    log_step "Updating package lists"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would run: apt-get update && apt-get upgrade -y"
        return 0
    fi
    DEBIAN_FRONTEND=noninteractive $PKG_MGR update -qq
    DEBIAN_FRONTEND=noninteractive $PKG_MGR upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    log_ok "Packages updated"
    STEP_STATUS["apt_update"]="OK"
}

# install_packages <pkg1> [pkg2 ...]
install_packages() {
    local pkgs=("$@")
    local to_install=()

    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            to_install+=("$pkg")
        else
            log_debug "Already installed: ${pkg}"
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        log_ok "All requested packages already installed"
        return 0
    fi

    log_info "Installing: ${to_install[*]}"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install: ${to_install[*]}"
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "${to_install[@]}"
    log_ok "Installed: ${to_install[*]}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 · BASE SETUP
# ─────────────────────────────────────────────────────────────────────────────

BASE_PACKAGES=(
    curl wget git unzip tar jq
    vim nano htop net-tools dnsutils
    iproute2 ufw fail2ban socat
    tcpdump mtr ca-certificates
    lsb-release gnupg2 software-properties-common
    bc psmisc procps
)

setup_base_packages() {
    log_step "Installing base packages"
    install_packages "${BASE_PACKAGES[@]}"
    STEP_STATUS["base_packages"]="OK"
}

# ── Timezone ──────────────────────────────────────────────────────────────────
setup_timezone() {
    log_step "Timezone configuration"
    local current_tz
    current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'UTC')"
    log_info "Current timezone: ${current_tz}"

    if [[ "$NON_INTERACTIVE" == true ]]; then
        log_info "Non-interactive: keeping ${current_tz}"
        STEP_STATUS["timezone"]="SKIPPED"
        return 0
    fi

    local new_tz
    read -rp "  Enter timezone [${current_tz}]: " new_tz
    new_tz="${new_tz:-$current_tz}"

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would set timezone to: ${new_tz}"
        STEP_STATUS["timezone"]="DRY"
        return 0
    fi

    if timedatectl set-timezone "$new_tz" 2>/dev/null; then
        log_ok "Timezone set to: ${new_tz}"
        STEP_STATUS["timezone"]="OK"
    else
        log_warn "Failed to set timezone '${new_tz}'; keeping ${current_tz}"
        STEP_STATUS["timezone"]="WARN"
    fi
}

# ── SSH hardening (safe — won't lock you out) ─────────────────────────────────
setup_ssh() {
    log_step "SSH configuration"
    local sshd_cfg="/etc/ssh/sshd_config"

    [[ -f "$sshd_cfg" ]] || { log_warn "sshd_config not found — skipping SSH setup"; return 0; }

    backup_file "$sshd_cfg"

    # Read current SSH port
    SSH_PORT="$(grep -E '^#?Port ' "$sshd_cfg" | head -1 | awk '{print $2}' | tr -d '#')"
    SSH_PORT="${SSH_PORT:-22}"
    log_info "Detected SSH port: ${SSH_PORT}"

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would harden sshd_config (port ${SSH_PORT})"
        STEP_STATUS["ssh"]="DRY"
        return 0
    fi

    # Only apply settings that aren't already set
    _sshd_set() {
        local key="$1" val="$2"
        if grep -qE "^${key}\s+" "$sshd_cfg"; then
            sed -i "s|^${key}\s.*|${key} ${val}|" "$sshd_cfg"
        elif grep -qE "^#${key}" "$sshd_cfg"; then
            sed -i "s|^#${key}.*|${key} ${val}|" "$sshd_cfg"
        else
            echo "${key} ${val}" >> "$sshd_cfg"
        fi
    }

    _sshd_set "PermitRootLogin"          "prohibit-password"
    _sshd_set "PasswordAuthentication"   "yes"   # keep yes until keys are confirmed
    _sshd_set "X11Forwarding"            "no"
    _sshd_set "MaxAuthTries"             "5"
    _sshd_set "ClientAliveInterval"      "300"
    _sshd_set "ClientAliveCountMax"      "2"
    _sshd_set "LoginGraceTime"           "60"
    _sshd_set "AllowAgentForwarding"     "no"
    _sshd_set "AllowTcpForwarding"       "yes"   # keep for tunnels

    # Validate config
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        log_ok "SSH config applied and reloaded"
        STEP_STATUS["ssh"]="OK"
    else
        log_error "sshd config validation failed — reverting backup"
        cp -a "${BACKUP_DIR}/sshd_config.${TIMESTAMP}.bak" "$sshd_cfg"
        STEP_STATUS["ssh"]="FAILED"
    fi
}

# ── Swap ──────────────────────────────────────────────────────────────────────
setup_swap() {
    log_step "Swap configuration"

    local existing_swap
    existing_swap="$(swapon --show=SIZE --noheadings 2>/dev/null | head -1 || echo '')"

    if [[ -n "$existing_swap" ]]; then
        log_info "Swap already active (${existing_swap}). Skipping."
        STEP_STATUS["swap"]="SKIPPED"
        return 0
    fi

    local swap_size="2G"
    if [[ "$NON_INTERACTIVE" == false ]]; then
        read -rp "  Create swap file? Size [2G / enter to skip]: " swap_size
        [[ -z "$swap_size" ]] && { log_info "Skipping swap"; STEP_STATUS["swap"]="SKIPPED"; return 0; }
    else
        log_info "Non-interactive: skipping swap creation"
        STEP_STATUS["swap"]="SKIPPED"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would create ${swap_size} swap at /swapfile"
        STEP_STATUS["swap"]="DRY"
        return 0
    fi

    local swapfile="/swapfile"
    if [[ -f "$swapfile" ]]; then
        log_warn "Swap file already exists at ${swapfile}. Skipping."
        STEP_STATUS["swap"]="SKIPPED"
        return 0
    fi

    fallocate -l "$swap_size" "$swapfile" || dd if=/dev/zero of="$swapfile" bs=1M count=2048 status=none
    chmod 600 "$swapfile"
    mkswap "$swapfile" -q
    swapon "$swapfile"
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10 &>/dev/null
    log_ok "Swap ${swap_size} created and enabled"
    STEP_STATUS["swap"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8 · SYSCTL MANAGEMENT (idempotent)
# ─────────────────────────────────────────────────────────────────────────────

# _sysctl_set <key> <value> <file>
# Sets or replaces a sysctl key in the given file. Idempotent.
_sysctl_set() {
    local key="$1" value="$2" file="$3"
    mkdir -p "$(dirname "$file")"
    touch "$file"

    if grep -qE "^${key}\s*=" "$file" 2>/dev/null; then
        # Replace existing
        local old_val
        old_val="$(grep -E "^${key}\s*=" "$file" | head -1 | cut -d= -f2- | xargs)"
        if [[ "$old_val" != "$value" ]]; then
            sed -i "s|^${key}\s*=.*|${key} = ${value}|" "$file"
            log_debug "sysctl updated: ${key} = ${value} (was: ${old_val})"
        else
            log_debug "sysctl unchanged: ${key} = ${value}"
        fi
    else
        # Append new
        echo "${key} = ${value}" >> "$file"
        log_debug "sysctl added: ${key} = ${value}"
    fi
}

apply_sysctl_network() {
    log_step "Applying network sysctl settings"
    backup_file "$SYSCTL_FILE"

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would write sysctl to ${SYSCTL_FILE}"
        STEP_STATUS["sysctl_network"]="DRY"
        return 0
    fi

    cat > "${SYSCTL_FILE}.header" <<'EOF'
# Managed by server-bootstrap.sh — do not edit manually
# Generated: TIMESTAMP_PLACEHOLDER
EOF
    sed -i "s/TIMESTAMP_PLACEHOLDER/$(date)/" "${SYSCTL_FILE}.header"

    # Write to tmp, then merge
    local tmpfile
    tmpfile="$(mktemp)"

    declare -A NET_SYSCTL=(
        ["net.ipv4.tcp_rmem"]="4096 131072 16777216"
        ["net.ipv4.tcp_wmem"]="4096 65536 16777216"
        ["net.ipv4.tcp_mem"]="786432 1048576 1572864"
        ["net.ipv4.tcp_window_scaling"]="1"
        ["net.ipv4.tcp_sack"]="1"
        ["net.ipv4.tcp_timestamps"]="1"
        ["net.core.default_qdisc"]="fq"
        ["net.ipv4.tcp_congestion_control"]="bbr"
    )

    # Start fresh or preserve existing non-conflicting values
    cp "${SYSCTL_FILE}.header" "$tmpfile"

    for key in "${!NET_SYSCTL[@]}"; do
        echo "${key} = ${NET_SYSCTL[$key]}" >> "$tmpfile"
    done

    mv "$tmpfile" "$SYSCTL_FILE"
    rm -f "${SYSCTL_FILE}.header"

    sysctl --system &>/dev/null || sysctl -p "$SYSCTL_FILE" &>/dev/null || true
    log_ok "Network sysctl applied (${SYSCTL_FILE})"
    STEP_STATUS["sysctl_network"]="OK"
}

apply_sysctl_router() {
    log_step "Applying router/Relay sysctl settings"

    local router_file="/etc/sysctl.d/99-router.conf"
    backup_file "$router_file"

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would write router sysctl to ${router_file}"
        STEP_STATUS["sysctl_router"]="DRY"
        return 0
    fi

    declare -A ROUTER_SYSCTL=(
        ["net.ipv4.icmp_echo_ignore_all"]="1"
        ["net.ipv6.conf.all.disable_ipv6"]="1"
        ["net.ipv6.conf.default.disable_ipv6"]="1"
        ["net.ipv6.conf.lo.disable_ipv6"]="1"
        ["net.ipv4.ip_forward"]="1"
    )

    local tmpfile
    tmpfile="$(mktemp)"
    echo "# Managed by server-bootstrap.sh (router mode) — $(date)" > "$tmpfile"

    for key in "${!ROUTER_SYSCTL[@]}"; do
        echo "${key} = ${ROUTER_SYSCTL[$key]}" >> "$tmpfile"
    done

    mv "$tmpfile" "$router_file"
    sysctl --system &>/dev/null || sysctl -p "$router_file" &>/dev/null || true
    log_ok "Router sysctl applied (${router_file})"
    STEP_STATUS["sysctl_router"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9 · UFW
# ─────────────────────────────────────────────────────────────────────────────

# Detect current SSH port — checks sshd_config, running process, and active socket
_get_ssh_port() {
    local sshd_cfg="/etc/ssh/sshd_config"
    local port=""

    # 1. sshd_config: uncommented Port directive
    port="$(grep -E '^Port ' "$sshd_cfg" 2>/dev/null | awk '{print $2}' | head -1)"

    # 2. Fallback: what port is sshd actually listening on right now
    if [[ -z "$port" ]]; then
        port="$(ss -tlnp 2>/dev/null | grep sshd | grep -oP '(?<=:)\d+' | head -1)"
    fi

    # 3. Fallback: active SSH connection this script is running over
    if [[ -z "$port" ]]; then
        port="$(ss -tnp 2>/dev/null | grep "ESTABLISHED" | grep sshd \
            | grep -oP ':\K\d+(?=\s)' | sort -u | head -1)"
    fi

    # 4. Hard fallback
    echo "${port:-22}"
}

setup_ufw() {
    local mode="${1:-base}" # base | node | gate | relay
    log_step "Configuring UFW (mode: ${mode})"

    install_packages ufw

    local ssh_port
    ssh_port="$(_get_ssh_port)"
    log_info "SSH port: ${ssh_port}"

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would configure UFW: allow SSH:${ssh_port}, mode-specific ports"
        STEP_STATUS["ufw"]="DRY"
        return 0
    fi

    # Reset & configure defaults
    ufw --force reset &>/dev/null
    ufw default deny incoming  &>/dev/null
    ufw default allow outgoing &>/dev/null

    # Always allow SSH first — CRITICAL to avoid lockout
    ufw allow "${ssh_port}/tcp" comment 'SSH' &>/dev/null
    log_info "UFW: allowed SSH on port ${ssh_port}"

    # Mode-specific rules
    case "$mode" in
        node)
            ufw allow 443/tcp  comment 'HTTPS/Xray'  &>/dev/null
            ufw allow 80/tcp   comment 'HTTP'         &>/dev/null
            ufw allow 8443/tcp comment 'Alt-HTTPS'    &>/dev/null
            ;;
        gate)
            ufw allow 443/tcp  comment 'HTTPS/Xray'  &>/dev/null
            ufw allow 80/tcp   comment 'HTTP'         &>/dev/null
            ufw allow 8443/tcp comment 'Alt-HTTPS'    &>/dev/null
            ;;
        relay)
            ufw allow "${RELAY_PORT:-443}/tcp" comment 'HAProxy relay' &>/dev/null
            ;;
        monitoring)
            ufw allow 3000/tcp comment 'Grafana' &>/dev/null
            ;;
        base|*)
            # Only SSH
            ;;
    esac

    # Safety check: SSH rule MUST be present before enabling UFW
    if ! ufw status 2>/dev/null | grep -qE "${ssh_port}/(tcp|any)"; then
        log_error "SAFETY ABORT: SSH port ${ssh_port} not found in UFW rules — refusing to enable UFW to avoid lockout"
        log_error "Run manually: ufw allow ${ssh_port}/tcp && ufw enable"
        STEP_STATUS["ufw"]="FAILED"
        return 1
    fi

    # Enable UFW non-interactively
    ufw --force enable &>/dev/null
    log_ok "UFW enabled with rules for mode '${mode}'"
    ufw status verbose 2>/dev/null | while read -r line; do log_debug "  ufw: ${line}"; done
    STEP_STATUS["ufw"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 10 · FAIL2BAN
# ─────────────────────────────────────────────────────────────────────────────

setup_fail2ban() {
    log_step "Configuring Fail2Ban"
    install_packages fail2ban

    local jail_local="/etc/fail2ban/jail.local"

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would configure fail2ban jail.local"
        STEP_STATUS["fail2ban"]="DRY"
        return 0
    fi

    # Only create jail.local if it doesn't exist or is empty
    if [[ ! -s "$jail_local" ]]; then
        backup_file "$jail_local"
        local ssh_port
        ssh_port="$(_get_ssh_port)"

        cat > "$jail_local" <<EOF
[DEFAULT]
bantime   = 1h
findtime  = 10m
maxretry  = 5
ignoreip  = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${ssh_port}
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 5
EOF
        log_info "Created jail.local with sshd jail (port ${ssh_port})"
    else
        log_info "jail.local already exists — not overwriting"
    fi

    systemctl enable fail2ban  &>/dev/null
    systemctl restart fail2ban &>/dev/null
    log_ok "Fail2Ban started and enabled"
    STEP_STATUS["fail2ban"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11 · HAPROXY (Relay/router mode)
# ─────────────────────────────────────────────────────────────────────────────
#
# Architecture:
#   Client → RELAY_ADDRESS:RELAY_PORT (HAProxy)
#               ├─ bk_blocked  → blackhole  (government IPs / scanners)
#               ├─ bk_ignored  → blackhole  (NOT in Russian operator allowlist)
#               └─ bk_upstream → GATE_ADDRESS:GATE_PORT  send-proxy-v2
#
# Lists:
#   /etc/haproxy/blocked.lst  — government networks + antiscanner CIDRs
#   /etc/haproxy/allowed.lst  — Russian mobile/ISP operator CIDRs (whois RADB)
#
# Cron: daily 04:20 — analyze logs → update lists → reload haproxy
# ─────────────────────────────────────────────────────────────────────────────

# Validate IPv4 address
_validate_ip() {
    local ip="$1"
    local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    [[ $ip =~ $re ]] || return 1
    local IFS='.'
    read -r o1 o2 o3 o4 <<< "$ip"
    for o in $o1 $o2 $o3 $o4; do (( o <= 255 )) || return 1; done
    return 0
}

# Validate port (1-65535)
_validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# ── Install HAProxy 2.8 with robust fallback (no hard PPA dependency) ────────
_install_haproxy_28() {
    log_info "Installing HAProxy 2.8.*"

    # Check if already correct version
    if command -v haproxy &>/dev/null; then
        local ver
        ver="$(haproxy -v 2>/dev/null | head -1 | grep -oP '(?<=version )\d+\.\d+')"
        if [[ "$ver" == "2.8" ]]; then
            log_ok "HAProxy 2.8 already installed"
            return 0
        fi
        log_info "Upgrading HAProxy (current: ${ver}) → 2.8"
    fi

    install_packages software-properties-common apt-transport-https

    # 1) Try distro repositories first (works on Ubuntu noble-updates)
    if apt-cache madison haproxy 2>/dev/null | grep -qE '2\.8\.'; then
        log_info "HAProxy 2.8 found in distro repository, installing without external PPA"
        DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y haproxy=2.8.\* \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" && {
            log_ok "HAProxy installed from distro repo: $(haproxy -v 2>/dev/null | head -1)"
            return 0
        }
        log_warn "Version-pinned install failed from distro repo, trying generic haproxy package"
        DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y haproxy \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" && {
            local ver2
            ver2="$(haproxy -v 2>/dev/null | head -1 | grep -oP '(?<=version )\d+\.\d+' || true)"
            if [[ "$ver2" == "2.8" ]]; then
                log_ok "HAProxy installed from distro repo: $(haproxy -v 2>/dev/null | head -1)"
                return 0
            fi
        }
        log_warn "Distro install did not provide HAProxy 2.8, trying external repository fallback"
    fi

    # 2) Fallback path for systems where 2.8 is absent in distro repos
    if [[ "$OS_ID" == "ubuntu" ]]; then
        log_info "Trying Ubuntu PPA fallback: ppa:vbernat/haproxy-2.8"
        add-apt-repository ppa:vbernat/haproxy-2.8 -y &>/dev/null || {
            log_warn "Could not add PPA. Will fallback to generic distro haproxy package."
            DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y haproxy \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold"
            log_ok "HAProxy installed (fallback): $(haproxy -v 2>/dev/null | head -1)"
            return 0
        }

        if ! DEBIAN_FRONTEND=noninteractive $PKG_MGR update -qq; then
            log_warn "PPA update failed (possibly unsupported distro codename). Removing PPA and falling back."
            rm -f /etc/apt/sources.list.d/vbernat-ubuntu-haproxy-2_8-*.sources \
                  /etc/apt/sources.list.d/vbernat-ubuntu-haproxy-2_8-*.list 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive $PKG_MGR update -qq || true
            DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y haproxy \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold"
            log_ok "HAProxy installed (fallback): $(haproxy -v 2>/dev/null | head -1)"
            return 0
        fi

        if DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y haproxy=2.8.\* \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold"; then
            log_ok "HAProxy installed from PPA: $(haproxy -v 2>/dev/null | head -1)"
            return 0
        fi

        log_warn "PPA install failed, trying generic distro haproxy package"
        DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y haproxy \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold"
        log_ok "HAProxy installed (fallback): $(haproxy -v 2>/dev/null | head -1)"
    else
        # Debian fallback chain: distro repo first, then haproxy.debian.net
        log_info "Trying Debian distro repository first"
        if DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y haproxy=2.8.\* \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold"; then
            log_ok "HAProxy installed from distro repo: $(haproxy -v 2>/dev/null | head -1)"
            return 0
        fi

        log_warn "Debian distro repo does not provide HAProxy 2.8, using haproxy.debian.net"
        curl -fsSL https://haproxy.debian.net/bernat.debian.net.gpg \
            | gpg --dearmor -o /usr/share/keyrings/haproxy.debian.net.gpg

        echo "deb [signed-by=/usr/share/keyrings/haproxy.debian.net.gpg] \
https://haproxy.debian.net bookworm-backports-2.8 main" \
            > /etc/apt/sources.list.d/haproxy.list

        DEBIAN_FRONTEND=noninteractive $PKG_MGR update -qq
        DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y haproxy=2.8.\* \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold"

        log_ok "HAProxy installed from haproxy.debian.net: $(haproxy -v 2>/dev/null | head -1)"
    fi
}

# ── Ask / validate Relay parameters ──────────────────────────────────────────
_ask_relay_params() {
    # RELAY_ADDRESS
    if [[ -z "${RELAY_ADDRESS:-}" ]]; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            # Auto-detect primary IP
            RELAY_ADDRESS="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')"
            log_info "Auto-detected RELAY_ADDRESS: ${RELAY_ADDRESS}"
        else
            local detected
            detected="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo '')"
            while true; do
                read -rp "  Enter RELAY (this server) IP [${detected}]: " RELAY_ADDRESS
                RELAY_ADDRESS="${RELAY_ADDRESS:-$detected}"
                _validate_ip "$RELAY_ADDRESS" && break
                log_warn "Invalid IP: '${RELAY_ADDRESS}'"
            done
        fi
    fi
    _validate_ip "$RELAY_ADDRESS" || { log_error "Invalid RELAY_ADDRESS: ${RELAY_ADDRESS}"; exit 1; }

    # RELAY_PORT
    RELAY_PORT="${RELAY_PORT:-443}"
    if [[ "$NON_INTERACTIVE" == false ]]; then
        read -rp "  RELAY port [${RELAY_PORT}]: " _rp
        RELAY_PORT="${_rp:-$RELAY_PORT}"
    fi
    _validate_port "$RELAY_PORT" || { log_error "Invalid RELAY_PORT: ${RELAY_PORT}"; exit 1; }

    # GATE_ADDRESS
    if [[ -z "${GATE_ADDRESS:-}" ]]; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            log_error "--gate-address is required in non-interactive Relay mode"
            exit 1
        fi
        while true; do
            read -rp "  Enter GATE IP address: " GATE_ADDRESS
            _validate_ip "$GATE_ADDRESS" && break
            log_warn "Invalid IP: '${GATE_ADDRESS}'"
        done
    fi
    _validate_ip "$GATE_ADDRESS" || { log_error "Invalid GATE_ADDRESS: ${GATE_ADDRESS}"; exit 1; }

    # GATE_PORT
    GATE_PORT="${GATE_PORT:-9443}"
    if [[ "$NON_INTERACTIVE" == false ]]; then
        read -rp "  GATE port [${GATE_PORT}] (recommended: NOT 443): " _gp
        GATE_PORT="${_gp:-$GATE_PORT}"
    fi
    _validate_port "$GATE_PORT" || { log_error "Invalid GATE_PORT: ${GATE_PORT}"; exit 1; }

    log_info "RELAY  : ${RELAY_ADDRESS}:${RELAY_PORT}"
    log_info "GATE   : ${GATE_ADDRESS}:${GATE_PORT}"
}

# ── Write HAProxy config (relay mode) ────────────────────────────────────────
_write_haproxy_cfg() {
    local haproxy_cfg="/etc/haproxy/haproxy.cfg"
    backup_file "$haproxy_cfg"

    # Ensure list files and socket dir exist before writing config
    mkdir -p /var/run/haproxy
    touch /etc/haproxy/blocked.lst /etc/haproxy/allowed.lst

    cat > "$haproxy_cfg" <<EOF
global
    log /dev/log local0
    maxconn 100000
    daemon
    nbthread auto
    stats socket /var/run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s

defaults
    mode tcp
    timeout connect 10s
    timeout client  1h
    timeout server  1h
    timeout tunnel  1h
    log             global
    option          tcplog
    option          dontlognull
    retries         3

# ── Stats HTTP page (localhost only, port 8404) ───────────────────────────────
frontend ft_stats
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats show-legends
    stats show-node
    no log

# ── Main inbound frontend ─────────────────────────────────────────────────────
frontend ft_inbound
    bind *:${RELAY_PORT}
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

    # Priority: blocked list first, then allowlist check
    use_backend bk_blocked if { src -f /etc/haproxy/blocked.lst }
    use_backend bk_ignored  if !{ src -f /etc/haproxy/allowed.lst }
    default_backend bk_upstream

# ── Silent-drop backends (no server = HAProxy closes silently, logs backend name)
backend bk_blocked
    timeout connect 1s

backend bk_ignored
    timeout connect 1s

# ── Upstream gate ─────────────────────────────────────────────────────────────
backend bk_upstream
    option tcp-check
    timeout check 5s
    server upstream ${GATE_ADDRESS}:${GATE_PORT} send-proxy-v2 check inter 10s rise 2 fall 3
EOF

    log_info "HAProxy relay config written (→ ${GATE_ADDRESS}:${GATE_PORT})"
}

# ── Blocklist update script ───────────────────────────────────────────────────
_write_update_blocklist() {
    cat > /usr/local/bin/update_blocklist.sh << 'SCRIPT'
#!/bin/bash
# Downloads government networks + antiscanner lists into /etc/haproxy/blocked.lst
set -euo pipefail

GL=$(echo "aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL3NoYWRvdy1uZXRsYWIvdHJhZmZpYy1ndWFyZC1saXN0cy9yZWZzL2hlYWRzL21haW4vcHVibGljL2dvdmVybm1lbnRfbmV0d29ya3MubGlzdA==" | base64 -d)
AU=$(echo "aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL3NoYWRvdy1uZXRsYWIvdHJhZmZpYy1ndWFyZC1saXN0cy9yZWZzL2hlYWRzL21haW4vcHVibGljL2FudGlzY2FubmVyLmxpc3Q=" | base64 -d)
OUTPUT="/etc/haproxy/blocked.lst"
TMP="$(mktemp)"

curl -fsSL "$GL" "$AU" \
    | grep -v '^#' \
    | grep -v '^$' \
    | grep -v ':' \
    | sort -u > "$TMP"

mv "$TMP" "$OUTPUT"
echo "$(date '+%Y-%m-%d %H:%M:%S')  blocked: $(wc -l < "$OUTPUT") networks written to $OUTPUT"
SCRIPT

    chmod +x /usr/local/bin/update_blocklist.sh
    log_info "Created /usr/local/bin/update_blocklist.sh"
}

# ── Allowlist update script (URL fetch or RADB whois fallback) ───────────────
_write_update_allowlist() {
    if [[ -n "${ALLOWED_LST_URL:-}" ]]; then
        # ── Mode A: fetch pre-built allowed.lst from URL (e.g. GitHub raw) ──
        cat > /usr/local/bin/update_allowlist.sh << SCRIPT
#!/bin/bash
# Fetches /etc/haproxy/allowed.lst from a pre-built URL (GitHub Actions / raw)
set -euo pipefail

OUTPUT="/etc/haproxy/allowed.lst"
TIMESTAMP_FILE="/etc/haproxy/allowed.lst.lastmod"
TMP="\$(mktemp)"
LOG="/var/log/haproxy-allowlist-update.log"
URL="${ALLOWED_LST_URL}"

_log() { echo "\$(date '+%Y-%m-%d %H:%M:%S')  \$*" | tee -a "\$LOG"; }

_log "Fetching allowed.lst from \$URL"

# Build curl args: use If-Modified-Since if we have a saved timestamp
CURL_ARGS=(-fsSL --retry 3 --retry-delay 5 --max-time 30 --write-out "%{http_code}")
if [[ -f "\$TIMESTAMP_FILE" ]]; then
    CURL_ARGS+=(--header "If-Modified-Since: \$(cat "\$TIMESTAMP_FILE")")
fi

HTTP_CODE=\$(curl "\${CURL_ARGS[@]}" "\$URL" -o "\$TMP" 2>>\$LOG || true)

case "\$HTTP_CODE" in
    200)
        # Sanity check: must contain at least one CIDR
        if grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' "\$TMP"; then
            mv "\$TMP" "\$OUTPUT"
            # Save Last-Modified for next run
            curl -fsSI --max-time 10 "\$URL" 2>/dev/null \
                | grep -i '^last-modified:' \
                | sed 's/[Ll]ast-[Mm]odified: //' \
                | tr -d '\r' > "\$TIMESTAMP_FILE" || true
            _log "OK: \$(wc -l < "\$OUTPUT") networks written to \$OUTPUT"
        else
            _log "ERROR: downloaded file contains no valid CIDRs — keeping existing list"
            rm -f "\$TMP"
            exit 1
        fi
        ;;
    304)
        _log "NOT MODIFIED: list unchanged on server, skipping update"
        rm -f "\$TMP"
        exit 0
        ;;
    *)
        _log "ERROR: HTTP \$HTTP_CODE from \$URL — keeping existing list"
        rm -f "\$TMP"
        exit 1
        ;;
esac
SCRIPT
        log_info "Created /usr/local/bin/update_allowlist.sh (URL mode: ${ALLOWED_LST_URL})"
    else
        # ── Mode B: generate locally via RADB whois (original behaviour) ──
        cat > /usr/local/bin/update_allowlist.sh << 'SCRIPT'
#!/bin/bash
# Fetches IPv4 prefixes for Russian mobile/ISP ASNs from RADB whois
# into /etc/haproxy/allowed.lst
set -euo pipefail

OUTPUT="/etc/haproxy/allowed.lst"
TMP="$(mktemp)"

# Russian operator ASNs (MTS, MegaFon, Beeline, Tele2, Rostelecom, etc.)
ASNS="8359 13174 21365 30922 34351 3216 16043 16345 42842
31133 8263 6854 50928 48615 47395 47218 43841 42891 41976
35298 34552 31268 31224 31213 31208 31205 31195 31163 29648
25290 25159 24866 20663 20632 12396 202804 12958 15378 42437
48092 48190 41330 39374 13116 201776 206673 12389 35816 205638
214257 202498 203451 203561 47204"

> "$TMP"

for ASN in $ASNS; do
    echo -n "Fetching AS${ASN}... "
    RESULT=$(whois -h whois.radb.net -- "-i origin AS${ASN}" 2>/dev/null \
        | grep "^route:" \
        | awk '{print $2}')
    COUNT=$(echo "$RESULT" | grep -c '.' || true)
    echo "${COUNT} prefixes"
    echo "$RESULT" >> "$TMP"
    sleep 0.3
done

# Filter: IPv4 only, deduplicate, sort
grep -v ':' "$TMP" | grep -E '^[0-9]' | sort -u > "$OUTPUT"
rm -f "$TMP"

echo "$(date '+%Y-%m-%d %H:%M:%S')  allowed: $(wc -l < "$OUTPUT") networks written to $OUTPUT"
SCRIPT
        log_info "Created /usr/local/bin/update_allowlist.sh (whois/RADB mode)"
    fi

    chmod +x /usr/local/bin/update_allowlist.sh
}

# ── Log analysis script ───────────────────────────────────────────────────────
_write_analyze_logs() {
    cat > /usr/local/bin/analyze_logs.sh << 'SCRIPT'
#!/bin/bash
# Extracts top IPs from haproxy blocked/ignored logs

BLOCKED_LOG="/var/log/haproxy-blocked.log"
IGNORED_LOG="/var/log/haproxy-ignored.log"
BLOCKED_OUT="/etc/haproxy/blocked.txt"
IGNORED_OUT="/etc/haproxy/ignored.txt"

_analyze() {
    local logfile="$1" outfile="$2"
    if [[ ! -f "$logfile" ]]; then
        echo "Log not found: $logfile"
        return
    fi
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$logfile" \
        | sort | uniq -c | sort -rn \
        | awk '{printf "%s (%d)\n", $2, $1}' > "$outfile"
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $(wc -l < "$outfile") unique IPs → $outfile"
}

_analyze "$BLOCKED_LOG" "$BLOCKED_OUT"
_analyze "$IGNORED_LOG" "$IGNORED_OUT"
SCRIPT

    chmod +x /usr/local/bin/analyze_logs.sh
    log_info "Created /usr/local/bin/analyze_logs.sh"
}

# ── rsyslog: separate log files per backend ───────────────────────────────────
_write_rsyslog_conf() {
    install_packages rsyslog

    # Ensure haproxy log dir exists for rsyslog socket
    mkdir -p /var/lib/haproxy/dev

    cat > /etc/rsyslog.d/49-haproxy.conf << 'EOF'
$AddUnixListenSocket /var/lib/haproxy/dev/log

if $programname == 'haproxy' and $msg contains 'bk_blocked' then /var/log/haproxy-blocked.log
if $programname == 'haproxy' and $msg contains 'bk_ignored' then /var/log/haproxy-ignored.log

:programname, startswith, "haproxy" /var/log/haproxy.log
:programname, startswith, "haproxy" stop
EOF

    systemctl restart rsyslog
    log_info "rsyslog configured for haproxy split logging"
}

# ── logrotate: hourly, keep 24h ───────────────────────────────────────────────
_write_logrotate() {
    cat > /etc/logrotate.d/haproxy << 'EOF'
/var/log/haproxy*.log {
    hourly
    rotate 24
    missingok
    notifempty
    compress
    delaycompress
    postrotate
        [ ! -x /usr/lib/rsyslog/rsyslog-rotate ] || /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF
    log_info "logrotate configured (hourly, 24 rotations)"
}

# ── Cron: daily update lists → reload ────────────────────────────────────────
#
#   04:15  blocklist + log analysis  (fast, ~10s)
#   04:20  allowlist                 (whois: slow ~2-3 min; URL: fast ~2s)
#   04:25  haproxy reload            (after both lists are ready)
#
#   If ALLOWED_LST_URL is set, allowlist is also refreshed every 6 hours
#   so the server stays in sync with GitHub Actions schedule (daily push).
# ─────────────────────────────────────────────────────────────────────────────
_write_cron() {
    if [[ -n "${ALLOWED_LST_URL:-}" ]]; then
        cat > /etc/cron.d/haproxy-lists << EOF
# server-bootstrap: update haproxy IP lists (URL mode)
# 04:15 — blocklist + log analysis (fast)
15 4 * * * root /usr/local/bin/update_blocklist.sh && /usr/local/bin/analyze_logs.sh

# 04:20 — allowlist from URL + reload
20 4 * * * root /usr/local/bin/update_allowlist.sh && systemctl reload haproxy

# Every 6h (skip 04:xx — covered above) — keep allowlist fresh
# Runs at 10:00, 16:00, 22:00 — reload only if update succeeded (exit 0)
0 10,16,22 * * * root /usr/local/bin/update_allowlist.sh && systemctl reload haproxy
EOF
        log_info "Cron jobs set: daily 04:15/04:20 + 10:00/16:00/22:00 allowlist refresh (URL mode)"
    else
        cat > /etc/cron.d/haproxy-lists << 'EOF'
# server-bootstrap: update haproxy IP lists (whois/RADB mode)
# 04:15 — blocklist + log analysis (fast)
15 4 * * * root /usr/local/bin/update_blocklist.sh && /usr/local/bin/analyze_logs.sh

# 04:20 — allowlist via whois (slow: ~2-3 min) + reload
20 4 * * * root /usr/local/bin/update_allowlist.sh && systemctl reload haproxy
EOF
        log_info "Cron jobs set: daily 04:15/04:20 → update lists + reload haproxy (whois mode)"
    fi
}

# ── Main HAProxy setup entry point ────────────────────────────────────────────
setup_haproxy() {
    log_step "Configuring HAProxy 2.8 (Relay/router mode)"

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install HAProxy 2.8 (distro-first, PPA fallback)"
        log_dry "Would configure: RELAY:${RELAY_ADDRESS:-?}:${RELAY_PORT:-443} → GATE:${GATE_ADDRESS:-?}:${GATE_PORT:-9443}"
        log_dry "Would create: update_blocklist.sh, update_allowlist.sh, analyze_logs.sh"
        if [[ -n "${ALLOWED_LST_URL:-}" ]]; then
            log_dry "Allowlist mode: URL fetch → ${ALLOWED_LST_URL}"
            log_dry "Would configure: rsyslog split logs, logrotate (hourly/24h), cron (04:15/04:20 + 10:00/16:00/22:00)"
        else
            log_dry "Allowlist mode: whois/RADB (slow, ~2-3 min)"
            log_dry "Would configure: rsyslog split logs, logrotate (hourly/24h), cron (04:15/04:20)"
        fi
        STEP_STATUS["haproxy"]="DRY"
        return 0
    fi

    # 1. Collect parameters
    _ask_relay_params

    # 2. Install HAProxy 2.8
    _install_haproxy_28

    # 3. Write helper scripts
    _write_update_blocklist
    _write_update_allowlist
    _write_analyze_logs

    # 4. Write HAProxy config
    _write_haproxy_cfg

    # 5. Fetch initial lists
    log_info "Fetching initial blocklist..."
    /usr/local/bin/update_blocklist.sh || log_warn "Blocklist fetch failed — continuing with empty list"

    local allowlist_label="(may take 2-3 min via whois)"
    [[ -n "${ALLOWED_LST_URL:-}" ]] && allowlist_label="from URL"
    log_info "Fetching initial allowlist ${allowlist_label}..."
    /usr/local/bin/update_allowlist.sh || log_warn "Allowlist fetch failed — continuing with empty list"

    # 6. Logging infrastructure
    _write_rsyslog_conf
    _write_logrotate
    _write_cron

    # 7. Ensure /var/run/haproxy exists (stats socket dir)
    mkdir -p /var/run/haproxy
    chown haproxy:haproxy /var/run/haproxy 2>/dev/null || true

    # 8. Systemd drop-in: auto-restart on failure
    mkdir -p /etc/systemd/system/haproxy.service.d
    cat > /etc/systemd/system/haproxy.service.d/override.conf <<'OVERRIDE'
[Service]
Restart=always
RestartSec=3s
LimitNOFILE=1048576
RuntimeDirectory=haproxy
RuntimeDirectoryMode=0750
OVERRIDE
    systemctl daemon-reload &>/dev/null

    # 9. Validate config then start (graceful reload if already running)
    log_info "Validating HAProxy config..."
    if haproxy -c -f /etc/haproxy/haproxy.cfg; then
        systemctl enable haproxy &>/dev/null
        if systemctl is-active --quiet haproxy 2>/dev/null; then
            systemctl reload haproxy
            log_ok "HAProxy reloaded gracefully (zero downtime)"
        else
            systemctl restart haproxy
            log_ok "HAProxy started"
        fi
        log_ok "HAProxy 2.8 running (${RELAY_ADDRESS}:${RELAY_PORT} → ${GATE_ADDRESS}:${GATE_PORT})"
        systemctl status haproxy --no-pager -l 2>/dev/null | head -10 | sed 's/^/    /'
        STEP_STATUS["haproxy"]="OK"
    else
        log_error "HAProxy config validation FAILED — reverting backup"
        local bak="${BACKUP_DIR}/haproxy.cfg.${TIMESTAMP}.bak"
        [[ -f "$bak" ]] && cp -a "$bak" /etc/haproxy/haproxy.cfg
        STEP_STATUS["haproxy"]="FAILED"
        return 1
    fi

    # 10. Show useful hints
    echo ""
    log_info "Useful commands:"
    echo -e "    ${CYAN}# Live HAProxy log${RESET}"
    echo    "    tail -f /var/log/haproxy.log"
    echo -e "    ${CYAN}# Blocked IPs log${RESET}"
    echo    "    tail -f /var/log/haproxy-blocked.log"
    echo -e "    ${CYAN}# Ignored IPs log${RESET}"
    echo    "    tail -f /var/log/haproxy-ignored.log"
    echo -e "    ${CYAN}# Stats page (localhost)${RESET}"
    echo    "    curl -s http://127.0.0.1:8404/stats"
    echo -e "    ${CYAN}# Stats via socket${RESET}"
    echo    "    echo 'show info' | socat stdio /var/run/haproxy/admin.sock"
    echo -e "    ${CYAN}# Force update lists now${RESET}"
    echo    "    /usr/local/bin/update_blocklist.sh && /usr/local/bin/update_allowlist.sh && systemctl reload haproxy"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11b · HAPROXY GATE MODE
#
# Architecture:
#   Relay → GATE_LISTEN_PORT (HAProxy on gate)
#               ├─ bk_blocked → silent drop  (government IPs / scanners)
#               ├─ bk_ignored → silent drop  (NOT in Russian operator allowlist)
#               └─ bk_xray   → 127.0.0.1:XRAY_PORT  accept-proxy
#
# Lists (same update scripts as relay mode):
#   /etc/haproxy/blocked.lst  — government networks + antiscanner CIDRs
#   /etc/haproxy/allowed.lst  — Russian mobile/ISP operator CIDRs
# ─────────────────────────────────────────────────────────────────────────────

GATE_LISTEN_PORT="9443"   # port HAProxy listens on (relay sends here)
XRAY_PORT="443"            # port remnanode/xray listens on locally

_write_haproxy_cfg_gate() {
    local haproxy_cfg="/etc/haproxy/haproxy.cfg"
    backup_file "$haproxy_cfg"

    mkdir -p /var/run/haproxy
    touch /etc/haproxy/blocked.lst /etc/haproxy/allowed.lst

    cat > "$haproxy_cfg" <<EOF
global
    log /dev/log local0
    maxconn 100000
    daemon
    nbthread auto
    stats socket /var/run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s

defaults
    mode tcp
    timeout connect 10s
    timeout client  1h
    timeout server  1h
    timeout tunnel  1h
    log             global
    option          tcplog
    option          dontlognull
    retries         3

# ── Stats page (localhost only) ───────────────────────────────────────────────
frontend ft_stats
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats show-legends
    stats show-node
    no log

# ── Gate inbound (from relay, carries PROXY protocol v2) ─────────────────────
frontend ft_gate
    bind *:${GATE_LISTEN_PORT} accept-proxy

    use_backend bk_blocked if { src -f /etc/haproxy/blocked.lst }
    use_backend bk_ignored  if !{ src -f /etc/haproxy/allowed.lst }
    default_backend bk_xray

# ── Silent-drop backends ──────────────────────────────────────────────────────
backend bk_blocked
    timeout connect 1s

backend bk_ignored
    timeout connect 1s

# ── Local xray/remnanode ──────────────────────────────────────────────────────
backend bk_xray
    option tcp-check
    timeout check 5s
    server xray 127.0.0.1:${XRAY_PORT} send-proxy-v2 check inter 10s rise 2 fall 3
EOF

    log_info "HAProxy gate config written (listen :${GATE_LISTEN_PORT} → 127.0.0.1:${XRAY_PORT})"
}

setup_haproxy_gate() {
    log_step "Configuring HAProxy 2.8 (Gate mode — HAProxy-native blocking)"

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install HAProxy 2.8 for gate mode"
        log_dry "Would configure: *:${GATE_LISTEN_PORT} (accept-proxy) → 127.0.0.1:${XRAY_PORT}"
        log_dry "Would create: blocked.lst, allowed.lst, update scripts, cron"
        STEP_STATUS["haproxy_gate"]="DRY"
        return 0
    fi

    # Ask for ports if interactive
    if [[ "$NON_INTERACTIVE" == false ]]; then
        read -rp "  Gate listen port (relay sends here) [${GATE_LISTEN_PORT}]: " _glp
        GATE_LISTEN_PORT="${_glp:-$GATE_LISTEN_PORT}"
        _validate_port "$GATE_LISTEN_PORT" || { log_error "Invalid port: ${GATE_LISTEN_PORT}"; exit 1; }

        read -rp "  Local xray/remnanode port [${XRAY_PORT}]: " _xp
        XRAY_PORT="${_xp:-$XRAY_PORT}"
        _validate_port "$XRAY_PORT" || { log_error "Invalid port: ${XRAY_PORT}"; exit 1; }
    fi

    log_info "Gate HAProxy: *:${GATE_LISTEN_PORT} (accept-proxy) → 127.0.0.1:${XRAY_PORT}"

    # 1. Install HAProxy 2.8
    _install_haproxy_28

    # 2. Write helper scripts (same as relay mode)
    _write_update_blocklist
    _write_update_allowlist
    _write_analyze_logs

    # 3. Write gate config
    _write_haproxy_cfg_gate

    # 4. Fetch initial lists
    log_info "Fetching initial blocklist..."
    /usr/local/bin/update_blocklist.sh || log_warn "Blocklist fetch failed — continuing with empty list"

    local allowlist_label="(may take 2-3 min via whois)"
    [[ -n "${ALLOWED_LST_URL:-}" ]] && allowlist_label="from URL"
    log_info "Fetching initial allowlist ${allowlist_label}..."
    /usr/local/bin/update_allowlist.sh || log_warn "Allowlist fetch failed — continuing with empty list"

    # 5. Logging + logrotate + cron
    _write_rsyslog_conf
    _write_logrotate
    _write_cron

    # 6. Systemd drop-in: auto-restart
    mkdir -p /etc/systemd/system/haproxy.service.d
    cat > /etc/systemd/system/haproxy.service.d/override.conf <<'OVERRIDE'
[Service]
Restart=always
RestartSec=3s
LimitNOFILE=1048576
RuntimeDirectory=haproxy
RuntimeDirectoryMode=0750
OVERRIDE
    systemctl daemon-reload &>/dev/null

    # 7. Validate and start
    mkdir -p /var/run/haproxy
    chown haproxy:haproxy /var/run/haproxy 2>/dev/null || true

    if haproxy -c -f /etc/haproxy/haproxy.cfg; then
        systemctl enable haproxy &>/dev/null
        if systemctl is-active --quiet haproxy 2>/dev/null; then
            systemctl reload haproxy
            log_ok "HAProxy gate reloaded gracefully"
        else
            systemctl restart haproxy
            log_ok "HAProxy gate started"
        fi
        systemctl status haproxy --no-pager -l 2>/dev/null | head -10 | sed 's/^/    /'
        STEP_STATUS["haproxy_gate"]="OK"
    else
        log_error "HAProxy gate config validation FAILED — reverting backup"
        local bak="${BACKUP_DIR}/haproxy.cfg.${TIMESTAMP}.bak"
        [[ -f "$bak" ]] && cp -a "$bak" /etc/haproxy/haproxy.cfg
        STEP_STATUS["haproxy_gate"]="FAILED"
        return 1
    fi

    echo ""
    log_info "Gate HAProxy hints:"
    echo -e "    ${CYAN}# Stats page${RESET}"
    echo    "    curl -s http://127.0.0.1:8404/stats"
    echo -e "    ${CYAN}# Force update lists${RESET}"
    echo    "    /usr/local/bin/update_blocklist.sh && /usr/local/bin/update_allowlist.sh && systemctl reload haproxy"
    echo -e "    ${CYAN}# Relay should send to this server on port ${GATE_LISTEN_PORT} with send-proxy-v2${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 12 · MOBILE443-FILTER
# ─────────────────────────────────────────────────────────────────────────────

MOBILE443_BASE_URL="https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main"

# mode: node | gate | relay
install_mobile443_filter() {
    local mode="${1:-node}"
    log_step "Installing mobile443-filter (mode: ${mode})"

    local script_url
    case "$mode" in
        gate) script_url="${MOBILE443_BASE_URL}/install_block_only.sh" ;;
        node|relay|*) script_url="${MOBILE443_BASE_URL}/install.sh" ;;
    esac

    log_info "Script URL: ${script_url}"

    # Check URL availability
    if ! curl -fsS --max-time 10 "$script_url" -o /dev/null 2>/dev/null; then
        log_error "Cannot reach mobile443-filter URL: ${script_url}"
        STEP_STATUS["mobile443"]="FAILED"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install mobile443-filter from ${script_url}"
        STEP_STATUS["mobile443"]="DRY"
        return 0
    fi

    if bash <(curl -Ls "$script_url"); then
        log_ok "mobile443-filter installed successfully"
        STEP_STATUS["mobile443"]="OK"
    else
        log_error "mobile443-filter installation failed (exit code: $?)"
        STEP_STATUS["mobile443"]="FAILED"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 13 · REMNANODE
# ─────────────────────────────────────────────────────────────────────────────

REMNANODE_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"

install_remnanode() {
    log_step "Installing remnanode"

    if [[ "$IS_CONTAINER" == true ]]; then
        log_warn "Container virtualization detected — Docker may not work properly!"
        if [[ "$NON_INTERACTIVE" == false ]]; then
            read -rp "  Continue anyway? [y/N]: " ans
            [[ "${ans,,}" == "y" ]] || { log_info "Skipping remnanode"; STEP_STATUS["remnanode"]="SKIPPED"; return 0; }
        fi
    fi

    if ! curl -fsS --max-time 10 "$REMNANODE_URL" -o /dev/null 2>/dev/null; then
        log_error "Cannot reach remnanode URL: ${REMNANODE_URL}"
        STEP_STATUS["remnanode"]="FAILED"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install remnanode from ${REMNANODE_URL}"
        STEP_STATUS["remnanode"]="DRY"
        return 0
    fi

    log_info "Running remnanode installer..."
    if bash <(curl -Ls "$REMNANODE_URL") @ install; then
        log_ok "remnanode installed successfully"
        # Post-install checks
        if command -v docker &>/dev/null; then
            local containers
            containers="$(docker ps --format '{{.Names}}' 2>/dev/null || echo '')"
            log_info "Running containers: ${containers:-none}"
        fi
        STEP_STATUS["remnanode"]="OK"
    else
        log_error "remnanode installation failed"
        STEP_STATUS["remnanode"]="FAILED"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 14 · SELFSTEAL
# ─────────────────────────────────────────────────────────────────────────────

SELFSTEAL_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh"

install_selfsteal() {
    log_step "Installing selfsteal"

    if [[ "$SKIP_SELFSTEAL" == true ]]; then
        log_info "Skipping selfsteal (--skip-selfsteal)"
        STEP_STATUS["selfsteal"]="SKIPPED"
        return 0
    fi

    if [[ "$NON_INTERACTIVE" == false ]]; then
        read -rp "  Install selfsteal? [Y/n]: " ans
        if [[ "${ans,,}" == "n" ]]; then
            log_info "Skipping selfsteal"
            STEP_STATUS["selfsteal"]="SKIPPED"
            return 0
        fi
    fi

    if ! curl -fsS --max-time 10 "$SELFSTEAL_URL" -o /dev/null 2>/dev/null; then
        log_error "Cannot reach selfsteal URL: ${SELFSTEAL_URL}"
        STEP_STATUS["selfsteal"]="FAILED"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install selfsteal from ${SELFSTEAL_URL}"
        STEP_STATUS["selfsteal"]="DRY"
        return 0
    fi

    log_info "Running selfsteal installer..."
    if bash <(curl -Ls "$SELFSTEAL_URL") @ install; then
        log_ok "selfsteal installed successfully"
        STEP_STATUS["selfsteal"]="OK"
    else
        log_error "selfsteal installation failed"
        STEP_STATUS["selfsteal"]="FAILED"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 15 · DOCKER
# ─────────────────────────────────────────────────────────────────────────────

install_docker() {
    log_step "Installing Docker & Docker Compose"

    if command -v docker &>/dev/null; then
        log_ok "Docker already installed: $(docker --version 2>/dev/null)"
        STEP_STATUS["docker"]="SKIPPED"
        return 0
    fi

    if [[ "$IS_CONTAINER" == true ]]; then
        log_warn "Container virtualization — Docker may not function correctly!"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install Docker via official script"
        STEP_STATUS["docker"]="DRY"
        return 0
    fi

    # Official Docker install
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker &>/dev/null
    systemctl start  docker &>/dev/null
    log_ok "Docker installed: $(docker --version 2>/dev/null)"

    # Docker Compose v2 (plugin)
    if ! docker compose version &>/dev/null; then
        install_packages docker-compose-plugin 2>/dev/null || \
        install_packages docker-compose        2>/dev/null || \
        log_warn "docker-compose plugin not available in repo"
    fi
    log_ok "Docker Compose: $(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || echo 'unavailable')"
    STEP_STATUS["docker"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 15b · MONITORING STACK (Prometheus + Grafana)
#
# Stack (Docker Compose at /opt/monitoring):
#   prometheus     — scrapes node_exporter + haproxy_exporter, port 9090 (localhost)
#   grafana        — dashboards, port 3000 (public, password-protected)
#   node_exporter  — system metrics, port 9100 (localhost)
#   haproxy_exporter — HAProxy stats via socket, port 9101 (localhost)
#
# Grafana admin password: auto-generated, saved to /opt/monitoring/.grafana_password
# ─────────────────────────────────────────────────────────────────────────────

MONITORING_DIR="/opt/monitoring"
MONITORING_GRAFANA_PORT="3000"
MONITORING_PROMETHEUS_PORT="9090"

install_monitoring() {
    log_step "Installing monitoring stack (Prometheus + Grafana)"

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install: prometheus, grafana, node_exporter, haproxy_exporter via Docker Compose"
        log_dry "Would create: ${MONITORING_DIR}/docker-compose.yml + provisioning files"
        log_dry "Would open UFW port ${MONITORING_GRAFANA_PORT}/tcp for Grafana"
        STEP_STATUS["monitoring"]="DRY"
        return 0
    fi

    # Docker is required
    if ! command -v docker &>/dev/null; then
        log_info "Docker not found — installing..."
        install_docker
    fi
    if ! docker compose version &>/dev/null 2>&1; then
        log_error "Docker Compose not available — cannot install monitoring stack"
        STEP_STATUS["monitoring"]="FAILED"
        return 1
    fi

    mkdir -p "${MONITORING_DIR}/grafana/provisioning/datasources"
    mkdir -p "${MONITORING_DIR}/grafana/provisioning/dashboards"
    mkdir -p "${MONITORING_DIR}/grafana/dashboards"
    mkdir -p "${MONITORING_DIR}/prometheus"

    # ── Generate random Grafana admin password ────────────────────────────────
    local grafana_pass
    if [[ -f "${MONITORING_DIR}/.grafana_password" ]]; then
        grafana_pass="$(cat "${MONITORING_DIR}/.grafana_password")"
        log_info "Using existing Grafana password from ${MONITORING_DIR}/.grafana_password"
    else
        grafana_pass="$(tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 20 2>/dev/null || echo 'ChangeMe123!')"
        echo "$grafana_pass" > "${MONITORING_DIR}/.grafana_password"
        chmod 600 "${MONITORING_DIR}/.grafana_password"
    fi

    # ── Docker Compose ────────────────────────────────────────────────────────
    cat > "${MONITORING_DIR}/docker-compose.yml" <<EOF
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "127.0.0.1:${MONITORING_PROMETHEUS_PORT}:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=30d'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "0.0.0.0:${MONITORING_GRAFANA_PORT}:3000"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=${grafana_pass}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:${MONITORING_GRAFANA_PORT}
      - GF_ANALYTICS_REPORTING_ENABLED=false
      - GF_ANALYTICS_CHECK_FOR_UPDATES=false
    depends_on:
      - prometheus

  node_exporter:
    image: prom/node-exporter:latest
    container_name: node_exporter
    restart: unless-stopped
    pid: host
    network_mode: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(\\$\$|/)'
      - '--web.listen-address=127.0.0.1:9100'

  haproxy_exporter:
    image: prom/haproxy-exporter:latest
    container_name: haproxy_exporter
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/haproxy:/var/run/haproxy:ro
    command:
      - '--haproxy.scrape-uri=unix:/var/run/haproxy/admin.sock'
      - '--web.listen-address=127.0.0.1:9101'

volumes:
  prometheus_data:
  grafana_data:
EOF

    # ── Prometheus config ─────────────────────────────────────────────────────
    cat > "${MONITORING_DIR}/prometheus/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: '{{ hostname }}'

  - job_name: 'haproxy'
    static_configs:
      - targets: ['localhost:9101']
EOF

    # ── Grafana datasource provisioning ──────────────────────────────────────
    cat > "${MONITORING_DIR}/grafana/provisioning/datasources/prometheus.yml" <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
EOF

    # ── Grafana dashboard provisioning ────────────────────────────────────────
    cat > "${MONITORING_DIR}/grafana/provisioning/dashboards/default.yml" <<'EOF'
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: 'Server Bootstrap'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
EOF

    # ── HAProxy dashboard ─────────────────────────────────────────────────────
    cat > "${MONITORING_DIR}/grafana/dashboards/haproxy.json" <<'DASHBOARD'
{
  "title": "HAProxy Overview",
  "uid": "haproxy-overview",
  "schemaVersion": 38,
  "version": 1,
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "panels": [
    {
      "type": "stat", "id": 1, "gridPos": {"h": 4, "w": 4, "x": 0, "y": 0},
      "title": "Active Connections",
      "targets": [{"expr": "haproxy_process_current_connections", "datasource": "Prometheus"}],
      "options": {"colorMode": "background", "graphMode": "area"},
      "fieldConfig": {"defaults": {"thresholds": {"steps": [
        {"color": "green", "value": null}, {"color": "yellow", "value": 10000}, {"color": "red", "value": 40000}
      ]}}}
    },
    {
      "type": "stat", "id": 2, "gridPos": {"h": 4, "w": 4, "x": 4, "y": 0},
      "title": "Sessions/sec",
      "targets": [{"expr": "rate(haproxy_process_sessions_total[1m])", "datasource": "Prometheus"}],
      "options": {"colorMode": "background", "graphMode": "area"},
      "fieldConfig": {"defaults": {"unit": "reqps"}}
    },
    {
      "type": "stat", "id": 3, "gridPos": {"h": 4, "w": 4, "x": 8, "y": 0},
      "title": "Bytes In/s",
      "targets": [{"expr": "rate(haproxy_process_bytes_in_total[1m])", "datasource": "Prometheus"}],
      "options": {"colorMode": "value"},
      "fieldConfig": {"defaults": {"unit": "Bps"}}
    },
    {
      "type": "stat", "id": 4, "gridPos": {"h": 4, "w": 4, "x": 12, "y": 0},
      "title": "Bytes Out/s",
      "targets": [{"expr": "rate(haproxy_process_bytes_out_total[1m])", "datasource": "Prometheus"}],
      "options": {"colorMode": "value"},
      "fieldConfig": {"defaults": {"unit": "Bps"}}
    },
    {
      "type": "stat", "id": 5, "gridPos": {"h": 4, "w": 4, "x": 16, "y": 0},
      "title": "Backend bk_upstream Status",
      "targets": [{"expr": "haproxy_backend_status{proxy=\"bk_upstream\"}", "datasource": "Prometheus"}],
      "options": {"colorMode": "background"},
      "fieldConfig": {"defaults": {"mappings": [
        {"options": {"1": {"text": "UP", "color": "green"}}, "type": "value"},
        {"options": {"0": {"text": "DOWN", "color": "red"}}, "type": "value"}
      ]}}
    },
    {
      "type": "timeseries", "id": 6, "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
      "title": "Connections over time",
      "targets": [
        {"expr": "haproxy_process_current_connections", "legendFormat": "Active", "datasource": "Prometheus"},
        {"expr": "rate(haproxy_process_sessions_total[1m])", "legendFormat": "Sessions/s", "datasource": "Prometheus"}
      ],
      "fieldConfig": {"defaults": {"unit": "short"}}
    },
    {
      "type": "timeseries", "id": 7, "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
      "title": "Traffic (bytes/s)",
      "targets": [
        {"expr": "rate(haproxy_process_bytes_in_total[1m])", "legendFormat": "In", "datasource": "Prometheus"},
        {"expr": "rate(haproxy_process_bytes_out_total[1m])", "legendFormat": "Out", "datasource": "Prometheus"}
      ],
      "fieldConfig": {"defaults": {"unit": "Bps"}}
    },
    {
      "type": "timeseries", "id": 8, "gridPos": {"h": 8, "w": 24, "x": 0, "y": 12},
      "title": "Backend connections (upstream / blocked / ignored)",
      "targets": [
        {"expr": "rate(haproxy_backend_sessions_total{proxy=\"bk_upstream\"}[1m])", "legendFormat": "upstream", "datasource": "Prometheus"},
        {"expr": "rate(haproxy_backend_sessions_total{proxy=\"bk_blocked\"}[1m])", "legendFormat": "blocked", "datasource": "Prometheus"},
        {"expr": "rate(haproxy_backend_sessions_total{proxy=\"bk_ignored\"}[1m])", "legendFormat": "ignored", "datasource": "Prometheus"}
      ],
      "fieldConfig": {"defaults": {"unit": "reqps"}}
    }
  ]
}
DASHBOARD

    # ── Node Exporter dashboard ───────────────────────────────────────────────
    cat > "${MONITORING_DIR}/grafana/dashboards/node.json" <<'DASHBOARD'
{
  "title": "Node Overview",
  "uid": "node-overview",
  "schemaVersion": 38,
  "version": 1,
  "refresh": "30s",
  "time": { "from": "now-1h", "to": "now" },
  "panels": [
    {
      "type": "gauge", "id": 1, "gridPos": {"h": 6, "w": 6, "x": 0, "y": 0},
      "title": "CPU Usage %",
      "targets": [{"expr": "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100)", "datasource": "Prometheus"}],
      "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100,
        "thresholds": {"steps": [{"color":"green","value":null},{"color":"yellow","value":70},{"color":"red","value":90}]}}}
    },
    {
      "type": "gauge", "id": 2, "gridPos": {"h": 6, "w": 6, "x": 6, "y": 0},
      "title": "Memory Usage %",
      "targets": [{"expr": "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)", "datasource": "Prometheus"}],
      "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100,
        "thresholds": {"steps": [{"color":"green","value":null},{"color":"yellow","value":80},{"color":"red","value":95}]}}}
    },
    {
      "type": "stat", "id": 3, "gridPos": {"h": 6, "w": 6, "x": 12, "y": 0},
      "title": "Load Average (1m)",
      "targets": [{"expr": "node_load1", "datasource": "Prometheus"}],
      "fieldConfig": {"defaults": {"unit": "short"}}
    },
    {
      "type": "stat", "id": 4, "gridPos": {"h": 6, "w": 6, "x": 18, "y": 0},
      "title": "Uptime",
      "targets": [{"expr": "node_time_seconds - node_boot_time_seconds", "datasource": "Prometheus"}],
      "fieldConfig": {"defaults": {"unit": "s"}}
    },
    {
      "type": "timeseries", "id": 5, "gridPos": {"h": 8, "w": 12, "x": 0, "y": 6},
      "title": "CPU over time",
      "targets": [{"expr": "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100)", "legendFormat": "CPU %", "datasource": "Prometheus"}],
      "fieldConfig": {"defaults": {"unit": "percent"}}
    },
    {
      "type": "timeseries", "id": 6, "gridPos": {"h": 8, "w": 12, "x": 12, "y": 6},
      "title": "Network traffic",
      "targets": [
        {"expr": "rate(node_network_receive_bytes_total{device!~\"lo|docker.*|veth.*\"}[1m])", "legendFormat": "In {{device}}", "datasource": "Prometheus"},
        {"expr": "rate(node_network_transmit_bytes_total{device!~\"lo|docker.*|veth.*\"}[1m])", "legendFormat": "Out {{device}}", "datasource": "Prometheus"}
      ],
      "fieldConfig": {"defaults": {"unit": "Bps"}}
    },
    {
      "type": "timeseries", "id": 7, "gridPos": {"h": 8, "w": 24, "x": 0, "y": 14},
      "title": "Disk I/O",
      "targets": [
        {"expr": "rate(node_disk_read_bytes_total[1m])", "legendFormat": "Read {{device}}", "datasource": "Prometheus"},
        {"expr": "rate(node_disk_written_bytes_total[1m])", "legendFormat": "Write {{device}}", "datasource": "Prometheus"}
      ],
      "fieldConfig": {"defaults": {"unit": "Bps"}}
    }
  ]
}
DASHBOARD

    # ── UFW: open Grafana port ────────────────────────────────────────────────
    if command -v ufw &>/dev/null; then
        ufw allow "${MONITORING_GRAFANA_PORT}/tcp" comment 'Grafana dashboard' &>/dev/null || true
        log_info "UFW: opened port ${MONITORING_GRAFANA_PORT}/tcp for Grafana"
    fi

    # ── Cron watchdog: restart if containers are down ─────────────────────────
    cat > /etc/cron.d/monitoring-watchdog <<EOF
# server-bootstrap: monitoring stack watchdog
*/5 * * * * root cd ${MONITORING_DIR} && docker compose ps --quiet | grep -q . || docker compose up -d >> /var/log/monitoring-watchdog.log 2>&1
EOF

    # ── Start the stack ───────────────────────────────────────────────────────
    log_info "Starting monitoring stack..."
    cd "${MONITORING_DIR}"
    docker compose pull --quiet 2>/dev/null || log_warn "Could not pull latest images — using cached"
    docker compose up -d

    # Wait a moment and check
    sleep 5
    if docker compose ps 2>/dev/null | grep -qE "Up|running"; then
        log_ok "Monitoring stack started"
        docker compose ps 2>/dev/null | sed 's/^/    /'
    else
        log_warn "Some containers may not be running — check: docker compose -f ${MONITORING_DIR}/docker-compose.yml ps"
    fi

    STEP_STATUS["monitoring"]="OK"

    echo ""
    log_ok "Monitoring stack ready:"
    local server_ip
    server_ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo 'YOUR_IP')"
    echo -e "    ${CYAN}Grafana   :${RESET} http://${server_ip}:${MONITORING_GRAFANA_PORT}"
    echo -e "    ${CYAN}Login     :${RESET} admin / $(cat "${MONITORING_DIR}/.grafana_password")"
    echo -e "    ${CYAN}Prometheus:${RESET} http://127.0.0.1:${MONITORING_PROMETHEUS_PORT} (localhost only)"
    echo -e "    ${CYAN}Password  :${RESET} saved to ${MONITORING_DIR}/.grafana_password"
    echo ""
}

uninstall_monitoring() {
    log_step "Uninstalling monitoring stack"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would stop and remove monitoring Docker Compose stack + cron"; return 0; }

    if [[ -f "${MONITORING_DIR}/docker-compose.yml" ]]; then
        cd "${MONITORING_DIR}"
        docker compose down --volumes 2>/dev/null || true
    fi

    rm -f /etc/cron.d/monitoring-watchdog
    rm -rf "${MONITORING_DIR}"

    if command -v ufw &>/dev/null; then
        ufw delete allow "${MONITORING_GRAFANA_PORT}/tcp" &>/dev/null || true
    fi

    state_save_step "monitoring" "REMOVED"
    log_ok "Monitoring stack removed"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 16 · STATUS CHECKS
# ─────────────────────────────────────────────────────────────────────────────

check_bbr() {
    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'unknown')"
    local qdisc
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'unknown')"
    echo -e "  ${CYAN}TCP congestion control:${RESET} ${cc}"
    echo -e "  ${CYAN}Default qdisc         :${RESET} ${qdisc}"
    if [[ "$cc" == "bbr" ]]; then
        echo -e "  ${GREEN}✓ BBR active${RESET}"
    else
        echo -e "  ${YELLOW}⚠ BBR not active (current: ${cc})${RESET}"
    fi
}

check_status_all() {
    log_step "System status"
    print_separator

    echo -e "\n  ${BOLD}Network:${RESET}"
    ip -4 addr show | grep 'inet ' | awk '{print "    " $2 "  (" $NF ")"}' 2>/dev/null || echo "    n/a"

    echo -e "\n  ${BOLD}Open ports:${RESET}"
    ss -tlnp 2>/dev/null | tail -n +2 | awk '{print "    " $4}' | sort -u || echo "    n/a"

    echo -e "\n  ${BOLD}BBR / qdisc:${RESET}"
    check_bbr

    echo -e "\n  ${BOLD}UFW:${RESET}"
    ufw status 2>/dev/null | head -5 | sed 's/^/    /' || echo "    not installed"

    echo -e "\n  ${BOLD}Fail2Ban:${RESET}"
    systemctl is-active fail2ban 2>/dev/null | sed 's/^/    /' || echo "    not installed"
    fail2ban-client status 2>/dev/null | head -3 | sed 's/^/    /' || true

    echo -e "\n  ${BOLD}HAProxy:${RESET}"
    if command -v haproxy &>/dev/null; then
        systemctl is-active haproxy 2>/dev/null | sed 's/^/    /' || echo "    inactive"
    else
        echo "    not installed"
    fi

    echo -e "\n  ${BOLD}Docker:${RESET}"
    if command -v docker &>/dev/null; then
        docker --version 2>/dev/null | sed 's/^/    /'
        docker ps --format '    {{.Names}}  {{.Status}}' 2>/dev/null || echo "    (no containers)"
    else
        echo "    not installed"
    fi

    echo -e "\n  ${BOLD}Monitoring stack:${RESET}"
    if [[ -f "${MONITORING_DIR}/docker-compose.yml" ]]; then
        local server_ip
        server_ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo '?')"
        if command -v docker &>/dev/null; then
            docker compose -f "${MONITORING_DIR}/docker-compose.yml" ps --format '    {{.Name}}  {{.Status}}' 2>/dev/null \
                || echo "    (cannot reach Docker)"
        fi
        if [[ -f "${MONITORING_DIR}/.grafana_password" ]]; then
            echo -e "    Grafana: http://${server_ip}:${MONITORING_GRAFANA_PORT}  (admin / $(cat "${MONITORING_DIR}/.grafana_password"))"
        else
            echo -e "    Grafana: http://${server_ip}:${MONITORING_GRAFANA_PORT}"
        fi
    else
        echo "    not installed (use custom mode → Install monitoring)"
    fi

    print_separator
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 17 · SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗"
    echo -e  "║                  BOOTSTRAP SUMMARY                  ║"
    echo -e  "╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""

    for step in "${!STEP_STATUS[@]}"; do
        local status="${STEP_STATUS[$step]}"
        local icon color
        case "$status" in
            OK)      icon="✓"; color="$LGREEN" ;;
            FAILED)  icon="✗"; color="$LRED"   ;;
            SKIPPED) icon="–"; color="$GRAY"   ;;
            DRY)     icon="○"; color="$MAGENTA" ;;
            WARN)    icon="⚠"; color="$YELLOW"  ;;
            *)       icon="?"; color="$WHITE"   ;;
        esac
        printf "  ${color}[%s]${RESET}  %-25s %s\n" "$icon" "$step" "$status"
    done

    echo ""
    echo -e "  ${CYAN}Log file   :${RESET} ${LOG_FILE}"
    echo -e "  ${CYAN}Config file:${RESET} ${CONFIG_FILE}"
    echo -e "  ${CYAN}Backups    :${RESET} ${BACKUP_DIR}"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "\n  ${MAGENTA}${BOLD}[DRY RUN] — No changes were made.${RESET}"
    fi
    echo ""
}

save_config() {
    if [[ "$DRY_RUN" == true ]]; then return 0; fi
    cat > "$CONFIG_FILE" <<EOF
# server-bootstrap configuration — generated $(date)
BOOTSTRAP_VERSION="${SCRIPT_VERSION}"
BOOTSTRAP_MODE="${MODE}"
BOOTSTRAP_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GATE_ADDRESS="${GATE_ADDRESS:-}"
IS_CONTAINER="${IS_CONTAINER:-false}"
OS_PRETTY="${OS_PRETTY:-}"
EOF
    log_debug "Config saved to ${CONFIG_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 17b · STATE ENGINE (resume + version-aware reinstall)
# ─────────────────────────────────────────────────────────────────────────────
#
#  State file format (/etc/server-bootstrap.state):
#    VERSION=1.0.2
#    MODE=relay
#    UPDATED=2026-04-12T04:00:00Z
#    step:haproxy=OK
#    step:ufw=OK
#    step:fail2ban=FAILED
#    ...
#
#  Logic:
#    - state_step_ok <step>  → returns 0 if step=OK and version matches
#    - state_save_step <step> <status>  → writes/updates step in state file
#    - state_check_version  → returns 0 if version matches, 1 if changed
#    - state_load  → reads state file into STATE_ associative array
#    - state_reset → clears state file (full reinstall)
# ─────────────────────────────────────────────────────────────────────────────

declare -A _STATE=()
_STATE_VERSION=""
_STATE_MODE=""

state_load() {
    [[ -f "$STATE_FILE" ]] || return 0
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^# ]] && continue
        [[ -z "$key" ]]    && continue
        case "$key" in
            VERSION) _STATE_VERSION="$val" ;;
            MODE)    _STATE_MODE="$val"    ;;
            step:*)  _STATE["${key#step:}"]="$val" ;;
        esac
    done < "$STATE_FILE"
    log_debug "State loaded: version=${_STATE_VERSION} mode=${_STATE_MODE} steps=${#_STATE[@]}"
}

state_save_step() {
    local step="$1" status="$2"
    [[ "$DRY_RUN" == true ]] && return 0

    # Update in-memory
    _STATE["$step"]="$status"

    # Rewrite state file atomically
    local tmp; tmp="$(mktemp)"
    {
        echo "VERSION=${SCRIPT_VERSION}"
        echo "MODE=${MODE:-${_STATE_MODE}}"
        echo "UPDATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for s in "${!_STATE[@]}"; do
            echo "step:${s}=${_STATE[$s]}"
        done
    } > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

state_step_ok() {
    # Returns 0 (true) if step completed OK in current version → skip it
    local step="$1"
    [[ "$RESUME" != true ]]                        && return 1
    [[ "${_STATE[$step]:-}" == "OK" ]]             || return 1
    [[ "${_STATE_VERSION:-}" == "$SCRIPT_VERSION" ]] || return 1
    return 0
}

state_check_version() {
    # Returns 0 if state exists and version differs from current
    [[ -f "$STATE_FILE" ]] || return 1
    [[ -n "${_STATE_VERSION:-}" ]] || return 1
    [[ "${_STATE_VERSION}" != "$SCRIPT_VERSION" ]] && return 0
    return 1
}

state_reset() {
    rm -f "$STATE_FILE"
    _STATE=()
    _STATE_VERSION=""
    _STATE_MODE=""
    log_info "State cleared — fresh install"
}

# ── Show changelog between two versions ──────────────────────────────────────
show_changelog() {
    local from="${1:-}" to="${2:-$SCRIPT_VERSION}"
    echo ""
    echo -e "  ${BOLD}${CYAN}Changelog:${RESET}"
    echo ""

    # Collect and sort versions
    local versions=()
    for v in "${!CHANGELOG[@]}"; do versions+=("$v"); done
    IFS=$'\n' versions=($(printf '%s\n' "${versions[@]}" | sort -V))

    local show=false
    for v in "${versions[@]}"; do
        # Show versions strictly after 'from' up to 'to' inclusive
        if [[ "$v" == "$to" ]]; then
            echo -e "  ${YELLOW}v${v}${RESET}"
            echo -e "    ${CHANGELOG[$v]}"
            echo ""
            break
        fi
        if [[ "$show" == true || "$v" == "$from" ]]; then
            if [[ "$v" != "$from" ]]; then
                echo -e "  ${YELLOW}v${v}${RESET}"
                echo -e "    ${CHANGELOG[$v]}"
                echo ""
            fi
            show=true
        fi
    done

    if [[ "$show" == false ]]; then
        # from not found — show all up to to
        for v in "${versions[@]}"; do
            echo -e "  ${YELLOW}v${v}${RESET}"
            echo -e "    ${CHANGELOG[$v]}"
            echo ""
            [[ "$v" == "$to" ]] && break
        done
    fi
}

# ── Soft update: backup configs → re-run steps → restore on failure ──────────
#
#  Strategy per component:
#    haproxy   → backup /etc/haproxy/*.cfg,*.lst  → re-run setup_haproxy → restore if failed
#    fail2ban  → backup /etc/fail2ban/jail.local  → re-run setup_fail2ban
#    ufw       → backup ufw rules                 → re-run setup_ufw
#    sysctl    → backup sysctl file               → re-run apply_sysctl_*
#    others    → re-run as-is (no config to preserve)
# ─────────────────────────────────────────────────────────────────────────────
_soft_backup() {
    local label="$1"; shift
    local bak_dir="${BACKUP_DIR}/soft-update-${TIMESTAMP}/${label}"
    mkdir -p "$bak_dir"
    for src in "$@"; do
        [[ -e "$src" ]] && cp -a "$src" "$bak_dir/" && \
            log_debug "Backed up ${src} → ${bak_dir}/"
    done
    echo "$bak_dir"  # return path for restore
}

_soft_restore() {
    local bak_dir="$1" dest_dir="$2"
    if [[ -d "$bak_dir" ]]; then
        cp -a "${bak_dir}/." "$dest_dir/" 2>/dev/null && \
            log_warn "Restored configs from backup: ${bak_dir}" || \
            log_error "Restore failed — check ${bak_dir} manually"
    fi
}

run_soft_update() {
    log_step "SOFT UPDATE: v${_STATE_VERSION} → v${SCRIPT_VERSION}"
    log_info "Configs will be backed up before each component update"
    log_info "On failure, previous config is automatically restored"
    echo ""

    local mode="${_STATE_MODE:-$MODE}"

    # ── haproxy ──
    if [[ "${_STATE[haproxy]:-}" == "OK" ]]; then
        log_step "Updating: haproxy"
        local bak; bak=$(_soft_backup "haproxy" /etc/haproxy)
        state_save_step "haproxy" "UPDATING"
        if setup_haproxy; then
            state_save_step "haproxy" "OK"
            log_ok "haproxy updated"
        else
            log_error "haproxy update failed — restoring backup"
            _soft_restore "$bak" /etc/haproxy
            state_save_step "haproxy" "FAILED"
        fi
    fi

    # ── fail2ban ──
    if [[ "${_STATE[fail2ban]:-}" == "OK" ]]; then
        log_step "Updating: fail2ban"
        local bak; bak=$(_soft_backup "fail2ban" /etc/fail2ban/jail.local)
        state_save_step "fail2ban" "UPDATING"
        if setup_fail2ban; then
            state_save_step "fail2ban" "OK"
            log_ok "fail2ban updated"
        else
            log_error "fail2ban update failed — restoring backup"
            _soft_restore "$bak" /etc/fail2ban
            state_save_step "fail2ban" "FAILED"
        fi
    fi

    # ── ufw ──
    if [[ "${_STATE[ufw]:-}" == "OK" ]]; then
        log_step "Updating: UFW rules"
        local bak; bak=$(_soft_backup "ufw" /etc/ufw/user.rules /etc/ufw/user6.rules)
        state_save_step "ufw" "UPDATING"
        if setup_ufw "$mode"; then
            state_save_step "ufw" "OK"
            log_ok "UFW updated"
        else
            log_error "UFW update failed — restoring backup"
            _soft_restore "$bak" /etc/ufw
            state_save_step "ufw" "FAILED"
        fi
    fi

    # ── sysctl ──
    if [[ "${_STATE[sysctl_network]:-}" == "OK" ]]; then
        log_step "Updating: sysctl (network)"
        local bak; bak=$(_soft_backup "sysctl" "$SYSCTL_FILE")
        state_save_step "sysctl_network" "UPDATING"
        if apply_sysctl_network; then
            state_save_step "sysctl_network" "OK"
            log_ok "sysctl network updated"
        else
            log_error "sysctl update failed — restoring backup"
            _soft_restore "$bak" "$(dirname "$SYSCTL_FILE")"
            sysctl --system &>/dev/null || true
            state_save_step "sysctl_network" "FAILED"
        fi
    fi

    if [[ "${_STATE[sysctl_router]:-}" == "OK" ]]; then
        state_save_step "sysctl_router" "UPDATING"
        if apply_sysctl_router; then
            state_save_step "sysctl_router" "OK"
            log_ok "sysctl router updated"
        else
            state_save_step "sysctl_router" "FAILED"
        fi
    fi

    # ── ssh ──
    if [[ "${_STATE[ssh]:-}" == "OK" ]]; then
        log_step "Updating: SSH config"
        local bak; bak=$(_soft_backup "ssh" /etc/ssh/sshd_config)
        state_save_step "ssh" "UPDATING"
        if setup_ssh; then
            state_save_step "ssh" "OK"
            log_ok "SSH config updated"
        else
            log_error "SSH update failed — restoring backup"
            _soft_restore "$bak" /etc/ssh
            systemctl restart sshd 2>/dev/null || true
            state_save_step "ssh" "FAILED"
        fi
    fi

    # ── haproxy_gate ──
    if [[ "${_STATE[haproxy_gate]:-}" == "OK" ]]; then
        log_step "Updating: haproxy_gate"
        local bak; bak=$(_soft_backup "haproxy_gate" /etc/haproxy)
        state_save_step "haproxy_gate" "UPDATING"
        if setup_haproxy_gate; then
            state_save_step "haproxy_gate" "OK"
            log_ok "haproxy_gate updated"
        else
            log_error "haproxy_gate update failed — restoring backup"
            _soft_restore "$bak" /etc/haproxy
            state_save_step "haproxy_gate" "FAILED"
        fi
    fi

    # ── monitoring ──
    if [[ "${_STATE[monitoring]:-}" == "OK" ]]; then
        log_step "Updating: monitoring stack"
        state_save_step "monitoring" "UPDATING"
        if install_monitoring; then
            state_save_step "monitoring" "OK"
            log_ok "monitoring updated"
        else
            state_save_step "monitoring" "FAILED"
        fi
    fi

    # ── remnanode / selfsteal / mobile443: re-run without data wipe ──
    for step in remnanode selfsteal mobile443; do
        if [[ "${_STATE[$step]:-}" == "OK" ]]; then
            log_step "Updating: ${step}"
            state_save_step "$step" "UPDATING"
            case "$step" in
                remnanode) install_remnanode   ;;
                selfsteal) install_selfsteal   ;;
                mobile443) install_mobile443_filter "$mode" ;;
            esac
            local rc=$?
            [[ $rc -eq 0 ]] && state_save_step "$step" "OK" || state_save_step "$step" "FAILED"
        fi
    done

    # Bump version in state after soft update
    state_save_step "_version_updated" "OK"
    log_ok "Soft update complete — v${_STATE_VERSION} → v${SCRIPT_VERSION}"
    log_info "Backups saved to: ${BACKUP_DIR}/soft-update-${TIMESTAMP}/"
}


# Usage: run_step <step_name> <function_name> [args...]
run_step() {
    local step="$1"; shift
    local fn="$1";   shift

    if state_step_ok "$step"; then
        log_ok "  [RESUME] Skipping ${step} — already completed in v${_STATE_VERSION}"
        STEP_STATUS["$step"]="SKIPPED(resume)"
        return 0
    fi

    "$fn" "$@"
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        state_save_step "$step" "OK"
    else
        state_save_step "$step" "FAILED"
    fi
    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 17c · UNINSTALL FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

uninstall_haproxy() {
    log_step "Uninstalling HAProxy"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would remove haproxy, cron, scripts, lists"; return 0; }

    systemctl stop haproxy    2>/dev/null || true
    systemctl disable haproxy 2>/dev/null || true
    apt-get remove --purge -y haproxy 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    rm -f /etc/cron.d/haproxy-lists
    rm -f /usr/local/bin/update_blocklist.sh
    rm -f /usr/local/bin/update_allowlist.sh
    rm -f /usr/local/bin/analyze_logs.sh
    rm -f /etc/rsyslog.d/49-haproxy.conf
    rm -f /etc/logrotate.d/haproxy
    rm -rf /etc/haproxy
    systemctl restart rsyslog 2>/dev/null || true

    state_save_step "haproxy" "REMOVED"
    log_ok "HAProxy removed"
}

uninstall_fail2ban() {
    log_step "Uninstalling fail2ban"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would remove fail2ban and jail configs"; return 0; }

    systemctl stop fail2ban    2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
    apt-get remove --purge -y fail2ban 2>/dev/null || true
    rm -f /etc/fail2ban/jail.local

    state_save_step "fail2ban" "REMOVED"
    log_ok "fail2ban removed"
}

uninstall_ufw() {
    log_step "Uninstalling UFW"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would disable and purge ufw"; return 0; }

    ufw --force disable 2>/dev/null || true
    apt-get remove --purge -y ufw 2>/dev/null || true

    state_save_step "ufw" "REMOVED"
    log_ok "UFW removed"
}

uninstall_remnanode() {
    log_step "Uninstalling remnanode"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would stop and remove remnanode container and data"; return 0; }

    local compose_dir="/opt/remnanode"
    if [[ -f "${compose_dir}/docker-compose.yml" ]]; then
        docker compose -f "${compose_dir}/docker-compose.yml" down --volumes 2>/dev/null || true
    fi
    rm -rf "$compose_dir"
    rm -rf /var/lib/remnanode
    rm -rf /var/log/remnanode

    state_save_step "remnanode" "REMOVED"
    log_ok "remnanode removed"
}

uninstall_selfsteal() {
    log_step "Uninstalling selfsteal"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would remove selfsteal service and files"; return 0; }

    systemctl stop selfsteal    2>/dev/null || true
    systemctl disable selfsteal 2>/dev/null || true
    rm -f /etc/systemd/system/selfsteal.service
    rm -f /usr/local/bin/selfsteal
    rm -rf /etc/selfsteal
    systemctl daemon-reload 2>/dev/null || true

    state_save_step "selfsteal" "REMOVED"
    log_ok "selfsteal removed"
}

uninstall_mobile443() {
    log_step "Uninstalling mobile443-filter"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would remove mobile443 nftables rules and scripts"; return 0; }

    # Try to call cleanup if script exists
    if [[ -f /usr/local/bin/mobile443-filter.sh ]]; then
        bash /usr/local/bin/mobile443-filter.sh uninstall 2>/dev/null || true
    fi
    rm -f /usr/local/bin/mobile443-filter.sh
    rm -f /etc/cron.d/mobile443-filter
    rm -f /etc/nftables.d/mobile443.nft 2>/dev/null || true

    state_save_step "mobile443" "REMOVED"
    log_ok "mobile443-filter removed"
}

uninstall_docker() {
    log_step "Uninstalling Docker"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would remove docker, images, volumes"; return 0; }

    systemctl stop docker 2>/dev/null || true
    apt-get remove --purge -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    rm -rf /var/lib/docker /etc/docker

    state_save_step "docker" "REMOVED"
    log_ok "Docker removed"
}

uninstall_sysctl() {
    log_step "Reverting sysctl settings"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would remove ${SYSCTL_FILE} and reload sysctl"; return 0; }

    rm -f "$SYSCTL_FILE"
    sysctl --system &>/dev/null || true

    state_save_step "sysctl_network" "REMOVED"
    state_save_step "sysctl_router"  "REMOVED"
    log_ok "sysctl settings reverted"
}

# Interactive uninstall menu
run_uninstall() {
    log_step "UNINSTALL MODE"

    # Load state to show what's installed
    state_load

    echo ""
    echo -e "  ${BOLD}${RED}Uninstall — select components to remove:${RESET}"
    echo ""

    # Build list of installed components from state
    local components=()
    local labels=()

    for step in haproxy haproxy_gate monitoring fail2ban ufw remnanode selfsteal mobile443 docker sysctl_network; do
        local st="${_STATE[$step]:-unknown}"
        if [[ "$st" == "OK" || "$st" == "SKIPPED(resume)" ]]; then
            components+=("$step")
            labels+=("${step}  [installed]")
        elif [[ "$st" == "REMOVED" ]]; then
            : # skip already removed
        else
            components+=("$step")
            labels+=("${step}  [status: ${st}]")
        fi
    done

    if [[ ${#components[@]} -eq 0 ]]; then
        log_warn "No installed components found in state file"
        log_info "You can still uninstall manually by selecting components below"
        components=(haproxy haproxy_gate monitoring fail2ban ufw remnanode selfsteal mobile443 docker sysctl_network)
        for c in "${components[@]}"; do labels+=("$c"); done
    fi

    echo -e "  ${YELLOW}0)${RESET} ALL components (full wipe)"
    local i=1
    for label in "${labels[@]}"; do
        echo -e "  ${YELLOW}${i})${RESET} ${label}"
        ((i++))
    done
    echo -e "  ${RED}q)${RESET} Cancel"
    echo ""

    local choice
    if [[ "$NON_INTERACTIVE" == true ]]; then
        log_error "--uninstall requires interactive mode or explicit --mode with component flags"
        exit 1
    fi

    read -rp "  Your choice: " choice

    case "$choice" in
        q|Q) log_info "Uninstall cancelled"; return 0 ;;
        0)
            log_warn "Full wipe selected — removing ALL components"
            read -rp "  Are you sure? This cannot be undone. [yes/N]: " confirm
            [[ "${confirm,,}" != "yes" ]] && { log_info "Cancelled"; return 0; }
            uninstall_monitoring
            uninstall_haproxy
            uninstall_remnanode
            uninstall_selfsteal
            uninstall_mobile443
            uninstall_fail2ban
            uninstall_ufw
            uninstall_sysctl
            rm -f "$STATE_FILE" "$CONFIG_FILE"
            log_ok "Full uninstall complete"
            ;;
        *)
            local idx=$(( choice - 1 ))
            if [[ $idx -ge 0 && $idx -lt ${#components[@]} ]]; then
                local target="${components[$idx]}"
                log_info "Uninstalling: ${target}"
                case "$target" in
                    haproxy)       uninstall_haproxy    ;;
                    haproxy_gate)  uninstall_haproxy    ;;
                    monitoring)    uninstall_monitoring ;;
                    fail2ban)      uninstall_fail2ban   ;;
                    ufw)           uninstall_ufw        ;;
                    remnanode)     uninstall_remnanode  ;;
                    selfsteal)     uninstall_selfsteal  ;;
                    mobile443)     uninstall_mobile443  ;;
                    docker)        uninstall_docker     ;;
                    sysctl_network|sysctl_router) uninstall_sysctl ;;
                    *) log_error "Unknown component: ${target}" ;;
                esac
            else
                log_warn "Invalid choice: ${choice}"
            fi
            ;;
    esac
}



run_base() {
    log_step "MODE: BASE"
    apt_update
    run_step "base_packages"   setup_base_packages
    run_step "timezone"        setup_timezone
    run_step "ssh"             setup_ssh
    run_step "sysctl_network"  apply_sysctl_network
    run_step "swap"            setup_swap
    run_step "ufw"             setup_ufw "base"
    run_step "fail2ban"        setup_fail2ban
    STEP_STATUS["mode"]="base/OK"
}

run_node() {
    log_step "MODE: NODE"
    apt_update
    run_step "base_packages"   setup_base_packages
    run_step "timezone"        setup_timezone
    run_step "ssh"             setup_ssh
    run_step "sysctl_network"  apply_sysctl_network
    run_step "swap"            setup_swap
    run_step "ufw"             setup_ufw "node"
    run_step "fail2ban"        setup_fail2ban
    run_step "mobile443"       install_mobile443_filter "node"
    run_step "remnanode"       install_remnanode
    run_step "selfsteal"       install_selfsteal
    STEP_STATUS["mode"]="node/OK"
}

run_gate() {
    log_step "MODE: GATE"
    apt_update
    run_step "base_packages"   setup_base_packages
    run_step "timezone"        setup_timezone
    run_step "ssh"             setup_ssh
    run_step "sysctl_network"  apply_sysctl_network
    run_step "swap"            setup_swap
    run_step "ufw"             setup_ufw "gate"
    run_step "fail2ban"        setup_fail2ban
    run_step "mobile443"       install_mobile443_filter "gate"
    run_step "remnanode"       install_remnanode
    run_step "selfsteal"       install_selfsteal
    STEP_STATUS["mode"]="gate/OK"
}

run_relay() {
    log_step "MODE: Relay (NODE RELAY)"
    # Relay mode: HAProxy handles traffic filtering via blocked.lst + allowed.lst.
    # mobile443-filter is NOT used here — allowlist logic replaces it.
    # remnanode and selfsteal are NOT installed on a relay/router node.
    apt_update
    run_step "base_packages"   setup_base_packages
    run_step "timezone"        setup_timezone
    run_step "ssh"             setup_ssh
    run_step "sysctl_network"  apply_sysctl_network
    run_step "sysctl_router"   apply_sysctl_router
    run_step "swap"            setup_swap
    run_step "ufw"             setup_ufw "relay"
    run_step "fail2ban"        setup_fail2ban
    run_step "haproxy"         setup_haproxy
    STEP_STATUS["mode"]="relay/OK"
}

run_custom() {
    log_step "MODE: CUSTOM (step-by-step)"

    _ask() { local q="$1"; read -rp "  $q [Y/n]: " _ans; [[ "${_ans,,}" != "n" ]]; }

    apt_update

    _ask "Install base packages?" && setup_base_packages
    _ask "Configure timezone?"    && setup_timezone
    _ask "Harden SSH?"            && setup_ssh
    _ask "Apply network sysctl?"  && apply_sysctl_network
    _ask "Apply router sysctl (block ICMP, disable IPv6)?" && apply_sysctl_router
    _ask "Configure UFW?"         && setup_ufw "node"
    _ask "Configure Fail2Ban?"    && setup_fail2ban
    _ask "Install HAProxy (Relay mode)?" && setup_haproxy
    _ask "Install mobile443-filter?" && {
        local m
        read -rp "  Mode for mobile443-filter [node/gate/relay]: " m
        install_mobile443_filter "${m:-node}"
    }
    _ask "Install remnanode?"     && install_remnanode
    _ask "Install selfsteal?"     && { SKIP_SELFSTEAL=false; install_selfsteal; }
    _ask "Install Docker?"        && install_docker
    _ask "Create swap?"           && setup_swap
    _ask "Install monitoring stack (Prometheus + Grafana)?" && install_monitoring

    STEP_STATUS["mode"]="custom/OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 19 · INTERACTIVE MENU
# ─────────────────────────────────────────────────────────────────────────────

show_menu() {
    # Load state once for the menu session
    state_load

    while true; do
        clear
        print_header

        # Show resume hint if previous install exists
        if [[ -n "${_STATE_MODE:-}" ]]; then
            echo -e "  ${YELLOW}⚡ Previous install found: mode=${_STATE_MODE} v${_STATE_VERSION}${RESET}"
            echo -e "  ${GRAY}   Use 'r) Resume' to continue from where it stopped${RESET}"
            echo ""
        fi

        echo -e "  ${BOLD}Select mode:${RESET}"
        echo ""
        echo -e "  ${CYAN}1)${RESET} base    — Base server preparation only"
        echo -e "  ${CYAN}2)${RESET} node    — Regular node (base + remnanode + selfsteal)"
        echo -e "  ${CYAN}3)${RESET} gate    — Gate node (base + remnanode + selfsteal + block-only filter)"
        echo -e "  ${CYAN}4)${RESET} relay   — Relay/Node Relay mode (base + haproxy + mobile443 filter)"
        echo -e "  ${CYAN}5)${RESET} custom  — Step-by-step component selection"
        echo ""
        echo -e "  ${YELLOW}r)${RESET} Resume  — Continue interrupted installation"
        echo -e "  ${YELLOW}s)${RESET} Status  — Show current system status"
        echo -e "  ${YELLOW}d)${RESET} Dry run — Toggle dry-run (currently: ${DRY_RUN})"
        echo -e "  ${YELLOW}v)${RESET} Verbose — Toggle verbose (currently: ${VERBOSE})"
        echo -e "  ${RED}u)${RESET} Uninstall — Remove installed components"
        echo -e "  ${RED}q)${RESET} Quit"
        echo ""
        print_separator
        read -rp "  Your choice: " choice

        case "$choice" in
            1) MODE="base";   show_summary_confirm && run_base   ;;
            2) MODE="node";   show_summary_confirm && run_node   ;;
            3) MODE="gate";   show_summary_confirm && run_gate   ;;
            4) MODE="relay";  show_summary_confirm && run_relay  ;;
            5) MODE="custom"; run_custom ;;
            r|R)
                if [[ -z "${_STATE_MODE:-}" ]]; then
                    log_warn "No previous installation state found"
                else
                    RESUME=true
                    MODE="${_STATE_MODE}"
                    log_info "Resuming ${MODE} (v${_STATE_VERSION} → v${SCRIPT_VERSION})"
                    show_summary_confirm && case "$MODE" in
                        base)  run_base  ;;
                        node)  run_node  ;;
                        gate)  run_gate  ;;
                        relay) run_relay ;;
                        *)     log_error "Cannot resume unknown mode: ${MODE}" ;;
                    esac
                fi
                ;;
            u|U) run_uninstall; read -rp "  Press Enter to continue..." _ ;;
            s|S) check_status_all; read -rp "  Press Enter to continue..." _ ;;
            d|D) DRY_RUN=$([ "$DRY_RUN" == true ] && echo false || echo true); log_info "Dry-run: ${DRY_RUN}" ;;
            v|V) VERBOSE=$([ "$VERBOSE" == true ] && echo false || echo true); log_info "Verbose: ${VERBOSE}" ;;
            q|Q) echo -e "\n  ${GRAY}Exiting.${RESET}\n"; exit 0 ;;
            *)   log_warn "Unknown option: ${choice}" ;;
        esac

        if [[ -n "$MODE" && "$MODE" != "custom" && "$RESUME" != true ]]; then
            save_config
            print_summary
            check_status_all
            break
        fi
        # Reset RESUME flag after one cycle so menu stays usable
        RESUME=false
    done
}

show_summary_confirm() {
    echo ""
    echo -e "  ${BOLD}${YELLOW}About to run mode: ${MODE}${RESET}"
    echo -e "  ${GRAY}Log: ${LOG_FILE}${RESET}"
    echo -e "  ${GRAY}Dry-run: ${DRY_RUN} | Verbose: ${VERBOSE}${RESET}"
    echo ""
    if [[ "$NON_INTERACTIVE" == false ]]; then
        read -rp "  Proceed? [Y/n]: " ans
        [[ "${ans,,}" == "n" ]] && { log_info "Aborted by user"; return 1; }
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 20 · CLI ARGUMENT PARSER
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF

${BOLD}Usage:${RESET}
  ${SCRIPT_NAME} [OPTIONS]

${BOLD}Options:${RESET}
  --mode <mode>          Run mode: base | node | gate | relay | custom
  --gate-address <ip>    Gate IP address (required for relay mode)
  --allowed-url <url>    URL to fetch allowed.lst (raw GitHub/CDN); empty = use whois/RADB
  --resume               Resume interrupted install (skip already-OK steps)
  --uninstall            Interactive uninstall menu
  --dry-run              Simulate — no changes applied
  --verbose, -v          Enable verbose/debug output
  --skip-selfsteal       Skip selfsteal installation
  --skip-update          Skip apt update/upgrade
  --non-interactive, -y  Non-interactive mode (use defaults)
  --status               Show system status and exit
  --version              Show version and exit
  --help, -h             Show this help

${BOLD}Examples:${RESET}
  # Interactive menu
  bash ${SCRIPT_NAME}

  # Non-interactive node setup
  bash ${SCRIPT_NAME} --mode node --non-interactive

  # Relay/Node Relay mode with gate address
  bash ${SCRIPT_NAME} --mode relay --gate-address 1.2.3.4 --non-interactive

  # Relay mode with pre-built allowlist from GitHub
  bash ${SCRIPT_NAME} --mode relay --gate-address 1.2.3.4 --allowed-url https://raw.githubusercontent.com/USER/REPO/main/allowed.lst --non-interactive

  # Dry run (preview only)
  bash ${SCRIPT_NAME} --mode node --dry-run --verbose

  # Custom with verbose + no selfsteal
  bash ${SCRIPT_NAME} --mode custom --skip-selfsteal -v

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)            MODE="$2";          shift 2 ;;
            --gate-address)    GATE_ADDRESS="$2";    shift 2 ;;
            --allowed-url)     ALLOWED_LST_URL="$2"; shift 2 ;;
            --relay-address)   RELAY_ADDRESS="$2"; shift 2 ;;
            --relay-port)      RELAY_PORT="$2";    shift 2 ;;
            --gate-port)       GATE_PORT="$2";     shift 2 ;;
            --resume)          RESUME=true;          shift   ;;
            --uninstall)       UNINSTALL=true;        shift   ;;
            --verbose|-v)      VERBOSE=true;         shift   ;;
            --skip-selfsteal)  SKIP_SELFSTEAL=true;  shift   ;;
            --skip-update)     SKIP_UPDATE=true;     shift   ;;
            --non-interactive|-y) NON_INTERACTIVE=true; shift ;;
            --status)
                preflight_checks
                check_status_all
                exit 0
                ;;
            --version)
                echo "server-bootstrap ${SCRIPT_VERSION}"
                exit 0
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 21 · MAIN ENTRYPOINT
# ─────────────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    print_header
    _log_session_header
    log_info "server-bootstrap v${SCRIPT_VERSION} started (PID: $$)"
    log_info "Log: ${LOG_FILE}"

    preflight_checks

    if [[ "$DRY_RUN" == true ]]; then
        log_warn "DRY-RUN mode active — no changes will be made"
    fi

    # ── Uninstall mode ────────────────────────────────────────────────────────
    if [[ "$UNINSTALL" == true ]]; then
        state_load
        run_uninstall
        exit 0
    fi

    # ── Load existing state ───────────────────────────────────────────────────
    state_load

    # ── Version mismatch handling ─────────────────────────────────────────────
    if state_check_version; then
        echo ""
        log_warn "Installed version: ${_STATE_VERSION}  →  Current script: ${SCRIPT_VERSION}"
        echo -e "  ${YELLOW}A previous installation (v${_STATE_VERSION}) was found.${RESET}"

        show_changelog "${_STATE_VERSION}" "${SCRIPT_VERSION}"

        if [[ "$NON_INTERACTIVE" == false ]]; then
            echo -e "  ${BOLD}What would you like to do?${RESET}"
            echo ""
            echo -e "  ${CYAN}1)${RESET} Soft update   — Re-run changed components, backup configs first"
            echo -e "              Keeps existing data (remnanode volumes, SSL certs, etc.)"
            echo -e "  ${CYAN}2)${RESET} Resume        — Continue any failed steps with new version"
            echo -e "              Skips steps that already completed OK"
            echo -e "  ${CYAN}3)${RESET} Full reinstall — Clear state, run everything from scratch"
            echo -e "  ${RED}4)${RESET} Abort"
            echo ""
            read -rp "  Your choice [1/2/3/4]: " _vchoice
            case "${_vchoice}" in
                1)
                    log_info "Soft update selected — backing up configs"
                    [[ -z "$MODE" ]] && MODE="${_STATE_MODE}"
                    run_soft_update
                    save_config
                    print_summary
                    check_status_all
                    exit 0
                    ;;
                2)
                    log_info "Resume selected — skipping completed steps, re-running failed/missing"
                    local _prev_mode="${_STATE_MODE}"
                    state_reset
                    [[ -n "${_prev_mode}" && -z "$MODE" ]] && MODE="$_prev_mode"
                    RESUME=false
                    ;;
                3)
                    log_info "Full reinstall selected"
                    state_reset
                    RESUME=false
                    ;;
                *)
                    log_info "Aborted"
                    exit 0
                    ;;
            esac
        else
            # Non-interactive
            if [[ "$RESUME" == true ]]; then
                log_info "Version changed + --resume: clearing state for clean reinstall"
                state_reset
            else
                log_warn "Version mismatch (v${_STATE_VERSION} → v${SCRIPT_VERSION})."
                log_warn "Use --resume to reinstall or --uninstall to remove."
                exit 1
            fi
        fi
    elif [[ "$RESUME" == true && -n "${_STATE_MODE}" ]]; then
        # Same version, resume mode — restore MODE from state if not set
        [[ -z "$MODE" ]] && MODE="${_STATE_MODE}"
        log_info "Resuming installation (v${SCRIPT_VERSION}, mode: ${MODE})"
    fi

    # ── Non-interactive with --mode ───────────────────────────────────────────
    if [[ "$NON_INTERACTIVE" == true && -n "$MODE" ]]; then
        case "$MODE" in
            base)   run_base    ;;
            node)   run_node    ;;
            gate)   run_gate    ;;
            relay)  run_relay   ;;
            custom) run_custom  ;;
            *)
                log_error "Unknown mode: '${MODE}'. Valid: base | node | gate | relay | custom"
                exit 1
                ;;
        esac
        save_config
        print_summary
        check_status_all
        exit 0
    fi

    # ── Interactive with --mode ───────────────────────────────────────────────
    if [[ -n "$MODE" ]]; then
        case "$MODE" in
            base)   show_summary_confirm && run_base    ;;
            node)   show_summary_confirm && run_node    ;;
            gate)   show_summary_confirm && run_gate    ;;
            relay)  show_summary_confirm && run_relay   ;;
            custom) run_custom ;;
            *)
                log_error "Unknown mode: '${MODE}'"
                exit 1
                ;;
        esac
        save_config
        print_summary
        check_status_all
        exit 0
    fi

    # ── Full interactive menu ─────────────────────────────────────────────────
    show_menu
}

main "$@"

# ─────────────────────────────────────────────────────────────────────────────
# END OF SCRIPT
# ─────────────────────────────────────────────────────────────────────────────

# ==============================================================================
# USAGE EXAMPLES
# ==============================================================================
#
# ── Interactive (full menu) ───────────────────────────────────────────────────
#   sudo bash server-bootstrap.sh
#
# ── Non-interactive presets ──────────────────────────────────────────────────
#   sudo bash server-bootstrap.sh --mode base --non-interactive
#   sudo bash server-bootstrap.sh --mode node --non-interactive
#   sudo bash server-bootstrap.sh --mode gate --non-interactive --skip-selfsteal
#   sudo bash server-bootstrap.sh --mode bs   --gate-address 1.2.3.4 --non-interactive
#
# ── Dev/testing ───────────────────────────────────────────────────────────────
#   sudo bash server-bootstrap.sh --mode node --dry-run --verbose
#   sudo bash server-bootstrap.sh --status
#
# ==============================================================================
# TODO / FUTURE IMPROVEMENTS
# ==============================================================================
#
# 1.  [ ] nftables / iptables-legacy switcher
# 2.  [ ] Certificate management (acme.sh / certbot)
# 3.  [x] Uninstall/rollback functions per component — DONE in v1.0.2/v1.0.3
# 4.  [ ] Provider presets (Hetzner, Vultr, DigitalOcean network quirks)
# 5.  [ ] IPv6 dual-stack support in UFW rules
# 6.  [ ] Automatic SSH key injection (from GitHub/URL)
# 7.  [x] Monitoring stack: Prometheus + Grafana + node_exporter + haproxy_exporter — DONE in v1.0.4
# 8.  [ ] Kernel BBR2 / TCP optimization tuning for specific workloads
# 9.  [ ] GitHub Actions / CI self-test (shellcheck + bats)
# 10. [ ] Web dashboard for status (simple Flask / static HTML)
# 11. [ ] Automated update check for this script
# 12. [ ] WireGuard peer setup helpers
# 13. [ ] Rate limiting rules in UFW / nftables
# 14. [ ] remnanode update / status check helper
# 15. [ ] selfsteal update / regenerate cert helper
# ==============================================================================
