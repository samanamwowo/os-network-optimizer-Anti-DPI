#!/usr/bin/env bash
#
# Complete OS Anti-Filtering & DPI Defense Script (Ultra Edition)
# Author Telegram : @ScriptingGs
# GitHub          : https://github.com/samanamwowo/
#
# Supported distros: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
#
# CLI usage (besides the interactive menu):
#   anti-dpi status            run diagnostics
#   anti-dpi update [sha256]   update (optionally verifying an expected sha256)
#   anti-dpi uninstall         revert everything this script changed
#
set -uo pipefail

SCRIPT_VERSION="2.0.0"

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

# ------------------------------------------------------------
#  Paths / state
# ------------------------------------------------------------
SYSCTL_FILE="/etc/sysctl.d/99-antidpi-ultimate.conf"
SYSCTL_FILE_LEGACY_1="/etc/sysctl.d/99-antidpi.conf"
SYSCTL_FILE_LEGACY_2="/etc/sysctl.d/99-antidpi-ultra.conf"
EXTRA_SYSCTL_FILE="/etc/sysctl.d/99-antidpi-extra.conf"
MODULES_FILE="/etc/modules-load.d/antidpi-bbr.conf"
NIC_SERVICE="/etc/systemd/system/antidpi-nic.service"
TC_SERVICE="/etc/systemd/system/antidpi-tc.service"
NOISE_SERVICE="/etc/systemd/system/antidpi-noise.service"
NOISE_SCRIPT="/usr/local/bin/noise-gen.sh"
GLOBAL_CMD_A="/usr/local/bin/anti-dpi"
GLOBAL_CMD_B="/usr/bin/anti-dpi"

# $0 is not a real file when the script is piped / run via <(curl ...)
SELF_PATH="$(readlink -f "$0" 2>/dev/null || true)"
[[ -f "$SELF_PATH" ]] || SELF_PATH=""

STATE_DIR="/etc/antidpi"
LOG_DIR="${STATE_DIR}/logs"
STATE_IFACE_FILE="${STATE_DIR}/iface"
STATE_TTL_FILE="${STATE_DIR}/ttl_value"
STATE_CONFIG_FILE="${STATE_DIR}/config"
STATE_ORIG_SYSCTL="${STATE_DIR}/orig_sysctl"
STATE_ORIG_OFFLOAD="${STATE_DIR}/orig_offload"
STATE_IRQ_PREV="${STATE_DIR}/irqbalance_prev"
STATE_IPV6_MIRROR_FILE="${STATE_DIR}/ipv6_mirror_enabled"
STATE_TC_FILE="${STATE_DIR}/tc_jitter"
STATE_QDISC_TOUCHED="${STATE_DIR}/qdisc_touched"

# Every iptables rule created by this script carries this comment, so it can be
# found and removed without ever touching rules owned by Docker/WireGuard/ufw.
RULE_TAG="antidpi"

# Pin the update source with UPDATE_REF=<tag-or-commit> (default: main branch).
UPDATE_REF="${UPDATE_REF:-main}"
UPDATE_BASE="https://raw.githubusercontent.com/samanamwowo/os-network-optimizer-Anti-DPI"

# User choices (persisted in $STATE_CONFIG_FILE so every menu option agrees)
DISABLE_IPV6="no"
DISABLE_TIMESTAMPS="no"

# ============================================================
#  Logging - ALL logs go to stderr so that command substitution
#  ($(...)) never captures them as data.
# ============================================================
log_info()  { echo -e "${CYAN}[INFO]${NC}  $1" >&2; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1" >&2; }
log_err()   { echo -e "${RED}[FAIL]${NC}  $1" >&2; }
log_step()  { echo -e "${MAGENTA}[STEP]${NC} ${BOLD}$1${NC}" >&2; }

trap 'log_err "Script interrupted."; exit 130' INT TERM

# Yes/No prompt. Usage: ask_yn "question" y|n   (returns 0 for yes)
# Returns the default when stdin is closed (no infinite loops on EOF).
ask_yn() {
    local prompt="$1" def="${2:-n}" ans hint
    [[ "$def" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "$(echo -e "${YELLOW}${prompt} ${hint}: ${NC}")" ans || ans=""
    ans="${ans:-$def}"
    [[ "$ans" =~ ^[Yy] ]]
}

# ============================================================
#  State directory / config persistence
# ============================================================
ensure_state_dir() {
    mkdir -p "${STATE_DIR}/backups" "$LOG_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null
}

save_config() {
    ensure_state_dir
    {
        echo "DISABLE_IPV6=${DISABLE_IPV6}"
        echo "DISABLE_TIMESTAMPS=${DISABLE_TIMESTAMPS}"
    } > "$STATE_CONFIG_FILE"
}

# Parsed line by line (never sourced) so a corrupted file cannot run code.
load_config() {
    [[ -f "$STATE_CONFIG_FILE" ]] || return 0
    local k v
    while IFS='=' read -r k v; do
        [[ "$v" == "yes" || "$v" == "no" ]] || continue
        case "$k" in
            DISABLE_IPV6)       DISABLE_IPV6="$v" ;;
            DISABLE_TIMESTAMPS) DISABLE_TIMESTAMPS="$v" ;;
        esac
    done < "$STATE_CONFIG_FILE"
}

# ============================================================
#  iptables helpers - only ever touch rules tagged with RULE_TAG
# ============================================================
# Usage: safe_iptables_delete <table> <chain> <fixed-string-pattern> [binary]
# Deletes every rule in <table>/<chain> whose "-S" line contains the pattern.
# Rules are parsed into an argv array (no eval).
safe_iptables_delete() {
    local table="$1" chain="$2" pattern="$3" binary="${4:-iptables}"
    command -v "$binary" >/dev/null 2>&1 || return 0
    local rule_line rest
    local -a args
    while IFS= read -r rule_line; do
        [[ -z "$rule_line" ]] && continue
        rest="${rule_line#-A "$chain" }"
        args=()
        read -ra args <<< "$rest"
        "$binary" -w -t "$table" -D "$chain" "${args[@]}" 2>/dev/null
    done < <("$binary" -w -t "$table" -S "$chain" 2>/dev/null | grep -F -- "$pattern")
}

# Delete only this script's own (tagged) rules.
delete_tagged_rules() {
    local table="$1" chain="$2" binary="${3:-iptables}"
    safe_iptables_delete "$table" "$chain" "--comment ${RULE_TAG}" "$binary"
}

# ============================================================
#  Wait for a concurrent apt/dpkg process to finish
# ============================================================
wait_for_apt_lock() {
    local -a lockfiles=(/var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock)
    local lock_check=""
    if   command -v fuser >/dev/null 2>&1; then lock_check="fuser"
    elif command -v lsof  >/dev/null 2>&1; then lock_check="lsof"
    else
        log_info "Neither fuser nor lsof is available - skipping apt lock check."
        return 0
    fi

    local waited=0 max_wait=60 f busy
    while :; do
        busy=0
        for f in "${lockfiles[@]}"; do
            [[ -e "$f" ]] || continue
            "$lock_check" "$f" >/dev/null 2>&1 && busy=1
        done
        [[ "$busy" -eq 0 ]] && break
        [[ "$waited" -eq 0 ]] && log_info "Another apt/dpkg process is running - waiting for it to finish..."
        sleep 3
        waited=$((waited + 3))
        if [[ "$waited" -ge "$max_wait" ]]; then
            log_warn "apt/dpkg still locked after ${max_wait}s - proceeding anyway, install may fail."
            break
        fi
    done
}

# Install packages; verifies the result instead of silently assuming success.
# Usage: apt_install <command-to-verify> <package> [package...]
apt_install() {
    local verify_cmd="$1"; shift
    command -v "$verify_cmd" >/dev/null 2>&1 && return 0
    if ! command -v apt-get >/dev/null 2>&1; then
        log_err "apt-get not found - please install '$*' manually."
        return 1
    fi
    wait_for_apt_lock
    apt-get update -qq >"${LOG_DIR}/apt.log" 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >>"${LOG_DIR}/apt.log" 2>&1
    if command -v "$verify_cmd" >/dev/null 2>&1; then
        return 0
    fi
    log_err "Failed to install '$*' (see ${LOG_DIR}/apt.log)."
    return 1
}

# ============================================================
#  Persist iptables/ip6tables rules across reboots.
#  NOTE: netfilter-persistent saves the *entire* live ruleset
#  (Docker/ufw/fail2ban chains included) - the user is told.
# ============================================================
persist_iptables_rules() {
    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        if command -v debconf-set-selections >/dev/null 2>&1; then
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null
        fi
        apt_install netfilter-persistent iptables-persistent || true
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        if netfilter-persistent save >/dev/null 2>&1; then
            log_ok "Firewall rules saved - will survive a reboot"
            if systemctl is-active docker >/dev/null 2>&1 || command -v ufw >/dev/null 2>&1; then
                log_warn "Docker/ufw detected: the saved ruleset includes THEIR current rules too."
                log_warn "If you rely on Docker or ufw managing its own rules at boot, review /etc/iptables/rules.v4."
            fi
        else
            log_warn "netfilter-persistent save failed - rules will NOT survive a reboot."
        fi
    else
        log_warn "iptables-persistent unavailable - rules applied but will NOT survive a reboot."
    fi
}

# ============================================================
#  Banner / root / distro
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
    echo -e "${BOLD}  Project   :${NC} Complete OS Anti-Filtering & DPI Defeater (Ultra Edition) v${SCRIPT_VERSION}"
    echo -e "${BOLD}  Telegram  :${NC} ${GREEN}@ScriptingGs${NC}"
    echo -e "${BOLD}  GitHub    :${NC} ${GREEN}https://github.com/samanamwowo/${NC}"
    echo -e "${BLUE}------------------------------------------------------------${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "This script must be run as root. Try: sudo bash $0"
        exit 1
    fi
}

