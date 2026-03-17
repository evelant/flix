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

import ca.uwaterloo.flix.language.ast.{AtomicOp, LoweredAst, WasmImportSpec}
import ca.uwaterloo.flix.language.phase.{DirectImportAbi, WasmImportInterface}

import scala.collection.mutable

/**
  * Computes and renders the imported WIT world for direct sync `extern wasm` bindings.
  */
object LlvmWasmImportsWriter {

  case class Entry(spec: WasmImportSpec,
                   interfaceId: WasmImportInterface.Id,
                   signature: DirectImportAbi.Signature)

  def compute(root: LoweredAst.Root): List[Entry] = {
    val entries = mutable.LinkedHashMap.empty[(String, String), Entry]

    root.defs.values.foreach { defn =>
      extractBody(defn.exp).foreach { body =>
        val interfaceId = WasmImportInterface.parse(body.spec.interface).getOrElse {
          throw new IllegalStateException(s"Malformed lowered wasm import interface '${body.spec.interface}' for '${defn.sym}'.")
        }
        val sig = DirectImportAbi.signatureOf(defn.fparams.map(_.tpe), body.resultTpe).getOrElse {
          throw new IllegalStateException(s"Unsupported lowered wasm import signature for '${defn.sym}'.")
        }
        entries.getOrElseUpdate((body.spec.interface, body.spec.func), Entry(body.spec, interfaceId, sig))
      }
    }

    entries.values.toList.sortBy(e => (e.interfaceId.qualifiedInterface, e.spec.func))
  }

  def renderBindings(entries: List[Entry]): String = {
    val sb = new StringBuilder(2048)
    sb.append("package flix:bindings@0.1.0;\n\n")
    sb.append("world flix {\n")
    sb.append("  import flix:sys/sys@0.1.0;\n")
    entries.map(_.interfaceId.qualifiedInterface).distinct.foreach { id =>
      sb.append(s"  import $id;\n")
    }
    sb.append("  export flix:runtime/runtime@0.1.0;\n")
    sb.append("}\n")
    sb.toString()
  }

  def renderDeps(entries: List[Entry]): Map[String, String] = {
    val grouped = entries.groupBy(_.interfaceId.depFileName).toList.sortBy(_._1)
    grouped.map {
      case (fileName, groupEntries) =>
        val first = groupEntries.head.interfaceId
        val interfaces = groupEntries
          .groupBy(_.interfaceId.interfaceName)
          .toList
          .sortBy(_._1)
          .map { case (ifaceName, ifaceEntries) =>
            val methods = ifaceEntries
              .groupBy(_.spec.func)
              .toList
              .sortBy(_._1)
              .map(_._2.head)
              .map { entry =>
                s"  ${entry.spec.func}: func(${renderParams(entry.signature.params)})${renderResult(entry.signature.result)};"
              }
              .mkString("\n")
            s"""interface $ifaceName {
$methods
}"""
          }
          .mkString("\n\n")
        fileName -> s"""package ${first.namespace}:${first.packageName}@${first.version};
                       |
                       |$interfaces
                       |""".stripMargin
    }.toMap
  }

  private case class Body(spec: WasmImportSpec, resultTpe: ca.uwaterloo.flix.language.ast.SimpleType)

  private def extractBody(exp0: LoweredAst.Expr): Option[Body] = exp0 match {
    case LoweredAst.Expr.WasmImport(spec, tpe, _, _) =>
      Some(Body(spec, tpe))
    case LoweredAst.Expr.ApplyAtomic(AtomicOp.Box, List(LoweredAst.Expr.WasmImport(spec, tpe, _, _)), _, _, _, _) =>
      Some(Body(spec, tpe))
    case _ =>
      None
  }

  private def renderParams(params: List[DirectImportAbi.AbiType]): String =
    params.zipWithIndex.map { case (tpe, i) => s"p$i: ${renderAbiType(tpe)}" }.mkString(", ")

  private def renderResult(result: DirectImportAbi.AbiType): String = result match {
    case DirectImportAbi.AbiType.Unit => ""
    case other => s" -> ${renderAbiType(other)}"
  }

  private def renderAbiType(tpe: DirectImportAbi.AbiType): String = tpe match {
    case DirectImportAbi.AbiType.Unit => "tuple<>"
    case DirectImportAbi.AbiType.Bool => "bool"
    case DirectImportAbi.AbiType.Int8 => "s8"
    case DirectImportAbi.AbiType.Int16 => "s16"
    case DirectImportAbi.AbiType.Int32 => "s32"
    case DirectImportAbi.AbiType.Int64 => "s64"
    case DirectImportAbi.AbiType.Float32 => "f32"
    case DirectImportAbi.AbiType.Float64 => "f64"
  }
}
