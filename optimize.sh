#!/usr/bin/env bash
#
# Complete OS Anti-Filtering & DPI Defense Script (Ultra Edition)
# Author Telegram : @ScriptingGs
# GitHub          : https://github.com/samanamwowo/
#
# Supported distros: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
#
set -uo pipefail

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

SYSCTL_FILE="/etc/sysctl.d/99-antidpi-ultra.conf"
SYSCTL_FILE_LEGACY="/etc/sysctl.d/99-antidpi.conf"
NIC_SERVICE="/etc/systemd/system/antidpi-nic.service"
NOISE_SERVICE="/etc/systemd/system/antidpi-noise.service"
NOISE_SCRIPT="/usr/local/bin/noise-gen.sh"
NGINX_CONF="/etc/nginx/conf.d/antidpi.conf"
GLOBAL_CMD_A="/usr/local/bin/anti-dpi"
GLOBAL_CMD_B="/usr/bin/anti-dpi"
SELF_PATH="$(readlink -f "$0")"
STATE_DIR="/etc/antidpi"
STATE_IFACE_FILE="${STATE_DIR}/iface"
STATE_TTL_FILE="${STATE_DIR}/ttl_value"

log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()   { echo -e "${RED}[FAIL]${NC}  $1"; }
log_step()  { echo -e "${MAGENTA}[STEP]${NC} ${BOLD}$1${NC}"; }

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
#  Detect primary network interface
# ============================================================
detect_iface() {
    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)
    if [[ -z "$iface" ]]; then
        iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
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
#  Section 3: Kernel & TCP stack hardening
# ============================================================
apply_kernel_tweaks() {
    log_step "Applying kernel network stack tweaks..."
    mkdir -p "$(dirname "$SYSCTL_FILE")"

    [[ -f "$SYSCTL_FILE_LEGACY" ]] && rm -f "$SYSCTL_FILE_LEGACY"

    cat > "$SYSCTL_FILE" << SYSCTL_EOF
# Generated by Complete OS Anti-Filtering Optimization Script (Ultra Edition)
# Do not edit manually - regenerate via 'anti-dpi'
# Buffers below are scaled for this host: ${CPU_CORES} core(s), ${RAM_MB}MB RAM

# --- BBR + fq for better throughput / congestion behaviour ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Reduce OS/network fingerprinting surface ---
net.ipv4.tcp_timestamps = 0
net.ipv4.ip_default_ttl = 128

# --- TCP Fast Open ---
net.ipv4.tcp_fastopen = 3

# --- High concurrency connection handling ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# --- Buffer / receive window tuning (scaled to host resources) ---
net.ipv4.tcp_rmem = 4096 87380 ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${WMEM_MAX}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 2

# --- RFC1337 + dynamic address handling ---
net.ipv4.tcp_rfc1337 = 1
net.ipv4.ip_dynaddr = 1
SYSCTL_EOF

    if sysctl --system >/tmp/antidpi_sysctl.log 2>&1; then
        log_ok "sysctl parameters applied ($SYSCTL_FILE)"
    else
        log_warn "sysctl --system reported issues; see /tmp/antidpi_sysctl.log"
    fi

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$current_cc" == "bbr" ]]; then
        log_ok "BBR congestion control is active"
    else
        log_warn "BBR not active (current: $current_cc) - attempting to load tcp_bbr module"
        modprobe tcp_bbr 2>/dev/null && sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    fi
}

# ============================================================
#  DNS optimization
# ============================================================
apply_dns_optimization() {
    log_step "Optimizing DNS resolvers..."

    if [[ -f /etc/resolv.conf && ! -f /etc/resolv.conf.antidpi.bak ]]; then
        cp -f /etc/resolv.conf /etc/resolv.conf.antidpi.bak 2>/dev/null
        log_info "Original /etc/resolv.conf backed up to /etc/resolv.conf.antidpi.bak"
    fi

    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    fi

    cat > /etc/resolv.conf << 'RESOLV_EOF'
# Generated by Complete OS Anti-Filtering Optimization Script
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2
RESOLV_EOF

    chattr +i /etc/resolv.conf 2>/dev/null

    log_ok "DNS set to 1.1.1.1 / 8.8.8.8 (file locked against overwrite)"
}

