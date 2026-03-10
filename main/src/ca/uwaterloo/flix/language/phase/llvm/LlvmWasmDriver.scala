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

package ca.uwaterloo.flix.language.phase.llvm

import ca.uwaterloo.flix.api.Flix
import ca.uwaterloo.flix.language.ast.SourceLocation
import ca.uwaterloo.flix.util.{ArtifactNames, Build, InternalCompilerException}

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths, StandardCopyOption}
import scala.jdk.CollectionConverters.*

/**
  * Drives the host toolchain to turn textual LLVM IR (`.ll`) into a wasm component + JS package.
  *
  * Browser-first bring-up:
  *   - core module is `wasm32-freestanding` (no WASI preview1),
  *   - the component world is described by WIT (`docs/planning/native-backend/wit/flix-bindings`),
  *   - we use `wasm-tools component embed/new` to produce a component,
  *   - we optionally use `jco transpile` to generate a browser/Node-friendly JS bundle.
  */
object LlvmWasmDriver {

  case class Artifacts(coreWasm: Path,
                       componentWasm: Path,
                       componentJs: Path,
                       exportsManifest: Path,
                       jsOutDir: Path,
                       nodeRunner: Path)

  private val BundledRuntimeZigResource: String = "/runtime/src/flix_rt_llvm.zig"
  private val BundledUnicodeCaseTablesZigResource: String = "/runtime/src/unicode_case_tables.zig"
  private val BundledRegexRuntimeZigResource: String = "/runtime/src/rt_regex.zig"
  private val BundledWitGlueCResource: String = "/runtime/src/wit/flix.c"
  private val BundledWitGlueHResource: String = "/runtime/src/wit/flix.h"
  private val BundledSysJsResource: String = "/tools/wasm-runner-js/sys.js"
  private val BundledRunFlixResource: String = "/tools/wasm-runner-js/run-flix.mjs"
  private val BundledRunnerResource: String = "/tools/wasm-runner-js/runner.mjs"
  private val BundledNodeHandlersResource: String = "/tools/wasm-runner-js/node-handlers.mjs"
  private val BundledNodeTcpHandlersResource: String = "/tools/wasm-runner-js/node-tcp-handlers.mjs"
  private val BundledNodeProcessHandlersResource: String = "/tools/wasm-runner-js/node-process-handlers.mjs"
  private val BundledWasmtimeCargoTomlResource: String = "/tools/wasm-runner-rs/Cargo.toml"
  private val BundledWasmtimeCargoLockResource: String = "/tools/wasm-runner-rs/Cargo.lock"
  private val BundledWasmtimeLibResource: String = "/tools/wasm-runner-rs/src/lib.rs"
  private val BundledWasmtimeHostResource: String = "/tools/wasm-runner-rs/src/host.rs"
  private val BundledWasmtimeRunnerResource: String = "/tools/wasm-runner-rs/src/runner.rs"
  private val BundledWasmtimeBinResource: String = "/tools/wasm-runner-rs/src/bin/run_flix.rs"
  private val BundledWitBindingsResource: String = "/docs/planning/native-backend/wit/flix-bindings/bindings.wit"
  private val BundledWitRuntimeDepResource: String = "/docs/planning/native-backend/wit/flix-bindings/deps/runtime.wit"
  private val BundledWitSysDepResource: String = "/docs/planning/native-backend/wit/flix-bindings/deps/sys.wit"

  private val DefaultWitBindingsDir: Path =
    Paths.get("docs/planning/native-backend/wit/flix-bindings").toAbsolutePath.normalize()

  private val DefaultWitGlueDir: Path =
    Paths.get("runtime/src/wit").toAbsolutePath.normalize()

  private val DefaultSysJs: Path =
    Paths.get("tools/wasm-runner-js/sys.js").toAbsolutePath.normalize()

  private val DefaultNodeRunner: Path =
    Paths.get("tools/wasm-runner-js/run-flix.mjs").toAbsolutePath.normalize()

  private val DefaultRunnerModule: Path =
    Paths.get("tools/wasm-runner-js/runner.mjs").toAbsolutePath.normalize()

  private val DefaultNodeHandlersModule: Path =
    Paths.get("tools/wasm-runner-js/node-handlers.mjs").toAbsolutePath.normalize()

