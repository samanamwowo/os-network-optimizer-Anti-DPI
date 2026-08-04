# Complete OS Network Optimization Script

A Bash automation tool for Ubuntu (20.04 / 22.04 / 24.04) and Debian (11 / 12) that applies a set of well-known Linux kernel, network-interface, and TCP/IP stack tuning parameters aimed at improving connection stability, reducing latency variance, and modernizing default congestion control behavior on a server or VPS.

**Author (Telegram):** [@ScriptingGs](https://t.me/ScriptingGs)
**Repository:** https://github.com/samanamwowo/

---

## What this project is

This script automates a collection of standard Linux networking tweaks that are individually documented in the kernel's own `sysctl` and `ethtool`/`tc` documentation, and are commonly used by system administrators to:

- Enable modern TCP congestion control (BBR + `fq` queuing discipline)
- Tune TCP buffer sizes and window scaling for better throughput on high-latency links
- Enable TCP Fast Open
- Adjust NIC offload settings and MSS sizing, which can help with certain MTU/fragmentation-related connectivity issues
- Apply basic traffic-shaping (`tc`) for smoother packet pacing
- Deploy a minimal reverse-proxy pattern in front of port 80 using Nginx

All changes are written to standard, well-known locations (`/etc/sysctl.d/`, `systemd` unit files, `iptables`/`nft` rules) so they are transparent, inspectable, and fully reversible via the built-in uninstall option.

## What this project is not

- It is not malware, a backdoor, or a tool for attacking, intercepting, or degrading other people's systems or networks.
- It does not exfiltrate data, phone home, or communicate with any remote server controlled by the author. Read the source â€” every line is visible and auditable in this repository.
- It does not target, name, or claim to defeat any specific government, agency, or product. Any resemblance to techniques discussed in general networking literature (RFCs, kernel docs, `ethtool`/`tc` man pages) is because those are exactly where these techniques come from.
- It is not intended to facilitate illegal activity, and the author does not encourage using it for any purpose that violates the laws of the jurisdiction in which it is deployed.

## Installation

```bash

```

After the first run, the tool installs itself as a global command:

```bash
sudo anti-dpi
```

## Usage

Running the script (or the `anti-dpi` command) opens an interactive menu:

| Option | Description |
|---|---|
| 1 | Apply the full set of optimizations |
| 2 | Check current status of all applied settings |
| 3 | Fully uninstall and restore default OS settings |
| 4 | Exit |

Every change made by option 1 can be cleanly reverted with option 3 â€” nothing is left behind.

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

Issues and pull requests are welcome. Please keep discussion focused on the technical implementation (kernel parameters, `iptables`/`nft` rules, `systemd` units, etc.).
