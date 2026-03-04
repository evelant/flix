import * as fs from "node:fs/promises";
import * as http from "node:http";
import * as os from "node:os";
import * as path from "node:path";
import { pathToFileURL } from "node:url";

import { FlixRunner } from "../../wasm-runner-js/runner.mjs";
import { makeNodeFsHandlers } from "../../wasm-runner-js/node-handlers.mjs";

const disposeSym = Symbol.dispose ?? Symbol.for("dispose");
const maybeDispose = (x) => {
  const fn = x?.[disposeSym];
  if (typeof fn === "function") fn.call(x);
};

async function startServer() {
  const server = http.createServer((req, res) => {
    if (req.url === "/hello") {
      const body = Buffer.from("hello", "utf8");
      res.statusCode = 200;
      res.setHeader("Content-Type", "text/plain; charset=utf-8");
      res.setHeader("Content-Length", body.length);
      res.end(body);
      return;
    }

    res.statusCode = 404;
    res.end();
  });

  await new Promise((resolve, reject) => {
    server.on("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });

  const addr = server.address();
  if (!addr || typeof addr !== "object") throw new Error("server did not bind");
  const url = `http://127.0.0.1:${addr.port}/hello`;
  return { server, url };
}

async function loadRuntime() {
  const jsPath = path.resolve("build/llvm/wasm/js/flix-llvm-wasm.component.js");
  const jsUrl = pathToFileURL(jsPath).href;
  const mod = await import(jsUrl);
  if (!mod?.runtime) throw new Error(`missing 'runtime' export in ${jsPath}`);
  return mod.runtime;
}

async function findDefId(symbol) {
  const manifestPath = path.resolve("build/llvm/flix_wasm_exports.json");
  const txt = await fs.readFile(manifestPath, { encoding: "utf8" });
  const json = JSON.parse(txt);
  const defs = Array.isArray(json?.defs) ? json.defs : [];
  const hit = defs.find((d) => d?.symbol === symbol);
  if (!hit) throw new Error(`symbol not found in exports manifest: ${symbol}`);
  return BigInt(hit.defId);
}

const sandboxDir = await fs.mkdtemp(path.join(os.tmpdir(), "flix-wasm-smoke-flix-"));
try {
  const fixturesDir = path.join(sandboxDir, "fixtures");
  await fs.mkdir(fixturesDir, { recursive: true });
  await fs.writeFile(path.join(fixturesDir, "hello.txt"), "hello", { encoding: "utf8" });

  const { server, url } = await startServer();
  try {
    const runtime = await loadRuntime();
    const defId = await findDefId("SmokeFlix.smoke");

    const ctx = runtime.newCtx();
    try {
      const runner = new FlixRunner(runtime, {
        budget: 10,
        handlers: {
          ...makeNodeFsHandlers({ rootDir: sandboxDir }),
          // http-request uses the default runner handler (fetch).
        },
      });

      const vUrl = runtime.boxString(ctx, url);
      const vFile = runtime.boxString(ctx, "fixtures/hello.txt");
      try {
        const taskId = runtime.startTask(ctx, defId, [vUrl, vFile]);
        const out = await runner.runTaskToCompletion(ctx, taskId);
        try {
          if (out.tag !== "ok") throw new Error(`expected ok, got ${out.tag}`);
          const got = runtime.unboxString(ctx, out.val);
          const expected = "hello|200 hello";
          if (got !== expected) throw new Error(`expected '${expected}', got '${got}'`);
        } finally {
          maybeDispose(out.val);
        }
      } finally {
        maybeDispose(vUrl);
        maybeDispose(vFile);
      }
    } finally {
      maybeDispose(ctx);
    }
  } finally {
    server.close();
  }
} finally {
  await fs.rm(sandboxDir, { recursive: true, force: true });
}

console.log("[wasm-smoke-flix] ok");
