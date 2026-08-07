#!/usr/bin/env bash
#
# Complete OS Anti-Filtering & DPI Defense Script (Ultra Edition)
# Author Telegram : @ScriptingGs
# GitHub          : https://github.com/samanamwowo/
#
# Supported distros: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
#
set -uo pipefail
trap 'log_err "Script interrupted."; exit 130' INT TERM

# ============================================================
#  Colors / Style
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

SYSCTL_FILE="/etc/sysctl.d/99-antidpi-ultimate.conf"
SYSCTL_FILE_LEGACY_1="/etc/sysctl.d/99-antidpi.conf"
SYSCTL_FILE_LEGACY_2="/etc/sysctl.d/99-antidpi-ultra.conf"
NIC_SERVICE="/etc/systemd/system/antidpi-nic.service"
NOISE_SERVICE="/etc/systemd/system/antidpi-noise.service"
NOISE_SCRIPT="/usr/local/bin/noise-gen.sh"
GLOBAL_CMD_A="/usr/local/bin/anti-dpi"
GLOBAL_CMD_B="/usr/bin/anti-dpi"
SELF_PATH="$(readlink -f "$0")"
STATE_DIR="/etc/antidpi"
STATE_IFACE_FILE="${STATE_DIR}/iface"
STATE_TTL_FILE="${STATE_DIR}/ttl_value"
UPDATE_URL="https://raw.githubusercontent.com/samanamwowo/os-network-optimizer-Anti-DPI/refs/heads/main/optimize.sh"

log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()   { echo -e "${RED}[FAIL]${NC}  $1"; }
log_step()  { echo -e "${MAGENTA}[STEP]${NC} ${BOLD}$1${NC}"; }

# ============================================================
#  Safe iptables rule removal (no eval - parses into an array instead)
# ============================================================
# Usage: safe_iptables_delete <table> <chain> <grep-pattern> [binary]
# Finds every rule in <table>/<chain> matching <grep-pattern>, converts each
# "-A <chain> ..." line into a real argv array, and deletes it with -D.
# This avoids eval'ing a shell string built from command output.
# [binary] defaults to "iptables"; pass "ip6tables" to operate on IPv6 rules.
safe_iptables_delete() {
    local table="$1" chain="$2" pattern="$3" binary="${4:-iptables}"
    local rule_line
    while IFS= read -r rule_line; do
        [[ -z "$rule_line" ]] && continue
        local rest="${rule_line#-A "$chain" }"
        local -a args=()
        read -ra args <<< "$rest"
        "$binary" -t "$table" -D "$chain" "${args[@]}" 2>/dev/null
    done < <("$binary" -t "$table" -S "$chain" 2>/dev/null | grep -- "$pattern")
}

# ============================================================
#  Wait for a concurrent apt/dpkg process to finish (avoids silent
#  install failures if unattended-upgrades or another apt run is active)
# ============================================================
wait_for_apt_lock() {
    # Prefer fuser; fall back to lsof; fall back to a simple flock test-lock
    # if neither exists, so this still does something useful everywhere.
    if command -v fuser >/dev/null 2>&1; then
        check_locked() { fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; }
    elif command -v lsof >/dev/null 2>&1; then
        check_locked() { lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || lsof /var/lib/apt/lists/lock >/dev/null 2>&1; }
    elif command -v flock >/dev/null 2>&1; then
        check_locked() { ! flock -n -x -w 0 /var/lib/dpkg/lock-frontend true 2>/dev/null; }
    else
        log_info "Neither fuser, lsof, nor flock is available - skipping apt lock check (proceeding directly)."
        return 0
    fi

    local waited=0
    local max_wait=60
    while check_locked; do
        if [[ "$waited" -eq 0 ]]; then
            log_info "Another apt/dpkg process is running - waiting for it to finish..."
        fi
        sleep 3
        waited=$((waited + 3))
        if [[ "$waited" -ge "$max_wait" ]]; then
            log_warn "apt/dpkg still locked after ${max_wait}s - proceeding anyway, install may fail."
            break
        fi
    done
}

# ============================================================
#  Persist current iptables/ip6tables rules across reboots.
#  Installs iptables-persistent on first use (asks debconf non-interactively
#  to not overwrite with a blank ruleset), then saves.
# ============================================================
persist_iptables_rules() {
    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        wait_for_apt_lock
        apt-get update -qq >/dev/null 2>&1
        if command -v debconf-set-selections >/dev/null 2>&1; then
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null
        else
            log_info "debconf-set-selections not found - relying on DEBIAN_FRONTEND=noninteractive alone (may still prompt on very minimal systems)."
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
        log_ok "iptables/ip6tables rules saved - will survive a reboot"
    else
        log_warn "Could not install iptables-persistent - rules were applied but will NOT survive a reboot. Install 'iptables-persistent' manually to fix this."
    fi
}

# ============================================================
#  Banner
# ============================================================
print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
   ___          __  _        ____  ____ ____   __  __ __
  /   |  ____  / /_(_)      / __ \/ __ \  _/  / / / // /_______
 / /| | / __ \/ __/ /______/ / / / /_/ /_ \  / / / // //_/ __ \
/ ___ |/ / / / /_/ /_____/ /_/ / ____/__/ / / /_/ / / // /_/ /
/_/  |_/_/ /_/\__/_/      \____/_/   /____/  \____/_//_/\__,_/
             Ultra Edition - DPI Defense Toolkit
