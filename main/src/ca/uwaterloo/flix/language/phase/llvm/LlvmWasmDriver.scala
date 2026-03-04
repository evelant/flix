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
import ca.uwaterloo.flix.util.{Build, InternalCompilerException}

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
                       jsOutDir: Option[Path])

  private val BundledRuntimeZigResource: String = "/runtime/src/flix_rt_llvm.zig"
  private val BundledUnicodeCaseTablesZigResource: String = "/runtime/src/unicode_case_tables.zig"

  private val WitBindingsDir: Path =
    Paths.get("docs/planning/native-backend/wit/flix-bindings").toAbsolutePath.normalize()

  private val WitGlueC: Path =
    Paths.get("runtime/src/wit/flix.c").toAbsolutePath.normalize()

  private val DefaultSysJs: Path =
    Paths.get("tools/wasm-runner-js/sys.js").toAbsolutePath.normalize()

  def run(modulePath: Path)(implicit flix: Flix): Artifacts = {
    val outDir = flix.options.outputPath.resolve("llvm").toAbsolutePath
    Files.createDirectories(outDir)

    val wasmDir = outDir.resolve("wasm")
    Files.createDirectories(wasmDir)

    val optFlag = flix.options.build match {
      case Build.Development => "-O0"
      case Build.Production => "-O2"
    }

    val runtimeZig = resolveRuntimeZig(outDir)
    val runtimeObj = compileRuntime(runtimeZig, wasmDir, optFlag)
    val moduleObj = compileModule(modulePath, wasmDir, optFlag)
    val witObj = compileWitGlue(wasmDir, optFlag)

    val coreWasm = wasmDir.resolve("flix-llvm-wasm.core.wasm")
    linkCore(coreWasm, wasmDir, optFlag, List(moduleObj, runtimeObj, witObj))

    val embeddedCore = wasmDir.resolve("flix-llvm-wasm.core.embed.wasm")
    embedWit(coreWasm, embeddedCore, wasmDir)

    val componentWasm = wasmDir.resolve("flix-llvm-wasm.component.wasm")
    componentize(embeddedCore, componentWasm, wasmDir)

    val jsOutDir = Some(transpileToJs(componentWasm, wasmDir))

    Artifacts(coreWasm = coreWasm, componentWasm = componentWasm, jsOutDir = jsOutDir)
  }

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

    try {
      Files.copy(is, dest, StandardCopyOption.REPLACE_EXISTING)
      Files.copy(unicodeIs, unicodeDest, StandardCopyOption.REPLACE_EXISTING)
    } finally {
      is.close()
      unicodeIs.close()
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
  private def compileWitGlue(wasmDir: Path, optFlag: String): Path = {
    val out = wasmDir.resolve("flix_wit_glue.wasm.o")
    val cmd = List(
      "zig", "cc",
      "-target", "wasm32-wasi",
      "-c",
      optFlag,
      WitGlueC.toString,
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

  private def embedWit(inWasm: Path, outWasm: Path, cwd: Path): Unit = {
    if (!Files.exists(WitBindingsDir)) {
      throw InternalCompilerException(s"Missing WIT bindings directory: '$WitBindingsDir'.", SourceLocation.Unknown)
    }

    val cmd = List(
      "wasm-tools",
      "component",
      "embed",
      WitBindingsDir.toString,
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
    if (Files.exists(DefaultSysJs)) {
      Files.copy(DefaultSysJs, jsDir.resolve("sys.js"), StandardCopyOption.REPLACE_EXISTING)
    }

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