check_distro() {
    if [[ ! -f /etc/os-release ]]; then
        log_warn "Could not detect the OS distribution. This script targets Ubuntu/Debian (apt-get)."
        return 0
    fi
    local distro_id
    distro_id=$(. /etc/os-release && echo "${ID:-unknown}")
    case "$distro_id" in
        ubuntu|debian) : ;;
        *)
            log_warn "Detected distro: '$distro_id'. Built and tested for Ubuntu/Debian only (apt-get, iptables-persistent)."
            log_warn "It may partially work or fail on other distros. Proceed at your own risk."
            ;;
    esac
}

# ============================================================
#  Network interface detection
#  - prints ONLY the interface name on stdout
#  - returns non-zero on failure (never calls exit inside $(...))
# ============================================================
detect_iface() {
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    if [[ -z "$iface" ]]; then
        iface=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    fi
    if [[ -z "$iface" ]]; then
        log_err "Could not auto-detect the primary network interface."
        return 1
    fi
    ensure_state_dir
    echo "$iface" > "$STATE_IFACE_FILE"
    echo "$iface"
}

get_tracked_iface() {
    local iface=""
    if [[ -s "$STATE_IFACE_FILE" ]]; then
        iface=$(head -n1 "$STATE_IFACE_FILE")
        # Re-detect if the saved interface no longer exists (renamed / hardware change)
        if [[ -n "$iface" ]] && ip link show "$iface" >/dev/null 2>&1; then
            echo "$iface"
            return 0
        fi
        log_warn "Saved interface '$iface' no longer exists - re-detecting."
    fi
    detect_iface
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
    log_info "CPU cores: ${CPU_CORES} | RAM: ${RAM_MB}MB | socket buffer max: $((RMEM_MAX / 1024 / 1024))MB"
}

# ============================================================
#  Pristine-state snapshot (used by Uninstall for a REAL revert)
# ============================================================
MANAGED_SYSCTL_KEYS=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.ipv4.ip_default_ttl
    net.ipv4.conf.all.accept_redirects
    net.ipv4.conf.all.send_redirects
    net.ipv4.tcp_fastopen
    net.core.somaxconn
    net.core.netdev_max_backlog
    net.ipv4.tcp_max_syn_backlog
    net.ipv4.tcp_max_tw_buckets
    net.ipv4.tcp_rmem
    net.ipv4.tcp_wmem
    net.core.rmem_max
    net.core.wmem_max
    net.ipv4.tcp_moderate_rcvbuf
    net.ipv4.tcp_notsent_lowat
    net.ipv4.tcp_keepalive_time
    net.ipv4.tcp_keepalive_intvl
    net.ipv4.tcp_keepalive_probes
    net.ipv4.tcp_rfc1337
    net.ipv4.tcp_timestamps
    net.ipv4.tcp_slow_start_after_idle
    net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_syncookies
    net.ipv4.conf.all.accept_source_route
    net.ipv4.conf.all.rp_filter
    net.ipv4.conf.default.rp_filter
    net.ipv6.conf.all.disable_ipv6
    net.ipv6.conf.default.disable_ipv6
    net.ipv6.conf.lo.disable_ipv6
)

# Typical kernel defaults - used ONLY when a previous version of this script was
# already applied before the pristine snapshot could be taken.
typical_defaults() {
    cat << 'DEFAULTS_EOF'
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=cubic
net.ipv4.ip_default_ttl=64
net.ipv4.conf.all.accept_redirects=1
net.ipv4.conf.all.send_redirects=1
net.ipv4.tcp_fastopen=1
net.core.somaxconn=4096
net.core.netdev_max_backlog=1000
net.ipv4.tcp_max_syn_backlog=1024
net.ipv4.tcp_max_tw_buckets=131072
net.ipv4.tcp_rmem=4096 131072 6291456
net.ipv4.tcp_wmem=4096 16384 4194304
net.core.rmem_max=212992
net.core.wmem_max=212992
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_notsent_lowat=4294967295
net.ipv4.tcp_keepalive_time=7200
net.ipv4.tcp_keepalive_intvl=75
net.ipv4.tcp_keepalive_probes=9
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_slow_start_after_idle=1
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
DEFAULTS_EOF
}