EOF
    echo -e "${NC}"
    echo -e "${BOLD}  Project   :${NC} Complete OS Anti-Filtering & DPI Defeater (Ultra Edition)"
    echo -e "${BOLD}  Telegram  :${NC} ${GREEN}@ScriptingGs${NC}"
    echo -e "${BOLD}  GitHub    :${NC} ${GREEN}https://github.com/samanamwowo/${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
}

# ============================================================
#  Root check
# ============================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "This script must be run as root. Try: sudo bash $0"
        exit 1
    fi
}

# ============================================================
#  Warn (non-fatally) if not running on a supported distro
# ============================================================
check_distro() {
    if [[ ! -f /etc/os-release ]]; then
        log_warn "Could not detect the OS distribution (/etc/os-release missing). This script targets Ubuntu/Debian and uses apt-get - it will likely fail on other distros."
        return 0
    fi

    local distro_id
    distro_id=$(. /etc/os-release && echo "$ID")

    case "$distro_id" in
        ubuntu|debian) : ;;
        *)
            log_warn "Detected distro: '$distro_id'. This script is built and tested for Ubuntu/Debian only (it relies on apt-get, iptables-persistent, etc)."
            log_warn "It may partially work or fail outright on other distros (RHEL/CentOS/Arch/etc). Proceed at your own risk."
            ;;
    esac
}

# ============================================================
#  Detect primary network interface
# ============================================================
detect_iface() {
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)
    if [[ -z "$iface" ]]; then
        iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
    fi
    if [[ -z "$iface" ]]; then
        log_err "Could not auto-detect the primary network interface."
        exit 1
    fi
    mkdir -p "$STATE_DIR"
    echo "$iface" > "$STATE_IFACE_FILE"
    echo "$iface"
}

get_tracked_iface() {
    if [[ -f "$STATE_IFACE_FILE" ]]; then
        cat "$STATE_IFACE_FILE"
    else
        detect_iface
    fi
}

# ============================================================
#  Detect CPU / RAM and scale buffer sizing
# ============================================================
CPU_CORES=1
RAM_MB=1024
RMEM_MAX=16777216
WMEM_MAX=16777216

detect_resources() {
    log_step "Detecting system resources..."
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    [[ -z "$RAM_MB" ]] && RAM_MB=1024

    if   [[ "$RAM_MB" -ge 8192 ]]; then RMEM_MAX=134217728; WMEM_MAX=134217728
    elif [[ "$RAM_MB" -ge 4096 ]]; then RMEM_MAX=67108864;  WMEM_MAX=67108864
    elif [[ "$RAM_MB" -ge 2048 ]]; then RMEM_MAX=33554432;  WMEM_MAX=33554432
    else                                RMEM_MAX=16777216;  WMEM_MAX=16777216
    fi

    log_info "CPU cores: ${CPU_CORES} | RAM: ${RAM_MB}MB | TCP buffer max: $((RMEM_MAX / 1024 / 1024))MB"
}

# ============================================================
#  Snapshot current state before making changes (manual-rollback aid)
# ============================================================
backup_current_state() {
    mkdir -p "${STATE_DIR}/backups"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local sysctl_bak="${STATE_DIR}/backups/sysctl-${ts}.txt"
    local iptables_bak="${STATE_DIR}/backups/iptables-${ts}.rules"

    sysctl -a > "$sysctl_bak" 2>/dev/null
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$iptables_bak" 2>/dev/null
    fi

    # Keep only the 5 most recent snapshots of each type to avoid unbounded growth
    ls -1t "${STATE_DIR}"/backups/sysctl-*.txt 2>/dev/null | tail -n +6 | xargs -r rm -f
    ls -1t "${STATE_DIR}"/backups/iptables-*.rules 2>/dev/null | tail -n +6 | xargs -r rm -f

    log_info "Pre-change snapshot saved: $sysctl_bak"
    log_info "                           $iptables_bak"
    log_info "(for manual reference/diffing only - use option 5 'Uninstall' for a guaranteed clean revert)"
}

# ============================================================
#  Install self as global command
# ============================================================
install_global_command() {
    log_step "Installing global command 'anti-dpi'..."
    local target="$GLOBAL_CMD_A"
    mkdir -p "$(dirname "$target")" 2>/dev/null || target="$GLOBAL_CMD_B"

    if [[ "$SELF_PATH" != "$target" ]]; then
        cp -f "$SELF_PATH" "$target"
        chmod +x "$target"
    else
        chmod +x "$target"
    fi

    if command -v anti-dpi >/dev/null 2>&1; then
        log_ok "You can now run this tool anywhere by typing: anti-dpi"
    else
        log_warn "Installed to $target but it is not yet on PATH in this shell. Try opening a new terminal."
    fi
}

