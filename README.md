# Tunnel Checker

Tunnel Checker is a small Bash tool for checking whether the network path between a specific **Iran server** and a specific **Foreign server** is likely suitable for tunneling and sustained data transfer.

It tests the actual server pair instead of relying on ping alone, then returns a compact **0-100 readiness score**, verdict, confidence level, and recommendation.

## What it checks

The normal readiness test measures:

- ICMP packet loss, latency, and latency variation;
- sustained TCP data transfer;
- UDP continuity and packet loss using practical-size datagrams plus a bounded sustained sample;
- path MTU;
- local interface errors and drops observed during the test.

The tool is designed as a **server-pair readiness tester**. It does not create, configure, or manage tunnels.

## Supported environment

- Debian and Ubuntu Linux
- Bash
- IPv4 for the complete current test flow
- root or `sudo` access for installation and listener management

## Install

Recommended one-line installer:

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: tunnel-checker' 'https://api.github.com/repos/ach1992/tunnel-checker/contents/install.sh?ref=main' | { if [ "$(id -u)" -eq 0 ]; then bash && /usr/local/bin/tunnel-checker; elif command -v sudo >/dev/null 2>&1; then sudo bash && sudo /usr/local/bin/tunnel-checker; else printf '%s\n' 'ERROR: root privileges are required and sudo is unavailable. Log in as root and retry.' >&2; exit 1; fi; }
```

The installer also starts Tunnel Checker after installation. It works from a root shell and from a sudo-capable user account.

Alternative download sources:

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

If the current shell is already root, omit `sudo`.

On first run, select whether the machine is the **Iran** or **Foreign** endpoint. The selected role is saved for later runs.

## Basic workflow

Install Tunnel Checker on both endpoints.

On the endpoint that will act as the temporary test target:

```bash
sudo tunnel-checker --server
```

Default test ports are:

- TCP `5201`
- UDP `5202`

Before running a readiness test:

- make sure the peer Tunnel Checker target is running;
- allow the selected TCP port and paired UDP port through host/provider firewall rules;
- restrict those rules to the peer IP when practical.

Tunnel Checker does **not** modify firewall rules automatically.

On the other endpoint:

```bash
sudo tunnel-checker --full
```

If the opposite connection-initiation direction also matters, stop or swap the target and repeat the test from the other endpoint.

## Result

A normal result includes:

- tested pair and direction;
- TCP and UDP ports;
- readiness score;
- verdict;
- confidence;
- recommendation;
- a compact result for each measured signal;
- the primary reason for the result.

### Score meaning

| Score | Verdict | Practical meaning |
|---:|---|---|
| 85-100 | `EXCELLENT` | Strong candidate for the tested pair and direction |
| 70-84 | `GOOD` | Likely usable; review any warning |
| 50-69 | `CAUTION` | Borderline or affected by one or more weak signals |
| <50 | `POOR` | Prefer another peer/server unless the observed limitation is acceptable |

Recommendations are one of:

- `USE`
- `CAUTION`
- `TRY ANOTHER SERVER`

Confidence (`HIGH`, `MEDIUM`, or `LOW`) reflects how much useful evidence was successfully measured.

The score assumes the test target and selected test ports were prepared before the test. With those prerequisites met, failed TCP/UDP checks are treated as path/filtering evidence. If the target or firewall setup is uncertain, verify the setup and rerun before acting on the score.

## Quick check

```bash
sudo tunnel-checker --quick
```

Quick mode uses fewer probes and a smaller TCP payload. It finishes faster, but intentionally provides less evidence than the full test and skips the sustained UDP sample and PMTU search.

## Other commands

```bash
sudo tunnel-checker --status
sudo tunnel-checker --stop
sudo tunnel-checker --last
sudo tunnel-checker --update
sudo tunnel-checker --uninstall
tunnel-checker --version
```

`--uninstall` removes Tunnel Checker-owned files and processes only. Shared OS packages are left installed.

## Scope and limitations

Each result applies only to the **tested server pair, direction, and ports**. A different Foreign IP, provider, route, direction, or port can behave differently.

Tunnel Checker measures generic network-path readiness. It does not emulate every tunnel protocol or application handshake, so protocol-aware filtering/DPI may still affect a specific encrypted wrapper, raw-IP transport, ICMP-like transport, or other recognizable traffic pattern differently.

A strong score means the tested underlying path is a good candidate. It is not a universal compatibility guarantee for every possible tunnel implementation.

## Safety

Tunnel Checker does not automatically change:

- firewall rules;
- routes;
- `sysctl` values;
- tunnel configuration;
- provider/network settings.

Temporary test listeners are unauthenticated and time-bounded. Generated test traffic is also bounded.

Tunnel Checker does not require an account, telemetry service, central server, or SSH connection between the tested endpoints.

## Project specification

Durable product requirements are documented in [`PROJECT-SPEC.md`](PROJECT-SPEC.md).

## License

Tunnel Checker is released under the [MIT License](LICENSE).
