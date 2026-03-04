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

import ca.uwaterloo.flix.api.Flix
import ca.uwaterloo.flix.language.ast.shared.ExpPosition
import ca.uwaterloo.flix.language.ast.{AtomicOp, ErasedAst, LoweredAst, Purity, SemanticOp, SimpleType}
import ca.uwaterloo.flix.language.dbg.AstPrinter.DebugNoOp
import ca.uwaterloo.flix.util.CompilationTarget
import ca.uwaterloo.flix.util.ParOps

import scala.collection.mutable

/**
  * Computes backend-neutral lowered information (locals + pc-points).
  */
object Lowerer {

  def run(root: ErasedAst.Root)(implicit flix: Flix): LoweredAst.Root = flix.phase("Lowerer") {
    implicit val r: ErasedAst.Root = root
    val target = flix.options.target

    val defs = ParOps.parMapValues(root.defs)(visitDef(_, target))
    val enums = ParOps.parMapValues(root.enums)(visitEnum)
    val structs = ParOps.parMapValues(root.structs)(visitStruct)
    val effects = ParOps.parMapValues(root.effects)(visitEffect)

    LoweredAst.Root(defs, enums, structs, effects, root.mainEntryPoint, root.entryPoints, root.sources)
  }(DebugNoOp())

  private def visitDef(d: ErasedAst.Def, target: CompilationTarget)(implicit root: ErasedAst.Root): LoweredAst.Def = d match {
    case ErasedAst.Def(ann, mod, sym, cparams0, fparams0, exp, tpe, unboxedType0, loc) =>
      implicit val lctx: LocalContext = new LocalContext(isControlImpure = canSuspend(exp.purity, target))

      // It is important to visit parameters and variables in the order the backend expects: cparams, fparams, then lparams.
      val cparams = cparams0.map(visitFormalParam)
      val fparams = fparams0.map(visitFormalParam)
      val e = visitExpr(exp, target)

      val ls = lctx.lparams.toList
      val pcPoints = lctx.getPcPoints
      val unboxedType = LoweredAst.UnboxedType(unboxedType0.tpe)

      LoweredAst.Def(ann, mod, sym, cparams, fparams, ls, pcPoints, e, tpe, unboxedType, loc)
  }

  private def visitEnum(enm: ErasedAst.Enum): LoweredAst.Enum = {
    val cases = enm.cases.map {
      case (sym, caze) => sym -> visitCase(caze)
    }
    LoweredAst.Enum(enm.ann, enm.mod, enm.sym, cases, enm.loc)
  }

  private def visitCase(caze: ErasedAst.Case): LoweredAst.Case =
    LoweredAst.Case(caze.sym, caze.tpes, caze.loc)

  private def visitStruct(struct: ErasedAst.Struct): LoweredAst.Struct = {
    val fields = struct.fields.map(visitStructField)
    LoweredAst.Struct(struct.ann, struct.mod, struct.sym, fields, struct.loc)
  }

  private def visitStructField(field: ErasedAst.StructField): LoweredAst.StructField =
    LoweredAst.StructField(field.sym, field.tpe, field.loc)

  private def visitEffect(effect: ErasedAst.Effect): LoweredAst.Effect = {
    val ops = effect.ops.map(visitOp)
    LoweredAst.Effect(effect.ann, effect.mod, effect.sym, ops, effect.loc)
  }

  private def visitOp(op: ErasedAst.Op): LoweredAst.Op = {
    val fparams = op.fparams.map(visitFormalParam)
    LoweredAst.Op(op.sym, op.ann, op.mod, fparams, op.tpe, op.purity, op.loc)
  }

