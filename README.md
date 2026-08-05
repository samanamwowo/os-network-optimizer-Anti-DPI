# Complete OS Anti-Filtering & DPI Defense Script (Ultra Edition)

A Bash automation tool for Ubuntu (20.04 / 22.04 / 24.04) and Debian (11 / 12) that applies a comprehensive set of Linux kernel and network-interface tuning parameters aimed at improving connection stability, reducing latency variance, resisting network fingerprinting, and modernizing default congestion control behavior on a server or VPS.

**Author (Telegram):** [@ScriptingGs](https://t.me/ScriptingGs)
**Repository:** https://github.com/samanamwowo/os-network-optimizer-Anti-DPI

---

## What this project is

This script automates a collection of standard Linux networking tweaks that are individually documented in the kernel's own `sysctl` and `ethtool`/`tc` documentation, and are commonly used by system administrators to:

- Enable modern TCP congestion control (BBR + `fq` queuing discipline)
- Scale TCP buffer sizes automatically based on the host's detected CPU core count and RAM
- Enable TCP Fast Open, high-concurrency connection handling, and TCP keepalive tuning
- Balance network interrupt handling across CPU cores where applicable
- Adjust NIC offload settings and MSS sizing, which can help with certain MTU/fragmentation-related connectivity issues
- Vary outbound TTL values between deployments to reduce a static OS fingerprint
- Apply basic traffic-shaping (`tc`) for smoother, less uniform packet pacing
- Optionally generate low-volume, randomized background HTTP requests to avoid a perfectly flat/idle traffic profile

All changes are written to standard, well-known locations (`/etc/sysctl.d/`, `systemd` unit files, `iptables` rules) so they are transparent, inspectable, and fully reversible via the built-in uninstall option.

## What this project is not

- It is not malware, a backdoor, or a tool for attacking, intercepting, or degrading other people's systems or networks.
- It does not exfiltrate data, phone home, or communicate with any remote server controlled by the author. Read the source â€” every line is visible and auditable in this repository.
- It does not target, name, or claim to defeat any specific government, agency, or product. Any resemblance to techniques discussed in general networking literature (RFCs, kernel docs, `ethtool`/`tc`/`iptables` man pages) is because those are exactly where these techniques come from.
- It is not intended to facilitate illegal activity, and the author does not encourage using it for any purpose that violates the laws of the jurisdiction in which it is deployed.

## Installation

```bash
git clone https://github.com/samanamwowo/os-network-optimizer-Anti-DPI.git
cd os-network-optimizer-Anti-DPI
chmod +x optimize.sh
sudo ./optimize.sh
```

After the first run, the tool installs itself as a global command:

```bash
sudo anti-dpi
```

âš ï¸ **Updating:** always fetch the script fresh with `curl` and never paste its contents directly into a terminal editor (`nano`/`vi`) over SSH from a mobile client â€” long manual pastes can silently truncate or corrupt heredocs and break the script.

```bash
rm -f optimize.sh
curl -fsSL https://raw.githubusercontent.com/samanamwowo/os-network-optimizer-Anti-DPI/refs/heads/main/optimize.sh -o optimize.sh
bash -n optimize.sh && echo "File is valid"
chmod +x optimize.sh
sudo ./optimize.sh
```

> **Coming from an older version that had the DNS or Honeypot modules?** Run `Uninstall` on the *old* script first, before replacing it with the current version â€” the current version's uninstall option no longer knows how to clean up components it no longer contains (locked `/etc/resolv.conf`, the old `unbound`/`nginx` services, related `iptables` rules). Cleaning up with the old script first avoids leaving orphaned configuration behind.

## Usage

Running the script (or the `anti-dpi` command) opens an interactive menu. Each option is tagged with a priority so you know what's essential versus optional:

| Option | Priority | Description |
|---|---|---|
| 1 | `REQUIRED` | Core kernel hardening â€” sysctl tuning, BBR, resource-aware buffer scaling, IRQ balancing |
| 2 | `RECOMMENDED` | L3/L4 network manipulation â€” NIC offload disable, MSS clamping, TTL randomization, traffic jitter |
| 3 | `OPTIONAL` | Background traffic noise generator |
| 4 | `RECOMMENDED` | Comprehensive status & diagnostics |
| 5 | `SYSTEM TOOL` | Uninstall and restore factory defaults |
| 6 | â€” | Exit |

Every change made by options 1-3 can be cleanly reverted with option 5 â€” nothing is left behind.

## What each option does

### 1) Core kernel hardening `[REQUIRED]`
- Detects CPU core count and RAM, then scales `tcp_rmem` / `tcp_wmem` buffer ceilings accordingly (16MB on modest hosts, up to 128MB on larger ones)
- Writes kernel parameters to `/etc/sysctl.d/99-antidpi-ultimate.conf`: BBR + `fq` congestion control, disabled TCP timestamps, TTL set to 128, disabled ICMP redirects, TCP Fast Open, high-concurrency backlog tuning, TCP keepalive tuning, and `tcp_rfc1337` / `ip_dynaddr`
- Installs and enables `irqbalance` to spread interrupt handling across CPU cores â€” automatically **skipped** on single-core hosts, since `irqbalance` is not effective there and will exit on its own; this is expected behavior, not an error

### 2) L3/L4 network manipulation `[RECOMMENDED]`
- Disables NIC hardware offload (`tso`/`gso`/`gro`) via `ethtool`, with a `systemd` service to persist this across reboots
- Applies TCP MSS clamping (500 bytes) via `iptables`
- Sets outbound TTL to a randomly chosen value between 125-128 each time this option runs (note: standard `iptables` only supports a fixed `--ttl-set` value per rule â€” there is no true per-packet randomization built into stock `iptables` â€” this approximates fingerprint variation between deployments)
- Applies `tc`-based jitter (~10ms Â± 5ms, normal distribution) to port 80 traffic to avoid a perfectly uniform packet timing pattern

### 3) Background traffic generator `[OPTIONAL]`
- Installs a lightweight `systemd` service (`antidpi-noise.service`) running as the unprivileged `nobody` user
- Periodically (every 30-180 seconds, randomized) sends a GET request to a rotating list of well-known public sites with a randomized User-Agent, to avoid the host's traffic graph looking perfectly idle between periods of real use

### 4) Status check `[RECOMMENDED]`
Reports on: OS distribution, kernel version, virtualization type, BBR status, sysctl config presence, IRQ balancing state (with single-core detection), NIC offload/service state, MSS/TTL `iptables` rules, `tc` jitter state, noise-generator service state, and whether the global `anti-dpi` command is installed.

### 5) Uninstall `[SYSTEM TOOL]`
Cleanly reverses every change made by options 1-3: removes the sysctl file, disables `irqbalance`, removes the NIC persistence service and re-enables offload, removes the noise generator, flushes all `iptables`/`tc` rules added by the script, and removes the global `anti-dpi` command.

## Requirements

- Root privileges (`sudo`)
- Ubuntu 20.04/22.04/24.04 or Debian 11/12
- Standard `apt` package sources reachable from the host

## Disclaimer

This software is provided **"as is"**, without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author be liable for any claim, damages, or other liability arising from the use of this software.

This project is published for **educational and system-administration purposes**. It is the responsibility of anyone who deploys this script to ensure their use of it complies with the laws and regulations applicable to them and to the systems they administer. The author does not operate, control, or have visibility into how any downstream user deploys this code.

## License

MIT License â€” see [`LICENSE`](LICENSE) for details.

## Contributing

Issues and pull requests are welcome. Please keep discussion focused on the technical implementation (kernel parameters, `iptables` rules, `systemd` units, etc.).- Enable TCP Fast Open and high-concurrency connection handling (`somaxconn`, backlog tuning)
- Optimize DNS resolution with fast, reliable resolvers
- Balance network interrupt handling across CPU cores where applicable
- Adjust NIC offload settings and MSS sizing, which can help with certain MTU/fragmentation-related connectivity issues
- Vary outbound TTL values between deployments to reduce a static OS fingerprint
- Apply basic traffic-shaping (`tc`) for smoother, less uniform packet pacing
- Deploy a minimal decoy web response in front of an internal port to answer unsolicited/automated probes with an innocuous page instead of exposing the underlying service
- Optionally generate low-volume, randomized background HTTP requests to avoid a perfectly flat/idle traffic profile

All changes are written to standard, well-known locations (`/etc/sysctl.d/`, `systemd` unit files, `iptables` rules) so they are transparent, inspectable, and fully reversible via the built-in uninstall option.

## What this project is not

- It is not malware, a backdoor, or a tool for attacking, intercepting, or degrading other people's systems or networks.
- It does not exfiltrate data, phone home, or communicate with any remote server controlled by the author. Read the source — every line is visible and auditable in this repository.
- It does not target, name, or claim to defeat any specific government, agency, or product. Any resemblance to techniques discussed in general networking literature (RFCs, kernel docs, `ethtool`/`tc`/`iptables` man pages) is because those are exactly where these techniques come from.
- It is not intended to facilitate illegal activity, and the author does not encourage using it for any purpose that violates the laws of the jurisdiction in which it is deployed.

## Installation

```bash
git clone https://github.com/samanamwowo/os-network-optimizer-Anti-DPI.git
cd os-network-optimizer-Anti-DPI
chmod +x optimize.sh
sudo ./optimize.sh
```

After the first run, the tool installs itself as a global command:

```bash
sudo anti-dpi
```

⚠️ **Updating:** always fetch the script fresh with `curl` and never paste its contents directly into a terminal editor (`nano`/`vi`) over SSH from a mobile client — long manual pastes can silently truncate or corrupt heredocs and break the script.

```bash
rm -f optimize.sh
curl -fsSL https://raw.githubusercontent.com/samanamwowo/os-network-optimizer-Anti-DPI/refs/heads/main/optimize.sh -o optimize.sh
bash -n optimize.sh && echo "File is valid"
chmod +x optimize.sh
sudo ./optimize.sh
```

## Usage

Running the script (or the `anti-dpi` command) opens an interactive menu:

| Option | Description |
|---|---|
| 1 | Apply full system optimizations — kernel/sysctl tuning, DNS, IRQ balancing, NIC offload, MSS clamping, TTL variation, and traffic-shaping jitter |
| 2 | Install the active-probing decoy (Nginx-based Layer 7 response for unsolicited traffic) |
| 3 | Deploy the background traffic generator (low-volume randomized requests to public sites) |
| 4 | Run a full status/health check across every component |
| 5 | Fully uninstall and restore default OS settings |
| 6 | Exit |

Every change made by options 1-3 can be cleanly reverted with option 5 — nothing is left behind.

## What each option does

### 1) Full system optimizations
- Detects CPU core count and RAM, then scales `tcp_rmem` / `tcp_wmem` buffer ceilings accordingly (16MB on modest hosts, up to 128MB on larger ones)
- Writes kernel parameters to `/etc/sysctl.d/99-antidpi-ultra.conf`: BBR + `fq` congestion control, disabled TCP timestamps, TTL set to 128, TCP Fast Open, `somaxconn`/backlog tuning for high concurrency, and `tcp_rfc1337` / `ip_dynaddr`
- Points DNS at `1.1.1.1` and `8.8.8.8` and locks `/etc/resolv.conf` against being silently overwritten by other services (with automatic backup/restore of your original config)
- Installs and enables `irqbalance` to spread interrupt handling across CPU cores — automatically **skipped** on single-core hosts, since `irqbalance` is not effective there and will exit on its own; this is expected behavior, not an error
- Disables NIC hardware offload (`tso`/`gso`/`gro`) via `ethtool`, with a `systemd` service to persist this across reboots
- Applies TCP MSS clamping (500 bytes) via `iptables`
- Sets outbound TTL to a randomly chosen value between 125-128 each time the script runs (note: standard `iptables` only supports a fixed `--ttl-set` value per rule — there is no true per-packet randomization built into stock `iptables` — this approximates fingerprint variation between deployments)
- Applies `tc`-based jitter (~10ms ± 5ms, normal distribution) to port 80 traffic to avoid a perfectly uniform packet timing pattern

### 2) Active-probing decoy
- Installs Nginx bound to an internal port and serves a benign, valid-looking response
- Configures `iptables` NAT rules so that only requests matching a specific known pattern reach the real service; everything else on port 80 is answered by the decoy
- Persists the rules with `netfilter-persistent`

### 3) Background traffic generator
- Installs a lightweight `systemd` service (`antidpi-noise.service`) running as the unprivileged `nobody` user
- Periodically (every 30-180 seconds, randomized) sends a GET request to a rotating list of well-known public sites with a randomized User-Agent, to avoid the host's traffic graph looking perfectly idle between periods of real use

### 4) Status check
Reports on: BBR status, sysctl config presence, DNS resolver config, IRQ balancing state (with single-core detection), NIC offload/service state, MSS/TTL/redirect `iptables` rules, `tc` jitter state, Nginx decoy state, noise-generator service state, and whether the global `anti-dpi` command is installed.

### 5) Uninstall
Cleanly reverses every change made by options 1-3: removes the sysctl file, restores the original `/etc/resolv.conf`, disables `irqbalance`, removes the NIC persistence service and re-enables offload, removes the noise generator, flushes all `iptables`/`tc` rules added by the script, removes the Nginx decoy config, and removes the global `anti-dpi` command.

## Requirements

- Root privileges (`sudo`)
- Ubuntu 20.04/22.04/24.04 or Debian 11/12
- Standard `apt` package sources reachable from the host

## Disclaimer

This software is provided **"as is"**, without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author be liable for any claim, damages, or other liability arising from the use of this software.

This project is published for **educational and system-administration purposes**. It is the responsibility of anyone who deploys this script to ensure their use of it complies with the laws and regulations applicable to them and to the systems they administer. The author does not operate, control, or have visibility into how any downstream user deploys this code.

## License

MIT License — see [`LICENSE`](LICENSE) for details.

## Contributing

Issues and pull requests are welcome. Please keep discussion focused on the technical implementation (kernel parameters, `iptables`/`nft` rules, `systemd` units, etc.).