  private val DefaultNodeTcpHandlersModule: Path =
    Paths.get("tools/wasm-runner-js/node-tcp-handlers.mjs").toAbsolutePath.normalize()

  private val DefaultNodeProcessHandlersModule: Path =
    Paths.get("tools/wasm-runner-js/node-process-handlers.mjs").toAbsolutePath.normalize()

  private val DefaultWasmtimeRunnerCargoToml: Path =
    Paths.get("tools/wasm-runner-rs/Cargo.toml").toAbsolutePath.normalize()

  def run(modulePath: Path, emitJs: Boolean = true)(implicit flix: Flix): Artifacts = {
    val outDir = flix.options.outputPath.resolve("llvm").toAbsolutePath
    Files.createDirectories(outDir)

    val wasmDir = wasmDirPath(flix.options.outputPath)
    Files.createDirectories(wasmDir)

    val optFlag = flix.options.build match {
      case Build.Development => "-O0"
      case Build.Production => "-O2"
    }

    val runtimeZig = resolveRuntimeZig(outDir)
    val witBindingsDir = resolveWitBindingsDir(outDir)
    val witGlueC = resolveWitGlue(outDir)
    val runtimeObj = compileRuntime(runtimeZig, wasmDir, optFlag)
    val moduleObj = compileModule(modulePath, wasmDir, optFlag)
    val witObj = compileWitGlue(witGlueC, wasmDir, optFlag)

    val coreWasm = coreWasmPath(flix.options.outputPath, flix.options.artifactName)
    linkCore(coreWasm, wasmDir, optFlag, List(moduleObj, runtimeObj, witObj))

    val embeddedCore = wasmDir.resolve("flix-llvm-wasm.core.embed.wasm")
    embedWit(coreWasm, embeddedCore, wasmDir, witBindingsDir)

    val componentWasm = componentWasmPath(flix.options.outputPath, flix.options.artifactName)
    componentize(embeddedCore, componentWasm, wasmDir)

    if (emitJs) {
      transpileToJs(componentWasm, wasmDir)
    }
    val jsOutDir = jsOutDirPath(flix.options.outputPath)
    val componentJs = componentJsPath(flix.options.outputPath, flix.options.artifactName)
    val nodeRunner = if (emitJs) resolveNodeRunner(outDir) else outDir.resolve("wasm-runner-js").resolve("run-flix.mjs")
    val exportsManifest = LlvmWasmExportWriter.manifestPath(flix.options.outputPath, flix.options.artifactName)

    Artifacts(
      coreWasm = coreWasm,
      componentWasm = componentWasm,
      componentJs = componentJs,
      exportsManifest = exportsManifest,
      jsOutDir = jsOutDir,
      nodeRunner = nodeRunner
    )
  }

  def wasmDirPath(outputPath: Path): Path =
    outputPath.resolve("llvm").resolve("wasm").toAbsolutePath.normalize()

  def coreWasmPath(outputPath: Path, artifactName: String = ArtifactNames.DefaultBaseName): Path =
    wasmDirPath(outputPath).resolve(ArtifactNames.wasmCoreFileName(artifactName))

  def componentWasmPath(outputPath: Path, artifactName: String = ArtifactNames.DefaultBaseName): Path =
    wasmDirPath(outputPath).resolve(ArtifactNames.wasmComponentFileName(artifactName))

  def jsOutDirPath(outputPath: Path): Path =
    wasmDirPath(outputPath).resolve("js")

  def componentJsPath(outputPath: Path, artifactName: String = ArtifactNames.DefaultBaseName): Path =
    jsOutDirPath(outputPath).resolve(ArtifactNames.wasmComponentJsFileName(artifactName))

