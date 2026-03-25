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
import java.nio.file.{FileSystem, FileSystemNotFoundException, FileSystems, Files, Path, Paths, StandardCopyOption}
import scala.jdk.CollectionConverters.*

/**
  * Drives the host toolchain to turn textual LLVM IR (`.ll`) into a native executable.
  *
  * Bring-up choice: use `zig cc` as the portable compiler+linker driver.
  */
object LlvmNativeDriver {

  case class Artifacts(executable: Path)

  case class LibraryArtifacts(staticLibrary: Path)

  case class SharedLibraryArtifacts(sharedLibrary: Path)

  private val BundledRuntimeSourceDir: String = "/runtime/src"
  private val BundledLibxevSourceDir: String = "/vendor/libxev/src"

  /**
    * Compiles `modulePath` (a `.ll` file) into a native executable in `outputPath/llvm/`.
    */
  def run(modulePath: Path)(implicit flix: Flix): Artifacts = {
    val outDir = flix.options.outputPath.resolve("llvm").toAbsolutePath
    Files.createDirectories(outDir)

    val exePath = executablePath(flix.options.outputPath, flix.options.artifactName)

    val optFlag = flix.options.build match {
      case Build.Development => "-O0"
      case Build.Production => "-O2"
    }

    val runtimeZig = resolveRuntimeZig(outDir)

    val runtimeObjs = compileRuntime(runtimeZig, outDir, optFlag)

    val cmd = List(
      "zig",
      "cc",
      "-Wno-override-module",
      optFlag,
      modulePath.toString,
    ) ::: runtimeObjs.map(_.toString) ::: List(
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
    * Compiles `modulePath` (a `.ll` file) into a static library in `outputPath/llvm/`.
    *
    * The archive contains both the LLVM module object and the Zig runtime object.
    */
  def buildStaticLibrary(modulePath: Path)(implicit flix: Flix): LibraryArtifacts = {
    val outDir = flix.options.outputPath.resolve("llvm").toAbsolutePath
    Files.createDirectories(outDir)

    val optFlag = flix.options.build match {
      case Build.Development => "-O0"
      case Build.Production => "-O2"
    }

    val runtimeZig = resolveRuntimeZig(outDir)
    val runtimeObjs = compileRuntime(runtimeZig, outDir, optFlag)
    val moduleObj = compileModule(modulePath, outDir, optFlag)

    val libPath = staticLibraryPath(flix.options.outputPath, flix.options.artifactName)
    val arCmd = List(
      "zig",
      "ar",
      "rcs",
      libPath.toString,
      moduleObj.toString,
    ) ::: runtimeObjs.map(_.toString)
    val (arExit, arOutput) = exec(arCmd, outDir)
    if (arExit != 0) {
      throw InternalCompilerException(
        s"LLVM-native toolchain failed while creating archive (exit $arExit):\n${arCmd.mkString(" ")}\n\n$arOutput",
        SourceLocation.Unknown
      )
    }

    LibraryArtifacts(libPath)
  }

  /**
    * Compiles `modulePath` (a `.ll` file) into a shared library in `outputPath/llvm/`.
    *
    * The shared library contains both the LLVM module object and the Zig runtime object.
    */
  def buildSharedLibrary(modulePath: Path)(implicit flix: Flix): SharedLibraryArtifacts = {
    val outDir = flix.options.outputPath.resolve("llvm").toAbsolutePath
    Files.createDirectories(outDir)

    val optFlag = flix.options.build match {
      case Build.Development => "-O0"
      case Build.Production => "-O2"
    }

    val runtimeZig = resolveRuntimeZig(outDir)
    val runtimeObjs = compileRuntime(runtimeZig, outDir, optFlag)
    val moduleObj = compileModule(modulePath, outDir, optFlag)

    val libPath = sharedLibraryPath(flix.options.outputPath, flix.options.artifactName)

    val linkModeFlag = if (isMac) "-dynamiclib" else "-shared"
    val windowsExportFlags = if (isWindows) List("-Wl,--export-all-symbols") else Nil

    val linkCmd = List(
      "zig",
      "cc",
      linkModeFlag,
      "-Wno-override-module",
      optFlag
    ) ::: windowsExportFlags ::: List(
      moduleObj.toString,
    ) ::: runtimeObjs.map(_.toString) ::: List(
      "-o",
      libPath.toString
    )

    val (linkExit, linkOutput) = exec(linkCmd, outDir)
    if (linkExit != 0) {
      throw InternalCompilerException(
        s"LLVM-native toolchain failed while linking shared library (exit $linkExit):\n${linkCmd.mkString(" ")}\n\n$linkOutput",
        SourceLocation.Unknown
      )
    }

    SharedLibraryArtifacts(libPath)
  }

  /**
    * Resolves the Zig runtime support file for the LLVM-native backend.
    *
    * Bring-up behavior:
    *   1. Prefer `runtime/src/flix_rt_llvm.zig` relative to the current working directory.
    *   2. Otherwise, extract the bundled runtime source tree and vendored `libxev` source into `outDir`.
    */
  private def resolveRuntimeZig(outDir: Path): Path = {
    val runtimeDir = outDir.resolve("runtime/src").toAbsolutePath.normalize()
    val libxevDir = runtimeDir.resolve("vendor/libxev/src").toAbsolutePath.normalize()

    val cwdRuntimeDir = Paths.get("runtime/src").toAbsolutePath.normalize()
    val cwdLibxevDir = Paths.get("vendor/libxev/src").toAbsolutePath.normalize()

    if (Files.exists(cwdRuntimeDir.resolve("flix_rt_llvm.zig")) && Files.exists(cwdLibxevDir.resolve("main.zig"))) {
      copyTree(cwdRuntimeDir, runtimeDir)
      copyTree(cwdLibxevDir, libxevDir)
    } else {
      copyBundledTree(BundledRuntimeSourceDir, runtimeDir)
      copyBundledTree(BundledLibxevSourceDir, libxevDir)
    }

    runtimeDir.resolve("flix_rt_llvm.zig")
  }

  private def copyTree(sourceDir: Path, destDir: Path): Unit = {
    Files.walk(sourceDir).forEach { src =>
      if (Files.isRegularFile(src)) {
        val rel = sourceDir.relativize(src)
        val dest = destDir.resolve(rel.toString).toAbsolutePath.normalize()
        Option(dest.getParent).foreach(parent => Files.createDirectories(parent))
        Files.copy(src, dest, StandardCopyOption.REPLACE_EXISTING)
      }
    }
  }

  private def copyBundledTree(resourceDir: String, destDir: Path): Unit = {
    val resourceUrl = Option(getClass.getResource(resourceDir)).getOrElse {
      throw InternalCompilerException(
        s"Missing bundled LLVM runtime resource tree '$resourceDir'.",
        SourceLocation.Unknown
      )
    }

    val resourceUri = resourceUrl.toURI

    def copyFrom(root: Path, closeFs: Option[FileSystem]): Unit = {
      try {
        Files.walk(root).forEach { src =>
          if (Files.isRegularFile(src)) {
            val rel = root.relativize(src)
            val dest = destDir.resolve(rel.toString).toAbsolutePath.normalize()
            Option(dest.getParent).foreach(parent => Files.createDirectories(parent))
            Files.copy(src, dest, StandardCopyOption.REPLACE_EXISTING)
          }
        }
      } finally {
        closeFs.foreach(_.close())
      }
    }

    if (resourceUri.getScheme == "jar") {
      val (fs, closeFs) =
        try (FileSystems.getFileSystem(resourceUri), None)
        catch {
          case _: FileSystemNotFoundException =>
            val created = FileSystems.newFileSystem(resourceUri, Map.empty[String, AnyRef].asJava)
            (created, Some(created))
        }
      copyFrom(fs.getPath(resourceDir), closeFs)
    } else {
      copyFrom(Paths.get(resourceUri), None)
    }
  }

  private def compileRuntime(runtimeZig: Path, outDir: Path, optFlag: String): List[Path] = {
    def compileOne(source: Path, objectName: String): Path = {
      val runtimeObj = outDir.resolve(objectName)
      val compileRuntimeCmd =
        List("zig", "cc", "-c", "-Wno-override-module") :::
          picFlags :::
          List(optFlag, source.toString, "-o", runtimeObj.toString)
      val (rtExit, rtOutput) = exec(compileRuntimeCmd, outDir)
      if (rtExit != 0) {
        throw InternalCompilerException(
          s"LLVM-native toolchain failed while compiling runtime (exit $rtExit):\n${compileRuntimeCmd.mkString(" ")}\n\n$rtOutput",
          SourceLocation.Unknown
        )
      }
      runtimeObj
    }

    val rtCore = compileOne(runtimeZig, "flix_rt_llvm.o")
    val rtXev = compileOne(runtimeZig.getParent.resolve("rt_xev.zig"), "rt_xev.o")
    List(rtCore, rtXev)
  }

  private def compileModule(modulePath: Path, outDir: Path, optFlag: String): Path = {
    val moduleObj = outDir.resolve("module.o")
    val compileModuleCmd =
      List("zig", "cc", "-c", "-Wno-override-module") :::
        picFlags :::
        List(optFlag, modulePath.toString, "-o", moduleObj.toString)

    val (modExit, modOutput) = exec(compileModuleCmd, outDir)
    if (modExit != 0) {
      throw InternalCompilerException(
        s"LLVM-native toolchain failed while compiling module object (exit $modExit):\n${compileModuleCmd.mkString(" ")}\n\n$modOutput",
        SourceLocation.Unknown
      )
    }

    moduleObj
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

  private def isMac: Boolean =
    System.getProperty("os.name", "").toLowerCase.contains("mac")

  def executablePath(outputPath: Path, artifactName: String = ArtifactNames.DefaultBaseName): Path =
    outputPath.resolve("llvm").resolve(ArtifactNames.nativeExecutableFileName(artifactName)).toAbsolutePath.normalize()

  def staticLibraryPath(outputPath: Path, artifactName: String = ArtifactNames.DefaultBaseName): Path =
    outputPath.resolve("llvm").resolve(ArtifactNames.nativeStaticLibraryFileName(artifactName)).toAbsolutePath.normalize()

  def sharedLibraryPath(outputPath: Path, artifactName: String = ArtifactNames.DefaultBaseName): Path =
    outputPath.resolve("llvm").resolve(ArtifactNames.nativeSharedLibraryFileName(artifactName)).toAbsolutePath.normalize()

  private def picFlags: List[String] =
    if (isWindows) Nil else List("-fPIC")

}
