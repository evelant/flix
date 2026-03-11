/*
 * Copyright 2026 Magnus Madsen
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package ca.uwaterloo.flix

import ca.uwaterloo.flix.api.Flix
import ca.uwaterloo.flix.language.CompilationMessage
import ca.uwaterloo.flix.language.ast.shared.SecurityContext
import ca.uwaterloo.flix.util.{CompilationTarget, Options, StdlibProfile}
import org.scalatest.funsuite.AnyFunSuite

import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path}
import java.util.concurrent.TimeUnit
import scala.jdk.CollectionConverters.*

class LlvmWasmExportSuite extends AnyFunSuite {

  private val TestOptions: Options =
    Options.TestWithLibAll.copy(
      stdlibProfile = StdlibProfile.Portable,
      target = CompilationTarget.LlvmWasm,
      incremental = false,
      outputJvm = false,
    )

  private val ProgramSource: String =
    """
      |mod Test {
      |    eff HostEcho {
      |        def echo(s: String): String
      |    }
      |
      |    @Export
      |    pub def add(x: Int32, y: Int32): Int32 = x + y
      |
      |    @Export
      |    pub def echo(s: String): String = s
      |
      |    @Export
      |    pub def bytesId(a: Array[Int8, Static]): Array[Int8, Static] = a
      |
      |    @Export
      |    pub def suspendEcho(s: String): String \ HostEcho = HostEcho.echo(s)
      |}
      |""".stripMargin

  private case class CompiledArtifacts(outDir: Path,
                                       componentJs: Path,
                                       bindingsJs: Path,
                                       bindingsTypes: Path,
                                       typedExportComponent: Path,
                                       typedWitDir: Path)

  test("llvm-wasm-typed-export-bindings") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-wasm export test)")
    assume(hasWasmTools, "wasm-tools not found on PATH (skipping LLVM-wasm export test)")
    assume(hasJco, "jco not found on PATH (skipping LLVM-wasm export test)")
    assume(hasNode, "node not found on PATH (skipping LLVM-wasm export test)")
    val nodeFile = Files.createTempFile("flix-llvm-wasm-export-bindings-", ".mjs")
    val compiled = compileArtifacts(ProgramSource)
    try {
      if (!Files.exists(compiled.componentJs)) fail(s"Missing wasm JS component artifact: ${compiled.componentJs}")
      if (!Files.exists(compiled.bindingsJs)) fail(s"Missing wasm JS export bindings: ${compiled.bindingsJs}")
      if (!Files.exists(compiled.bindingsTypes)) fail(s"Missing wasm TS export bindings: ${compiled.bindingsTypes}")
      if (!Files.exists(compiled.typedExportComponent)) fail(s"Missing wasm typed export component: ${compiled.typedExportComponent}")
      if (!Files.isDirectory(compiled.typedWitDir)) fail(s"Missing wasm typed export WIT directory: ${compiled.typedWitDir}")

      val (witExit, witOutput) = runCmd(List("wasm-tools", "component", "wit", compiled.typedExportComponent.toString))
      if (witExit != 0) {
        fail(s"Failed to inspect typed export component WIT:\n$witOutput")
      }
      if (!witOutput.contains("export flix:exports/api@0.1.0;")) {
        fail(s"Typed export component did not expose the expected typed API:\n$witOutput")
      }
      if (witOutput.contains("export flix:runtime/runtime@0.1.0;")) {
        fail(s"Typed export component leaked the internal runtime interface:\n$witOutput")
      }

      val nodeProgram =
        s"""
           |import { newCtx, Exports } from ${jsStringLiteral(compiled.bindingsJs.toUri.toString)};
           |
           |const disposeSym = Symbol.dispose ?? Symbol.for("dispose");
           |function maybeDispose(x) {
           |  try {
           |    const fn = x?.[disposeSym];
           |    if (typeof fn === "function") fn.call(x);
           |  } catch {}
           |}
           |
           |function assert(cond, msg) {
           |  if (!cond) throw new Error(msg);
           |}
           |
           |function eqBytes(a, b) {
           |  if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array)) return false;
           |  if (a.length !== b.length) return false;
           |  for (let i = 0; i < a.length; i++) {
           |    if (a[i] !== b[i]) return false;
           |  }
           |  return true;
           |}
           |
           |const ctx = newCtx();
           |try {
           |  const add = Exports.Test.add(ctx, 1, 2);
           |  assert(add.tag === "ok" && add.val === 3, `bad add: $${JSON.stringify(add)}`);
           |
           |  const echo = Exports.Test.echo(ctx, "hello");
           |  assert(echo.tag === "ok" && echo.val === "hello", `bad echo: $${JSON.stringify(echo)}`);
           |
           |  const data = new Uint8Array([0, 1, 2, 255]);
           |  const bytes = Exports.Test.bytesId(ctx, data);
           |  assert(bytes.tag === "ok" && eqBytes(bytes.val, data), "bad bytes");
           |
           |  const susp = Exports.Test.suspendEcho(ctx, "hello");
           |  assert(susp.tag === "suspended", `bad suspend tag: $${String(susp.tag)}`);
           |  assert(ctx.suspensionArgCount(susp.val) === 1, "bad suspension argc");
           |  const arg0 = ctx.suspensionArgAsPtr(susp.val, 0);
           |  try {
           |    assert(ctx.unboxString(arg0) === "hello", "bad suspension arg0");
           |  } finally {
           |    maybeDispose(arg0);
           |  }
           |
           |  const ok = ctx.boxString("ok");
           |  try {
           |    const resumed = Exports.Test.resumeSuspendEcho(ctx, susp.val, ok);
           |    assert(resumed.tag === "ok" && resumed.val === "ok", `bad resumed result: $${JSON.stringify(resumed)}`);
           |  } finally {
           |    maybeDispose(ok);
           |  }
           |
           |  console.log("OK");
           |} finally {
           |  maybeDispose(ctx);
           |}
           |""".stripMargin

      Files.writeString(nodeFile, nodeProgram, StandardCharsets.UTF_8)

      val (exit, output) = runNode(nodeFile)
      if (exit != 0) {
        fail(s"Typed wasm export bindings smoke failed with exit $exit:\n$output")
      }
      if (output.trim != "OK") {
        fail(s"Unexpected typed wasm export bindings output:\n$output")
      }
    } finally {
      Files.deleteIfExists(nodeFile)
      deleteRecursive(compiled.outDir)
    }
  }

  test("llvm-wasm-typed-export-component-wasmtime-host") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-wasm export test)")
    assume(hasWasmTools, "wasm-tools not found on PATH (skipping LLVM-wasm export test)")
    assume(hasJco, "jco not found on PATH (skipping LLVM-wasm export test)")
    assume(hasCargoStable, "cargo +stable not available (skipping LLVM-wasm Wasmtime export test)")

    val compiled = compileArtifacts(ProgramSource)
    val hostDir = Files.createTempDirectory("flix-llvm-wasm-export-wasmtime-host-")
    try {
      val cargoToml =
        """
          |[package]
          |name = "typed_export_host"
          |version = "0.1.0"
          |edition = "2021"
          |
          |[dependencies]
          |anyhow = "1"
          |wasmtime = { version = "38", features = ["component-model"] }
          |""".stripMargin

      Files.createDirectories(hostDir.resolve("src"))
      Files.writeString(hostDir.resolve("Cargo.toml"), cargoToml, StandardCharsets.UTF_8)

      val rustMain =
        s"""
           |use anyhow::{bail, Context, Result};
           |use wasmtime::{
           |    Config, Engine, Store,
           |    component::{Component, HasSelf, Linker},
           |};
           |
           |mod bindings {
           |    wasmtime::component::bindgen!({
           |        path: ${jsStringLiteral(compiled.typedWitDir.toString)},
           |        world: "flix",
           |    });
           |}
           |
           |use bindings::exports::flix::exports::api;
           |use bindings::flix::sys::sys::{Capability, Host as SysHost, LogLevel};
           |
           |#[derive(Default)]
           |struct State;
           |
           |impl SysHost for State {
           |    fn log(&mut self, _level: LogLevel, _msg: String) {}
           |
           |    fn time_now_ms(&mut self) -> i64 { 0 }
           |
           |    fn random_bytes(&mut self, len: u32) -> Vec<u8> {
           |        (0..len).map(|i| (i as u8).wrapping_mul(31)).collect()
           |    }
           |
           |    fn get_args(&mut self) -> Vec<String> { Vec::new() }
           |
           |    fn has_capability(&mut self, _cap: Capability) -> bool { false }
           |}
           |
           |fn main() -> Result<()> {
           |    let component_path = std::env::args().nth(1).context("missing component path")?;
           |
           |    let mut config = Config::new();
           |    config.wasm_component_model(true);
           |    let engine = Engine::new(&config)?;
           |
           |    let component = Component::from_file(&engine, &component_path)
           |        .with_context(|| format!("failed to load component: {}", component_path))?;
           |
           |    let mut linker = Linker::<State>::new(&engine);
           |    bindings::flix::sys::sys::add_to_linker::<_, HasSelf<_>>(&mut linker, |s| s)?;
           |
           |    let mut store = Store::new(&engine, State::default());
           |    let flix = bindings::Flix::instantiate(&mut store, &component, &linker)?;
           |    let api = flix.flix_exports_api();
           |    let ctx_api = api.ctx();
           |    let ctx = ctx_api.call_constructor(&mut store)?;
           |
           |    match ctx_api.call_test_add(&mut store, ctx, 1, 2)? {
           |        api::ExecInt32::Ok(v) if v == 3 => {}
           |        other => bail!("bad add result: {:?}", other),
           |    }
           |
           |    match ctx_api.call_test_echo(&mut store, ctx, "hello")? {
           |        api::ExecString::Ok(v) if v == "hello" => {}
           |        other => bail!("bad echo result: {:?}", other),
           |    }
           |
           |    let data = vec![0u8, 1, 2, 255];
           |    match ctx_api.call_test_bytesid(&mut store, ctx, &data)? {
           |        api::ExecBytes::Ok(v) if v == data => {}
           |        other => bail!("bad bytes result: {:?}", other),
           |    }
           |
           |    let susp = match ctx_api.call_test_suspendecho(&mut store, ctx, "hello")? {
           |        api::ExecString::Suspended(s) => s,
           |        other => bail!("bad suspend result: {:?}", other),
           |    };
           |
           |    let argc = ctx_api.call_suspension_arg_count(&mut store, ctx, susp)?;
           |    if argc != 1 {
           |        bail!("unexpected suspension arg count: {}", argc);
           |    }
           |
           |    let arg0 = ctx_api.call_suspension_arg_as_ptr(&mut store, ctx, susp, 0)?;
           |    let arg0_text = ctx_api.call_unbox_string(&mut store, ctx, arg0)?;
           |    if arg0_text != "hello" {
           |        bail!("bad suspension arg: {}", arg0_text);
           |    }
           |    arg0.resource_drop(&mut store)?;
           |
           |    let ok = ctx_api.call_box_string(&mut store, ctx, "ok")?;
           |    match ctx_api.call_resume_test_suspendecho(&mut store, ctx, susp, ok)? {
           |        api::ExecString::Ok(v) if v == "ok" => {}
           |        other => bail!("bad resume result: {:?}", other),
           |    }
           |    ok.resource_drop(&mut store)?;
           |    ctx.resource_drop(&mut store)?;
           |
           |    println!("OK");
           |    Ok(())
           |}
           |""".stripMargin

      Files.writeString(hostDir.resolve("src").resolve("main.rs"), rustMain, StandardCharsets.UTF_8)

      val (exit, output) = runCmd(List(
        "cargo",
        "+stable",
        "run",
        "--quiet",
        "--manifest-path",
        hostDir.resolve("Cargo.toml").toString,
        "--",
        compiled.typedExportComponent.toString
      ))

      if (exit != 0) {
        fail(s"Typed Wasmtime host smoke failed with exit $exit:\n$output")
      }
      if (output.trim != "OK") {
        fail(s"Unexpected typed Wasmtime host output:\n$output")
      }
    } finally {
      deleteRecursive(hostDir)
      deleteRecursive(compiled.outDir)
    }
  }

  private def runNode(nodeFile: Path): (Int, String) = {
    runCmd(List("node", nodeFile.toAbsolutePath.normalize().toString))
  }

  private def runCmd(cmd: List[String]): (Int, String) = {
    val pb = new ProcessBuilder(cmd.asJava)
    pb.redirectErrorStream(true)
    val p = pb.start()
    val output = new String(p.getInputStream.readAllBytes(), StandardCharsets.UTF_8)
    val exit = p.waitFor()
    (exit, output)
  }

  private def hasZig: Boolean = hasCmd(List("zig", "version"))

  private def hasWasmTools: Boolean = hasCmd(List("wasm-tools", "--version"))

  private def hasJco: Boolean = hasCmd(List("jco", "--version"))

  private def hasNode: Boolean = hasCmd(List("node", "--version"))

  private def hasCargoStable: Boolean = hasCmd(List("cargo", "+stable", "--version"))

  private def hasCmd(cmd: List[String]): Boolean = {
    try {
      val p = new ProcessBuilder(cmd.asJava).redirectErrorStream(true).start()
      p.waitFor(2, TimeUnit.SECONDS) && p.exitValue() == 0
    } catch {
      case _: IOException => false
      case _: InterruptedException => false
    }
  }

  private def deleteRecursive(root: Path): Unit = {
    if (!Files.exists(root)) return
    Files.walk(root)
      .sorted(java.util.Comparator.reverseOrder())
      .iterator()
      .asScala
      .foreach(Files.deleteIfExists)
  }

  private def jsStringLiteral(s: String): String =
    "\"" + s.flatMap {
      case '\\' => "\\\\"
      case '"' => "\\\""
      case '\n' => "\\n"
      case '\r' => "\\r"
      case '\t' => "\\t"
      case c => c.toString
    } + "\""

  private def compileArtifacts(program: String): CompiledArtifacts = {
    val flixFile = Files.createTempFile("flix-llvm-wasm-export-", ".flix")
    val outDir = Files.createTempDirectory("flix-llvm-wasm-export-out-")

    Files.writeString(flixFile, program, StandardCharsets.UTF_8)

    try {
      val flix = new Flix()
      flix.setOptions(TestOptions.copy(outputPath = outDir, artifactName = "ffi-smoke"))
      implicit val sctx: SecurityContext = SecurityContext.Unrestricted
      flix.addFile(flixFile)

      val (optRoot, errors) = flix.check()
      if (errors.nonEmpty) {
        fail(CompilationMessage.formatAll(errors)(flix.getFormatter, optRoot))
      }

      flix.codeGen(optRoot.get)

      CompiledArtifacts(
        outDir = outDir,
        componentJs = ca.uwaterloo.flix.language.phase.llvm.LlvmWasmDriver.componentJsPath(outDir, "ffi-smoke"),
        bindingsJs = ca.uwaterloo.flix.language.phase.llvm.LlvmWasmBindingWriter.bindingsJsPath(outDir, "ffi-smoke"),
        bindingsTypes = ca.uwaterloo.flix.language.phase.llvm.LlvmWasmBindingWriter.bindingsTypesPath(outDir, "ffi-smoke"),
        typedExportComponent = ca.uwaterloo.flix.language.phase.llvm.LlvmWasmTypedExportsWriter.typedComponentPath(outDir, "ffi-smoke"),
        typedWitDir = ca.uwaterloo.flix.language.phase.llvm.LlvmWasmTypedExportsWriter.typedWitDirPath(outDir, "ffi-smoke")
      )
    } finally {
      Files.deleteIfExists(flixFile)
    }
  }

}
