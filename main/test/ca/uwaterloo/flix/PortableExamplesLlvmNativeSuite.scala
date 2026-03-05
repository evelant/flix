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
import java.nio.file.{Files, Path, Paths}
import java.util.concurrent.TimeUnit
import scala.jdk.CollectionConverters.*

/**
  * End-to-end "portable examples" for the LLVM-native backend.
  *
  * This suite is intentionally whitelist-based:
  *   - examples must compile with `StdlibProfile.Portable`,
  *   - examples must run deterministically and terminate quickly,
  *   - examples must avoid JVM interop and external network dependencies.
  */
class PortableExamplesLlvmNativeSuite extends AnyFunSuite {

  private val TestOptions: Options =
    Options.TestWithLibAll.copy(
      stdlibProfile = StdlibProfile.Portable,
      target = CompilationTarget.LlvmNative,
      incremental = false,
      outputJvm = false,
    )

  private case class Example(name: String, file: Path, expectedStdoutTrim: String, timeoutSeconds: Long = 15)

  // Keep this list small and stable; add new examples intentionally as the LLVM backend grows.
  private val Examples: List[Example] = List(
    Example(
      name = "functional-adt-pattern",
      file = Paths.get("examples/functional-style/algebraic-data-types-and-pattern-matching.flix"),
      expectedStdoutTrim = "8"
    ),
    Example(
      name = "functional-hof",
      file = Paths.get("examples/functional-style/higher-order-functions.flix"),
      expectedStdoutTrim = "127"
    ),
    Example(
      name = "functional-pipeline",
      file = Paths.get("examples/functional-style/function-composition-pipelines-and-currying.flix"),
      expectedStdoutTrim = "true"
    ),
    Example(
      name = "functional-lists",
      file = Paths.get("examples/functional-style/lists-and-list-processing.flix"),
      expectedStdoutTrim = "22"
    ),
    Example(
      name = "functional-tce-mutual",
      file = Paths.get("examples/functional-style/mutual-recursion-with-full-tail-call-elimination.flix"),
      expectedStdoutTrim = "true"
    ),
    Example(
      name = "modules-declaring",
      file = Paths.get("examples/modules/declaring-a-module.flix"),
      expectedStdoutTrim = "579"
    ),
    Example(
      name = "records-poly-update",
      file = Paths.get("examples/records/polymorphic-record-update.flix"),
      expectedStdoutTrim = "4"
    ),
    Example(
      name = "package-minimal-main",
      file = Paths.get("examples/package-manager/minimal-project/src/Main.flix"),
      expectedStdoutTrim = "Hello World!"
    ),
  )

  for (Example(name, file, expected, timeoutSeconds) <- Examples) {
    test(s"llvm-native-portable-example-$name") {
      assume(hasZig, "zig not found on PATH (skipping LLVM-native portable examples)")

      val outDir = Files.createTempDirectory(s"flix-llvm-native-portable-example-$name-")
      try {
        val exe = compileLlvmNative(file, outDir)
        val (exit, output) = runExecutable(exe, timeoutSeconds = timeoutSeconds)
        if (exit != 0) {
          fail(s"Example '$name' failed with exit $exit:\n$output")
        }
        val trimmed = output.trim
        if (trimmed != expected) {
          fail(s"Example '$name' output mismatch.\nExpected: '$expected'\nActual:   '$trimmed'\nRaw:\n$output")
        }
      } finally {
        deleteRecursive(outDir)
      }
    }
  }

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

  private def runExecutable(executable: Path, timeoutSeconds: Long): (Int, String) = {
    val pb = new ProcessBuilder(List(executable.toString).asJava)
    pb.redirectErrorStream(true)

    val p = pb.start()
    p.getOutputStream.close()

    val baos = new java.io.ByteArrayOutputStream()
    val is = p.getInputStream

    val readerThread = new Thread(() => {
      val buf = new Array[Byte](8192)
      try {
        var n = is.read(buf)
        while (n != -1) {
          baos.write(buf, 0, n)
          n = is.read(buf)
        }
      } catch {
        case _: IOException => ()
      }
    })
    readerThread.setDaemon(true)
    readerThread.start()

    val finished = p.waitFor(timeoutSeconds, TimeUnit.SECONDS)
    if (!finished) {
      p.destroyForcibly()
      p.waitFor(2, TimeUnit.SECONDS)
    }

    readerThread.join(1_000)

    val output = new String(baos.toByteArray, StandardCharsets.UTF_8)
    if (!finished) {
      fail(s"Process timed out after ${timeoutSeconds}s. Output so far:\n$output")
    }
    (p.exitValue(), output)
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

