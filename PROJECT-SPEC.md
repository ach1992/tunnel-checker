# Tunnel Checker — Project Specification

## Purpose

Tunnel Checker is a small Bash-based diagnostic tool for deciding whether the network path between two Linux servers is suitable and stable enough for tunneling workloads.

The primary use case is an Iran server paired with an overseas server where ordinary ping may look healthy while real tunnels are slow, asymmetric, lossy, unstable, or intermittently fail.

This file is the canonical source for durable project intent. Live work belongs in GitHub Issues/PRs; implementation details belong in code and README documentation.

## Product outcome

A user can install Tunnel Checker with one command on both endpoints, identify each endpoint as Iran or Foreign, prepare either endpoint as a temporary test target, run practical diagnostics from both sides, and receive concise evidence-based guidance about tunnel suitability.

The tool must not stop at "ping works" or "the TCP port opens" when real sustained data transfer is unhealthy. When normal throughput tests fail or stall, bounded independent evidence should distinguish an application/test-protocol failure from a broader TCP/UDP data-path failure when the peer and environment can support that distinction.

## Supported environment

- Debian and Ubuntu Linux.
- Bash.
- IPv4 is required for the complete current test set.
- Root/sudo is required for installation/package management; diagnostics should otherwise use only privileges required by their underlying tools.

## Core workflow

The normal workflow is deliberately SSH-free.

1. Install Tunnel Checker on both endpoints.
2. On first interactive launch, identify the local endpoint as `Iran` or `Foreign`; persist that choice and allow changing it later.
3. Prepare endpoint B as a temporary test target.
4. Run Full Test from endpoint A toward B.
5. Stop/swap the target role.
6. Prepare endpoint A as the test target.
7. Run Full Test from endpoint B toward A.

`iperf3 -R` may measure reverse-direction data during one run, but exact path diagnostics such as MTR/route/PMTU are local-perspective measurements. A second Full Test from the peer is therefore the authoritative way to measure the opposite path. SSH is not required by the normal product workflow.

## Installation and lifecycle

- Provide a one-line installer.
- Install into a predictable system location and expose a `tunnel-checker` command.
- Detect and install only required OS packages when missing.
- Support update from the management menu.
- Provide an uninstaller.
- Uninstall only files owned by Tunnel Checker; do not remove shared packages.
- Support the official GitHub Contents API as an independent download path, with GitHub Raw and a practical CDN fallback for restricted networks.

## Management menu

The role-aware terminal menu should provide:

1. Full test from the current endpoint toward its peer.
2. Quick test.
3. Prepare the current endpoint as a temporary test target.
4. Stop the test target.
5. Show test-target status.
6. Change endpoint role.
7. Show the last summary.
8. Update Tunnel Checker.
9. Uninstall Tunnel Checker.
10. Exit.

The header should always make the current endpoint and test direction obvious.

## Network diagnostics

The Full Test should cover practical failure modes that can make a tunnel fail even when ordinary ping looks healthy, when supported by the environment and peer:

- Peer resolution/reachability and local route/source/interface.
- ICMP packet loss, average RTT, and RTT variation.
- `iperf3` service/control reachability derived from a real bounded protocol session rather than a raw fake-client hit on the active service socket.
- TCP single-stream throughput in both data directions.
- TCP parallel-stream throughput in both data directions.
- TCP retransmission information exposed by `iperf3`.
- UDP throughput/loss/jitter in both data directions at bounded rates derived from the expected workload.
- RTT increase under verified upload/download load.
- ICMP/TCP/UDP MTR path analysis with destination loss summarized separately from raw intermediate-hop behavior.
- `tracepath` path-MTU information where available.
- IPv4 DF/PMTU discovery with bounded probes.
- Local interface packet/error/drop counters around the active test window, including enough packet-delta context to interpret drop severity responsibly.
- Detection of meaningful directional performance asymmetry.
- Clear distinction between a blocked/unavailable diagnostic, a tool/protocol failure, a sustained-transfer stall, and a measured bad network result.
- When `iperf3` TCP data fails or stalls despite a reachable service/control session, a bounded protocol-independent TCP continuity diagnostic on an isolated auxiliary socket/port when peer support is available.
- When UDP suitability would otherwise be unknown because an `iperf3` TCP control session failed, an independent bounded UDP-path diagnostic when peer support is available.

Intermediate MTR probe loss must not be treated as end-to-end packet loss when the destination and later hops remain healthy.

MTR/control/path probes must not intentionally reuse the active `iperf3` application socket in a way that creates fake clients, misleading server errors, or ambiguity about whether the real data test failed. Use isolated probe semantics/ports or derive the required evidence from the real application session.

## Test safety