# Saved once (the first time anything is applied) and never overwritten, so a
# re-run cannot replace the true original values with our own tweaked ones.
snapshot_original_sysctl() {
    ensure_state_dir
    [[ -f "$STATE_ORIG_SYSCTL" ]] && return 0

    if [[ -f "$SYSCTL_FILE" || -f "$SYSCTL_FILE_LEGACY_1" || -f "$SYSCTL_FILE_LEGACY_2" ]]; then
        log_warn "An earlier install of this script is already active, so the exact original values are unknown."
        log_warn "Uninstall will reset them to typical kernel defaults instead."
        typical_defaults > "$STATE_ORIG_SYSCTL"
        return 0
    fi

    local key val
    : > "$STATE_ORIG_SYSCTL"
    for key in "${MANAGED_SYSCTL_KEYS[@]}"; do
        val=$(sysctl -n "$key" 2>/dev/null) || continue
        val="${val//$'\t'/ }"
        echo "${key}=${val}" >> "$STATE_ORIG_SYSCTL"
    done
    log_info "Original sysctl values saved to $STATE_ORIG_SYSCTL (used by Uninstall)"
}

restore_original_sysctl() {
    [[ -f "$STATE_ORIG_SYSCTL" ]] || return 1
    local key val
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        [[ "$key" =~ ^[a-z0-9_.]+$ ]] || continue
        sysctl -w "${key}=${val}" >/dev/null 2>&1
    done < "$STATE_ORIG_SYSCTL"
    return 0
}

# Reference snapshots (diffing / manual inspection only)
backup_current_state() {
    ensure_state_dir
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local sysctl_bak="${STATE_DIR}/backups/sysctl-${ts}.txt"
    local iptables_bak="${STATE_DIR}/backups/iptables-${ts}.rules"

    sysctl -a > "$sysctl_bak" 2>/dev/null
    command -v iptables-save >/dev/null 2>&1 && iptables-save > "$iptables_bak" 2>/dev/null

    # Keep only the 5 most recent snapshots of each type
    ls -1t "${STATE_DIR}"/backups/sysctl-*.txt 2>/dev/null | tail -n +6 | xargs -r rm -f
    ls -1t "${STATE_DIR}"/backups/iptables-*.rules 2>/dev/null | tail -n +6 | xargs -r rm -f

    log_info "Reference snapshots saved in ${STATE_DIR}/backups/ (kept even after Uninstall)"
}

# ============================================================
#  Install self as global command
#  Never silently downgrades a newer installed copy.
# ============================================================
install_global_command() {
    if [[ -z "$SELF_PATH" ]]; then
        log_warn "Running from a pipe/process substitution - skipping 'anti-dpi' install. Save this script to a file and run it once to install the command."
        return 0
    fi

    local target="$GLOBAL_CMD_A"
    if [[ ! -d "$(dirname "$target")" ]]; then
        mkdir -p "$(dirname "$target")" 2>/dev/null || target="$GLOBAL_CMD_B"
    fi
    [[ "$SELF_PATH" == "$target" ]] && return 0

    if [[ -f "$target" ]]; then
        cmp -s "$SELF_PATH" "$target" && return 0
        local installed_ver highest
        installed_ver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$target" 2>/dev/null | head -n1)
        if [[ -n "$installed_ver" && "$installed_ver" != "$SCRIPT_VERSION" ]]; then
            highest=$(printf '%s\n%s\n' "$installed_ver" "$SCRIPT_VERSION" | sort -V | tail -n1)
            if [[ "$highest" == "$installed_ver" ]]; then
                log_warn "Installed 'anti-dpi' is v${installed_ver}, newer than this file (v${SCRIPT_VERSION}) - leaving it untouched."
                return 0
            fi
        fi
    fi

    log_step "Installing global command 'anti-dpi'..."
    if cp -f "$SELF_PATH" "$target" && chmod 755 "$target"; then
        if command -v anti-dpi >/dev/null 2>&1; then
            log_ok "You can now run this tool anywhere by typing: anti-dpi"
        else
            log_warn "Installed to $target but it is not yet on PATH in this shell. Open a new terminal."
        fi
    else
        log_warn "Could not write $target (read-only filesystem?) - continuing without the global command."
    fi
}

# ============================================================
#  Make the fq qdisc effective NOW (net.core.default_qdisc only affects
#  qdiscs created after the sysctl is set - i.e. after a reboot).
#  Handles both single-queue and multi-queue (mq) NICs.
# ============================================================
apply_fq_now() {
    local iface="$1"
    command -v tc >/dev/null 2>&1 || return 0
    modprobe sch_fq >/dev/null 2>&1

    # Skip if our jitter shaping owns the root qdisc
    [[ -f "$STATE_TC_FILE" ]] && return 0

    local root_kind
    root_kind=$(tc qdisc show dev "$iface" root 2>/dev/null | awk 'NR==1{print $2}')
    case "$root_kind" in
        fq) log_ok "fq already active on $iface" ; return 0 ;;
        mq)
            local parent changed=0
            while read -r parent; do
                [[ -n "$parent" ]] || continue
                tc qdisc replace dev "$iface" parent "$parent" fq 2>/dev/null && changed=1
            done < <(tc qdisc show dev "$iface" 2>/dev/null | awk '$1=="qdisc" && $2!="mq" {for(i=1;i<=NF;i++) if ($i=="parent") print $(i+1)}')
            [[ "$changed" -eq 1 ]] && touch "$STATE_QDISC_TOUCHED" && log_ok "fq attached to each TX queue of $iface (BBR pacing)"
            ;;
        noqueue|"")
            log_info "Interface $iface has no queueing discipline (virtual device) - fq not needed."
            ;;
        *)
            if tc qdisc replace dev "$iface" root fq 2>/dev/null; then
                touch "$STATE_QDISC_TOUCHED"
                log_ok "fq attached to $iface (BBR pacing active without reboot)"
            else
                log_warn "Could not attach fq on $iface now - it will apply after reboot via default_qdisc."
            fi
            ;;
    esac
}