# ============================================================
#  Core kernel hardening (menu option 1)
# ============================================================
apply_kernel_tweaks() {
    log_step "Applying kernel network stack tweaks..."
    mkdir -p "$(dirname "$SYSCTL_FILE")"

    [[ -f "$SYSCTL_FILE_LEGACY_1" ]] && rm -f "$SYSCTL_FILE_LEGACY_1"
    [[ -f "$SYSCTL_FILE_LEGACY_2" ]] && rm -f "$SYSCTL_FILE_LEGACY_2"

    cat > "$SYSCTL_FILE" << SYSCTL_EOF
# Generated by Complete OS Anti-Filtering Optimization Script (Ultra Edition)
# Do not edit manually - regenerate via 'anti-dpi'
# Buffers below are scaled for this host: ${CPU_CORES} core(s), ${RAM_MB}MB RAM

# --- BBR + fq for better throughput / congestion behaviour ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Reduce OS/network fingerprinting surface ---
net.ipv4.ip_default_ttl = 128
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# --- TCP Fast Open ---
net.ipv4.tcp_fastopen = 3

# --- High concurrency connection handling ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000

# --- Buffer / receive window tuning (scaled to host resources) ---
net.ipv4.tcp_rmem = 4096 87380 ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${WMEM_MAX}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 2

# --- Keepalive tuning (detect dead peers faster without being aggressive) ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# --- RFC1337 + dynamic address handling ---
net.ipv4.tcp_rfc1337 = 1
net.ipv4.ip_dynaddr = 1
SYSCTL_EOF

    if [[ "${DISABLE_TIMESTAMPS:-no}" == "yes" ]]; then
        cat >> "$SYSCTL_FILE" << 'TS_EOF'

# --- TCP timestamps disabled by user choice ---
# Reduces one fingerprinting/uptime-disclosure vector, but on very high-speed
# links (>1Gbps) it removes PAWS (Protection Against Wrapped Sequence numbers)
# protection. Only disable this if you understand that tradeoff.
net.ipv4.tcp_timestamps = 0
TS_EOF
        log_info "TCP timestamps: disabled (user opted in)"
    else
        cat >> "$SYSCTL_FILE" << 'TS_EOF'

# --- TCP timestamps left at kernel default (enabled) ---
# Disabling them removes a minor fingerprinting vector but can affect PAWS
# protection on very high-speed links. Left on by default; re-run this option
# and opt in if you specifically want them off.
net.ipv4.tcp_timestamps = 1
TS_EOF
    fi

    if [[ "${DISABLE_IPV6:-no}" == "yes" ]]; then
        cat >> "$SYSCTL_FILE" << 'V6_EOF'

# --- IPv6 disabled by user choice ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
V6_EOF
        log_info "IPv6: disabled (user opted in)"
    fi

    if sysctl --system >/tmp/antidpi_sysctl.log 2>&1; then
        log_ok "sysctl parameters applied ($SYSCTL_FILE)"
    else
        log_warn "sysctl --system reported issues; see /tmp/antidpi_sysctl.log (some parameters may be unavailable in a container - non-fatal)"
    fi

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$current_cc" == "bbr" ]]; then
        log_ok "BBR congestion control is active"
    else
        log_warn "BBR not active (current: $current_cc) - checking module availability and attempting to load tcp_bbr"
        if ! modinfo tcp_bbr >/dev/null 2>&1 && [[ ! -f /proc/config.gz ]]; then
            log_warn "tcp_bbr module not found for this kernel ($(uname -r)) - BBR may not be supported here. Falling back to whatever the kernel default is."
        fi
        modprobe tcp_bbr 2>/dev/null && sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
        if [[ "$current_cc" == "bbr" ]]; then
            log_ok "BBR successfully activated"
        else
            log_warn "Could not activate BBR on this kernel - continuing with '$current_cc' instead (non-fatal)"
        fi
    fi
}

# ============================================================
#  IRQ balancing across CPU cores (single-core aware)
# ============================================================
apply_irq_balancing() {
    log_step "Configuring IRQ balancing..."

    if [[ "${CPU_CORES:-1}" -le 1 ]]; then
        log_info "Single CPU core detected - irqbalance provides no benefit on single-core hosts and will refuse to run. Skipping (this is expected, not an error)."
        systemctl disable irqbalance >/dev/null 2>&1
        systemctl stop irqbalance >/dev/null 2>&1
        return 0
    fi

    if ! command -v irqbalance >/dev/null 2>&1; then
        wait_for_apt_lock
        apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y irqbalance >/dev/null 2>&1
    fi

    systemctl enable irqbalance >/dev/null 2>&1
    systemctl restart irqbalance >/dev/null 2>&1
    sleep 1

    if systemctl is-active irqbalance >/dev/null 2>&1; then
        log_ok "irqbalance is installed, enabled, and running (${CPU_CORES} cores)"
    else
        if journalctl -u irqbalance --no-pager -n 20 2>/dev/null | grep -qi "single cpu"; then
            log_info "irqbalance exited: the hypervisor only exposes a single effective IRQ CPU on this VM. This is normal for some KVM/OpenVZ guests and is safe to ignore."
        else
            log_warn "irqbalance could not be started - check 'systemctl status irqbalance'"
        fi
    fi
}

# ============================================================
#  Extra security sysctl module (separate file - fully optional/removable)
# ============================================================
EXTRA_SYSCTL_FILE="/etc/sysctl.d/99-antidpi-extra.conf"

apply_extra_hardening() {
    log_step "Applying extra security/performance sysctl module..."

    cat > "$EXTRA_SYSCTL_FILE" << 'EXTRA_EOF'
# Generated by Complete OS Anti-Filtering Optimization Script (Ultra Edition)
# Fully separate, optional module - safe to delete this single file to revert
# just these settings without touching the core module.

# --- Reverse-path filtering: reject packets whose source address couldn't
# --- have reached us via the interface they arrived on (basic anti-spoofing) ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# --- Log "martian" packets (impossible/spoofed source addresses) for later review ---
net.ipv4.conf.all.log_martians = 1

# --- Don't reset the congestion window after an idle period; keeps a proxy
# --- connection's throughput consistent instead of restarting slow-start
# --- every time it goes quiet and resumes (typical of interactive proxy use) ---
net.ipv4.tcp_slow_start_after_idle = 0

# --- Let the kernel actively probe for a working MTU instead of relying
# --- purely on ICMP (helps on paths that silently drop ICMP) ---
net.ipv4.tcp_mtu_probing = 1
EXTRA_EOF

    if sysctl --system >/tmp/antidpi_sysctl_extra.log 2>&1; then
        log_ok "Extra hardening applied ($EXTRA_SYSCTL_FILE)"
    else
        log_warn "sysctl --system reported issues for the extra module; see /tmp/antidpi_sysctl_extra.log (non-fatal)"
    fi
}