  private def visitExpr(exp0: ErasedAst.Expr, target: CompilationTarget)(implicit lctx: LocalContext, root: ErasedAst.Root): LoweredAst.Expr = exp0 match {
    case ErasedAst.Expr.Cst(cst, loc) =>
      LoweredAst.Expr.Cst(cst, loc)

    case ErasedAst.Expr.Var(sym, tpe, loc) =>
      LoweredAst.Expr.Var(sym, tpe, loc)

    case ErasedAst.Expr.ApplyAtomic(op, exps, tpe, purity, loc) =>
      val pcPointId = if (isSuspendableAtomicOp(op, target)) lctx.newPcPointId() else 0
      val es = exps.map(visitExpr(_, target))
      LoweredAst.Expr.ApplyAtomic(op, es, pcPointId, tpe, purity, loc)

    case ErasedAst.Expr.ApplyClo(exp1, exp2, ct, tpe, purity, loc) =>
      val pcPointId = if (ct == ExpPosition.NonTail && canSuspend(purity, target)) lctx.newPcPointId() else 0
      val e1 = visitExpr(exp1, target)
      val e2 = visitExpr(exp2, target)
      LoweredAst.Expr.ApplyClo(e1, e2, ct, pcPointId, tpe, purity, loc)

    case ErasedAst.Expr.ApplyDef(sym, exps, ct, tpe, purity, loc) =>
      val defn = root.defs(sym)
      val pcPointId = if (ct == ExpPosition.NonTail && canSuspend(defn.exp.purity, target)) lctx.newPcPointId() else 0
      val es = exps.map(visitExpr(_, target))
      LoweredAst.Expr.ApplyDef(sym, es, ct, pcPointId, tpe, purity, loc)

    case ErasedAst.Expr.ApplyOp(sym, exps, tpe, purity, loc) =>
      val pcPointId = lctx.newPcPointId()
      val es = exps.map(visitExpr(_, target))
      LoweredAst.Expr.ApplyOp(sym, es, pcPointId, tpe, purity, loc)

    case ErasedAst.Expr.ApplySelfTail(sym, actuals, tpe, purity, loc) =>
      val es = actuals.map(visitExpr(_, target))
      LoweredAst.Expr.ApplySelfTail(sym, es, tpe, purity, loc)

    case ErasedAst.Expr.IfThenElse(exp1, exp2, exp3, tpe, purity, loc) =>
      val e1 = visitExpr(exp1, target)
      val e2 = visitExpr(exp2, target)
      val e3 = visitExpr(exp3, target)
      LoweredAst.Expr.IfThenElse(e1, e2, e3, tpe, purity, loc)

    case ErasedAst.Expr.Branch(exp, branches, tpe, purity, loc) =>
      val e = visitExpr(exp, target)
      val bs = branches.map {
        case (label, body) => label -> visitExpr(body, target)
      }
      LoweredAst.Expr.Branch(e, bs, tpe, purity, loc)

    case ErasedAst.Expr.JumpTo(sym, tpe, purity, loc) =>
      LoweredAst.Expr.JumpTo(sym, tpe, purity, loc)

    case ErasedAst.Expr.Let(sym, exp1, exp2, loc) =>
      lctx.lparams.addOne(LoweredAst.LocalParam(sym, exp1.tpe))
      val e1 = visitExpr(exp1, target)
      val e2 = visitExpr(exp2, target)
      LoweredAst.Expr.Let(sym, e1, e2, loc)

    case ErasedAst.Expr.Stmt(exp1, exp2, loc) =>
      val e1 = visitExpr(exp1, target)
      val e2 = visitExpr(exp2, target)
      LoweredAst.Expr.Stmt(e1, e2, loc)

    case ErasedAst.Expr.Region(sym, exp, tpe, purity, loc) =>
      lctx.lparams.addOne(LoweredAst.LocalParam(sym, SimpleType.Region))
      val e = visitExpr(exp, target)
      LoweredAst.Expr.Region(sym, e, tpe, purity, loc)

    case ErasedAst.Expr.TryCatch(exp, rules, tpe, purity, loc) =>
      val e = visitExpr(exp, target)
      val rs = rules.map {
        case ErasedAst.CatchRule(sym, catchTpe, body) =>
          lctx.lparams.addOne(LoweredAst.LocalParam(sym, SimpleType.Object))
          val b = visitExpr(body, target)
          LoweredAst.CatchRule(sym, catchTpe, b)
      }
      LoweredAst.Expr.TryCatch(e, rs, tpe, purity, loc)

    case ErasedAst.Expr.RunWith(exp, effUse, rules, ct, tpe, purity, loc) =>
      val pcPointId = if (ct == ExpPosition.NonTail) lctx.newPcPointId() else 0
      val e = visitExpr(exp, target)
      val rs = rules.map {
        case ErasedAst.HandlerRule(op, fparams, body) =>
          val b = visitExpr(body, target)
          LoweredAst.HandlerRule(op, fparams.map(visitFormalParam), b)
      }
      LoweredAst.Expr.RunWith(e, effUse, rs, ct, pcPointId, tpe, purity, loc)

    case ErasedAst.Expr.NewObject(name, clazz, tpe, purity, methods, loc) =>
      val specs = methods.map {
        case ErasedAst.JvmMethod(ident, fparams, clo, retTpe, methPurity, methLoc) =>
          val c = visitExpr(clo, target)
          LoweredAst.JvmMethod(ident, fparams.map(visitFormalParam), c, retTpe, methPurity, methLoc)
      }
      LoweredAst.Expr.NewObject(name, clazz, tpe, purity, specs, loc)

  }

