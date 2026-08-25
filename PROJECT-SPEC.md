# Tunnel Checker — Project Specification

## Purpose

Tunnel Checker is a small Bash tool for one practical question:

**Is the network path between this Iran server and this specific Foreign server likely good enough for tunneling and sustained data transfer?**

The primary problem is that Iran-side filtering, routing, shaping, or destination/IP-range behavior can make one Foreign peer work well while another peer fails even when ordinary ping looks healthy.

Tunnel Checker is therefore a **server-pair readiness tester**, not a general network-diagnostics laboratory and not a tunnel manager.

This file is the canonical source for durable project intent. Live work belongs in GitHub Issues/PRs; implementation details belong in code and README documentation.

## Product outcome

A user installs Tunnel Checker on an Iran server and a Foreign server, prepares one endpoint as a temporary bounded test target, runs a short readiness test from the other endpoint, and receives:

- a 0–100 readiness score;
- a simple verdict;
- evidence confidence;
- a small number of high-signal results;
- one primary reason;
- a direct action such as `USE`, `CAUTION`, or `TRY ANOTHER SERVER`.

The result applies only to the tested endpoint pair and initiation direction. A different Foreign IP, provider, range, route, or direction may produce a different result.

## What matters

The default readiness decision should use only signals that materially predict whether real tunnel/data traffic is likely to work:

1. ICMP packet loss and latency stability.
2. Bounded sustained TCP data transfer independent of tunnel software.
3. UDP packet continuity/loss independent of TCP control channels.
4. Practical path MTU.
5. Meaningful local interface errors/drops observed during the active test.

A healthy ping alone is never sufficient. A TCP connection opening alone is never sufficient. If sustained TCP data stalls after a small amount of transfer, that must materially reduce/cap the general readiness result even when ping is perfect.

## Scoring and confidence

The readiness score is advisory but must remain useful when some optional evidence is unavailable.

- Core independent TCP/UDP evidence may drive a score without requiring a complete `iperf3` matrix.
- Missing optional evidence lowers confidence rather than automatically making the whole result unusable.
- Confirmed severe failures may cap the score/verdict even when other metrics are healthy.
- Confidence reflects evidence coverage, not optimism.
- The score must never imply that an untested Foreign IP/range will behave the same way.

Default score bands:

- `85–100`: `EXCELLENT`
- `70–84`: `GOOD`
- `50–69`: `CAUTION`
- `<50`: `POOR`

The direct recommendation should be one of:

- `USE`
- `CAUTION`
- `TRY ANOTHER SERVER`

## Workflow

The normal workflow is SSH-free.

1. Install on both endpoints.
2. Save each endpoint role as `IRAN` or `FOREIGN`.
3. Prepare endpoint B as a temporary test target.
4. Run the readiness test from endpoint A toward B.
5. If the opposite initiation perspective matters, swap roles and repeat from B toward A.

One run must already provide a useful pair/direction assessment. The second run is confirmation for the opposite initiation perspective, not a prerequisite for every useful result.

## Speed and output

The normal readiness test should usually finish in tens of seconds, not several minutes.

The normal terminal output must stay compact. It should show only:

- endpoint pair/direction;
- score, verdict, confidence, recommendation;
- a few core signal rows;
- primary reason;
- scope/next-action note.

Do not print raw multi-hop MTR, tracepath, or multi-page diagnostic dumps in the normal readiness flow. Deep diagnosis can be added as an optional follow-up capability only when it materially helps explain a failed pair.

## Temporary target

The target should expose only bounded diagnostic listeners needed by the current readiness test.

- TCP and UDP listeners must use separate explicit ports.
- Startup must fail closed unless the expected sockets are actually bound by Tunnel Checker-owned processes.
- Listeners must automatically stop after a bounded lifetime.
- Occupied ports must be reported clearly.
- Stop/uninstall must terminate only Tunnel Checker-owned processes/state.
- The tool must warn that listeners are unauthenticated and should be restricted to the peer IP when practical.

## Safety

Tunnel Checker must never silently change:

- firewall rules;
- routes;
- `sysctl` values;
- tunnel configuration;
- provider/network settings.

Tests must be bounded in time and generated traffic. No credentials, SSH dependency, daemon mode, account, telemetry, or central service is required.

## Supported environment

- Debian and Ubuntu Linux.
- Bash.
- IPv4 for the complete current test.
- Root/sudo for installation/package management and owned listener inspection where required.

## Non-goals

- Creating, configuring, or managing tunnels.
- Identifying or recommending specific tunnel products.
- Exhaustively proving the exact cause of filtering/shaping.
- Continuous monitoring.
- Long-form network forensics in the normal test path.
- Automatically generalizing one Foreign peer result to other IP ranges/providers.

## Completion criteria

The current product outcome is complete when:

1. Fresh supported hosts can install with the documented one-line installer.
2. Endpoint role persists and the UI makes the tested direction clear.
3. Either endpoint can start/stop a bounded verified TCP/UDP test target safely.
4. The readiness test finishes quickly and measures the high-signal core factors above.
5. A healthy ping cannot hide a confirmed sustained TCP stall.
6. UDP evidence is measured independently of TCP-control behavior.
7. A useful 0–100 score, verdict, confidence, recommendation, and reason are produced from sufficient core evidence.
8. Output is concise and does not dump raw MTR/trace details by default.
9. The result clearly states that it applies only to the tested pair/direction.
10. Update/uninstall preserve unrelated/shared system state.
11. Bash syntax and smoke/regression tests pass in CI.
