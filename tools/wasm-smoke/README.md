# Wasm Component Smoke Harness (Wasmtime)

This directory is a small, standalone harness to validate that our current WIT
surface can be:

1) implemented as a wasm component (guest), and
2) instantiated + called from a host (Wasmtime embedding API),

without relying on fragile string-concatenated IR or ad-hoc JS glue.

It is intentionally minimal and should stay that way.

## What It Tests

- `flix:sys` host imports work (`log`, `time-now-ms`, `random-bytes`, `has-capability`).
- `flix:runtime` exports work end-to-end:
  - `new-ctx`
  - boxing/unboxing (`box-i32`, `unbox-i32`, `box-string`, `unbox-string`)
  - `invoke` returning `exec` (`ok`, `thrown`, and `suspended` with a pollable `task-id`)
  - task/scheduler surface:
    - `start-task`
    - `sched-step` returning multiple `suspension`s
    - `poll-task` returning `task-outcome`
  - `suspension-peek`
  - typed per-op payload + resumption:
    - `suspension-request` returning `op-request`
    - `resume-timer-sleep` (no “fabricate Unit” requirement)
    - `resume-http-ok` / `resume-http-err`
    - Filesystem: typed requests + `resume-file-*` resumers (see `runtime/wit/op-catalog.md`)
    - Process: typed requests + `resume-process-*` resumers (see `runtime/wit/op-catalog.md`)
    - TCP:
      - `resume-tcp-socket-connect-ok` / `resume-tcp-socket-connect-err`
      - `resume-tcp-socket-read-ok` / `resume-tcp-socket-read-err`
      - `resume-tcp-socket-write-ok` / `resume-tcp-socket-write-err`
      - `resume-tcp-socket-close-ok` / `resume-tcp-socket-close-err`
      - `resume-tcp-server-bind-ok` / `resume-tcp-server-bind-err`
      - `resume-tcp-server-accept-ok` / `resume-tcp-server-accept-err`
      - `resume-tcp-server-local-port-ok` / `resume-tcp-server-local-port-err`
      - `resume-tcp-server-close-ok` / `resume-tcp-server-close-err`
  - `resume-ok` + `resume-throw` (unblocks tasks; completion observed via `poll-task`)
- Resource ownership is sane at the boundary:
  - `ctx` is passed by `borrow<ctx>` to avoid accidental consumption.
  - `suspension` is consumed by `resume-*` (and should not be dropped by the host after).

## Tooling Notes (2026-03-02)

- Wasmtime component-model async + WASI P3/0.3 are real but explicitly **incomplete/unstable**;
  this harness stays synchronous and avoids depending on futures/streams at the boundary.
- `jco transpile` is currently the practical browser path for components, but it has real
  constraints (e.g. multi-memory polyfill limitations, wasm EH/tag section interactions).

## Run

Requirements:

- Rust `stable` (this repo’s environment currently uses `rustc 1.93+`).
- `wasm-tools` on PATH.
- `wasmtime` on PATH.
- For the JS packaging smoke: `jco` + `node` on PATH.

One command:

```bash
tools/wasm-smoke/run.sh
```

## Flix (compiler end-to-end)

To smoke-test the Flix LLVM-wasm backend end-to-end (compile → componentize → `jco transpile` → Node runner):

```bash
tools/wasm-smoke/run_flix.sh
```

## Browser (OPFS)

To exercise filesystem ops in a real browser via OPFS:

```bash
node tools/wasm-smoke/browser/serve.mjs
```

Then open `http://127.0.0.1:8000/tools/wasm-smoke/browser/opfs.html`.

Manual steps (debug builds):

```bash
cd tools/wasm-smoke/guest
cargo +stable build --target wasm32-unknown-unknown

wasm-tools component new \
  target/wasm32-unknown-unknown/debug/flix_smoke_guest.wasm \
  -o ../out/flix-smoke.component.wasm

cd ../host
cargo +stable run -- ../out/flix-smoke.component.wasm
```