  private def visitFormalParam(fp: ErasedAst.FormalParam): LoweredAst.FormalParam =
    LoweredAst.FormalParam(fp.sym, fp.tpe)

  /**
    * A local non-shared context. Does not need to be thread-safe.
    */
  private class LocalContext(private val isControlImpure: Boolean) {

    val lparams: mutable.ArrayBuffer[LoweredAst.LocalParam] = mutable.ArrayBuffer.empty

    private var pcPoints: Int = 0

    def newPcPointId(): Int = {
      if (isControlImpure) {
        pcPoints += 1
        pcPoints
      } else {
        0
      }
    }

    def getPcPoints: Int = pcPoints
  }

  private def canSuspend(purity: Purity, target: CompilationTarget): Boolean = target match {
    case CompilationTarget.LlvmWasm => !Purity.isPure(purity)
    case _ => Purity.isControlImpure(purity)
  }

  private def isSuspendableAtomicOp(op: AtomicOp, target: CompilationTarget): Boolean = target match {
    case CompilationTarget.LlvmWasm =>
      op match {
        case AtomicOp.Unary(sop) => isSuspendableIoOp(sop)
        case _ => false
      }
    case _ => false
  }

  private def isSuspendableIoOp(sop: SemanticOp.UnaryOp): Boolean = sop match {
    case SemanticOp.IoOp.SleepMillis => true
    case SemanticOp.IoOp.FileExists => true
    case SemanticOp.IoOp.FileIsDirectory => true
    case SemanticOp.IoOp.FileIsRegularFile => true
    case SemanticOp.IoOp.FileIsReadable => true
    case SemanticOp.IoOp.FileIsSymbolicLink => true
    case SemanticOp.IoOp.FileIsWritable => true
    case SemanticOp.IoOp.FileIsExecutable => true
    case SemanticOp.IoOp.FileAccessTime => true
    case SemanticOp.IoOp.FileCreationTime => true
    case SemanticOp.IoOp.FileModificationTime => true
    case SemanticOp.IoOp.FileSize => true
    case SemanticOp.IoOp.FileRead => true
    case SemanticOp.IoOp.FileReadLines => true
    case SemanticOp.IoOp.FileReadBytes => true
    case SemanticOp.IoOp.FileList => true
    case SemanticOp.IoOp.FileWrite => true
    case SemanticOp.IoOp.FileWriteBytes => true
    case SemanticOp.IoOp.FileAppend => true
    case SemanticOp.IoOp.FileAppendBytes => true
    case SemanticOp.IoOp.FileTruncate => true
    case SemanticOp.IoOp.FileMkDir => true
    case SemanticOp.IoOp.FileMkDirs => true
    case SemanticOp.IoOp.FileMkTempDir => true
    case SemanticOp.IoOp.TcpSocketRead => true
    case SemanticOp.IoOp.TcpSocketWrite => true
    case SemanticOp.IoOp.TcpSocketConnect => true
    case SemanticOp.IoOp.TcpSocketClose => true
    case SemanticOp.IoOp.TcpServerBind => true
    case SemanticOp.IoOp.TcpServerLocalPort => true
    case SemanticOp.IoOp.TcpServerAccept => true
    case SemanticOp.IoOp.TcpServerClose => true
    case SemanticOp.IoOp.ProcessStdinWrite => true
    case SemanticOp.IoOp.ProcessExec => true
    case SemanticOp.IoOp.ProcessExitValue => true
    case SemanticOp.IoOp.ProcessIsAlive => true
    case SemanticOp.IoOp.ProcessPid => true
    case SemanticOp.IoOp.ProcessStop => true
    case SemanticOp.IoOp.ProcessWaitFor => true
    case SemanticOp.IoOp.ProcessWaitForTimeout => true
    case SemanticOp.IoOp.ProcessStdoutRead => true
    case SemanticOp.IoOp.ProcessStderrRead => true
    case SemanticOp.IoOp.ProcessRelease => true
    case SemanticOp.IoOp.HttpRequest => true
    case _ => false
  }

}
