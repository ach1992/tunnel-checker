# Tunnel Checker — Project Specification

## Purpose

Tunnel Checker is a small Bash-based network diagnostic tool for evaluating whether the network path between two Linux servers is suitable and stable enough for tunneling workloads.

The primary use case is testing an Iran server against an overseas server when basic ping works but real tunnels are unstable, slow, asymmetric, or intermittently fail.

This file is the canonical source for project-level intent and durable requirements. Live work belongs in GitHub Issues/PRs; implementation details belong in code and README documentation.

## Product outcome

A user can install Tunnel Checker with one command on a supported server, open a simple management menu, prepare either endpoint for testing, run practical link-quality tests between the two servers, and receive a readable final assessment with actionable recommendations.

## Supported environment

Initial release target:

- Linux servers using Debian or Ubuntu.
- Bash shell.
- IPv4 is required for the complete initial test set.
- IPv6 may be reported/detected where available, but complete IPv6 parity is not required for the first release.
- Root/sudo is required for installation and package management; ordinary diagnostics should use the minimum privileges needed by the underlying tools.

## Core requirements

### Installation and lifecycle

- Provide a one-line installer.
- Install into a predictable system location and expose a `tunnel-checker` command.
- Detect and install only required OS packages when missing.
- Support an update path from the management menu.
- Provide an uninstaller.
- Uninstall only files owned by Tunnel Checker; do not remove shared packages installed by the OS/package manager.
- Support a GitHub-hosted source plus a practical CDN fallback so installation is still possible when `raw.githubusercontent.com` is inaccessible.

### Management menu

Provide a simple terminal menu for:

1. Full tunnel-link test.
2. Quick test.
3. Start temporary iperf3 test server.
4. Stop test server.
5. Show test-server status.
6. Update Tunnel Checker.
7. Uninstall Tunnel Checker.
8. Exit.

The script should ask interactively for values it genuinely needs and provide safe defaults wherever possible.

### Network diagnostics

The full test should cover the practical paths and failure modes that can make a tunnel fail even when ordinary ping looks healthy.

Required diagnostics, when the local environment and peer permit them:

- Peer reachability and address resolution.
- Local route/interface/source-address information toward the peer.
- ICMP latency and packet loss over a meaningful sample.
- RTT minimum/average/maximum and jitter/variation.
- TCP reachability to the iperf3 test port.
- TCP single-stream throughput, local -> peer.
- TCP single-stream throughput, peer -> local using iperf3 reverse mode.
- TCP parallel-stream throughput in both directions.
- TCP retransmission information when exposed by iperf3.
- UDP throughput/loss/jitter in both directions at bounded user-selected or automatically chosen rates.
- ICMP MTR path analysis.
- TCP MTR path analysis where supported.
- UDP MTR path analysis where supported.
- `tracepath`/equivalent path-MTU information where available.
- Path MTU discovery using non-fragmenting ICMP probes with bounded search where supported.
- Local interface packet/error/drop counters before and after the active transfer tests when discoverable.
- Detection of asymmetric performance between directions.
- Clear distinction between an unavailable/blocked diagnostic and an actual failed link test.

### Optional true reverse-path diagnostics

iperf3 reverse mode measures data flow in the opposite direction but does not reveal the Internet route from the remote server back to the local server.

The tool may optionally use an existing SSH connection to the peer to run reverse-side ping/MTR/route diagnostics. It must not collect, store, or embed passwords, private keys, or other credentials. If SSH is unavailable, the report must state that true reverse-path route diagnostics were not measured rather than pretending that they were.

### Test safety

- Active tests must be bounded in duration and bandwidth.
- The user should be able to choose or accept a sensible maximum expected tunnel bandwidth.
- A temporary iperf3 server must not be silently left running forever.
- Starting the test server must clearly state that the selected TCP/UDP port must be reachable from the peer and that an exposed iperf3 service can consume bandwidth.
- Tunnel Checker must not silently modify firewall rules, routing, sysctl, tunnel configuration, or production network configuration.
- Commands that are unavailable on a distribution/version should degrade gracefully and be reported as skipped/unsupported.

## Results and scoring

At the end of a full test, print a readable terminal report containing at minimum:

- Metric/test name.
- Forward result.
- Reverse result where applicable.
- Health state (`GOOD`, `WARN`, `BAD`, or `N/A`).
- A combined tunnel-suitability score from 0–100.
- Overall verdict such as `EXCELLENT`, `GOOD`, `MARGINAL`, or `POOR`.
- Concise recommendations derived from actual observations.

The score is advisory, not a guarantee. Packet loss, jitter, sustained throughput, bidirectional asymmetry, MTU problems, and path instability should influence the verdict more strongly than raw ping alone.

Thresholds must be centralized in the script so future tuning does not require rewriting reporting logic.

## Quick test

Quick test should be deliberately lightweight and include only high-signal checks such as:

- route/reachability;
- short ping sample;
- TCP port reachability;
- short TCP throughput in both directions when iperf3 is available;
- concise verdict.

It should not run the full multi-rate UDP/path suite.

## User experience

- English source/UI for the initial release.
- Color output when attached to a compatible terminal, with a readable no-color fallback.
- Clear progress while tests run.
- Avoid dumping raw command output unless it is useful; summarize primary metrics and show detailed route diagnostics in a separate section.
- Store no sensitive credentials.
- Temporary report files must be bounded and safe.

## Non-goals for the initial release

- Creating or managing tunnels.
- Changing firewall configuration automatically.
- Continuous monitoring/daemon mode.
- Web UI.
- Central server, telemetry, accounts, or cloud service.
- Benchmarking the public Internet in general; the focus is the path between the two user-controlled endpoints.
- Perfect diagnosis of carrier filtering or traffic shaping when it cannot be proven by available measurements.

## Completion criteria

The initial project outcome is complete when:

1. A fresh supported Debian/Ubuntu server can install the tool using a documented one-line command.
2. `tunnel-checker` opens the management menu.
3. The peer can run a bounded temporary iperf3 server from the same tool.
4. Quick and Full tests execute without destructive network changes.
5. Full test measures the required available bidirectional data/path signals and explicitly marks unavailable diagnostics.
6. The final report provides a score, verdict, directional metrics, and evidence-based recommendations.
7. Update and uninstall flows work without removing unrelated/shared system files.
8. README documents installation, two-server usage, firewall/iperf exposure, interpretation, and uninstall.