# ============================================================
#  IPv6 mirror module for MSS/TTL rules (separate, optional/removable)
# ============================================================
STATE_IPV6_MIRROR_FILE="${STATE_DIR}/ipv6_mirror_enabled"

apply_ipv6_mirror() {
    local mss_value="${1:-1360}"
    log_step "Mirroring MSS clamping to IPv6 (ip6tables)..."

    if [[ "${DISABLE_IPV6:-no}" == "yes" ]]; then
        log_info "IPv6 is disabled on this host - skipping IPv6 rule mirroring (nothing to do)."
        return 0
    fi

    if ! command -v ip6tables >/dev/null 2>&1; then
        log_info "Installing ip6tables support..."
        wait_for_apt_lock
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y iptables >/dev/null 2>&1
    fi

    if ! command -v ip6tables >/dev/null 2>&1; then
        log_warn "ip6tables not available on this system - IPv6 traffic will NOT receive the MSS clamp. Skipping (non-fatal)."
        return 1
    fi

    safe_iptables_delete "filter" "FORWARD" "-j TCPMSS" "ip6tables"
    safe_iptables_delete "filter" "OUTPUT" "-j TCPMSS" "ip6tables"

    ip6tables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_value"
    ip6tables -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_value"

    mkdir -p "$STATE_DIR"
    touch "$STATE_IPV6_MIRROR_FILE"
    log_ok "IPv6 MSS clamping mirrored (${mss_value} bytes) - IPv4-only rules were previously a gap"
}

run_kernel_hardening() {
    check_root
    log_step "Starting core kernel hardening..."
    detect_iface >/dev/null
    detect_resources
    backup_current_state
    echo

    DISABLE_TIMESTAMPS="no"
    read -rp "$(echo -e "${YELLOW}Disable TCP timestamps? Minor fingerprint reduction, but can affect PAWS protection on links above ~1Gbps. [y/N]: ${NC}")" ts_choice
    [[ "$ts_choice" =~ ^[Yy]$ ]] && DISABLE_TIMESTAMPS="yes"

    DISABLE_IPV6="no"
    read -rp "$(echo -e "${YELLOW}Disable IPv6 entirely on this host? [y/N]: ${NC}")" v6_choice
    [[ "$v6_choice" =~ ^[Yy]$ ]] && DISABLE_IPV6="yes"

    APPLY_EXTRA_HARDENING="no"
    read -rp "$(echo -e "${YELLOW}Apply the extra hardening module too (anti-spoofing rp_filter, martian logging, idle-restart tuning)? Separate file, safe to skip. [Y/n]: ${NC}")" extra_choice
    [[ ! "$extra_choice" =~ ^[Nn]$ ]] && APPLY_EXTRA_HARDENING="yes"
    echo

    install_global_command
    echo
    apply_kernel_tweaks
    echo
    apply_irq_balancing
    echo
    if [[ "$APPLY_EXTRA_HARDENING" == "yes" ]]; then
        apply_extra_hardening
        echo
    fi
    log_ok "Core kernel hardening applied successfully."
}

# ============================================================
#  L3/L4 network manipulation (menu option 2)
# ============================================================
apply_nic_tuning() {
    local iface="$1"
    log_step "Tuning NIC offload settings on interface: $iface"

    if [[ "${CPU_CORES:-0}" -gt 0 && "${CPU_CORES}" -le 2 ]]; then
        log_warn "This host has only ${CPU_CORES} CPU core(s). Disabling NIC offload (tso/gso/gro)"
        log_warn "moves packet segmentation work from the network card to the CPU, which can"
        log_warn "push a weak/shared vCPU to 100% under real traffic and cause instability."
        read -rp "$(echo -e "${YELLOW}Proceed anyway? [y/N]: ${NC}")" offload_confirm
        if [[ ! "$offload_confirm" =~ ^[Yy]$ ]]; then
            log_info "Skipping NIC offload changes on this low-core host (nothing changed)."
            return 0
        fi
    fi

    if ! command -v ethtool >/dev/null 2>&1; then
        log_info "Installing ethtool..."
        wait_for_apt_lock
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y ethtool >/dev/null 2>&1
    fi

    ethtool -K "$iface" tso off gso off gro off >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        log_ok "Offloading (tso/gso/gro) disabled on $iface"
    else
        log_warn "Some offload features may not be supported on $iface (non-fatal, common on virtio NICs)"
    fi

    log_info "Creating persistence service: antidpi-nic.service"
    cat > "$NIC_SERVICE" << EOF
[Unit]
Description=Anti-DPI NIC offload persistence
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -K ${iface} tso off gso off gro off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable antidpi-nic.service >/dev/null 2>&1
    systemctl restart antidpi-nic.service >/dev/null 2>&1
    log_ok "antidpi-nic.service enabled and started"
}

