# Tunnel Checker

Tunnel Checker answers one practical question quickly:

> **Is this Iran server ↔ this specific Foreign server path likely good enough for tunneling/data transfer?**

A good ping is not enough. Iran-side filtering/routing can make one Foreign IP work normally while another stalls or fails. Tunnel Checker tests the actual pair and gives a compact **0–100 readiness score**, confidence, and a direct recommendation.

## Install

Recommended for restricted networks:

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: tunnel-checker' 'https://api.github.com/repos/ach1992/tunnel-checker/contents/install.sh?ref=main' | sudo bash
```

Alternatives:

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/ach1992/tunnel-checker@main/install.sh | sudo bash
```

```bash
curl -fsSL https://raw.githubusercontent.com/ach1992/tunnel-checker/main/install.sh | sudo bash
```

Run:

```bash
sudo tunnel-checker
```

On first run select whether the machine is the **Iran** or **Foreign** endpoint.

## Normal workflow

On the target endpoint:

```bash
sudo tunnel-checker --server
```

Default ports are:

- TCP `5201`
- UDP `5202`

Tunnel Checker does not modify firewall rules. Allow these ports only from the peer IP when practical.

On the other endpoint:

```bash
sudo tunnel-checker --full
```

The readiness test normally checks:

- packet loss, RTT, and RTT variation;
- sustained TCP data transfer using a bounded protocol-independent echo payload;
- UDP packet continuity/loss;
- path MTU;
- local interface errors/drops during the test.

The normal test is intentionally short and does **not** run or print several MTR/trace dumps.

## Result

Typical output is deliberately compact:

```text
TUNNEL READINESS — IRAN->FOREIGN
------------------------------------------------------------------------------------------
 Pair: 5.202.4.20 -> 209.38.241.220
 Score: 91/100    Verdict: EXCELLENT    Confidence: HIGH
 Recommendation: USE

 SIGNAL           RESULT                                        STATUS
------------------------------------------------------------------------------------------
 Ping             0% loss | 85.2 ms | var 0.5 ms               GOOD
 TCP data         48.0 Mbps effective | complete                GOOD
 UDP packets      20/20 replies | 0.00% loss                    GOOD
 Path MTU         1500 bytes                                    GOOD
 Local interface  0.0000% drops | 0 errors                     GOOD

 Main reason: Core path checks completed without a major blocker.
 Scope: this score applies only to this server pair and direction; another peer IP may behave differently.
```

If ping is perfect but sustained TCP data stalls, that severe signal caps the general readiness result and can produce:

```text
Score: 49/100
Verdict: POOR
Recommendation: TRY ANOTHER SERVER
```

UDP success remains visible separately; Tunnel Checker does not infer UDP quality from a TCP-control failure.

## Score meaning

| Score | Verdict | Practical meaning |
|---:|---|---|
| 85–100 | EXCELLENT | Strong candidate for this tested pair/direction |
| 70–84 | GOOD | Likely usable; review any warning |
| 50–69 | CAUTION | Borderline or protocol-specific weakness |
| <50 | POOR | Prefer another peer/server unless you know the limitation is acceptable |

Confidence (`HIGH`, `MEDIUM`, `LOW`) describes how much core evidence was successfully measured.

## Important scope

A result belongs to the **tested pair and direction**. It does not prove that the Iran server will behave the same with another Foreign IP/range/provider.

If you need to verify connections initiated in the opposite direction, stop/swap the target and run the same test from the peer.

## Quick check

```bash
sudo tunnel-checker --quick
```

This uses fewer probes and a smaller TCP payload. It is faster but intentionally capped at lower evidence confidence.

## Status / stop / last result

```bash
sudo tunnel-checker --status
sudo tunnel-checker --stop
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

The uninstaller removes Tunnel Checker-owned files/processes only. Shared OS packages are left installed.

## Safety

Tunnel Checker never automatically changes firewall, routes, `sysctl`, tunnel configuration, or provider settings. Temporary listeners are unauthenticated and automatically time-bounded.

## Project specification

Durable product requirements: [`PROJECT-SPEC.md`](PROJECT-SPEC.md).