  /**
    * Resolves the Zig runtime support file for the LLVM backend.
    *
    * Bring-up behavior:
    *   1. Prefer `runtime/src/flix_rt_llvm.zig` relative to the current working directory.
    *   2. Otherwise, extract the bundled resource from `flix.jar` into `outDir`.
    */
  private def resolveRuntimeZig(outDir: Path): Path = {
    val cwdRuntime = Paths.get("runtime/src/flix_rt_llvm.zig").toAbsolutePath.normalize()
    if (Files.exists(cwdRuntime)) return cwdRuntime

    val dest = outDir.resolve("flix_rt_llvm.zig").toAbsolutePath.normalize()
    val unicodeDest = outDir.resolve("unicode_case_tables.zig").toAbsolutePath.normalize()
    val regexDest = outDir.resolve("rt_regex.zig").toAbsolutePath.normalize()
    val is = Option(getClass.getResourceAsStream(BundledRuntimeZigResource)).getOrElse {
      throw InternalCompilerException(
        s"Missing LLVM runtime support file: '$cwdRuntime' and no bundled resource '$BundledRuntimeZigResource' found.",
        SourceLocation.Unknown
      )
    }
    val unicodeIs = Option(getClass.getResourceAsStream(BundledUnicodeCaseTablesZigResource)).getOrElse {
      throw InternalCompilerException(
        s"Missing LLVM runtime support file: '$cwdRuntime' and no bundled resource '$BundledUnicodeCaseTablesZigResource' found.",
        SourceLocation.Unknown
      )
    }
    val regexIs = Option(getClass.getResourceAsStream(BundledRegexRuntimeZigResource)).getOrElse {
      throw InternalCompilerException(
        s"Missing LLVM runtime support file: '$cwdRuntime' and no bundled resource '$BundledRegexRuntimeZigResource' found.",
        SourceLocation.Unknown
      )
    }

    try {
      Files.copy(is, dest, StandardCopyOption.REPLACE_EXISTING)
      Files.copy(unicodeIs, unicodeDest, StandardCopyOption.REPLACE_EXISTING)
      Files.copy(regexIs, regexDest, StandardCopyOption.REPLACE_EXISTING)
    } finally {
      is.close()
      unicodeIs.close()
      regexIs.close()
    }

    dest
  }

  private def compileRuntime(runtimeZig: Path, wasmDir: Path, optFlag: String): Path = {
    val out = wasmDir.resolve("flix_rt_llvm.wasm.o")
    val cmd = List(
      "zig", "cc",
      "-target", "wasm32-freestanding",
      "-c",
      "-Wno-override-module",
      optFlag,
      runtimeZig.toString,
      "-o", out.toString
    )
    val (exit, output) = exec(cmd, wasmDir)
    if (exit != 0) {
      throw InternalCompilerException(
        s"LLVM-wasm toolchain failed while compiling runtime (exit $exit):\n${cmd.mkString(" ")}\n\n$output",
        SourceLocation.Unknown
      )
    }
    out
  }

  private def compileModule(modulePath: Path, wasmDir: Path, optFlag: String): Path = {
    val out = wasmDir.resolve("module.wasm.o")
    val cmd = List(
      "zig", "cc",
      "-target", "wasm32-freestanding",
      "-c",
      "-Wno-override-module",
      optFlag,
      modulePath.toString,
      "-o", out.toString
    )
    val (exit, output) = exec(cmd, wasmDir)
    if (exit != 0) {
      throw InternalCompilerException(
        s"LLVM-wasm toolchain failed while compiling module object (exit $exit):\n${cmd.mkString(" ")}\n\n$output",
        SourceLocation.Unknown
      )
    }
    out
  }

  /**
    * Compiles the generated WIT C glue.
    *
    * Bring-up shortcut: compile as `wasm32-wasi` (headers available) but link into a freestanding core module.
    * This avoids introducing a WASI dependency as long as we do not link wasi-libc.
    */
  private def compileWitGlue(witGlueC: Path, wasmDir: Path, optFlag: String): Path = {
    val out = wasmDir.resolve("flix_wit_glue.wasm.o")
    val cmd = List(
      "zig", "cc",
      "-target", "wasm32-wasi",
      "-c",
      optFlag,
      witGlueC.toString,
      "-o", out.toString
    )
    val (exit, output) = exec(cmd, wasmDir)
    if (exit != 0) {
      throw InternalCompilerException(
        s"LLVM-wasm toolchain failed while compiling WIT glue (exit $exit):\n${cmd.mkString(" ")}\n\n$output",
        SourceLocation.Unknown
      )
    }
    out
  }