# ============================================================
#  Core kernel tuning (menu option 1)
#  Only settings with a real, measurable effect are kept. Removed from the
#  original: tcp_adv_win_scale (obsolete on kernels >= 6.6), ip_dynaddr
#  (dial-up only), log_martians (log spam), strict rp_filter (breaks VPN /
#  asymmetric routing).
# ============================================================
apply_kernel_tweaks() {
    local iface="${1:-}"
    log_step "Applying kernel network stack tweaks..."
    ensure_state_dir
    mkdir -p "$(dirname "$SYSCTL_FILE")"

    rm -f "$SYSCTL_FILE_LEGACY_1" "$SYSCTL_FILE_LEGACY_2"

    # Load BBR BEFORE the sysctl file is applied, and make the module load at boot.
    modprobe tcp_bbr >/dev/null 2>&1
    modprobe sch_fq  >/dev/null 2>&1
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        mkdir -p "$(dirname "$MODULES_FILE")"
        printf 'tcp_bbr\nsch_fq\n' > "$MODULES_FILE"
    fi

    cat > "$SYSCTL_FILE" << SYSCTL_EOF
# Generated by Complete OS Anti-Filtering Optimization Script v${SCRIPT_VERSION}
# Do not edit manually - regenerate via 'anti-dpi'
# Buffers below are scaled for this host: ${CPU_CORES} core(s), ${RAM_MB}MB RAM

# --- BBR + fq: higher throughput on lossy / long-RTT links ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Don't collapse the congestion window after an idle period; interactive
# --- proxy traffic is bursty and would otherwise re-enter slow-start constantly ---
net.ipv4.tcp_slow_start_after_idle = 0

# --- Probe for a working path MTU (helps where ICMP is dropped) ---
net.ipv4.tcp_mtu_probing = 1

# --- Uniform default TTL (reduces OS fingerprint variance) ---
net.ipv4.ip_default_ttl = 128
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# --- TCP Fast Open (kernel auto-disables it on paths that black-hole it) ---
net.ipv4.tcp_fastopen = 3

# --- High concurrency connection handling ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000

# --- Buffers (scaled to RAM). net.core.[rw]mem_max is what UDP-based
# --- transports (QUIC / Hysteria / WireGuard) are capped by; tcp_[rw]mem
# --- controls TCP autotuning. ---
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.ipv4.tcp_rmem = 4096 87380 ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${WMEM_MAX}
net.ipv4.tcp_moderate_rcvbuf = 1
# Bound unsent data per socket: lowers bufferbloat/latency for many-connection proxies
net.ipv4.tcp_notsent_lowat = 131072

# --- Keepalive tuning ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.tcp_rfc1337 = 1
SYSCTL_EOF

    if [[ "$DISABLE_TIMESTAMPS" == "yes" ]]; then
        cat >> "$SYSCTL_FILE" << 'TS_EOF'

# --- TCP timestamps disabled by user choice ---
# Removes an uptime-disclosure vector but also PAWS protection on links > 1Gbps
# and slightly worsens RTT estimation. Only disable if you accept that.
net.ipv4.tcp_timestamps = 0
TS_EOF
        log_info "TCP timestamps: disabled (user opted in)"
    else
        printf '\n# --- TCP timestamps left enabled (kernel default) ---\nnet.ipv4.tcp_timestamps = 1\n' >> "$SYSCTL_FILE"
    fi

    if [[ "$DISABLE_IPV6" == "yes" ]]; then
        cat >> "$SYSCTL_FILE" << 'V6_EOF'

# --- IPv6 disabled by user choice ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
V6_EOF
        log_info "IPv6: disabled (user opted in)"
    fi

    # Apply only OUR file (not the whole system) and report per-key problems.
    local sysctl_log="${LOG_DIR}/sysctl.log"
    if sysctl -p "$SYSCTL_FILE" >"$sysctl_log" 2>&1; then
        log_ok "sysctl parameters applied ($SYSCTL_FILE)"
    else
        log_warn "Some sysctl keys were rejected by this kernel/container (non-fatal):"
        grep -iE "error|cannot|unknown|invalid" "$sysctl_log" | head -n 5 | sed 's/^/        /' >&2
        log_warn "Full output: $sysctl_log"
    fi

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$current_cc" == "bbr" ]]; then
        log_ok "BBR congestion control is active"
    else
        log_warn "BBR could not be activated (current: $current_cc). Kernel $(uname -r) may lack tcp_bbr (common in OpenVZ/LXC containers). Continuing (non-fatal)."
    fi

    [[ -n "$iface" ]] && apply_fq_now "$iface"
}

# ============================================================
#  IRQ balancing across CPU cores (single-core aware)
# ============================================================
apply_irq_balancing() {
    log_step "Configuring IRQ balancing..."

    if [[ "${CPU_CORES:-1}" -le 1 ]]; then
        log_info "Single CPU core - irqbalance gives no benefit here. Skipping (expected, not an error)."
        return 0
    fi

    # Remember the previous state once so Uninstall can put it back.
    if [[ ! -f "$STATE_IRQ_PREV" ]]; then
        ensure_state_dir
        if systemctl is-active irqbalance >/dev/null 2>&1; then echo active > "$STATE_IRQ_PREV"
        else echo inactive > "$STATE_IRQ_PREV"; fi
    fi

    apt_install irqbalance irqbalance || { log_warn "irqbalance not installed - skipping."; return 0; }

    systemctl enable irqbalance >/dev/null 2>&1
    systemctl restart irqbalance >/dev/null 2>&1
    sleep 1

    if systemctl is-active irqbalance >/dev/null 2>&1; then
        log_ok "irqbalance is installed, enabled, and running (${CPU_CORES} cores)"
    elif journalctl -u irqbalance --no-pager -n 20 2>/dev/null | grep -qi "single cpu"; then
        log_info "irqbalance exited: the hypervisor exposes a single effective IRQ CPU. Safe to ignore."
    else
        log_warn "irqbalance could not be started - check 'systemctl status irqbalance'"
    fi
}

# ============================================================
#  Extra sysctl module (separate file - optional/removable)
# ============================================================
apply_extra_hardening() {
    log_step "Applying extra security sysctl module..."

    cat > "$EXTRA_SYSCTL_FILE" << EXTRA_EOF
# Generated by Complete OS Anti-Filtering Optimization Script v${SCRIPT_VERSION}
# Separate, optional module - delete this file to revert just these settings.

# --- Reverse-path filter in LOOSE mode (2): drops obviously spoofed sources but
# --- does NOT break WireGuard/VPN, policy routing or multi-homed servers the
# --- way strict mode (1) does ---
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
EXTRA_EOF

    if sysctl -p "$EXTRA_SYSCTL_FILE" >"${LOG_DIR}/sysctl_extra.log" 2>&1; then
        log_ok "Extra hardening applied ($EXTRA_SYSCTL_FILE)"
    else
        log_warn "Some extra keys were rejected (non-fatal); see ${LOG_DIR}/sysctl_extra.log"
    fi
}

# ============================================================
#  IPv6 mirror of the MSS clamp (separate, optional/removable)
# ============================================================
apply_ipv6_mirror() {
    local mss_value="${1:-1360}"
    log_step "Mirroring MSS clamping to IPv6 (ip6tables)..."

    if [[ "$DISABLE_IPV6" == "yes" ]]; then
        log_info "IPv6 is disabled on this host - nothing to mirror."
        return 0
    fi

    apt_install ip6tables iptables || { log_warn "ip6tables unavailable - IPv6 not clamped (non-fatal)."; return 1; }

    delete_tagged_rules filter FORWARD ip6tables
    delete_tagged_rules filter OUTPUT  ip6tables

    ip6tables -w -A FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$RULE_TAG" -j TCPMSS --set-mss "$mss_value"
    ip6tables -w -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$RULE_TAG" -j TCPMSS --set-mss "$mss_value"

    ensure_state_dir
    touch "$STATE_IPV6_MIRROR_FILE"
    log_ok "IPv6 MSS clamping applied (${mss_value} bytes)"
}

run_kernel_hardening() {
    check_root
    log_step "Starting core kernel tuning..."
    ensure_state_dir

    local iface
    if ! iface=$(detect_iface); then
        log_err "Aborting - no usable network interface found. Nothing was changed."
        return 1
    fi
    detect_resources
    backup_current_state
    snapshot_original_sysctl
    echo

    ask_yn "Disable TCP timestamps? Minor fingerprint reduction, but affects PAWS on >1Gbps links." n \
        && DISABLE_TIMESTAMPS="yes" || DISABLE_TIMESTAMPS="no"
    ask_yn "Disable IPv6 entirely on this host?" n \
        && DISABLE_IPV6="yes" || DISABLE_IPV6="no"
    local apply_extra="no"
    ask_yn "Apply the extra hardening module too (loose rp_filter, syncookies)? Separate file." y && apply_extra="yes"
    save_config
    echo

    install_global_command
    echo
    apply_kernel_tweaks "$iface"
    echo
    apply_irq_balancing
    echo
    if [[ "$apply_extra" == "yes" ]]; then
        apply_extra_hardening
        echo
    fi
    log_ok "Core kernel tuning applied successfully."
}

