# Tunnel Checker

A simple Linux tool for measuring bidirectional tunnel-link quality between two servers: packet loss, jitter, throughput, asymmetry, route behavior, MTU, and other signals that ordinary ping can miss.

It is designed for cases such as an Iran server and an overseas server where basic ICMP ping looks normal but tunnels are unstable, slow, or intermittently fail under real traffic.

## What it tests

The Full Test uses the peer as a controlled endpoint and, where supported, checks:

- IPv4 resolution and the local route/source/interface selected for the peer.
- ICMP packet loss, RTT, and RTT variation.
- TCP reachability of the `iperf3` control port.
- TCP single-stream throughput in both directions.
- TCP four-stream throughput in both directions.
- TCP retransmission counters exposed by `iperf3`.
- RTT increase under sustained upload and download load to expose queueing/bufferbloat that idle ping can miss.
- UDP throughput, packet loss, and jitter in both directions at 25%, 50%, and 100% of the expected tunnel bandwidth.
- Local interface errors/drops before and after active traffic tests.
- Path MTU using `tracepath` and IPv4 DF probes.
- MTR route diagnostics with ICMP, TCP, and UDP probes.
- Optional true reverse-path ping/MTR/route diagnostics over an existing SSH connection.
- A final `0-100` tunnel-suitability score, verdict, and evidence-based recommendations.

`iperf3 -R` measures actual data transfer from peer to local, but it does not reveal the Internet route from peer to local. Enable the optional SSH reverse-path step when you need that route measured too.

## Supported systems

Initial release:

- Debian
- Ubuntu
- Bash
- IPv4 for the complete test set

The installer uses distribution packages and keeps dependencies small.

## One-line install

For networks where `raw.githubusercontent.com` may be unreachable, use the jsDelivr-backed installer:

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/ach1992/tunnel-checker@main/install.sh | sudo bash
```

GitHub Raw is also supported:

```bash
curl -fsSL https://raw.githubusercontent.com/ach1992/tunnel-checker/main/install.sh | sudo bash
```

Then open the menu:

```bash
sudo tunnel-checker
```

The installer validates Bash syntax before installing the downloaded main script. The tool's update flow tries GitHub Raw and then jsDelivr as a fallback.

> A one-line `curl | bash` installer executes remote code as root. If you prefer to inspect it first, download `install.sh`, review it, and run it locally.

## Typical two-server workflow

### 1. On the overseas/peer server

Install Tunnel Checker, run:

```bash
sudo tunnel-checker
```

Choose:

```text
3) Start temporary iperf3 test server
```

The default port is `5201`. The server is automatically bounded by a user-selected lifetime; the default is 30 minutes.

Your firewall/provider firewall must allow **TCP and UDP** on the selected `iperf3` port from the testing server. Tunnel Checker deliberately does **not** alter firewall rules.

### 2. On the Iran/testing server

Install and run:

```bash
sudo tunnel-checker
```

Choose:

```text
1) Full tunnel-link test
```

Enter:

- peer IP/hostname;
- the peer's `iperf3` port;
- the bandwidth you actually expect the tunnel to sustain.

The expected bandwidth controls the bounded UDP test rates and helps the score judge whether measured throughput is useful for your intended workload.

### 3. Optional true reverse path

At the end of a Full Test you can allow SSH-assisted reverse diagnostics. Tunnel Checker uses the existing `ssh` client only for that test; it does not collect or store passwords, SSH keys, or tokens.

If SSH is skipped or unavailable, peer-to-local **data transfer** is still tested using `iperf3 -R`, but the exact peer-to-local MTR route is reported as not measured.

## Menu

```text
1) Full tunnel-link test
2) Quick test
3) Start temporary iperf3 test server
4) Stop test server
5) Test server status
6) Update Tunnel Checker
7) Uninstall Tunnel Checker
8) Exit
```

Direct CLI shortcuts are also available:

```bash
tunnel-checker --full
tunnel-checker --quick
tunnel-checker --server
tunnel-checker --stop
tunnel-checker --status
tunnel-checker --update
tunnel-checker --uninstall
tunnel-checker --version
```

## Interpreting results

A tunnel candidate should be judged by the combination of signals, not by ping alone. As a practical starting point:

| Signal | Good starting target |
|---|---:|
| ICMP loss | <= 0.2% |
| UDP loss at intended rate | <= 0.5% |
| RTT variation / jitter | preferably <= 5-10 ms |
| Bidirectional throughput | stable and close to the required workload |
| Direction asymmetry | low enough that the slower direction still meets the workload |
| PMTU | understood and compatible with tunnel overhead |
| Local interface errors/drops | no meaningful increase during the test |

The score is advisory. It is intentionally sensitive to packet loss, jitter, directional asymmetry, usable throughput, MTU problems, and local drops rather than treating low average ping as proof of a healthy tunnel path.

Intermediate MTR hops can rate-limit ICMP responses. Loss on one intermediate hop is not automatically real end-to-end packet loss when later hops and the destination remain healthy.

## Safety

Tunnel Checker does not automatically modify:

- firewall rules;
- routes;
- `sysctl` values;
- tunnel configuration;
- provider/network settings.

`iperf3` has no authentication and can consume bandwidth. The temporary server is time-bounded, but you should still restrict its port to the testing peer using your existing firewall/provider controls whenever possible.

Active throughput tests intentionally generate traffic. Choose an expected bandwidth that is safe for your server/provider plan.

## Reports

When permissions allow, the latest summarized report and route details are written to:

```text
/var/log/tunnel-checker/last-report.txt
```

## Update

From the menu choose:

```text
6) Update Tunnel Checker
```

or run:

```bash
sudo tunnel-checker --update
```

## Uninstall

From the menu choose:

```text
7) Uninstall Tunnel Checker
```

or run:

```bash
sudo tunnel-checker --uninstall
```

The uninstaller removes only Tunnel Checker-owned files and reports. It does **not** remove shared OS packages such as `iperf3`, `mtr`, `jq`, or `iproute2`.

## Project specification

The durable project-level requirements are in [`PROJECT-SPEC.md`](PROJECT-SPEC.md). Live implementation work is tracked in GitHub Issues/PRs.
