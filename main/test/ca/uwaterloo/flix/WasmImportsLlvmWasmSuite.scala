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

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths}
import scala.jdk.CollectionConverters.*

class WasmImportsLlvmWasmSuite extends AnyFunSuite {

  private val ArtifactName = "extern-wasm-sync"

  private val TestOptions: Options =
    Options.TestWithLibAll.copy(
      stdlibProfile = StdlibProfile.Portable,
      target = CompilationTarget.LlvmWasm,
      incremental = false,
      outputJvm = false,
    )

  private val FixtureFile: Path =
    Paths.get("main/test/flix/wasm/apps/extern_wasm_sync/Main.flix")

  private case class CompiledArtifacts(outDir: Path,
                                       bindingsJs: Path,
                                       bindingsTypes: Path,
                                       component: Path,
                                       witDir: Path)

  test("llvm-wasm-extern-imports-js-host") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-wasm extern import test)")
    assume(hasWasmTools, "wasm-tools not found on PATH (skipping LLVM-wasm extern import test)")
    assume(hasJco, "jco not found on PATH (skipping LLVM-wasm extern import test)")
    assume(hasNode, "node not found on PATH (skipping LLVM-wasm extern import test)")

    val compiled = compileArtifacts()
    val nodeFile = Files.createTempFile("flix-llvm-wasm-extern-import-js-", ".mjs")
    try {
      val bindingsText = Files.readString(compiled.bindingsJs, StandardCharsets.UTF_8)
      assert(bindingsText.contains("configureImports"))
      assert(bindingsText.contains("\"host:math/basic@0.1.0\""))

      val nodeProgram =
        s"""
           |import { configureImports, newCtx, Exports } from ${jsStringLiteral(compiled.bindingsJs.toUri.toString)};
           |
           |function assert(cond, msg) {
           |  if (!cond) throw new Error(msg);
           |}
           |
           |configureImports({
           |  "host:math/basic@0.1.0": {
           |    cos: (x) => Math.cos(x),
           |    neg: (x) => -x,
           |    iseven: (x) => (x % 2) === 0,
           |  },
           |});
           |
           |const disposeSym = Symbol.dispose ?? Symbol.for("dispose");
           |const ctx = newCtx();
           |try {
           |  const cosRes = Exports.Api.callCos(ctx, 1.0);
           |  assert(cosRes.tag === "ok" && Math.abs(cosRes.val - Math.cos(1.0)) < 1e-12, `bad cos: $${JSON.stringify(cosRes)}`);
           |
           |  const negRes = Exports.Api.callNeg(ctx, -42);
           |  assert(negRes.tag === "ok" && negRes.val === 42, `bad neg: $${JSON.stringify(negRes)}`);
           |
           |  const evenRes = Exports.Api.callIsEven(ctx, 8);
           |  assert(evenRes.tag === "ok" && evenRes.val === true, `bad even: $${JSON.stringify(evenRes)}`);
           |
           |  const oddRes = Exports.Api.callIsEven(ctx, 7);
           |  assert(oddRes.tag === "ok" && oddRes.val === false, `bad odd: $${JSON.stringify(oddRes)}`);
           |
           |  console.log("OK");
           |} finally {
           |  try {
           |    const fn = ctx?.[disposeSym];
           |    if (typeof fn === "function") fn.call(ctx);
           |  } catch {}
           |}
           |""".stripMargin

      Files.writeString(nodeFile, nodeProgram, StandardCharsets.UTF_8)

      val (exit, output) = runCmd(List("node", nodeFile.toString))
      if (exit != 0) {
        fail(s"JS extern wasm host failed with exit $exit:\n$output")
      }
      if (output.trim != "OK") {
        fail(s"Unexpected JS extern wasm host output:\n$output")
      }
    } finally {
      Files.deleteIfExists(nodeFile)
      deleteRecursive(compiled.outDir)
    }
  }

  test("llvm-wasm-extern-imports-wasmtime-host") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-wasm extern import test)")
    assume(hasWasmTools, "wasm-tools not found on PATH (skipping LLVM-wasm extern import test)")
    assume(hasJco, "jco not found on PATH (skipping LLVM-wasm extern import test)")
    assume(hasCargoStable, "cargo +stable not available (skipping LLVM-wasm extern import test)")

    val compiled = compileArtifacts()
    val hostDir = Files.createTempDirectory("flix-llvm-wasm-extern-import-wasmtime-")
    try {
      Files.createDirectories(hostDir.resolve("src"))
      Files.writeString(hostDir.resolve("Cargo.toml"),
        """
          |[package]
          |name = "extern_import_host"
          |version = "0.1.0"
          |edition = "2021"
          |
          |[dependencies]
          |anyhow = "1"
          |wasmtime = { version = "38", features = ["component-model"] }
          |""".stripMargin,
        StandardCharsets.UTF_8)

      Files.writeString(hostDir.resolve("src").resolve("main.rs"),
        s"""
           |use anyhow::{bail, Context, Result};
           |use wasmtime::{
           |    Config, Engine, Store,
           |    component::{Component, HasSelf, Linker},
           |};
           |
           |mod bindings {
           |    wasmtime::component::bindgen!({
           |        path: ${jsStringLiteral(compiled.witDir.toString)},
           |        world: "flix",
           |    });
           |}
           |
           |use bindings::exports::flix::exports::api;
           |use bindings::flix::sys::sys::{Capability, Host as SysHost, LogLevel};
           |use bindings::host::math::basic::Host as MathHost;
           |
           |#[derive(Default)]
           |struct State;
           |
           |impl SysHost for State {
           |    fn log(&mut self, _level: LogLevel, _msg: String) {}
           |    fn time_now_ms(&mut self) -> i64 { 0 }
           |    fn random_bytes(&mut self, len: u32) -> Vec<u8> { (0..len).map(|i| i as u8).collect() }
           |    fn get_args(&mut self) -> Vec<String> { Vec::new() }
           |    fn has_capability(&mut self, _cap: Capability) -> bool { false }
           |}
           |
           |impl MathHost for State {
           |    fn cos(&mut self, x: f64) -> f64 { x.cos() }
           |    fn neg(&mut self, x: i32) -> i32 { -x }
           |    fn iseven(&mut self, x: i32) -> bool { x % 2 == 0 }
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
           |    bindings::host::math::basic::add_to_linker::<_, HasSelf<_>>(&mut linker, |s| s)?;
           |
           |    let mut store = Store::new(&engine, State::default());
           |    let flix = bindings::Flix::instantiate(&mut store, &component, &linker)?;
           |    let api = flix.flix_exports_api();
           |    let ctx_api = api.ctx();
           |    let ctx = ctx_api.call_constructor(&mut store)?;
           |
           |    match ctx_api.call_api_callcos(&mut store, ctx, 1.0)? {
           |        api::ExecFloat64::Ok(v) if (v - 1.0f64.cos()).abs() < 1e-12 => {}
           |        other => bail!("bad cos result: {:?}", other),
           |    }
           |
           |    match ctx_api.call_api_callneg(&mut store, ctx, -42)? {
           |        api::ExecInt32::Ok(v) if v == 42 => {}
           |        other => bail!("bad neg result: {:?}", other),
           |    }
           |
           |    match ctx_api.call_api_calliseven(&mut store, ctx, 8)? {
           |        api::ExecBool::Ok(v) if v => {}
           |        other => bail!("bad isEven(8): {:?}", other),
           |    }
           |
           |    match ctx_api.call_api_calliseven(&mut store, ctx, 7)? {
           |        api::ExecBool::Ok(v) if !v => {}
           |        other => bail!("bad isEven(7): {:?}", other),
           |    }
           |
           |    println!("OK");
           |    Ok(())
           |}
           |""".stripMargin,
        StandardCharsets.UTF_8)

      val (exit, output) = runCmd(List(
        "cargo", "+stable", "run", "--quiet",
        "--manifest-path", hostDir.resolve("Cargo.toml").toString,
        "--", compiled.component.toString
      ))
      if (exit != 0) {
        fail(s"Wasmtime extern wasm host failed with exit $exit:\n$output")
      }
      if (output.trim != "OK") {
        fail(s"Unexpected Wasmtime extern wasm host output:\n$output")
      }
    } finally {
      deleteRecursive(hostDir)
      deleteRecursive(compiled.outDir)
    }
  }

  private def compileArtifacts(): CompiledArtifacts = {
    val outDir = Files.createTempDirectory("flix-llvm-wasm-import-out-")
    val flix = new Flix()
    flix.setOptions(TestOptions.copy(outputPath = outDir, artifactName = ArtifactName))
    implicit val sctx: SecurityContext = SecurityContext.Unrestricted
    flix.addFile(FixtureFile)

    val (optRoot, errors) = flix.check()
    if (errors.nonEmpty) {
      fail(CompilationMessage.formatAll(errors)(flix.getFormatter, optRoot))
    }

    flix.codeGen(optRoot.get)

    CompiledArtifacts(
      outDir = outDir,
      bindingsJs = ca.uwaterloo.flix.language.phase.llvm.LlvmExportSdkWriter.wasmBindingsJsPath(outDir, ArtifactName),
      bindingsTypes = ca.uwaterloo.flix.language.phase.llvm.LlvmExportSdkWriter.wasmBindingsTypesPath(outDir, ArtifactName),
      component = ca.uwaterloo.flix.language.phase.llvm.LlvmExportSdkWriter.wasmComponentPath(outDir, ArtifactName),
      witDir = ca.uwaterloo.flix.language.phase.llvm.LlvmExportSdkWriter.wasmWitDir(outDir),
    )
  }

  private def runCmd(cmd: List[String]): (Int, String) = {
    val pb = new ProcessBuilder(cmd.asJava)
    pb.redirectErrorStream(true)
    val p = pb.start()
    p.getOutputStream.close()
    val output = new String(p.getInputStream.readAllBytes(), StandardCharsets.UTF_8)
    val exit = p.waitFor()
    (exit, output)
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

  private def hasCommand(cmd: List[String]): Boolean = {
    val pb = new ProcessBuilder(cmd.asJava)
    pb.redirectErrorStream(true)
    try {
      val p = pb.start()
      val finished = p.waitFor()
      finished == 0
    } catch {
      case _: Throwable => false
    }
  }

  private def hasZig: Boolean = hasCommand(List("zig", "version"))
  private def hasWasmTools: Boolean = hasCommand(List("wasm-tools", "--version"))
  private def hasJco: Boolean = hasCommand(List("jco", "--version"))
  private def hasNode: Boolean = hasCommand(List("node", "--version"))
  private def hasCargoStable: Boolean = hasCommand(List("cargo", "+stable", "--version"))
}