# ============================================================
#  L3/L4 network manipulation (menu option 2)
# ============================================================

# Prints "<tso> <gso> <gro>" (on/off) for an interface
get_offload_state() {
    ethtool -k "$1" 2>/dev/null | awk -F': *' '
        /^tcp-segmentation-offload:/     {split($2,a," "); t=a[1]}
        /^generic-segmentation-offload:/ {split($2,a," "); g=a[1]}
        /^generic-receive-offload:/      {split($2,a," "); r=a[1]}
        END {if (t!="" && g!="" && r!="") print t, g, r}'
}

# NIC offload OFF is OPT-IN: it makes the CPU do segmentation work, which
# lowers throughput and raises CPU load. The exact original state is saved so
# Uninstall restores it precisely (not blindly "on").
apply_nic_tuning() {
    local iface="$1"
    log_step "Disabling NIC offload (tso/gso/gro) on interface: $iface"

    apt_install ethtool ethtool || { log_warn "ethtool unavailable - skipping NIC offload changes."; return 1; }

    if [[ ! -f "$STATE_ORIG_OFFLOAD" ]]; then
        local st
        st=$(get_offload_state "$iface")
        if [[ -n "$st" ]]; then
            read -r t g r <<< "$st"
            ensure_state_dir
            echo "${iface} tso=${t} gso=${g} gro=${r}" > "$STATE_ORIG_OFFLOAD"
        fi
    fi

    if ! ethtool -K "$iface" tso off gso off gro off >/dev/null 2>&1; then
        log_warn "Some offload features are not changeable on $iface (common on virtio NICs) - non-fatal."
    else
        log_ok "Offloading (tso/gso/gro) disabled on $iface"
    fi

    local ethtool_bin
    ethtool_bin=$(command -v ethtool)
    cat > "$NIC_SERVICE" << EOF
[Unit]
Description=Anti-DPI NIC offload persistence
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${ethtool_bin} -K ${iface} tso off gso off gro off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable antidpi-nic.service >/dev/null 2>&1
    systemctl restart antidpi-nic.service >/dev/null 2>&1
    log_ok "antidpi-nic.service enabled (persists across reboots)"
}

# MSS clamp rules are tagged, so re-running replaces only OUR rules.
apply_mss_clamp() {
    local mss_value="${1:-1360}"
    log_step "Applying TCP MSS clamping (target: ${mss_value} bytes)..."

    apt_install iptables iptables || { log_err "iptables unavailable - MSS clamp not applied."; return 1; }

    delete_tagged_rules filter FORWARD
    delete_tagged_rules filter OUTPUT

    iptables -w -A FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$RULE_TAG" -j TCPMSS --set-mss "$mss_value"
    iptables -w -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$RULE_TAG" -j TCPMSS --set-mss "$mss_value"

    log_ok "MSS clamped to ${mss_value} bytes on FORWARD/OUTPUT chains"
}

# Opt-in. The value is rotated once per run (not per connection).
apply_ttl_randomization() {
    log_step "Applying TTL fingerprint rule..."
    modprobe xt_TTL >/dev/null 2>&1
    delete_tagged_rules mangle OUTPUT

    local rand_ttl=$(( (RANDOM % 4) + 125 ))
    if iptables -w -t mangle -A OUTPUT -m comment --comment "$RULE_TAG" -j TTL --ttl-set "$rand_ttl" 2>"${LOG_DIR}/ttl.log"; then
        ensure_state_dir
        echo "$rand_ttl" > "$STATE_TTL_FILE"
        log_ok "Outbound TTL set to $rand_ttl (mangle/OUTPUT)"
    else
        log_warn "Could not apply TTL target (xt_TTL unavailable on this kernel). Skipping, non-fatal."
    fi
}

# Prints the tc commands (one per line, plain words - no eval needed) that build
# the jitter hierarchy. Everything except the chosen port keeps flowing through
# an fq qdisc (so BBR pacing is preserved); only the proxy port goes through netem.
tc_jitter_commands() {
    local iface="$1" port="$2"
    echo "qdisc replace dev ${iface} root handle 1: prio bands 3 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1"
    echo "qdisc replace dev ${iface} parent 1:2 handle 20: fq"
    echo "qdisc replace dev ${iface} parent 1:3 handle 30: netem delay 10ms 5ms distribution normal"
    echo "filter add dev ${iface} protocol ip parent 1: prio 3 u32 match ip sport ${port} 0xffff flowid 1:3"
    echo "filter add dev ${iface} protocol ipv6 parent 1: prio 4 u32 match ip6 sport ${port} 0xffff flowid 1:3"
}

# Opt-in and persistent (systemd). NOTE: netem adds ~10ms latency to proxy
# traffic - a real performance cost, hence off by default.
apply_traffic_shaping() {
    local iface="$1" target_port="${2:-443}"
    log_step "Applying traffic shaping (jitter) on interface: $iface, port: $target_port"

    apt_install tc iproute2 || { log_warn "tc unavailable - skipping."; return 1; }
    modprobe sch_netem >/dev/null 2>&1
    modprobe sch_prio  >/dev/null 2>&1
    modprobe sch_fq    >/dev/null 2>&1

    local tc_bin
    tc_bin=$(command -v tc)

    tc qdisc del dev "$iface" root >/dev/null 2>&1

    local line ok=1
    local -a words
    : > "${LOG_DIR}/tc.log"
    while IFS= read -r line; do
        read -ra words <<< "$line"
        if ! "$tc_bin" "${words[@]}" 2>>"${LOG_DIR}/tc.log"; then
            log_warn "tc step failed: tc ${line}"
            ok=0
            break
        fi
    done < <(tc_jitter_commands "$iface" "$target_port")

    if [[ "$ok" -ne 1 ]]; then
        log_warn "Traffic shaping incomplete - rolling back to the default qdisc. See ${LOG_DIR}/tc.log"
        tc qdisc del dev "$iface" root >/dev/null 2>&1
        rm -f "$STATE_TC_FILE"
        return 1
    fi

    ensure_state_dir
    echo "${iface} ${target_port}" > "$STATE_TC_FILE"
    touch "$STATE_QDISC_TOUCHED"

    # Persist across reboots (tc state is lost on reboot otherwise)
    {
        echo "[Unit]"
        echo "Description=Anti-DPI tc jitter shaping"
        echo "After=network-online.target"
        echo "Wants=network-online.target"
        echo
        echo "[Service]"
        echo "Type=oneshot"
        echo "RemainAfterExit=yes"
        echo "ExecStartPre=-${tc_bin} qdisc del dev ${iface} root"
        while IFS= read -r line; do
            echo "ExecStart=${tc_bin} ${line}"
        done < <(tc_jitter_commands "$iface" "$target_port")
        echo
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } > "$TC_SERVICE"
    systemctl daemon-reload
    systemctl enable antidpi-tc.service >/dev/null 2>&1

    log_ok "Jitter (10ms +/- 5ms) applied to port ${target_port} on $iface and persisted (antidpi-tc.service)"
}