  private def linkCore(outWasm: Path, wasmDir: Path, optFlag: String, objs: List[Path]): Unit = {
    val cmd = List(
      "zig", "cc",
      "-target", "wasm32-freestanding",
      "-Wl,--no-entry",
      // Canonical ABI requires `cabi_realloc` to be exported by the core module.
      // (The implementation is provided by `runtime/src/flix_rt_llvm.zig`.)
      "-Wl,--export=cabi_realloc",
      optFlag
    ) ::: objs.map(_.toString) ::: List("-o", outWasm.toString)

    val (exit, output) = exec(cmd, wasmDir)
    if (exit != 0) {
      throw InternalCompilerException(
        s"LLVM-wasm toolchain failed while linking core wasm (exit $exit):\n${cmd.mkString(" ")}\n\n$output",
        SourceLocation.Unknown
      )
    }
  }

  private def embedWit(inWasm: Path, outWasm: Path, cwd: Path, witBindingsDir: Path): Unit = {
    if (!Files.exists(witBindingsDir)) {
      throw InternalCompilerException(s"Missing WIT bindings directory: '$witBindingsDir'.", SourceLocation.Unknown)
    }

    val cmd = List(
      "wasm-tools",
      "component",
      "embed",
      witBindingsDir.toString,
      inWasm.toString,
      "--world",
      "flix",
      "-o",
      outWasm.toString
    )
    val (exit, output) = exec(cmd, cwd)
    if (exit != 0) {
      throw InternalCompilerException(
        s"wasm-tools failed while embedding WIT metadata (exit $exit):\n${cmd.mkString(" ")}\n\n$output",
        SourceLocation.Unknown
      )
    }
  }

  private def componentize(inWasm: Path, outComponent: Path, cwd: Path): Unit = {
    val cmd = List(
      "wasm-tools",
      "component",
      "new",
      inWasm.toString,
      "-o",
      outComponent.toString
    )
    val (exit, output) = exec(cmd, cwd)
    if (exit != 0) {
      throw InternalCompilerException(
        s"wasm-tools failed while creating a component (exit $exit):\n${cmd.mkString(" ")}\n\n$output",
        SourceLocation.Unknown
      )
    }
  }

  private def transpileToJs(component: Path, wasmDir: Path): Path = {
    val jsDir = wasmDir.resolve("js")
    Files.createDirectories(jsDir)

    // Ensure a default sys implementation is available for the transpiled output.
    // Hosts are free to ignore/replace this mapping.
    copyDefaultSysJs(jsDir)

    val cmd = List(
      "jco",
      "transpile",
      component.toString,
      "-o",
      jsDir.toString,
      "--map",
      "flix:sys/sys=./sys.js"
    )

    val (exit, output) = exec(cmd, wasmDir)
    if (exit != 0) {
      throw InternalCompilerException(
        s"jco transpile failed (exit $exit):\n${cmd.mkString(" ")}\n\n$output",
        SourceLocation.Unknown
      )
    }

    jsDir
  }

  private def copyDefaultSysJs(jsDir: Path): Unit = {
    val dest = jsDir.resolve("sys.js")
    if (Files.exists(DefaultSysJs)) {
      Files.copy(DefaultSysJs, dest, StandardCopyOption.REPLACE_EXISTING)
      return
    }

    copyBundledResource(BundledSysJsResource, dest)
  }

  private def resolveNodeRunner(outDir: Path): Path = {
    if (Files.exists(DefaultNodeRunner)
      && Files.exists(DefaultRunnerModule)
      && Files.exists(DefaultNodeHandlersModule)
      && Files.exists(DefaultNodeTcpHandlersModule)
      && Files.exists(DefaultNodeProcessHandlersModule)) {
      return DefaultNodeRunner
    }

    val runnerDir = outDir.resolve("wasm-runner-js")
    Files.createDirectories(runnerDir)

    copyBundledResource(BundledRunFlixResource, runnerDir.resolve("run-flix.mjs"))
    copyBundledResource(BundledRunnerResource, runnerDir.resolve("runner.mjs"))
    copyBundledResource(BundledNodeHandlersResource, runnerDir.resolve("node-handlers.mjs"))
    copyBundledResource(BundledNodeTcpHandlersResource, runnerDir.resolve("node-tcp-handlers.mjs"))
    copyBundledResource(BundledNodeProcessHandlersResource, runnerDir.resolve("node-process-handlers.mjs"))

    runnerDir.resolve("run-flix.mjs")
  }

