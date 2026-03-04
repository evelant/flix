#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "[wasm-smoke-flix] compiling Flix smoke component"
(cd "$ROOT" && ./gradlew run --args="--Xtarget llvm-wasm --Xstdlib-profile portable tools/wasm-smoke/flix/SmokeFlix.flix")

if command -v node >/dev/null 2>&1; then
  echo "[wasm-smoke-flix] running JS driver (node)"
  node "$ROOT/tools/wasm-smoke/flix/run.mjs"
else
  echo "[wasm-smoke-flix] missing node on PATH" >&2
  exit 1
fi