apply_mss_clamp() {
    local mss_value="${1:-1360}"
    log_step "Applying TCP MSS clamping (target: ${mss_value} bytes)..."

    if ! command -v iptables >/dev/null 2>&1; then
        wait_for_apt_lock
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y iptables >/dev/null 2>&1
    fi

    # Remove any MSS clamp this script previously added, in case the value changed
    safe_iptables_delete "filter" "FORWARD" "-j TCPMSS"
    safe_iptables_delete "filter" "OUTPUT" "-j TCPMSS"

    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_value"
    iptables -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_value"

    log_ok "MSS clamped to ${mss_value} bytes on FORWARD/OUTPUT chains"
}

apply_ttl_randomization() {
    log_step "Applying TTL fingerprint randomization..."

    modprobe xt_TTL >/dev/null 2>&1

    # Always remove any previous TTL rule from this script first, so a
    # re-run actually rotates the value instead of silently keeping the old one.
    safe_iptables_delete "mangle" "OUTPUT" "-j TTL"

    local rand_ttl=$(( (RANDOM % 4) + 125 ))

    if iptables -t mangle -A OUTPUT -j TTL --ttl-set "$rand_ttl" 2>/tmp/antidpi_ttl.log; then
        mkdir -p "$STATE_DIR"
        echo "$rand_ttl" > "$STATE_TTL_FILE"
        log_ok "Outbound TTL set to $rand_ttl (mangle/OUTPUT) - rotated from any previous value"
    else
        log_warn "Could not apply TTL target (xt_TTL module unavailable on this kernel - common on some minimal/container kernels). Skipping, non-fatal."
    fi
}

apply_traffic_shaping() {
    local iface="$1"
    local target_port="${2:-443}"
    log_step "Applying traffic shaping (jitter) on interface: $iface, port: $target_port"

    if ! command -v tc >/dev/null 2>&1; then
        wait_for_apt_lock
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y iproute2 >/dev/null 2>&1
    fi

    tc qdisc del dev "$iface" root >/dev/null 2>&1

    local step_ok=1

    if ! tc qdisc add dev "$iface" root handle 1: prio 2>/tmp/antidpi_tc.log; then
        log_warn "tc: failed to add root qdisc on $iface; see /tmp/antidpi_tc.log"
        step_ok=0
    fi

    if [[ "$step_ok" -eq 1 ]] && ! tc qdisc add dev "$iface" parent 1:3 handle 30: netem delay 10ms 5ms distribution normal 2>>/tmp/antidpi_tc.log; then
        log_warn "tc: failed to add netem delay qdisc on $iface; see /tmp/antidpi_tc.log"
        step_ok=0
    fi

    if [[ "$step_ok" -eq 1 ]] && ! tc filter add dev "$iface" protocol ip parent 1:0 prio 3 u32 \
        match ip sport "$target_port" 0xffff flowid 1:3 2>>/tmp/antidpi_tc.log; then
        log_warn "tc: failed to add the port filter on $iface; see /tmp/antidpi_tc.log"
        step_ok=0
    fi

    if [[ "$step_ok" -eq 1 ]]; then
        log_ok "Jitter (10ms +/- 5ms, normal distribution) applied to port ${target_port} traffic on $iface"
    else
        log_warn "Traffic shaping setup incomplete (non-fatal) - check 'tc qdisc show dev $iface' and /tmp/antidpi_tc.log"
    fi
}

run_l3l4_manipulation() {
    check_root
    log_step "Starting L3/L4 network manipulation..."
    local iface
    iface=$(get_tracked_iface)
    detect_resources
    backup_current_state
    log_info "Using interface: $iface"
    echo

    local proxy_port
    read -rp "$(echo -e "${YELLOW}Which port does your proxy/service actually run on? (the jitter targets this port) [443]: ${NC}")" proxy_port
    proxy_port="${proxy_port:-443}"
    if ! [[ "$proxy_port" =~ ^[0-9]+$ ]] || [[ "$proxy_port" -lt 1 || "$proxy_port" -gt 65535 ]]; then
        log_warn "Invalid port '$proxy_port' - falling back to 443."
        proxy_port=443
    fi

    local mss_value
    read -rp "$(echo -e "${YELLOW}MSS clamp value in bytes (536-1460, lower = more fragmentation/overhead) [1360]: ${NC}")" mss_value
    mss_value="${mss_value:-1360}"
    if ! [[ "$mss_value" =~ ^[0-9]+$ ]] || [[ "$mss_value" -lt 536 || "$mss_value" -gt 1460 ]]; then
        log_warn "Invalid MSS '$mss_value' - falling back to 1360."
        mss_value=1360
    fi

    local mirror_v6="no"
    read -rp "$(echo -e "${YELLOW}Also mirror the MSS clamp to IPv6 (ip6tables)? Skipping this leaves IPv6 traffic untouched. [Y/n]: ${NC}")" v6_mirror_choice
    [[ ! "$v6_mirror_choice" =~ ^[Nn]$ ]] && mirror_v6="yes"
    echo

    apply_nic_tuning "$iface"
    echo
    apply_mss_clamp "$mss_value"
    echo
    if [[ "$mirror_v6" == "yes" ]]; then
        apply_ipv6_mirror "$mss_value"
        echo
    fi
    apply_ttl_randomization
    echo
    apply_traffic_shaping "$iface" "$proxy_port"
    echo
    log_step "Persisting firewall rules across reboots..."
    persist_iptables_rules
    echo
    log_ok "L3/L4 network manipulation applied successfully."
}

