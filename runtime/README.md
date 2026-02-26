# Flix Native Runtime Spikes (Zig)

This directory contains small, runnable spikes to de-risk the planned native runtime substrate:

- Pollchecks + soft handshakes (foundation for GC coordination with `spawn`)
- `libxev` integration (completion → resume shape)

## Run

From repo root:

- `cd runtime && zig build run-handshake`
- `cd runtime && zig build run-xev-timer`
- `cd runtime && zig build run-xev-http-get -- http://example.com/`
- `cd runtime && zig build run-xev-http-wire -- http://example.com/`
- `cd runtime && zig build run-xev-http-syscall -- http://example.com/`

Optional:

- `cd runtime && zig build -Doptimize=ReleaseFast run-handshake`
- `cd runtime && zig build -Doptimize=ReleaseFast run-xev-timer`
- `cd runtime && zig build -Doptimize=ReleaseFast run-xev-http-get -- http://example.com/`
- `cd runtime && zig build -Doptimize=ReleaseFast run-xev-http-wire -- http://example.com/`
- `cd runtime && zig build -Doptimize=ReleaseFast run-xev-http-syscall -- http://example.com/`
