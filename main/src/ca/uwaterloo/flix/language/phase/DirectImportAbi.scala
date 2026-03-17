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

import ca.uwaterloo.flix.language.ast.{SimpleType, Type, TypeConstructor}

object DirectImportAbi {

  sealed trait AbiType

  object AbiType {
    case object Unit extends AbiType
    case object Bool extends AbiType
    case object Int8 extends AbiType
    case object Int16 extends AbiType
    case object Int32 extends AbiType
    case object Int64 extends AbiType
    case object Float32 extends AbiType
    case object Float64 extends AbiType
  }

  case class Signature(params: List[AbiType], result: AbiType)

  def signatureOf(fparams: List[Type], result: Type): Option[Signature] = {
    val ps = fparams.map(toParamAbiType)
    val r = toResultAbiType(result)
    if (ps.forall(_.nonEmpty) && r.nonEmpty) Some(Signature(ps.flatten, r.get)) else None
  }

  def signatureOf(fparams: List[SimpleType], result: SimpleType): Option[Signature] = {
    val ps = fparams.map(toParamAbiType)
    val r = toResultAbiType(result)
    if (ps.forall(_.nonEmpty) && r.nonEmpty) Some(Signature(ps.flatten, r.get)) else None
  }

  def supportsParam(tpe: Type): Boolean = toParamAbiType(tpe).nonEmpty
  def supportsResult(tpe: Type): Boolean = toResultAbiType(tpe).nonEmpty
  def supportsParam(tpe: SimpleType): Boolean = toParamAbiType(tpe).nonEmpty
  def supportsResult(tpe: SimpleType): Boolean = toResultAbiType(tpe).nonEmpty

  private def toParamAbiType(tpe: Type): Option[AbiType] = toLeafAbiType(tpe).filter(_ != AbiType.Unit)
  private def toResultAbiType(tpe: Type): Option[AbiType] = toLeafAbiType(tpe)
  private def toParamAbiType(tpe: SimpleType): Option[AbiType] = toLeafAbiType(tpe).filter(_ != AbiType.Unit)
  private def toResultAbiType(tpe: SimpleType): Option[AbiType] = toLeafAbiType(tpe)

  private def toLeafAbiType(tpe: Type): Option[AbiType] = {
    if (tpe.typeVars.nonEmpty) None
    else tpe.typeConstructor match {
      case Some(TypeConstructor.Unit) => Some(AbiType.Unit)
      case Some(TypeConstructor.Bool) => Some(AbiType.Bool)
      case Some(TypeConstructor.Int8) => Some(AbiType.Int8)
      case Some(TypeConstructor.Int16) => Some(AbiType.Int16)
      case Some(TypeConstructor.Int32) => Some(AbiType.Int32)
      case Some(TypeConstructor.Int64) => Some(AbiType.Int64)
      case Some(TypeConstructor.Float32) => Some(AbiType.Float32)
      case Some(TypeConstructor.Float64) => Some(AbiType.Float64)
      case _ => None
    }
  }

  private def toLeafAbiType(tpe: SimpleType): Option[AbiType] = tpe match {
    case SimpleType.Unit => Some(AbiType.Unit)
    case SimpleType.Bool => Some(AbiType.Bool)
    case SimpleType.Int8 => Some(AbiType.Int8)
    case SimpleType.Int16 => Some(AbiType.Int16)
    case SimpleType.Int32 => Some(AbiType.Int32)
    case SimpleType.Int64 => Some(AbiType.Int64)
    case SimpleType.Float32 => Some(AbiType.Float32)
    case SimpleType.Float64 => Some(AbiType.Float64)
    case _ => None
  }
}
