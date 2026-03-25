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

import org.scalatest.funsuite.AnyFunSuite

import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths}
import java.util.concurrent.TimeUnit
import scala.jdk.CollectionConverters.*

class NativeRuntimeZigSuite extends AnyFunSuite {

  test("native-runtime-zig-tests") {
    assume(hasZig, "zig not found on PATH (skipping native runtime Zig tests)")

    val stageRoot = Files.createTempDirectory("flix-native-runtime-zig-")
    try {
      val runtimeDir = stageRoot.resolve("runtime/src")
      val libxevDir = runtimeDir.resolve("vendor/libxev/src")
      copyTree(Paths.get("runtime/src"), runtimeDir)
      copyTree(Paths.get("vendor/libxev/src"), libxevDir)

      runZigTest(runtimeDir.resolve("async_wait_v0.zig"), stageRoot)
      runZigTest(runtimeDir.resolve("fs_async_v0.zig"), stageRoot)
      runZigTest(runtimeDir.resolve("http_request_std_wire_v0.zig"), stageRoot)
      runZigTest(runtimeDir.resolve("rt_xev.zig"), stageRoot)
    } finally {
      deleteRecursive(stageRoot)
    }
  }

  private def runZigTest(source: Path, cwd: Path): Unit = {
    val cmd = List("zig", "test", source.toString)
    val pb = new ProcessBuilder(cmd.asJava)
    pb.directory(cwd.toFile)
    pb.redirectErrorStream(true)

    val p = pb.start()
    val output = new String(p.getInputStream.readAllBytes(), StandardCharsets.UTF_8)
    val finished = p.waitFor(60, TimeUnit.SECONDS)
    if (!finished) {
      p.destroyForcibly()
      fail(s"zig test timed out for $source.\nOutput so far:\n$output")
    }

    val exit = p.exitValue()
    if (exit != 0) {
      fail(s"zig test failed for $source with exit $exit:\n$output")
    }
  }

  private def copyTree(sourceDir: Path, destDir: Path): Unit = {
    val stream = Files.walk(sourceDir)
    try {
      stream.forEach { src =>
        if (Files.isRegularFile(src)) {
          val rel = sourceDir.relativize(src)
          val dest = destDir.resolve(rel.toString)
          Option(dest.getParent).foreach(parent => Files.createDirectories(parent))
          Files.copy(src, dest)
        }
      }
    } finally {
      stream.close()
    }
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
