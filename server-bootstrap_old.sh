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
#  Version: 1.0.0
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 · CONSTANTS & GLOBALS
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/server-bootstrap.log"
readonly CONFIG_FILE="/etc/server-bootstrap.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-custom-network.conf"
readonly BACKUP_DIR="/var/backups/server-bootstrap"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# ── Runtime flags (set via CLI args) ─────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
NON_INTERACTIVE=false
SKIP_SELFSTEAL=false
SKIP_UPDATE=false
MODE=""         # base | node | gate | relay | custom
GATE_ADDRESS="" # used in relay mode

# ── Auto-detect pipe mode (curl URL | bash kills stdin) ───────────────────────
# If stdin is NOT a terminal, force non-interactive to protect all `read` calls.
# Correct curl usage:  bash <(curl -Ls URL) [--args]   ← stdin = tty, OK
# Broken curl usage:   curl -Ls URL | bash              ← stdin = pipe, force -y
if [[ ! -t 0 ]]; then
    NON_INTERACTIVE=true
fi

# ── State tracking for summary ────────────────────────────────────────────────
declare -A STEP_STATUS=()

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
  ║         SERVER BOOTSTRAP  ·  v1.0.0                  ║
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

# Detect current SSH port (with fallback)
_get_ssh_port() {
    local sshd_cfg="/etc/ssh/sshd_config"
    local port
    port="$(grep -E '^Port ' "$sshd_cfg" 2>/dev/null | awk '{print $2}' | head -1)"
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
        node|gate)
            ufw allow 443/tcp  comment 'HTTPS/Xray'  &>/dev/null
            ufw allow 80/tcp   comment 'HTTP'         &>/dev/null
            ufw allow 8443/tcp comment 'Alt-HTTPS'    &>/dev/null
            ;;
        relay)
            ufw allow 443/tcp  comment 'HAProxy TCP proxy' &>/dev/null
            ;;
        base|*)
            # Only SSH
            ;;
    esac

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

# Validate IPv4 address
_validate_ip() {
    local ip="$1"
    local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ ! $ip =~ $re ]]; then return 1; fi
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for o in $o1 $o2 $o3 $o4; do
        (( o <= 255 )) || return 1
    done
    return 0
}

