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
import com.sun.net.httpserver.{HttpExchange, HttpHandler, HttpServer}
import org.scalatest.funsuite.AnyFunSuite

import java.io.IOException
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths}
import java.util.concurrent.{ExecutorService, Executors, TimeUnit}
import scala.jdk.CollectionConverters.*

/**
  * End-to-end "real program" fixtures for the LLVM-native backend.
  *
  * These tests are intentionally small but exercise whole-program compilation and
  * OS integration points (argv, stdio, filesystem, HTTP).
  */
class NativeProgramsLlvmNativeSuite extends AnyFunSuite {

  private val TestOptions: Options =
    Options.TestWithLibAll.copy(
      stdlibProfile = StdlibProfile.Portable,
      target = CompilationTarget.LlvmNative,
      incremental = false,
      outputJvm = false,
    )

  private val fixturesDir = Paths.get("main/test/flix/native/apps")

  test("llvm-native-fixture-cli-console") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-native real program fixture)")

    val outDir = Files.createTempDirectory("flix-llvm-native-fixture-cli-console-")
    try {
      val exe = compileLlvmNative(fixturesDir.resolve("cli_console"), outDir)
      val (exit, output) = runExecutable(
        exe,
        args = List("result"),
        stdin = "40\n2\n",
        timeoutSeconds = 10,
      )
      if (exit != 0) {
        fail(s"CLI/Console fixture failed with exit $exit:\n$output")
      }
      if (!output.contains("cli-console: ready")) {
        fail(s"Expected readiness banner, but output was:\n$output")
      }
      if (!output.contains("result:42")) {
        fail(s"Expected computed result, but output was:\n$output")
      }
    } finally {
      deleteRecursive(outDir)
    }
  }

  test("llvm-native-fixture-http-file") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-native real program fixture)")

    val executor = Executors.newCachedThreadPool()
    val server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0)
    server.setExecutor(executor)

    val token = "secret123"
    server.createContext("/kv", new HttpHandler {
      override def handle(exchange: HttpExchange): Unit = {
        val bytes = s"token=$token\n".getBytes(StandardCharsets.UTF_8)
        exchange.sendResponseHeaders(200, bytes.length)
        val os = exchange.getResponseBody
        os.write(bytes)
        os.close()
      }
    })

    server.start()
    val baseUrl = s"http://127.0.0.1:${server.getAddress.getPort}/kv"

    val inputFile = Files.createTempFile("flix-llvm-native-fixture-http-file-", ".txt")
    Files.writeString(inputFile, s"$token\n", StandardCharsets.UTF_8)

    val outDir = Files.createTempDirectory("flix-llvm-native-fixture-http-file-")

    try {
      val exe = compileLlvmNative(fixturesDir.resolve("http_file_app"), outDir)
      val (exit, output) = runExecutable(
        exe,
        args = List(baseUrl, inputFile.toString),
        timeoutSeconds = 15,
      )
      if (exit != 0) {
        fail(s"HTTP+File fixture failed with exit $exit:\n$output")
      }
      if (!output.contains("native-http-file: ok")) {
        fail(s"Expected success banner, but output was:\n$output")
      }
    } finally {
      Files.deleteIfExists(inputFile)
      deleteRecursive(outDir)
      server.stop(0)
      shutdownExecutor(executor)
    }
  }

  private def compileLlvmNative(dir: Path, outDir: Path): Path = {
    val flix = new Flix()
    flix.setOptions(TestOptions.copy(outputPath = outDir))
    implicit val sctx: SecurityContext = SecurityContext.Unrestricted

    for (p <- FileOps.getFlixFilesIn(dir, Int.MaxValue)) flix.addFile(p)

    val (optRoot, errors) = flix.check()
    if (errors.nonEmpty) {
      fail(CompilationMessage.formatAll(errors)(flix.getFormatter, optRoot))
    }

    flix.codeGen(optRoot.get)
    executablePath(outDir)
  }

  private def runExecutable(
    executable: Path,
    args: List[String] = Nil,
    env: Map[String, String] = Map.empty,
    stdin: String = "",
    timeoutSeconds: Long = 30,
  ): (Int, String) = {
    val cmd = (executable.toString :: args).asJava
    val pb = new ProcessBuilder(cmd)
    val pbEnv = pb.environment()
    env.foreach { case (k, v) => pbEnv.put(k, v) }
    pb.redirectErrorStream(true)

    val p = pb.start()

    // Provide stdin (always close to avoid hanging waiting for input).
    val os = p.getOutputStream
    try {
      if (stdin.nonEmpty) os.write(stdin.getBytes(StandardCharsets.UTF_8))
    } finally {
      os.close()
    }

    val output = new String(p.getInputStream.readAllBytes(), StandardCharsets.UTF_8)
    val finished = p.waitFor(timeoutSeconds, TimeUnit.SECONDS)
    if (!finished) {
      p.destroyForcibly()
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

  private def shutdownExecutor(executor: ExecutorService): Unit = {
    executor.shutdown()
    if (!executor.awaitTermination(2, TimeUnit.SECONDS)) executor.shutdownNow()
  }

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