# ============================================================
#  Background noise generator (menu option 3)
# ============================================================
deploy_noise_generator() {
    check_root
    log_warn "Honest disclosure before you enable this:"
    log_warn "This traffic goes out as ordinary, separate connections from this host -"
    log_warn "it is NOT injected into your proxy tunnel and does not disguise or pad"
    log_warn "your tunnel's traffic in any way. A filterer analyzing your proxy's"
    log_warn "connection sees it independently of this. The only thing this does is"
    log_warn "keep the server's overall traffic graph from looking perfectly idle"
    log_warn "between periods of real use - nothing more. It also uses a small"
    log_warn "amount of bandwidth/CPU continuously."
    read -rp "$(echo -e "${YELLOW}Deploy it anyway? [y/N]: ${NC}")" noise_confirm
    if [[ ! "$noise_confirm" =~ ^[Yy]$ ]]; then
        log_info "Skipping background noise generator (nothing changed)."
        return 0
    fi
    log_step "Deploying background traffic noise generator..."

    if ! command -v curl >/dev/null 2>&1; then
        log_info "Installing curl (required by the noise generator)..."
        wait_for_apt_lock
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y curl >/dev/null 2>&1
        if ! command -v curl >/dev/null 2>&1; then
            log_err "curl could not be installed - the noise generator needs it to function. Aborting this module (nothing else changed)."
            return 1
        fi
    fi

    cat > "$NOISE_SCRIPT" << 'NOISE_EOF'
#!/usr/bin/env bash
# Anti-DPI background noise generator
# Periodically requests a rotating set of high-traffic public sites to help
# flatten peak/off-peak traffic graphs on this host. Runs as an unprivileged
# systemd service; safe to stop/disable at any time.

SITES=(
    "https://www.google.com"
    "https://www.bing.com"
    "https://www.wikipedia.org"
    "https://www.cloudflare.com"
    "https://www.microsoft.com"
    "https://www.apple.com"
    "https://github.com"
    "https://stackoverflow.com"
    "https://www.bbc.com"
    "https://www.reddit.com"
)

USER_AGENTS=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
)

while true; do
    site="${SITES[$RANDOM % ${#SITES[@]}]}"
    ua="${USER_AGENTS[$RANDOM % ${#USER_AGENTS[@]}]}"
    curl -s -o /dev/null -A "$ua" --max-time 8 "$site" 2>/dev/null
    sleep_time=$(( (RANDOM % 151) + 30 ))
    sleep "$sleep_time"
done
NOISE_EOF

    chmod +x "$NOISE_SCRIPT"
    log_ok "Noise generator script written to $NOISE_SCRIPT"

    cat > "$NOISE_SERVICE" << EOF
[Unit]
Description=Anti-DPI Background Traffic Noise Generator
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${NOISE_SCRIPT}
Restart=always
RestartSec=5
User=nobody
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable antidpi-noise.service >/dev/null 2>&1
    systemctl restart antidpi-noise.service >/dev/null 2>&1

    if systemctl is-active antidpi-noise.service >/dev/null 2>&1; then
        log_ok "antidpi-noise.service is running (requests every 30-180s to rotating public sites)"
    else
        log_warn "antidpi-noise.service failed to start - check 'systemctl status antidpi-noise.service'"
    fi
}

