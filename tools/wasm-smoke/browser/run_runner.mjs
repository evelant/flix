import { runtime } from "../browser-out/flix-smoke.component.js";
import { FlixRunner } from "../../wasm-runner-js/runner.mjs";
import { makeNodeFsHandlers, makeTempSandbox } from "../../wasm-runner-js/node-handlers.mjs";
import { makeNodeTcpHandlers } from "../../wasm-runner-js/node-tcp-handlers.mjs";
import { makeNodeProcessHandlers } from "../../wasm-runner-js/node-process-handlers.mjs";

import * as fs from "node:fs/promises";
import * as path from "node:path";

const disposeSym = Symbol.dispose ?? Symbol.for("dispose");
const maybeDispose = (x) => {
  const fn = x?.[disposeSym];
  if (typeof fn === "function") fn.call(x);
};

const ctx = runtime.newCtx();

const sandboxDir = await makeTempSandbox("flix-wasm-smoke-");
const fixturesDir = path.join(sandboxDir, "fixtures");
const outDir = path.join(sandboxDir, "out");

await fs.mkdir(fixturesDir, { recursive: true });
await fs.mkdir(outDir, { recursive: true });

await fs.writeFile(path.join(fixturesDir, "hello.txt"), "hello", { encoding: "utf8" });
await fs.writeFile(path.join(fixturesDir, "lines.txt"), "a\nb\n", { encoding: "utf8" });
await fs.writeFile(path.join(fixturesDir, "bytes.bin"), new Uint8Array([1, 2, 3]));

const runner = new FlixRunner(runtime, {
  budget: 10,
  handlers: {
    ...makeNodeFsHandlers({ rootDir: sandboxDir }),
    ...makeNodeTcpHandlers({ connectTimeoutMs: 2000 }),
    ...makeNodeProcessHandlers(),

    // Keep smoke tests deterministic: use a stub handler instead of `fetch`.
    "http-request": async ({ runtime, ctx, suspension, request }) => {
      // Validate the payload shape we expect from the guest.
      if (request.method !== "GET" || request.url !== "https://example.com/hello") {
        runtime.resumeHttpErr(ctx, suspension, { kindCode: 14, msg: "unexpected request" });
        return;
      }

      runtime.resumeHttpOk(ctx, suspension, {
        status: 200,
        headers: [{ name: "x-foo", value: "bar" }],
        body: "hello",
      });
    },
  },
});

async function runTask(defId) {
  const task = runtime.startTask(ctx, defId, []);
  return runner.runTaskToCompletion(ctx, task);
}

async function assertOkI32(defId, expected) {
  const out = await runTask(defId);
  try {
    if (out.tag !== "ok") throw new Error(`expected ok for def ${defId}, got ${out.tag}`);
    const got = runtime.unboxI32(ctx, out.val);
    if (got !== expected) throw new Error(`expected ${expected} for def ${defId}, got ${got}`);
  } finally {
    maybeDispose(out.val);
  }
}

async function assertOkString(defId, expected) {
  const out = await runTask(defId);
  try {
    if (out.tag !== "ok") throw new Error(`expected ok for def ${defId}, got ${out.tag}`);
    const got = runtime.unboxString(ctx, out.val);
    if (got !== expected) throw new Error(`expected '${expected}' for def ${defId}, got '${got}'`);
  } finally {
    maybeDispose(out.val);
  }
}

async function assertThrownString(defId, expected) {
  const out = await runTask(defId);
  try {
    if (out.tag !== "thrown") throw new Error(`expected thrown for def ${defId}, got ${out.tag}`);
    const got = runtime.unboxString(ctx, out.val);
    if (got !== expected) throw new Error(`expected '${expected}' for def ${defId}, got '${got}'`);
  } finally {
    maybeDispose(out.val);
  }
}

async function assertThrownStartsWith(defId, prefix) {
  const out = await runTask(defId);
  try {
    if (out.tag !== "thrown") throw new Error(`expected thrown for def ${defId}, got ${out.tag}`);
    const got = runtime.unboxString(ctx, out.val);
    if (!got.startsWith(prefix)) {
      throw new Error(`expected '${got}' for def ${defId} to start with '${prefix}'`);
    }
  } finally {
    maybeDispose(out.val);
  }
}

// def 4: timer-sleep (default runner handler: setTimeout)
await assertOkI32(4n, 123);

// def 5: http-request (custom handler)
await assertOkString(5n, "200 hello");

// --- filesystem ops (node handlers) ---
await assertOkString(16n, "exists=true");
await assertOkString(17n, "size=5");
await assertOkString(18n, "read=hello");
await assertOkString(19n, "lines=2 first=a");
await assertOkString(20n, "bytes=3 first=1");
await assertOkString(21n, "list=3 first=bytes.bin");
await assertOkString(22n, "write-ok");
await assertThrownString(54n, "8 not a directory");
await assertThrownStartsWith(55n, "14 ");

const wrote = await fs.readFile(path.join(outDir, "write.txt"), { encoding: "utf8" });
if (wrote !== "hello") throw new Error(`expected out/write.txt to contain 'hello', got '${wrote}'`);

// def 52: TCP roundtrip (node handlers)
await assertOkString(52n, "tcp-ok");

// def 53: Process roundtrip (node handlers)
await assertOkString(53n, "proc-ok");

maybeDispose(ctx);

await fs.rm(sandboxDir, { recursive: true, force: true });