run_l3l4_manipulation() {
    check_root
    log_step "Starting L3/L4 network manipulation..."
    ensure_state_dir
    load_config

    local iface
    if ! iface=$(get_tracked_iface); then
        log_err "Aborting - no usable network interface found. Nothing was changed."
        return 1
    fi
    detect_resources
    backup_current_state
    snapshot_original_sysctl
    log_info "Using interface: $iface"
    echo

    local do_mss="no" mss_value=1360
    if ask_yn "Apply TCP MSS clamping? (helps on paths with MTU problems; slightly lowers per-packet efficiency)" y; then
        do_mss="yes"
        local in_mss
        read -rp "$(echo -e "${YELLOW}MSS value in bytes (536-1460, lower = more overhead) [1360]: ${NC}")" in_mss || in_mss=""
        in_mss="${in_mss:-1360}"
        if [[ "$in_mss" =~ ^[0-9]+$ ]] && [[ "$in_mss" -ge 536 && "$in_mss" -le 1460 ]]; then
            mss_value="$in_mss"
        else
            log_warn "Invalid MSS '$in_mss' - falling back to 1360."
        fi
    fi

    local do_nic="no" do_ttl="no" do_jitter="no" proxy_port=443
    ask_yn "Disable NIC offload (tso/gso/gro)? No proven anti-DPI benefit and costs CPU/throughput." n && do_nic="yes"
    ask_yn "Add an outbound TTL rule (125-128, chosen once per run)? sysctl already sets TTL 128." n && do_ttl="yes"
    if ask_yn "Add network jitter on your proxy port? Adds ~10ms latency to that traffic (performance cost)." n; then
        do_jitter="yes"
        local in_port
        read -rp "$(echo -e "${YELLOW}Port your proxy/service listens on [443]: ${NC}")" in_port || in_port=""
        in_port="${in_port:-443}"
        if [[ "$in_port" =~ ^[0-9]+$ ]] && [[ "$in_port" -ge 1 && "$in_port" -le 65535 ]]; then
            proxy_port="$in_port"
        else
            log_warn "Invalid port '$in_port' - falling back to 443."
        fi
    fi
    echo

    if [[ "$do_nic" == "yes" ]]; then
        if [[ "${CPU_CORES:-0}" -le 2 ]]; then
            log_warn "Only ${CPU_CORES} CPU core(s): disabling offload can push a small vCPU to 100% under load."
            ask_yn "Really disable offload on this low-core host?" n || do_nic="no"
        fi
        [[ "$do_nic" == "yes" ]] && { apply_nic_tuning "$iface"; echo; }
    fi

    if [[ "$do_mss" == "yes" ]]; then
        apply_mss_clamp "$mss_value"
        echo
        if [[ "$DISABLE_IPV6" != "yes" ]]; then
            apply_ipv6_mirror "$mss_value"
            echo
        fi
    fi

    if [[ "$do_ttl" == "yes" ]]; then
        apply_ttl_randomization
        echo
    fi

    if [[ "$do_jitter" == "yes" ]]; then
        apply_traffic_shaping "$iface" "$proxy_port"
        echo
    else
        apply_fq_now "$iface"
        echo
    fi

    if [[ "$do_mss" == "yes" || "$do_ttl" == "yes" ]]; then
        log_step "Persisting firewall rules across reboots..."
        persist_iptables_rules
        echo
    fi
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
    log_warn "between periods of real use - nothing more. It also uses bandwidth/CPU"
    log_warn "continuously (a full page fetch every 30-180s)."
    if ! ask_yn "Deploy it anyway?" n; then
        log_info "Skipping background noise generator (nothing changed)."
        return 0
    fi
    log_step "Deploying background traffic noise generator..."
    ensure_state_dir

    apt_install curl curl || { log_err "curl is required - aborting this module (nothing else changed)."; return 1; }

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
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable antidpi-noise.service >/dev/null 2>&1
    systemctl restart antidpi-noise.service >/dev/null 2>&1

    if systemctl is-active antidpi-noise.service >/dev/null 2>&1; then
        log_ok "antidpi-noise.service is running (requests every 30-180s)"
    else
        log_warn "antidpi-noise.service failed to start - check 'systemctl status antidpi-noise.service'"
    fi
}

# ============================================================
#  Status / diagnostics (menu option 4)
# ============================================================
check_status() {
    check_root
    log_step "System & DPI Defense Status (script v${SCRIPT_VERSION})"
    echo >&2

    echo -e "${BOLD}-- System Info --${NC}" >&2
    [[ -f /etc/os-release ]] && log_info "OS: $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
    log_info "Kernel: $(uname -r)"
    command -v systemd-detect-virt >/dev/null 2>&1 && log_info "Virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"
    echo >&2

    echo -e "${BOLD}-- Congestion Control / qdisc --${NC}" >&2
    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unavailable")
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unavailable")
    [[ "$cc" == "bbr" ]] && log_ok "BBR: active" || log_warn "BBR: NOT active (current: $cc)"
    [[ "$qd" == "fq"  ]] && log_ok "default_qdisc: fq" || log_warn "default_qdisc: $qd (expected fq)"
    if [[ -s "$STATE_IFACE_FILE" ]]; then
        local iface_q
        iface_q=$(head -n1 "$STATE_IFACE_FILE")
        log_info "Root qdisc on ${iface_q}: $(tc qdisc show dev "$iface_q" root 2>/dev/null | awk 'NR==1{print $2}')"
    fi
    echo >&2

    echo -e "${BOLD}-- sysctl config files --${NC}" >&2
    [[ -f "$SYSCTL_FILE" ]] && log_ok "$SYSCTL_FILE exists" || log_warn "$SYSCTL_FILE not found"
    [[ -f "$EXTRA_SYSCTL_FILE" ]] && log_ok "$EXTRA_SYSCTL_FILE exists (extra module active)" || log_info "Extra module not applied (optional)"
    [[ -f "$MODULES_FILE" ]] && log_ok "tcp_bbr set to load at boot" || log_warn "tcp_bbr not registered for boot loading"
    [[ -f "$STATE_ORIG_SYSCTL" ]] && log_ok "Original sysctl values saved (Uninstall can restore them)" || log_warn "No original-values snapshot yet"
    echo >&2

    echo -e "${BOLD}-- IRQ balancing --${NC}" >&2
    local cores
    cores=$(nproc 2>/dev/null || echo 1)
    if [[ "$cores" -le 1 ]]; then
        log_info "Single-core host - irqbalance intentionally not used"
    elif systemctl is-active irqbalance >/dev/null 2>&1; then
        log_ok "irqbalance is active (${cores} cores)"
    else
        log_warn "irqbalance is not active"
    fi
    echo >&2

    echo -e "${BOLD}-- NIC offload (optional) --${NC}" >&2
    if systemctl is-enabled antidpi-nic.service >/dev/null 2>&1; then
        log_ok "antidpi-nic.service is enabled"
    else
        log_info "NIC offload tuning not installed (default, recommended)"
    fi
    if [[ -s "$STATE_IFACE_FILE" ]] && command -v ethtool >/dev/null 2>&1; then
        ethtool -k "$(head -n1 "$STATE_IFACE_FILE")" 2>/dev/null | grep -E "^(tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload)" >&2
    fi
    echo >&2

    echo -e "${BOLD}-- Firewall rules (tagged '${RULE_TAG}') --${NC}" >&2
    local current_mss
    current_mss=$(iptables -w -S FORWARD 2>/dev/null | grep -F -- "--comment ${RULE_TAG}" | sed -n 's/.*--set-mss \([0-9]\+\).*/\1/p' | head -n1)
    [[ -n "$current_mss" ]] && log_ok "MSS clamp present (IPv4), value: ${current_mss} bytes" || log_info "MSS clamp not present"
    if [[ -f "$STATE_IPV6_MIRROR_FILE" ]] && ip6tables -w -S FORWARD 2>/dev/null | grep -qF -- "--comment ${RULE_TAG}"; then
        log_ok "IPv6 MSS clamp present"
    else
        log_info "IPv6 MSS clamp not applied (optional)"
    fi
    if iptables -w -t mangle -S OUTPUT 2>/dev/null | grep -qF -- "--comment ${RULE_TAG}"; then
        log_ok "TTL rule present (value: $(cat "$STATE_TTL_FILE" 2>/dev/null || echo unknown))"
    else
        log_info "TTL rule not present (optional; sysctl already sets TTL 128)"
    fi
    if command -v netfilter-persistent >/dev/null 2>&1 && [[ -f /etc/iptables/rules.v4 ]]; then
        log_ok "Rules are persisted (survive a reboot)"
    else
        log_info "iptables-persistent not installed - firewall rules (if any) would NOT survive a reboot"
    fi
    echo >&2

    echo -e "${BOLD}-- Jitter shaping (optional) --${NC}" >&2
    if [[ -f "$STATE_TC_FILE" ]]; then
        local tc_iface tc_port
        read -r tc_iface tc_port < "$STATE_TC_FILE"
        if tc qdisc show dev "$tc_iface" 2>/dev/null | grep -q netem; then
            log_ok "Jitter active on ${tc_iface}, port ${tc_port}"
        else
            log_warn "Jitter configured but netem not found on ${tc_iface}"
        fi
        systemctl is-enabled antidpi-tc.service >/dev/null 2>&1 && log_ok "antidpi-tc.service enabled (persists)" || log_warn "antidpi-tc.service not enabled - jitter would be lost on reboot"
    else
        log_info "Jitter not enabled (default, recommended for performance)"
    fi
    echo >&2

    echo -e "${BOLD}-- Background noise generator --${NC}" >&2
    systemctl is-active antidpi-noise.service >/dev/null 2>&1 && log_ok "antidpi-noise.service is running" || log_info "antidpi-noise.service not running"
    echo >&2

    echo -e "${BOLD}-- Global command --${NC}" >&2
    command -v anti-dpi >/dev/null 2>&1 && log_ok "'anti-dpi' at: $(command -v anti-dpi)" || log_warn "'anti-dpi' not found on PATH"
}

