# Tunnel Checker

A simple Linux tool for checking whether the network path between two servers is actually suitable for tunneling — not just whether ping works.

It measures packet loss, RTT/jitter, real TCP/UDP transfer, directional asymmetry, loaded latency, routes, MTR destination loss, MTU, and local interface errors/drops, then gives a concise suitability assessment.

## Supported systems

- Debian
- Ubuntu
- Bash
- IPv4 for the complete test set

## One-line install

For restricted networks where `raw.githubusercontent.com` or jsDelivr may time out, use the official GitHub REST API bootstrap:

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: tunnel-checker' 'https://api.github.com/repos/ach1992/tunnel-checker/contents/install.sh?ref=main' | sudo bash
```

The installer and self-update flow try `api.github.com` first, then GitHub Raw, then jsDelivr. Downloads are syntax-validated before installation.

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

The temporary target uses three isolated ports derived from the selected `iperf3` base port (default `5201`):

- base port: `iperf3` TCP control and TCP/UDP data (`5201` by default);
- base + 1: Tunnel Checker-owned TCP continuity/probe listener (`5202` by default);
- base + 2: Tunnel Checker-owned UDP continuity/probe listener (`5203` by default).

Choose a base port from `1` through `65533`. The required TCP/UDP ports must be reachable from the testing peer.

Tunnel Checker deliberately does **not** modify firewall rules. These listeners are unauthenticated test endpoints, so restrict all three ports to the peer IP when practical. Every listener is time-bounded, ownership-checked, and stopped automatically.

## What Full Test measures

- IPv4 resolution and route/source/interface selection.
- ICMP packet loss, average RTT, and variation.
- `iperf3` reachability through a real, bounded protocol session; the active service port is not hit with a raw fake-client probe.
- TCP single-stream throughput in both data directions.
- TCP four-stream throughput in both data directions.
- TCP retransmission counters when available.
- Bounded `iperf3`-independent TCP echo continuity when normal TCP evidence fails or peer-support confirmation is needed.
- UDP loss/jitter in both data directions at 25%, 50%, and 100% of the requested tunnel bandwidth.
- Independent UDP echo evidence when `iperf3` UDP evidence is unavailable, so a TCP-control failure is not misclassified as proof of a bad UDP path.
- RTT increase under **verified** upload/download load.
- Local interface packet errors/drops around the active test window, including the packet-delta denominator and sample adequacy before rate-based interpretation.
- PMTU with IPv4 DF probes and `tracepath`.
- MTR using ICMP, TCP, and UDP probes; TCP/UDP path probes use the isolated diagnostic ports rather than the active `iperf3` service socket.
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

A successful bounded `iperf3` probe establishes protocol reachability without opening a fake client connection with `nc -z`. It still does **not** prove that sustained data is healthy. If normal TCP data fails, Tunnel Checker can run an isolated TCP echo continuity test; a partial transfer that stops making progress until timeout is reported explicitly as a sustained TCP stall.

If that independent TCP test confirms a sustained stall, the **TCP tunnels / proxies** use case can be `UNSUITABLE` even while the overall run remains `INCOMPLETE`. Missing or unrelated UDP evidence is not automatically downgraded with it.

### Ping looks good but sustained data stalls

A healthy ping does not prove that a tunnel-quality data flow is healthy. A real-world endpoint pair used while developing Tunnel Checker produced all of the following at the same time:

- `0%` ICMP loss;
- about `85 ms` stable RTT;
- PMTU `1500`;
- `0%` final-destination loss in ICMP/TCP/UDP MTR;
- successful TCP connection establishment;
- but only a few tens of KiB of real TCP data before the congestion window collapsed and the transfer stalled until timeout.

The same stall was reproduced with a protocol-independent raw TCP transfer, with a small TCP MSS (`536`), and on a separate high TCP port. That combination is strong evidence of a sustained TCP data-path problem under the tested conditions rather than an idle-ping, large-MTU, `iperf3`-parsing, or single-port-only problem.

Do **not** conclude that UDP/WireGuard is bad solely because an `iperf3 -u` test failed in this situation: `iperf3` uses a TCP control session for UDP tests, so a broken control/data session can make UDP evidence unavailable without proving that the UDP path itself is bad.

Starting with `v0.3.0`, Full Test automates the bounded independent TCP continuity check on the peer's isolated diagnostic listener. A confirmed partial transfer followed by no progress until the outer timeout is reported as a sustained TCP data-path stall. If independent TCP completes while `iperf3` fails, the report instead preserves that distinction rather than blaming the general TCP path.

When `iperf3` UDP evidence is missing, `v0.3.0` also uses an isolated UDP echo diagnostic when peer support can be confirmed. A failed `iperf3 -u` run by itself never marks UDP/WireGuard unsuitable.

### MTR warning

Loss on an intermediate router is not automatically real packet loss. Routers commonly rate-limit ICMP/TCP/UDP probe replies. If later hops and the final destination remain at 0% loss, the intermediate percentage should not be interpreted as end-to-end loss.

Starting with `v0.3.0`, TCP/UDP MTR and `tracepath` use the isolated diagnostic ports rather than the active `iperf3` service socket. Full Test therefore no longer creates fake `iperf3` clients through its own reachability or path-probe logic.

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

The uninstaller removes Tunnel Checker-owned files/reports only. Shared OS packages such as `iperf3`, `socat`, `mtr`, `jq`, and `iproute2` remain installed.

## Project specification

Durable requirements: [`PROJECT-SPEC.md`](PROJECT-SPEC.md). Live implementation work is tracked in GitHub Issues/PRs.
