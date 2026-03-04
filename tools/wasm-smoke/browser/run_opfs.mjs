import { runtime } from "../browser-out/flix-smoke.component.js";
import { FlixRunner } from "../../wasm-runner-js/runner.mjs";
import { makeOpfsFsHandlers, makeOpfsSandbox } from "../../wasm-runner-js/opfs-handlers.mjs";

const disposeSym = Symbol.dispose ?? Symbol.for("dispose");
const maybeDispose = (x) => {
  const fn = x?.[disposeSym];
  if (typeof fn === "function") fn.call(x);
};

function setStatus(msg) {
  const el = globalThis.document?.getElementById?.("status");
  if (el) el.textContent = msg;
}

async function writeTextFile(dir, name, text) {
  const fh = await dir.getFileHandle(name, { create: true });
  const w = await fh.createWritable();
  try {
    await w.write(text);
  } finally {
    await w.close();
  }
}

async function writeBytesFile(dir, name, bytes) {
  const fh = await dir.getFileHandle(name, { create: true });
  const w = await fh.createWritable();
  try {
    await w.write(bytes);
  } finally {
    await w.close();
  }
}

async function main() {
  setStatus("running…");

  const ctx = runtime.newCtx();
  const sandbox = await makeOpfsSandbox("flix-wasm-smoke-");

  try {
    const fixturesDir = await sandbox.rootDirHandle.getDirectoryHandle("fixtures", { create: true });
    await sandbox.rootDirHandle.getDirectoryHandle("out", { create: true });

    await writeTextFile(fixturesDir, "hello.txt", "hello");
    await writeTextFile(fixturesDir, "lines.txt", "a\nb\n");
    await writeBytesFile(fixturesDir, "bytes.bin", new Uint8Array([1, 2, 3]));

    const runner = new FlixRunner(runtime, {
      budget: 10,
      handlers: {
        ...makeOpfsFsHandlers({ rootDirHandle: sandbox.rootDirHandle }),

        // Keep smoke tests deterministic: use a stub handler instead of `fetch`.
        "http-request": async ({ runtime, ctx, suspension, request }) => {
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
        if (!got.startsWith(prefix)) throw new Error(`expected '${got}' for def ${defId} to start with '${prefix}'`);
      } finally {
        maybeDispose(out.val);
      }
    }

    // def 4: timer-sleep (default runner handler: setTimeout)
    await assertOkI32(4n, 123);

    // def 5: http-request (stub handler)
    await assertOkString(5n, "200 hello");

    // --- filesystem ops (OPFS handlers) ---
    await assertOkString(16n, "exists=true");
    await assertOkString(17n, "size=5");
    await assertOkString(18n, "read=hello");
    await assertOkString(19n, "lines=2 first=a");
    await assertOkString(20n, "bytes=3 first=1");
    await assertOkString(21n, "list=3 first=bytes.bin");
    await assertOkString(22n, "write-ok");
    await assertThrownString(54n, "8 not a directory");
    await assertThrownStartsWith(55n, "14 ");

    setStatus("opfs smoke OK");
    console.log("opfs smoke OK");
  } finally {
    maybeDispose(ctx);
    await sandbox.cleanup();
  }
}

main().catch((e) => {
  setStatus(`ERROR: ${e instanceof Error ? e.message : String(e)}`);
  throw e;
});

