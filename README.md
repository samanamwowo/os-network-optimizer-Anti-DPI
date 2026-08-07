# Complete OS Anti-Filtering & DPI Defense Script (Ultra Edition)

A Bash automation tool for Ubuntu (20.04 / 22.04 / 24.04) and Debian (11 / 12) that applies a comprehensive set of Linux kernel and network-interface tuning parameters aimed at improving connection stability, reducing latency variance, resisting network fingerprinting, and modernizing default congestion control behavior on a server or VPS.

**Author (Telegram):** [@ScriptingGs](https://t.me/ScriptingGs)
**Repository:** https://github.com/samanamwowo/os-network-optimizer-Anti-DPI

---

## What this project honestly is

This is a **network/kernel optimizer with a handful of lightweight anti-fingerprinting heuristics** â€” not a full DPI-evasion system. It does not implement Fake-TLS, uTLS/JA3 spoofing, SNI camouflage, TCP segment desync, or QUIC manipulation. Those techniques live in the *proxy protocol layer* (REALITY, Fake-TLS-capable clients, tools like zapret/ByeDPI), not in `sysctl`/`iptables`/`tc`, and this script does not attempt to reimplement them.

What it *does* do, all through standard, documented Linux mechanisms:

- Enable modern TCP congestion control (BBR + `fq`), with an explicit kernel-support check instead of silently failing
- Scale TCP buffer sizes automatically based on detected CPU cores and RAM
- Enable TCP Fast Open, high-concurrency connection handling, TCP keepalive tuning
- Balance network interrupts across CPU cores (skipped automatically on single-core hosts)
- Adjust NIC offload and MSS sizing â€” both configurable, with a confirmation prompt before touching offload on low-core hosts
- Rotate outbound TTL on every run (not a one-time static value)
- Apply `tc` jitter to the port your service actually uses (you're asked which port â€” it never assumes port 80)
- Optionally generate low-volume background HTTP requests, with an explicit disclosure of what that traffic does and does not do
- Persist every `iptables`/`ip6tables` rule it adds across reboots
- Safely update itself from GitHub with syntax validation and automatic backup before replacing anything

All changes are written to standard, well-known locations (`/etc/sysctl.d/`, `systemd` unit files, `iptables` rules) so they are transparent, inspectable, and fully reversible via the built-in uninstall option. A snapshot of `sysctl` and `iptables` state is also saved before every change, for manual reference.

## What this project is not

- It is not malware, a backdoor, or a tool for attacking, intercepting, or degrading other people's systems or networks. Read the source â€” every line is visible and auditable in this repository. It does not exfiltrate data or phone home to anywhere but the GitHub repo it came from (only when you explicitly choose to update).
- It does not target, name, or claim to defeat any specific government, agency, or product.
- It is not intended to facilitate illegal activity, and the author does not encourage using it for any purpose that violates the laws of the jurisdiction in which it is deployed.

## Installation

```bash
git clone https://github.com/samanamwowo/os-network-optimizer-Anti-DPI.git
cd os-network-optimizer-Anti-DPI
chmod +x optimize.sh
sudo ./optimize.sh
```

The global command `anti-dpi` is installed automatically the moment the script starts â€” regardless of which menu option you pick first. From then on:

```bash
sudo anti-dpi
```

âš ï¸ **Manual updates:** always fetch fresh with `curl` and never paste the script's contents directly into a terminal editor (`nano`/`vi`) over SSH from a mobile client â€” long manual pastes can silently truncate heredocs and break the script. (Or just use menu option 5 â€” see below.)

```bash
rm -f optimize.sh
curl -fsSL https://raw.githubusercontent.com/samanamwowo/os-network-optimizer-Anti-DPI/refs/heads/main/optimize.sh -o optimize.sh
bash -n optimize.sh && echo "File is valid"
chmod +x optimize.sh
sudo ./optimize.sh
```

âš ï¸ **Note on automation:** several options ask interactive questions (proxy port, MSS value, whether to disable TCP timestamps/IPv6, confirmation before touching NIC offload on low-core hosts). The script cannot be driven fully unattended (e.g. `curl | sudo bash`) â€” it expects a terminal to answer prompts on. This is intentional: these values genuinely depend on your setup and hardware.

## Usage

| Option | Priority | Description |
|---|---|---|
| 1 | `REQUIRED` | Core kernel hardening â€” sysctl tuning, BBR, resource-aware buffer scaling, IRQ balancing, optional extra-hardening module |
| 2 | `RECOMMENDED` | L3/L4 network manipulation â€” NIC offload disable, MSS clamping, TTL rotation, traffic jitter, optional IPv6 mirror, persisted across reboots |
| 3 | `OPTIONAL` | Background traffic noise generator |
| 4 | `RECOMMENDED` | Comprehensive status & diagnostics |
| 5 | `SYSTEM TOOL` | Update to latest version (safe: validated, backed up, auto-restarts) |
| 6 | `SYSTEM TOOL` | Uninstall and restore factory defaults |
| 7 | â€” | Exit |

Every change made by options 1-3 can be cleanly reverted with option 6 â€” nothing is left behind.

## What each option does

### 1) Core kernel hardening `[REQUIRED]`
- Detects CPU cores and RAM, scales `tcp_rmem`/`tcp_wmem` ceilings accordingly (16MBâ€“128MB)
- Asks whether to disable TCP timestamps (off by default â€” disabling trims a minor fingerprinting vector but can affect PAWS protection above ~1Gbps)
- Asks whether to disable IPv6 entirely (off by default)
- Asks whether to apply the **extra hardening module** â€” a fully separate, fully removable sysctl file (`/etc/sysctl.d/99-antidpi-extra.conf`) adding `rp_filter` anti-spoofing, martian-packet logging, `tcp_slow_start_after_idle=0`, and `tcp_mtu_probing`
- Writes the core sysctl file: BBR + `fq`, TTL 128, disabled ICMP redirects, TCP Fast Open, high-concurrency backlog tuning, keepalive tuning, `tcp_rfc1337`/`ip_dynaddr`
- Explicitly checks whether the running kernel supports the `tcp_bbr` module before claiming success â€” no silent fallback
- Installs `irqbalance`, automatically skipped on single-core hosts (it would refuse to run there anyway)
- Warns, non-fatally, if the detected distro isn't Ubuntu/Debian

### 2) L3/L4 network manipulation `[RECOMMENDED]`
- Asks which port your proxy/service runs on (default 443) â€” jitter targets **this** port, never a hardcoded one
- Asks for an MSS clamp value, 536â€“1460 (default 1360, not the old overly-aggressive 500)
- Asks whether to mirror the MSS clamp to IPv6 via `ip6tables` (skippable â€” IPv4-only was a real gap in earlier versions)
- Before disabling NIC offload, checks CPU core count and asks for confirmation on 1-2 core hosts (disabling offload moves packet segmentation to the CPU and can overload a weak vCPU)
- **Rotates** the outbound TTL (125-128) on every run â€” earlier versions set it once and never touched it again on subsequent runs; fixed
- Applies `tc` jitter (~10ms Â± 5ms) to the chosen port, checking each `tc` step individually and reporting exactly which one failed if any do
- **Persists every rule** added in this option via `iptables-persistent`/`netfilter-persistent save` â€” this was a real gap in earlier versions where rules silently vanished on reboot

### 3) Background traffic generator `[OPTIONAL]`
- Prints an explicit disclosure before deploying: this traffic is separate, ordinary connections â€” **not** injected into your proxy tunnel, does not disguise tunnel traffic, only prevents the server's aggregate traffic graph from looking perfectly idle. You confirm before it installs.
- Verifies `curl` is installed (installing it if missing) before deploying â€” earlier versions assumed it was always present
- Runs as the unprivileged `nobody` user via `systemd`, requesting a rotating list of public sites every 30-180 seconds

### 4) Status check `[RECOMMENDED]`
Reports on: OS distribution, kernel version, virtualization type, BBR status, sysctl config presence (core + extra module), IRQ balancing state, NIC offload/service state, the actual current MSS value in effect, IPv6 mirror status, TTL rotation state, whether rules are actually persisted across reboots, `tc` jitter state, noise-generator service state, and global command availability.

### 5) Update to latest version `[SYSTEM TOOL]`
- Downloads the latest script to a temp file (never touches the running copy directly)
- Validates it with `bash -n` â€” if invalid, aborts and changes nothing
- Compares SHA256 against the currently running version â€” skips if already up to date
- Backs up the current version before replacing it (keeps the 5 most recent backups)
- Replaces both the local file and the global `anti-dpi` command, then restarts itself into the new version automatically

### 6) Uninstall `[SYSTEM TOOL]`
Cleanly reverses every change made by options 1-3: removes both sysctl files (core + extra), disables `irqbalance`, removes the NIC persistence service and re-enables offload, removes the noise generator, flushes all `iptables`/`ip6tables`/`tc` rules added by the script (parsed safely, not with `eval`), and removes the global `anti-dpi` command.

## Reliability details worth knowing

- **`safe_iptables_delete`**: rule removal is done by parsing `iptables -S` output into a real argv array and calling `-D` directly â€” no `eval` on a string built from command output anywhere in this script.
- **apt/dpkg lock awareness**: before installing packages, the script waits (up to 60s) for any concurrent `apt`/`dpkg` process to finish, using `fuser`, falling back to `lsof`, falling back to `flock`, so it still does something useful even on minimal images missing all three.
- **Distro check**: warns (non-fatally) if you're not on Ubuntu/Debian, since the script relies on `apt-get` throughout.

## Pre-change snapshots

Before options 1 and 2 make any change, the script saves a snapshot of `sysctl -a` and `iptables-save` output to `/etc/antidpi/backups/` (timestamped, keeping the 5 most recent of each). This is for manual diffing/reference â€” it is **not** an automatic rollback mechanism. For a guaranteed clean revert, use option 6.

## Requirements

- Root privileges (`sudo`)
- Ubuntu 20.04/22.04/24.04 or Debian 11/12 (other distros will get a warning, not a hard stop, but are untested)
- Standard `apt` package sources reachable from the host
- A terminal to answer interactive prompts

## Disclaimer

This software is provided **"as is"**, without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author be liable for any claim, damages, or other liability arising from the use of this software.

This project is published for **educational and system-administration purposes**. It is the responsibility of anyone who deploys this script to ensure their use of it complies with the laws and regulations applicable to them and to the systems they administer.

## License

MIT License â€” see [`LICENSE`](LICENSE) for details.

## Contributing

Issues and pull requests are welcome. Please keep discussion focused on the technical implementation (kernel parameters, `iptables` rules, `systemd` units, etc.).- Scale TCP buffer sizes automatically based on the host's detected CPU core count and RAM
- Enable TCP Fast Open, high-concurrency connection handling, and TCP keepalive tuning
- Balance network interrupt handling across CPU cores where applicable
- Adjust NIC offload settings and MSS sizing (both configurable, with a confirmation prompt before touching offload on low-core hosts)
- Vary outbound TTL values between deployments to reduce a static OS fingerprint
- Apply traffic-shaping (`tc`) jitter to the port your service actually uses (you're asked which port at runtime — it does not assume port 80)
- Optionally generate low-volume, randomized background HTTP requests, with an explicit disclosure of what that traffic does and does not do

All changes are written to standard, well-known locations (`/etc/sysctl.d/`, `systemd` unit files, `iptables` rules) so they are transparent, inspectable, and fully reversible via the built-in uninstall option. A snapshot of `sysctl` and `iptables` state is also saved before every change, for manual reference.

## What this project is not

- It is not malware, a backdoor, or a tool for attacking, intercepting, or degrading other people's systems or networks.
- It does not exfiltrate data, phone home, or communicate with any remote server controlled by the author. Read the source — every line is visible and auditable in this repository.
- It does not target, name, or claim to defeat any specific government, agency, or product. Any resemblance to techniques discussed in general networking literature (RFCs, kernel docs, `ethtool`/`tc`/`iptables` man pages) is because those are exactly where these techniques come from.
- **It is a network/kernel optimizer with a few lightweight anti-fingerprinting heuristics — not a full DPI-evasion system.** It does not implement Fake-TLS, uTLS/JA3 spoofing, SNI camouflage, QUIC manipulation, or fragmentation-based protocol obfuscation. If you need those, pair this script with a proxy protocol that implements them (e.g. REALITY, Fake-TLS-capable proxies) — this script only tunes the underlying OS around them.
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

> **Coming from an older version that had the DNS or Honeypot modules?** Run `Uninstall` on the *old* script first, before replacing it with the current version — the current version's uninstall option no longer knows how to clean up components it no longer contains.

⚠️ **Note on automation:** several options now ask interactive questions (proxy port, MSS value, whether to disable TCP timestamps/IPv6, confirmation before touching NIC offload on low-core hosts). This means the script can no longer be driven fully unattended (e.g. piped through `curl | sudo bash`) — it expects a terminal to answer prompts on. This is intentional: those values genuinely depend on your setup and hardware, and guessing them wrong was causing real problems (see Changelog).

## Usage

Running the script (or the `anti-dpi` command) opens an interactive menu. Each option is tagged with a priority so you know what's essential versus optional:

| Option | Priority | Description |
|---|---|---|
| 1 | `REQUIRED` | Core kernel hardening — sysctl tuning, BBR, resource-aware buffer scaling, IRQ balancing |
| 2 | `RECOMMENDED` | L3/L4 network manipulation — NIC offload disable, MSS clamping, TTL randomization, traffic jitter |
| 3 | `OPTIONAL` | Background traffic noise generator |
| 4 | `RECOMMENDED` | Comprehensive status & diagnostics |
| 5 | `SYSTEM TOOL` | Uninstall and restore factory defaults |
| 6 | — | Exit |

Every change made by options 1-3 can be cleanly reverted with option 5 — nothing is left behind.

## What each option does

### 1) Core kernel hardening `[REQUIRED]`
- Detects CPU core count and RAM, then scales `tcp_rmem` / `tcp_wmem` buffer ceilings accordingly (16MB on modest hosts, up to 128MB on larger ones)
- Asks whether to disable TCP timestamps (off by default — disabling trims a minor fingerprinting vector but can affect PAWS protection on links above ~1Gbps)
- Asks whether to disable IPv6 entirely (off by default)
- Writes kernel parameters to `/etc/sysctl.d/99-antidpi-ultimate.conf`: BBR + `fq` congestion control, TTL set to 128, disabled ICMP redirects, TCP Fast Open, high-concurrency backlog tuning, TCP keepalive tuning, and `tcp_rfc1337` / `ip_dynaddr`
- Explicitly checks whether the running kernel actually supports the `tcp_bbr` module before claiming success — if it doesn't, you're told plainly instead of the script silently continuing with a different congestion control algorithm
- Installs and enables `irqbalance` to spread interrupt handling across CPU cores — automatically **skipped** on single-core hosts, since `irqbalance` is not effective there and will exit on its own

### 2) L3/L4 network manipulation `[RECOMMENDED]`
- Asks which port your proxy/service actually runs on (default 443) — the traffic jitter targets **this** port, not a hardcoded one. Earlier versions of this script applied jitter to port 80 unconditionally, which had no effect on proxy traffic running elsewhere; this is now fixed.
- Asks for an MSS clamp value between 536-1460 (default 1360). Earlier versions hardcoded 500, which needlessly increased packet-per-second overhead and could measurably reduce throughput; 1360 is a much more reasonable default and you can tune it further.
- Before disabling NIC hardware offload (`tso`/`gso`/`gro`), checks CPU core count — on hosts with 1-2 cores, warns that moving packet segmentation from the NIC to the CPU can push a weak vCPU to 100% under load, and asks for explicit confirmation before proceeding
- Sets outbound TTL to a randomly chosen value between 125-128 each time this option runs (note: standard `iptables` only supports a fixed `--ttl-set` value per rule — there is no true per-packet randomization built into stock `iptables` — this approximates fingerprint variation between deployments)

### 3) Background traffic generator `[OPTIONAL]`
- Before deploying, prints an explicit disclosure: this traffic is separate, ordinary connections from the host — it is **not** injected into your proxy tunnel and does not disguise tunnel traffic. It only prevents the server's aggregate traffic graph from looking perfectly idle. You're asked to confirm before it's installed.
- Installs a lightweight `systemd` service (`antidpi-noise.service`) running as the unprivileged `nobody` user
- Periodically (every 30-180 seconds, randomized) sends a GET request to a rotating list of well-known public sites with a randomized User-Agent

### 4) Status check `[RECOMMENDED]`
Reports on: OS distribution, kernel version, virtualization type, BBR status, sysctl config presence, IRQ balancing state (with single-core detection), NIC offload/service state, the actual current MSS value in effect, TTL randomization state, `tc` jitter state, noise-generator service state, and whether the global `anti-dpi` command is installed.

### 5) Uninstall `[SYSTEM TOOL]`
Cleanly reverses every change made by options 1-3: removes the sysctl file, disables `irqbalance`, removes the NIC persistence service and re-enables offload, removes the noise generator, flushes all `iptables`/`tc` rules added by the script (dynamically, so it correctly removes whatever MSS/TTL values were actually configured — not just a hardcoded default), and removes the global `anti-dpi` command.

## Pre-change snapshots

Before options 1 and 2 make any change, the script saves a snapshot of `sysctl -a` and `iptables-save` output to `/etc/antidpi/backups/` (timestamped, keeping the 5 most recent of each). This is for manual diffing/reference if you want to see exactly what changed — it is **not** an automatic rollback mechanism. For a guaranteed clean revert, use option 5 (Uninstall).

## Requirements

- Root privileges (`sudo`)
- Ubuntu 20.04/22.04/24.04 or Debian 11/12
- Standard `apt` package sources reachable from the host
- A terminal to answer interactive prompts (see the automation note above)

## Disclaimer

This software is provided **"as is"**, without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the author be liable for any claim, damages, or other liability arising from the use of this software.

This project is published for **educational and system-administration purposes**. It is the responsibility of anyone who deploys this script to ensure their use of it complies with the laws and regulations applicable to them and to the systems they administer. The author does not operate, control, or have visibility into how any downstream user deploys this code.

## License

MIT License — see [`LICENSE`](LICENSE) for details.

## Contributing

Issues and pull requests are welcome. Please keep discussion focused on the technical implementation (kernel parameters, `iptables` rules, `systemd` units, etc.).d +x optimize.sh
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
