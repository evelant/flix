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

class LlvmNativeExportSuite extends AnyFunSuite {

  private val TestOptions: Options =
    Options.TestWithLibAll.copy(
      stdlibProfile = StdlibProfile.Portable,
      target = CompilationTarget.LlvmNative,
      incremental = false,
      outputJvm = false,
    )

  test("llvm-native-export-static-library") {
    assume(hasZig, "zig not found on PATH (skipping LLVM-native export test)")

    val program =
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
        |    pub def bytesLen(a: Array[Int8, Static]): Int32 = Array.length(a)
        |
        |    @Export
        |    pub def bytesId(a: Array[Int8, Static]): Array[Int8, Static] = a
        |
        |    @Export
        |    pub def suspendEcho(s: String): String \ HostEcho = HostEcho.echo(s)
        |}
        |""".stripMargin

    val flixFile = Files.createTempFile("flix-llvm-native-export-", ".flix")
    val outDir = Files.createTempDirectory("flix-llvm-native-export-out-")
    try {
      Files.writeString(flixFile, program, StandardCharsets.UTF_8)

      val flix = new Flix()
      flix.setOptions(TestOptions.copy(outputPath = outDir))
      implicit val sctx: SecurityContext = SecurityContext.Unrestricted
      flix.addFile(flixFile)

      val (optRoot, errors) = flix.check()
      if (errors.nonEmpty) {
        fail(CompilationMessage.formatAll(errors)(flix.getFormatter, optRoot))
      }

      flix.codeGen(optRoot.get)

      val llvmDir = outDir.resolve("llvm").toAbsolutePath.normalize()
      val header = ca.uwaterloo.flix.language.phase.llvm.LlvmExportWriter.exportsHeaderPath(outDir)
      val lib = ca.uwaterloo.flix.language.phase.llvm.LlvmNativeDriver.staticLibraryPath(outDir)
      val shared = ca.uwaterloo.flix.language.phase.llvm.LlvmNativeDriver.sharedLibraryPath(outDir)
      if (!Files.exists(header)) fail(s"Missing exports header: $header")
      if (!Files.exists(lib)) fail(s"Missing static library: $lib")
      if (!Files.exists(shared)) fail(s"Missing shared library: $shared")

      val cFile = Files.createTempFile(outDir, "flix-llvm-export-smoke-", ".c")
      val exeName = if (isWindows) "export_smoke.exe" else "export_smoke"
      val exe = llvmDir.resolve(exeName)

      val cProgram =
        """
          |#include "flix.h"
          |#include <stdio.h>
          |#include <string.h>
          |
          |int main(void) {
          |  flix_init(0, NULL);
          |  flix_ctx_t* ctx = flix_ctx_new();
          |  if (!ctx) {
          |    fprintf(stderr, "flix_ctx_new returned NULL\n");
          |    return 1;
          |  }
          |
          |  // Int32 export.
          |  int32_t sum = 0;
          |  flix_exec_t add_r = flix_export_Test_add(ctx, (int32_t)1, (int32_t)2, &sum);
          |  if (add_r.tag != FLIX_EXEC_OK) {
          |    fprintf(stderr, "bad add tag: %lld\n", (long long)add_r.tag);
          |    return 1;
          |  }
          |  if (sum != 3) {
          |    fprintf(stderr, "bad add value: %d\n", (int)sum);
          |    return 2;
          |  }
          |
          |  // String roundtrip export.
          |  const uint8_t hello_bytes[] = { 'h', 'e', 'l', 'l', 'o' };
          |  flix_string_t hello = flix_string_from_utf8(ctx, hello_bytes, 5);
          |  flix_string_t echoed = 0;
          |  flix_exec_t echo_r = flix_export_Test_echo(ctx, hello, &echoed);
          |  if (echo_r.tag != FLIX_EXEC_OK) {
          |    fprintf(stderr, "bad echo tag: %lld\n", (long long)echo_r.tag);
          |    return 3;
          |  }
          |  int64_t echoed_len = 0;
          |  uint8_t* echoed_out = flix_string_to_utf8(ctx, echoed, &echoed_len);
          |  if (echoed_len != 5 || memcmp(echoed_out, hello_bytes, 5) != 0) {
          |    fprintf(stderr, "bad echo payload\n");
          |    return 4;
          |  }
          |  flix_free(echoed_out);
          |  flix_handle_release(ctx, echoed);
          |
          |  // Bytes roundtrip export.
          |  const uint8_t data[] = { 0, 1, 2, 255 };
          |  flix_bytes_t arr = flix_bytes_from_slice(ctx, data, 4);
          |  int32_t arr_len = 0;
          |  flix_exec_t len_r = flix_export_Test_bytesLen(ctx, arr, &arr_len);
          |  if (len_r.tag != FLIX_EXEC_OK) {
          |    fprintf(stderr, "bad bytesLen tag: %lld\n", (long long)len_r.tag);
          |    return 5;
          |  }
          |  if (arr_len != 4) {
          |    fprintf(stderr, "bad bytesLen value: %d\n", (int)arr_len);
          |    return 6;
          |  }
          |  flix_bytes_t arr2 = 0;
          |  flix_exec_t id_r = flix_export_Test_bytesId(ctx, arr, &arr2);
          |  if (id_r.tag != FLIX_EXEC_OK) {
          |    fprintf(stderr, "bad bytesId tag: %lld\n", (long long)id_r.tag);
          |    return 7;
          |  }
          |  int64_t out_len = 0;
          |  uint8_t* out = flix_bytes_to_slice(ctx, arr2, &out_len);
          |  if (out_len != 4 || memcmp(out, data, 4) != 0) {
          |    fprintf(stderr, "bad bytesId payload\n");
          |    return 8;
          |  }
          |  flix_free(out);
          |  flix_handle_release(ctx, arr);
          |  flix_handle_release(ctx, arr2);
          |
          |  // Suspension + resume roundtrip export (host effect).
          |  flix_string_t ignored = 0;
          |  flix_exec_t susp_r = flix_export_Test_suspendEcho(ctx, hello, &ignored);
          |  if (susp_r.tag != FLIX_EXEC_SUSPENDED) {
          |    fprintf(stderr, "bad suspendEcho tag: %lld\n", (long long)susp_r.tag);
          |    return 9;
          |  }
          |  flix_handle_t susp = (flix_handle_t)susp_r.payload;
          |  if (flix_suspension_arg_count(ctx, susp) != 1) {
          |    fprintf(stderr, "bad suspension argc\n");
          |    return 10;
          |  }
          |  flix_string_t arg0 = (flix_string_t) flix_suspension_arg_as_ptr(ctx, susp, 0);
          |  int64_t arg0_len = 0;
          |  uint8_t* arg0_out = flix_string_to_utf8(ctx, arg0, &arg0_len);
          |  if (arg0_len != 5 || memcmp(arg0_out, hello_bytes, 5) != 0) {
          |    fprintf(stderr, "bad suspension arg0\n");
          |    return 11;
          |  }
          |  flix_free(arg0_out);
          |  flix_handle_release(ctx, arg0);
          |
          |  const uint8_t ok_bytes[] = { 'o', 'k' };
          |  flix_string_t ok = flix_string_from_utf8(ctx, ok_bytes, 2);
          |  flix_string_t resumed = 0;
          |  flix_exec_t resume_r = flix_export_resume_Test_suspendEcho(ctx, susp, ok, &resumed);
          |  if (resume_r.tag != FLIX_EXEC_OK) {
          |    fprintf(stderr, "bad suspendEcho resume tag: %lld\n", (long long)resume_r.tag);
          |    return 12;
          |  }
          |  int64_t resumed_len = 0;
          |  uint8_t* resumed_out = flix_string_to_utf8(ctx, resumed, &resumed_len);
          |  if (resumed_len != 2 || memcmp(resumed_out, ok_bytes, 2) != 0) {
          |    fprintf(stderr, "bad suspendEcho resume payload\n");
          |    return 13;
          |  }
          |  flix_free(resumed_out);
          |  flix_handle_release(ctx, ok);
          |  flix_handle_release(ctx, resumed);
          |  flix_handle_release(ctx, susp);
          |  flix_handle_release(ctx, hello);
          |
          |  flix_ctx_free(ctx);
          |  printf("OK\n");
          |  return 0;
          |}
          |""".stripMargin

      Files.writeString(cFile, cProgram, StandardCharsets.UTF_8)

      val compileCmd = List(
        "zig",
        "cc",
        "-I",
        llvmDir.toString,
        cFile.toString,
        lib.toString,
        "-o",
        exe.toString
      )
      val (ccExit, ccOutput) = exec(compileCmd, llvmDir)
      if (ccExit != 0) {
        fail(s"Failed to compile C export smoke test (exit $ccExit):\n${compileCmd.mkString(" ")}\n\n$ccOutput")
      }

      val (exit, output) = runExecutable(exe)
      if (exit != 0) {
        fail(s"Export smoke test failed with exit $exit:\n$output")
      }
      if (output.trim != "OK") {
        fail(s"Unexpected export smoke output:\n$output")
      }

      // Also verify that the shared library can be loaded dynamically and its symbols resolved.
      if (!isWindows) {
        val dynCFile = Files.createTempFile(outDir, "flix-llvm-export-dyn-", ".c")
        val dynExeName = if (isWindows) "export_dyn_smoke.exe" else "export_dyn_smoke"
        val dynExe = llvmDir.resolve(dynExeName)

        val dynProgram =
          """
            |#include "flix.h"
            |#include <stdio.h>
            |#include <dlfcn.h>
            |#include <string.h>
            |
            |typedef void (*flix_init_fn)(int32_t argc, char** argv);
            |typedef flix_ctx_t* (*flix_ctx_new_fn)(void);
            |typedef void (*flix_ctx_free_fn)(flix_ctx_t* ctx);
            |typedef void (*flix_handle_release_fn)(flix_ctx_t* ctx, flix_handle_t h);
            |typedef flix_exec_t (*flix_add_fn)(flix_ctx_t* ctx, int32_t x, int32_t y, int32_t* out);
            |typedef flix_exec_t (*flix_echo_fn)(flix_ctx_t* ctx, flix_string_t s, flix_string_t* out);
            |typedef flix_exec_t (*flix_blen_fn)(flix_ctx_t* ctx, flix_bytes_t a, int32_t* out);
            |typedef flix_exec_t (*flix_bid_fn)(flix_ctx_t* ctx, flix_bytes_t a, flix_bytes_t* out);
            |typedef flix_exec_t (*flix_susp_echo_fn)(flix_ctx_t* ctx, flix_string_t s, flix_string_t* out);
            |typedef flix_exec_t (*flix_susp_echo_resume_fn)(flix_ctx_t* ctx, flix_handle_t susp, flix_handle_t resume, flix_string_t* out);
            |typedef void (*flix_free_fn)(void* p);
            |typedef flix_string_t (*flix_string_from_utf8_fn)(flix_ctx_t* ctx, const uint8_t* bytes, int64_t len);
            |typedef uint8_t* (*flix_string_to_utf8_fn)(flix_ctx_t* ctx, flix_string_t str, int64_t* out_len);
            |typedef flix_i8_array_t (*flix_i8_array_from_bytes_fn)(flix_ctx_t* ctx, const uint8_t* bytes, int64_t len);
            |typedef uint8_t* (*flix_i8_array_to_bytes_fn)(flix_ctx_t* ctx, flix_i8_array_t arr, int64_t* out_len);
            |typedef int64_t (*flix_susp_arg_count_fn)(flix_ctx_t* ctx, flix_handle_t susp);
            |
            |int main(int argc, char** argv) {
            |  if (argc < 2) {
            |    fprintf(stderr, "missing shared library path\n");
            |    return 2;
            |  }
            |  void* lib = dlopen(argv[1], RTLD_NOW);
            |  if (!lib) {
            |    fprintf(stderr, "dlopen failed: %s\n", dlerror());
            |    return 3;
            |  }
            |
            |  flix_init_fn flix_init_ptr = (flix_init_fn)dlsym(lib, "flix_init");
            |  flix_ctx_new_fn ctx_new_ptr = (flix_ctx_new_fn)dlsym(lib, "flix_ctx_new");
            |  flix_ctx_free_fn ctx_free_ptr = (flix_ctx_free_fn)dlsym(lib, "flix_ctx_free");
            |  flix_handle_release_fn release_ptr = (flix_handle_release_fn)dlsym(lib, "flix_handle_release");
            |  flix_add_fn add_ptr = (flix_add_fn)dlsym(lib, "flix_export_Test_add");
            |  flix_echo_fn echo_ptr = (flix_echo_fn)dlsym(lib, "flix_export_Test_echo");
            |  flix_blen_fn blen_ptr = (flix_blen_fn)dlsym(lib, "flix_export_Test_bytesLen");
            |  flix_bid_fn bid_ptr = (flix_bid_fn)dlsym(lib, "flix_export_Test_bytesId");
            |  flix_susp_echo_fn susp_echo_ptr = (flix_susp_echo_fn)dlsym(lib, "flix_export_Test_suspendEcho");
            |  flix_susp_echo_resume_fn susp_echo_resume_ptr = (flix_susp_echo_resume_fn)dlsym(lib, "flix_export_resume_Test_suspendEcho");
            |  flix_free_fn free_ptr = (flix_free_fn)dlsym(lib, "flix_free");
            |  flix_string_from_utf8_fn from_utf8_ptr = (flix_string_from_utf8_fn)dlsym(lib, "flix_string_from_utf8");
            |  flix_string_to_utf8_fn to_utf8_ptr = (flix_string_to_utf8_fn)dlsym(lib, "flix_string_to_utf8");
            |  flix_i8_array_from_bytes_fn arr_from_ptr = (flix_i8_array_from_bytes_fn)dlsym(lib, "flix_i8_array_from_bytes");
            |  flix_i8_array_to_bytes_fn arr_to_ptr = (flix_i8_array_to_bytes_fn)dlsym(lib, "flix_i8_array_to_bytes");
            |  flix_susp_arg_count_fn susp_argc_ptr = (flix_susp_arg_count_fn)dlsym(lib, "flix_suspension_arg_count");
            |  if (!flix_init_ptr || !ctx_new_ptr || !ctx_free_ptr || !release_ptr ||
            |      !add_ptr || !echo_ptr || !blen_ptr || !bid_ptr || !susp_echo_ptr || !susp_echo_resume_ptr ||
            |      !free_ptr || !from_utf8_ptr || !to_utf8_ptr || !arr_from_ptr || !arr_to_ptr || !susp_argc_ptr) {
            |    fprintf(stderr, "dlsym failed\n");
            |    return 4;
            |  }
            |
            |  flix_init_ptr(0, NULL);
            |
            |  flix_ctx_t* ctx = ctx_new_ptr();
            |  if (!ctx) {
            |    fprintf(stderr, "flix_ctx_new returned NULL\n");
            |    return 5;
            |  }
            |
            |  int32_t sum = 0;
            |  flix_exec_t add_r = add_ptr(ctx, (int32_t)1, (int32_t)2, &sum);
            |  if (add_r.tag != FLIX_EXEC_OK || sum != 3) {
            |    fprintf(stderr, "bad add\n");
            |    return 6;
            |  }
            |
            |  const uint8_t hello_bytes[] = { 'h', 'e', 'l', 'l', 'o' };
            |  flix_string_t hello = from_utf8_ptr(ctx, hello_bytes, 5);
            |  flix_string_t echoed = 0;
            |  flix_exec_t echo_r = echo_ptr(ctx, hello, &echoed);
            |  if (echo_r.tag != FLIX_EXEC_OK) {
            |    fprintf(stderr, "bad echo\n");
            |    return 7;
            |  }
            |  int64_t echoed_len = 0;
            |  uint8_t* echoed_out = to_utf8_ptr(ctx, echoed, &echoed_len);
            |  if (echoed_len != 5 || memcmp(echoed_out, hello_bytes, 5) != 0) {
            |    fprintf(stderr, "bad echo payload\n");
            |    return 8;
            |  }
            |  free_ptr(echoed_out);
            |  release_ptr(ctx, echoed);
            |
            |  const uint8_t data[] = { 0, 1, 2, 255 };
            |  flix_bytes_t arr = arr_from_ptr(ctx, data, 4);
            |  int32_t arr_len = 0;
            |  flix_exec_t len_r = blen_ptr(ctx, arr, &arr_len);
            |  if (len_r.tag != FLIX_EXEC_OK || arr_len != 4) {
            |    fprintf(stderr, "bad bytesLen\n");
            |    return 9;
            |  }
            |  flix_bytes_t arr2 = 0;
            |  flix_exec_t id_r = bid_ptr(ctx, arr, &arr2);
            |  if (id_r.tag != FLIX_EXEC_OK) {
            |    fprintf(stderr, "bad bytesId\n");
            |    return 10;
            |  }
            |  int64_t out_len = 0;
            |  uint8_t* out = arr_to_ptr(ctx, arr2, &out_len);
            |  if (out_len != 4 || memcmp(out, data, 4) != 0) {
            |    fprintf(stderr, "bad bytesId payload\n");
            |    return 11;
            |  }
            |  free_ptr(out);
            |  release_ptr(ctx, arr);
            |  release_ptr(ctx, arr2);
            |
            |  flix_string_t ignored = 0;
            |  flix_exec_t susp_r = susp_echo_ptr(ctx, hello, &ignored);
            |  if (susp_r.tag != FLIX_EXEC_SUSPENDED) {
            |    fprintf(stderr, "bad suspendEcho\n");
            |    return 12;
            |  }
            |  flix_handle_t susp = (flix_handle_t)susp_r.payload;
            |  if (susp_argc_ptr(ctx, susp) != 1) {
            |    fprintf(stderr, "bad suspend argc\n");
            |    return 13;
            |  }
            |  const uint8_t ok_bytes[] = { 'o', 'k' };
            |  flix_string_t ok = from_utf8_ptr(ctx, ok_bytes, 2);
            |  flix_string_t resumed = 0;
            |  flix_exec_t resume_r = susp_echo_resume_ptr(ctx, susp, ok, &resumed);
            |  if (resume_r.tag != FLIX_EXEC_OK) {
            |    fprintf(stderr, "bad suspend resume\n");
            |    return 14;
            |  }
            |  int64_t resumed_len = 0;
            |  uint8_t* resumed_out = to_utf8_ptr(ctx, resumed, &resumed_len);
            |  if (resumed_len != 2 || memcmp(resumed_out, ok_bytes, 2) != 0) {
            |    fprintf(stderr, "bad resume payload\n");
            |    return 15;
            |  }
            |  free_ptr(resumed_out);
            |  release_ptr(ctx, ok);
            |  release_ptr(ctx, resumed);
            |  release_ptr(ctx, susp);
            |  release_ptr(ctx, hello);
            |  ctx_free_ptr(ctx);
            |
            |  printf("OK\n");
            |  return 0;
            |}
            |""".stripMargin

        Files.writeString(dynCFile, dynProgram, StandardCharsets.UTF_8)

        val dynCompileCmd = List(
          "zig",
          "cc",
          "-I",
          llvmDir.toString,
          dynCFile.toString
        ) ::: (if (isMac) Nil else List("-ldl")) ::: List(
          "-o",
          dynExe.toString
        )

        val (dynCcExit, dynCcOutput) = exec(dynCompileCmd, llvmDir)
        if (dynCcExit != 0) {
          fail(s"Failed to compile dynamic-load export smoke test (exit $dynCcExit):\n${dynCompileCmd.mkString(" ")}\n\n$dynCcOutput")
        }

        val (dynExit, dynOutput) = runExecutable(dynExe, shared.toString)
        if (dynExit != 0) {
          fail(s"Dynamic-load export smoke test failed with exit $dynExit:\n$dynOutput")
        }
        if (dynOutput.trim != "OK") {
          fail(s"Unexpected dynamic-load export smoke output:\n$dynOutput")
        }
      }
    } finally {
      Files.deleteIfExists(flixFile)
      deleteRecursive(outDir)
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

  private def exec(cmd: List[String], cwd: Path): (Int, String) = {
    val pb = new ProcessBuilder(cmd.asJava)
    pb.redirectErrorStream(true)
    pb.directory(cwd.toFile)
    val p = pb.start()
    val output = new String(p.getInputStream.readAllBytes(), StandardCharsets.UTF_8)
    val exit = p.waitFor()
    (exit, output)
  }

  private def runExecutable(executable: Path): (Int, String) = {
    val pb = new ProcessBuilder(List(executable.toString).asJava)
    pb.redirectErrorStream(true)
    val p = pb.start()
    val output = new String(p.getInputStream.readAllBytes(), StandardCharsets.UTF_8)
    val exit = p.waitFor()
    (exit, output)
  }

  private def runExecutable(executable: Path, arg: String): (Int, String) = {
    val pb = new ProcessBuilder(List(executable.toString, arg).asJava)
    pb.redirectErrorStream(true)
    val p = pb.start()
    val output = new String(p.getInputStream.readAllBytes(), StandardCharsets.UTF_8)
    val exit = p.waitFor()
    (exit, output)
  }

  private def isWindows: Boolean =
    System.getProperty("os.name", "").toLowerCase.contains("win")

  private def isMac: Boolean =
    System.getProperty("os.name", "").toLowerCase.contains("mac")

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
