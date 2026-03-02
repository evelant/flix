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

/**
  * Runtime smoke tests for the portable Process/ProcessWithResult primops on the LLVM-native backend.
  */
class PortableProcessLlvmNativeSuite extends AnyFunSuite {

  private val TestOptions: Options =
    Options.TestWithLibAll.copy(
      stdlibProfile = StdlibProfile.Portable,
      target = CompilationTarget.LlvmNative,
      incremental = false,
      outputJvm = false,
    )

  test("portable-process-llvm-native") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-native portable process runtime test)")

    val (cmd, args) =
      if (isWindows) ("cmd.exe", List("/c", "exit 42"))
      else ("/bin/sh", List("-c", "exit 42"))

    val flixArgs = args.map(escapeFlixString).mkString(" :: ") + " :: Nil"

    val program =
      s"""
         |def expect(cond: Bool, msg: String): Unit =
         |    if (cond) () else bug!(msg)
         |
         |def unexpectedErr(e: a): Unit with ToString[a] =
         |    expect(false, "unexpected Err: " + ToString.toString(e))
         |
         |def main(): Unit \\ IO = {
         |    let args = ${flixArgs};
         |    match ProcessWithResult.runWithIO(() -> ProcessWithResult.exec(${escapeFlixString(cmd)}, args)) {
         |        case Ok(ph) => {
         |            match ProcessWithResult.runWithIO(() -> ProcessWithResult.pid(ph)) {
         |                case Ok(pid) => expect(pid > 0i64, "expected pid > 0")
         |                case Err(e) => unexpectedErr(e)
         |            };
         |            match ProcessWithResult.runWithIO(() -> ProcessWithResult.waitFor(ph)) {
         |                case Ok(code) => expect(code == 42i32, "expected exit 42")
         |                case Err(e) => unexpectedErr(e)
         |            };
         |            match ProcessWithResult.runWithIO(() -> ProcessWithResult.exitValue(ph)) {
         |                case Ok(code) => expect(code == 42i32, "expected exitValue 42")
         |                case Err(e) => unexpectedErr(e)
         |            };
         |            match ProcessHandle.release(ph) {
         |                case Ok(_) => ()
         |                case Err(e) => unexpectedErr(e)
         |            };
         |            ()
         |        }
         |        case Err(e) => unexpectedErr(e)
         |    }
         |}
         |""".stripMargin

    val testFile = Files.createTempFile("flix-portable-process-llvm-native-", ".flix")
    Files.writeString(testFile, program, StandardCharsets.UTF_8)

    val outDir = Files.createTempDirectory("flix-llvm-native-process-")
    try {
      val exe = compileLlvmNative(testFile, outDir)
      val (exit, output) = runExecutable(exe)
      if (exit != 0) {
        fail(s"LLVM-native portable process test program failed with exit $exit:\n$output")
      }
    } finally {
      Files.deleteIfExists(testFile)
      deleteRecursive(outDir)
    }
  }

  private def escapeFlixString(s: String): String =
    "\"" + s.flatMap {
      case '\\' => "\\\\"
      case '"' => "\\\""
      case '\n' => "\\n"
      case '\r' => "\\r"
      case '\t' => "\\t"
      case c => c.toString
    } + "\""

  private def compileLlvmNative(file: Path, outDir: Path): Path = {
    val flix = new Flix()
    flix.setOptions(TestOptions.copy(outputPath = outDir))
    implicit val sctx: SecurityContext = SecurityContext.Unrestricted
    flix.addFile(file)

    val (optRoot, errors) = flix.check()
    if (errors.nonEmpty) {
      fail(CompilationMessage.formatAll(errors)(flix.getFormatter, optRoot))
    }

    flix.codeGen(optRoot.get)
    executablePath(outDir)
  }

  private def runExecutable(executable: Path): (Int, String) = {
    val pb = new ProcessBuilder(List(executable.toString).asJava)
    pb.redirectErrorStream(true)
    val p = pb.start()
    val output = new String(p.getInputStream.readAllBytes(), StandardCharsets.UTF_8)
    val exit = p.waitFor()
    (exit, output)
  }

  private def hasZig: Boolean = {
    try {
      val p = new ProcessBuilder("zig", "version").redirectErrorStream(true).start()
      p.waitFor(2, TimeUnit.SECONDS) && p.exitValue() == 0
    } catch {
      case _: IOException => false
      case _: InterruptedException => false
    }
  }

  private def executablePath(outDir: Path): Path = {
    val exeName = if (isWindows) "flix-llvm-native.exe" else "flix-llvm-native"
    outDir.resolve("llvm").resolve(exeName).toAbsolutePath.normalize()
  }

  private def isWindows: Boolean =
    System.getProperty("os.name", "").toLowerCase.contains("win")

  private def deleteRecursive(root: Path): Unit = {
    if (!Files.exists(root)) return
    val stream = Files.walk(root)
    try {
      stream.iterator().asScala.toList.sortBy(_.getNameCount).reverse.foreach(p => Files.deleteIfExists(p))
    } finally {
      stream.close()
    }
  }
}
