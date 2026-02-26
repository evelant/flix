/*
 * Copyright 2023 Jonathan Lindegaard Starup
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

package ca.uwaterloo.flix.language.dbg.printer

import ca.uwaterloo.flix.language.ast.SemanticOp.*
import ca.uwaterloo.flix.language.ast.*
import ca.uwaterloo.flix.language.ast.shared.Mutability
import ca.uwaterloo.flix.language.dbg.DocAst
import ca.uwaterloo.flix.language.dbg.DocAst.Expr
import ca.uwaterloo.flix.language.dbg.DocAst.Expr.*
import ca.uwaterloo.flix.util.collection.ListOps

object OpPrinter {

  private val and = "and"
  private val div = "/"
  private val eq = "=="
  private val exp = "**"
  private val ge = ">="
  private val gt = ">"
  private val le = "<="
  private val lt = "<"
  private val minus = "-"
  private val mul = "*"
  private val neg = "-"
  private val neq = "!="
  private val not = "!"
  private val or = "or"
  private val plus = "+"
  private val rem = "rem"
  private val shl = "shl"
  private val shr = "shr"
  private val xor = "xor"

  /**
    * Returns the string representation of `so`.
    */
  def print(so: SemanticOp): String = so match {
    case BoolOp.Not |
         Int8Op.Not |
         Int16Op.Not |
         Int32Op.Not |
         Int64Op.Not => not
    case BoolOp.And |
         Int8Op.And |
         Int16Op.And |
         Int32Op.And => and
    case BoolOp.Or |
         Int8Op.Or |
         Int16Op.Or |
         Int32Op.Or |
         Int64Op.Or => or
    case BoolOp.Eq |
         Float32Op.Eq |
         CharOp.Eq |
         Float64Op.Eq |
         Int8Op.Eq |
         Int16Op.Eq |
         Int32Op.Eq |
         Int64Op.Eq => eq
    case BoolOp.Neq |
         CharOp.Neq |
         Float32Op.Neq |
         Float64Op.Neq |
         Int8Op.Neq |
         Int16Op.Neq |
         Int32Op.Neq |
         Int64Op.Neq => neq
    case CharOp.Lt |
         Float32Op.Lt |
         Float64Op.Lt |
         Int8Op.Lt |
         Int16Op.Lt |
         Int32Op.Lt |
         Int64Op.Lt => lt
    case CharOp.Le |
         Float32Op.Le |
         Float64Op.Le |
         Int8Op.Le |
         Int16Op.Le |
         Int32Op.Le |
         Int64Op.Le => le
    case CharOp.Gt |
         Float32Op.Gt |
         Float64Op.Gt |
         Int8Op.Gt |
         Int16Op.Gt |
         Int32Op.Gt |
         Int64Op.Gt => gt
    case CharOp.Ge |
         Float32Op.Ge |
         Float64Op.Ge |
         Int8Op.Ge |
         Int16Op.Ge |
         Int32Op.Ge |
         Int64Op.Ge => ge
    case Float32Op.Add |
         Float64Op.Add |
         Int8Op.Add |
         Int16Op.Add |
         Int32Op.Add |
         Int64Op.Add |
         Int64Op.And |
         StringOp.Concat => plus
    case Float32Op.Sub |
         Float64Op.Sub |
         Int8Op.Sub |
         Int16Op.Sub |
         Int32Op.Sub |
         Int64Op.Sub => minus
    case Float32Op.Mul |
         Float64Op.Mul |
         Int8Op.Mul |
         Int16Op.Mul |
         Int32Op.Mul |
         Int64Op.Mul => mul
    case Float32Op.Div |
         Float64Op.Div |
         Int8Op.Div |
         Int16Op.Div |
         Int32Op.Div |
         Int64Op.Div => div
    case Float32Op.Exp |
         Float64Op.Exp |
         Int8Op.Exp |
         Int16Op.Exp |
         Int32Op.Exp |
         Int64Op.Exp => exp
    case Float32Op.Neg |
         Float64Op.Neg |
         Int8Op.Neg |
         Int16Op.Neg |
         Int32Op.Neg |
         Int64Op.Neg => neg
    case Int8Op.Rem |
         Int16Op.Rem |
         Int32Op.Rem |
         Int64Op.Rem => rem
    case Int8Op.Xor |
         Int16Op.Xor |
         Int32Op.Xor |
         Int64Op.Xor => xor
    case Int8Op.Shl |
         Int16Op.Shl |
         Int32Op.Shl |
         Int64Op.Shl => shl
    case Int8Op.Shr |
         Int16Op.Shr |
         Int32Op.Shr |
         Int64Op.Shr => shr
    case ExnOp.KindId => "exnKindId"
    case ToStringOp.CharToString => "charToString"
    case ToStringOp.Float32ToString => "float32ToString"
    case ToStringOp.Float64ToString => "float64ToString"
    case ToStringOp.Int8ToString => "int8ToString"
    case ToStringOp.Int16ToString => "int16ToString"
    case ToStringOp.Int32ToString => "int32ToString"
    case ToStringOp.Int64ToString => "int64ToString"
    case ConvertOp.Int8ToInt16 => "int8ToInt16"
    case ConvertOp.Int8ToInt32 => "int8ToInt32"
    case ConvertOp.Int8ToInt64 => "int8ToInt64"
    case ConvertOp.Int8ToFloat32 => "int8ToFloat32"
    case ConvertOp.Int8ToFloat64 => "int8ToFloat64"
    case ConvertOp.Int16ToInt8 => "int16ToInt8"
    case ConvertOp.Int16ToInt32 => "int16ToInt32"
    case ConvertOp.Int16ToInt64 => "int16ToInt64"
    case ConvertOp.Int16ToFloat32 => "int16ToFloat32"
    case ConvertOp.Int16ToFloat64 => "int16ToFloat64"
    case ConvertOp.Int32ToInt8 => "int32ToInt8"
    case ConvertOp.Int32ToInt16 => "int32ToInt16"
    case ConvertOp.Int32ToInt64 => "int32ToInt64"
    case ConvertOp.Int32ToFloat32 => "int32ToFloat32"
    case ConvertOp.Int32ToFloat64 => "int32ToFloat64"
    case ConvertOp.Int64ToInt8 => "int64ToInt8"
    case ConvertOp.Int64ToInt16 => "int64ToInt16"
    case ConvertOp.Int64ToInt32 => "int64ToInt32"
    case ConvertOp.Int64ToFloat32 => "int64ToFloat32"
    case ConvertOp.Int64ToFloat64 => "int64ToFloat64"
    case ConvertOp.Float32ToInt8 => "float32ToInt8"
    case ConvertOp.Float32ToInt16 => "float32ToInt16"
    case ConvertOp.Float32ToInt32 => "float32ToInt32"
    case ConvertOp.Float32ToInt64 => "float32ToInt64"
    case ConvertOp.Float32ToFloat64 => "float32ToFloat64"
    case ConvertOp.Float64ToInt8 => "float64ToInt8"
    case ConvertOp.Float64ToInt16 => "float64ToInt16"
    case ConvertOp.Float64ToInt32 => "float64ToInt32"
    case ConvertOp.Float64ToInt64 => "float64ToInt64"
    case ConvertOp.Float64ToFloat32 => "float64ToFloat32"
    case CharOp.IsLetter => "charIsLetter"
    case CharOp.IsDigit => "charIsDigit"
    case CharOp.IsLetterOrDigit => "charIsLetterOrDigit"
    case CharOp.IsLowerCase => "charIsLowerCase"
    case CharOp.IsUpperCase => "charIsUpperCase"
    case CharOp.IsTitleCase => "charIsTitleCase"
    case CharOp.IsWhitespace => "charIsWhitespace"
    case CharOp.IsDefined => "charIsDefined"
    case CharOp.IsISOControl => "charIsISOControl"
    case CharOp.IsMirrored => "charIsMirrored"
    case CharOp.IsSurrogate => "charIsSurrogate"
    case CharOp.IsSurrogatePair => "charIsSurrogatePair"
    case CharOp.ToLowerCase => "charToLowerCase"
    case CharOp.ToUpperCase => "charToUpperCase"
    case CharOp.ToTitleCase => "charToTitleCase"
    case CharOp.GetNumericValue => "charGetNumericValue"
    case CharOp.ToCodePoint => "charToCodePoint"
    case CharOp.Digit => "charDigit"
    case CharOp.ForDigit => "charForDigit"
    case PlatformOp.FileSeparator => "fileSeparator"
    case PlatformOp.PathSeparator => "pathSeparator"
    case PlatformOp.LineSeparator => "lineSeparator"
    case ObjectOp.IsNull => "objectIsNull"
    case StringOp.Length => "stringLength"
    case StringOp.CharAt => "stringCharAt"
    case StringOp.ToLowerCase => "stringToLowerCase"
    case StringOp.ToUpperCase => "stringToUpperCase"
    case StringOp.Repeat => "stringRepeat"
    case ParseOp.Int8FromString => "int8FromString"
    case ParseOp.Int16FromString => "int16FromString"
    case ParseOp.Int32FromString => "int32FromString"
    case ParseOp.Int64FromString => "int64FromString"
    case ParseOp.Float32FromString => "float32FromString"
    case ParseOp.Float64FromString => "float64FromString"
    case ParseOp.Int32Parse => "int32Parse"
    case ParseOp.Int64Parse => "int64Parse"
    case StringBuilderOp.New => "stringBuilderNew"
    case StringBuilderOp.AppendString => "stringBuilderAppendString"
    case StringBuilderOp.AppendCodePoint => "stringBuilderAppendCodePoint"
    case StringBuilderOp.CharAt => "stringBuilderCharAt"
    case StringBuilderOp.Length => "stringBuilderLength"
    case StringBuilderOp.SetLength => "stringBuilderSetLength"
    case StringBuilderOp.ToString => "stringBuilderToString"
    case RegexOp.FlagCanonEq => "regexFlagCanonEq"
    case RegexOp.FlagCaseInsensitive => "regexFlagCaseInsensitive"
    case RegexOp.FlagComments => "regexFlagComments"
    case RegexOp.FlagDotall => "regexFlagDotall"
    case RegexOp.FlagLiteral => "regexFlagLiteral"
    case RegexOp.FlagMultiline => "regexFlagMultiline"
    case RegexOp.FlagUnicodeCase => "regexFlagUnicodeCase"
    case RegexOp.FlagUnicodeCharacterClass => "regexFlagUnicodeCharacterClass"
    case RegexOp.FlagUnixLines => "regexFlagUnixLines"
    case RegexOp.Compile => "regexCompile"
    case RegexOp.CompileWithFlags => "regexCompileWithFlags"
    case RegexOp.TryCompile => "regexTryCompile"
    case RegexOp.TryCompileWithFlags => "regexTryCompileWithFlags"
    case RegexOp.Quote => "regexQuote"
    case RegexOp.Pattern => "regexPattern"
    case RegexOp.Flags => "regexFlags"
    case RegexOp.Split => "regexSplit"
    case RegexOp.NewMatcher => "regexNewMatcher"
    case RegexOp.MatcherMatches => "regexMatcherMatches"
    case RegexOp.MatcherFind => "regexMatcherFind"
    case RegexOp.MatcherFindFrom => "regexMatcherFindFrom"
    case RegexOp.MatcherLookingAt => "regexMatcherLookingAt"
    case RegexOp.MatcherReplaceAll => "regexMatcherReplaceAll"
    case RegexOp.MatcherReplaceFirst => "regexMatcherReplaceFirst"
    case RegexOp.MatcherSetBounds => "regexMatcherSetBounds"
    case RegexOp.MatcherStart => "regexMatcherStart"
    case RegexOp.MatcherEnd => "regexMatcherEnd"
    case RegexOp.MatcherGroup => "regexMatcherGroup"
    case RegexOp.MatcherGroupCount => "regexMatcherGroupCount"
    case HashOp.CharHash => "charHash"
    case HashOp.Float32Hash => "float32Hash"
    case HashOp.Float64Hash => "float64Hash"
    case HashOp.Int8Hash => "int8Hash"
    case HashOp.Int16Hash => "int16Hash"
    case HashOp.Int32Hash => "int32Hash"
    case HashOp.Int64Hash => "int64Hash"
    case HashOp.StringHash => "stringHash"
    case IoOp.Print => "print"
    case IoOp.EPrint => "eprint"
    case IoOp.Readln => "readln"
    case IoOp.Println => "println"
    case IoOp.EPrintln => "eprintln"
    case IoOp.SleepMillis => "sleepMillis"
    case IoOp.Exit => "exit"
    case IoOp.NewId => "newId"
    case IoOp.TcpSocketRead => "tcpSocketRead"
    case IoOp.TcpSocketWrite => "tcpSocketWrite"
    case IoOp.TcpSocketConnect => "tcpSocketConnect"
    case IoOp.TcpSocketClose => "tcpSocketClose"
    case IoOp.TcpServerBind => "tcpServerBind"
    case IoOp.TcpServerAccept => "tcpServerAccept"
    case IoOp.TcpServerClose => "tcpServerClose"
    case IoOp.ProcessStdinWrite => "processStdinWrite"
    case IoOp.ProcessExec => "processExec"
    case IoOp.ProcessExitValue => "processExitValue"
    case IoOp.ProcessIsAlive => "processIsAlive"
    case IoOp.ProcessPid => "processPid"
    case IoOp.ProcessStop => "processStop"
    case IoOp.ProcessWaitFor => "processWaitFor"
    case IoOp.ProcessWaitForTimeout => "processWaitForTimeout"
    case IoOp.ProcessStdoutRead => "processStdoutRead"
    case IoOp.ProcessStderrRead => "processStderrRead"
    case IoOp.ProcessRelease => "processRelease"
    case IoOp.HttpRequest => "httpRequest"
    case IoOp.EnvGetArgs => "envGetArgs"
    case IoOp.EnvGetEnvPairs => "envGetEnvPairs"
    case IoOp.EnvGetVar => "envGetVar"
    case IoOp.EnvGetProp => "envGetProp"
    case IoOp.EnvVirtualProcessors => "envVirtualProcessors"
  }

  /**
    * Returns the [[DocAst.Expr]] representation of `op`.
    */
  def print(op: AtomicOp, ds: List[Expr], tpe: DocAst.Type, eff: DocAst.Type): Expr = (op, ds) match {
    case (AtomicOp.GetStaticField(field), Nil) => JavaGetStaticField(field)
    case (AtomicOp.HoleError(sym), Nil) => HoleError(sym)
    case (AtomicOp.MatchError, Nil) => MatchError
    case (AtomicOp.CastError(_, _), Nil) => CastError
    case (AtomicOp.Unary(sop), List(d)) => Unary(OpPrinter.print(sop), d)
    case (AtomicOp.Binary(sop), List(d1, d2)) => Binary(d1, OpPrinter.print(sop), d2)
    case (AtomicOp.Is(sym), List(d)) => Is(sym, d)
    case (AtomicOp.Tag(sym), _) => Tag(sym, ds)
    case (AtomicOp.Untag(_, idx), List(d)) => Untag(d, idx)
    case (AtomicOp.InstanceOf(clazz), List(d)) => InstanceOf(d, clazz)
    case (AtomicOp.Cast, List(d)) => UncheckedCast(d, Some(tpe), Some(eff))
    case (AtomicOp.Unbox, List(d)) => Unbox(d, tpe)
    case (AtomicOp.Box, List(d)) => Box(d)
    case (AtomicOp.Index(idx), List(d)) => Index(idx, d)
    case (AtomicOp.RecordSelect(label), List(d)) => RecordSelect(label, d)
    case (AtomicOp.RecordRestrict(label), List(d)) => RecordRestrict(label, d)
    case (AtomicOp.ArrayLength, List(d)) => ArrayLength(d)
    case (AtomicOp.StructNew(sym, Mutability.Mutable, fields), d :: rs) =>
      ListOps.zipOption(fields, rs) match {
        case None => Expr.Unknown
        case Some(fs) => Expr.StructNew(sym, fs, Some(d))
      }
    case (AtomicOp.StructNew(sym, Mutability.Immutable, fields), rs) =>
      ListOps.zipOption(fields, rs) match {
        case None => Expr.Unknown
        case Some(fs) => Expr.StructNew(sym, fs, None)
      }
    case (AtomicOp.StructGet(field), List(d)) => Expr.StructGet(d, field)
    case (AtomicOp.StructPut(field), List(d1, d2)) => Expr.StructPut(d1, field, d2)
    case (AtomicOp.Lazy, List(d)) => Lazy(d)
    case (AtomicOp.Force, List(d)) => Force(d)
    case (AtomicOp.GetField(field), List(d)) => JavaGetField(field, d)
    case (AtomicOp.PutStaticField(field), List(d)) => JavaPutStaticField(field, d)
    case (AtomicOp.Closure(sym), _) => ClosureLifted(sym, ds)
    case (AtomicOp.Tuple, _) => Tuple(ds)
    case (AtomicOp.ArrayLit, _) => ArrayLit(ds)
    case (AtomicOp.InvokeConstructor(constructor), _) => JavaInvokeConstructor(constructor, ds)
    case (AtomicOp.InvokeStaticMethod(method), _) => JavaInvokeStaticMethod(method, ds)
    case (AtomicOp.RecordExtend(label), List(d1, d2)) => RecordExtend(label, d1, d2)
    case (AtomicOp.ArrayNew, List(d1, d2)) => ArrayNew(d1, d2)
    case (AtomicOp.ArrayLoad, List(d1, d2)) => ArrayLoad(d1, d2)
    case (AtomicOp.Spawn, List(d1, d2)) => Spawn(d1, d2)
    case (AtomicOp.PutField(field), List(d1, d2)) => JavaPutField(field, d1, d2)
    case (AtomicOp.ArrayStore, List(d1, d2, d3)) => ArrayStore(d1, d2, d3)
    case (AtomicOp.InvokeMethod(method), d :: rs) => JavaInvokeMethod(method, d, rs)
    // fall back if non other applies
    case (op1, ds1) => App(Meta(op1.toString), ds1)
  }

}
