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
import ca.uwaterloo.flix.util.{CompilationTarget, FileOps, Options, StdlibProfile}
import org.scalatest.funsuite.AnyFunSuite

import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths}
import java.util.concurrent.TimeUnit
import scala.jdk.CollectionConverters.*

/**
  * End-to-end runtime smoke tests for the portable conformance suite on the LLVM-native backend.
  *
  * This compiles+links+executes a small driver that calls the portable `@Test` functions explicitly.
  */
class PortableStdlibLlvmNativeRuntimeSuite extends AnyFunSuite {

  private val TestOptions: Options =
    Options.TestWithLibAll.copy(
      stdlibProfile = StdlibProfile.Portable,
      target = CompilationTarget.LlvmNative,
      incremental = false,
      outputJvm = false,
    )

  private val portableTestsDir = Paths.get("main/test/flix/portable")

  test("portable-stdlib-llvm-native-runtime") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-native portable stdlib runtime test)")

    val driverFile = Files.createTempFile("flix-portable-llvm-native-driver-", ".flix")
    val outDir = Files.createTempDirectory("flix-llvm-native-portable-runtime-")
    try {
      Files.writeString(driverFile, driverSource, StandardCharsets.UTF_8)

      val flix = new Flix()
      flix.setOptions(TestOptions.copy(outputPath = outDir))
      implicit val sctx: SecurityContext = SecurityContext.Unrestricted

      for (p <- FileOps.getFlixFilesIn(portableTestsDir, 1)) flix.addFile(p)
      flix.addFile(driverFile)

      val (optRoot, errors) = flix.check()
      if (errors.nonEmpty) {
        fail(CompilationMessage.formatAll(errors)(flix.getFormatter, optRoot))
      }

      flix.codeGen(optRoot.get)

      val (exit, output) = runExecutable(executablePath(outDir))
      if (exit != 0) {
        fail(s"LLVM-native portable conformance driver failed with exit $exit:\n$output")
      }
    } finally {
      Files.deleteIfExists(driverFile)
      deleteRecursive(outDir)
    }
  }

  test("portable-uncaught-exception-llvm-native") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-native portable uncaught exception test)")

    val driverFile = Files.createTempFile("flix-portable-llvm-native-uncaught-exn-", ".flix")
    val outDir = Files.createTempDirectory("flix-llvm-native-portable-uncaught-exn-")
    try {
      Files.writeString(driverFile, uncaughtExnDriverSource, StandardCharsets.UTF_8)

      val flix = new Flix()
      flix.setOptions(TestOptions.copy(outputPath = outDir))
      implicit val sctx: SecurityContext = SecurityContext.Unrestricted

      flix.addFile(driverFile)

      val (optRoot, errors) = flix.check()
      if (errors.nonEmpty) {
        fail(CompilationMessage.formatAll(errors)(flix.getFormatter, optRoot))
      }

      flix.codeGen(optRoot.get)

      val (exit, output) = runExecutable(executablePath(outDir))
      if (exit != 1) {
        fail(s"Expected exit code 1 for uncaught exception, but got $exit:\n$output")
      }
      if (!output.contains("Uncaught Flix exception")) {
        fail(s"Expected uncaught exception report, but output was:\n$output")
      }
      if (!output.contains("  at ")) {
        fail(s"Expected at least one trace frame, but output was:\n$output")
      }
      if (!output.contains("Test.Portable.UncaughtExn")) {
        fail(s"Expected trace to contain def symbol names, but output was:\n$output")
      }
    } finally {
      Files.deleteIfExists(driverFile)
      deleteRecursive(outDir)
    }
  }

  test("portable-unhandled-suspension-llvm-native") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-native portable unhandled suspension test)")

    val driverFile = Files.createTempFile("flix-portable-llvm-native-unhandled-susp-", ".flix")
    val outDir = Files.createTempDirectory("flix-llvm-native-portable-unhandled-susp-")
    try {
      Files.writeString(driverFile, unhandledSuspensionDriverSource, StandardCharsets.UTF_8)

      val flix = new Flix()
      flix.setOptions(TestOptions.copy(outputPath = outDir))
      implicit val sctx: SecurityContext = SecurityContext.Unrestricted

      flix.addFile(driverFile)

      val (optRoot, errors) = flix.check()
      if (errors.nonEmpty) {
        fail(CompilationMessage.formatAll(errors)(flix.getFormatter, optRoot))
      }

      flix.codeGen(optRoot.get)

      val (exit, output) = runExecutable(executablePath(outDir))
      if (exit != 1) {
        fail(s"Expected exit code 1 for unhandled suspension, but got $exit:\n$output")
      }
      if (!output.contains("Unhandled Flix suspension")) {
        fail(s"Expected unhandled suspension report, but output was:\n$output")
      }
      if (!output.contains("Boom.boom")) {
        fail(s"Expected suspension report to contain effect/op names, but output was:\n$output")
      }
    } finally {
      Files.deleteIfExists(driverFile)
      deleteRecursive(outDir)
    }
  }

  test("llvm-native-gc-stress") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-native GC stress test)")

    val driverFile = Files.createTempFile("flix-llvm-native-gc-stress-", ".flix")
    val outDir = Files.createTempDirectory("flix-llvm-native-gc-stress-")
    try {
      Files.writeString(driverFile, gcStressDriverSource, StandardCharsets.UTF_8)

      val flix = new Flix()
      flix.setOptions(TestOptions.copy(outputPath = outDir))
      implicit val sctx: SecurityContext = SecurityContext.Unrestricted

      flix.addFile(driverFile)

      val (optRoot, errors) = flix.check()
      if (errors.nonEmpty) {
        fail(CompilationMessage.formatAll(errors)(flix.getFormatter, optRoot))
      }

      flix.codeGen(optRoot.get)

      val (exit, output) = runExecutable(
        executablePath(outDir),
        Map(
          "FLIX_GC_STRESS" -> "1",
          // Keep the heap tiny to ensure collections are requested frequently.
          "FLIX_GC_HEAP_LIMIT_BYTES" -> "65536",
        ),
      )

      if (exit != 0) {
        fail(s"LLVM-native GC stress driver failed with exit $exit:\n$output")
      }
      if (!output.contains("gc-stress: done")) {
        fail(s"Expected GC stress driver to complete, but output was:\n$output")
      }
    } finally {
      Files.deleteIfExists(driverFile)
      deleteRecursive(outDir)
    }
  }

  private val driverSource: String =
    """
      |mod Test {}
      |
      |def main(): Unit \ {Chan, NonDet, IO} = {
      |    %%PRINTLN%%("portable-stdlib-llvm-native-runtime: start");
      |
      |    %%PRINTLN%%("portable: Channel");
      |    let _ = Test.Portable.Channel.runAll();
      |
      |    %%PRINTLN%%("portable: DnsPingSignatures");
      |    let _ = Test.Portable.DnsPingSignatures.runAll();
      |
      |    %%PRINTLN%%("portable: FileSystem");
      |    let _ = Test.Portable.FileSystem.runAll();
      |
      |    %%PRINTLN%%("portable: BufReader");
      |    let _ = Test.Portable.BufReaderSuite.runAll();
      |
      |    %%PRINTLN%%("portable: NetAddrs");
      |    let _ = Test.Portable.NetAddrs.runAll();
      |
      |    %%PRINTLN%%("portable: Parsing");
      |    let _ = Test.Portable.Parsing.runAll();
      |
      |    %%PRINTLN%%("portable: Regex");
      |    let _ = Test.Portable.Regex.runAll();
      |
      |    %%PRINTLN%%("portable: String");
      |    let _ = Test.Portable.String.runAll();
      |
      |    %%PRINTLN%%("portable: Char");
      |    let _ = Test.Portable.Char.runAll();
      |
      |    %%PRINTLN%%("portable: StringBuilder");
      |    let _ = Test.Portable.StringBuilder.runAll();
      |
      |    %%PRINTLN%%("portable: Ref");
      |    let _ = Test.Portable.Ref.runAll();
      |
      |    %%PRINTLN%%("portable: MutCollections");
      |    let _ = Test.Portable.MutCollections.runAll();
      |
      |    %%PRINTLN%%("portable: Exceptions");
      |    let _ = Test.Portable.Exceptions.runAll();
      |
      |    %%PRINTLN%%("portable: RegionSpawn");
      |    let _ = Test.Portable.RegionSpawn.runAll();
      |
      |    %%PRINTLN%%("portable: TcpProcessSignatures");
      |    let _ = Test.Portable.TcpProcessSignatures.runAll();
      |
      |    %%PRINTLN%%("portable: TcpLoopback");
      |    let _ = Test.Portable.TcpLoopback.runAll();
      |
      |    %%PRINTLN%%("portable-stdlib-llvm-native-runtime: done");
      |    ()
      |}
      |""".stripMargin

  private val uncaughtExnDriverSource: String =
    """
      |mod Test {}
      |
      |mod Test.Portable.UncaughtExn {
      |
      |    def g(): Unit \ IO = throw Exn.mk(999)
      |
      |    pub def f(): Unit \ IO = g()
      |
      |}
      |
      |def main(): Unit \ IO = Test.Portable.UncaughtExn.f()
      |""".stripMargin

  private val unhandledSuspensionDriverSource: String =
    """
      |mod Test {}
      |
      |eff Boom {
      |    def boom(): Unit
      |}
      |
      |def f(): Unit \ Boom = Boom.boom()
      |
      |def main(): Unit \ IO = unchecked_cast(f() as _ \ IO)
      |""".stripMargin

  private val gcStressDriverSource: String =
    """
      |mod Test {}
      |
      |def allocLoop(n: Int32): Int32 = {
      |    def loop(i: Int32, acc: Int32): Int32 =
      |        if (i == n) acc else {
      |            let s = "${i}-${i}-${i}-${i}";
      |            loop(i + 1, acc + String.length(s))
      |        };
      |    loop(0, 0)
      |}
      |
      |def main(): Unit \ {Chan, NonDet, IO} = region rc {
      |    %%PRINTLN%%("gc-stress: start");
      |
      |    let (tx, rx) = Channel.unbuffered();
      |
      |    spawn {
      |        %%SLEEP_MILLIS%%(100i64);
      |        Channel.send(42, tx);
      |        ()
      |    } @ rc;
      |
      |    spawn {
      |        let x = allocLoop(100000);
      |        discard %%NEW_ID%%(());
      |        if (x < 0) () else ()
      |    } @ rc;
      |
      |    let v = Channel.recv(rx);
      |    %%PRINTLN%%("gc-stress: got " + Int32.toString(v));
      |    %%PRINTLN%%("gc-stress: done");
      |    ()
      |}
      |""".stripMargin

  private def runExecutable(executable: Path): (Int, String) =
    runExecutable(executable, Map.empty)

  private def runExecutable(executable: Path, env: Map[String, String]): (Int, String) = {
    val pb = new ProcessBuilder(List(executable.toString).asJava)
    val pbEnv = pb.environment()
    env.foreach { case (k, v) => pbEnv.put(k, v) }
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
