# Tunnel Checker

Tunnel Checker answers one practical question quickly:

> **Is this Iran server <-> this specific Foreign server path likely good enough for tunneling/data transfer?**

A good ping is not enough. Iran-side filtering/routing can make one Foreign IP work normally while another stalls or fails. Tunnel Checker tests the actual pair and gives a compact **0-100 readiness score**, confidence, and a direct recommendation.

## Install

Recommended one-line installer (works both from a root shell and from a sudo-capable user):

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: tunnel-checker' 'https://api.github.com/repos/ach1992/tunnel-checker/contents/install.sh?ref=main' | { if [ "$(id -u)" -eq 0 ]; then bash && /usr/local/bin/tunnel-checker; elif command -v sudo >/dev/null 2>&1; then sudo bash && sudo /usr/local/bin/tunnel-checker; else printf '%s\n' 'ERROR: root privileges are required and sudo is unavailable. Log in as root and retry.' >&2; exit 1; fi; }
```

This supports minimal Debian/Ubuntu images that do not install `sudo` by default. If the current shell is already `root`, no `sudo` package is required.

Alternative download sources below assume a root shell. From a non-root account with `sudo`, replace the final `bash` with `sudo bash`.

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/ach1992/tunnel-checker@main/install.sh | bash
```

```bash
curl -fsSL https://raw.githubusercontent.com/ach1992/tunnel-checker/main/install.sh | bash
```

For later runs:

```bash
sudo tunnel-checker
```

If the current shell is already `root`, omit `sudo`:

```bash
tunnel-checker
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
- UDP continuity/loss with 1200-byte probes plus a bounded sustained multi-packet UDP sample;
- path MTU;
- local interface errors/drops during the test.

The normal test is intentionally short and does **not** run or print multi-page path diagnostics.

## Result

Typical output is deliberately compact:

```text
TUNNEL READINESS - IRAN->FOREIGN
------------------------------------------------------------------------------------------
 Pair: 5.202.4.20 -> 209.38.241.220
 Score: 91/100    Verdict: EXCELLENT    Confidence: HIGH
 Recommendation: USE

 SIGNAL           RESULT                                        STATUS
------------------------------------------------------------------------------------------
 Ping             0% loss | 85.2 ms | var 0.5 ms               GOOD
 TCP data         48.0 Mbps effective | complete                GOOD
 UDP data         20/20 | 0.00% loss | bulk 240/240 KB         GOOD
 Path MTU         1500 bytes                                    GOOD
 Local interface  0.0000% drops | 0 errors                     GOOD

 Main reason: Core path checks completed without a major blocker.
 Scope: this score covers this pair/direction on TCP 5201 + UDP 5202; protocol-specific filtering may differ.
```

If ping is perfect but sustained TCP data stalls, that severe signal caps the general readiness result and can produce:

```text
Score: 49/100
Verdict: POOR
Recommendation: TRY ANOTHER SERVER
```

UDP success remains visible separately; Tunnel Checker does not infer UDP quality from a TCP failure.

## Score meaning

| Score | Verdict | Practical meaning |
|---:|---|---|
| 85-100 | EXCELLENT | Strong candidate for this tested pair/direction |
| 70-84 | GOOD | Likely usable; review any warning |
| 50-69 | CAUTION | Borderline or protocol-specific weakness |
| <50 | POOR | Prefer another peer/server unless you know the limitation is acceptable |

Confidence (`HIGH`, `MEDIUM`, `LOW`) describes how much core evidence was successfully measured.

## Important scope

A result belongs to the **tested pair, direction, and ports**. It does not prove that the Iran server will behave the same with another Foreign IP/range/provider or another port.

The test measures generic path behavior rather than emulating every possible tunnel protocol. Protocol-aware filtering/DPI can still treat a specific application handshake, encrypted wrapper, raw-IP transport, or other recognizable traffic differently. A strong score means the underlying tested path is a good candidate; it is not a universal protocol-compatibility guarantee.

The TCP echo transfers payload both ways on one connection. If you need to verify connections **initiated from the opposite endpoint**, stop/swap the target and run the same test from the peer.

## Quick check

```bash
sudo tunnel-checker --quick
```

This uses fewer probes and a smaller TCP payload. It is faster but intentionally capped at lower evidence confidence and skips the sustained UDP sample/PMTU search.

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

The uninstaller removes Tunnel Checker-owned files/processes only. Shared OS packages are left installed. v0.4 also safely cleans obsolete Tunnel Checker-owned runtime files/logs from v0.3 when stopping or uninstalling a target.

## Safety

Tunnel Checker never automatically changes firewall, routes, `sysctl`, tunnel configuration, or provider settings. Temporary listeners are unauthenticated and automatically time-bounded.

## Project specification

Durable product requirements: [`PROJECT-SPEC.md`](PROJECT-SPEC.md).