- Active tests must be bounded in duration and bandwidth.
- The user chooses or accepts an expected tunnel bandwidth used to bound active tests.
- A temporary `iperf3` server must automatically stop after a bounded lifetime.
- Starting the server must state that TCP/UDP on the selected port must be reachable from the peer and that `iperf3` has no authentication.
- Temporary target startup must fail closed unless the requested service socket is actually bound by the expected `iperf3` process; stale PID state or a parent `timeout` process alone is not proof that the listener is healthy.
- Occupied ports and bind/listener failures must be reported clearly without claiming the test target is running.
- Any auxiliary TCP/UDP diagnostic listener must be separate from the live `iperf3` protocol socket, bounded, explicit, and removed/stopped with the same ownership discipline as the normal temporary target.
- Tunnel Checker must not silently change firewall rules, routing, sysctl, tunnel configuration, or provider settings.
- Unsupported tools/flags must degrade gracefully.

## Results, evidence, and scoring

The concise result section should show:

- metric/test name;
- current endpoint -> peer result;
- peer -> current endpoint data result where actually measured;
- health state such as `GOOD`, `WARN`, `BAD`, `FAILED`, or `N/A`;
- evidence confidence;
- a numeric 0–100 score only when essential evidence exists;
- overall verdict;
- concise recommendations derived from observed evidence.

A reachable TCP control/service path is not proof that an `iperf3` data test succeeded. When an active data test fails, surface a useful bounded error reason rather than silently turning it into `N/A`.

A failed `iperf3 -u` run is not, by itself, proof that the UDP data path is bad when the failure may come from `iperf3`'s TCP control session. UDP tunnel suitability must stay `UNKNOWN` unless UDP-specific evidence exists.

When an independent bounded continuity check confirms that TCP establishes but sustained transfer repeatedly stalls, the TCP tunnel/proxy use case may be `UNSUITABLE` even if overall evidence remains incomplete. Do not hide a confirmed data-path failure behind a generic `UNKNOWN` merely because unrelated evidence is missing.

Loaded-latency results are valid only when the tool verifies that a real `iperf3` load was created. If essential TCP/UDP evidence is missing, the run must be `INCOMPLETE`, confidence must be low, and no authoritative numeric score should be shown.

The score is advisory and should weight packet loss, jitter, usable throughput, directional asymmetry, load-induced latency, MTU, and meaningful local drops more strongly than idle ping alone.

## Use-case assessment

At the end of a Full Test, include a compact evidence-based table indicating `SUITABLE`, `CAUTION`, `UNSUITABLE`, or `UNKNOWN` for at least:

- TCP tunnels/proxies;
- UDP tunnels such as WireGuard-style workloads;
- interactive/realtime traffic;
- bulk/high-bandwidth transfer;
- MTU-sensitive tunnels;
- overall endpoint pair.

Missing required evidence must produce `UNKNOWN`, not a guessed suitability result, except that a separately confirmed failure for one specific use case may mark that use case `UNSUITABLE` while unrelated use cases remain `UNKNOWN`.

## Quick test

Quick Test should remain deliberately lightweight and include high-signal checks such as route/reachability, a short ping sample, short TCP throughput in both data directions when available, and a concise verdict. It does not need the full UDP/path/fallback-diagnostic suite.

## User experience

- English source/UI for the current release.
- Consistent ANSI color and section styling when attached to a compatible terminal, with a readable no-color fallback.
- Clear progress while tests run.
- Keep raw MTR/trace details below the concise summary rather than forcing users to interpret them first.
- Do not store credentials or require SSH.
- Keep temporary files bounded and safe.

## Non-goals

- Creating or managing tunnels.
- Automatically changing firewall rules.
- Continuous monitoring/daemon mode.
- Web UI, central service, accounts, or telemetry.
- Perfect diagnosis of carrier filtering/traffic shaping when available measurements cannot prove it.
- Automatically combining two independent endpoint reports in the current release.

## Completion criteria

The current product outcome is complete when:

1. Fresh supported hosts can install the tool using the documented one-line installer.
2. First interactive launch identifies and persists Iran/Foreign endpoint role.
3. The menu clearly reflects current role and test direction.
4. Either endpoint can run a bounded temporary `iperf3` target with verified listener ownership and clear bind-conflict handling.
5. Quick/Full tests run without destructive network changes.
6. Full Test measures all required available signals and clearly distinguishes failed/unavailable evidence.
7. Missing essential data yields `INCOMPLETE` rather than a misleading numeric score.
8. The result includes concise metric, suitability, confidence, recommendation, and use-case tables plus optional raw route details.
9. The documented standard workflow measures both endpoint perspectives without SSH.
10. Update/uninstall flows preserve unrelated/shared system state.
11. Full Test does not create misleading `iperf3` fake-client errors through its own reachability or MTR probes.
12. When `iperf3` TCP stalls and peer support exists, the tool can independently distinguish an `iperf3`-specific failure from a broader sustained TCP data-path failure.
13. UDP tunnel suitability is based on UDP-specific evidence rather than being inferred from a failed TCP control path.