setup_haproxy() {
    log_step "Configuring HAProxy (Relay/router mode)"
    install_packages haproxy

    # Get gate address
    if [[ -z "$GATE_ADDRESS" ]]; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            log_error "--gate-address is required in non-interactive Relay mode"
            exit 1
        fi
        while true; do
            read -rp "  Enter GATE IP address (e.g. 1.2.3.4): " GATE_ADDRESS
            if _validate_ip "$GATE_ADDRESS"; then
                break
            else
                log_warn "Invalid IP: '${GATE_ADDRESS}'. Please try again."
            fi
        done
    else
        if ! _validate_ip "$GATE_ADDRESS"; then
            log_error "Invalid GATE_ADDRESS: '${GATE_ADDRESS}'"
            exit 1
        fi
    fi

    log_info "GATE_ADDRESS: ${GATE_ADDRESS}"

    local haproxy_cfg="/etc/haproxy/haproxy.cfg"
    backup_file "$haproxy_cfg"

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would configure HAProxy → ${GATE_ADDRESS}:443 with send-proxy-v2"
        STEP_STATUS["haproxy"]="DRY"
        return 0
    fi

    cat > "$haproxy_cfg" <<EOF
global
    log /dev/log local0
    maxconn 50000
    daemon

defaults
    mode tcp
    timeout connect 5s
    timeout client  50s
    timeout server  50s
    log             global
    option          tcplog

frontend ft_xray
    bind *:443
    default_backend bk_xray

backend bk_xray
    server xray ${GATE_ADDRESS}:443 send-proxy-v2
EOF

    # Validate config before restart
    if haproxy -c -f "$haproxy_cfg" &>/dev/null; then
        systemctl enable haproxy  &>/dev/null
        systemctl restart haproxy &>/dev/null
        log_ok "HAProxy configured and started (→ ${GATE_ADDRESS}:443)"
        STEP_STATUS["haproxy"]="OK"
    else
        log_error "HAProxy config validation FAILED — reverting backup"
        if [[ -f "${BACKUP_DIR}/haproxy.cfg.${TIMESTAMP}.bak" ]]; then
            cp -a "${BACKUP_DIR}/haproxy.cfg.${TIMESTAMP}.bak" "$haproxy_cfg"
        fi
        STEP_STATUS["haproxy"]="FAILED"
        return 1
    fi
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
# SECTION 18 · MODE FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

run_base() {
    log_step "MODE: BASE"
    apt_update
    setup_base_packages
    setup_timezone
    setup_ssh
    apply_sysctl_network
    setup_swap
    setup_ufw "base"
    setup_fail2ban
    STEP_STATUS["mode"]="base/OK"
}

run_node() {
    log_step "MODE: NODE"
    apt_update
    setup_base_packages
    setup_timezone
    setup_ssh
    apply_sysctl_network
    setup_swap
    setup_ufw "node"
    setup_fail2ban
    install_mobile443_filter "node"
    install_remnanode
    install_selfsteal
    STEP_STATUS["mode"]="node/OK"
}

run_gate() {
    log_step "MODE: GATE"
    apt_update
    setup_base_packages
    setup_timezone
    setup_ssh
    apply_sysctl_network
    setup_swap
    setup_ufw "gate"
    setup_fail2ban
    install_mobile443_filter "gate"
    install_remnanode
    install_selfsteal
    STEP_STATUS["mode"]="gate/OK"
}

run_relay() {
    log_step "MODE: Relay (NODE RELAY)"
    apt_update
    setup_base_packages
    setup_timezone
    setup_ssh
    apply_sysctl_network
    apply_sysctl_router
    setup_swap
    setup_ufw "relay"
    setup_fail2ban
    setup_haproxy
    install_mobile443_filter "relay"
    # No remnanode, no selfsteal by default
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

    STEP_STATUS["mode"]="custom/OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 19 · INTERACTIVE MENU
# ─────────────────────────────────────────────────────────────────────────────

show_menu() {
    while true; do
        clear
        print_header
        echo -e "  ${BOLD}Select mode:${RESET}"
        echo ""
        echo -e "  ${CYAN}1)${RESET} base    — Base server preparation only"
        echo -e "  ${CYAN}2)${RESET} node    — Regular node (base + remnanode + selfsteal)"
        echo -e "  ${CYAN}3)${RESET} gate    — Gate node (base + remnanode + selfsteal + block-only filter)"
        echo -e "  ${CYAN}4)${RESET} relay   — Relay/Node Relay mode (base + haproxy + mobile443 filter)"
        echo -e "  ${CYAN}5)${RESET} custom  — Step-by-step component selection"
        echo ""
        echo -e "  ${YELLOW}s)${RESET} Status  — Show current system status"
        echo -e "  ${YELLOW}d)${RESET} Dry run — Toggle dry-run (currently: ${DRY_RUN})"
        echo -e "  ${YELLOW}v)${RESET} Verbose — Toggle verbose (currently: ${VERBOSE})"
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
            s|S) check_status_all; read -rp "  Press Enter to continue..." _ ;;
            d|D) DRY_RUN=$([ "$DRY_RUN" == true ] && echo false || echo true); log_info "Dry-run: ${DRY_RUN}" ;;
            v|V) VERBOSE=$([ "$VERBOSE" == true ] && echo false || echo true); log_info "Verbose: ${VERBOSE}" ;;
            q|Q) echo -e "\n  ${GRAY}Exiting.${RESET}\n"; exit 0 ;;
            *)   log_warn "Unknown option: ${choice}" ;;
        esac

        if [[ -n "$MODE" && "$MODE" != "custom" ]]; then
            save_config
            print_summary
            check_status_all
            break
        fi
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
            --gate-address)    GATE_ADDRESS="$2";  shift 2 ;;
            --dry-run)         DRY_RUN=true;        shift   ;;
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
    log_info "server-bootstrap v${SCRIPT_VERSION} started (PID: $$)"
    log_info "Log: ${LOG_FILE}"

    preflight_checks

    if [[ "$DRY_RUN" == true ]]; then
        log_warn "DRY-RUN mode active — no changes will be made"
    fi

    # Non-interactive with --mode
    if [[ "$NON_INTERACTIVE" == true && -n "$MODE" ]]; then
        case "$MODE" in
            base)   run_base   ;;
            node)   run_node   ;;
            gate)   run_gate   ;;
            relay)  run_relay  ;;
            custom) run_custom ;;
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

    # Interactive with --mode (ask for confirm)
    if [[ -n "$MODE" ]]; then
        case "$MODE" in
            base)   show_summary_confirm && run_base   ;;
            node)   show_summary_confirm && run_node   ;;
            gate)   show_summary_confirm && run_gate   ;;
            relay)  show_summary_confirm && run_relay  ;;
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

    # Full interactive menu
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
#   sudo bash server-bootstrap.sh --mode relay --gate-address 1.2.3.4 --non-interactive
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
# 3.  [ ] Uninstall/rollback functions per component
#           (haproxy remove, fail2ban purge, etc.)
# 4.  [ ] Provider presets (Hetzner, Vultr, DigitalOcean network quirks)
# 5.  [ ] IPv6 dual-stack support in UFW rules
# 6.  [ ] Automatic SSH key injection (from GitHub/URL)
# 7.  [ ] Monitoring stack: Prometheus node-exporter + Grafana Alloy
# 8.  [ ] Kernel BBR2 / TCP optimization tuning for specific workloads
# 9.  [ ] GitHub Actions / CI self-test (shellcheck + bats)
# 10. [ ] Web dashboard for status (simple Flask / static HTML)
# 11. [ ] Automated update check for this script
# 12. [ ] WireGuard peer setup helpers
# 13. [ ] Rate limiting rules in UFW / nftables
# 14. [ ] remnanode update / status check helper
# 15. [ ] selfsteal update / regenerate cert helper
# ==============================================================================
