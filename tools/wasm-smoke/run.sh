#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "[wasm-smoke] ensuring rust targets"
rustup +stable target add wasm32-unknown-unknown >/dev/null 2>&1 || true

echo "[wasm-smoke] building guest"
cargo +stable build \
  --manifest-path "$ROOT/tools/wasm-smoke/guest/Cargo.toml" \
  --target wasm32-unknown-unknown

echo "[wasm-smoke] componentizing guest"
mkdir -p "$ROOT/tools/wasm-smoke/out"
wasm-tools component new \
  "$ROOT/tools/wasm-smoke/guest/target/wasm32-unknown-unknown/debug/flix_smoke_guest.wasm" \
  -o "$ROOT/tools/wasm-smoke/out/flix-smoke.component.wasm"

echo "[wasm-smoke] running host"
cargo +stable run \
  --manifest-path "$ROOT/tools/wasm-smoke/host/Cargo.toml" \
  --bin flix-smoke-host \
  -- "$ROOT/tools/wasm-smoke/out/flix-smoke.component.wasm"

echo "[wasm-smoke] running host runner (real fs + tcp)"
cargo +stable run \
  --manifest-path "$ROOT/tools/wasm-smoke/host/Cargo.toml" \
  --bin run_runner \
  -- "$ROOT/tools/wasm-smoke/out/flix-smoke.component.wasm"

if command -v jco >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  echo "[wasm-smoke] transpiling component to JS (jco)"
  mkdir -p "$ROOT/tools/wasm-smoke/browser-out"

  jco transpile \
    "$ROOT/tools/wasm-smoke/out/flix-smoke.component.wasm" \
    -o "$ROOT/tools/wasm-smoke/browser-out" \
    --map "flix:sys/sys=../browser/sys.js"

  echo "[wasm-smoke] running JS driver (node)"
  node "$ROOT/tools/wasm-smoke/browser/run.mjs"

  echo "[wasm-smoke] running JS runner (node)"
  node "$ROOT/tools/wasm-smoke/browser/run_runner.mjs"
else
  echo "[wasm-smoke] skipping JS smoke (missing jco or node)"
fi
