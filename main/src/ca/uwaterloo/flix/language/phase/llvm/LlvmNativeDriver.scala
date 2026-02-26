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
import java.nio.file.{Files, Path, StandardCopyOption}
import java.nio.file.Paths
import scala.jdk.CollectionConverters.*

/**
  * Drives the host toolchain to turn textual LLVM IR (`.ll`) into a native executable.
  *
  * Bring-up choice: use `zig cc` as the portable compiler+linker driver.
  */
object LlvmNativeDriver {

  case class Artifacts(executable: Path)

  private val BundledRuntimeZigResource: String = "/runtime/src/flix_rt_llvm.zig"

  /**
    * Compiles `modulePath` (a `.ll` file) into a native executable in `outputPath/llvm/`.
    */
  def run(modulePath: Path)(implicit flix: Flix): Artifacts = {
    val outDir = flix.options.outputPath.resolve("llvm").toAbsolutePath
    Files.createDirectories(outDir)

    val exeName = if (isWindows) "flix-llvm-native.exe" else "flix-llvm-native"
    val exePath = outDir.resolve(exeName)
    val runtimeObj = outDir.resolve("flix_rt_llvm.o")

    val optFlag = flix.options.build match {
      case Build.Development => "-O0"
      case Build.Production => "-O2"
    }

    val runtimeZig = resolveRuntimeZig(outDir)

    // Compile the Zig runtime to an object file.
    val compileRuntimeCmd = List(
      "zig",
      "cc",
      "-c",
      "-Wno-override-module",
      optFlag,
      runtimeZig.toString,
      "-o",
      runtimeObj.toString
    )
    val (rtExit, rtOutput) = exec(compileRuntimeCmd, outDir)
    if (rtExit != 0) {
      throw InternalCompilerException(
        s"LLVM-native toolchain failed while compiling runtime (exit $rtExit):\n${compileRuntimeCmd.mkString(" ")}\n\n$rtOutput",
        SourceLocation.Unknown
      )
    }

    val cmd = List(
      "zig",
      "cc",
      "-Wno-override-module",
      optFlag,
      modulePath.toString,
      runtimeObj.toString,
      "-o",
      exePath.toString
    )

    val (exitCode, output) = exec(cmd, outDir)
    if (exitCode != 0) {
      throw InternalCompilerException(
        s"LLVM-native toolchain failed (exit $exitCode):\n${cmd.mkString(" ")}\n\n$output",
        SourceLocation.Unknown
      )
    }

    Artifacts(exePath)
  }

  /**
    * Resolves the Zig runtime support file for the LLVM-native backend.
    *
    * Bring-up behavior:
    *   1. Prefer `runtime/src/flix_rt_llvm.zig` relative to the current working directory.
    *   2. Otherwise, extract the bundled resource from `flix.jar` into `outDir`.
    */
  private def resolveRuntimeZig(outDir: Path): Path = {
    val cwdRuntime = Paths.get("runtime/src/flix_rt_llvm.zig").toAbsolutePath.normalize()
    if (Files.exists(cwdRuntime)) return cwdRuntime

    val dest = outDir.resolve("flix_rt_llvm.zig").toAbsolutePath.normalize()
    val is = Option(getClass.getResourceAsStream(BundledRuntimeZigResource)).getOrElse {
      throw InternalCompilerException(
        s"Missing LLVM runtime support file: '$cwdRuntime' and no bundled resource '$BundledRuntimeZigResource' found.",
        SourceLocation.Unknown
      )
    }

    try {
      Files.copy(is, dest, StandardCopyOption.REPLACE_EXISTING)
    } finally {
      is.close()
    }

    dest
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

  private def isWindows: Boolean =
    System.getProperty("os.name", "").toLowerCase.contains("win")

}
