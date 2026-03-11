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

package ca.uwaterloo.flix.language.phase

import ca.uwaterloo.flix.language.ast.{SimpleType, Symbol, Type, TypeConstructor}
import ca.uwaterloo.flix.util.Result

import scala.annotation.tailrec

/**
  * Portable export ABI classification shared by the LLVM-native and LLVM-wasm embedding surfaces.
  *
  * v0 intentionally exposes a small, explicit type universe:
  *   Unit, Bool, Int8/16/32/64, Float32/64, String, and Bytes (`Array[Int8, Static]`).
  */
object ExportAbi {

  case class Signature(params: List[AbiType], result: AbiType)

  sealed trait AbiType {
    def displayName: String
  }

  object AbiType {
    case object Unit extends AbiType { val displayName = "Unit" }
    case object Bool extends AbiType { val displayName = "Bool" }
    case object Int8 extends AbiType { val displayName = "Int8" }
    case object Int16 extends AbiType { val displayName = "Int16" }
    case object Int32 extends AbiType { val displayName = "Int32" }
    case object Int64 extends AbiType { val displayName = "Int64" }
    case object Float32 extends AbiType { val displayName = "Float32" }
    case object Float64 extends AbiType { val displayName = "Float64" }
    case object String extends AbiType { val displayName = "String" }
    case object Bytes extends AbiType { val displayName = "Bytes" }
  }

  /**
    * Returns the portable v0 export ABI type for the given source-level type.
    *
    * `Ok(None)` means "well-formed but not exportable".
    * `Err(())` means "malformed / unresolved".
    */
  @tailrec
  def portableV0FromType(tpe: Type): Result[Option[AbiType], Unit] = tpe match {
    case Type.Cst(TypeConstructor.Unit, _) => Result.Ok(Some(AbiType.Unit))
    case Type.Cst(TypeConstructor.Bool, _) => Result.Ok(Some(AbiType.Bool))
    case Type.Cst(TypeConstructor.Int8, _) => Result.Ok(Some(AbiType.Int8))
    case Type.Cst(TypeConstructor.Int16, _) => Result.Ok(Some(AbiType.Int16))
    case Type.Cst(TypeConstructor.Int32, _) => Result.Ok(Some(AbiType.Int32))
    case Type.Cst(TypeConstructor.Int64, _) => Result.Ok(Some(AbiType.Int64))
    case Type.Cst(TypeConstructor.Float32, _) => Result.Ok(Some(AbiType.Float32))
    case Type.Cst(TypeConstructor.Float64, _) => Result.Ok(Some(AbiType.Float64))
    case Type.Cst(TypeConstructor.Str, _) => Result.Ok(Some(AbiType.String))

    // Array[Int8, Static]
    case Type.Apply(Type.Apply(Type.Cst(TypeConstructor.Array, _), elm, _), reg, _) =>
      (isInt8Type(elm), isStaticRegion(reg)) match {
        case (Result.Ok(true), Result.Ok(true)) => Result.Ok(Some(AbiType.Bytes))
        case (Result.Ok(_), Result.Ok(_)) => Result.Ok(None)
        case _ => Result.Err(())
      }

    case Type.Cst(_, _) => Result.Ok(None)
    case Type.Apply(_, _, _) => Result.Ok(None)
    case Type.Alias(_, _, t, _) => portableV0FromType(t)
    case Type.Var(_, _) => Result.Err(())
    case Type.AssocType(_, _, _, _) => Result.Err(())
    case Type.JvmToType(_, _) => Result.Err(())
    case Type.JvmToEff(_, _) => Result.Err(())
    case Type.UnresolvedJvmType(_, _) => Result.Err(())
  }

  /**
    * Returns the portable v0 export ABI type for the given lowered/simple type.
    */
  def portableV0FromSimpleType(tpe: SimpleType): Option[AbiType] = tpe match {
    case SimpleType.Unit => Some(AbiType.Unit)
    case SimpleType.Bool => Some(AbiType.Bool)
    case SimpleType.Int8 => Some(AbiType.Int8)
    case SimpleType.Int16 => Some(AbiType.Int16)
    case SimpleType.Int32 => Some(AbiType.Int32)
    case SimpleType.Int64 => Some(AbiType.Int64)
    case SimpleType.Float32 => Some(AbiType.Float32)
    case SimpleType.Float64 => Some(AbiType.Float64)
    case SimpleType.String => Some(AbiType.String)
    case SimpleType.Array(SimpleType.Int8) => Some(AbiType.Bytes)
    case _ => None
  }

  def portableV0Signature(params: List[SimpleType], result: SimpleType): Option[Signature] =
    for {
      ps <- traverse(params)(portableV0FromSimpleType)
      r <- portableV0FromSimpleType(result)
    } yield Signature(ps, r)

  @tailrec
  private def isInt8Type(tpe: Type): Result[Boolean, Unit] = tpe match {
    case Type.Cst(TypeConstructor.Int8, _) => Result.Ok(true)
    case Type.Alias(_, _, t, _) => isInt8Type(t)
    case Type.Cst(_, _) => Result.Ok(false)
    case Type.Apply(_, _, _) => Result.Ok(false)
    case Type.Var(_, _) => Result.Err(())
    case Type.AssocType(_, _, _, _) => Result.Err(())
    case Type.JvmToType(_, _) => Result.Err(())
    case Type.JvmToEff(_, _) => Result.Err(())
    case Type.UnresolvedJvmType(_, _) => Result.Err(())
  }

  @tailrec
  private def isStaticRegion(tpe: Type): Result[Boolean, Unit] = tpe match {
    case Type.Cst(TypeConstructor.Effect(sym, _), _) if sym == Symbol.IO => Result.Ok(true)
    case Type.Alias(_, _, t, _) => isStaticRegion(t)
    case Type.Cst(_, _) => Result.Ok(false)
    case Type.Apply(_, _, _) => Result.Ok(false)
    case Type.Var(_, _) => Result.Err(())
    case Type.AssocType(_, _, _, _) => Result.Err(())
    case Type.JvmToType(_, _) => Result.Err(())
    case Type.JvmToEff(_, _) => Result.Err(())
    case Type.UnresolvedJvmType(_, _) => Result.Err(())
  }

  private def traverse[A, B](xs: List[A])(f: A => Option[B]): Option[List[B]] =
    xs.foldRight(Option(List.empty[B])) {
      case (x, Some(acc)) => f(x).map(_ :: acc)
      case (_, None) => None
    }
}
