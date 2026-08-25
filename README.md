# Tunnel Checker

A simple Linux tool for checking whether the network path between two servers is actually suitable for tunneling — not just whether ping works.

It measures packet loss, RTT/jitter, real TCP/UDP transfer, directional asymmetry, loaded latency, routes, MTR destination loss, MTU, and local interface errors/drops, then gives a concise suitability assessment.

## Supported systems

- Debian
- Ubuntu
- Bash
- IPv4 for the complete test set

## One-line install

Recommended where GitHub Raw may be blocked:

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/ach1992/tunnel-checker@main/install.sh | sudo bash
```

GitHub Raw:

```bash
curl -fsSL https://raw.githubusercontent.com/ach1992/tunnel-checker/main/install.sh | sudo bash
```

Run:

```bash
sudo tunnel-checker
```

On first interactive launch, choose whether that machine is the **Iran** or **Foreign** endpoint. The role is saved and can be changed later from the menu.

## Recommended two-sided workflow

No SSH setup is required.

### Pass 1 — Iran -> Foreign perspective

On the Foreign server:

1. Run `sudo tunnel-checker`.
2. Confirm its role is `FOREIGN`.
3. Choose **Prepare this server as test target**.

On the Iran server:

1. Confirm its role is `IRAN`.
2. Choose **Full test: IRAN->FOREIGN**.

### Pass 2 — Foreign -> Iran perspective

Swap sides.

On the Iran server, prepare it as the temporary test target. Then on the Foreign server run **Full test: FOREIGN->IRAN**.

This second pass matters because `iperf3 -R` can send data in the reverse direction, but route/MTR/PMTU diagnostics are still measured from the host running the test. Running Full Test from both endpoints gives both real path perspectives without SSH.

## Firewall requirement

The temporary target uses `iperf3` (default port `5201`). TCP and UDP on the selected port must be reachable from the other endpoint.

Tunnel Checker deliberately does **not** modify firewall rules. `iperf3` has no authentication, so restrict the test port to the peer IP when practical. The server is time-bounded and stops automatically.

## What Full Test measures

- IPv4 resolution and route/source/interface selection.
- ICMP packet loss, average RTT, and variation.
- `iperf3` control-port reachability.
- TCP single-stream throughput in both data directions.
- TCP four-stream throughput in both data directions.
- TCP retransmission counters when available.
- UDP loss/jitter in both data directions at 25%, 50%, and 100% of the requested tunnel bandwidth.
- RTT increase under **verified** upload/download load.
- Local interface packet errors/drops around the active test window.
- PMTU with IPv4 DF probes and `tracepath`.
- MTR using ICMP, TCP, and UDP probes.
- Destination loss summarized separately from intermediate-hop probe loss.

Raw MTR/trace output is shown after the concise assessment for deeper diagnosis.

## Result interpretation

A complete Full Test prints a metric table, evidence confidence, optional 0–100 score, recommendations, and a compact use-case table similar to:

```text
USE CASE                    ASSESSMENT     BASIS
------------------------------------------------------------------------------------------
TCP tunnels / proxies       SUITABLE       slow side 52.0 Mbps
UDP tunnels (e.g. WG)       SUITABLE       loss 0.10%, jitter 2.1 ms
Interactive / realtime      CAUTION        RTT 85 ms; loaded RTT +18 ms
Bulk / high bandwidth       SUITABLE       slow side 55 / 50 Mbps target
MTU-sensitive tunnels       SUITABLE       path MTU 1500 bytes
Overall endpoint pair       SUITABLE       score 87/100; run peer test too
```

If essential TCP/UDP tests do not complete, Tunnel Checker intentionally reports:

```text
Score: N/A
Verdict: INCOMPLETE
Evidence confidence: LOW
```

It does **not** turn missing data into a misleading numerical score.

A reachable `iperf3` port only proves that the control socket is open. If the real data test fails, Tunnel Checker reports a bounded error reason so version mismatch, busy server, protocol failure, or other tool/network problems are visible.

### MTR warning

Loss on an intermediate router is not automatically real packet loss. Routers commonly rate-limit ICMP/TCP/UDP probe replies. If later hops and the final destination remain at 0% loss, the intermediate percentage should not be interpreted as end-to-end loss.

## Menu

The exact test direction depends on the saved endpoint role:

```text
1) Full test: IRAN->FOREIGN
2) Quick test: IRAN->FOREIGN
3) Prepare this IRAN server as test target
4) Stop test server
5) Test server status
6) Change endpoint role
7) Show last summary
8) Update Tunnel Checker
9) Uninstall Tunnel Checker
0) Exit
```

CLI shortcuts:

```bash
tunnel-checker --full
tunnel-checker --quick
tunnel-checker --server
tunnel-checker --stop
tunnel-checker --status
tunnel-checker --role
tunnel-checker --last
tunnel-checker --update
tunnel-checker --uninstall
tunnel-checker --version
```

## Practical targets

These are starting points, not universal guarantees:

| Signal | Good starting target |
|---|---:|
| ICMP loss | <= 0.2% |
| UDP loss at intended rate | <= 0.5% |
| RTT variation/jitter | preferably <= 5-10 ms |
| Bidirectional throughput | stable and close to required workload |
| Direction asymmetry | slower direction still meets workload |
| PMTU | known and compatible with tunnel overhead |
| Local errors/drops | no meaningful increase during active testing |

## Safety

Tunnel Checker does not automatically modify:

- firewall rules;
- routes;
- `sysctl` values;
- tunnel configuration;
- provider/network settings.

Active throughput tests generate real traffic. Choose an expected bandwidth appropriate for the server/provider plan.

## Reports

Latest concise summary:

```text
/var/log/tunnel-checker/last-report.txt
```

View it from the menu or with:

```bash
sudo tunnel-checker --last
```

## Update

```bash
sudo tunnel-checker --update
```

## Uninstall

```bash
sudo tunnel-checker --uninstall
```

The uninstaller removes Tunnel Checker-owned files/reports only. Shared OS packages such as `iperf3`, `mtr`, `jq`, and `iproute2` remain installed.

## Project specification

Durable requirements: [`PROJECT-SPEC.md`](PROJECT-SPEC.md). Live implementation work is tracked in GitHub Issues/PRs.