  def resolveWasmtimeRunnerManifest(outputPath: Path): Path = {
    val outDir = outputPath.resolve("llvm").toAbsolutePath.normalize()
    if (Files.exists(DefaultWasmtimeRunnerCargoToml)) {
      return DefaultWasmtimeRunnerCargoToml
    }

    val runnerDir = outDir.resolve("tools").resolve("wasm-runner-rs")
    Files.createDirectories(runnerDir.resolve("src").resolve("bin"))
    copyBundledResource(BundledWasmtimeCargoTomlResource, runnerDir.resolve("Cargo.toml"))
    copyBundledResource(BundledWasmtimeCargoLockResource, runnerDir.resolve("Cargo.lock"))
    copyBundledResource(BundledWasmtimeLibResource, runnerDir.resolve("src").resolve("lib.rs"))
    copyBundledResource(BundledWasmtimeHostResource, runnerDir.resolve("src").resolve("host.rs"))
    copyBundledResource(BundledWasmtimeRunnerResource, runnerDir.resolve("src").resolve("runner.rs"))
    copyBundledResource(BundledWasmtimeBinResource, runnerDir.resolve("src").resolve("bin").resolve("run_flix.rs"))

    val witDir = outDir.resolve("docs").resolve("planning").resolve("native-backend").resolve("wit").resolve("flix-bindings")
    Files.createDirectories(witDir.resolve("deps"))
    copyBundledResource(BundledWitBindingsResource, witDir.resolve("bindings.wit"))
    copyBundledResource(BundledWitRuntimeDepResource, witDir.resolve("deps").resolve("runtime.wit"))
    copyBundledResource(BundledWitSysDepResource, witDir.resolve("deps").resolve("sys.wit"))

    runnerDir.resolve("Cargo.toml")
  }

  private def resolveWitBindingsDir(outDir: Path): Path = {
    if (Files.exists(DefaultWitBindingsDir)) {
      return DefaultWitBindingsDir
    }

    val bindingsDir = outDir.resolve("wit-bindings")
    Files.createDirectories(bindingsDir.resolve("deps"))
    copyBundledResource(BundledWitBindingsResource, bindingsDir.resolve("bindings.wit"))
    copyBundledResource(BundledWitRuntimeDepResource, bindingsDir.resolve("deps").resolve("runtime.wit"))
    copyBundledResource(BundledWitSysDepResource, bindingsDir.resolve("deps").resolve("sys.wit"))
    bindingsDir
  }

  private def resolveWitGlue(outDir: Path): Path = {
    val witGlueC = DefaultWitGlueDir.resolve("flix.c")
    val witGlueH = DefaultWitGlueDir.resolve("flix.h")
    if (Files.exists(witGlueC) && Files.exists(witGlueH)) {
      return witGlueC
    }

    val witDir = outDir.resolve("wit")
    Files.createDirectories(witDir)
    copyBundledResource(BundledWitGlueCResource, witDir.resolve("flix.c"))
    copyBundledResource(BundledWitGlueHResource, witDir.resolve("flix.h"))
    witDir.resolve("flix.c")
  }

  private def copyBundledResource(resource: String, dest: Path): Unit = {
    val is = Option(getClass.getResourceAsStream(resource)).getOrElse {
      throw InternalCompilerException(
        s"Missing LLVM-wasm support resource '$resource'.",
        SourceLocation.Unknown
      )
    }

    try {
      Files.copy(is, dest, StandardCopyOption.REPLACE_EXISTING)
    } finally {
      is.close()
    }
  }

  private def exec(cmd: List[String], cwd: Path): (Int, String) = {
    val pb = new ProcessBuilder(cmd.asJava)
    pb.redirectErrorStream(true)
    pb.directory(cwd.toFile)

    val p = pb.start()
    val output = new String(p.getInputStream.readAllBytes(), StandardCharsets.UTF_8)
    val exit = p.waitFor()
    (exit, output)
  }
}