# ============================================================
#  Self-update (menu option 5)
#  Runs as root, so it is deliberately paranoid:
#   - source can be pinned to a tag/commit (UPDATE_REF)
#   - optional expected sha256 (anti-dpi update <sha256>)
#   - validates shebang, syntax and a version marker
#   - shows a diff and requires explicit confirmation
# ============================================================
self_update() {
    check_root
    local expected_hash="${1:-}"
    log_step "Checking for a newer version..."
    ensure_state_dir

    if [[ -z "$SELF_PATH" ]]; then
        log_err "Cannot update: the script is not running from a regular file."
        return 1
    fi
    apt_install curl curl || return 1

    local ref="$UPDATE_REF" in_ref
    read -rp "$(echo -e "${YELLOW}Git ref to update from - a tag or commit hash is safest [${ref}]: ${NC}")" in_ref || in_ref=""
    in_ref="${in_ref:-$ref}"
    if ! [[ "$in_ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        log_err "Invalid ref '$in_ref'. Aborting - nothing changed."
        return 1
    fi
    local url="${UPDATE_BASE}/${in_ref}/optimize.sh"

    local tmp_file
    tmp_file=$(mktemp "${STATE_DIR}/update-XXXXXX.sh") || { log_err "Could not create a temp file. Aborting."; return 1; }

    log_info "Downloading: $url"
    if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 --max-filesize 1048576 "$url" -o "$tmp_file"; then
        log_err "Download failed. Nothing changed - current version kept."
        rm -f "$tmp_file"
        return 1
    fi

    local problem=""
    [[ -s "$tmp_file" ]]                                   || problem="downloaded file is empty"
    [[ -z "$problem" ]] && ! head -n1 "$tmp_file" | grep -q '^#!.*bash'  && problem="missing bash shebang"
    [[ -z "$problem" ]] && ! grep -q '^SCRIPT_VERSION="' "$tmp_file"     && problem="no SCRIPT_VERSION marker (not this tool?)"
    [[ -z "$problem" ]] && ! bash -n "$tmp_file" 2>"${LOG_DIR}/update_syntax.log" && problem="syntax check failed (see ${LOG_DIR}/update_syntax.log)"
    if [[ -n "$problem" ]]; then
        log_err "Update rejected: $problem. Nothing changed."
        rm -f "$tmp_file"
        return 1
    fi
    log_ok "Downloaded script passed basic validation"

    local current_hash new_hash new_ver
    current_hash=$(sha256sum "$SELF_PATH" | awk '{print $1}')
    new_hash=$(sha256sum "$tmp_file" | awk '{print $1}')
    new_ver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$tmp_file" | head -n1)

    if [[ -n "$expected_hash" && "${expected_hash,,}" != "$new_hash" ]]; then
        log_err "SHA256 mismatch! expected ${expected_hash}, got ${new_hash}. Update aborted - nothing changed."
        rm -f "$tmp_file"
        return 1
    fi

    if [[ "$current_hash" == "$new_hash" ]]; then
        log_ok "You already have this version - nothing to update."
        rm -f "$tmp_file"
        return 0
    fi

    log_info "Current: v${SCRIPT_VERSION}  ->  Available: v${new_ver:-?}"
    log_info "New file sha256: ${new_hash}"
    log_info "Changes (first 60 diff lines):"
    diff -u "$SELF_PATH" "$tmp_file" | head -n 60 >&2
    echo >&2
    if ! ask_yn "This code will run as ROOT. Install this version?" n; then
        log_info "Update cancelled - nothing changed."
        rm -f "$tmp_file"
        return 0
    fi

    local backup_path="${STATE_DIR}/backups/optimize-$(date +%Y%m%d-%H%M%S).sh.bak"
    cp -f "$SELF_PATH" "$backup_path" 2>/dev/null
    ls -1t "${STATE_DIR}"/backups/optimize-*.sh.bak 2>/dev/null | tail -n +6 | xargs -r rm -f
    log_info "Current version backed up to: $backup_path"

    # Atomic replace: write next to the target, then rename
    local g
    for g in "$SELF_PATH" "$GLOBAL_CMD_A" "$GLOBAL_CMD_B"; do
        [[ -f "$g" ]] || continue
        if cp -f "$tmp_file" "${g}.new" && chmod 755 "${g}.new" && mv -f "${g}.new" "$g"; then
            :
        else
            log_err "Could not replace $g - nothing else was modified for that path."
            rm -f "${g}.new"
        fi
    done

    rm -f "$tmp_file"
    log_ok "Updated to v${new_ver:-?}. Restarting into the new version..."
    echo >&2
    exec bash "$SELF_PATH"
}

# ============================================================
#  Uninstall / rollback (menu option 6)
# ============================================================
run_uninstall() {
    check_root
    log_step "Rolling back all changes made by this script..."
    echo >&2

    # --- sysctl: restore the REAL original values (deleting the files alone does not) ---
    log_info "Removing sysctl configs and restoring original values..."
    rm -f "$SYSCTL_FILE" "$SYSCTL_FILE_LEGACY_1" "$SYSCTL_FILE_LEGACY_2" "$EXTRA_SYSCTL_FILE" "$MODULES_FILE"
    if restore_original_sysctl; then
        log_ok "sysctl values restored from the pre-change snapshot"
    else
        sysctl --system >/dev/null 2>&1
        log_warn "No original-values snapshot found. Config files were removed, but already-applied runtime values stay until reboot."
    fi

    # --- irqbalance: put it back the way it was ---
    if [[ -f "$STATE_IRQ_PREV" ]]; then
        if [[ "$(cat "$STATE_IRQ_PREV")" == "inactive" ]]; then
            systemctl disable irqbalance >/dev/null 2>&1
            systemctl stop irqbalance >/dev/null 2>&1
            log_ok "irqbalance returned to its previous (inactive) state"
        else
            log_ok "irqbalance was already active before - left running"
        fi
    fi

    # --- NIC offload ---
    if [[ -f "$NIC_SERVICE" ]]; then
        systemctl stop antidpi-nic.service >/dev/null 2>&1
        systemctl disable antidpi-nic.service >/dev/null 2>&1
        rm -f "$NIC_SERVICE"
        log_ok "antidpi-nic.service removed"
    fi
    if [[ -f "$STATE_ORIG_OFFLOAD" ]]; then
        local o_iface o_rest
        read -r o_iface o_rest < "$STATE_ORIG_OFFLOAD"
        if [[ "$o_rest" =~ ^tso=(on|off)\ gso=(on|off)\ gro=(on|off)$ ]] && command -v ethtool >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            ethtool -K "$o_iface" ${o_rest//=/ } >/dev/null 2>&1
            log_ok "Offload on $o_iface restored to its original state ($o_rest)"
        fi
    fi

    # --- tc / qdisc ---
    if [[ -f "$TC_SERVICE" ]]; then
        systemctl stop antidpi-tc.service >/dev/null 2>&1
        systemctl disable antidpi-tc.service >/dev/null 2>&1
        rm -f "$TC_SERVICE"
        log_ok "antidpi-tc.service removed"
    fi
    systemctl daemon-reload
    if [[ -f "$STATE_QDISC_TOUCHED" || -f "$STATE_TC_FILE" ]]; then
        local q_iface=""
        [[ -s "$STATE_TC_FILE" ]] && read -r q_iface _ < "$STATE_TC_FILE"
        [[ -z "$q_iface" && -s "$STATE_IFACE_FILE" ]] && q_iface=$(head -n1 "$STATE_IFACE_FILE")
        if [[ -n "$q_iface" ]]; then
            tc qdisc del dev "$q_iface" root >/dev/null 2>&1
            log_ok "Root qdisc on $q_iface reset to the system default"
        fi
    fi

    # --- noise generator ---
    if [[ -f "$NOISE_SERVICE" ]]; then
        systemctl stop antidpi-noise.service >/dev/null 2>&1
        systemctl disable antidpi-noise.service >/dev/null 2>&1
        rm -f "$NOISE_SERVICE"
        systemctl daemon-reload
    fi
    rm -f "$NOISE_SCRIPT"
    log_ok "Noise generator removed"

    # --- firewall: ONLY our tagged rules ---
    log_info "Removing iptables rules added by this script (tagged '${RULE_TAG}')..."
    delete_tagged_rules filter FORWARD
    delete_tagged_rules filter OUTPUT
    delete_tagged_rules mangle OUTPUT
    delete_tagged_rules filter FORWARD ip6tables
    delete_tagged_rules filter OUTPUT  ip6tables

    if ask_yn "Also remove UNTAGGED TCPMSS/TTL rules left by older versions of this script? (could match rules from other tools)" n; then
        safe_iptables_delete filter FORWARD "-j TCPMSS"
        safe_iptables_delete filter OUTPUT  "-j TCPMSS"
        safe_iptables_delete mangle OUTPUT  "-j TTL"
        safe_iptables_delete filter FORWARD "-j TCPMSS" ip6tables
        safe_iptables_delete filter OUTPUT  "-j TCPMSS" ip6tables
    fi
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    log_ok "iptables rules removed"

    # --- global command + state (reference backups are kept) ---
    rm -f "$GLOBAL_CMD_A" "$GLOBAL_CMD_B" 2>/dev/null
    log_ok "'anti-dpi' global command removed"
    if [[ -d "$STATE_DIR" ]]; then
        find "$STATE_DIR" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} + 2>/dev/null
        log_info "Reference snapshots kept in ${STATE_DIR}/backups (delete manually if not needed)"
    fi

    echo >&2
    echo -e "${GREEN}${BOLD}All changes made by this script were reverted.${NC}" >&2
    log_info "A reboot is recommended to fully clear any leftover runtime state."
}

# ============================================================
#  Main menu
# ============================================================
main_menu() {
    local choice
    while true; do
        print_banner
        echo -e "${BOLD}Please choose an option:${NC}"
        echo -e "  ${CYAN}1)${NC} Apply Core Kernel Tuning & BBR Optimization ${GREEN}[REQUIRED]${NC}"
        echo -e "  ${CYAN}2)${NC} Apply L3/L4 Network Tweaks (MSS clamp, optional TTL/jitter/offload) ${YELLOW}[RECOMMENDED]${NC}"
        echo -e "  ${CYAN}3)${NC} Deploy Background Noise Generator ${BLUE}[OPTIONAL]${NC}"
        echo -e "  ${CYAN}4)${NC} Run Comprehensive Status & Diagnostics ${YELLOW}[RECOMMENDED]${NC}"
        echo -e "  ${CYAN}5)${NC} Update to Latest Version ${MAGENTA}[SYSTEM TOOL]${NC}"
        echo -e "  ${CYAN}6)${NC} Uninstall & Restore Original Settings ${MAGENTA}[SYSTEM TOOL]${NC}"
        echo -e "  ${CYAN}7)${NC} Exit"
        echo -e "${BLUE}------------------------------------------------------------${NC}"
        # Exit cleanly on EOF (stdin closed) instead of looping forever
        read -rp "$(echo -e "${BOLD}Select [1-7]: ${NC}")" choice || { echo; exit 0; }
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
        read -rp "Press Enter to return to the menu..." _ || { echo; exit 0; }
    done
}

# ============================================================
#  Entry point (skipped when the file is sourced, e.g. for testing)
# ============================================================
main() {
    check_root
    check_distro
    load_config
    install_global_command

    case "${1:-}" in
        status)    check_status;           exit 0 ;;
        update)    self_update "${2:-}";   exit $? ;;
        uninstall) run_uninstall;          exit 0 ;;
        "")        : ;;
        *)         log_err "Unknown argument '$1'. Use: status | update [sha256] | uninstall"; exit 2 ;;
    esac

    echo
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