# ============================================================
#  Status / diagnostics (menu option 4)
# ============================================================
check_status() {
    check_root
    log_step "System & DPI Defense Status"
    echo

    echo -e "${BOLD}-- System Info --${NC}"
    if [[ -f /etc/os-release ]]; then
        log_info "OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
    fi
    log_info "Kernel: $(uname -r)"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        log_info "Virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"
    fi
    echo

    echo -e "${BOLD}-- Congestion Control --${NC}"
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unavailable")
    if [[ "$cc" == "bbr" ]]; then
        log_ok "BBR: active"
    else
        log_warn "BBR: NOT active (current: $cc)"
    fi
    echo

    echo -e "${BOLD}-- sysctl config file --${NC}"
    if [[ -f "$SYSCTL_FILE" ]]; then
        log_ok "$SYSCTL_FILE exists"
    else
        log_warn "$SYSCTL_FILE not found"
    fi
    if [[ -f "$EXTRA_SYSCTL_FILE" ]]; then
        log_ok "$EXTRA_SYSCTL_FILE exists (extra hardening module active)"
    else
        log_info "$EXTRA_SYSCTL_FILE not present (extra hardening module not applied - optional)"
    fi
    echo

    echo -e "${BOLD}-- IRQ balancing --${NC}"
    local cores
    cores=$(nproc 2>/dev/null || echo 1)
    if [[ "$cores" -le 1 ]]; then
        log_info "Single-core host - irqbalance intentionally not used"
    elif systemctl is-active irqbalance >/dev/null 2>&1; then
        log_ok "irqbalance is active (${cores} cores)"
    else
        log_warn "irqbalance is not active"
    fi
    echo

    echo -e "${BOLD}-- NIC offload / systemd service --${NC}"
    if systemctl is-enabled antidpi-nic.service >/dev/null 2>&1; then
        log_ok "antidpi-nic.service is enabled"
        systemctl is-active antidpi-nic.service >/dev/null 2>&1 && log_ok "antidpi-nic.service is active" || log_warn "antidpi-nic.service is not currently active"
    else
        log_warn "antidpi-nic.service not installed"
    fi
    if [[ -f "$STATE_IFACE_FILE" ]]; then
        local iface
        iface=$(cat "$STATE_IFACE_FILE")
        log_info "Tracked interface: $iface"
        ethtool -k "$iface" 2>/dev/null | grep -E "tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload"
    fi
    echo

    echo -e "${BOLD}-- iptables rules --${NC}"
    local current_mss
    current_mss=$(iptables -S FORWARD 2>/dev/null | sed -n 's/.*--set-mss \([0-9]\+\).*/\1/p' | head -n1)
    if [[ -n "$current_mss" ]]; then
        log_ok "MSS clamping rule present (FORWARD), value: ${current_mss} bytes"
    else
        log_warn "MSS clamping rule not found (FORWARD)"
    fi
    if [[ -f "$STATE_IPV6_MIRROR_FILE" ]] && command -v ip6tables >/dev/null 2>&1 && ip6tables -S FORWARD 2>/dev/null | grep -q "TCPMSS"; then
        log_ok "IPv6 MSS mirror rule present (FORWARD)"
    else
        log_info "IPv6 MSS mirror not applied (optional)"
    fi
    if iptables -t mangle -S OUTPUT 2>/dev/null | grep -q "TTL"; then
        local ttl_val
        ttl_val=$(cat "$STATE_TTL_FILE" 2>/dev/null || echo "unknown")
        log_ok "TTL randomization rule present (current value: $ttl_val)"
    else
        log_warn "TTL randomization rule not found"
    fi
    if command -v netfilter-persistent >/dev/null 2>&1 && [[ -f /etc/iptables/rules.v4 ]]; then
        log_ok "Rules are persisted (will survive a reboot)"
    else
        log_warn "iptables-persistent not detected - rules may NOT survive a reboot"
    fi
    echo

    echo -e "${BOLD}-- tc / traffic shaping --${NC}"
    if [[ -f "$STATE_IFACE_FILE" ]]; then
        local iface
        iface=$(cat "$STATE_IFACE_FILE")
        if tc qdisc show dev "$iface" 2>/dev/null | grep -q "netem"; then
            log_ok "Jitter shaping active on $iface"
        else
            log_warn "No jitter shaping found on $iface"
        fi
    fi
    echo

    echo -e "${BOLD}-- Background noise generator --${NC}"
    if systemctl is-active antidpi-noise.service >/dev/null 2>&1; then
        log_ok "antidpi-noise.service is running"
    else
        log_warn "antidpi-noise.service is not running"
    fi
    echo

    echo -e "${BOLD}-- Global command --${NC}"
    if command -v anti-dpi >/dev/null 2>&1; then
        log_ok "'anti-dpi' command available at: $(command -v anti-dpi)"
    else
        log_warn "'anti-dpi' global command not found on PATH"
    fi
}

# ============================================================
#  Self-update (menu option 5) — safe download, validate, replace, backup
# ============================================================
self_update() {
    check_root
    log_step "Checking for a newer version..."

    if ! command -v curl >/dev/null 2>&1; then
        wait_for_apt_lock
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y curl >/dev/null 2>&1
    fi

    local tmp_file
    tmp_file=$(mktemp /tmp/antidpi-update-XXXXXX.sh) || { log_err "Could not create a temp file. Aborting."; return 1; }

    log_info "Downloading latest version from GitHub..."
    if ! curl -fsSL "$UPDATE_URL" -o "$tmp_file"; then
        log_err "Download failed (network/DNS issue?). Nothing changed - current version kept."
        rm -f "$tmp_file"
        return 1
    fi

    if [[ ! -s "$tmp_file" ]]; then
        log_err "Downloaded file is empty. Aborting update - nothing changed."
        rm -f "$tmp_file"
        return 1
    fi

    log_info "Validating downloaded script syntax..."
    if ! bash -n "$tmp_file" 2>/tmp/antidpi_update_syntax.log; then
        log_err "Downloaded script FAILED syntax validation; see /tmp/antidpi_update_syntax.log"
        log_err "This can happen if the download was truncated or GitHub is serving a bad response."
        log_err "Nothing changed - your current, working version was NOT touched."
        rm -f "$tmp_file"
        return 1
    fi
    log_ok "Downloaded script is syntactically valid"

    local current_hash new_hash
    current_hash=$(sha256sum "$SELF_PATH" 2>/dev/null | awk '{print $1}')
    new_hash=$(sha256sum "$tmp_file" 2>/dev/null | awk '{print $1}')

    if [[ -n "$current_hash" && "$current_hash" == "$new_hash" ]]; then
        log_ok "You already have the latest version - nothing to update."
        rm -f "$tmp_file"
        return 0
    fi

    mkdir -p "${STATE_DIR}/backups"
    local backup_path="${STATE_DIR}/backups/optimize-$(date +%Y%m%d-%H%M%S).sh.bak"
    cp -f "$SELF_PATH" "$backup_path" 2>/dev/null
    ls -1t "${STATE_DIR}"/backups/optimize-*.sh.bak 2>/dev/null | tail -n +6 | xargs -r rm -f
    log_info "Current version backed up to: $backup_path"

    chmod +x "$tmp_file"

    if ! cp -f "$tmp_file" "$SELF_PATH" 2>/dev/null; then
        log_err "Could not overwrite $SELF_PATH (permissions/read-only filesystem?). Nothing changed."
        rm -f "$tmp_file"
        return 1
    fi
    chmod +x "$SELF_PATH"

    for global_path in "$GLOBAL_CMD_A" "$GLOBAL_CMD_B"; do
        if [[ -f "$global_path" ]]; then
            cp -f "$tmp_file" "$global_path" 2>/dev/null && chmod +x "$global_path"
        fi
    done

    rm -f "$tmp_file"
    log_ok "Updated successfully. Old version backed up, new version installed and validated."
    log_info "Restarting into the new version now..."
    echo
    exec "$SELF_PATH"
}