# ============================================================
#  IRQ balancing across CPU cores (FIXED: single-core aware)
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
#  Section 4: NIC tuning (offload disable) + systemd persistence
# ============================================================
apply_nic_tuning() {
    local iface="$1"
    log_step "Tuning NIC offload settings on interface: $iface"

    if ! command -v ethtool >/dev/null 2>&1; then
        log_info "Installing ethtool..."
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

# ============================================================
#  MSS clamping via iptables
# ============================================================
apply_mss_clamp() {
    log_step "Applying TCP MSS clamping (packet fragmentation resistance)..."

    if ! command -v iptables >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y iptables >/dev/null 2>&1
    fi

    iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500 2>/dev/null || \
        iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500

    iptables -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500 2>/dev/null || \
        iptables -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500

    log_ok "MSS clamped to 500 bytes on FORWARD/OUTPUT chains"
}

# ============================================================
#  TTL randomization (mangle table)
# ============================================================
apply_ttl_randomization() {
    log_step "Applying TTL fingerprint randomization..."

    modprobe xt_TTL >/dev/null 2>&1

    # Standard iptables' TTL target only supports a FIXED --ttl-set value per rule
    # (there is no real per-packet "--ttl-set-random" option in stock iptables).
    # To still vary the fingerprint between deployments/reboots of this script,
    # we pick one random value in the 125-128 range each time this runs.
    local rand_ttl=$(( (RANDOM % 4) + 125 ))

    if ! iptables -t mangle -C OUTPUT -j TTL --ttl-set "$rand_ttl" 2>/dev/null; then
        if iptables -t mangle -A OUTPUT -j TTL --ttl-set "$rand_ttl" 2>/tmp/antidpi_ttl.log; then
            mkdir -p "$STATE_DIR"
            echo "$rand_ttl" > "$STATE_TTL_FILE"
            log_ok "Outbound TTL set to $rand_ttl (mangle/OUTPUT)"
        else
            log_warn "Could not apply TTL target (xt_TTL module unavailable on this kernel - common on some minimal/container kernels). Skipping, non-fatal."
        fi
    else
        log_info "TTL mangle rule already present, skipping duplicate."
    fi
}

# ============================================================
#  Traffic shaping / jitter via tc
# ============================================================
apply_traffic_shaping() {
    local iface="$1"
    log_step "Applying traffic shaping (jitter) on interface: $iface"

    if ! command -v tc >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y iproute2 >/dev/null 2>&1
    fi

    tc qdisc del dev "$iface" root >/dev/null 2>&1

    tc qdisc add dev "$iface" root handle 1: prio
    tc qdisc add dev "$iface" parent 1:3 handle 30: netem delay 10ms 5ms distribution normal

    tc filter add dev "$iface" protocol ip parent 1:0 prio 3 u32 \
        match ip sport 80 0xffff flowid 1:3

    if [[ $? -eq 0 ]]; then
        log_ok "Jitter (10ms +/- 5ms, normal distribution) applied to port 80 traffic on $iface"
    else
        log_warn "tc filter setup reported an issue (non-fatal, check 'tc qdisc show dev $iface')"
    fi
}

# ============================================================
#  Full apply flow (menu option 1) — L3/L4 system tuning
# ============================================================
run_full_optimization() {
    check_root
    log_step "Starting full anti-DPI system optimization..."
    local iface
    iface=$(detect_iface)
    detect_resources
    log_info "Detected primary interface: $iface"
    echo

    install_global_command
    echo
    apply_kernel_tweaks
    echo
    apply_dns_optimization
    echo
    apply_irq_balancing
    echo
    apply_nic_tuning "$iface"
    echo
    apply_mss_clamp
    echo
    apply_ttl_randomization
    echo
    apply_traffic_shaping "$iface"
    echo
    log_ok "L3/L4 system optimizations applied successfully."
    echo -e "${GREEN}${BOLD}Done. Use menu options 2-3 to add the Nginx honeypot or noise generator.${NC}"
}

# ============================================================
#  Section 5: Active probing defense (menu option 2)
# ============================================================
apply_probing_defense() {
    check_root
    log_step "Setting up active-probing defense (Nginx decoy + iptables redirect)..."

    log_info "Installing nginx and iptables-persistent..."
    apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx iptables-persistent >/dev/null 2>&1

    mkdir -p /var/www/antidpi/video/stream
    printf '\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom' > /var/www/antidpi/video/stream/live.mp4

    cat > "$NGINX_CONF" << 'NGINX_EOF'
server {
    listen 8080;
    server_name _;

    location /video/stream/live.mp4 {
        root /var/www/antidpi;
        default_type video/mp4;
        add_header Content-Disposition "inline";
        add_header Cache-Control "no-cache";
    }

    location / {
        return 200 "OK\n";
        default_type text/plain;
    }
}
NGINX_EOF

    if nginx -t >/tmp/antidpi_nginx.log 2>&1; then
        systemctl restart nginx
        systemctl enable nginx >/dev/null 2>&1
        log_ok "Nginx decoy listening on 127.0.0.1:8080"
    else
        log_err "Nginx config test failed; see /tmp/antidpi_nginx.log"
        return 1
    fi

    log_info "Configuring iptables NAT redirection rules for port 80..."
    iptables -t nat -C PREROUTING -p tcp --dport 80 -m string --string "GET /video/stream/live.mp4" --algo bm -j ACCEPT 2>/dev/null || \
        iptables -t nat -A PREROUTING -p tcp --dport 80 -m string --string "GET /video/stream/live.mp4" --algo bm -j ACCEPT

    iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 8080 2>/dev/null || \
        iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 8080

    netfilter-persistent save >/dev/null 2>&1
    log_ok "iptables NAT rules applied and saved persistently"
    echo -e "${GREEN}${BOLD}Honeypot deployed. Probing traffic on port 80 now receives the decoy response.${NC}"
}

# ============================================================
#  Section 6: Background noise generator (menu option 3)
# ============================================================
deploy_noise_generator() {
    check_root
    log_step "Deploying background traffic noise generator..."

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
#  Section 7: Status check (menu option 4)
# ============================================================
check_status() {
    check_root
    log_step "System & DPI Defense Status"
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
    echo

    echo -e "${BOLD}-- DNS resolvers --${NC}"
    if grep -qE "1\.1\.1\.1|8\.8\.8\.8" /etc/resolv.conf 2>/dev/null; then
        log_ok "Optimized DNS resolvers active (1.1.1.1 / 8.8.8.8)"
    else
        log_warn "Optimized DNS resolvers not detected in /etc/resolv.conf"
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
    if iptables -S FORWARD 2>/dev/null | grep -q "TCPMSS"; then
        log_ok "MSS clamping rule present (FORWARD)"
    else
        log_warn "MSS clamping rule not found (FORWARD)"
    fi
    if iptables -t mangle -S OUTPUT 2>/dev/null | grep -q "TTL"; then
        local ttl_val
        ttl_val=$(cat "$STATE_TTL_FILE" 2>/dev/null || echo "unknown")
        log_ok "TTL randomization rule present (current value: $ttl_val)"
    else
        log_warn "TTL randomization rule not found"
    fi
    if iptables -t nat -S PREROUTING 2>/dev/null | grep -q "REDIRECT"; then
        log_ok "Port 80 -> 8080 honeypot redirect rule present"
    else
        log_warn "Port 80 honeypot redirect rule not found"
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

    echo -e "${BOLD}-- Nginx honeypot --${NC}"
    if systemctl is-active nginx >/dev/null 2>&1; then
        log_ok "nginx is running"
        [[ -f "$NGINX_CONF" ]] && log_ok "$NGINX_CONF present" || log_warn "$NGINX_CONF missing"
    else
        log_warn "nginx is not running"
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
#  Section 8: Uninstall / rollback (menu option 6)
# ============================================================
run_uninstall() {
    check_root
    log_step "Rolling back all changes to default settings..."
    echo

    log_info "Removing sysctl configs..."
    rm -f "$SYSCTL_FILE" "$SYSCTL_FILE_LEGACY"
    sysctl --system >/dev/null 2>&1
    log_ok "sysctl reset"

    log_info "Restoring original DNS configuration..."
    chattr -i /etc/resolv.conf 2>/dev/null
    if [[ -f /etc/resolv.conf.antidpi.bak ]]; then
        mv -f /etc/resolv.conf.antidpi.bak /etc/resolv.conf
        log_ok "Original /etc/resolv.conf restored"
    else
        log_info "No DNS backup found, leaving current /etc/resolv.conf as-is."
    fi

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
    iptables -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500 2>/dev/null
    iptables -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp --dport 80 -m string --string "GET /video/stream/live.mp4" --algo bm -j ACCEPT 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 8080 2>/dev/null

    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        del_rule="${rule/-A OUTPUT/-D OUTPUT}"
        eval "iptables -t mangle $del_rule" 2>/dev/null
    done < <(iptables -t mangle -S OUTPUT 2>/dev/null | grep -- "-j TTL")
    rm -f "$STATE_TTL_FILE"

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
    fi
    log_ok "iptables rules removed"

    log_info "Restoring Nginx configuration..."
    if [[ -f "$NGINX_CONF" ]]; then
        rm -f "$NGINX_CONF"
        rm -rf /var/www/antidpi
        nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1
        log_ok "Nginx honeypot removed"
    fi

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
        echo -e "  ${CYAN}1)${NC} Apply Full System & Anti-DPI Optimizations (L3/L4 Tuning)"
        echo -e "  ${CYAN}2)${NC} Install Smart Active-Probing Honeypot (Nginx Layer 7 Defense)"
        echo -e "  ${CYAN}3)${NC} Deploy Background Noise Generator (Traffic Flattening)"
        echo -e "  ${CYAN}4)${NC} Check System & DPI Defense Status"
        echo -e "  ${CYAN}5)${NC} Uninstall & Restore Factory Defaults"
        echo -e "  ${CYAN}6)${NC} Exit"
        echo -e "${BLUE}------------------------------------------------------------${NC}"
        read -rp "$(echo -e "${BOLD}Select [1-6]: ${NC}")" choice
        echo

        case "$choice" in
            1) run_full_optimization ;;
            2) apply_probing_defense ;;
            3) deploy_noise_generator ;;
            4) check_status ;;
            5) run_uninstall ;;
            6) echo -e "${GREEN}Goodbye.${NC}"; exit 0 ;;
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
main_menu