# ============================================================
#  Uninstall / rollback (menu option 6)
# ============================================================
run_uninstall() {
    check_root
    log_step "Rolling back all changes to default settings..."
    echo

    log_info "Removing sysctl configs..."
    rm -f "$SYSCTL_FILE" "$SYSCTL_FILE_LEGACY_1" "$SYSCTL_FILE_LEGACY_2" "$EXTRA_SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1
    log_ok "sysctl reset"

    log_info "Disabling irqbalance (leaving package installed)..."
    systemctl disable irqbalance >/dev/null 2>&1
    systemctl stop irqbalance >/dev/null 2>&1
    log_ok "irqbalance disabled"

    log_info "Removing NIC persistence service..."
    if [[ -f "$NIC_SERVICE" ]]; then
        systemctl stop antidpi-nic.service >/dev/null 2>&1
        systemctl disable antidpi-nic.service >/dev/null 2>&1
        rm -f "$NIC_SERVICE"
        systemctl daemon-reload
        log_ok "antidpi-nic.service removed"
    fi

    if [[ -f "$STATE_IFACE_FILE" ]]; then
        local iface
        iface=$(cat "$STATE_IFACE_FILE")
        log_info "Re-enabling offload features on $iface..."
        ethtool -K "$iface" tso on gso on gro on >/dev/null 2>&1
        log_info "Removing traffic shaping rules on $iface..."
        tc qdisc del dev "$iface" root >/dev/null 2>&1
    fi

    log_info "Removing noise generator..."
    if [[ -f "$NOISE_SERVICE" ]]; then
        systemctl stop antidpi-noise.service >/dev/null 2>&1
        systemctl disable antidpi-noise.service >/dev/null 2>&1
        rm -f "$NOISE_SERVICE"
        systemctl daemon-reload
    fi
    rm -f "$NOISE_SCRIPT"
    log_ok "Noise generator removed"

    log_info "Removing iptables rules added by this script..."
    safe_iptables_delete "filter" "FORWARD" "-j TCPMSS"
    safe_iptables_delete "filter" "OUTPUT" "-j TCPMSS"
    safe_iptables_delete "mangle" "OUTPUT" "-j TTL"
    rm -f "$STATE_TTL_FILE"

    if [[ -f "$STATE_IPV6_MIRROR_FILE" ]] && command -v ip6tables >/dev/null 2>&1; then
        safe_iptables_delete "filter" "FORWARD" "-j TCPMSS" "ip6tables"
        safe_iptables_delete "filter" "OUTPUT" "-j TCPMSS" "ip6tables"
        rm -f "$STATE_IPV6_MIRROR_FILE"
        log_ok "IPv6 MSS mirror rules removed"
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
    fi
    log_ok "iptables rules removed"

    log_info "Removing global command..."
    rm -f "$GLOBAL_CMD_A" "$GLOBAL_CMD_B" 2>/dev/null
    log_ok "'anti-dpi' global command removed"

    rm -rf "$STATE_DIR"

    echo
    echo -e "${GREEN}${BOLD}System successfully restored to factory/default network settings.${NC}"
}

# ============================================================
#  Main menu
# ============================================================
main_menu() {
    while true; do
        print_banner
        echo -e "${BOLD}Please choose an option:${NC}"
        echo -e "  ${CYAN}1)${NC} Apply Core Kernel Hardening & BBR Optimization ${GREEN}[REQUIRED]${NC}"
        echo -e "  ${CYAN}2)${NC} Apply L3/L4 Network Manipulation & MSS Splitting ${YELLOW}[RECOMMENDED]${NC}"
        echo -e "  ${CYAN}3)${NC} Deploy Background Noise Generator ${BLUE}[OPTIONAL]${NC}"
        echo -e "  ${CYAN}4)${NC} Run Comprehensive Status & Diagnostics ${YELLOW}[RECOMMENDED]${NC}"
        echo -e "  ${CYAN}5)${NC} Update to Latest Version ${MAGENTA}[SYSTEM TOOL]${NC}"
        echo -e "  ${CYAN}6)${NC} Uninstall & Restore Factory Defaults ${MAGENTA}[SYSTEM TOOL]${NC}"
        echo -e "  ${CYAN}7)${NC} Exit"
        echo -e "${BLUE}------------------------------------------------------------${NC}"
        read -rp "$(echo -e "${BOLD}Select [1-7]: ${NC}")" choice
        echo

        case "$choice" in
            1) run_kernel_hardening ;;
            2) run_l3l4_manipulation ;;
            3) deploy_noise_generator ;;
            4) check_status ;;
            5) self_update ;;
            6) run_uninstall ;;
            7) echo -e "${GREEN}Goodbye.${NC}"; exit 0 ;;
            *) log_err "Invalid option." ;;
        esac

        echo
        read -rp "Press Enter to return to the menu..." _
    done
}

# ============================================================
#  Entry point
# ============================================================
check_root
check_distro
install_global_command
echo
main_menu
