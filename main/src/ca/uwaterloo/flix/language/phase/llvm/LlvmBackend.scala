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
import ca.uwaterloo.flix.language.ast.AtomicOp
import ca.uwaterloo.flix.language.ast.LoweredAst.Expr
import ca.uwaterloo.flix.language.ast.SemanticOp.{BinaryOp, UnaryOp}
import ca.uwaterloo.flix.language.ast.shared.{Constant, ExpPosition}
import ca.uwaterloo.flix.language.ast.{ExnKindId, LoweredAst, Name, SemanticOp, SimpleType, Symbol}
import ca.uwaterloo.flix.language.dbg.AstPrinter.DebugNoOp
import ca.uwaterloo.flix.language.phase.llvm.LlvmIr.{Decl, Instr, Module as IrModule, Op, Terminator, Type, Value}
import ca.uwaterloo.flix.util.CompilationTarget

import scala.collection.mutable

/**
  * A minimal LLVM backend for bring-up.
  *
  * The emitted LLVM IR is intentionally incomplete: it supports only a pure subset of [[LoweredAst]].
  * The goal is to get the pipeline and artifact writing in place, while we incrementally expand support.
  */
object LlvmBackend {

  /** A thin wrapper around the emitted LLVM IR module text. */
  case class Module(text: String)

  def run(root: LoweredAst.Root)(implicit flix: Flix): Module = flix.phase("LlvmBackend") {
    val ir = new Emitter(root, flix.options.target).emitModule()
    Module(LlvmPrinter.printModule(ir))
  }(DebugNoOp())

  private final class Emitter(root: LoweredAst.Root, target: CompilationTarget) {

    private val flixResultTypeName: String = "flix_result_t"
    private val flixResultType: Type = Type.Named(flixResultTypeName)

    // flix_result_t tags (see docs/planning/native-backend/value-layout-v0.md).
    private val ResultTagValue: Long = 1L
    private val ResultTagThunk: Long = 2L
    private val ResultTagSuspension: Long = 3L
    private val ResultTagException: Long = 4L

    private val caseTagIds: Map[Symbol.CaseSym, Long] = computeCaseTagIds()
    private val effectSymIds: Map[Symbol.EffSym, Long] = computeEffectSymIds()
    private val opIndices: Map[Symbol.OpSym, Int] = computeOpIndices()

    private var tmpId: Int = 0
    private var labelId: Int = 0

    private val extraFunctions = mutable.ArrayBuffer.empty[LlvmIr.Function]
    private val extraFunctionNames = mutable.Set.empty[String]

    private def addExtraFunction(f: LlvmIr.Function): Unit = {
      if (extraFunctionNames.add(f.name)) {
        extraFunctions.addOne(f)
      }
    }

    private def freshTmp(tpe: Type): Value.Local = {
      tmpId += 1
      Value.Local(s"t$tmpId", tpe)
    }

    private def freshLabel(prefix: String): String = {
      labelId += 1
      s"$prefix$labelId"
    }

    def emitModule(): IrModule = {
      val typeDefs = List(
        LlvmIr.TypeDef(flixResultTypeName, Type.Struct(List(Type.I64, Type.I64)))
      )

      val decls = List(
        Decl.DeclareFun(Type.Void, "llvm.trap", Nil),
        Decl.DeclareFun(Type.Float, "llvm.pow.f32", List(Type.Float, Type.Float)),
        Decl.DeclareFun(Type.Double, "llvm.pow.f64", List(Type.Double, Type.Double)),
        Decl.DeclareFun(Type.Void, "flix_init", List(Type.I32, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_float32_to_string", List(Type.Float)),
        Decl.DeclareFun(Type.Ptr, "flix_float64_to_string", List(Type.Double)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_compile", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_compile_with_flags", List(Type.I32, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_try_compile", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_try_compile_with_flags", List(Type.I32, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_quote", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_pattern", List(Type.Ptr)),
        Decl.DeclareFun(Type.I32, "flix_regex_flags", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_new_matcher", List(Type.Ptr, Type.Ptr)),
        Decl.DeclareFun(Type.I1, "flix_regex_matcher_matches", List(Type.Ptr)),
        Decl.DeclareFun(Type.I1, "flix_regex_matcher_find", List(Type.Ptr)),
        Decl.DeclareFun(Type.I1, "flix_regex_matcher_find_from", List(Type.Ptr, Type.I32)),
        Decl.DeclareFun(Type.I1, "flix_regex_matcher_looking_at", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_matcher_replace_all", List(Type.Ptr, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_matcher_replace_first", List(Type.Ptr, Type.Ptr)),
        Decl.DeclareFun(Type.I64, "flix_regex_matcher_set_bounds", List(Type.Ptr, Type.I32, Type.I32)),
        Decl.DeclareFun(Type.I32, "flix_regex_matcher_start", List(Type.Ptr)),
        Decl.DeclareFun(Type.I32, "flix_regex_matcher_end", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_matcher_group", List(Type.Ptr, Type.I32)),
        Decl.DeclareFun(Type.I32, "flix_regex_matcher_group_count", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_regex_split", List(Type.Ptr, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_channel_new", List(Type.I32)),
        Decl.DeclareFun(Type.I64, "flix_channel_put", List(Type.Ptr, Type.I64)),
        Decl.DeclareFun(Type.I64, "flix_channel_get", List(Type.Ptr)),
        Decl.DeclareFun(Type.I64, "flix_spawn", List(Type.Ptr, Type.Ptr)),
        Decl.DeclareFun(Type.I64, "flix_print", List(Type.Ptr)),
        Decl.DeclareFun(Type.I64, "flix_eprint", List(Type.Ptr)),
        Decl.DeclareFun(Type.I64, "flix_println", List(Type.Ptr)),
        Decl.DeclareFun(Type.I64, "flix_eprintln", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_readln", List(Type.I64)),
        Decl.DeclareFun(Type.I64, "flix_sleep_millis", List(Type.I64)),
        Decl.DeclareFun(Type.Void, "flix_exit", List(Type.I32)),
        Decl.DeclareFun(Type.I64, "flix_new_id", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_tcp_socket_read", List(Type.I64, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_tcp_socket_write", List(Type.I64, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_tcp_socket_connect", List(Type.Ptr, Type.I32)),
        Decl.DeclareFun(Type.Ptr, "flix_tcp_socket_close", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_tcp_server_bind", List(Type.Ptr, Type.I32)),
        Decl.DeclareFun(Type.Ptr, "flix_tcp_server_accept", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_tcp_server_close", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_process_stdin_write", List(Type.I64, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_process_exec", List(Type.Ptr, Type.I1, Type.Ptr, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_process_exit_value", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_process_is_alive", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_process_pid", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_process_stop", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_process_wait_for", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_process_wait_for_timeout", List(Type.I64, Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_process_stdout_read", List(Type.I64, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_process_stderr_read", List(Type.I64, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_process_release", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_http_request", List(Type.Ptr, Type.Ptr, Type.Ptr, Type.I1, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_env_get_args", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_env_get_env_pairs", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_env_get_var", List(Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_env_get_prop", List(Type.Ptr)),
        Decl.DeclareFun(Type.I32, "flix_env_virtual_processors", List(Type.I64)),
        Decl.DeclareFun(Type.Ptr, "flix_frames_push", List(Type.Ptr, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_frames_reverse_onto", List(Type.Ptr, Type.Ptr)),
        Decl.DeclareFun(Type.Ptr, "flix_frame_copy", List(Type.Ptr)),
        Decl.DeclareFun(flixResultType, "flix_install_handler", List(Type.Ptr, Type.I64, Type.Ptr, Type.Ptr, Type.Ptr)),
        Decl.DeclareFun(flixResultType, "flix_resumption_rewind", List(Type.Ptr, Type.Ptr, Type.I64)),
        Decl.DeclareFun(Type.Ptr, "malloc", List(Type.I64))
      )

      val defFunctions = root.defs.values.toList.map(emitDef)
      val extra = extraFunctions.toList.sortBy(_.name)
      val closureWrappers = collectClosureSyms().toList.sortBy(_.toString).map(sym => emitClosureInvokeWrapper(root.defs(sym)))
      val thunkInvokeWrappers = collectThunkInvokeSyms().toList.sortBy(_.toString).map(sym => emitThunkInvokeWrapper(root.defs(sym)))
      val thunkApplyClosureWrappers = collectThunkApplyClosureArgTypes().toList.sortBy(_.render).map(emitThunkApplyClosureWrapper)
      val functions = (target, root.mainEntryPoint) match {
        case (CompilationTarget.LlvmNative, Some(mainSym)) =>
          defFunctions ::: extra ::: closureWrappers ::: thunkInvokeWrappers ::: thunkApplyClosureWrappers ::: List(emitNativeMainWrapper(mainSym))
        case _ =>
          defFunctions ::: extra ::: closureWrappers ::: thunkInvokeWrappers ::: thunkApplyClosureWrappers
      }

      IrModule(sourceFilename = "flix", typeDefs = typeDefs, decls = decls, functions = functions)
    }

    private def computeCaseTagIds(): Map[Symbol.CaseSym, Long] = {
      root.enums.values.flatMap { enm =>
        val sortedCases = enm.cases.keys.toList.sortBy(_.name)
        sortedCases.zipWithIndex.map {
          case (sym, idx) => sym -> idx.toLong
        }
      }.toMap
    }

    private def computeEffectSymIds(): Map[Symbol.EffSym, Long] = {
      // Assign stable, dense ids to effects for use in the LLVM runtime bring-up.
      // The only requirement is consistency within a compilation unit.
      root.effects.keys.toList.sortBy(_.toString).zipWithIndex.map {
        case (sym, idx) => sym -> (idx.toLong + 1L)
      }.toMap
    }

    private def computeOpIndices(): Map[Symbol.OpSym, Int] = {
      root.effects.values.flatMap { eff =>
        eff.ops.zipWithIndex.map {
          case (op, idx) => op.sym -> idx
        }
      }.toMap
    }

    private def recordFields(tpe: SimpleType): List[(String, SimpleType)] = {
      @scala.annotation.tailrec
      def loop(t: SimpleType, acc: List[(String, SimpleType)]): List[(String, SimpleType)] = t match {
        case SimpleType.RecordEmpty =>
          acc.reverse
        case SimpleType.RecordExtend(label, value, rest) =>
          loop(rest, (label, value) :: acc)
        case other =>
          throw new IllegalStateException(s"Unexpected record type: '$other'.")
      }
      loop(tpe, Nil)
    }

    private def extTagId(label: Name.Label): Long =
      fnv1a64(label.name)

    private def fnv1a64(s: String): Long = {
      // Stable 64-bit FNV-1a hash used for extensible tag ids in bring-up.
      var h = 0xcbf29ce484222325L
      val prime = 0x100000001b3L
      val bytes = s.getBytes(java.nio.charset.StandardCharsets.UTF_8)
      var i = 0
      while (i < bytes.length) {
        h ^= (bytes(i) & 0xff).toLong
        h *= prime
        i += 1
      }
      h
    }

    private def emitDef(defn: LoweredAst.Def): LlvmIr.Function = {
      if (ca.uwaterloo.flix.language.ast.Purity.isControlImpure(defn.exp.purity)) emitDefControlImpure(defn)
      else emitDefControlPure(defn)
    }

    private def emitDefControlPure(defn: LoweredAst.Def): LlvmIr.Function = {
      val fnName = LlvmNames.defName(defn.sym)

      val params = LlvmIr.Param("ctx", Type.Ptr) :: (defn.cparams ::: defn.fparams).zipWithIndex.map {
        case (p, i) => LlvmIr.Param(LlvmNames.paramName(i), llvmTypeOf(p.tpe))
      }

      val fb = new FunBuilder()
      val entry = fb.newBlock("entry")
      fb.setCurrent(entry)

      // Bind closure parameters (cparams) directly.
      var env: Map[Symbol.VarSym, Value] = Map.empty
      defn.cparams.zipWithIndex.foreach {
        case (p, i) =>
          env = env.updated(p.sym, Value.Local(LlvmNames.paramName(i), llvmTypeOf(p.tpe)))
      }

      // Bind function parameters (fparams) via stack slots so ApplySelfTail can update them.
      var slotTypes: Map[Symbol.VarSym, Type] = Map.empty
      defn.fparams.zipWithIndex.foreach {
        case (p, j) =>
          val idx = defn.cparams.length + j
          val paramTpe = llvmTypeOf(p.tpe)
          val paramVal = Value.Local(LlvmNames.paramName(idx), paramTpe)

          val slotPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(slotPtr, Op.Alloca(paramTpe))
          fb.current.emitStore(paramVal, slotPtr)

          env = env.updated(p.sym, slotPtr)
          slotTypes = slotTypes.updated(p.sym, paramTpe)
      }

      val ctxPtr = Value.Local("ctx", Type.Ptr)

      val loopLabel = freshLabel("loop")
      fb.current.setTerminator(Terminator.Br(loopLabel))

      val loopBlock = fb.newBlock(loopLabel)
      fb.setCurrent(loopBlock)

      val value = emitExpr(defn.exp, env, ctxPtr, fb, lenv = Map.empty, slotTypes = slotTypes, selfTailLabel = Some(loopLabel))
      if (!fb.current.isTerminated) {
        val packed = packResult(value, defn.tpe, fb)
        fb.current.setTerminator(Terminator.Ret(flixResultType, packed))
      }

      LlvmIr.Function(fnName, flixResultType, params, fb.result())
    }

    private def emitDefControlImpure(defn: LoweredAst.Def): LlvmIr.Function = {
      val fnName = LlvmNames.defName(defn.sym)
      addExtraFunction(emitFrameApplyFunction(defn))

      val params = LlvmIr.Param("ctx", Type.Ptr) :: (defn.cparams ::: defn.fparams).zipWithIndex.map {
        case (p, i) => LlvmIr.Param(LlvmNames.paramName(i), llvmTypeOf(p.tpe))
      }

      val fb = new FunBuilder()
      val entry = fb.newBlock("entry")
      fb.setCurrent(entry)

      val ctxPtr = Value.Local("ctx", Type.Ptr)

      val frameSlots = 3L + defn.cparams.length.toLong + defn.fparams.length.toLong + defn.lparams.length.toLong
      val sizeBytes = Value.IntConst(frameSlots * 8L, Type.I64)
      val framePtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(framePtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

      // Slot 0: frame apply function pointer bits.
      val codePtr = Value.Global(LlvmNames.frameApplyName(defn.sym), Type.Ptr)
      val codeBits = freshTmp(Type.I64)
      fb.current.emitAssign(codeBits, Op.Cast("ptrtoint", Type.I64, codePtr))
      storeI64Slot(framePtr, Value.IntConst(0L, Type.I64), codeBits, fb)

      // Slot 1: frame size in i64 slots.
      storeI64Slot(framePtr, Value.IntConst(1L, Type.I64), Value.IntConst(frameSlots, Type.I64), fb)

      // Slot 2: pc = 0.
      storeI64Slot(framePtr, Value.IntConst(2L, Type.I64), Value.IntConst(0L, Type.I64), fb)

      // Slots 3..: cparams, fparams, lparams.
      val varsBase = 3L
      (defn.cparams ::: defn.fparams).zipWithIndex.foreach {
        case (p, i) =>
          val idx = Value.IntConst(varsBase + i.toLong, Type.I64)
          val paramVal = Value.Local(LlvmNames.paramName(i), llvmTypeOf(p.tpe))
          val payload = boxToI64(paramVal, p.tpe, fb)
          storeI64Slot(framePtr, idx, payload, fb)
      }

      val localsBase = varsBase + (defn.cparams.length + defn.fparams.length).toLong
      defn.lparams.zipWithIndex.foreach {
        case (_, i) =>
          val idx = Value.IntConst(localsBase + i.toLong, Type.I64)
          storeI64Slot(framePtr, idx, Value.IntConst(0L, Type.I64), fb)
      }

      val callTmp = freshTmp(flixResultType)
      fb.current.emitAssign(callTmp, Op.Call(flixResultType, LlvmNames.frameApplyName(defn.sym), List(ctxPtr, framePtr, Value.IntConst(0L, Type.I64))))
      fb.current.setTerminator(Terminator.Ret(flixResultType, callTmp))

      LlvmIr.Function(fnName, flixResultType, params, fb.result())
    }

    private def emitFrameApplyFunction(defn: LoweredAst.Def): LlvmIr.Function = {
      val fnName = LlvmNames.frameApplyName(defn.sym)
      val params = List(
        LlvmIr.Param("ctx", Type.Ptr),
        LlvmIr.Param("self", Type.Ptr),
        LlvmIr.Param("arg0", Type.I64)
      )

      val fb = new FunBuilder()
      val entry = fb.newBlock("entry")
      fb.setCurrent(entry)

      val ctxPtr = Value.Local("ctx", Type.Ptr)
      val framePtr = Value.Local("self", Type.Ptr)
      val resumePayload = Value.Local("arg0", Type.I64)

      val pcPayload = loadI64Slot(framePtr, Value.IntConst(2L, Type.I64), fb)

      val pcLabel = (i: Int) => s"pc_${i}"
      val badLabel = freshLabel("pc_bad")

      // Dispatch chain on `pcPayload`.
      var i = 0
      var cur = fb.current
      while (i <= defn.pcPoints) {
        val isPc = freshTmp(Type.I1)
        cur.emitAssign(isPc, Op.ICmp("eq", pcPayload, Value.IntConst(i.toLong, Type.I64)))
        val nextLabel = if (i == defn.pcPoints) badLabel else freshLabel(s"pc_test_${i + 1}_")
        cur.setTerminator(Terminator.CondBr(isPc, pcLabel(i), nextLabel))
        if (i < defn.pcPoints) {
          cur = fb.newBlock(nextLabel)
        }
        i += 1
      }

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      // Pre-create pc blocks.
      val pcBlocks: Map[Int, BlockBuilder] = (0 to defn.pcPoints).map { id =>
        id -> fb.newBlock(pcLabel(id))
      }.toMap

      // Variable slots mapping: slot0=code, slot1=size, slot2=pc, slots3.. are vars.
      val base = 3L
      val slotIndexOf: Map[Symbol.VarSym, Long] = {
        val m = mutable.Map.empty[Symbol.VarSym, Long]
        defn.cparams.zipWithIndex.foreach { case (p, j) => m.put(p.sym, base + j.toLong) }
        val fBase = base + defn.cparams.length.toLong
        defn.fparams.zipWithIndex.foreach { case (p, j) => m.put(p.sym, fBase + j.toLong) }
        val lBase = fBase + defn.fparams.length.toLong
        defn.lparams.zipWithIndex.foreach { case (lp, j) => m.put(lp.sym, lBase + j.toLong) }
        m.toMap
      }

      // Compile from pc_0.
      fb.setCurrent(pcBlocks(0))
      val value = emitExprControlImpure(defn.exp, ctxPtr, fb, framePtr, slotIndexOf, lenv = Map.empty, resumePayload = resumePayload, pcBlocks = pcBlocks)
      if (!fb.current.isTerminated) {
        val packed = packResult(value, defn.tpe, fb)
        fb.current.setTerminator(Terminator.Ret(flixResultType, packed))
      }

      // Any pc blocks not filled are traps (should not happen if pcPoints is consistent).
      (1 to defn.pcPoints).foreach { id =>
        val b = pcBlocks(id)
        if (!b.isTerminated) {
          fb.setCurrent(b)
          fb.current.emitTrap()
          fb.current.setTerminator(Terminator.Unreachable)
        }
      }

      LlvmIr.Function(fnName, flixResultType, params, fb.result())
    }

    private def collectClosureSyms(): Set[Symbol.DefnSym] = {
      val syms = mutable.Set.empty[Symbol.DefnSym]

      def visitExp(e: Expr): Unit = e match {
        case Expr.Cst(_, _) => ()
        case Expr.Var(_, _, _) => ()

        case Expr.Let(_, e1, e2, _) =>
          visitExp(e1)
          visitExp(e2)

        case Expr.Stmt(e1, e2, _) =>
          visitExp(e1)
          visitExp(e2)

        case Expr.IfThenElse(e1, e2, e3, _, _, _) =>
          visitExp(e1)
          visitExp(e2)
          visitExp(e3)

        case Expr.Branch(e0, branches, _, _, _) =>
          visitExp(e0)
          branches.values.foreach(visitExp)

        case Expr.JumpTo(_, _, _, _) => ()

        case Expr.ApplyAtomic(op, exps, _, _, _) =>
          op match {
            case AtomicOp.Closure(sym) => syms += sym
            case _ => ()
          }
          exps.foreach(visitExp)

        case Expr.ApplyClo(e1, e2, _, _, _, _, _) =>
          visitExp(e1)
          visitExp(e2)

        case Expr.ApplyDef(_, exps, _, _, _, _, _) =>
          exps.foreach(visitExp)

        case Expr.ApplyOp(_, exps, _, _, _, _) =>
          exps.foreach(visitExp)

        case Expr.ApplySelfTail(_, actuals, _, _, _) =>
          actuals.foreach(visitExp)

        case Expr.Region(_, e0, _, _, _) =>
          visitExp(e0)

        case Expr.TryCatch(e0, rules, _, _, _) =>
          visitExp(e0)
          rules.foreach(r => visitExp(r.exp))

        case Expr.RunWith(e0, _, rules, _, _, _, _, _) =>
          visitExp(e0)
          rules.foreach(r => visitExp(r.exp))

        case Expr.NewObject(_, _, _, _, methods, _) =>
          methods.foreach(m => visitExp(m.exp))
      }

      root.defs.values.foreach(defn => visitExp(defn.exp))
      syms.toSet
    }

    private def collectThunkInvokeSyms(): Set[Symbol.DefnSym] = {
      val syms = mutable.Set.empty[Symbol.DefnSym]

      def visitExp(e: Expr): Unit = e match {
        case Expr.Cst(_, _) => ()
        case Expr.Var(_, _, _) => ()

        case Expr.Let(_, e1, e2, _) =>
          visitExp(e1)
          visitExp(e2)

        case Expr.Stmt(e1, e2, _) =>
          visitExp(e1)
          visitExp(e2)

        case Expr.IfThenElse(e1, e2, e3, _, _, _) =>
          visitExp(e1)
          visitExp(e2)
          visitExp(e3)

        case Expr.Branch(e0, branches, _, _, _) =>
          visitExp(e0)
          branches.values.foreach(visitExp)

        case Expr.JumpTo(_, _, _, _) => ()

        case Expr.ApplyAtomic(_, exps, _, _, _) =>
          exps.foreach(visitExp)

        case Expr.ApplyClo(e1, e2, _, _, _, _, _) =>
          visitExp(e1)
          visitExp(e2)

        case Expr.ApplyDef(sym, exps, ct, _, _, _, _) =>
          if (ct == ExpPosition.Tail) syms += sym
          exps.foreach(visitExp)

        case Expr.ApplyOp(_, exps, _, _, _, _) =>
          exps.foreach(visitExp)

        case Expr.ApplySelfTail(_, actuals, _, _, _) =>
          actuals.foreach(visitExp)

        case Expr.Region(_, e0, _, _, _) =>
          visitExp(e0)

        case Expr.TryCatch(e0, rules, _, _, _) =>
          visitExp(e0)
          rules.foreach(r => visitExp(r.exp))

        case Expr.RunWith(e0, _, rules, _, _, _, _, _) =>
          visitExp(e0)
          rules.foreach(r => visitExp(r.exp))

        case Expr.NewObject(_, _, _, _, methods, _) =>
          methods.foreach(m => visitExp(m.exp))
      }

      root.defs.values.foreach(defn => visitExp(defn.exp))
      syms.toSet
    }

    private def collectThunkApplyClosureArgTypes(): Set[Type] = {
      val tpes = mutable.Set.empty[Type]

      def visitExp(e: Expr): Unit = e match {
        case Expr.Cst(_, _) => ()
        case Expr.Var(_, _, _) => ()

        case Expr.Let(_, e1, e2, _) =>
          visitExp(e1)
          visitExp(e2)

        case Expr.Stmt(e1, e2, _) =>
          visitExp(e1)
          visitExp(e2)

        case Expr.IfThenElse(e1, e2, e3, _, _, _) =>
          visitExp(e1)
          visitExp(e2)
          visitExp(e3)

        case Expr.Branch(e0, branches, _, _, _) =>
          visitExp(e0)
          branches.values.foreach(visitExp)

        case Expr.JumpTo(_, _, _, _) => ()

        case Expr.ApplyAtomic(_, exps, _, _, _) =>
          exps.foreach(visitExp)

        case Expr.ApplyClo(e1, e2, ct, _, _, _, _) =>
          if (ct == ExpPosition.Tail) tpes += llvmTypeOf(e2.tpe)
          visitExp(e1)
          visitExp(e2)

        case Expr.ApplyDef(_, exps, _, _, _, _, _) =>
          exps.foreach(visitExp)

        case Expr.ApplyOp(_, exps, _, _, _, _) =>
          exps.foreach(visitExp)

        case Expr.ApplySelfTail(_, actuals, _, _, _) =>
          actuals.foreach(visitExp)

        case Expr.Region(_, e0, _, _, _) =>
          visitExp(e0)

        case Expr.TryCatch(e0, rules, _, _, _) =>
          visitExp(e0)
          rules.foreach(r => visitExp(r.exp))

        case Expr.RunWith(e0, _, rules, _, _, _, _, _) =>
          visitExp(e0)
          rules.foreach(r => visitExp(r.exp))

        case Expr.NewObject(_, _, _, _, methods, _) =>
          methods.foreach(m => visitExp(m.exp))
      }

      root.defs.values.foreach(defn => visitExp(defn.exp))
      tpes.toSet
    }

    private def emitClosureInvokeWrapper(defn: LoweredAst.Def): LlvmIr.Function = {
      val wrapperName = LlvmNames.closureInvokeName(defn.sym)
      val defName = LlvmNames.defName(defn.sym)

      val argTpe = defn.fparams.headOption.map(p => llvmTypeOf(p.tpe)).getOrElse(Type.I64)
      val params = List(
        LlvmIr.Param("ctx", Type.Ptr),
        LlvmIr.Param("self", Type.Ptr),
        LlvmIr.Param("arg0", argTpe)
      )

      val fb = new FunBuilder()
      val entry = fb.newBlock("entry")
      fb.setCurrent(entry)

      if (defn.fparams.length != 1) {
        fb.current.emitTrap()
        fb.current.setTerminator(Terminator.Ret(flixResultType, Value.Undef(flixResultType)))
        return LlvmIr.Function(wrapperName, flixResultType, params, fb.result())
      }

      val ctxPtr = Value.Local("ctx", Type.Ptr)
      val selfPtr = Value.Local("self", Type.Ptr)
      val arg0 = Value.Local("arg0", argTpe)

      val capturedArgs = defn.cparams.zipWithIndex.map {
        case (cp, i) =>
          val slotPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, selfPtr, Value.IntConst((i + 1).toLong, Type.I64)))

          val payload = freshTmp(Type.I64)
          fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
          unboxFromI64(payload, cp.tpe, fb)
      }

      val callTmp = freshTmp(flixResultType)
      fb.current.emitAssign(callTmp, Op.Call(flixResultType, defName, ctxPtr :: (capturedArgs :+ arg0)))
      fb.current.setTerminator(Terminator.Ret(flixResultType, callTmp))

      LlvmIr.Function(wrapperName, flixResultType, params, fb.result())
    }

    private def emitThunkInvokeWrapper(defn: LoweredAst.Def): LlvmIr.Function = {
      val wrapperName = LlvmNames.thunkInvokeName(defn.sym)
      val defName = LlvmNames.defName(defn.sym)

      val params = List(
        LlvmIr.Param("ctx", Type.Ptr),
        LlvmIr.Param("self", Type.Ptr),
        LlvmIr.Param("arg0", Type.I64), // dummy
      )

      val fb = new FunBuilder()
      val entry = fb.newBlock("entry")
      fb.setCurrent(entry)

      val ctxPtr = Value.Local("ctx", Type.Ptr)
      val selfPtr = Value.Local("self", Type.Ptr)

      val allParams = defn.cparams ::: defn.fparams
      val args = allParams.zipWithIndex.map {
        case (p, i) =>
          val slotPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, selfPtr, Value.IntConst((i + 1).toLong, Type.I64)))

          val payload = freshTmp(Type.I64)
          fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
          unboxFromI64(payload, p.tpe, fb)
      }

      val callTmp = freshTmp(flixResultType)
      fb.current.emitAssign(callTmp, Op.Call(flixResultType, defName, ctxPtr :: args))
      fb.current.setTerminator(Terminator.Ret(flixResultType, callTmp))

      LlvmIr.Function(wrapperName, flixResultType, params, fb.result())
    }

    private def emitThunkApplyClosureWrapper(argTpe: Type): LlvmIr.Function = {
      val wrapperName = LlvmNames.thunkApplyClosureName(argTpe)

      val params = List(
        LlvmIr.Param("ctx", Type.Ptr),
        LlvmIr.Param("self", Type.Ptr),
        LlvmIr.Param("arg0", Type.I64), // dummy
      )

      val fb = new FunBuilder()
      val entry = fb.newBlock("entry")
      fb.setCurrent(entry)

      val ctxPtr = Value.Local("ctx", Type.Ptr)
      val selfPtr = Value.Local("self", Type.Ptr)

      // Captured layout:
      //   slot 0: wrapper code pointer bits (i64)
      //   slot 1: closure pointer bits (i64)
      //   slot 2: argument payload bits (i64)
      val cloSlotPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(cloSlotPtr, Op.Gep(Type.I64, selfPtr, Value.IntConst(1L, Type.I64)))
      val cloBits = freshTmp(Type.I64)
      fb.current.emitAssign(cloBits, Op.Load(Type.I64, cloSlotPtr))

      val cloPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(cloPtr, Op.Cast("inttoptr", Type.Ptr, cloBits))

      val argSlotPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(argSlotPtr, Op.Gep(Type.I64, selfPtr, Value.IntConst(2L, Type.I64)))
      val argBits = freshTmp(Type.I64)
      fb.current.emitAssign(argBits, Op.Load(Type.I64, argSlotPtr))

      val argVal = unboxPayloadToType(argBits, argTpe, fb)

      // Load the invoke function pointer from the closure slot 0.
      val cloInvokeSlotPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(cloInvokeSlotPtr, Op.Gep(Type.I64, cloPtr, Value.IntConst(0L, Type.I64)))

      val codeBits = freshTmp(Type.I64)
      fb.current.emitAssign(codeBits, Op.Load(Type.I64, cloInvokeSlotPtr))

      val codePtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(codePtr, Op.Cast("inttoptr", Type.Ptr, codeBits))

      val callTmp = freshTmp(flixResultType)
      fb.current.emitAssign(callTmp, Op.CallIndirect(flixResultType, codePtr, List(ctxPtr, cloPtr, argVal)))
      fb.current.setTerminator(Terminator.Ret(flixResultType, callTmp))

      LlvmIr.Function(wrapperName, flixResultType, params, fb.result())
    }

    private def unboxPayloadToType(payload: Value, tpe: Type, fb: FunBuilder): Value = tpe match {
      case Type.I1 =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I1, payload))
        tmp
      case Type.I8 =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I8, payload))
        tmp
      case Type.I16 =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I16, payload))
        tmp
      case Type.I32 =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I32, payload))
        tmp
      case Type.I64 =>
        payload
      case Type.Float =>
        val asI32 = freshTmp(Type.I32)
        fb.current.emitAssign(asI32, Op.Cast("trunc", Type.I32, payload))
        val asF32 = freshTmp(Type.Float)
        fb.current.emitAssign(asF32, Op.Cast("bitcast", Type.Float, asI32))
        asF32
      case Type.Double =>
        val asF64 = freshTmp(Type.Double)
        fb.current.emitAssign(asF64, Op.Cast("bitcast", Type.Double, payload))
        asF64
      case Type.Ptr =>
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Cast("inttoptr", Type.Ptr, payload))
        tmp
      case _ =>
        fb.current.emitTrap()
        Value.Undef(tpe)
    }

    private def emitNativeMainWrapper(mainSym: Symbol.DefnSym): LlvmIr.Function = {
      val flixMainName = LlvmNames.defName(mainSym)
      val mainDef = root.defs(mainSym)

      val params = List(
        LlvmIr.Param("argc", Type.I32),
        LlvmIr.Param("argv", Type.Ptr)
      )

      val fb = new FunBuilder()
      val entry = fb.newBlock("entry")
      fb.setCurrent(entry)

      fb.current.emitCallVoid("flix_init", List(Value.Local("argc", Type.I32), Value.Local("argv", Type.Ptr)))

      // Call the Flix main entry point with a null context pointer for bring-up.
      val ctxPtr = Value.Null(Type.Ptr)
      val mainArgs = (mainDef.cparams ::: mainDef.fparams).map(p => defaultValueFor(p.tpe))
      val callTmp = freshTmp(flixResultType)
      fb.current.emitAssign(callTmp, Op.Call(flixResultType, flixMainName, ctxPtr :: mainArgs))

      // Ensure we run to completion even if main returns a THUNK.
      unwindThunkToValuePayload(callTmp, ctxPtr, fb)

      // Always exit successfully for now.
      fb.current.setTerminator(Terminator.Ret(Type.I32, Value.IntConst(0L, Type.I32)))

      LlvmIr.Function("main", Type.I32, params, fb.result())
    }

    private def defaultValueFor(tpe: SimpleType): Value = llvmTypeOf(tpe) match {
      case Type.I1 => Value.IntConst(0L, Type.I1)
      case Type.I8 => Value.IntConst(0L, Type.I8)
      case Type.I16 => Value.IntConst(0L, Type.I16)
      case Type.I32 => Value.IntConst(0L, Type.I32)
      case Type.I64 => Value.IntConst(0L, Type.I64)
      case Type.Float => Value.Float32Const(0)
      case Type.Double => Value.Float64Const(0L)
      case Type.Ptr => Value.Null(Type.Ptr)
      case other => Value.Undef(other)
    }

    private def llvmTypeOf(tpe: SimpleType): Type = tpe match {
      case SimpleType.Bool => Type.I1
      case SimpleType.Char => Type.I32
      case SimpleType.Int8 => Type.I8
      case SimpleType.Int16 => Type.I16
      case SimpleType.Int32 => Type.I32
      case SimpleType.Int64 => Type.I64
      case SimpleType.Float32 => Type.Float
      case SimpleType.Float64 => Type.Double
      case SimpleType.Unit => Type.I64
      case SimpleType.Null => Type.Ptr
      case SimpleType.Object => Type.I64
      case _ => Type.Ptr
    }

    private def packResult(v: Value, tpe: SimpleType, fb: FunBuilder): Value = {
      val payload = boxToI64(v, tpe, fb)
      packResultTagged(ResultTagValue, payload, fb)
    }

    private def packThunkResult(thunkPtr0: Value, fb: FunBuilder): Value = {
      val thunkPtr = castValue(thunkPtr0, Type.Ptr, fb)
      val payload = castValue(thunkPtr, Type.I64, fb)
      packResultTagged(ResultTagThunk, payload, fb)
    }

    private def packResultTagged(tag: Long, payload0: Value, fb: FunBuilder): Value = {
      val payload = castValue(payload0, Type.I64, fb)

      val r0 = freshTmp(flixResultType)
      fb.current.emitAssign(r0, Op.InsertValue(flixResultType, Value.Undef(flixResultType), Value.IntConst(tag, Type.I64), index = 0))

      val r1 = freshTmp(flixResultType)
      fb.current.emitAssign(r1, Op.InsertValue(flixResultType, r0, payload, index = 1))

      r1
    }

    /**
      * Unwinds thunks until we reach a non-thunk result (VALUE/SUSPENSION/EXCEPTION) and returns it.
      */
    private def unwindThunkToResult(result0: Value, ctxPtr: Value, fb: FunBuilder): Value = {
      val entryLabel = fb.current.label

      val loopLabel = freshLabel("unwind_loop")
      val bodyLabel = freshLabel("unwind_body")
      val endLabel = freshLabel("unwind_end")

      // Pre-header: jump to the loop.
      fb.current.setTerminator(Terminator.Br(loopLabel))

      val nextResult = freshTmp(flixResultType)

      // Loop header.
      val loopBlock = fb.newBlock(loopLabel)
      fb.setCurrent(loopBlock)

      val curResult = freshTmp(flixResultType)
      loopBlock.emitPhi(curResult, List((result0, entryLabel), (nextResult, bodyLabel)))

      val tag = freshTmp(Type.I64)
      loopBlock.emitAssign(tag, Op.ExtractValue(Type.I64, flixResultType, curResult, index = 0))

      val isThunk = freshTmp(Type.I1)
      loopBlock.emitAssign(isThunk, Op.ICmp("eq", tag, Value.IntConst(ResultTagThunk, Type.I64)))
      loopBlock.setTerminator(Terminator.CondBr(isThunk, bodyLabel, endLabel))

      // Loop body: invoke the thunk and iterate.
      val bodyBlock = fb.newBlock(bodyLabel)
      fb.setCurrent(bodyBlock)

      val payload = freshTmp(Type.I64)
      bodyBlock.emitAssign(payload, Op.ExtractValue(Type.I64, flixResultType, curResult, index = 1))

      val thunkPtr = freshTmp(Type.Ptr)
      bodyBlock.emitAssign(thunkPtr, Op.Cast("inttoptr", Type.Ptr, payload))

      // Invoke the thunk (same convention as [[emitInvokeThunk]]), but write directly into `nextResult` for the phi.
      val slot0Ptr = freshTmp(Type.Ptr)
      bodyBlock.emitAssign(slot0Ptr, Op.Gep(Type.I64, thunkPtr, Value.IntConst(0L, Type.I64)))

      val codeI64 = freshTmp(Type.I64)
      bodyBlock.emitAssign(codeI64, Op.Load(Type.I64, slot0Ptr))

      val codePtr = freshTmp(Type.Ptr)
      bodyBlock.emitAssign(codePtr, Op.Cast("inttoptr", Type.Ptr, codeI64))

      bodyBlock.emitAssign(nextResult, Op.CallIndirect(flixResultType, codePtr, List(ctxPtr, thunkPtr, Value.IntConst(0L, Type.I64))))
      bodyBlock.setTerminator(Terminator.Br(loopLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      curResult
    }

    /**
      * Unwinds suspension-free thunks until we reach a VALUE result and returns its payload bits.
      *
      * Bring-up behavior:
      *   - Traps on SUSPENSION or EXCEPTION.
      */
    private def unwindThunkToValuePayload(result0: Value, ctxPtr: Value, fb: FunBuilder): Value = {
      val r = unwindThunkToResult(result0, ctxPtr, fb)

      val tag = freshTmp(Type.I64)
      fb.current.emitAssign(tag, Op.ExtractValue(Type.I64, flixResultType, r, index = 0))
      val isValue = freshTmp(Type.I1)
      fb.current.emitAssign(isValue, Op.ICmp("eq", tag, Value.IntConst(ResultTagValue, Type.I64)))

      val valueLabel = freshLabel("unwind_value")
      val badLabel = freshLabel("unwind_bad")
      fb.current.setTerminator(Terminator.CondBr(isValue, valueLabel, badLabel))

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      val valueBlock = fb.newBlock(valueLabel)
      fb.setCurrent(valueBlock)

      val valuePayload = freshTmp(Type.I64)
      valueBlock.emitAssign(valuePayload, Op.ExtractValue(Type.I64, flixResultType, r, index = 1))
      valuePayload
    }

    /**
      * Invokes a thunk object (closure-like) using the thunk calling convention:
      *   flix_result_t (*)(ptr ctx, ptr self, i64 dummy_arg)
      */
    private def emitInvokeThunk(thunkPtr0: Value, ctxPtr: Value, fb: FunBuilder): Value = {
      val thunkPtr = castValue(thunkPtr0, Type.Ptr, fb)

      // Load the invoke function pointer from slot 0.
      val slot0Ptr = freshTmp(Type.Ptr)
      fb.current.emitAssign(slot0Ptr, Op.Gep(Type.I64, thunkPtr, Value.IntConst(0L, Type.I64)))

      val codeI64 = freshTmp(Type.I64)
      fb.current.emitAssign(codeI64, Op.Load(Type.I64, slot0Ptr))

      val codePtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(codePtr, Op.Cast("inttoptr", Type.Ptr, codeI64))

      val callTmp = freshTmp(flixResultType)
      fb.current.emitAssign(callTmp, Op.CallIndirect(flixResultType, codePtr, List(ctxPtr, thunkPtr, Value.IntConst(0L, Type.I64))))
      callTmp
    }

    private def boxToI64(v: Value, tpe: SimpleType, fb: FunBuilder): Value = tpe match {
      case SimpleType.Unit =>
        Value.IntConst(0L, Type.I64)

      case SimpleType.Bool =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Cast("zext", Type.I64, v))
        tmp

      case SimpleType.Char =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Cast("zext", Type.I64, v))
        tmp

      case SimpleType.Int8 =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I64, v))
        tmp

      case SimpleType.Int16 =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I64, v))
        tmp

      case SimpleType.Int32 =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I64, v))
        tmp

      case SimpleType.Int64 =>
        v

      case SimpleType.Float32 =>
        val asI32 = freshTmp(Type.I32)
        fb.current.emitAssign(asI32, Op.Cast("bitcast", Type.I32, v))

        val asI64 = freshTmp(Type.I64)
        fb.current.emitAssign(asI64, Op.Cast("zext", Type.I64, asI32))
        asI64

      case SimpleType.Float64 =>
        val asI64 = freshTmp(Type.I64)
        fb.current.emitAssign(asI64, Op.Cast("bitcast", Type.I64, v))
        asI64

      case SimpleType.Null =>
        Value.IntConst(0L, Type.I64)

      case SimpleType.Object =>
        v.tpe match {
          case Type.I64 => v
          case _ => castValue(v, Type.I64, fb)
        }

      case _ =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Cast("ptrtoint", Type.I64, v))
        tmp
    }

    private def unboxFromI64(payload: Value, tpe: SimpleType, fb: FunBuilder): Value = tpe match {
      case SimpleType.Unit =>
        Value.IntConst(0L, Type.I64)

      case SimpleType.Bool =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I1, payload))
        tmp

      case SimpleType.Char =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I32, payload))
        tmp

      case SimpleType.Int8 =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I8, payload))
        tmp

      case SimpleType.Int16 =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I16, payload))
        tmp

      case SimpleType.Int32 =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I32, payload))
        tmp

      case SimpleType.Int64 =>
        payload

      case SimpleType.Float32 =>
        val asI32 = freshTmp(Type.I32)
        fb.current.emitAssign(asI32, Op.Cast("trunc", Type.I32, payload))

        val asF32 = freshTmp(Type.Float)
        fb.current.emitAssign(asF32, Op.Cast("bitcast", Type.Float, asI32))
        asF32

      case SimpleType.Float64 =>
        val asF64 = freshTmp(Type.Double)
        fb.current.emitAssign(asF64, Op.Cast("bitcast", Type.Double, payload))
        asF64

      case SimpleType.Null =>
        Value.Null(Type.Ptr)

      case SimpleType.Object =>
        payload

      case _ =>
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Cast("inttoptr", Type.Ptr, payload))
        tmp
    }

    private def emitExpr(exp0: Expr,
                         env: Map[Symbol.VarSym, Value],
                         ctxPtr: Value,
                         fb: FunBuilder,
                         lenv: Map[Symbol.LabelSym, String],
                         slotTypes: Map[Symbol.VarSym, Type],
                         selfTailLabel: Option[String]): Value = exp0 match {
      case Expr.Cst(cst, _) =>
        emitConstant(cst, fb)

      case Expr.Var(sym, tpe, _) =>
        slotTypes.get(sym) match {
          case None =>
            env.getOrElse(sym, Value.Undef(llvmTypeOf(tpe)))
          case Some(valueTpe) =>
            val slotPtr = env.getOrElse(sym, Value.Undef(Type.Ptr))
            val tmp = freshTmp(valueTpe)
            fb.current.emitAssign(tmp, Op.Load(valueTpe, slotPtr))
            tmp
        }

      case Expr.Let(sym, exp1, exp2, _) =>
        val v1 = emitExpr(exp1, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel)
        if (fb.current.isTerminated) {
          Value.Undef(llvmTypeOf(exp0.tpe))
        } else {
          val env1 = env.updated(sym, v1)
          emitExpr(exp2, env1, ctxPtr, fb, lenv, slotTypes, selfTailLabel)
        }

      case Expr.Stmt(exp1, exp2, _) =>
        emitExpr(exp1, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel)
        if (fb.current.isTerminated) Value.Undef(llvmTypeOf(exp0.tpe))
        else emitExpr(exp2, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel)

      case Expr.Region(sym, exp, _, _, _) =>
        // Bring-up: the JVM backend ignores regions at runtime.
        // For now we represent regions as a null pointer and rely on the type system for safety.
        val env1 = env.updated(sym, Value.Null(Type.Ptr))
        emitExpr(exp, env1, ctxPtr, fb, lenv, slotTypes, selfTailLabel)

      case Expr.IfThenElse(exp1, exp2, exp3, tpe, _, _) =>
        val c0 = emitExpr(exp1, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel)
        if (fb.current.isTerminated) {
          return Value.Undef(llvmTypeOf(exp0.tpe))
        }
        val cond = coerceToI1(c0, fb)

        val thenLabel = freshLabel("then")
        val elseLabel = freshLabel("else")
        val endLabel = freshLabel("ifend")

        fb.current.setTerminator(Terminator.CondBr(cond, thenLabel, elseLabel))

        val joinTpe = llvmTypeOf(tpe)
        val incomings = mutable.ArrayBuffer.empty[(Value, String)]

        // Then.
        val thenBlock = fb.newBlock(thenLabel)
        fb.setCurrent(thenBlock)
        val vThen = emitExpr(exp2, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel)
        if (!fb.current.isTerminated) {
          val vThenCoerced = coerceValue(vThen, joinTpe, fb)
          val predLabel = fb.current.label
          fb.current.setTerminator(Terminator.Br(endLabel))
          incomings.addOne((vThenCoerced, predLabel))
        }

        // Else.
        val elseBlock = fb.newBlock(elseLabel)
        fb.setCurrent(elseBlock)
        val vElse = emitExpr(exp3, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel)
        if (!fb.current.isTerminated) {
          val vElseCoerced = coerceValue(vElse, joinTpe, fb)
          val predLabel = fb.current.label
          fb.current.setTerminator(Terminator.Br(endLabel))
          incomings.addOne((vElseCoerced, predLabel))
        }

        // Join.
        val joinBlock = fb.newBlock(endLabel)
        fb.setCurrent(joinBlock)

        if (incomings.isEmpty) {
          // Both branches terminate => no control flow reaches the join.
          joinBlock.setTerminator(Terminator.Unreachable)
          Value.Undef(joinTpe)
        } else {
          val phiDest = freshTmp(joinTpe)
          joinBlock.emitPhi(phiDest, incomings.toList)
          phiDest
        }

      case Expr.ApplyAtomic(op, exps, tpe, _, _) =>
        val argTpes = exps.map(_.tpe)
        emitExprs(exps, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel) match {
          case None => Value.Undef(llvmTypeOf(tpe))
          case Some(args) => emitApplyAtomic(op, argTpes, args, tpe, ctxPtr, fb)
        }

      case Expr.ApplyDef(sym, exps, ct, _, tpe, _, _) =>
        val fnName = LlvmNames.defName(sym)
        emitExprs(exps, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel) match {
          case None => Value.Undef(llvmTypeOf(tpe))
          case Some(args) =>
            ct match {
              case ExpPosition.Tail =>
                val thunkArgs = args.zip(exps).map {
                  case (v, e) => boxToI64(v, e.tpe, fb)
                }

                val slots = 1L + thunkArgs.length.toLong
                val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

                val thunkPtr = freshTmp(Type.Ptr)
                fb.current.emitAssign(thunkPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

                val codePtr = Value.Global(LlvmNames.thunkInvokeName(sym), Type.Ptr)
                val codeI64 = freshTmp(Type.I64)
                fb.current.emitAssign(codeI64, Op.Cast("ptrtoint", Type.I64, codePtr))

                val slot0Ptr = freshTmp(Type.Ptr)
                fb.current.emitAssign(slot0Ptr, Op.Gep(Type.I64, thunkPtr, Value.IntConst(0L, Type.I64)))
                fb.current.emitStore(codeI64, slot0Ptr)

                thunkArgs.zipWithIndex.foreach {
                  case (payload, i) =>
                    val slotPtr = freshTmp(Type.Ptr)
                    fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, thunkPtr, Value.IntConst((i + 1).toLong, Type.I64)))
                    fb.current.emitStore(payload, slotPtr)
                }

                val result = packThunkResult(thunkPtr, fb)
                fb.current.setTerminator(Terminator.Ret(flixResultType, result))
                Value.Undef(llvmTypeOf(tpe))

              case ExpPosition.NonTail =>
                val callTmp = freshTmp(flixResultType)
                fb.current.emitAssign(callTmp, Op.Call(flixResultType, fnName, ctxPtr :: args))

                val payload = unwindThunkToValuePayload(callTmp, ctxPtr, fb)
                unboxFromI64(payload, tpe, fb)
            }
        }

      case Expr.ApplyClo(exp1, exp2, ct, _, tpe, _, _) =>
        val clo = emitExpr(exp1, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel)
        if (fb.current.isTerminated) {
          Value.Undef(llvmTypeOf(tpe))
        } else {
          val arg = emitExpr(exp2, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel)
          if (fb.current.isTerminated) {
            Value.Undef(llvmTypeOf(tpe))
          } else {
            ct match {
              case ExpPosition.Tail =>
                val thunkArgs = List(
                  castValue(clo, Type.I64, fb),
                  boxToI64(arg, exp2.tpe, fb)
                )

                val slots = 1L + thunkArgs.length.toLong
                val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

                val thunkPtr = freshTmp(Type.Ptr)
                fb.current.emitAssign(thunkPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

                val codePtr = Value.Global(LlvmNames.thunkApplyClosureName(llvmTypeOf(exp2.tpe)), Type.Ptr)
                val codeI64 = freshTmp(Type.I64)
                fb.current.emitAssign(codeI64, Op.Cast("ptrtoint", Type.I64, codePtr))

                val slot0Ptr = freshTmp(Type.Ptr)
                fb.current.emitAssign(slot0Ptr, Op.Gep(Type.I64, thunkPtr, Value.IntConst(0L, Type.I64)))
                fb.current.emitStore(codeI64, slot0Ptr)

                thunkArgs.zipWithIndex.foreach {
                  case (payload, i) =>
                    val slotPtr = freshTmp(Type.Ptr)
                    fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, thunkPtr, Value.IntConst((i + 1).toLong, Type.I64)))
                    fb.current.emitStore(payload, slotPtr)
                }

                val result = packThunkResult(thunkPtr, fb)
                fb.current.setTerminator(Terminator.Ret(flixResultType, result))
                Value.Undef(llvmTypeOf(tpe))

              case ExpPosition.NonTail =>
                // Load the invoke function pointer from slot 0.
                val slot0Ptr = freshTmp(Type.Ptr)
                fb.current.emitAssign(slot0Ptr, Op.Gep(Type.I64, clo, Value.IntConst(0L, Type.I64)))

                val codeI64 = freshTmp(Type.I64)
                fb.current.emitAssign(codeI64, Op.Load(Type.I64, slot0Ptr))

                val codePtr = freshTmp(Type.Ptr)
                fb.current.emitAssign(codePtr, Op.Cast("inttoptr", Type.Ptr, codeI64))

                val callTmp = freshTmp(flixResultType)
                fb.current.emitAssign(callTmp, Op.CallIndirect(flixResultType, codePtr, List(ctxPtr, clo, arg)))

                val payload = unwindThunkToValuePayload(callTmp, ctxPtr, fb)
                unboxFromI64(payload, tpe, fb)
            }
          }
        }

      case Expr.ApplySelfTail(sym, actuals, _, _, _) =>
        emitExprs(actuals, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel) match {
          case None =>
            Value.Undef(llvmTypeOf(exp0.tpe))
          case Some(args) =>
            val defn = root.defs(sym)
            defn.fparams.zip(args).foreach {
              case (fp, arg) =>
                val expectedTpe = slotTypes.getOrElse(fp.sym, llvmTypeOf(fp.tpe))
                val slotPtr = env.getOrElse(fp.sym, Value.Undef(Type.Ptr))
                val coercedArg = castValue(arg, expectedTpe, fb)
                fb.current.emitStore(coercedArg, slotPtr)
            }

            selfTailLabel match {
              case Some(lbl) => fb.current.setTerminator(Terminator.Br(lbl))
              case None =>
                fb.current.emitTrap()
                fb.current.setTerminator(Terminator.Unreachable)
            }

            Value.Undef(llvmTypeOf(exp0.tpe))
        }

      case Expr.Branch(exp, branches, tpe, _, _) =>
        val joinTpe = llvmTypeOf(tpe)
        val endLabel = freshLabel("branch_end")

        val branchLabels = branches.keys.map { sym =>
          sym -> freshLabel("branch")
        }.toMap
        val lenv1 = lenv ++ branchLabels

        val entryValue = emitExpr(exp, env, ctxPtr, fb, lenv1, slotTypes, selfTailLabel)

        val incomings = mutable.ArrayBuffer.empty[(Value, String)]
        if (!fb.current.isTerminated) {
          val vEntry = coerceValue(entryValue, joinTpe, fb)
          val predLabel = fb.current.label
          fb.current.setTerminator(Terminator.Br(endLabel))
          incomings.addOne((vEntry, predLabel))
        }

        // Compile each branch block. Keep deterministic ordering by label id.
        val sortedBranches = branches.toList.sortBy(_._1.id)
        sortedBranches.foreach {
          case (sym, brExp) =>
            val label = branchLabels(sym)
            val b = fb.newBlock(label)
            fb.setCurrent(b)
            val v = emitExpr(brExp, env, ctxPtr, fb, lenv1, slotTypes, selfTailLabel)
            if (!fb.current.isTerminated) {
              val vCoerced = coerceValue(v, joinTpe, fb)
              val predLabel = fb.current.label
              fb.current.setTerminator(Terminator.Br(endLabel))
              incomings.addOne((vCoerced, predLabel))
            }
        }

        // Join.
        val joinBlock = fb.newBlock(endLabel)
        fb.setCurrent(joinBlock)
        if (incomings.isEmpty) {
          // No branch returns a value => no control flow reaches the join.
          joinBlock.setTerminator(Terminator.Unreachable)
          Value.Undef(joinTpe)
        } else {
          val phiDest = freshTmp(joinTpe)
          joinBlock.emitPhi(phiDest, incomings.toList)
          phiDest
        }

      case Expr.JumpTo(sym, _, _, _) =>
        lenv.get(sym) match {
          case Some(lbl) => fb.current.setTerminator(Terminator.Br(lbl))
          case None =>
            fb.current.emitTrap()
            fb.current.setTerminator(Terminator.Unreachable)
        }
        Value.Undef(llvmTypeOf(exp0.tpe))

      case Expr.RunWith(exp, effUse, rules, ct, pcPointId, tpe, _, _) =>
        emitRunWithExpression(exp, effUse.sym, rules, ct, pcPointId, tpe, env, slotTypes, selfTailLabel, ctxPtr, fb, None, Map.empty, lenv, Value.Undef(Type.I64), Map.empty)

      case _ =>
        // Unsupported for bring-up: emit a fail-fast trap.
        fb.current.emitTrap()
        Value.Undef(llvmTypeOf(exp0.tpe))
    }

    private def emitExprControlImpure(exp0: Expr,
                                     ctxPtr: Value,
                                     fb: FunBuilder,
                                     framePtr: Value,
                                     slotIndexOf: Map[Symbol.VarSym, Long],
                                     lenv: Map[Symbol.LabelSym, String],
                                     resumePayload: Value,
                                     pcBlocks: Map[Int, BlockBuilder]): Value = exp0 match {
      case Expr.Cst(cst, _) =>
        emitConstant(cst, fb)

      case Expr.Var(sym, tpe, _) =>
        val idx = slotIndexOf.getOrElse(sym, -1L)
        if (idx < 0) {
          fb.current.emitTrap()
          Value.Undef(llvmTypeOf(tpe))
        } else {
          val payload = loadI64Slot(framePtr, Value.IntConst(idx, Type.I64), fb)
          unboxFromI64(payload, tpe, fb)
        }

      case Expr.Let(sym, exp1, exp2, _) =>
        val v1 = emitExprControlImpure(exp1, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)
        if (fb.current.isTerminated) {
          Value.Undef(llvmTypeOf(exp0.tpe))
        } else {
          val idx = slotIndexOf.getOrElse(sym, -1L)
          if (idx < 0) {
            fb.current.emitTrap()
            Value.Undef(llvmTypeOf(exp0.tpe))
          } else {
            val payload = boxToI64(v1, exp1.tpe, fb)
            storeI64Slot(framePtr, Value.IntConst(idx, Type.I64), payload, fb)
            emitExprControlImpure(exp2, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)
          }
        }

      case Expr.Stmt(exp1, exp2, _) =>
        emitExprControlImpure(exp1, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)
        if (fb.current.isTerminated) Value.Undef(llvmTypeOf(exp0.tpe))
        else emitExprControlImpure(exp2, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)

      case Expr.Region(sym, exp, _, _, _) =>
        val idx = slotIndexOf.getOrElse(sym, -1L)
        if (idx >= 0) {
          storeI64Slot(framePtr, Value.IntConst(idx, Type.I64), Value.IntConst(0L, Type.I64), fb)
        }
        emitExprControlImpure(exp, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)

      case Expr.IfThenElse(exp1, exp2, exp3, tpe, _, _) =>
        val c0 = emitExprControlImpure(exp1, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)
        if (fb.current.isTerminated) return Value.Undef(llvmTypeOf(exp0.tpe))
        val cond = coerceToI1(c0, fb)

        val thenLabel = freshLabel("then")
        val elseLabel = freshLabel("else")
        val endLabel = freshLabel("ifend")

        fb.current.setTerminator(Terminator.CondBr(cond, thenLabel, elseLabel))

        val joinTpe = llvmTypeOf(tpe)
        val incomings = mutable.ArrayBuffer.empty[(Value, String)]

        val thenBlock = fb.newBlock(thenLabel)
        fb.setCurrent(thenBlock)
        val vThen = emitExprControlImpure(exp2, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)
        if (!fb.current.isTerminated) {
          val vThenCoerced = coerceValue(vThen, joinTpe, fb)
          val predLabel = fb.current.label
          fb.current.setTerminator(Terminator.Br(endLabel))
          incomings.addOne((vThenCoerced, predLabel))
        }

        val elseBlock = fb.newBlock(elseLabel)
        fb.setCurrent(elseBlock)
        val vElse = emitExprControlImpure(exp3, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)
        if (!fb.current.isTerminated) {
          val vElseCoerced = coerceValue(vElse, joinTpe, fb)
          val predLabel = fb.current.label
          fb.current.setTerminator(Terminator.Br(endLabel))
          incomings.addOne((vElseCoerced, predLabel))
        }

        val joinBlock = fb.newBlock(endLabel)
        fb.setCurrent(joinBlock)
        if (incomings.isEmpty) {
          joinBlock.setTerminator(Terminator.Unreachable)
          Value.Undef(joinTpe)
        } else {
          val phiDest = freshTmp(joinTpe)
          joinBlock.emitPhi(phiDest, incomings.toList)
          phiDest
        }

      case Expr.ApplyAtomic(op, exps, tpe, _, _) =>
        val argTpes = exps.map(_.tpe)
        emitExprsControlImpure(exps, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks) match {
          case None => Value.Undef(llvmTypeOf(tpe))
          case Some(args) => emitApplyAtomic(op, argTpes, args, tpe, ctxPtr, fb)
        }

      case Expr.ApplyDef(sym, exps, ct, pcPointId, tpe, _, _) =>
        val fnName = LlvmNames.defName(sym)
        emitExprsControlImpure(exps, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks) match {
          case None => Value.Undef(llvmTypeOf(tpe))
          case Some(args) =>
            ct match {
              case ExpPosition.Tail =>
                val thunkArgs = args.zip(exps).map {
                  case (v, e) => boxToI64(v, e.tpe, fb)
                }

                val slots = 1L + thunkArgs.length.toLong
                val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

                val thunkPtr = freshTmp(Type.Ptr)
                fb.current.emitAssign(thunkPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

                val codePtr = Value.Global(LlvmNames.thunkInvokeName(sym), Type.Ptr)
                val codeI64 = freshTmp(Type.I64)
                fb.current.emitAssign(codeI64, Op.Cast("ptrtoint", Type.I64, codePtr))

                val slot0Ptr = freshTmp(Type.Ptr)
                fb.current.emitAssign(slot0Ptr, Op.Gep(Type.I64, thunkPtr, Value.IntConst(0L, Type.I64)))
                fb.current.emitStore(codeI64, slot0Ptr)

                thunkArgs.zipWithIndex.foreach {
                  case (payload, i) =>
                    val slotPtr = freshTmp(Type.Ptr)
                    fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, thunkPtr, Value.IntConst((i + 1).toLong, Type.I64)))
                    fb.current.emitStore(payload, slotPtr)
                }

                val result = packThunkResult(thunkPtr, fb)
                fb.current.setTerminator(Terminator.Ret(flixResultType, result))
                Value.Undef(llvmTypeOf(tpe))

              case ExpPosition.NonTail =>
                val callTmp = freshTmp(flixResultType)
                fb.current.emitAssign(callTmp, Op.Call(flixResultType, fnName, ctxPtr :: args))

                if (pcPointId > 0) {
                  emitCallAndHandleSuspension(callTmp, pcPointId, tpe, ctxPtr, fb, framePtr, resumePayload, pcBlocks)
                } else {
                  val payload = unwindThunkToValuePayload(callTmp, ctxPtr, fb)
                  unboxFromI64(payload, tpe, fb)
                }
            }
        }

      case Expr.ApplyClo(exp1, exp2, ct, pcPointId, tpe, purity, _) =>
        val clo = emitExprControlImpure(exp1, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)
        if (fb.current.isTerminated) {
          Value.Undef(llvmTypeOf(tpe))
        } else {
          val arg = emitExprControlImpure(exp2, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)
          if (fb.current.isTerminated) {
            Value.Undef(llvmTypeOf(tpe))
          } else {
            ct match {
              case ExpPosition.Tail =>
                val thunkArgs = List(
                  castValue(clo, Type.I64, fb),
                  boxToI64(arg, exp2.tpe, fb)
                )

                val slots = 1L + thunkArgs.length.toLong
                val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

                val thunkPtr = freshTmp(Type.Ptr)
                fb.current.emitAssign(thunkPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

                val codePtr = Value.Global(LlvmNames.thunkApplyClosureName(llvmTypeOf(exp2.tpe)), Type.Ptr)
                val codeI64 = freshTmp(Type.I64)
                fb.current.emitAssign(codeI64, Op.Cast("ptrtoint", Type.I64, codePtr))

                val slot0Ptr = freshTmp(Type.Ptr)
                fb.current.emitAssign(slot0Ptr, Op.Gep(Type.I64, thunkPtr, Value.IntConst(0L, Type.I64)))
                fb.current.emitStore(codeI64, slot0Ptr)

                thunkArgs.zipWithIndex.foreach {
                  case (payload, i) =>
                    val slotPtr = freshTmp(Type.Ptr)
                    fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, thunkPtr, Value.IntConst((i + 1).toLong, Type.I64)))
                    fb.current.emitStore(payload, slotPtr)
                }

                val result = packThunkResult(thunkPtr, fb)
                fb.current.setTerminator(Terminator.Ret(flixResultType, result))
                Value.Undef(llvmTypeOf(tpe))

              case ExpPosition.NonTail =>
                val slot0Ptr = freshTmp(Type.Ptr)
                fb.current.emitAssign(slot0Ptr, Op.Gep(Type.I64, clo, Value.IntConst(0L, Type.I64)))

                val codeI64 = freshTmp(Type.I64)
                fb.current.emitAssign(codeI64, Op.Load(Type.I64, slot0Ptr))

                val codePtr = freshTmp(Type.Ptr)
                fb.current.emitAssign(codePtr, Op.Cast("inttoptr", Type.Ptr, codeI64))

                val callTmp = freshTmp(flixResultType)
                fb.current.emitAssign(callTmp, Op.CallIndirect(flixResultType, codePtr, List(ctxPtr, clo, arg)))

                if (pcPointId > 0 && ca.uwaterloo.flix.language.ast.Purity.isControlImpure(purity)) {
                  emitCallAndHandleSuspension(callTmp, pcPointId, tpe, ctxPtr, fb, framePtr, resumePayload, pcBlocks)
                } else {
                  val payload = unwindThunkToValuePayload(callTmp, ctxPtr, fb)
                  unboxFromI64(payload, tpe, fb)
                }
            }
          }
        }

      case Expr.ApplyOp(sym, exps, pcPointId, tpe, _, _) =>
        emitApplyOpSuspension(sym, exps, pcPointId, tpe, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)

      case Expr.ApplySelfTail(sym, actuals, _, _, _) =>
        emitExprsControlImpure(actuals, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks) match {
          case None => Value.Undef(llvmTypeOf(exp0.tpe))
          case Some(args) =>
            val defn = root.defs(sym)
            defn.fparams.zip(args).foreach {
              case (fp, arg0) =>
                val idx = slotIndexOf.getOrElse(fp.sym, -1L)
                if (idx >= 0) {
                  val payload = boxToI64(arg0, fp.tpe, fb)
                  storeI64Slot(framePtr, Value.IntConst(idx, Type.I64), payload, fb)
                }
            }
            storeI64Slot(framePtr, Value.IntConst(2L, Type.I64), Value.IntConst(0L, Type.I64), fb)
            fb.current.setTerminator(Terminator.Br("pc_0"))
            Value.Undef(llvmTypeOf(exp0.tpe))
        }

      case Expr.Branch(exp, branches, tpe, _, _) =>
        val joinTpe = llvmTypeOf(tpe)
        val endLabel = freshLabel("branch_end")

        val branchLabels = branches.keys.map { sym =>
          sym -> freshLabel("branch")
        }.toMap
        val lenv1 = lenv ++ branchLabels

        val entryValue = emitExprControlImpure(exp, ctxPtr, fb, framePtr, slotIndexOf, lenv1, resumePayload, pcBlocks)

        val incomings = mutable.ArrayBuffer.empty[(Value, String)]
        if (!fb.current.isTerminated) {
          val vEntry = coerceValue(entryValue, joinTpe, fb)
          val predLabel = fb.current.label
          fb.current.setTerminator(Terminator.Br(endLabel))
          incomings.addOne((vEntry, predLabel))
        }

        val sortedBranches = branches.toList.sortBy(_._1.id)
        sortedBranches.foreach {
          case (sym, brExp) =>
            val label = branchLabels(sym)
            val b = fb.newBlock(label)
            fb.setCurrent(b)
            val v = emitExprControlImpure(brExp, ctxPtr, fb, framePtr, slotIndexOf, lenv1, resumePayload, pcBlocks)
            if (!fb.current.isTerminated) {
              val vCoerced = coerceValue(v, joinTpe, fb)
              val predLabel = fb.current.label
              fb.current.setTerminator(Terminator.Br(endLabel))
              incomings.addOne((vCoerced, predLabel))
            }
        }

        val joinBlock = fb.newBlock(endLabel)
        fb.setCurrent(joinBlock)
        if (incomings.isEmpty) {
          joinBlock.setTerminator(Terminator.Unreachable)
          Value.Undef(joinTpe)
        } else {
          val phiDest = freshTmp(joinTpe)
          joinBlock.emitPhi(phiDest, incomings.toList)
          phiDest
        }

      case Expr.JumpTo(sym, _, _, _) =>
        lenv.get(sym) match {
          case Some(lbl) => fb.current.setTerminator(Terminator.Br(lbl))
          case None =>
            fb.current.emitTrap()
            fb.current.setTerminator(Terminator.Unreachable)
        }
        Value.Undef(llvmTypeOf(exp0.tpe))

      case Expr.RunWith(exp, effUse, rules, ct, pcPointId, tpe, _, _) =>
        emitRunWithExpression(exp, effUse.sym, rules, ct, pcPointId, tpe, Map.empty, Map.empty, None, ctxPtr, fb, Some(framePtr), slotIndexOf, lenv, resumePayload, pcBlocks)

      case _ =>
        fb.current.emitTrap()
        Value.Undef(llvmTypeOf(exp0.tpe))
    }

    private def emitExprsControlImpure(exps: List[Expr],
                                      ctxPtr: Value,
                                      fb: FunBuilder,
                                      framePtr: Value,
                                      slotIndexOf: Map[Symbol.VarSym, Long],
                                      lenv: Map[Symbol.LabelSym, String],
                                      resumePayload: Value,
                                      pcBlocks: Map[Int, BlockBuilder]): Option[List[Value]] = {
      val buf = mutable.ListBuffer.empty[Value]
      val it = exps.iterator
      while (it.hasNext && !fb.current.isTerminated) {
        buf.addOne(emitExprControlImpure(it.next(), ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks))
      }
      if (fb.current.isTerminated) None else Some(buf.toList)
    }

    private def emitCallAndHandleSuspension(result0: Value,
                                           pcPointId: Int,
                                           expectedTpe: SimpleType,
                                           ctxPtr: Value,
                                           fb: FunBuilder,
                                           framePtr: Value,
                                           resumePayload: Value,
                                           pcBlocks: Map[Int, BlockBuilder]): Value = {
      val r = unwindThunkToResult(result0, ctxPtr, fb)

      val tag = freshTmp(Type.I64)
      fb.current.emitAssign(tag, Op.ExtractValue(Type.I64, flixResultType, r, index = 0))

      val isValue = freshTmp(Type.I1)
      fb.current.emitAssign(isValue, Op.ICmp("eq", tag, Value.IntConst(ResultTagValue, Type.I64)))

      val valueLabel = freshLabel("call_value")
      val notValueLabel = freshLabel("call_not_value")
      fb.current.setTerminator(Terminator.CondBr(isValue, valueLabel, notValueLabel))

      val afterLabel = freshLabel("call_after")

      // Resume pc block.
      val resumeBlock = pcBlocks.getOrElse(pcPointId, throw new IllegalStateException(s"missing pc block: $pcPointId"))
      if (resumeBlock.isTerminated) {
        throw new IllegalStateException(s"pc block $pcPointId already terminated")
      }
      val resumeValue = {
        val saved = fb.current
        fb.setCurrent(resumeBlock)
        val v = unboxFromI64(resumePayload, expectedTpe, fb)
        fb.current.setTerminator(Terminator.Br(afterLabel))
        fb.setCurrent(saved)
        v
      }

      // VALUE path.
      val valueBlock = fb.newBlock(valueLabel)
      fb.setCurrent(valueBlock)
      val payload = freshTmp(Type.I64)
      fb.current.emitAssign(payload, Op.ExtractValue(Type.I64, flixResultType, r, index = 1))
      val valueValue = unboxFromI64(payload, expectedTpe, fb)
      fb.current.setTerminator(Terminator.Br(afterLabel))

      // Non-VALUE path.
      val notValueBlock = fb.newBlock(notValueLabel)
      fb.setCurrent(notValueBlock)
      val isSusp = freshTmp(Type.I1)
      fb.current.emitAssign(isSusp, Op.ICmp("eq", tag, Value.IntConst(ResultTagSuspension, Type.I64)))
      val suspLabel = freshLabel("call_susp")
      val exnLabel = freshLabel("call_exn")
      fb.current.setTerminator(Terminator.CondBr(isSusp, suspLabel, exnLabel))

      val suspBlock = fb.newBlock(suspLabel)
      fb.setCurrent(suspBlock)
      // Attach current frame as a prefix frame and return the suspension.
      val suspPayload = freshTmp(Type.I64)
      fb.current.emitAssign(suspPayload, Op.ExtractValue(Type.I64, flixResultType, r, index = 1))
      val suspPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(suspPtr, Op.Cast("inttoptr", Type.Ptr, suspPayload))

      val oldPrefixBits = loadI64Slot(suspPtr, Value.IntConst(2L, Type.I64), fb)
      val oldPrefixPtr = castValue(oldPrefixBits, Type.Ptr, fb)

      storeI64Slot(framePtr, Value.IntConst(2L, Type.I64), Value.IntConst(pcPointId.toLong, Type.I64), fb)

      val newPrefixPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(newPrefixPtr, Op.Call(Type.Ptr, "flix_frames_push", List(framePtr, oldPrefixPtr)))
      val newPrefixBits = freshTmp(Type.I64)
      fb.current.emitAssign(newPrefixBits, Op.Cast("ptrtoint", Type.I64, newPrefixPtr))
      storeI64Slot(suspPtr, Value.IntConst(2L, Type.I64), newPrefixBits, fb)

      fb.current.setTerminator(Terminator.Ret(flixResultType, r))

      val exnBlock = fb.newBlock(exnLabel)
      fb.setCurrent(exnBlock)
      val isExn = freshTmp(Type.I1)
      fb.current.emitAssign(isExn, Op.ICmp("eq", tag, Value.IntConst(ResultTagException, Type.I64)))
      val exnOkLabel = freshLabel("call_exn_ok")
      val exnBadLabel = freshLabel("call_exn_bad")
      fb.current.setTerminator(Terminator.CondBr(isExn, exnOkLabel, exnBadLabel))

      val exnOkBlock = fb.newBlock(exnOkLabel)
      fb.setCurrent(exnOkBlock)
      fb.current.setTerminator(Terminator.Ret(flixResultType, r))

      val exnBadBlock = fb.newBlock(exnBadLabel)
      fb.setCurrent(exnBadBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      // Join.
      val afterBlock = fb.newBlock(afterLabel)
      fb.setCurrent(afterBlock)
      val joinTpe = llvmTypeOf(expectedTpe)
      val phiDest = freshTmp(joinTpe)
      afterBlock.emitPhi(phiDest, List((valueValue, valueBlock.label), (resumeValue, resumeBlock.label)))
      phiDest
    }

    private def emitApplyOpSuspension(sym: Symbol.OpSym,
                                     exps: List[Expr],
                                     pcPointId: Int,
                                     tpe: SimpleType,
                                     ctxPtr: Value,
                                     fb: FunBuilder,
                                     framePtr: Value,
                                     slotIndexOf: Map[Symbol.VarSym, Long],
                                     lenv: Map[Symbol.LabelSym, String],
                                     resumePayload: Value,
                                     pcBlocks: Map[Int, BlockBuilder]): Value = {
      val effId = effectSymIds.getOrElse(sym.eff, 0L)
      val opIndex = opIndices.getOrElse(sym, -1)
      if (effId == 0L || opIndex < 0) {
        fb.current.emitTrap()
        return Value.Undef(llvmTypeOf(tpe))
      }

      emitExprsControlImpure(exps, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks) match {
        case None => Value.Undef(llvmTypeOf(tpe))
        case Some(args) =>
          val argPayloads = args.zip(exps).map {
            case (v, e) => boxToI64(v, e.tpe, fb)
          }

          // Set pc on the current frame.
          storeI64Slot(framePtr, Value.IntConst(2L, Type.I64), Value.IntConst(pcPointId.toLong, Type.I64), fb)

          // Create prefix frames list with this frame.
          val prefixPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(prefixPtr, Op.Call(Type.Ptr, "flix_frames_push", List(framePtr, Value.Null(Type.Ptr))))
          val prefixBits = freshTmp(Type.I64)
          fb.current.emitAssign(prefixBits, Op.Cast("ptrtoint", Type.I64, prefixPtr))

          // Allocate suspension object.
          val slots = 5L + argPayloads.length.toLong
          val sizeBytes = Value.IntConst(slots * 8L, Type.I64)
          val suspPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(suspPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

          storeI64Slot(suspPtr, Value.IntConst(0L, Type.I64), Value.IntConst(effId, Type.I64), fb)
          storeI64Slot(suspPtr, Value.IntConst(1L, Type.I64), Value.IntConst(opIndex.toLong, Type.I64), fb)
          storeI64Slot(suspPtr, Value.IntConst(2L, Type.I64), prefixBits, fb)
          storeI64Slot(suspPtr, Value.IntConst(3L, Type.I64), Value.IntConst(0L, Type.I64), fb)
          storeI64Slot(suspPtr, Value.IntConst(4L, Type.I64), Value.IntConst(argPayloads.length.toLong, Type.I64), fb)
          argPayloads.zipWithIndex.foreach {
            case (p, i) =>
              storeI64Slot(suspPtr, Value.IntConst(5L + i.toLong, Type.I64), p, fb)
          }

          val suspBits = freshTmp(Type.I64)
          fb.current.emitAssign(suspBits, Op.Cast("ptrtoint", Type.I64, suspPtr))
          val r = packResultTagged(ResultTagSuspension, suspBits, fb)
          fb.current.setTerminator(Terminator.Ret(flixResultType, r))

          // Resume pc block.
          val afterLabel = freshLabel("do_after")
          val resumeBlock = pcBlocks.getOrElse(pcPointId, throw new IllegalStateException(s"missing pc block: $pcPointId"))
          if (resumeBlock.isTerminated) {
            throw new IllegalStateException(s"pc block $pcPointId already terminated")
          }
          val resumedValue = {
            val saved = fb.current
            fb.setCurrent(resumeBlock)
            val v = unboxFromI64(resumePayload, tpe, fb)
            fb.current.setTerminator(Terminator.Br(afterLabel))
            fb.setCurrent(saved)
            v
          }

          val afterBlock = fb.newBlock(afterLabel)
          fb.setCurrent(afterBlock)
          val joinTpe = llvmTypeOf(tpe)
          val phiDest = freshTmp(joinTpe)
          afterBlock.emitPhi(phiDest, List((resumedValue, resumeBlock.label)))
          phiDest
      }
    }

    private def emitRunWithExpression(exp: Expr,
                                     effSym: Symbol.EffSym,
                                     rules: List[LoweredAst.HandlerRule],
                                     ct: ExpPosition,
                                     pcPointId: Int,
                                     tpe: SimpleType,
                                     env: Map[Symbol.VarSym, Value],
                                     slotTypes: Map[Symbol.VarSym, Type],
                                     selfTailLabel: Option[String],
                                     ctxPtr: Value,
                                     fb: FunBuilder,
                                     framePtrOpt: Option[Value],
                                     slotIndexOf: Map[Symbol.VarSym, Long],
                                     lenv: Map[Symbol.LabelSym, String],
                                     resumePayload: Value,
                                     pcBlocks: Map[Int, BlockBuilder]): Value = {
      val effId = effectSymIds.getOrElse(effSym, 0L)
      val eff = root.effects.getOrElse(effSym, throw new IllegalStateException(s"missing effect: $effSym"))

      val thunkPtr = framePtrOpt match {
        case None =>
          emitExpr(exp, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel)
        case Some(framePtr) =>
          emitExprControlImpure(exp, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)
      }
      if (fb.current.isTerminated) return Value.Undef(llvmTypeOf(tpe))

      val opCount = eff.ops.length
      val handlerSlots = 2L + 2L * opCount.toLong
      val handlerSize = Value.IntConst(handlerSlots * 8L, Type.I64)
      val handlerPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(handlerPtr, Op.Call(Type.Ptr, "malloc", List(handlerSize)))

      storeI64Slot(handlerPtr, Value.IntConst(0L, Type.I64), Value.IntConst(effId, Type.I64), fb)
      storeI64Slot(handlerPtr, Value.IntConst(1L, Type.I64), Value.IntConst(opCount.toLong, Type.I64), fb)

      val ruleMap = rules.map(r => r.op.sym -> r).toMap
      eff.ops.zipWithIndex.foreach {
        case (op, idx) =>
          val rule = ruleMap.getOrElse(op.sym, throw new IllegalStateException(s"missing handler rule for op: ${op.sym}"))

          val cloPtr = framePtrOpt match {
            case None =>
              emitExpr(rule.exp, env, ctxPtr, fb, lenv, slotTypes, selfTailLabel)
            case Some(framePtr) =>
              emitExprControlImpure(rule.exp, ctxPtr, fb, framePtr, slotIndexOf, lenv, resumePayload, pcBlocks)
          }

          val cloBits = castValue(cloPtr, Type.I64, fb)
          storeI64Slot(handlerPtr, Value.IntConst((2L + idx.toLong * 2L + 1L), Type.I64), cloBits, fb)

          val closureSym = findClosureSym(rule.exp).getOrElse(throw new IllegalStateException("expected handler rule closure"))
          val wrapperName = getOrEmitEffectOpWrapper(op.sym, closureSym)
          val wrapperBits = freshTmp(Type.I64)
          fb.current.emitAssign(wrapperBits, Op.Cast("ptrtoint", Type.I64, Value.Global(wrapperName, Type.Ptr)))
          storeI64Slot(handlerPtr, Value.IntConst((2L + idx.toLong * 2L), Type.I64), wrapperBits, fb)
      }

      val callTmp = freshTmp(flixResultType)
      fb.current.emitAssign(callTmp, Op.Call(flixResultType, "flix_install_handler", List(ctxPtr, Value.IntConst(effId, Type.I64), handlerPtr, Value.Null(Type.Ptr), castValue(thunkPtr, Type.Ptr, fb))))

      ct match {
        case ExpPosition.Tail =>
          fb.current.setTerminator(Terminator.Ret(flixResultType, callTmp))
          Value.Undef(llvmTypeOf(tpe))
        case ExpPosition.NonTail =>
          framePtrOpt match {
            case Some(framePtr) if pcPointId > 0 =>
              emitCallAndHandleSuspension(callTmp, pcPointId, tpe, ctxPtr, fb, framePtr, resumePayload, pcBlocks)
            case _ =>
              val payload = unwindThunkToValuePayload(callTmp, ctxPtr, fb)
              unboxFromI64(payload, tpe, fb)
          }
      }
    }

    private def findClosureSym(exp0: Expr): Option[Symbol.DefnSym] = exp0 match {
      case Expr.ApplyAtomic(AtomicOp.Closure(sym), _, _, _, _) => Some(sym)
      case Expr.ApplyAtomic(AtomicOp.Box | AtomicOp.Unbox | AtomicOp.Cast, exps, _, _, _) if exps.length == 1 =>
        findClosureSym(exps.head)
      case _ => None
    }

    private def getOrEmitResumptionInvokeWrapper(argTpe: SimpleType): String = {
      val name = s"flix_k_invoke_${LlvmNamesInternal.mangle(llvmTypeOf(argTpe).render)}"
      if (extraFunctionNames.contains(name)) return name
      addExtraFunction(emitResumptionInvokeWrapper(name, argTpe))
      name
    }

    private def emitResumptionInvokeWrapper(name: String, argTpe: SimpleType): LlvmIr.Function = {
      val llvmArgTpe = llvmTypeOf(argTpe)
      val params = List(
        LlvmIr.Param("ctx", Type.Ptr),
        LlvmIr.Param("self", Type.Ptr),
        LlvmIr.Param("arg0", llvmArgTpe)
      )

      val fb = new FunBuilder()
      val entry = fb.newBlock("entry")
      fb.setCurrent(entry)

      val ctxPtr = Value.Local("ctx", Type.Ptr)
      val selfPtr = Value.Local("self", Type.Ptr)
      val arg0 = Value.Local("arg0", llvmArgTpe)

      val resBits = loadI64Slot(selfPtr, Value.IntConst(1L, Type.I64), fb)
      val resPtr = castValue(resBits, Type.Ptr, fb)
      val payload = boxToI64(arg0, argTpe, fb)
      val callTmp = freshTmp(flixResultType)
      fb.current.emitAssign(callTmp, Op.Call(flixResultType, "flix_resumption_rewind", List(ctxPtr, resPtr, payload)))
      fb.current.setTerminator(Terminator.Ret(flixResultType, callTmp))

      LlvmIr.Function(name, flixResultType, params, fb.result())
    }

    private def getOrEmitEffectOpWrapper(opSym: Symbol.OpSym, closureSym: Symbol.DefnSym): String = {
      val name = s"flix_eff_wrap_${LlvmNamesInternal.mangle(opSym.toString)}_${LlvmNamesInternal.mangle(closureSym.toString)}"
      if (extraFunctionNames.contains(name)) return name
      addExtraFunction(emitEffectOpWrapper(name, opSym, closureSym))
      name
    }

    private def emitEffectOpWrapper(name: String, opSym: Symbol.OpSym, closureSym: Symbol.DefnSym): LlvmIr.Function = {
      val params = List(
        LlvmIr.Param("ctx", Type.Ptr),
        LlvmIr.Param("handler", Type.Ptr),
        LlvmIr.Param("resumption", Type.Ptr),
        LlvmIr.Param("suspension", Type.Ptr)
      )

      val fb = new FunBuilder()
      val entry = fb.newBlock("entry")
      fb.setCurrent(entry)

      val ctxPtr = Value.Local("ctx", Type.Ptr)
      val handlerPtr = Value.Local("handler", Type.Ptr)
      val resumptionPtr = Value.Local("resumption", Type.Ptr)
      val suspensionPtr = Value.Local("suspension", Type.Ptr)

      val opIdx = opIndices.getOrElse(opSym, throw new IllegalStateException(s"missing op index: $opSym"))
      val opDef = root.effects(opSym.eff).ops(opIdx)

      // Load handler rule closure pointer from handler slots.
      val closureSlot = 2L + 2L * opIdx.toLong + 1L
      val cloBits = loadI64Slot(handlerPtr, Value.IntConst(closureSlot, Type.I64), fb)
      val cloPtr = castValue(cloBits, Type.Ptr, fb)

      // Allocate continuation closure that captures the resumption.
      val kInvokeName = getOrEmitResumptionInvokeWrapper(opDef.tpe)
      val kPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(kPtr, Op.Call(Type.Ptr, "malloc", List(Value.IntConst(16L, Type.I64))))

      val kCodeBits = freshTmp(Type.I64)
      fb.current.emitAssign(kCodeBits, Op.Cast("ptrtoint", Type.I64, Value.Global(kInvokeName, Type.Ptr)))
      storeI64Slot(kPtr, Value.IntConst(0L, Type.I64), kCodeBits, fb)

      val resBits = freshTmp(Type.I64)
      fb.current.emitAssign(resBits, Op.Cast("ptrtoint", Type.I64, resumptionPtr))
      storeI64Slot(kPtr, Value.IntConst(1L, Type.I64), resBits, fb)

      val closureDef = root.defs(closureSym)
      val capturedArgs = closureDef.cparams.zipWithIndex.map {
        case (cp, i) =>
          val payload = loadI64Slot(cloPtr, Value.IntConst((i + 1).toLong, Type.I64), fb)
          unboxFromI64(payload, cp.tpe, fb)
      }

      val opArgs = opDef.fparams.zipWithIndex.map {
        case (fp, i) =>
          val payload = loadI64Slot(suspensionPtr, Value.IntConst((5L + i.toLong), Type.I64), fb)
          unboxFromI64(payload, fp.tpe, fb)
      }

      val expectedFormalCount = if (opDef.fparams.isEmpty) 2 else opDef.fparams.length + 1
      if (closureDef.fparams.length != expectedFormalCount) {
        throw new IllegalStateException(s"Unexpected handler rule arity for '$closureSym'. Expected $expectedFormalCount. Actual ${closureDef.fparams.length}.")
      }

      val formalArgs = if (opDef.fparams.isEmpty) {
        val unitArg = Value.IntConst(0L, Type.I64)
        val kArgTpe = llvmTypeOf(closureDef.fparams(1).tpe)
        val kArg = castValue(kPtr, kArgTpe, fb)
        List(unitArg, kArg)
      } else {
        val kArgTpe = llvmTypeOf(closureDef.fparams.last.tpe)
        val kArg = castValue(kPtr, kArgTpe, fb)
        opArgs :+ kArg
      }

      val callTmp = freshTmp(flixResultType)
      fb.current.emitAssign(callTmp, Op.Call(flixResultType, LlvmNames.defName(closureSym), ctxPtr :: (capturedArgs ::: formalArgs)))
      fb.current.setTerminator(Terminator.Ret(flixResultType, callTmp))

      LlvmIr.Function(name, flixResultType, params, fb.result())
    }

    private def emitExprs(exps: List[Expr],
                          env: Map[Symbol.VarSym, Value],
                          ctxPtr: Value,
                          fb: FunBuilder,
                          lenv: Map[Symbol.LabelSym, String],
                          slotTypes: Map[Symbol.VarSym, Type],
                          selfTailLabel: Option[String]): Option[List[Value]] = {
      val buf = mutable.ListBuffer.empty[Value]
      val it = exps.iterator
      while (it.hasNext && !fb.current.isTerminated) {
        buf.addOne(emitExpr(it.next(), env, ctxPtr, fb, lenv, slotTypes, selfTailLabel))
      }
      if (fb.current.isTerminated) None else Some(buf.toList)
    }

    private def coerceToI1(v: Value, fb: FunBuilder): Value = {
      v.tpe match {
        case Type.I1 => v
        case Type.Ptr =>
          val tmp = freshTmp(Type.I1)
          fb.current.emitAssign(tmp, Op.ICmp("ne", v, Value.Null(Type.Ptr)))
          tmp
        case t if isIntType(t) =>
          val tmp = freshTmp(Type.I1)
          fb.current.emitAssign(tmp, Op.ICmp("ne", v, Value.IntConst(0L, t)))
          tmp
        case _ =>
          fb.current.emitTrap()
          Value.Undef(Type.I1)
      }
    }

    private def coerceValue(v: Value, expectedTpe: Type, fb: FunBuilder): Value = {
      if (v.tpe == expectedTpe) return v
      (v.tpe, expectedTpe) match {
        case (Type.I1, Type.I64) =>
          val tmp = freshTmp(Type.I64)
          fb.current.emitAssign(tmp, Op.Cast("zext", Type.I64, v))
          tmp
        case (Type.I32, Type.I64) =>
          val tmp = freshTmp(Type.I64)
          fb.current.emitAssign(tmp, Op.Cast("sext", Type.I64, v))
          tmp
        case (Type.I64, Type.I32) =>
          val tmp = freshTmp(Type.I32)
          fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I32, v))
          tmp
        case (Type.I64, Type.I1) =>
          val tmp = freshTmp(Type.I1)
          fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I1, v))
          tmp
        case _ =>
          v
      }
    }

    private def emitConstant(cst: Constant, fb: FunBuilder): Value = cst match {
      case Constant.Unit =>
        Value.IntConst(0L, Type.I64)

      case Constant.Bool(lit) =>
        Value.IntConst(if (lit) 1L else 0L, Type.I1)

      case Constant.Char(lit) =>
        Value.IntConst(lit.toLong, Type.I32)

      case Constant.Int8(lit) =>
        Value.IntConst(lit.toLong, Type.I8)

      case Constant.Int16(lit) =>
        Value.IntConst(lit.toLong, Type.I16)

      case Constant.Int32(lit) =>
        Value.IntConst(lit.toLong, Type.I32)

      case Constant.Int64(lit) =>
        Value.IntConst(lit, Type.I64)

      case Constant.Float32(lit) =>
        Value.Float32Const(java.lang.Float.floatToRawIntBits(lit))

      case Constant.Float64(lit) =>
        Value.Float64Const(java.lang.Double.doubleToRawLongBits(lit))

      case Constant.Null =>
        Value.Null(Type.Ptr)

      case Constant.Static =>
        // Bring-up: represent the static region as null.
        Value.Null(Type.Ptr)

      case Constant.RecordEmpty =>
        // Bring-up: represent the empty record as null.
        Value.Null(Type.Ptr)

      case Constant.Str(lit) =>
        val len = lit.length.toLong
        val slots = 1L + len
        val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

        val strPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(strPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

        val lenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, strPtr, Value.IntConst(0L, Type.I64)))
        fb.current.emitStore(Value.IntConst(len, Type.I64), lenPtr)

        var i = 0
        while (i < lit.length) {
          val slotPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, strPtr, Value.IntConst((i + 1).toLong, Type.I64)))
          fb.current.emitStore(Value.IntConst(lit.charAt(i).toLong, Type.I64), slotPtr)
          i += 1
        }

        strPtr

      case _ =>
        fb.current.emitTrap()
        Value.Undef(Type.Ptr)
    }

    private def loadI64Slot(basePtr0: Value, idx: Value, fb: FunBuilder): Value = {
      val basePtr = castValue(basePtr0, Type.Ptr, fb)
      val slotPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, basePtr, idx))
      val payload = freshTmp(Type.I64)
      fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
      payload
    }

    private def storeI64Slot(basePtr0: Value, idx: Value, payload: Value, fb: FunBuilder): Unit = {
      val basePtr = castValue(basePtr0, Type.Ptr, fb)
      val slotPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, basePtr, idx))
      fb.current.emitStore(payload, slotPtr)
    }

    private def loadTupleElement(tuplePtr0: Value, idx: Long, tpe: SimpleType, fb: FunBuilder): Value = {
      val payload = loadI64Slot(tuplePtr0, Value.IntConst(idx, Type.I64), fb)
      unboxFromI64(payload, tpe, fb)
    }

    private def allocTuple2(payload0: Value, payload1: Value, fb: FunBuilder): Value = {
      val tupPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(tupPtr, Op.Call(Type.Ptr, "malloc", List(Value.IntConst(16L, Type.I64))))
      storeI64Slot(tupPtr, Value.IntConst(0L, Type.I64), payload0, fb)
      storeI64Slot(tupPtr, Value.IntConst(1L, Type.I64), payload1, fb)
      tupPtr
    }

    private def stringLenI64(strPtr0: Value, fb: FunBuilder): Value = {
      val strPtr = castValue(strPtr0, Type.Ptr, fb)
      val lenPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, strPtr, Value.IntConst(0L, Type.I64)))
      val lenI64 = freshTmp(Type.I64)
      fb.current.emitAssign(lenI64, Op.Load(Type.I64, lenPtr))
      lenI64
    }

    private def stringCharPayloadI64(strPtr0: Value, idxI64: Value, fb: FunBuilder): Value = {
      val strPtr = castValue(strPtr0, Type.Ptr, fb)
      val slotIdx = freshTmp(Type.I64)
      fb.current.emitAssign(slotIdx, Op.Bin("add", Type.I64, idxI64, Value.IntConst(1L, Type.I64)))
      loadI64Slot(strPtr, slotIdx, fb)
    }

    private def allocString(lenI64: Value, fb: FunBuilder): Value = {
      val slots = freshTmp(Type.I64)
      fb.current.emitAssign(slots, Op.Bin("add", Type.I64, lenI64, Value.IntConst(1L, Type.I64)))
      val sizeBytes = freshTmp(Type.I64)
      fb.current.emitAssign(sizeBytes, Op.Bin("mul", Type.I64, slots, Value.IntConst(8L, Type.I64)))
      val strPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(strPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))
      storeI64Slot(strPtr, Value.IntConst(0L, Type.I64), lenI64, fb)
      strPtr
    }

    private def emitApplyAtomic(op: AtomicOp, argTpes: List[SimpleType], args: List[Value], resultTpe: SimpleType, ctxPtr: Value, fb: FunBuilder): Value = op match {
      case AtomicOp.Closure(sym) =>
        val captured = args.zip(argTpes).map {
          case (v, tpe) => boxToI64(v, tpe, fb)
        }

        val slots = 1L + captured.length.toLong
        val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

        val cloPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(cloPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

        // Slot 0: invoke function pointer, stored as i64.
        val codePtr = Value.Global(LlvmNames.closureInvokeName(sym), Type.Ptr)
        val codeI64 = freshTmp(Type.I64)
        fb.current.emitAssign(codeI64, Op.Cast("ptrtoint", Type.I64, codePtr))

        val slot0Ptr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slot0Ptr, Op.Gep(Type.I64, cloPtr, Value.IntConst(0L, Type.I64)))
        fb.current.emitStore(codeI64, slot0Ptr)

        captured.zipWithIndex.foreach {
          case (payload, i) =>
            val slotPtr = freshTmp(Type.Ptr)
            fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, cloPtr, Value.IntConst((i + 1).toLong, Type.I64)))
            fb.current.emitStore(payload, slotPtr)
        }

        cloPtr

      case AtomicOp.Tuple =>
        val elms = args.zip(argTpes).map {
          case (v, tpe) => boxToI64(v, tpe, fb)
        }

        val slots = elms.length.toLong
        val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

        val tupPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(tupPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

        elms.zipWithIndex.foreach {
          case (payload, i) =>
            val slotPtr = freshTmp(Type.Ptr)
            fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, tupPtr, Value.IntConst(i.toLong, Type.I64)))
            fb.current.emitStore(payload, slotPtr)
        }

        tupPtr

      case AtomicOp.Index(idx) =>
        val tuplePtr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val tuplePtr = castValue(tuplePtr0, Type.Ptr, fb)

        val slotPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, tuplePtr, Value.IntConst(idx.toLong, Type.I64)))

        val payload = freshTmp(Type.I64)
        fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
        unboxFromI64(payload, resultTpe, fb)

      case AtomicOp.RecordSelect(label) =>
        val recordTpe = argTpes.headOption.getOrElse(SimpleType.RecordEmpty)
        val recordPtr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val recordPtr = castValue(recordPtr0, Type.Ptr, fb)

        val fields = recordFields(recordTpe)
        val idx = fields.indexWhere(_._1 == label.name)
        if (idx < 0) {
          fb.current.emitTrap()
          Value.Undef(llvmTypeOf(resultTpe))
        } else {
          val slotPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, recordPtr, Value.IntConst(idx.toLong, Type.I64)))

          val payload = freshTmp(Type.I64)
          fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
          unboxFromI64(payload, resultTpe, fb)
        }

      case AtomicOp.RecordExtend(label) =>
        val v0 = args.headOption.getOrElse(Value.Undef(Type.I64))
        val vTpe = argTpes.headOption.getOrElse(SimpleType.Object)
        val rest0 = args.drop(1).headOption.getOrElse(Value.Undef(Type.Ptr))
        val restPtr = castValue(rest0, Type.Ptr, fb)
        val restTpe = argTpes.drop(1).headOption.getOrElse(SimpleType.RecordEmpty)

        val resultFields = recordFields(resultTpe)
        val restFields = recordFields(restTpe)
        val restIndex = restFields.zipWithIndex.map { case ((l, _), i) => l -> i }.toMap

        val slots = resultFields.length.toLong
        val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

        val recPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(recPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

        val vPayload = boxToI64(v0, vTpe, fb)

        resultFields.zipWithIndex.foreach {
          case ((fldLabel, _), i) =>
            val slotPtr = freshTmp(Type.Ptr)
            fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, recPtr, Value.IntConst(i.toLong, Type.I64)))
            if (fldLabel == label.name) {
              fb.current.emitStore(vPayload, slotPtr)
            } else {
              restIndex.get(fldLabel) match {
                case None =>
                  fb.current.emitTrap()
                case Some(oldIdx) =>
                  val oldSlotPtr = freshTmp(Type.Ptr)
                  fb.current.emitAssign(oldSlotPtr, Op.Gep(Type.I64, restPtr, Value.IntConst(oldIdx.toLong, Type.I64)))
                  val payload = freshTmp(Type.I64)
                  fb.current.emitAssign(payload, Op.Load(Type.I64, oldSlotPtr))
                  fb.current.emitStore(payload, slotPtr)
              }
            }
        }

        recPtr

      case AtomicOp.RecordRestrict(label) =>
        val recordTpe = argTpes.headOption.getOrElse(SimpleType.RecordEmpty)
        val recordPtr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val recordPtr = castValue(recordPtr0, Type.Ptr, fb)

        val oldFields = recordFields(recordTpe)
        val newFields = recordFields(resultTpe)

        if (newFields.isEmpty) {
          Value.Null(Type.Ptr)
        } else {
          val oldIndex = oldFields.zipWithIndex.map { case ((l, _), i) => l -> i }.toMap
          val slots = newFields.length.toLong
          val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

          val recPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(recPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

          newFields.zipWithIndex.foreach {
            case ((fldLabel, _), i) =>
              val slotPtr = freshTmp(Type.Ptr)
              fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, recPtr, Value.IntConst(i.toLong, Type.I64)))
              oldIndex.get(fldLabel) match {
                case None =>
                  fb.current.emitTrap()
                case Some(oldIdx) =>
                  val oldSlotPtr = freshTmp(Type.Ptr)
                  fb.current.emitAssign(oldSlotPtr, Op.Gep(Type.I64, recordPtr, Value.IntConst(oldIdx.toLong, Type.I64)))
                  val payload = freshTmp(Type.I64)
                  fb.current.emitAssign(payload, Op.Load(Type.I64, oldSlotPtr))
                  fb.current.emitStore(payload, slotPtr)
              }
          }

          recPtr
        }

      case AtomicOp.Tag(sym) =>
        val tagId = caseTagIds.get(sym)
        val payloads = args.zip(argTpes).map {
          case (v, tpe) => boxToI64(v, tpe, fb)
        }

        tagId match {
          case None =>
            fb.current.emitTrap()
            Value.Undef(Type.Ptr)

          case Some(id) =>
            val slots = 1L + payloads.length.toLong
            val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

            val objPtr = freshTmp(Type.Ptr)
            fb.current.emitAssign(objPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

            val tagPtr = freshTmp(Type.Ptr)
            fb.current.emitAssign(tagPtr, Op.Gep(Type.I64, objPtr, Value.IntConst(0L, Type.I64)))
            fb.current.emitStore(Value.IntConst(id, Type.I64), tagPtr)

            payloads.zipWithIndex.foreach {
              case (payload, i) =>
                val slotPtr = freshTmp(Type.Ptr)
                fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, objPtr, Value.IntConst((i + 1).toLong, Type.I64)))
                fb.current.emitStore(payload, slotPtr)
            }

            objPtr
        }

      case AtomicOp.Is(sym) =>
        val tagId = caseTagIds.get(sym)
        val objPtr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val objPtr = castValue(objPtr0, Type.Ptr, fb)

        tagId match {
          case None =>
            fb.current.emitTrap()
            Value.Undef(Type.I1)

          case Some(id) =>
            val tagPtr = freshTmp(Type.Ptr)
            fb.current.emitAssign(tagPtr, Op.Gep(Type.I64, objPtr, Value.IntConst(0L, Type.I64)))

            val tagVal = freshTmp(Type.I64)
            fb.current.emitAssign(tagVal, Op.Load(Type.I64, tagPtr))

            val cmp = freshTmp(Type.I1)
            fb.current.emitAssign(cmp, Op.ICmp("eq", tagVal, Value.IntConst(id, Type.I64)))
            cmp
        }

      case AtomicOp.Untag(sym, idx) =>
        val tagId = caseTagIds.get(sym)
        val objPtr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val objPtr = castValue(objPtr0, Type.Ptr, fb)

        tagId match {
          case None =>
            fb.current.emitTrap()
            Value.Undef(llvmTypeOf(resultTpe))

          case Some(id) =>
            // Defensive: trap if the tag doesn't match.
            val tagPtr = freshTmp(Type.Ptr)
            fb.current.emitAssign(tagPtr, Op.Gep(Type.I64, objPtr, Value.IntConst(0L, Type.I64)))

            val tagVal = freshTmp(Type.I64)
            fb.current.emitAssign(tagVal, Op.Load(Type.I64, tagPtr))

            val ok = freshTmp(Type.I1)
            fb.current.emitAssign(ok, Op.ICmp("eq", tagVal, Value.IntConst(id, Type.I64)))

            val thenLabel = freshLabel("untag_ok")
            val elseLabel = freshLabel("untag_bad")
            val endLabel = freshLabel("untag_end")

            fb.current.setTerminator(Terminator.CondBr(ok, thenLabel, elseLabel))

            val slot = (idx + 1).toLong
            val joinTpe = llvmTypeOf(resultTpe)
            val incomings = mutable.ArrayBuffer.empty[(Value, String)]

            // Ok path.
            val okBlock = fb.newBlock(thenLabel)
            fb.setCurrent(okBlock)
            val slotPtr = freshTmp(Type.Ptr)
            fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, objPtr, Value.IntConst(slot, Type.I64)))
            val payload = freshTmp(Type.I64)
            fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
            val valueOk = unboxFromI64(payload, resultTpe, fb)
            if (!fb.current.isTerminated) {
              val v = coerceValue(valueOk, joinTpe, fb)
              fb.current.setTerminator(Terminator.Br(endLabel))
              incomings.addOne((v, thenLabel))
            }

            // Bad path.
            val badBlock = fb.newBlock(elseLabel)
            fb.setCurrent(badBlock)
            fb.current.emitTrap()
            fb.current.setTerminator(Terminator.Unreachable)

            // Join.
            val joinBlock = fb.newBlock(endLabel)
            fb.setCurrent(joinBlock)
            if (incomings.isEmpty) Value.Undef(joinTpe)
            else {
              val phiDest = freshTmp(joinTpe)
              joinBlock.emitPhi(phiDest, incomings.toList)
              phiDest
            }
        }

      case AtomicOp.ExtTag(label) =>
        val tagId = extTagId(label)
        val payloads = args.zip(argTpes).map {
          case (v, tpe) => boxToI64(v, tpe, fb)
        }

        val slots = 1L + payloads.length.toLong
        val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

        val objPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(objPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

        val tagPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(tagPtr, Op.Gep(Type.I64, objPtr, Value.IntConst(0L, Type.I64)))
        fb.current.emitStore(Value.IntConst(tagId, Type.I64), tagPtr)

        payloads.zipWithIndex.foreach {
          case (payload, i) =>
            val slotPtr = freshTmp(Type.Ptr)
            fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, objPtr, Value.IntConst((i + 1).toLong, Type.I64)))
            fb.current.emitStore(payload, slotPtr)
        }

        objPtr

      case AtomicOp.ExtIs(label) =>
        val tagId = extTagId(label)
        val objPtr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val objPtr = castValue(objPtr0, Type.Ptr, fb)

        val tagPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(tagPtr, Op.Gep(Type.I64, objPtr, Value.IntConst(0L, Type.I64)))

        val tagVal = freshTmp(Type.I64)
        fb.current.emitAssign(tagVal, Op.Load(Type.I64, tagPtr))

        val cmp = freshTmp(Type.I1)
        fb.current.emitAssign(cmp, Op.ICmp("eq", tagVal, Value.IntConst(tagId, Type.I64)))
        cmp

      case AtomicOp.ExtUntag(label, idx) =>
        val tagId = extTagId(label)
        val objPtr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val objPtr = castValue(objPtr0, Type.Ptr, fb)

        val tagPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(tagPtr, Op.Gep(Type.I64, objPtr, Value.IntConst(0L, Type.I64)))

        val tagVal = freshTmp(Type.I64)
        fb.current.emitAssign(tagVal, Op.Load(Type.I64, tagPtr))

        val ok = freshTmp(Type.I1)
        fb.current.emitAssign(ok, Op.ICmp("eq", tagVal, Value.IntConst(tagId, Type.I64)))

        val okLabel = freshLabel("extuntag_ok")
        val badLabel = freshLabel("extuntag_bad")
        fb.current.setTerminator(Terminator.CondBr(ok, okLabel, badLabel))

        val badBlock = fb.newBlock(badLabel)
        fb.setCurrent(badBlock)
        fb.current.emitTrap()
        fb.current.setTerminator(Terminator.Unreachable)

        val okBlock = fb.newBlock(okLabel)
        fb.setCurrent(okBlock)

        val slot = (idx + 1).toLong
        val slotPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, objPtr, Value.IntConst(slot, Type.I64)))
        val payload = freshTmp(Type.I64)
        fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
        unboxFromI64(payload, resultTpe, fb)

      case AtomicOp.ArrayLit =>
        val elms = args.zip(argTpes).map {
          case (v, tpe) => boxToI64(v, tpe, fb)
        }

        val len = elms.length.toLong
        val slots = 1L + len
        val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

        val arrPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(arrPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

        val lenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, arrPtr, Value.IntConst(0L, Type.I64)))
        fb.current.emitStore(Value.IntConst(len, Type.I64), lenPtr)

        elms.zipWithIndex.foreach {
          case (payload, i) =>
            val slotPtr = freshTmp(Type.Ptr)
            fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, arrPtr, Value.IntConst((i + 1).toLong, Type.I64)))
            fb.current.emitStore(payload, slotPtr)
        }

        arrPtr

      case AtomicOp.ArrayNew =>
        val default0 = args.headOption.getOrElse(Value.Undef(Type.I64))
        val len0 = args.drop(1).headOption.getOrElse(Value.Undef(Type.I32))
        val defaultTpe = argTpes.headOption.getOrElse(SimpleType.Object)

        val lenI64 = castValue(len0, Type.I64, fb)
        val negative = freshTmp(Type.I1)
        fb.current.emitAssign(negative, Op.ICmp("slt", lenI64, Value.IntConst(0L, Type.I64)))

        val okLabel = freshLabel("arr_ok")
        val badLabel = freshLabel("arr_bad")
        val contLabel = freshLabel("arr_cont")

        fb.current.setTerminator(Terminator.CondBr(negative, badLabel, okLabel))

        // Negative length.
        val badBlock = fb.newBlock(badLabel)
        fb.setCurrent(badBlock)
        fb.current.emitTrap()
        fb.current.setTerminator(Terminator.Unreachable)

        // Ok.
        val okBlock = fb.newBlock(okLabel)
        fb.setCurrent(okBlock)

        val slots = freshTmp(Type.I64)
        fb.current.emitAssign(slots, Op.Bin("add", Type.I64, lenI64, Value.IntConst(1L, Type.I64)))

        val sizeBytes = freshTmp(Type.I64)
        fb.current.emitAssign(sizeBytes, Op.Bin("mul", Type.I64, slots, Value.IntConst(8L, Type.I64)))

        val arrPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(arrPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

        val lenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, arrPtr, Value.IntConst(0L, Type.I64)))
        fb.current.emitStore(lenI64, lenPtr)

        val defaultPayload = boxToI64(default0, defaultTpe, fb)

        // Initialize elements with the default value.
        val iPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(iPtr, Op.Alloca(Type.I64))
        fb.current.emitStore(Value.IntConst(0L, Type.I64), iPtr)

        val loopLabel = freshLabel("arr_loop")
        val bodyLabel = freshLabel("arr_body")
        val endLabel = freshLabel("arr_end")

        fb.current.setTerminator(Terminator.Br(loopLabel))

        val loopBlock = fb.newBlock(loopLabel)
        fb.setCurrent(loopBlock)
        val iVal = freshTmp(Type.I64)
        fb.current.emitAssign(iVal, Op.Load(Type.I64, iPtr))
        val cond = freshTmp(Type.I1)
        fb.current.emitAssign(cond, Op.ICmp("slt", iVal, lenI64))
        fb.current.setTerminator(Terminator.CondBr(cond, bodyLabel, endLabel))

        val bodyBlock = fb.newBlock(bodyLabel)
        fb.setCurrent(bodyBlock)
        val slotIdx = freshTmp(Type.I64)
        fb.current.emitAssign(slotIdx, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
        val slotPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, arrPtr, slotIdx))
        fb.current.emitStore(defaultPayload, slotPtr)
        val iNext = freshTmp(Type.I64)
        fb.current.emitAssign(iNext, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
        fb.current.emitStore(iNext, iPtr)
        fb.current.setTerminator(Terminator.Br(loopLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        fb.current.setTerminator(Terminator.Br(contLabel))

        val contBlock = fb.newBlock(contLabel)
        fb.setCurrent(contBlock)
        arrPtr

      case AtomicOp.ArrayLoad =>
        val arr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val idx0 = args.drop(1).headOption.getOrElse(Value.Undef(Type.I32))
        val arrPtr = castValue(arr0, Type.Ptr, fb)
        val idxI64 = castValue(idx0, Type.I64, fb)

        val lenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, arrPtr, Value.IntConst(0L, Type.I64)))
        val lenI64 = freshTmp(Type.I64)
        fb.current.emitAssign(lenI64, Op.Load(Type.I64, lenPtr))

        val neg = freshTmp(Type.I1)
        fb.current.emitAssign(neg, Op.ICmp("slt", idxI64, Value.IntConst(0L, Type.I64)))
        val ge = freshTmp(Type.I1)
        fb.current.emitAssign(ge, Op.ICmp("sge", idxI64, lenI64))
        val oob = freshTmp(Type.I1)
        fb.current.emitAssign(oob, Op.Bin("or", Type.I1, neg, ge))

        val okLabel = freshLabel("aload_ok")
        val badLabel = freshLabel("aload_bad")
        val endLabel = freshLabel("aload_end")

        fb.current.setTerminator(Terminator.CondBr(oob, badLabel, okLabel))

        val badBlock = fb.newBlock(badLabel)
        fb.setCurrent(badBlock)
        fb.current.emitTrap()
        fb.current.setTerminator(Terminator.Unreachable)

        val okBlock = fb.newBlock(okLabel)
        fb.setCurrent(okBlock)
        val slotIdx = freshTmp(Type.I64)
        fb.current.emitAssign(slotIdx, Op.Bin("add", Type.I64, idxI64, Value.IntConst(1L, Type.I64)))
        val slotPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, arrPtr, slotIdx))
        val payload = freshTmp(Type.I64)
        fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
        val valueOk = unboxFromI64(payload, resultTpe, fb)
        if (!fb.current.isTerminated) {
          fb.current.setTerminator(Terminator.Br(endLabel))
        }

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        valueOk

      case AtomicOp.ArrayStore =>
        val arr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val idx0 = args.drop(1).headOption.getOrElse(Value.Undef(Type.I32))
        val v0 = args.drop(2).headOption.getOrElse(Value.Undef(Type.I64))
        val vTpe = argTpes.drop(2).headOption.getOrElse(SimpleType.Object)

        val arrPtr = castValue(arr0, Type.Ptr, fb)
        val idxI64 = castValue(idx0, Type.I64, fb)

        val lenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, arrPtr, Value.IntConst(0L, Type.I64)))
        val lenI64 = freshTmp(Type.I64)
        fb.current.emitAssign(lenI64, Op.Load(Type.I64, lenPtr))

        val neg = freshTmp(Type.I1)
        fb.current.emitAssign(neg, Op.ICmp("slt", idxI64, Value.IntConst(0L, Type.I64)))
        val ge = freshTmp(Type.I1)
        fb.current.emitAssign(ge, Op.ICmp("sge", idxI64, lenI64))
        val oob = freshTmp(Type.I1)
        fb.current.emitAssign(oob, Op.Bin("or", Type.I1, neg, ge))

        val okLabel = freshLabel("astore_ok")
        val badLabel = freshLabel("astore_bad")
        val endLabel = freshLabel("astore_end")

        fb.current.setTerminator(Terminator.CondBr(oob, badLabel, okLabel))

        val badBlock = fb.newBlock(badLabel)
        fb.setCurrent(badBlock)
        fb.current.emitTrap()
        fb.current.setTerminator(Terminator.Unreachable)

        val okBlock = fb.newBlock(okLabel)
        fb.setCurrent(okBlock)
        val slotIdx = freshTmp(Type.I64)
        fb.current.emitAssign(slotIdx, Op.Bin("add", Type.I64, idxI64, Value.IntConst(1L, Type.I64)))
        val slotPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, arrPtr, slotIdx))
        val payload = boxToI64(v0, vTpe, fb)
        fb.current.emitStore(payload, slotPtr)
        fb.current.setTerminator(Terminator.Br(endLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        Value.IntConst(0L, Type.I64)

      case AtomicOp.ArrayLength =>
        val arr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val arrPtr = castValue(arr0, Type.Ptr, fb)

        val lenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, arrPtr, Value.IntConst(0L, Type.I64)))

        val lenI64 = freshTmp(Type.I64)
        fb.current.emitAssign(lenI64, Op.Load(Type.I64, lenPtr))

        val lenI32 = freshTmp(Type.I32)
        fb.current.emitAssign(lenI32, Op.Cast("trunc", Type.I32, lenI64))
        lenI32

      case AtomicOp.StructNew(sym, mutability, _) =>
        val struct = root.structs(sym)
        val fieldCount = struct.fields.length
        val (fieldArgs, fieldTpes) = mutability match {
          case ca.uwaterloo.flix.language.ast.shared.Mutability.Immutable =>
            (args, argTpes)
          case ca.uwaterloo.flix.language.ast.shared.Mutability.Mutable =>
            // Region is the first argument; ignored for bring-up.
            (args.drop(1), argTpes.drop(1))
        }

        if (fieldArgs.length != fieldCount) {
          fb.current.emitTrap()
          Value.Undef(Type.Ptr)
        } else {
          val payloads = fieldArgs.zip(fieldTpes).map {
            case (v, tpe) => boxToI64(v, tpe, fb)
          }

          val slots = payloads.length.toLong
          val sizeBytes = Value.IntConst(slots * 8L, Type.I64)

          val objPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(objPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

          payloads.zipWithIndex.foreach {
            case (payload, i) =>
              val slotPtr = freshTmp(Type.Ptr)
              fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, objPtr, Value.IntConst(i.toLong, Type.I64)))
              fb.current.emitStore(payload, slotPtr)
          }

          objPtr
        }

      case AtomicOp.StructGet(field) =>
        val structPtr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val structPtr = castValue(structPtr0, Type.Ptr, fb)

        val struct = root.structs(field.structSym)
        val idx = struct.fields.indexWhere(_.sym == field)
        if (idx < 0) {
          fb.current.emitTrap()
          Value.Undef(llvmTypeOf(resultTpe))
        } else {
          val slotPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, structPtr, Value.IntConst(idx.toLong, Type.I64)))
          val payload = freshTmp(Type.I64)
          fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
          unboxFromI64(payload, resultTpe, fb)
        }

      case AtomicOp.StructPut(field) =>
        val structPtr0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val v0 = args.drop(1).headOption.getOrElse(Value.Undef(Type.I64))
        val vTpe = argTpes.drop(1).headOption.getOrElse(SimpleType.Object)

        val structPtr = castValue(structPtr0, Type.Ptr, fb)

        val struct = root.structs(field.structSym)
        val idx = struct.fields.indexWhere(_.sym == field)
        if (idx < 0) {
          fb.current.emitTrap()
        } else {
          val slotPtr = freshTmp(Type.Ptr)
          fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, structPtr, Value.IntConst(idx.toLong, Type.I64)))
          val payload = boxToI64(v0, vTpe, fb)
          fb.current.emitStore(payload, slotPtr)
        }
        Value.IntConst(0L, Type.I64)

      case AtomicOp.Lazy =>
        val exp0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val expTpe = argTpes.headOption.getOrElse(SimpleType.Object)

        val expPayload = boxToI64(exp0, expTpe, fb)

        // Layout: [0] = exp payload (i64), [1] = value payload (i64, valid iff exp == 0).
        val sizeBytes = Value.IntConst(16L, Type.I64)
        val lazyPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lazyPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

        val slot0Ptr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slot0Ptr, Op.Gep(Type.I64, lazyPtr, Value.IntConst(0L, Type.I64)))
        fb.current.emitStore(expPayload, slot0Ptr)

        val slot1Ptr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slot1Ptr, Op.Gep(Type.I64, lazyPtr, Value.IntConst(1L, Type.I64)))
        fb.current.emitStore(Value.IntConst(0L, Type.I64), slot1Ptr)

        lazyPtr

      case AtomicOp.Force =>
        val lazy0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val lazyPtr = castValue(lazy0, Type.Ptr, fb)

        val slot0Ptr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slot0Ptr, Op.Gep(Type.I64, lazyPtr, Value.IntConst(0L, Type.I64)))
        val expPayload = freshTmp(Type.I64)
        fb.current.emitAssign(expPayload, Op.Load(Type.I64, slot0Ptr))

        val isForced = freshTmp(Type.I1)
        fb.current.emitAssign(isForced, Op.ICmp("eq", expPayload, Value.IntConst(0L, Type.I64)))

        val forcedLabel = freshLabel("force_done")
        val computeLabel = freshLabel("force_compute")
        val endLabel = freshLabel("force_end")

        fb.current.setTerminator(Terminator.CondBr(isForced, forcedLabel, computeLabel))

        val joinTpe = llvmTypeOf(resultTpe)
        val incomings = mutable.ArrayBuffer.empty[(Value, String)]

        // Already forced: load cached value.
        val forcedBlock = fb.newBlock(forcedLabel)
        fb.setCurrent(forcedBlock)
        val slot1Ptr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slot1Ptr, Op.Gep(Type.I64, lazyPtr, Value.IntConst(1L, Type.I64)))
        val cachedPayload = freshTmp(Type.I64)
        fb.current.emitAssign(cachedPayload, Op.Load(Type.I64, slot1Ptr))
        val cachedValue = unboxFromI64(cachedPayload, resultTpe, fb)
        if (!fb.current.isTerminated) {
          val v = coerceValue(cachedValue, joinTpe, fb)
          val predLabel = fb.current.label
          fb.current.setTerminator(Terminator.Br(endLabel))
          incomings.addOne((v, predLabel))
        }

        // Not yet forced: invoke thunk and cache.
        val computeBlock = fb.newBlock(computeLabel)
        fb.setCurrent(computeBlock)

        val cloPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(cloPtr, Op.Cast("inttoptr", Type.Ptr, expPayload))

        // Load invoke pointer from closure slot 0.
        val cloSlot0Ptr = freshTmp(Type.Ptr)
        fb.current.emitAssign(cloSlot0Ptr, Op.Gep(Type.I64, cloPtr, Value.IntConst(0L, Type.I64)))
        val codeI64 = freshTmp(Type.I64)
        fb.current.emitAssign(codeI64, Op.Load(Type.I64, cloSlot0Ptr))
        val codePtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(codePtr, Op.Cast("inttoptr", Type.Ptr, codeI64))

        val callTmp = freshTmp(flixResultType)
        fb.current.emitAssign(callTmp, Op.CallIndirect(flixResultType, codePtr, List(ctxPtr, cloPtr, Value.IntConst(0L, Type.I64))))
        val payloadTmp = unwindThunkToValuePayload(callTmp, ctxPtr, fb)

        // Cache the value and mark as forced.
        val slot1Ptr2 = freshTmp(Type.Ptr)
        fb.current.emitAssign(slot1Ptr2, Op.Gep(Type.I64, lazyPtr, Value.IntConst(1L, Type.I64)))
        fb.current.emitStore(payloadTmp, slot1Ptr2)

        fb.current.emitStore(Value.IntConst(0L, Type.I64), slot0Ptr)

        val computedValue = unboxFromI64(payloadTmp, resultTpe, fb)
        if (!fb.current.isTerminated) {
          val v = coerceValue(computedValue, joinTpe, fb)
          val predLabel = fb.current.label
          fb.current.setTerminator(Terminator.Br(endLabel))
          incomings.addOne((v, predLabel))
        }

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        if (incomings.isEmpty) Value.Undef(joinTpe)
        else {
          val phiDest = freshTmp(joinTpe)
          endBlock.emitPhi(phiDest, incomings.toList)
          phiDest
        }

      case AtomicOp.Spawn =>
        val clo0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val rc0 = args.drop(1).headOption.getOrElse(Value.Null(Type.Ptr))

        val cloPtr = castValue(clo0, Type.Ptr, fb)
        val rcPtr = castValue(rc0, Type.Ptr, fb)

        // Bring-up: only support spawning in the Static region (represented as null).
        val isStatic = freshTmp(Type.I1)
        fb.current.emitAssign(isStatic, Op.ICmp("eq", rcPtr, Value.Null(Type.Ptr)))

        val okLabel = freshLabel("spawn_ok")
        val badLabel = freshLabel("spawn_bad")
        val endLabel = freshLabel("spawn_end")
        fb.current.setTerminator(Terminator.CondBr(isStatic, okLabel, badLabel))

        val okBlock = fb.newBlock(okLabel)
        fb.setCurrent(okBlock)
        val callTmp = freshTmp(Type.I64)
        fb.current.emitAssign(callTmp, Op.Call(Type.I64, "flix_spawn", List(ctxPtr, cloPtr)))
        fb.current.setTerminator(Terminator.Br(endLabel))

        val badBlock = fb.newBlock(badLabel)
        fb.setCurrent(badBlock)
        fb.current.emitTrap()
        fb.current.setTerminator(Terminator.Unreachable)

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        Value.IntConst(0L, Type.I64)

      case AtomicOp.ChannelNew =>
        val cap0 = args.headOption.getOrElse(Value.Undef(Type.I32))
        val capI32 = castValue(cap0, Type.I32, fb)

        val chanPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(chanPtr, Op.Call(Type.Ptr, "flix_channel_new", List(capI32)))
        chanPtr

      case AtomicOp.ChannelPut =>
        val chan0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val v0 = args.drop(1).headOption.getOrElse(Value.Undef(Type.I64))
        val vTpe = argTpes.drop(1).headOption.getOrElse(SimpleType.Object)

        val chanPtr = castValue(chan0, Type.Ptr, fb)
        val payload = boxToI64(v0, vTpe, fb)

        val callTmp = freshTmp(Type.I64)
        fb.current.emitAssign(callTmp, Op.Call(Type.I64, "flix_channel_put", List(chanPtr, payload)))
        callTmp

      case AtomicOp.ChannelGet =>
        val chan0 = args.headOption.getOrElse(Value.Undef(Type.Ptr))
        val chanPtr = castValue(chan0, Type.Ptr, fb)

        val payload = freshTmp(Type.I64)
        fb.current.emitAssign(payload, Op.Call(Type.I64, "flix_channel_get", List(chanPtr)))
        unboxFromI64(payload, resultTpe, fb)

      case AtomicOp.HoleError(_) | AtomicOp.MatchError | AtomicOp.CastError(_, _) | AtomicOp.Throw =>
        fb.current.emitTrap()
        fb.current.setTerminator(Terminator.Unreachable)
        Value.Undef(llvmTypeOf(resultTpe))

      case AtomicOp.Unary(SemanticOp.ExnOp.KindId) =>
        val tpe = argTpes.headOption.getOrElse(SimpleType.AnyType)
        Value.IntConst(ExnKindId.of(tpe).toLong, Type.I32)

      case AtomicOp.Unary(sop) =>
        emitUnary(sop, args.headOption.getOrElse(Value.Undef(llvmTypeOf(resultTpe))), fb)

      case AtomicOp.Binary(sop) =>
        val a = args.headOption.getOrElse(Value.Undef(Type.I64))
        val b = args.drop(1).headOption.getOrElse(Value.Undef(Type.I64))
        emitBinary(sop, a, b, fb)

      case AtomicOp.Box =>
        val v = args.headOption.getOrElse(Value.Undef(Type.I64))
        val tpe = argTpes.headOption.getOrElse(SimpleType.Object)
        boxToI64(v, tpe, fb)

      case AtomicOp.Unbox =>
        val payload = args.headOption.getOrElse(Value.Undef(Type.I64))
        val i64Payload = payload.tpe match {
          case Type.I64 => payload
          case Type.Ptr =>
            val tmp = freshTmp(Type.I64)
            fb.current.emitAssign(tmp, Op.Cast("ptrtoint", Type.I64, payload))
            tmp
          case t if isIntType(t) =>
            val tmp = freshTmp(Type.I64)
            fb.current.emitAssign(tmp, Op.Cast("sext", Type.I64, payload))
            tmp
          case _ =>
            fb.current.emitTrap()
            Value.Undef(Type.I64)
        }
        unboxFromI64(i64Payload, resultTpe, fb)

      case AtomicOp.Cast =>
        val v = args.headOption.getOrElse(Value.Undef(llvmTypeOf(resultTpe)))
        val expected = llvmTypeOf(resultTpe)
        castValue(v, expected, fb)

      case _ =>
        fb.current.emitTrap()
        Value.Undef(llvmTypeOf(resultTpe))
    }

    private def emitUnary(op: UnaryOp, x: Value, fb: FunBuilder): Value = op match {
      case SemanticOp.BoolOp.Not =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.Bin("xor", Type.I1, x, Value.IntConst(1L, Type.I1)))
        tmp

      case SemanticOp.CharOp.ToUpperCase =>
        val geA = freshTmp(Type.I1)
        fb.current.emitAssign(geA, Op.ICmp("uge", x, Value.IntConst(97L, Type.I32))) // 'a'
        val leZ = freshTmp(Type.I1)
        fb.current.emitAssign(leZ, Op.ICmp("ule", x, Value.IntConst(122L, Type.I32))) // 'z'
        val isLower = freshTmp(Type.I1)
        fb.current.emitAssign(isLower, Op.Bin("and", Type.I1, geA, leZ))

        val yesLabel = freshLabel("ctoupper_yes")
        val noLabel = freshLabel("ctoupper_no")
        val endLabel = freshLabel("ctoupper_end")
        fb.current.setTerminator(Terminator.CondBr(isLower, yesLabel, noLabel))

        val incomings = mutable.ArrayBuffer.empty[(Value, String)]

        val yesBlock = fb.newBlock(yesLabel)
        fb.setCurrent(yesBlock)
        val upper = freshTmp(Type.I32)
        fb.current.emitAssign(upper, Op.Bin("sub", Type.I32, x, Value.IntConst(32L, Type.I32)))
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((upper, yesLabel))

        val noBlock = fb.newBlock(noLabel)
        fb.setCurrent(noBlock)
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((x, noLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        val phi = freshTmp(Type.I32)
        endBlock.emitPhi(phi, incomings.toList)
        phi

      case SemanticOp.CharOp.ToLowerCase =>
        val geA = freshTmp(Type.I1)
        fb.current.emitAssign(geA, Op.ICmp("uge", x, Value.IntConst(65L, Type.I32))) // 'A'
        val leZ = freshTmp(Type.I1)
        fb.current.emitAssign(leZ, Op.ICmp("ule", x, Value.IntConst(90L, Type.I32))) // 'Z'
        val isUpper = freshTmp(Type.I1)
        fb.current.emitAssign(isUpper, Op.Bin("and", Type.I1, geA, leZ))

        val yesLabel = freshLabel("ctolower_yes")
        val noLabel = freshLabel("ctolower_no")
        val endLabel = freshLabel("ctolower_end")
        fb.current.setTerminator(Terminator.CondBr(isUpper, yesLabel, noLabel))

        val incomings = mutable.ArrayBuffer.empty[(Value, String)]

        val yesBlock = fb.newBlock(yesLabel)
        fb.setCurrent(yesBlock)
        val lower = freshTmp(Type.I32)
        fb.current.emitAssign(lower, Op.Bin("add", Type.I32, x, Value.IntConst(32L, Type.I32)))
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((lower, yesLabel))

        val noBlock = fb.newBlock(noLabel)
        fb.setCurrent(noBlock)
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((x, noLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        val phi = freshTmp(Type.I32)
        endBlock.emitPhi(phi, incomings.toList)
        phi

      case SemanticOp.Int8Op.Neg =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Bin("sub", Type.I8, Value.IntConst(0L, Type.I8), x))
        tmp

      case SemanticOp.Int8Op.Not =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Bin("xor", Type.I8, x, Value.IntConst(-1L, Type.I8)))
        tmp

      case SemanticOp.Int16Op.Neg =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Bin("sub", Type.I16, Value.IntConst(0L, Type.I16), x))
        tmp

      case SemanticOp.Int16Op.Not =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Bin("xor", Type.I16, x, Value.IntConst(-1L, Type.I16)))
        tmp

      case SemanticOp.Int32Op.Neg =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Bin("sub", Type.I32, Value.IntConst(0L, Type.I32), x))
        tmp

      case SemanticOp.Int32Op.Not =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Bin("xor", Type.I32, x, Value.IntConst(-1L, Type.I32)))
        tmp

      case SemanticOp.Float32Op.Neg =>
        val bits = freshTmp(Type.I32)
        fb.current.emitAssign(bits, Op.Cast("bitcast", Type.I32, x))

        val flipped = freshTmp(Type.I32)
        fb.current.emitAssign(flipped, Op.Bin("xor", Type.I32, bits, Value.IntConst(Int.MinValue.toLong, Type.I32)))

        val res = freshTmp(Type.Float)
        fb.current.emitAssign(res, Op.Cast("bitcast", Type.Float, flipped))
        res

      case SemanticOp.Int64Op.Neg =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Bin("sub", Type.I64, Value.IntConst(0L, Type.I64), x))
        tmp

      case SemanticOp.Int64Op.Not =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Bin("xor", Type.I64, x, Value.IntConst(-1L, Type.I64)))
        tmp

      case SemanticOp.Float64Op.Neg =>
        val bits = freshTmp(Type.I64)
        fb.current.emitAssign(bits, Op.Cast("bitcast", Type.I64, x))

        val flipped = freshTmp(Type.I64)
        fb.current.emitAssign(flipped, Op.Bin("xor", Type.I64, bits, Value.IntConst(Long.MinValue, Type.I64)))

        val res = freshTmp(Type.Double)
        fb.current.emitAssign(res, Op.Cast("bitcast", Type.Double, flipped))
        res

      case SemanticOp.ConvertOp.Int8ToInt16 =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I16, x))
        tmp

      case SemanticOp.ConvertOp.Int8ToInt32 =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I32, x))
        tmp

      case SemanticOp.ConvertOp.Int8ToInt64 =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I64, x))
        tmp

      case SemanticOp.ConvertOp.Int8ToFloat32 =>
        val tmp = freshTmp(Type.Float)
        fb.current.emitAssign(tmp, Op.Cast("sitofp", Type.Float, x))
        tmp

      case SemanticOp.ConvertOp.Int8ToFloat64 =>
        val tmp = freshTmp(Type.Double)
        fb.current.emitAssign(tmp, Op.Cast("sitofp", Type.Double, x))
        tmp

      case SemanticOp.ConvertOp.Int16ToInt8 =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I8, x))
        tmp

      case SemanticOp.ConvertOp.Int16ToInt32 =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I32, x))
        tmp

      case SemanticOp.ConvertOp.Int16ToInt64 =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I64, x))
        tmp

      case SemanticOp.ConvertOp.Int16ToFloat32 =>
        val tmp = freshTmp(Type.Float)
        fb.current.emitAssign(tmp, Op.Cast("sitofp", Type.Float, x))
        tmp

      case SemanticOp.ConvertOp.Int16ToFloat64 =>
        val tmp = freshTmp(Type.Double)
        fb.current.emitAssign(tmp, Op.Cast("sitofp", Type.Double, x))
        tmp

      case SemanticOp.ConvertOp.Int32ToInt8 =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I8, x))
        tmp

      case SemanticOp.ConvertOp.Int32ToInt16 =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I16, x))
        tmp

      case SemanticOp.ConvertOp.Int32ToInt64 =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I64, x))
        tmp

      case SemanticOp.ConvertOp.Int32ToFloat32 =>
        val tmp = freshTmp(Type.Float)
        fb.current.emitAssign(tmp, Op.Cast("sitofp", Type.Float, x))
        tmp

      case SemanticOp.ConvertOp.Int32ToFloat64 =>
        val tmp = freshTmp(Type.Double)
        fb.current.emitAssign(tmp, Op.Cast("sitofp", Type.Double, x))
        tmp

      case SemanticOp.ConvertOp.Int64ToInt8 =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I8, x))
        tmp

      case SemanticOp.ConvertOp.Int64ToInt16 =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I16, x))
        tmp

      case SemanticOp.ConvertOp.Int64ToInt32 =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I32, x))
        tmp

      case SemanticOp.ConvertOp.Int64ToFloat32 =>
        val tmp = freshTmp(Type.Float)
        fb.current.emitAssign(tmp, Op.Cast("sitofp", Type.Float, x))
        tmp

      case SemanticOp.ConvertOp.Int64ToFloat64 =>
        val tmp = freshTmp(Type.Double)
        fb.current.emitAssign(tmp, Op.Cast("sitofp", Type.Double, x))
        tmp

      case SemanticOp.ConvertOp.Float32ToInt8 =>
        val i32 = fpToInt32Saturating(x, fb)
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I8, i32))
        tmp

      case SemanticOp.ConvertOp.Float32ToInt16 =>
        val i32 = fpToInt32Saturating(x, fb)
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I16, i32))
        tmp

      case SemanticOp.ConvertOp.Float32ToInt32 =>
        fpToInt32Saturating(x, fb)

      case SemanticOp.ConvertOp.Float32ToInt64 =>
        fpToInt64Saturating(x, fb)

      case SemanticOp.ConvertOp.Float32ToFloat64 =>
        val tmp = freshTmp(Type.Double)
        fb.current.emitAssign(tmp, Op.Cast("fpext", Type.Double, x))
        tmp

      case SemanticOp.ConvertOp.Float64ToInt8 =>
        val i32 = fpToInt32Saturating(x, fb)
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I8, i32))
        tmp

      case SemanticOp.ConvertOp.Float64ToInt16 =>
        val i32 = fpToInt32Saturating(x, fb)
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I16, i32))
        tmp

      case SemanticOp.ConvertOp.Float64ToInt32 =>
        fpToInt32Saturating(x, fb)

      case SemanticOp.ConvertOp.Float64ToInt64 =>
        fpToInt64Saturating(x, fb)

      case SemanticOp.ConvertOp.Float64ToFloat32 =>
        val tmp = freshTmp(Type.Float)
        fb.current.emitAssign(tmp, Op.Cast("fptrunc", Type.Float, x))
        tmp

      case SemanticOp.PlatformOp.FileSeparator =>
        emitConstant(Constant.Str(java.io.File.separator), fb)

      case SemanticOp.PlatformOp.PathSeparator =>
        emitConstant(Constant.Str(java.io.File.pathSeparator), fb)

      case SemanticOp.PlatformOp.LineSeparator =>
        emitConstant(Constant.Str(System.lineSeparator()), fb)

      case SemanticOp.ObjectOp.IsNull =>
        val asI64 = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("eq", asI64, Value.IntConst(0L, Type.I64)))
        tmp

      case SemanticOp.RegexOp.FlagCanonEq =>
        Value.IntConst(128L, Type.I32)

      case SemanticOp.RegexOp.FlagCaseInsensitive =>
        Value.IntConst(2L, Type.I32)

      case SemanticOp.RegexOp.FlagComments =>
        Value.IntConst(4L, Type.I32)

      case SemanticOp.RegexOp.FlagDotall =>
        Value.IntConst(32L, Type.I32)

      case SemanticOp.RegexOp.FlagLiteral =>
        Value.IntConst(16L, Type.I32)

      case SemanticOp.RegexOp.FlagMultiline =>
        Value.IntConst(8L, Type.I32)

      case SemanticOp.RegexOp.FlagUnicodeCase =>
        Value.IntConst(64L, Type.I32)

      case SemanticOp.RegexOp.FlagUnicodeCharacterClass =>
        Value.IntConst(256L, Type.I32)

      case SemanticOp.RegexOp.FlagUnixLines =>
        Value.IntConst(1L, Type.I32)

      case SemanticOp.RegexOp.Compile =>
        val pat = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_compile", List(pat)))
        tmp

      case SemanticOp.RegexOp.CompileWithFlags =>
        val flags = loadTupleElement(x, 0L, SimpleType.Int32, fb)
        val pat = loadTupleElement(x, 1L, SimpleType.String, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_compile_with_flags", List(flags, pat)))
        tmp

      case SemanticOp.RegexOp.TryCompile =>
        val pat = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_try_compile", List(pat)))
        tmp

      case SemanticOp.RegexOp.TryCompileWithFlags =>
        val flags = loadTupleElement(x, 0L, SimpleType.Int32, fb)
        val pat = loadTupleElement(x, 1L, SimpleType.String, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_try_compile_with_flags", List(flags, pat)))
        tmp

      case SemanticOp.RegexOp.Quote =>
        val in = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_quote", List(in)))
        tmp

      case SemanticOp.RegexOp.Pattern =>
        val rgx = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_pattern", List(rgx)))
        tmp

      case SemanticOp.RegexOp.Flags =>
        val rgx = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Call(Type.I32, "flix_regex_flags", List(rgx)))
        tmp

      case SemanticOp.RegexOp.NewMatcher =>
        // Argument: (rc, rgx, input). rc ignored for bring-up.
        val rgx = loadTupleElement(x, 1L, SimpleType.Regex, fb)
        val in = loadTupleElement(x, 2L, SimpleType.String, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_new_matcher", List(rgx, in)))
        tmp

      case SemanticOp.RegexOp.MatcherMatches =>
        // Argument: (rc, matcher). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.Call(Type.I1, "flix_regex_matcher_matches", List(m)))
        tmp

      case SemanticOp.RegexOp.MatcherFind =>
        // Argument: (rc, matcher). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.Call(Type.I1, "flix_regex_matcher_find", List(m)))
        tmp

      case SemanticOp.RegexOp.MatcherFindFrom =>
        // Argument: (rc, matcher, pos). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val pos = loadTupleElement(x, 2L, SimpleType.Int32, fb)
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.Call(Type.I1, "flix_regex_matcher_find_from", List(m, pos)))
        tmp

      case SemanticOp.RegexOp.MatcherLookingAt =>
        // Argument: (rc, matcher). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.Call(Type.I1, "flix_regex_matcher_looking_at", List(m)))
        tmp

      case SemanticOp.RegexOp.MatcherReplaceAll =>
        // Argument: (rc, matcher, replacement). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val repl = loadTupleElement(x, 2L, SimpleType.String, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_matcher_replace_all", List(m, repl)))
        tmp

      case SemanticOp.RegexOp.MatcherReplaceFirst =>
        // Argument: (rc, matcher, replacement). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val repl = loadTupleElement(x, 2L, SimpleType.String, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_matcher_replace_first", List(m, repl)))
        tmp

      case SemanticOp.RegexOp.MatcherSetBounds =>
        // Argument: (rc, matcher, start, end). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val start = loadTupleElement(x, 2L, SimpleType.Int32, fb)
        val end = loadTupleElement(x, 3L, SimpleType.Int32, fb)
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Call(Type.I64, "flix_regex_matcher_set_bounds", List(m, start, end)))
        tmp

      case SemanticOp.RegexOp.MatcherStart =>
        // Argument: (rc, matcher). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Call(Type.I32, "flix_regex_matcher_start", List(m)))
        tmp

      case SemanticOp.RegexOp.MatcherEnd =>
        // Argument: (rc, matcher). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Call(Type.I32, "flix_regex_matcher_end", List(m)))
        tmp

      case SemanticOp.RegexOp.MatcherGroup =>
        // Argument: (rc, matcher, idx). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val idx = loadTupleElement(x, 2L, SimpleType.Int32, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_matcher_group", List(m, idx)))
        tmp

      case SemanticOp.RegexOp.MatcherGroupCount =>
        // Argument: (rc, matcher). rc ignored for bring-up.
        val m = loadTupleElement(x, 1L, SimpleType.RegexMatcher, fb)
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Call(Type.I32, "flix_regex_matcher_group_count", List(m)))
        tmp

      case SemanticOp.RegexOp.Split =>
        // Argument: (rc, rgx, input). rc ignored for bring-up.
        val rgx = loadTupleElement(x, 1L, SimpleType.Regex, fb)
        val in = loadTupleElement(x, 2L, SimpleType.String, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_regex_split", List(rgx, in)))
        tmp

      case SemanticOp.ToStringOp.CharToString =>
        emitCharToString(x, fb)

      case SemanticOp.ToStringOp.Int8ToString =>
        emitIntToStringNoMin(castValue(x, Type.I64, fb), fb)

      case SemanticOp.ToStringOp.Int16ToString =>
        emitIntToStringNoMin(castValue(x, Type.I64, fb), fb)

      case SemanticOp.ToStringOp.Int32ToString =>
        emitIntToStringNoMin(castValue(x, Type.I64, fb), fb)

      case SemanticOp.ToStringOp.Int64ToString =>
        val xi64 = castValue(x, Type.I64, fb)
        val isMin = freshTmp(Type.I1)
        fb.current.emitAssign(isMin, Op.ICmp("eq", xi64, Value.IntConst(Long.MinValue, Type.I64)))

        val minLabel = freshLabel("i64tos_min")
        val notLabel = freshLabel("i64tos_not")
        val endLabel = freshLabel("i64tos_end")

        fb.current.setTerminator(Terminator.CondBr(isMin, minLabel, notLabel))

        val incomings = mutable.ArrayBuffer.empty[(Value, String)]

        val minBlock = fb.newBlock(minLabel)
        fb.setCurrent(minBlock)
        val minStr = emitConstant(Constant.Str("-9223372036854775808"), fb)
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((minStr, minLabel))

        val notBlock = fb.newBlock(notLabel)
        fb.setCurrent(notBlock)
        val s = emitIntToStringNoMin(xi64, fb)
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((s, notLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        val phi = freshTmp(Type.Ptr)
        endBlock.emitPhi(phi, incomings.toList)
        phi

      case SemanticOp.ToStringOp.Float32ToString =>
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_float32_to_string", List(x)))
        tmp

      case SemanticOp.ToStringOp.Float64ToString =>
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_float64_to_string", List(x)))
        tmp

      case SemanticOp.StringBuilderOp.New =>
        emitStringBuilderNew(x, fb)

      case SemanticOp.StringBuilderOp.AppendString =>
        emitStringBuilderAppendString(x, fb)

      case SemanticOp.StringBuilderOp.AppendCodePoint =>
        emitStringBuilderAppendCodePoint(x, fb)

      case SemanticOp.StringBuilderOp.CharAt =>
        emitStringBuilderCharAt(x, fb)

      case SemanticOp.StringBuilderOp.Length =>
        emitStringBuilderLength(x, fb)

      case SemanticOp.StringBuilderOp.SetLength =>
        emitStringBuilderSetLength(x, fb)

      case SemanticOp.StringBuilderOp.ToString =>
        emitStringBuilderToString(x, fb)

      case SemanticOp.ParseOp.Int8FromString =>
        emitParseIntTuple(x, Value.IntConst(10L, Type.I64), -128L, 127L, fb)

      case SemanticOp.ParseOp.Int16FromString =>
        emitParseIntTuple(x, Value.IntConst(10L, Type.I64), -32768L, 32767L, fb)

      case SemanticOp.ParseOp.Int32FromString =>
        emitParseIntTuple(x, Value.IntConst(10L, Type.I64), Int.MinValue.toLong, Int.MaxValue.toLong, fb)

      case SemanticOp.ParseOp.Int64FromString =>
        emitParseIntTuple(x, Value.IntConst(10L, Type.I64), Long.MinValue, Long.MaxValue, fb)

      case SemanticOp.ParseOp.Int32Parse =>
        val radixI64 = castValue(loadTupleElement(x, 0, SimpleType.Int32, fb), Type.I64, fb)
        val sPtr = loadTupleElement(x, 1, SimpleType.String, fb)
        emitParseIntTuple(sPtr, radixI64, Int.MinValue.toLong, Int.MaxValue.toLong, fb)

      case SemanticOp.ParseOp.Int64Parse =>
        val radixI64 = castValue(loadTupleElement(x, 0, SimpleType.Int32, fb), Type.I64, fb)
        val sPtr = loadTupleElement(x, 1, SimpleType.String, fb)
        emitParseIntTuple(sPtr, radixI64, Long.MinValue, Long.MaxValue, fb)

      case SemanticOp.ParseOp.Float32FromString =>
        emitParseFloatTuple(x, is32 = true, fb)

      case SemanticOp.ParseOp.Float64FromString =>
        emitParseFloatTuple(x, is32 = false, fb)

      case SemanticOp.StringOp.Length =>
        val strPtr = castValue(x, Type.Ptr, fb)
        val lenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, strPtr, Value.IntConst(0L, Type.I64)))
        val lenI64 = freshTmp(Type.I64)
        fb.current.emitAssign(lenI64, Op.Load(Type.I64, lenPtr))
        val lenI32 = freshTmp(Type.I32)
        fb.current.emitAssign(lenI32, Op.Cast("trunc", Type.I32, lenI64))
        lenI32

      case SemanticOp.HashOp.CharHash =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I32, x))
        tmp

      case SemanticOp.HashOp.Float32Hash =>
        val isNaN = freshTmp(Type.I1)
        fb.current.emitAssign(isNaN, Op.FCmp("uno", x, x))

        val nanLabel = freshLabel("f32hash_nan")
        val notNanLabel = freshLabel("f32hash_notnan")
        val endLabel = freshLabel("f32hash_end")

        fb.current.setTerminator(Terminator.CondBr(isNaN, nanLabel, notNanLabel))

        val incomings = mutable.ArrayBuffer.empty[(Value, String)]

        val nanBlock = fb.newBlock(nanLabel)
        fb.setCurrent(nanBlock)
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((Value.IntConst(0x7fc00000L, Type.I32), nanLabel))

        val notNanBlock = fb.newBlock(notNanLabel)
        fb.setCurrent(notNanBlock)
        val bits = freshTmp(Type.I32)
        fb.current.emitAssign(bits, Op.Cast("bitcast", Type.I32, x))
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((bits, notNanLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        val phi = freshTmp(Type.I32)
        endBlock.emitPhi(phi, incomings.toList)
        phi

      case SemanticOp.HashOp.Float64Hash =>
        val isNaN = freshTmp(Type.I1)
        fb.current.emitAssign(isNaN, Op.FCmp("uno", x, x))

        val nanLabel = freshLabel("f64hash_nan")
        val notNanLabel = freshLabel("f64hash_notnan")
        val endLabel = freshLabel("f64hash_end")

        fb.current.setTerminator(Terminator.CondBr(isNaN, nanLabel, notNanLabel))

        val incomings = mutable.ArrayBuffer.empty[(Value, String)]

        val nanBlock = fb.newBlock(nanLabel)
        fb.setCurrent(nanBlock)
        val bitsNan = Value.IntConst(0x7ff8000000000000L, Type.I64)
        val shiftNan = freshTmp(Type.I64)
        fb.current.emitAssign(shiftNan, Op.Bin("lshr", Type.I64, bitsNan, Value.IntConst(32L, Type.I64)))
        val xoredNan = freshTmp(Type.I64)
        fb.current.emitAssign(xoredNan, Op.Bin("xor", Type.I64, bitsNan, shiftNan))
        val hashNan = freshTmp(Type.I32)
        fb.current.emitAssign(hashNan, Op.Cast("trunc", Type.I32, xoredNan))
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((hashNan, nanLabel))

        val notNanBlock = fb.newBlock(notNanLabel)
        fb.setCurrent(notNanBlock)
        val bits = freshTmp(Type.I64)
        fb.current.emitAssign(bits, Op.Cast("bitcast", Type.I64, x))
        val shift = freshTmp(Type.I64)
        fb.current.emitAssign(shift, Op.Bin("lshr", Type.I64, bits, Value.IntConst(32L, Type.I64)))
        val xored = freshTmp(Type.I64)
        fb.current.emitAssign(xored, Op.Bin("xor", Type.I64, bits, shift))
        val hash = freshTmp(Type.I32)
        fb.current.emitAssign(hash, Op.Cast("trunc", Type.I32, xored))
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((hash, notNanLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        val phi = freshTmp(Type.I32)
        endBlock.emitPhi(phi, incomings.toList)
        phi

      case SemanticOp.HashOp.Int8Hash =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I32, x))
        tmp

      case SemanticOp.HashOp.Int16Hash =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Cast("sext", Type.I32, x))
        tmp

      case SemanticOp.HashOp.Int32Hash =>
        x

      case SemanticOp.HashOp.Int64Hash =>
        val shifted = freshTmp(Type.I64)
        fb.current.emitAssign(shifted, Op.Bin("lshr", Type.I64, x, Value.IntConst(32L, Type.I64)))
        val xored = freshTmp(Type.I64)
        fb.current.emitAssign(xored, Op.Bin("xor", Type.I64, x, shifted))
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I32, xored))
        tmp

      case SemanticOp.HashOp.StringHash =>
        val strPtr = castValue(x, Type.Ptr, fb)

        val lenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, strPtr, Value.IntConst(0L, Type.I64)))
        val lenI64 = freshTmp(Type.I64)
        fb.current.emitAssign(lenI64, Op.Load(Type.I64, lenPtr))

        val iPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(iPtr, Op.Alloca(Type.I64))
        fb.current.emitStore(Value.IntConst(0L, Type.I64), iPtr)

        val hPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(hPtr, Op.Alloca(Type.I32))
        fb.current.emitStore(Value.IntConst(0L, Type.I32), hPtr)

        val loopLabel = freshLabel("strhash_loop")
        val bodyLabel = freshLabel("strhash_body")
        val endLabel = freshLabel("strhash_end")

        fb.current.setTerminator(Terminator.Br(loopLabel))

        val loopBlock = fb.newBlock(loopLabel)
        fb.setCurrent(loopBlock)
        val iVal = freshTmp(Type.I64)
        fb.current.emitAssign(iVal, Op.Load(Type.I64, iPtr))
        val cond = freshTmp(Type.I1)
        fb.current.emitAssign(cond, Op.ICmp("slt", iVal, lenI64))
        fb.current.setTerminator(Terminator.CondBr(cond, bodyLabel, endLabel))

        val bodyBlock = fb.newBlock(bodyLabel)
        fb.setCurrent(bodyBlock)
        val slotIdx = freshTmp(Type.I64)
        fb.current.emitAssign(slotIdx, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
        val slotPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, strPtr, slotIdx))
        val payload = freshTmp(Type.I64)
        fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
        val ch = freshTmp(Type.I32)
        fb.current.emitAssign(ch, Op.Cast("trunc", Type.I32, payload))

        val hVal = freshTmp(Type.I32)
        fb.current.emitAssign(hVal, Op.Load(Type.I32, hPtr))
        val hMul = freshTmp(Type.I32)
        fb.current.emitAssign(hMul, Op.Bin("mul", Type.I32, hVal, Value.IntConst(31L, Type.I32)))
        val hNext = freshTmp(Type.I32)
        fb.current.emitAssign(hNext, Op.Bin("add", Type.I32, hMul, ch))
        fb.current.emitStore(hNext, hPtr)

        val iNext = freshTmp(Type.I64)
        fb.current.emitAssign(iNext, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
        fb.current.emitStore(iNext, iPtr)
        fb.current.setTerminator(Terminator.Br(loopLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        val res = freshTmp(Type.I32)
        fb.current.emitAssign(res, Op.Load(Type.I32, hPtr))
        res

      case SemanticOp.IoOp.Print =>
        val s = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Call(Type.I64, "flix_print", List(s)))
        tmp

      case SemanticOp.IoOp.EPrint =>
        val s = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Call(Type.I64, "flix_eprint", List(s)))
        tmp

      case SemanticOp.IoOp.Println =>
        val s = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Call(Type.I64, "flix_println", List(s)))
        tmp

      case SemanticOp.IoOp.EPrintln =>
        val s = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Call(Type.I64, "flix_eprintln", List(s)))
        tmp

      case SemanticOp.IoOp.Readln =>
        val unit = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_readln", List(unit)))
        tmp

      case SemanticOp.IoOp.SleepMillis =>
        val ms = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Call(Type.I64, "flix_sleep_millis", List(ms)))
        tmp

      case SemanticOp.IoOp.Exit =>
        val code = castValue(x, Type.I32, fb)
        fb.current.emitCallVoid("flix_exit", List(code))
        fb.current.setTerminator(Terminator.Unreachable)
        Value.Undef(Type.I64)

      case SemanticOp.IoOp.NewId =>
        val unit = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Call(Type.I64, "flix_new_id", List(unit)))
        tmp

      case SemanticOp.IoOp.TcpSocketRead =>
        val id = loadTupleElement(x, 0L, SimpleType.Int64, fb)
        val buf = loadTupleElement(x, 1L, SimpleType.Array(SimpleType.Int8), fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_tcp_socket_read", List(id, buf)))
        tmp

      case SemanticOp.IoOp.TcpSocketWrite =>
        val id = loadTupleElement(x, 0L, SimpleType.Int64, fb)
        val buf = loadTupleElement(x, 1L, SimpleType.Array(SimpleType.Int8), fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_tcp_socket_write", List(id, buf)))
        tmp

      case SemanticOp.IoOp.TcpSocketConnect =>
        val ipBytes = loadTupleElement(x, 0L, SimpleType.Array(SimpleType.Int8), fb)
        val port = loadTupleElement(x, 1L, SimpleType.Int32, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_tcp_socket_connect", List(ipBytes, port)))
        tmp

      case SemanticOp.IoOp.TcpSocketClose =>
        val id = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_tcp_socket_close", List(id)))
        tmp

      case SemanticOp.IoOp.TcpServerBind =>
        val ipBytes = loadTupleElement(x, 0L, SimpleType.Array(SimpleType.Int8), fb)
        val port = loadTupleElement(x, 1L, SimpleType.Int32, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_tcp_server_bind", List(ipBytes, port)))
        tmp

      case SemanticOp.IoOp.TcpServerAccept =>
        val id = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_tcp_server_accept", List(id)))
        tmp

      case SemanticOp.IoOp.TcpServerClose =>
        val id = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_tcp_server_close", List(id)))
        tmp

      case SemanticOp.IoOp.ProcessStdinWrite =>
        val id = loadTupleElement(x, 0L, SimpleType.Int64, fb)
        val buf = loadTupleElement(x, 1L, SimpleType.Array(SimpleType.Int8), fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_stdin_write", List(id, buf)))
        tmp

      case SemanticOp.IoOp.ProcessExec =>
        val argv = loadTupleElement(x, 0L, SimpleType.Array(SimpleType.String), fb)
        val hasCwd = loadTupleElement(x, 1L, SimpleType.Bool, fb)
        val cwdStr = loadTupleElement(x, 2L, SimpleType.String, fb)
        val envPairs = loadTupleElement(x, 3L, SimpleType.Array(SimpleType.String), fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_exec", List(argv, hasCwd, cwdStr, envPairs)))
        tmp

      case SemanticOp.IoOp.ProcessExitValue =>
        val id = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_exit_value", List(id)))
        tmp

      case SemanticOp.IoOp.ProcessIsAlive =>
        val id = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_is_alive", List(id)))
        tmp

      case SemanticOp.IoOp.ProcessPid =>
        val id = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_pid", List(id)))
        tmp

      case SemanticOp.IoOp.ProcessStop =>
        val id = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_stop", List(id)))
        tmp

      case SemanticOp.IoOp.ProcessWaitFor =>
        val id = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_wait_for", List(id)))
        tmp

      case SemanticOp.IoOp.ProcessWaitForTimeout =>
        val id = loadTupleElement(x, 0L, SimpleType.Int64, fb)
        val timeoutMs = loadTupleElement(x, 1L, SimpleType.Int64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_wait_for_timeout", List(id, timeoutMs)))
        tmp

      case SemanticOp.IoOp.ProcessStdoutRead =>
        val id = loadTupleElement(x, 0L, SimpleType.Int64, fb)
        val buf = loadTupleElement(x, 1L, SimpleType.Array(SimpleType.Int8), fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_stdout_read", List(id, buf)))
        tmp

      case SemanticOp.IoOp.ProcessStderrRead =>
        val id = loadTupleElement(x, 0L, SimpleType.Int64, fb)
        val buf = loadTupleElement(x, 1L, SimpleType.Array(SimpleType.Int8), fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_stderr_read", List(id, buf)))
        tmp

      case SemanticOp.IoOp.ProcessRelease =>
        val id = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_process_release", List(id)))
        tmp

      case SemanticOp.IoOp.HttpRequest =>
        val method = loadTupleElement(x, 0L, SimpleType.String, fb)
        val url = loadTupleElement(x, 1L, SimpleType.String, fb)
        val headers = loadTupleElement(x, 2L, SimpleType.Array(SimpleType.String), fb)
        val hasBody = loadTupleElement(x, 3L, SimpleType.Bool, fb)
        val body = loadTupleElement(x, 4L, SimpleType.String, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_http_request", List(method, url, headers, hasBody, body)))
        tmp

      case SemanticOp.IoOp.EnvGetArgs =>
        val region = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_env_get_args", List(region)))
        tmp

      case SemanticOp.IoOp.EnvGetEnvPairs =>
        val region = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_env_get_env_pairs", List(region)))
        tmp

      case SemanticOp.IoOp.EnvGetVar =>
        val name = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_env_get_var", List(name)))
        tmp

      case SemanticOp.IoOp.EnvGetProp =>
        val name = castValue(x, Type.Ptr, fb)
        val tmp = freshTmp(Type.Ptr)
        fb.current.emitAssign(tmp, Op.Call(Type.Ptr, "flix_env_get_prop", List(name)))
        tmp

      case SemanticOp.IoOp.EnvVirtualProcessors =>
        val unit = castValue(x, Type.I64, fb)
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Call(Type.I32, "flix_env_virtual_processors", List(unit)))
        tmp

      case _ =>
        fb.current.emitTrap()
        Value.Undef(x.tpe)
    }

    private def emitCharToString(ch: Value, fb: FunBuilder): Value = {
      val payload = boxToI64(ch, SimpleType.Char, fb)
      val strPtr = allocString(Value.IntConst(1L, Type.I64), fb)
      storeI64Slot(strPtr, Value.IntConst(1L, Type.I64), payload, fb)
      strPtr
    }

    private def emitIntToStringNoMin(xI64: Value, fb: FunBuilder): Value = {
      val isNeg = freshTmp(Type.I1)
      fb.current.emitAssign(isNeg, Op.ICmp("slt", xI64, Value.IntConst(0L, Type.I64)))

      val absPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(absPtr, Op.Alloca(Type.I64))

      val negLabel = freshLabel("itos_neg")
      val posLabel = freshLabel("itos_pos")
      val absLabel = freshLabel("itos_abs")

      fb.current.setTerminator(Terminator.CondBr(isNeg, negLabel, posLabel))

      val negBlock = fb.newBlock(negLabel)
      fb.setCurrent(negBlock)
      val absNeg = freshTmp(Type.I64)
      fb.current.emitAssign(absNeg, Op.Bin("sub", Type.I64, Value.IntConst(0L, Type.I64), xI64))
      fb.current.emitStore(absNeg, absPtr)
      fb.current.setTerminator(Terminator.Br(absLabel))

      val posBlock = fb.newBlock(posLabel)
      fb.setCurrent(posBlock)
      fb.current.emitStore(xI64, absPtr)
      fb.current.setTerminator(Terminator.Br(absLabel))

      val absBlock = fb.newBlock(absLabel)
      fb.setCurrent(absBlock)
      val absVal = freshTmp(Type.I64)
      fb.current.emitAssign(absVal, Op.Load(Type.I64, absPtr))

      // Count digits in `absVal` (absVal >= 0).
      val nPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(nPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(absVal, nPtr)

      val digitsPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(digitsPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(Value.IntConst(1L, Type.I64), digitsPtr)

      val countLoopLabel = freshLabel("itos_count_loop")
      val countBodyLabel = freshLabel("itos_count_body")
      val countDoneLabel = freshLabel("itos_count_done")
      fb.current.setTerminator(Terminator.Br(countLoopLabel))

      val countLoopBlock = fb.newBlock(countLoopLabel)
      fb.setCurrent(countLoopBlock)
      val nVal = freshTmp(Type.I64)
      fb.current.emitAssign(nVal, Op.Load(Type.I64, nPtr))
      val cond = freshTmp(Type.I1)
      fb.current.emitAssign(cond, Op.ICmp("sge", nVal, Value.IntConst(10L, Type.I64)))
      fb.current.setTerminator(Terminator.CondBr(cond, countBodyLabel, countDoneLabel))

      val countBodyBlock = fb.newBlock(countBodyLabel)
      fb.setCurrent(countBodyBlock)
      val nNext = freshTmp(Type.I64)
      fb.current.emitAssign(nNext, Op.Bin("sdiv", Type.I64, nVal, Value.IntConst(10L, Type.I64)))
      fb.current.emitStore(nNext, nPtr)
      val dVal = freshTmp(Type.I64)
      fb.current.emitAssign(dVal, Op.Load(Type.I64, digitsPtr))
      val dNext = freshTmp(Type.I64)
      fb.current.emitAssign(dNext, Op.Bin("add", Type.I64, dVal, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(dNext, digitsPtr)
      fb.current.setTerminator(Terminator.Br(countLoopLabel))

      val countDoneBlock = fb.newBlock(countDoneLabel)
      fb.setCurrent(countDoneBlock)
      val digits = freshTmp(Type.I64)
      fb.current.emitAssign(digits, Op.Load(Type.I64, digitsPtr))

      val signOffset = freshTmp(Type.I64)
      fb.current.emitAssign(signOffset, Op.Cast("zext", Type.I64, isNeg))

      val totalLen = freshTmp(Type.I64)
      fb.current.emitAssign(totalLen, Op.Bin("add", Type.I64, digits, signOffset))

      val strPtr = allocString(totalLen, fb)

      // Fill digits from the end.
      val kPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(kPtr, Op.Alloca(Type.I64))
      val k0 = freshTmp(Type.I64)
      fb.current.emitAssign(k0, Op.Bin("sub", Type.I64, totalLen, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(k0, kPtr)

      val mPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(mPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(absVal, mPtr)

      val fillLoopLabel = freshLabel("itos_fill_loop")
      val fillBodyLabel = freshLabel("itos_fill_body")
      val fillDoneLabel = freshLabel("itos_fill_done")
      fb.current.setTerminator(Terminator.Br(fillLoopLabel))

      val fillLoopBlock = fb.newBlock(fillLoopLabel)
      fb.setCurrent(fillLoopBlock)
      val kVal = freshTmp(Type.I64)
      fb.current.emitAssign(kVal, Op.Load(Type.I64, kPtr))
      val cond2 = freshTmp(Type.I1)
      fb.current.emitAssign(cond2, Op.ICmp("sge", kVal, signOffset))
      fb.current.setTerminator(Terminator.CondBr(cond2, fillBodyLabel, fillDoneLabel))

      val fillBodyBlock = fb.newBlock(fillBodyLabel)
      fb.setCurrent(fillBodyBlock)
      val mVal = freshTmp(Type.I64)
      fb.current.emitAssign(mVal, Op.Load(Type.I64, mPtr))
      val digit = freshTmp(Type.I64)
      fb.current.emitAssign(digit, Op.Bin("srem", Type.I64, mVal, Value.IntConst(10L, Type.I64)))
      val mNext = freshTmp(Type.I64)
      fb.current.emitAssign(mNext, Op.Bin("sdiv", Type.I64, mVal, Value.IntConst(10L, Type.I64)))
      fb.current.emitStore(mNext, mPtr)

      val ch = freshTmp(Type.I64)
      fb.current.emitAssign(ch, Op.Bin("add", Type.I64, digit, Value.IntConst(48L, Type.I64)))

      val slotIdx = freshTmp(Type.I64)
      fb.current.emitAssign(slotIdx, Op.Bin("add", Type.I64, kVal, Value.IntConst(1L, Type.I64)))
      storeI64Slot(strPtr, slotIdx, ch, fb)

      val kNext = freshTmp(Type.I64)
      fb.current.emitAssign(kNext, Op.Bin("sub", Type.I64, kVal, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(kNext, kPtr)
      fb.current.setTerminator(Terminator.Br(fillLoopLabel))

      val fillDoneBlock = fb.newBlock(fillDoneLabel)
      fb.setCurrent(fillDoneBlock)

      val signLabel = freshLabel("itos_sign")
      val endLabel = freshLabel("itos_end")
      fb.current.setTerminator(Terminator.CondBr(isNeg, signLabel, endLabel))

      val signBlock = fb.newBlock(signLabel)
      fb.setCurrent(signBlock)
      storeI64Slot(strPtr, Value.IntConst(1L, Type.I64), Value.IntConst(45L, Type.I64), fb) // '-'
      fb.current.setTerminator(Terminator.Br(endLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      strPtr
    }

    private def sbLenI64(sbPtr0: Value, fb: FunBuilder): Value =
      loadI64Slot(sbPtr0, Value.IntConst(0L, Type.I64), fb)

    private def sbCapI64(sbPtr0: Value, fb: FunBuilder): Value =
      loadI64Slot(sbPtr0, Value.IntConst(1L, Type.I64), fb)

    private def sbDataPtr(sbPtr0: Value, fb: FunBuilder): Value = {
      val bits = loadI64Slot(sbPtr0, Value.IntConst(2L, Type.I64), fb)
      castValue(bits, Type.Ptr, fb)
    }

    private def sbStoreLen(sbPtr0: Value, lenI64: Value, fb: FunBuilder): Unit =
      storeI64Slot(sbPtr0, Value.IntConst(0L, Type.I64), lenI64, fb)

    private def sbStoreCap(sbPtr0: Value, capI64: Value, fb: FunBuilder): Unit =
      storeI64Slot(sbPtr0, Value.IntConst(1L, Type.I64), capI64, fb)

    private def sbStoreDataPtr(sbPtr0: Value, dataPtr: Value, fb: FunBuilder): Unit = {
      val bits = freshTmp(Type.I64)
      fb.current.emitAssign(bits, Op.Cast("ptrtoint", Type.I64, dataPtr))
      storeI64Slot(sbPtr0, Value.IntConst(2L, Type.I64), bits, fb)
    }

    private def sbEnsureCapacity(sbPtr0: Value, neededLenI64: Value, fb: FunBuilder): Unit = {
      val sbPtr = castValue(sbPtr0, Type.Ptr, fb)
      val cap = sbCapI64(sbPtr, fb)
      val enough = freshTmp(Type.I1)
      fb.current.emitAssign(enough, Op.ICmp("sge", cap, neededLenI64))

      val okLabel = freshLabel("sbcap_ok")
      val growLabel = freshLabel("sbcap_grow")
      val endLabel = freshLabel("sbcap_end")
      fb.current.setTerminator(Terminator.CondBr(enough, okLabel, growLabel))

      val okBlock = fb.newBlock(okLabel)
      fb.setCurrent(okBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))

      val growBlock = fb.newBlock(growLabel)
      fb.setCurrent(growBlock)

      // Compute newCap by doubling until it can hold neededLen.
      val newCapPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(newCapPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(cap, newCapPtr)

      val capLoopLabel = freshLabel("sbcap_loop")
      val capBodyLabel = freshLabel("sbcap_body")
      val capDoneLabel = freshLabel("sbcap_done")
      fb.current.setTerminator(Terminator.Br(capLoopLabel))

      val capLoopBlock = fb.newBlock(capLoopLabel)
      fb.setCurrent(capLoopBlock)
      val ncVal = freshTmp(Type.I64)
      fb.current.emitAssign(ncVal, Op.Load(Type.I64, newCapPtr))
      val needMore = freshTmp(Type.I1)
      fb.current.emitAssign(needMore, Op.ICmp("slt", ncVal, neededLenI64))
      fb.current.setTerminator(Terminator.CondBr(needMore, capBodyLabel, capDoneLabel))

      val capBodyBlock = fb.newBlock(capBodyLabel)
      fb.setCurrent(capBodyBlock)
      val ncNext = freshTmp(Type.I64)
      fb.current.emitAssign(ncNext, Op.Bin("mul", Type.I64, ncVal, Value.IntConst(2L, Type.I64)))
      fb.current.emitStore(ncNext, newCapPtr)
      fb.current.setTerminator(Terminator.Br(capLoopLabel))

      val capDoneBlock = fb.newBlock(capDoneLabel)
      fb.setCurrent(capDoneBlock)
      val newCap = freshTmp(Type.I64)
      fb.current.emitAssign(newCap, Op.Load(Type.I64, newCapPtr))

      val sizeBytes = freshTmp(Type.I64)
      fb.current.emitAssign(sizeBytes, Op.Bin("mul", Type.I64, newCap, Value.IntConst(8L, Type.I64)))
      val newBuf = freshTmp(Type.Ptr)
      fb.current.emitAssign(newBuf, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

      // Copy existing data.
      val oldBuf = sbDataPtr(sbPtr, fb)
      val len = sbLenI64(sbPtr, fb)

      val iPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(iPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(Value.IntConst(0L, Type.I64), iPtr)

      val copyLoopLabel = freshLabel("sbcap_copy_loop")
      val copyBodyLabel = freshLabel("sbcap_copy_body")
      val copyDoneLabel = freshLabel("sbcap_copy_done")
      fb.current.setTerminator(Terminator.Br(copyLoopLabel))

      val copyLoopBlock = fb.newBlock(copyLoopLabel)
      fb.setCurrent(copyLoopBlock)
      val iVal = freshTmp(Type.I64)
      fb.current.emitAssign(iVal, Op.Load(Type.I64, iPtr))
      val copyCond = freshTmp(Type.I1)
      fb.current.emitAssign(copyCond, Op.ICmp("slt", iVal, len))
      fb.current.setTerminator(Terminator.CondBr(copyCond, copyBodyLabel, copyDoneLabel))

      val copyBodyBlock = fb.newBlock(copyBodyLabel)
      fb.setCurrent(copyBodyBlock)
      val payload = loadI64Slot(oldBuf, iVal, fb)
      storeI64Slot(newBuf, iVal, payload, fb)
      val iNext = freshTmp(Type.I64)
      fb.current.emitAssign(iNext, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(iNext, iPtr)
      fb.current.setTerminator(Terminator.Br(copyLoopLabel))

      val copyDoneBlock = fb.newBlock(copyDoneLabel)
      fb.setCurrent(copyDoneBlock)

      // Install the new buffer (bring-up: leak the old buffer).
      sbStoreDataPtr(sbPtr, newBuf, fb)
      sbStoreCap(sbPtr, newCap, fb)

      fb.current.setTerminator(Terminator.Br(endLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
    }

    private def emitStringBuilderNew(_rc: Value, fb: FunBuilder): Value = {
      // Layout: [0]=len (i64), [1]=cap (i64), [2]=dataPtr bits (i64).
      val handlePtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(handlePtr, Op.Call(Type.Ptr, "malloc", List(Value.IntConst(24L, Type.I64))))

      val initCap = Value.IntConst(16L, Type.I64)
      val bufBytes = freshTmp(Type.I64)
      fb.current.emitAssign(bufBytes, Op.Bin("mul", Type.I64, initCap, Value.IntConst(8L, Type.I64)))
      val bufPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(bufPtr, Op.Call(Type.Ptr, "malloc", List(bufBytes)))

      sbStoreLen(handlePtr, Value.IntConst(0L, Type.I64), fb)
      sbStoreCap(handlePtr, initCap, fb)
      sbStoreDataPtr(handlePtr, bufPtr, fb)
      handlePtr
    }

    private def emitStringBuilderAppendString(argsTuple: Value, fb: FunBuilder): Value = {
      val sbPtr = loadTupleElement(argsTuple, 1, SimpleType.StringBuilderHandle, fb)
      val sPtr = loadTupleElement(argsTuple, 2, SimpleType.String, fb)

      val sbLen = sbLenI64(sbPtr, fb)
      val sLen = stringLenI64(sPtr, fb)

      val newLen = freshTmp(Type.I64)
      fb.current.emitAssign(newLen, Op.Bin("add", Type.I64, sbLen, sLen))

      sbEnsureCapacity(sbPtr, newLen, fb)

      val dataPtr = sbDataPtr(sbPtr, fb)

      val iPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(iPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(Value.IntConst(0L, Type.I64), iPtr)

      val loopLabel = freshLabel("sb_append_loop")
      val bodyLabel = freshLabel("sb_append_body")
      val endLabel = freshLabel("sb_append_end")
      fb.current.setTerminator(Terminator.Br(loopLabel))

      val loopBlock = fb.newBlock(loopLabel)
      fb.setCurrent(loopBlock)
      val iVal = freshTmp(Type.I64)
      fb.current.emitAssign(iVal, Op.Load(Type.I64, iPtr))
      val cond = freshTmp(Type.I1)
      fb.current.emitAssign(cond, Op.ICmp("slt", iVal, sLen))
      fb.current.setTerminator(Terminator.CondBr(cond, bodyLabel, endLabel))

      val bodyBlock = fb.newBlock(bodyLabel)
      fb.setCurrent(bodyBlock)
      val chPayload = stringCharPayloadI64(sPtr, iVal, fb)
      val dstIdx = freshTmp(Type.I64)
      fb.current.emitAssign(dstIdx, Op.Bin("add", Type.I64, sbLen, iVal))
      storeI64Slot(dataPtr, dstIdx, chPayload, fb)
      val iNext = freshTmp(Type.I64)
      fb.current.emitAssign(iNext, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(iNext, iPtr)
      fb.current.setTerminator(Terminator.Br(loopLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      sbStoreLen(sbPtr, newLen, fb)
      Value.IntConst(0L, Type.I64)
    }

    private def emitStringBuilderAppendCodePoint(argsTuple: Value, fb: FunBuilder): Value = {
      val sbPtr = loadTupleElement(argsTuple, 1, SimpleType.StringBuilderHandle, fb)
      val cpI64 = castValue(loadTupleElement(argsTuple, 2, SimpleType.Int32, fb), Type.I64, fb)

      val isNeg = freshTmp(Type.I1)
      fb.current.emitAssign(isNeg, Op.ICmp("slt", cpI64, Value.IntConst(0L, Type.I64)))
      val tooBig = freshTmp(Type.I1)
      fb.current.emitAssign(tooBig, Op.ICmp("sgt", cpI64, Value.IntConst(0x10ffffL, Type.I64)))
      val invalid = freshTmp(Type.I1)
      fb.current.emitAssign(invalid, Op.Bin("or", Type.I1, isNeg, tooBig))

      val okLabel = freshLabel("sbcp_ok")
      val badLabel = freshLabel("sbcp_bad")
      val contLabel = freshLabel("sbcp_cont")
      fb.current.setTerminator(Terminator.CondBr(invalid, badLabel, okLabel))

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      val okBlock = fb.newBlock(okLabel)
      fb.setCurrent(okBlock)

      val sbLen = sbLenI64(sbPtr, fb)
      val isSupplementary = freshTmp(Type.I1)
      fb.current.emitAssign(isSupplementary, Op.ICmp("sge", cpI64, Value.IntConst(0x10000L, Type.I64)))

      val oneLabel = freshLabel("sbcp_one")
      val twoLabel = freshLabel("sbcp_two")
      fb.current.setTerminator(Terminator.CondBr(isSupplementary, twoLabel, oneLabel))

      val oneBlock = fb.newBlock(oneLabel)
      fb.setCurrent(oneBlock)
      val newLen1 = freshTmp(Type.I64)
      fb.current.emitAssign(newLen1, Op.Bin("add", Type.I64, sbLen, Value.IntConst(1L, Type.I64)))
      sbEnsureCapacity(sbPtr, newLen1, fb)
      val dataPtr1 = sbDataPtr(sbPtr, fb)
      storeI64Slot(dataPtr1, sbLen, cpI64, fb)
      sbStoreLen(sbPtr, newLen1, fb)
      fb.current.setTerminator(Terminator.Br(contLabel))

      val twoBlock = fb.newBlock(twoLabel)
      fb.setCurrent(twoBlock)
      val newLen2 = freshTmp(Type.I64)
      fb.current.emitAssign(newLen2, Op.Bin("add", Type.I64, sbLen, Value.IntConst(2L, Type.I64)))
      sbEnsureCapacity(sbPtr, newLen2, fb)
      val dataPtr2 = sbDataPtr(sbPtr, fb)

      val cpPrime = freshTmp(Type.I64)
      fb.current.emitAssign(cpPrime, Op.Bin("sub", Type.I64, cpI64, Value.IntConst(0x10000L, Type.I64)))
      val hi = freshTmp(Type.I64)
      fb.current.emitAssign(hi, Op.Bin("add", Type.I64,
        Value.IntConst(0xd800L, Type.I64),
        {
          val shifted = freshTmp(Type.I64)
          fb.current.emitAssign(shifted, Op.Bin("lshr", Type.I64, cpPrime, Value.IntConst(10L, Type.I64)))
          shifted
        }
      ))
      val lo = freshTmp(Type.I64)
      fb.current.emitAssign(lo, Op.Bin("add", Type.I64,
        Value.IntConst(0xdc00L, Type.I64),
        {
          val masked = freshTmp(Type.I64)
          fb.current.emitAssign(masked, Op.Bin("and", Type.I64, cpPrime, Value.IntConst(0x3ffL, Type.I64)))
          masked
        }
      ))

      storeI64Slot(dataPtr2, sbLen, hi, fb)
      val sbLenPlus1 = freshTmp(Type.I64)
      fb.current.emitAssign(sbLenPlus1, Op.Bin("add", Type.I64, sbLen, Value.IntConst(1L, Type.I64)))
      storeI64Slot(dataPtr2, sbLenPlus1, lo, fb)
      sbStoreLen(sbPtr, newLen2, fb)
      fb.current.setTerminator(Terminator.Br(contLabel))

      val contBlock = fb.newBlock(contLabel)
      fb.setCurrent(contBlock)
      Value.IntConst(0L, Type.I64)
    }

    private def emitStringBuilderCharAt(argsTuple: Value, fb: FunBuilder): Value = {
      val sbPtr = loadTupleElement(argsTuple, 1, SimpleType.StringBuilderHandle, fb)
      val idxI64 = castValue(loadTupleElement(argsTuple, 2, SimpleType.Int32, fb), Type.I64, fb)
      val lenI64 = sbLenI64(sbPtr, fb)

      val neg = freshTmp(Type.I1)
      fb.current.emitAssign(neg, Op.ICmp("slt", idxI64, Value.IntConst(0L, Type.I64)))
      val ge = freshTmp(Type.I1)
      fb.current.emitAssign(ge, Op.ICmp("sge", idxI64, lenI64))
      val oob = freshTmp(Type.I1)
      fb.current.emitAssign(oob, Op.Bin("or", Type.I1, neg, ge))

      val okLabel = freshLabel("sbcharat_ok")
      val badLabel = freshLabel("sbcharat_bad")
      val endLabel = freshLabel("sbcharat_end")
      fb.current.setTerminator(Terminator.CondBr(oob, badLabel, okLabel))

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      val okBlock = fb.newBlock(okLabel)
      fb.setCurrent(okBlock)
      val dataPtr = sbDataPtr(sbPtr, fb)
      val payload = loadI64Slot(dataPtr, idxI64, fb)
      val ch = unboxFromI64(payload, SimpleType.Char, fb)
      fb.current.setTerminator(Terminator.Br(endLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      ch
    }

    private def emitStringBuilderLength(argsTuple: Value, fb: FunBuilder): Value = {
      val sbPtr = loadTupleElement(argsTuple, 1, SimpleType.StringBuilderHandle, fb)
      val lenI64 = sbLenI64(sbPtr, fb)
      val lenI32 = freshTmp(Type.I32)
      fb.current.emitAssign(lenI32, Op.Cast("trunc", Type.I32, lenI64))
      lenI32
    }

    private def emitStringBuilderSetLength(argsTuple: Value, fb: FunBuilder): Value = {
      val sbPtr = loadTupleElement(argsTuple, 1, SimpleType.StringBuilderHandle, fb)
      val newLenI64 = castValue(loadTupleElement(argsTuple, 2, SimpleType.Int32, fb), Type.I64, fb)

      val isNeg = freshTmp(Type.I1)
      fb.current.emitAssign(isNeg, Op.ICmp("slt", newLenI64, Value.IntConst(0L, Type.I64)))

      val okLabel = freshLabel("sblen_ok")
      val badLabel = freshLabel("sblen_bad")
      val contLabel = freshLabel("sblen_cont")
      fb.current.setTerminator(Terminator.CondBr(isNeg, badLabel, okLabel))

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      val okBlock = fb.newBlock(okLabel)
      fb.setCurrent(okBlock)

      val oldLen = sbLenI64(sbPtr, fb)
      val needsGrow = freshTmp(Type.I1)
      fb.current.emitAssign(needsGrow, Op.ICmp("sgt", newLenI64, oldLen))

      val growLabel = freshLabel("sblen_grow")
      val shrinkLabel = freshLabel("sblen_shrink")
      fb.current.setTerminator(Terminator.CondBr(needsGrow, growLabel, shrinkLabel))

      val shrinkBlock = fb.newBlock(shrinkLabel)
      fb.setCurrent(shrinkBlock)
      sbStoreLen(sbPtr, newLenI64, fb)
      fb.current.setTerminator(Terminator.Br(contLabel))

      val growBlock = fb.newBlock(growLabel)
      fb.setCurrent(growBlock)
      sbEnsureCapacity(sbPtr, newLenI64, fb)
      val dataPtr = sbDataPtr(sbPtr, fb)

      val iPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(iPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(oldLen, iPtr)

      val loopLabel = freshLabel("sblen_fill_loop")
      val bodyLabel = freshLabel("sblen_fill_body")
      val endLabel = freshLabel("sblen_fill_end")
      fb.current.setTerminator(Terminator.Br(loopLabel))

      val loopBlock = fb.newBlock(loopLabel)
      fb.setCurrent(loopBlock)
      val iVal = freshTmp(Type.I64)
      fb.current.emitAssign(iVal, Op.Load(Type.I64, iPtr))
      val cond = freshTmp(Type.I1)
      fb.current.emitAssign(cond, Op.ICmp("slt", iVal, newLenI64))
      fb.current.setTerminator(Terminator.CondBr(cond, bodyLabel, endLabel))

      val bodyBlock = fb.newBlock(bodyLabel)
      fb.setCurrent(bodyBlock)
      storeI64Slot(dataPtr, iVal, Value.IntConst(0L, Type.I64), fb)
      val iNext = freshTmp(Type.I64)
      fb.current.emitAssign(iNext, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(iNext, iPtr)
      fb.current.setTerminator(Terminator.Br(loopLabel))

      val endFillBlock = fb.newBlock(endLabel)
      fb.setCurrent(endFillBlock)
      sbStoreLen(sbPtr, newLenI64, fb)
      fb.current.setTerminator(Terminator.Br(contLabel))

      val contBlock = fb.newBlock(contLabel)
      fb.setCurrent(contBlock)
      Value.IntConst(0L, Type.I64)
    }

    private def emitStringBuilderToString(argsTuple: Value, fb: FunBuilder): Value = {
      val sbPtr = loadTupleElement(argsTuple, 1, SimpleType.StringBuilderHandle, fb)
      val lenI64 = sbLenI64(sbPtr, fb)
      val dataPtr = sbDataPtr(sbPtr, fb)

      val strPtr = allocString(lenI64, fb)

      val iPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(iPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(Value.IntConst(0L, Type.I64), iPtr)

      val loopLabel = freshLabel("sbtos_loop")
      val bodyLabel = freshLabel("sbtos_body")
      val endLabel = freshLabel("sbtos_end")
      fb.current.setTerminator(Terminator.Br(loopLabel))

      val loopBlock = fb.newBlock(loopLabel)
      fb.setCurrent(loopBlock)
      val iVal = freshTmp(Type.I64)
      fb.current.emitAssign(iVal, Op.Load(Type.I64, iPtr))
      val cond = freshTmp(Type.I1)
      fb.current.emitAssign(cond, Op.ICmp("slt", iVal, lenI64))
      fb.current.setTerminator(Terminator.CondBr(cond, bodyLabel, endLabel))

      val bodyBlock = fb.newBlock(bodyLabel)
      fb.setCurrent(bodyBlock)
      val payload = loadI64Slot(dataPtr, iVal, fb)
      val slotIdx = freshTmp(Type.I64)
      fb.current.emitAssign(slotIdx, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
      storeI64Slot(strPtr, slotIdx, payload, fb)
      val iNext = freshTmp(Type.I64)
      fb.current.emitAssign(iNext, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(iNext, iPtr)
      fb.current.setTerminator(Terminator.Br(loopLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      strPtr
    }

    private def emitTrimBounds(strPtr0: Value, fb: FunBuilder): (Value, Value) = {
      val strPtr = castValue(strPtr0, Type.Ptr, fb)
      val lenI64 = stringLenI64(strPtr, fb)

      val iPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(iPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(Value.IntConst(0L, Type.I64), iPtr)

      val lLoopLabel = freshLabel("triml_loop")
      val lCheckLabel = freshLabel("triml_check")
      val lIncLabel = freshLabel("triml_inc")
      val lDoneLabel = freshLabel("triml_done")
      fb.current.setTerminator(Terminator.Br(lLoopLabel))

      val lLoopBlock = fb.newBlock(lLoopLabel)
      fb.setCurrent(lLoopBlock)
      val iVal = freshTmp(Type.I64)
      fb.current.emitAssign(iVal, Op.Load(Type.I64, iPtr))
      val inRange = freshTmp(Type.I1)
      fb.current.emitAssign(inRange, Op.ICmp("slt", iVal, lenI64))
      fb.current.setTerminator(Terminator.CondBr(inRange, lCheckLabel, lDoneLabel))

      val lCheckBlock = fb.newBlock(lCheckLabel)
      fb.setCurrent(lCheckBlock)
      val ch = stringCharPayloadI64(strPtr, iVal, fb)
      val isWs = freshTmp(Type.I1)
      fb.current.emitAssign(isWs, Op.ICmp("sle", ch, Value.IntConst(32L, Type.I64)))
      fb.current.setTerminator(Terminator.CondBr(isWs, lIncLabel, lDoneLabel))

      val lIncBlock = fb.newBlock(lIncLabel)
      fb.setCurrent(lIncBlock)
      val iNext = freshTmp(Type.I64)
      fb.current.emitAssign(iNext, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(iNext, iPtr)
      fb.current.setTerminator(Terminator.Br(lLoopLabel))

      val lDoneBlock = fb.newBlock(lDoneLabel)
      fb.setCurrent(lDoneBlock)
      val start = freshTmp(Type.I64)
      fb.current.emitAssign(start, Op.Load(Type.I64, iPtr))

      val jPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(jPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(lenI64, jPtr)

      val rLoopLabel = freshLabel("trimr_loop")
      val rCheckLabel = freshLabel("trimr_check")
      val rDecLabel = freshLabel("trimr_dec")
      val rDoneLabel = freshLabel("trimr_done")
      fb.current.setTerminator(Terminator.Br(rLoopLabel))

      val rLoopBlock = fb.newBlock(rLoopLabel)
      fb.setCurrent(rLoopBlock)
      val jVal = freshTmp(Type.I64)
      fb.current.emitAssign(jVal, Op.Load(Type.I64, jPtr))
      val gtStart = freshTmp(Type.I1)
      fb.current.emitAssign(gtStart, Op.ICmp("sgt", jVal, start))
      fb.current.setTerminator(Terminator.CondBr(gtStart, rCheckLabel, rDoneLabel))

      val rCheckBlock = fb.newBlock(rCheckLabel)
      fb.setCurrent(rCheckBlock)
      val jMinus1 = freshTmp(Type.I64)
      fb.current.emitAssign(jMinus1, Op.Bin("sub", Type.I64, jVal, Value.IntConst(1L, Type.I64)))
      val ch2 = stringCharPayloadI64(strPtr, jMinus1, fb)
      val isWs2 = freshTmp(Type.I1)
      fb.current.emitAssign(isWs2, Op.ICmp("sle", ch2, Value.IntConst(32L, Type.I64)))
      fb.current.setTerminator(Terminator.CondBr(isWs2, rDecLabel, rDoneLabel))

      val rDecBlock = fb.newBlock(rDecLabel)
      fb.setCurrent(rDecBlock)
      val jNext = freshTmp(Type.I64)
      fb.current.emitAssign(jNext, Op.Bin("sub", Type.I64, jVal, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(jNext, jPtr)
      fb.current.setTerminator(Terminator.Br(rLoopLabel))

      val rDoneBlock = fb.newBlock(rDoneLabel)
      fb.setCurrent(rDoneBlock)
      val end = freshTmp(Type.I64)
      fb.current.emitAssign(end, Op.Load(Type.I64, jPtr))
      (start, end)
    }

    private def emitParseIntTuple(strPtr0: Value, radixI64: Value, minVal: Long, maxVal: Long, fb: FunBuilder): Value = {
      val strPtr = castValue(strPtr0, Type.Ptr, fb)
      val (start, end) = emitTrimBounds(strPtr, fb)

      val okPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(okPtr, Op.Alloca(Type.I1))
      fb.current.emitStore(Value.IntConst(0L, Type.I1), okPtr)

      val resPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(resPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(Value.IntConst(0L, Type.I64), resPtr)

      val badLow = freshTmp(Type.I1)
      fb.current.emitAssign(badLow, Op.ICmp("slt", radixI64, Value.IntConst(2L, Type.I64)))
      val badHigh = freshTmp(Type.I1)
      fb.current.emitAssign(badHigh, Op.ICmp("sgt", radixI64, Value.IntConst(36L, Type.I64)))
      val radixBad = freshTmp(Type.I1)
      fb.current.emitAssign(radixBad, Op.Bin("or", Type.I1, badLow, badHigh))

      val empty = freshTmp(Type.I1)
      fb.current.emitAssign(empty, Op.ICmp("sge", start, end))

      val fail0 = freshTmp(Type.I1)
      fb.current.emitAssign(fail0, Op.Bin("or", Type.I1, radixBad, empty))

      val failLabel = freshLabel("parsei_fail")
      val signLabel = freshLabel("parsei_sign")
      val endLabel = freshLabel("parsei_end")
      fb.current.setTerminator(Terminator.CondBr(fail0, failLabel, signLabel))

      val failBlock = fb.newBlock(failLabel)
      fb.setCurrent(failBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))

      val signBlock = fb.newBlock(signLabel)
      fb.setCurrent(signBlock)

      val idxPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(idxPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(start, idxPtr)

      val negPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(negPtr, Op.Alloca(Type.I1))
      fb.current.emitStore(Value.IntConst(0L, Type.I1), negPtr)

      val idxVal0 = freshTmp(Type.I64)
      fb.current.emitAssign(idxVal0, Op.Load(Type.I64, idxPtr))
      val ch0 = stringCharPayloadI64(strPtr, idxVal0, fb)
      val isMinus = freshTmp(Type.I1)
      fb.current.emitAssign(isMinus, Op.ICmp("eq", ch0, Value.IntConst(45L, Type.I64)))
      val isPlus = freshTmp(Type.I1)
      fb.current.emitAssign(isPlus, Op.ICmp("eq", ch0, Value.IntConst(43L, Type.I64)))
      val isSign = freshTmp(Type.I1)
      fb.current.emitAssign(isSign, Op.Bin("or", Type.I1, isMinus, isPlus))

      val consumeLabel = freshLabel("parsei_consume")
      val afterSignLabel = freshLabel("parsei_aftersign")
      fb.current.setTerminator(Terminator.CondBr(isSign, consumeLabel, afterSignLabel))

      val consumeBlock = fb.newBlock(consumeLabel)
      fb.setCurrent(consumeBlock)
      val minusLabel = freshLabel("parsei_minus")
      val plusLabel = freshLabel("parsei_plus")
      val setIdxLabel = freshLabel("parsei_setidx")
      fb.current.setTerminator(Terminator.CondBr(isMinus, minusLabel, plusLabel))

      val minusBlock = fb.newBlock(minusLabel)
      fb.setCurrent(minusBlock)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), negPtr)
      fb.current.setTerminator(Terminator.Br(setIdxLabel))

      val plusBlock = fb.newBlock(plusLabel)
      fb.setCurrent(plusBlock)
      fb.current.setTerminator(Terminator.Br(setIdxLabel))

      val setIdxBlock = fb.newBlock(setIdxLabel)
      fb.setCurrent(setIdxBlock)
      val idxNext = freshTmp(Type.I64)
      fb.current.emitAssign(idxNext, Op.Bin("add", Type.I64, idxVal0, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(idxNext, idxPtr)
      fb.current.setTerminator(Terminator.Br(afterSignLabel))

      val afterSignBlock = fb.newBlock(afterSignLabel)
      fb.setCurrent(afterSignBlock)
      val idxVal1 = freshTmp(Type.I64)
      fb.current.emitAssign(idxVal1, Op.Load(Type.I64, idxPtr))
      val emptyAfterSign = freshTmp(Type.I1)
      fb.current.emitAssign(emptyAfterSign, Op.ICmp("sge", idxVal1, end))

      val setupLabel = freshLabel("parsei_setup")
      fb.current.setTerminator(Terminator.CondBr(emptyAfterSign, failLabel, setupLabel))

      val setupBlock = fb.newBlock(setupLabel)
      fb.setCurrent(setupBlock)

      val negFlag = freshTmp(Type.I1)
      fb.current.emitAssign(negFlag, Op.Load(Type.I1, negPtr))

      val limitPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(limitPtr, Op.Alloca(Type.I64))

      val limitNegLabel = freshLabel("parsei_limit_neg")
      val limitPosLabel = freshLabel("parsei_limit_pos")
      val limitDoneLabel = freshLabel("parsei_limit_done")
      fb.current.setTerminator(Terminator.CondBr(negFlag, limitNegLabel, limitPosLabel))

      val limitNegBlock = fb.newBlock(limitNegLabel)
      fb.setCurrent(limitNegBlock)
      fb.current.emitStore(Value.IntConst(minVal, Type.I64), limitPtr)
      fb.current.setTerminator(Terminator.Br(limitDoneLabel))

      val limitPosBlock = fb.newBlock(limitPosLabel)
      fb.setCurrent(limitPosBlock)
      fb.current.emitStore(Value.IntConst(-maxVal, Type.I64), limitPtr)
      fb.current.setTerminator(Terminator.Br(limitDoneLabel))

      val limitDoneBlock = fb.newBlock(limitDoneLabel)
      fb.setCurrent(limitDoneBlock)
      val limitVal = freshTmp(Type.I64)
      fb.current.emitAssign(limitVal, Op.Load(Type.I64, limitPtr))
      val multmin = freshTmp(Type.I64)
      fb.current.emitAssign(multmin, Op.Bin("sdiv", Type.I64, limitVal, radixI64))

      fb.current.emitStore(Value.IntConst(0L, Type.I64), resPtr)

      val hasDigitPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(hasDigitPtr, Op.Alloca(Type.I1))
      fb.current.emitStore(Value.IntConst(0L, Type.I1), hasDigitPtr)

      val digitPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(digitPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(Value.IntConst(-1L, Type.I64), digitPtr)

      val loopLabel = freshLabel("parsei_loop")
      val bodyLabel = freshLabel("parsei_body")
      val afterLoopLabel = freshLabel("parsei_after")
      fb.current.setTerminator(Terminator.Br(loopLabel))

      val loopBlock = fb.newBlock(loopLabel)
      fb.setCurrent(loopBlock)
      val idxVal = freshTmp(Type.I64)
      fb.current.emitAssign(idxVal, Op.Load(Type.I64, idxPtr))
      val inRange = freshTmp(Type.I1)
      fb.current.emitAssign(inRange, Op.ICmp("slt", idxVal, end))
      fb.current.setTerminator(Terminator.CondBr(inRange, bodyLabel, afterLoopLabel))

      val bodyBlock = fb.newBlock(bodyLabel)
      fb.setCurrent(bodyBlock)
      val ch = stringCharPayloadI64(strPtr, idxVal, fb)

      val isNumLo = freshTmp(Type.I1)
      fb.current.emitAssign(isNumLo, Op.ICmp("sge", ch, Value.IntConst(48L, Type.I64)))
      val isNumHi = freshTmp(Type.I1)
      fb.current.emitAssign(isNumHi, Op.ICmp("sle", ch, Value.IntConst(57L, Type.I64)))
      val isNum = freshTmp(Type.I1)
      fb.current.emitAssign(isNum, Op.Bin("and", Type.I1, isNumLo, isNumHi))

      val isLowerLo = freshTmp(Type.I1)
      fb.current.emitAssign(isLowerLo, Op.ICmp("sge", ch, Value.IntConst(97L, Type.I64)))
      val isLowerHi = freshTmp(Type.I1)
      fb.current.emitAssign(isLowerHi, Op.ICmp("sle", ch, Value.IntConst(122L, Type.I64)))
      val isLower = freshTmp(Type.I1)
      fb.current.emitAssign(isLower, Op.Bin("and", Type.I1, isLowerLo, isLowerHi))

      val isUpperLo = freshTmp(Type.I1)
      fb.current.emitAssign(isUpperLo, Op.ICmp("sge", ch, Value.IntConst(65L, Type.I64)))
      val isUpperHi = freshTmp(Type.I1)
      fb.current.emitAssign(isUpperHi, Op.ICmp("sle", ch, Value.IntConst(90L, Type.I64)))
      val isUpper = freshTmp(Type.I1)
      fb.current.emitAssign(isUpper, Op.Bin("and", Type.I1, isUpperLo, isUpperHi))

      val digitNumLabel = freshLabel("parsei_digit_num")
      val digitCheckLowerLabel = freshLabel("parsei_digit_check_lower")
      val digitLowerLabel = freshLabel("parsei_digit_lower")
      val digitCheckUpperLabel = freshLabel("parsei_digit_check_upper")
      val digitUpperLabel = freshLabel("parsei_digit_upper")
      val digitBadLabel = freshLabel("parsei_digit_bad")
      val digitDoneLabel = freshLabel("parsei_digit_done")

      fb.current.setTerminator(Terminator.CondBr(isNum, digitNumLabel, digitCheckLowerLabel))

      val digitNumBlock = fb.newBlock(digitNumLabel)
      fb.setCurrent(digitNumBlock)
      val digitNum = freshTmp(Type.I64)
      fb.current.emitAssign(digitNum, Op.Bin("sub", Type.I64, ch, Value.IntConst(48L, Type.I64)))
      fb.current.emitStore(digitNum, digitPtr)
      fb.current.setTerminator(Terminator.Br(digitDoneLabel))

      val digitCheckLowerBlock = fb.newBlock(digitCheckLowerLabel)
      fb.setCurrent(digitCheckLowerBlock)
      fb.current.setTerminator(Terminator.CondBr(isLower, digitLowerLabel, digitCheckUpperLabel))

      val digitLowerBlock = fb.newBlock(digitLowerLabel)
      fb.setCurrent(digitLowerBlock)
      val digitLower0 = freshTmp(Type.I64)
      fb.current.emitAssign(digitLower0, Op.Bin("sub", Type.I64, ch, Value.IntConst(97L, Type.I64)))
      val digitLower = freshTmp(Type.I64)
      fb.current.emitAssign(digitLower, Op.Bin("add", Type.I64, digitLower0, Value.IntConst(10L, Type.I64)))
      fb.current.emitStore(digitLower, digitPtr)
      fb.current.setTerminator(Terminator.Br(digitDoneLabel))

      val digitCheckUpperBlock = fb.newBlock(digitCheckUpperLabel)
      fb.setCurrent(digitCheckUpperBlock)
      fb.current.setTerminator(Terminator.CondBr(isUpper, digitUpperLabel, digitBadLabel))

      val digitUpperBlock = fb.newBlock(digitUpperLabel)
      fb.setCurrent(digitUpperBlock)
      val digitUpper0 = freshTmp(Type.I64)
      fb.current.emitAssign(digitUpper0, Op.Bin("sub", Type.I64, ch, Value.IntConst(65L, Type.I64)))
      val digitUpper = freshTmp(Type.I64)
      fb.current.emitAssign(digitUpper, Op.Bin("add", Type.I64, digitUpper0, Value.IntConst(10L, Type.I64)))
      fb.current.emitStore(digitUpper, digitPtr)
      fb.current.setTerminator(Terminator.Br(digitDoneLabel))

      val digitBadBlock = fb.newBlock(digitBadLabel)
      fb.setCurrent(digitBadBlock)
      fb.current.emitStore(Value.IntConst(-1L, Type.I64), digitPtr)
      fb.current.setTerminator(Terminator.Br(digitDoneLabel))

      val digitDoneBlock = fb.newBlock(digitDoneLabel)
      fb.setCurrent(digitDoneBlock)
      val digitVal = freshTmp(Type.I64)
      fb.current.emitAssign(digitVal, Op.Load(Type.I64, digitPtr))

      val nonNeg = freshTmp(Type.I1)
      fb.current.emitAssign(nonNeg, Op.ICmp("sge", digitVal, Value.IntConst(0L, Type.I64)))
      val ltRadix = freshTmp(Type.I1)
      fb.current.emitAssign(ltRadix, Op.ICmp("slt", digitVal, radixI64))
      val digitOk = freshTmp(Type.I1)
      fb.current.emitAssign(digitOk, Op.Bin("and", Type.I1, nonNeg, ltRadix))

      val overflow1Label = freshLabel("parsei_ovf1")
      val updateLabel = freshLabel("parsei_update")
      fb.current.setTerminator(Terminator.CondBr(digitOk, overflow1Label, failLabel))

      val overflow1Block = fb.newBlock(overflow1Label)
      fb.setCurrent(overflow1Block)
      val resVal = freshTmp(Type.I64)
      fb.current.emitAssign(resVal, Op.Load(Type.I64, resPtr))
      val ovf1 = freshTmp(Type.I1)
      fb.current.emitAssign(ovf1, Op.ICmp("slt", resVal, multmin))

      val overflow2Label = freshLabel("parsei_ovf2")
      fb.current.setTerminator(Terminator.CondBr(ovf1, failLabel, overflow2Label))

      val overflow2Block = fb.newBlock(overflow2Label)
      fb.setCurrent(overflow2Block)
      val resMul = freshTmp(Type.I64)
      fb.current.emitAssign(resMul, Op.Bin("mul", Type.I64, resVal, radixI64))
      val limitPlusDigit = freshTmp(Type.I64)
      fb.current.emitAssign(limitPlusDigit, Op.Bin("add", Type.I64, limitVal, digitVal))
      val ovf2 = freshTmp(Type.I1)
      fb.current.emitAssign(ovf2, Op.ICmp("slt", resMul, limitPlusDigit))
      fb.current.setTerminator(Terminator.CondBr(ovf2, failLabel, updateLabel))

      val updateBlock = fb.newBlock(updateLabel)
      fb.setCurrent(updateBlock)
      val resNext = freshTmp(Type.I64)
      fb.current.emitAssign(resNext, Op.Bin("sub", Type.I64, resMul, digitVal))
      fb.current.emitStore(resNext, resPtr)
      val idxNext2 = freshTmp(Type.I64)
      fb.current.emitAssign(idxNext2, Op.Bin("add", Type.I64, idxVal, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(idxNext2, idxPtr)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), hasDigitPtr)
      fb.current.setTerminator(Terminator.Br(loopLabel))

      val afterLoopBlock = fb.newBlock(afterLoopLabel)
      fb.setCurrent(afterLoopBlock)
      val hasDigit = freshTmp(Type.I1)
      fb.current.emitAssign(hasDigit, Op.Load(Type.I1, hasDigitPtr))

      val finalizeLabel = freshLabel("parsei_finalize")
      fb.current.setTerminator(Terminator.CondBr(hasDigit, finalizeLabel, failLabel))

      val finalizeBlock = fb.newBlock(finalizeLabel)
      fb.setCurrent(finalizeBlock)
      val resNeg = freshTmp(Type.I64)
      fb.current.emitAssign(resNeg, Op.Load(Type.I64, resPtr))
      val negFlag2 = freshTmp(Type.I1)
      fb.current.emitAssign(negFlag2, Op.Load(Type.I1, negPtr))

      val keepLabel = freshLabel("parsei_keep")
      val flipLabel = freshLabel("parsei_flip")
      val doneLabel = freshLabel("parsei_done")
      fb.current.setTerminator(Terminator.CondBr(negFlag2, keepLabel, flipLabel))

      val keepBlock = fb.newBlock(keepLabel)
      fb.setCurrent(keepBlock)
      fb.current.emitStore(resNeg, resPtr)
      fb.current.setTerminator(Terminator.Br(doneLabel))

      val flipBlock = fb.newBlock(flipLabel)
      fb.setCurrent(flipBlock)
      val resPos = freshTmp(Type.I64)
      fb.current.emitAssign(resPos, Op.Bin("sub", Type.I64, Value.IntConst(0L, Type.I64), resNeg))
      fb.current.emitStore(resPos, resPtr)
      fb.current.setTerminator(Terminator.Br(doneLabel))

      val doneBlock = fb.newBlock(doneLabel)
      fb.setCurrent(doneBlock)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), okPtr)
      fb.current.setTerminator(Terminator.Br(endLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      val ok = freshTmp(Type.I1)
      fb.current.emitAssign(ok, Op.Load(Type.I1, okPtr))
      val okPayload = freshTmp(Type.I64)
      fb.current.emitAssign(okPayload, Op.Cast("zext", Type.I64, ok))
      val resPayload = freshTmp(Type.I64)
      fb.current.emitAssign(resPayload, Op.Load(Type.I64, resPtr))
      allocTuple2(okPayload, resPayload, fb)
    }

    private def emitParseFloatTuple(strPtr0: Value, is32: Boolean, fb: FunBuilder): Value = {
      val strPtr = castValue(strPtr0, Type.Ptr, fb)
      val (start, end) = emitTrimBounds(strPtr, fb)

      val ten = Value.Float64Const(java.lang.Double.doubleToRawLongBits(10.0))
      val zeroD = Value.Float64Const(java.lang.Double.doubleToRawLongBits(0.0))
      val nanD = Value.Float64Const(java.lang.Double.doubleToRawLongBits(java.lang.Double.NaN))
      val posInfD = Value.Float64Const(java.lang.Double.doubleToRawLongBits(java.lang.Double.POSITIVE_INFINITY))
      val negInfD = Value.Float64Const(java.lang.Double.doubleToRawLongBits(java.lang.Double.NEGATIVE_INFINITY))

      val okPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(okPtr, Op.Alloca(Type.I1))
      fb.current.emitStore(Value.IntConst(0L, Type.I1), okPtr)

      val valuePtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(valuePtr, Op.Alloca(Type.Double))
      fb.current.emitStore(zeroD, valuePtr)

      val idxPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(idxPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(start, idxPtr)

      val negPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(negPtr, Op.Alloca(Type.I1))
      fb.current.emitStore(Value.IntConst(0L, Type.I1), negPtr)

      val hasDigitPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(hasDigitPtr, Op.Alloca(Type.I1))
      fb.current.emitStore(Value.IntConst(0L, Type.I1), hasDigitPtr)

      val fracDigitsPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(fracDigitsPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(Value.IntConst(0L, Type.I64), fracDigitsPtr)

      val empty = freshTmp(Type.I1)
      fb.current.emitAssign(empty, Op.ICmp("sge", start, end))

      val failLabel = freshLabel("parsef_fail")
      val specialLabel = freshLabel("parsef_special")
      val signLabel = freshLabel("parsef_sign")
      val endLabel = freshLabel("parsef_end")
      fb.current.setTerminator(Terminator.CondBr(empty, failLabel, specialLabel))

      val failBlock = fb.newBlock(failLabel)
      fb.setCurrent(failBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))

      // Special values: NaN / Infinity.
      val specialBlock = fb.newBlock(specialLabel)
      fb.setCurrent(specialBlock)
      val len = freshTmp(Type.I64)
      fb.current.emitAssign(len, Op.Bin("sub", Type.I64, end, start))

      val len3Check = freshTmp(Type.I1)
      fb.current.emitAssign(len3Check, Op.ICmp("eq", len, Value.IntConst(3L, Type.I64)))
      val len3Label = freshLabel("parsef_len3")
      val len4CheckLabel = freshLabel("parsef_len4_check")
      fb.current.setTerminator(Terminator.CondBr(len3Check, len3Label, len4CheckLabel))

      // len == 3: "NaN"
      val len3Block = fb.newBlock(len3Label)
      fb.setCurrent(len3Block)
      val n0 = stringCharPayloadI64(strPtr, start, fb)
      val n1Idx = freshTmp(Type.I64)
      fb.current.emitAssign(n1Idx, Op.Bin("add", Type.I64, start, Value.IntConst(1L, Type.I64)))
      val n1 = stringCharPayloadI64(strPtr, n1Idx, fb)
      val n2Idx = freshTmp(Type.I64)
      fb.current.emitAssign(n2Idx, Op.Bin("add", Type.I64, start, Value.IntConst(2L, Type.I64)))
      val n2 = stringCharPayloadI64(strPtr, n2Idx, fb)

      val n0Ok = freshTmp(Type.I1)
      fb.current.emitAssign(n0Ok, Op.ICmp("eq", n0, Value.IntConst(78L, Type.I64))) // 'N'
      val n1Ok = freshTmp(Type.I1)
      fb.current.emitAssign(n1Ok, Op.ICmp("eq", n1, Value.IntConst(97L, Type.I64))) // 'a'
      val n2Ok = freshTmp(Type.I1)
      fb.current.emitAssign(n2Ok, Op.ICmp("eq", n2, Value.IntConst(78L, Type.I64))) // 'N'
      val nanOk3a = freshTmp(Type.I1)
      fb.current.emitAssign(nanOk3a, Op.Bin("and", Type.I1, n0Ok, n1Ok))
      val nanOk3 = freshTmp(Type.I1)
      fb.current.emitAssign(nanOk3, Op.Bin("and", Type.I1, nanOk3a, n2Ok))

      val nanHitLabel = freshLabel("parsef_nan_hit")
      fb.current.setTerminator(Terminator.CondBr(nanOk3, nanHitLabel, signLabel))

      // len == 4: [+|-] "NaN"
      val len4CheckBlock = fb.newBlock(len4CheckLabel)
      fb.setCurrent(len4CheckBlock)
      val len4Check = freshTmp(Type.I1)
      fb.current.emitAssign(len4Check, Op.ICmp("eq", len, Value.IntConst(4L, Type.I64)))
      val len4Label = freshLabel("parsef_len4")
      val len8CheckLabel = freshLabel("parsef_len8_check")
      fb.current.setTerminator(Terminator.CondBr(len4Check, len4Label, len8CheckLabel))

      val len4Block = fb.newBlock(len4Label)
      fb.setCurrent(len4Block)
      val s0 = stringCharPayloadI64(strPtr, start, fb)
      val s0IsMinus = freshTmp(Type.I1)
      fb.current.emitAssign(s0IsMinus, Op.ICmp("eq", s0, Value.IntConst(45L, Type.I64))) // '-'
      val s0IsPlus = freshTmp(Type.I1)
      fb.current.emitAssign(s0IsPlus, Op.ICmp("eq", s0, Value.IntConst(43L, Type.I64))) // '+'
      val s0IsSign = freshTmp(Type.I1)
      fb.current.emitAssign(s0IsSign, Op.Bin("or", Type.I1, s0IsMinus, s0IsPlus))

      val n1sIdx = freshTmp(Type.I64)
      fb.current.emitAssign(n1sIdx, Op.Bin("add", Type.I64, start, Value.IntConst(1L, Type.I64)))
      val n1s = stringCharPayloadI64(strPtr, n1sIdx, fb)
      val n2sIdx = freshTmp(Type.I64)
      fb.current.emitAssign(n2sIdx, Op.Bin("add", Type.I64, start, Value.IntConst(2L, Type.I64)))
      val n2s = stringCharPayloadI64(strPtr, n2sIdx, fb)
      val n3sIdx = freshTmp(Type.I64)
      fb.current.emitAssign(n3sIdx, Op.Bin("add", Type.I64, start, Value.IntConst(3L, Type.I64)))
      val n3s = stringCharPayloadI64(strPtr, n3sIdx, fb)

      val n1sOk = freshTmp(Type.I1)
      fb.current.emitAssign(n1sOk, Op.ICmp("eq", n1s, Value.IntConst(78L, Type.I64))) // 'N'
      val n2sOk = freshTmp(Type.I1)
      fb.current.emitAssign(n2sOk, Op.ICmp("eq", n2s, Value.IntConst(97L, Type.I64))) // 'a'
      val n3sOk = freshTmp(Type.I1)
      fb.current.emitAssign(n3sOk, Op.ICmp("eq", n3s, Value.IntConst(78L, Type.I64))) // 'N'
      val nanOk4a = freshTmp(Type.I1)
      fb.current.emitAssign(nanOk4a, Op.Bin("and", Type.I1, n1sOk, n2sOk))
      val nanOk4b = freshTmp(Type.I1)
      fb.current.emitAssign(nanOk4b, Op.Bin("and", Type.I1, nanOk4a, n3sOk))
      val nanOk4 = freshTmp(Type.I1)
      fb.current.emitAssign(nanOk4, Op.Bin("and", Type.I1, s0IsSign, nanOk4b))
      fb.current.setTerminator(Terminator.CondBr(nanOk4, nanHitLabel, signLabel))

      val nanHitBlock = fb.newBlock(nanHitLabel)
      fb.setCurrent(nanHitBlock)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), okPtr)
      fb.current.emitStore(nanD, valuePtr)
      fb.current.setTerminator(Terminator.Br(endLabel))

      // len == 8: "Infinity"
      val len8CheckBlock = fb.newBlock(len8CheckLabel)
      fb.setCurrent(len8CheckBlock)
      val len8Check = freshTmp(Type.I1)
      fb.current.emitAssign(len8Check, Op.ICmp("eq", len, Value.IntConst(8L, Type.I64)))
      val len8Label = freshLabel("parsef_len8")
      val len9CheckLabel = freshLabel("parsef_len9_check")
      fb.current.setTerminator(Terminator.CondBr(len8Check, len8Label, len9CheckLabel))

      val posInfHitLabel = freshLabel("parsef_posinf_hit")
      val negInfHitLabel = freshLabel("parsef_neginf_hit")

      val len8Block = fb.newBlock(len8Label)
      fb.setCurrent(len8Block)
      val i0 = stringCharPayloadI64(strPtr, start, fb)
      val i1Idx = freshTmp(Type.I64)
      fb.current.emitAssign(i1Idx, Op.Bin("add", Type.I64, start, Value.IntConst(1L, Type.I64)))
      val i1 = stringCharPayloadI64(strPtr, i1Idx, fb)
      val i2Idx = freshTmp(Type.I64)
      fb.current.emitAssign(i2Idx, Op.Bin("add", Type.I64, start, Value.IntConst(2L, Type.I64)))
      val i2 = stringCharPayloadI64(strPtr, i2Idx, fb)
      val i3Idx = freshTmp(Type.I64)
      fb.current.emitAssign(i3Idx, Op.Bin("add", Type.I64, start, Value.IntConst(3L, Type.I64)))
      val i3 = stringCharPayloadI64(strPtr, i3Idx, fb)
      val i4Idx = freshTmp(Type.I64)
      fb.current.emitAssign(i4Idx, Op.Bin("add", Type.I64, start, Value.IntConst(4L, Type.I64)))
      val i4 = stringCharPayloadI64(strPtr, i4Idx, fb)
      val i5Idx = freshTmp(Type.I64)
      fb.current.emitAssign(i5Idx, Op.Bin("add", Type.I64, start, Value.IntConst(5L, Type.I64)))
      val i5 = stringCharPayloadI64(strPtr, i5Idx, fb)
      val i6Idx = freshTmp(Type.I64)
      fb.current.emitAssign(i6Idx, Op.Bin("add", Type.I64, start, Value.IntConst(6L, Type.I64)))
      val i6 = stringCharPayloadI64(strPtr, i6Idx, fb)
      val i7Idx = freshTmp(Type.I64)
      fb.current.emitAssign(i7Idx, Op.Bin("add", Type.I64, start, Value.IntConst(7L, Type.I64)))
      val i7 = stringCharPayloadI64(strPtr, i7Idx, fb)

      val inf0 = freshTmp(Type.I1)
      fb.current.emitAssign(inf0, Op.ICmp("eq", i0, Value.IntConst(73L, Type.I64))) // 'I'
      val inf1 = freshTmp(Type.I1)
      fb.current.emitAssign(inf1, Op.ICmp("eq", i1, Value.IntConst(110L, Type.I64))) // 'n'
      val inf2 = freshTmp(Type.I1)
      fb.current.emitAssign(inf2, Op.ICmp("eq", i2, Value.IntConst(102L, Type.I64))) // 'f'
      val inf3 = freshTmp(Type.I1)
      fb.current.emitAssign(inf3, Op.ICmp("eq", i3, Value.IntConst(105L, Type.I64))) // 'i'
      val inf4 = freshTmp(Type.I1)
      fb.current.emitAssign(inf4, Op.ICmp("eq", i4, Value.IntConst(110L, Type.I64))) // 'n'
      val inf5 = freshTmp(Type.I1)
      fb.current.emitAssign(inf5, Op.ICmp("eq", i5, Value.IntConst(105L, Type.I64))) // 'i'
      val inf6 = freshTmp(Type.I1)
      fb.current.emitAssign(inf6, Op.ICmp("eq", i6, Value.IntConst(116L, Type.I64))) // 't'
      val inf7 = freshTmp(Type.I1)
      fb.current.emitAssign(inf7, Op.ICmp("eq", i7, Value.IntConst(121L, Type.I64))) // 'y'
      val infA = freshTmp(Type.I1)
      fb.current.emitAssign(infA, Op.Bin("and", Type.I1, inf0, inf1))
      val infB = freshTmp(Type.I1)
      fb.current.emitAssign(infB, Op.Bin("and", Type.I1, infA, inf2))
      val infC = freshTmp(Type.I1)
      fb.current.emitAssign(infC, Op.Bin("and", Type.I1, infB, inf3))
      val infD = freshTmp(Type.I1)
      fb.current.emitAssign(infD, Op.Bin("and", Type.I1, infC, inf4))
      val infE = freshTmp(Type.I1)
      fb.current.emitAssign(infE, Op.Bin("and", Type.I1, infD, inf5))
      val infF = freshTmp(Type.I1)
      fb.current.emitAssign(infF, Op.Bin("and", Type.I1, infE, inf6))
      val infOk8 = freshTmp(Type.I1)
      fb.current.emitAssign(infOk8, Op.Bin("and", Type.I1, infF, inf7))
      fb.current.setTerminator(Terminator.CondBr(infOk8, posInfHitLabel, signLabel))

      // len == 9: [+|-] "Infinity"
      val len9CheckBlock = fb.newBlock(len9CheckLabel)
      fb.setCurrent(len9CheckBlock)
      val len9Check = freshTmp(Type.I1)
      fb.current.emitAssign(len9Check, Op.ICmp("eq", len, Value.IntConst(9L, Type.I64)))
      val len9Label = freshLabel("parsef_len9")
      fb.current.setTerminator(Terminator.CondBr(len9Check, len9Label, signLabel))

      val len9Block = fb.newBlock(len9Label)
      fb.setCurrent(len9Block)
      val si0 = stringCharPayloadI64(strPtr, start, fb)
      val si0IsMinus = freshTmp(Type.I1)
      fb.current.emitAssign(si0IsMinus, Op.ICmp("eq", si0, Value.IntConst(45L, Type.I64))) // '-'
      val si0IsPlus = freshTmp(Type.I1)
      fb.current.emitAssign(si0IsPlus, Op.ICmp("eq", si0, Value.IntConst(43L, Type.I64))) // '+'
      val si0IsSign = freshTmp(Type.I1)
      fb.current.emitAssign(si0IsSign, Op.Bin("or", Type.I1, si0IsMinus, si0IsPlus))

      val signedInfCheckLabel = freshLabel("parsef_signed_inf_check")
      fb.current.setTerminator(Terminator.CondBr(si0IsSign, signedInfCheckLabel, signLabel))

      val signedInfCheckBlock = fb.newBlock(signedInfCheckLabel)
      fb.setCurrent(signedInfCheckBlock)
      val sStart = freshTmp(Type.I64)
      fb.current.emitAssign(sStart, Op.Bin("add", Type.I64, start, Value.IntConst(1L, Type.I64)))
      val si1 = stringCharPayloadI64(strPtr, sStart, fb)
      val si2Idx = freshTmp(Type.I64)
      fb.current.emitAssign(si2Idx, Op.Bin("add", Type.I64, start, Value.IntConst(2L, Type.I64)))
      val si2 = stringCharPayloadI64(strPtr, si2Idx, fb)
      val si3Idx = freshTmp(Type.I64)
      fb.current.emitAssign(si3Idx, Op.Bin("add", Type.I64, start, Value.IntConst(3L, Type.I64)))
      val si3 = stringCharPayloadI64(strPtr, si3Idx, fb)
      val si4Idx = freshTmp(Type.I64)
      fb.current.emitAssign(si4Idx, Op.Bin("add", Type.I64, start, Value.IntConst(4L, Type.I64)))
      val si4 = stringCharPayloadI64(strPtr, si4Idx, fb)
      val si5Idx = freshTmp(Type.I64)
      fb.current.emitAssign(si5Idx, Op.Bin("add", Type.I64, start, Value.IntConst(5L, Type.I64)))
      val si5 = stringCharPayloadI64(strPtr, si5Idx, fb)
      val si6Idx = freshTmp(Type.I64)
      fb.current.emitAssign(si6Idx, Op.Bin("add", Type.I64, start, Value.IntConst(6L, Type.I64)))
      val si6 = stringCharPayloadI64(strPtr, si6Idx, fb)
      val si7Idx = freshTmp(Type.I64)
      fb.current.emitAssign(si7Idx, Op.Bin("add", Type.I64, start, Value.IntConst(7L, Type.I64)))
      val si7 = stringCharPayloadI64(strPtr, si7Idx, fb)
      val si8Idx = freshTmp(Type.I64)
      fb.current.emitAssign(si8Idx, Op.Bin("add", Type.I64, start, Value.IntConst(8L, Type.I64)))
      val si8 = stringCharPayloadI64(strPtr, si8Idx, fb)

      val sInf0 = freshTmp(Type.I1)
      fb.current.emitAssign(sInf0, Op.ICmp("eq", si1, Value.IntConst(73L, Type.I64))) // 'I'
      val sInf1 = freshTmp(Type.I1)
      fb.current.emitAssign(sInf1, Op.ICmp("eq", si2, Value.IntConst(110L, Type.I64))) // 'n'
      val sInf2 = freshTmp(Type.I1)
      fb.current.emitAssign(sInf2, Op.ICmp("eq", si3, Value.IntConst(102L, Type.I64))) // 'f'
      val sInf3 = freshTmp(Type.I1)
      fb.current.emitAssign(sInf3, Op.ICmp("eq", si4, Value.IntConst(105L, Type.I64))) // 'i'
      val sInf4 = freshTmp(Type.I1)
      fb.current.emitAssign(sInf4, Op.ICmp("eq", si5, Value.IntConst(110L, Type.I64))) // 'n'
      val sInf5 = freshTmp(Type.I1)
      fb.current.emitAssign(sInf5, Op.ICmp("eq", si6, Value.IntConst(105L, Type.I64))) // 'i'
      val sInf6 = freshTmp(Type.I1)
      fb.current.emitAssign(sInf6, Op.ICmp("eq", si7, Value.IntConst(116L, Type.I64))) // 't'
      val sInf7 = freshTmp(Type.I1)
      fb.current.emitAssign(sInf7, Op.ICmp("eq", si8, Value.IntConst(121L, Type.I64))) // 'y'
      val sInfA = freshTmp(Type.I1)
      fb.current.emitAssign(sInfA, Op.Bin("and", Type.I1, sInf0, sInf1))
      val sInfB = freshTmp(Type.I1)
      fb.current.emitAssign(sInfB, Op.Bin("and", Type.I1, sInfA, sInf2))
      val sInfC = freshTmp(Type.I1)
      fb.current.emitAssign(sInfC, Op.Bin("and", Type.I1, sInfB, sInf3))
      val sInfD = freshTmp(Type.I1)
      fb.current.emitAssign(sInfD, Op.Bin("and", Type.I1, sInfC, sInf4))
      val sInfE = freshTmp(Type.I1)
      fb.current.emitAssign(sInfE, Op.Bin("and", Type.I1, sInfD, sInf5))
      val sInfF = freshTmp(Type.I1)
      fb.current.emitAssign(sInfF, Op.Bin("and", Type.I1, sInfE, sInf6))
      val sInfOk = freshTmp(Type.I1)
      fb.current.emitAssign(sInfOk, Op.Bin("and", Type.I1, sInfF, sInf7))

      val signedInfOkLabel = freshLabel("parsef_signed_inf_ok")
      fb.current.setTerminator(Terminator.CondBr(sInfOk, signedInfOkLabel, signLabel))

      val signedInfOkBlock = fb.newBlock(signedInfOkLabel)
      fb.setCurrent(signedInfOkBlock)
      fb.current.setTerminator(Terminator.CondBr(si0IsMinus, negInfHitLabel, posInfHitLabel))

      val posInfHitBlock = fb.newBlock(posInfHitLabel)
      fb.setCurrent(posInfHitBlock)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), okPtr)
      fb.current.emitStore(posInfD, valuePtr)
      fb.current.setTerminator(Terminator.Br(endLabel))

      val negInfHitBlock = fb.newBlock(negInfHitLabel)
      fb.setCurrent(negInfHitBlock)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), okPtr)
      fb.current.emitStore(negInfD, valuePtr)
      fb.current.setTerminator(Terminator.Br(endLabel))

      val signBlock = fb.newBlock(signLabel)
      fb.setCurrent(signBlock)

      val idxVal0 = freshTmp(Type.I64)
      fb.current.emitAssign(idxVal0, Op.Load(Type.I64, idxPtr))
      val ch0 = stringCharPayloadI64(strPtr, idxVal0, fb)
      val isMinus = freshTmp(Type.I1)
      fb.current.emitAssign(isMinus, Op.ICmp("eq", ch0, Value.IntConst(45L, Type.I64)))
      val isPlus = freshTmp(Type.I1)
      fb.current.emitAssign(isPlus, Op.ICmp("eq", ch0, Value.IntConst(43L, Type.I64)))
      val isSign = freshTmp(Type.I1)
      fb.current.emitAssign(isSign, Op.Bin("or", Type.I1, isMinus, isPlus))

      val consumeLabel = freshLabel("parsef_consume")
      val afterSignLabel = freshLabel("parsef_aftersign")
      fb.current.setTerminator(Terminator.CondBr(isSign, consumeLabel, afterSignLabel))

      val consumeBlock = fb.newBlock(consumeLabel)
      fb.setCurrent(consumeBlock)
      val minusLabel = freshLabel("parsef_minus")
      val plusLabel = freshLabel("parsef_plus")
      val setIdxLabel = freshLabel("parsef_setidx")
      fb.current.setTerminator(Terminator.CondBr(isMinus, minusLabel, plusLabel))

      val minusBlock = fb.newBlock(minusLabel)
      fb.setCurrent(minusBlock)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), negPtr)
      fb.current.setTerminator(Terminator.Br(setIdxLabel))

      val plusBlock = fb.newBlock(plusLabel)
      fb.setCurrent(plusBlock)
      fb.current.setTerminator(Terminator.Br(setIdxLabel))

      val setIdxBlock = fb.newBlock(setIdxLabel)
      fb.setCurrent(setIdxBlock)
      val idxNext = freshTmp(Type.I64)
      fb.current.emitAssign(idxNext, Op.Bin("add", Type.I64, idxVal0, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(idxNext, idxPtr)
      fb.current.setTerminator(Terminator.Br(afterSignLabel))

      val afterSignBlock = fb.newBlock(afterSignLabel)
      fb.setCurrent(afterSignBlock)
      val idxVal1 = freshTmp(Type.I64)
      fb.current.emitAssign(idxVal1, Op.Load(Type.I64, idxPtr))
      val emptyAfterSign = freshTmp(Type.I1)
      fb.current.emitAssign(emptyAfterSign, Op.ICmp("sge", idxVal1, end))

      val intLoopLabel = freshLabel("parsef_int_loop")
      fb.current.setTerminator(Terminator.CondBr(emptyAfterSign, failLabel, intLoopLabel))

      // Integer digits.
      val intLoopBlock = fb.newBlock(intLoopLabel)
      fb.setCurrent(intLoopBlock)
      val iIdx = freshTmp(Type.I64)
      fb.current.emitAssign(iIdx, Op.Load(Type.I64, idxPtr))
      val inRangeInt = freshTmp(Type.I1)
      fb.current.emitAssign(inRangeInt, Op.ICmp("slt", iIdx, end))
      val intCheckLabel = freshLabel("parsef_int_check")
      val afterIntLabel = freshLabel("parsef_after_int")
      fb.current.setTerminator(Terminator.CondBr(inRangeInt, intCheckLabel, afterIntLabel))

      val intCheckBlock = fb.newBlock(intCheckLabel)
      fb.setCurrent(intCheckBlock)
      val ch = stringCharPayloadI64(strPtr, iIdx, fb)
      val isNumLo = freshTmp(Type.I1)
      fb.current.emitAssign(isNumLo, Op.ICmp("sge", ch, Value.IntConst(48L, Type.I64)))
      val isNumHi = freshTmp(Type.I1)
      fb.current.emitAssign(isNumHi, Op.ICmp("sle", ch, Value.IntConst(57L, Type.I64)))
      val isDigit = freshTmp(Type.I1)
      fb.current.emitAssign(isDigit, Op.Bin("and", Type.I1, isNumLo, isNumHi))
      val intBodyLabel = freshLabel("parsef_int_body")
      fb.current.setTerminator(Terminator.CondBr(isDigit, intBodyLabel, afterIntLabel))

      val intBodyBlock = fb.newBlock(intBodyLabel)
      fb.setCurrent(intBodyBlock)
      val digitI64 = freshTmp(Type.I64)
      fb.current.emitAssign(digitI64, Op.Bin("sub", Type.I64, ch, Value.IntConst(48L, Type.I64)))
      val digitD = freshTmp(Type.Double)
      fb.current.emitAssign(digitD, Op.Cast("sitofp", Type.Double, digitI64))
      val v0 = freshTmp(Type.Double)
      fb.current.emitAssign(v0, Op.Load(Type.Double, valuePtr))
      val vMul = freshTmp(Type.Double)
      fb.current.emitAssign(vMul, Op.Bin("fmul", Type.Double, v0, ten))
      val vNext = freshTmp(Type.Double)
      fb.current.emitAssign(vNext, Op.Bin("fadd", Type.Double, vMul, digitD))
      fb.current.emitStore(vNext, valuePtr)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), hasDigitPtr)
      val iNext = freshTmp(Type.I64)
      fb.current.emitAssign(iNext, Op.Bin("add", Type.I64, iIdx, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(iNext, idxPtr)
      fb.current.setTerminator(Terminator.Br(intLoopLabel))

      // Optional fractional part.
      val afterIntBlock = fb.newBlock(afterIntLabel)
      fb.setCurrent(afterIntBlock)
      val dotIdx = freshTmp(Type.I64)
      fb.current.emitAssign(dotIdx, Op.Load(Type.I64, idxPtr))
      val inRangeDot = freshTmp(Type.I1)
      fb.current.emitAssign(inRangeDot, Op.ICmp("slt", dotIdx, end))
      val dotCheckLabel = freshLabel("parsef_dot_check")
      val afterFracLabel = freshLabel("parsef_after_frac")
      fb.current.setTerminator(Terminator.CondBr(inRangeDot, dotCheckLabel, afterFracLabel))

      val dotCheckBlock = fb.newBlock(dotCheckLabel)
      fb.setCurrent(dotCheckBlock)
      val dotCh = stringCharPayloadI64(strPtr, dotIdx, fb)
      val isDot = freshTmp(Type.I1)
      fb.current.emitAssign(isDot, Op.ICmp("eq", dotCh, Value.IntConst(46L, Type.I64)))
      val dotConsumeLabel = freshLabel("parsef_dot_consume")
      fb.current.setTerminator(Terminator.CondBr(isDot, dotConsumeLabel, afterFracLabel))

      val dotConsumeBlock = fb.newBlock(dotConsumeLabel)
      fb.setCurrent(dotConsumeBlock)
      val dotNext = freshTmp(Type.I64)
      fb.current.emitAssign(dotNext, Op.Bin("add", Type.I64, dotIdx, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(dotNext, idxPtr)

      val fracLoopLabel = freshLabel("parsef_frac_loop")
      fb.current.setTerminator(Terminator.Br(fracLoopLabel))

      val fracLoopBlock = fb.newBlock(fracLoopLabel)
      fb.setCurrent(fracLoopBlock)
      val fIdx = freshTmp(Type.I64)
      fb.current.emitAssign(fIdx, Op.Load(Type.I64, idxPtr))
      val inRangeFrac = freshTmp(Type.I1)
      fb.current.emitAssign(inRangeFrac, Op.ICmp("slt", fIdx, end))
      val fracCheckLabel = freshLabel("parsef_frac_check")
      fb.current.setTerminator(Terminator.CondBr(inRangeFrac, fracCheckLabel, afterFracLabel))

      val fracCheckBlock = fb.newBlock(fracCheckLabel)
      fb.setCurrent(fracCheckBlock)
      val fCh = stringCharPayloadI64(strPtr, fIdx, fb)
      val fNumLo = freshTmp(Type.I1)
      fb.current.emitAssign(fNumLo, Op.ICmp("sge", fCh, Value.IntConst(48L, Type.I64)))
      val fNumHi = freshTmp(Type.I1)
      fb.current.emitAssign(fNumHi, Op.ICmp("sle", fCh, Value.IntConst(57L, Type.I64)))
      val fIsDigit = freshTmp(Type.I1)
      fb.current.emitAssign(fIsDigit, Op.Bin("and", Type.I1, fNumLo, fNumHi))
      val fracBodyLabel = freshLabel("parsef_frac_body")
      fb.current.setTerminator(Terminator.CondBr(fIsDigit, fracBodyLabel, afterFracLabel))

      val fracBodyBlock = fb.newBlock(fracBodyLabel)
      fb.setCurrent(fracBodyBlock)
      val fDigitI64 = freshTmp(Type.I64)
      fb.current.emitAssign(fDigitI64, Op.Bin("sub", Type.I64, fCh, Value.IntConst(48L, Type.I64)))
      val fDigitD = freshTmp(Type.Double)
      fb.current.emitAssign(fDigitD, Op.Cast("sitofp", Type.Double, fDigitI64))
      val fv0 = freshTmp(Type.Double)
      fb.current.emitAssign(fv0, Op.Load(Type.Double, valuePtr))
      val fvMul = freshTmp(Type.Double)
      fb.current.emitAssign(fvMul, Op.Bin("fmul", Type.Double, fv0, ten))
      val fvNext = freshTmp(Type.Double)
      fb.current.emitAssign(fvNext, Op.Bin("fadd", Type.Double, fvMul, fDigitD))
      fb.current.emitStore(fvNext, valuePtr)
      val fd0 = freshTmp(Type.I64)
      fb.current.emitAssign(fd0, Op.Load(Type.I64, fracDigitsPtr))
      val fdNext = freshTmp(Type.I64)
      fb.current.emitAssign(fdNext, Op.Bin("add", Type.I64, fd0, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(fdNext, fracDigitsPtr)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), hasDigitPtr)
      val fIdxNext = freshTmp(Type.I64)
      fb.current.emitAssign(fIdxNext, Op.Bin("add", Type.I64, fIdx, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(fIdxNext, idxPtr)
      fb.current.setTerminator(Terminator.Br(fracLoopLabel))

      // After fraction: require at least one digit overall.
      val afterFracBlock = fb.newBlock(afterFracLabel)
      fb.setCurrent(afterFracBlock)
      val hasDigit = freshTmp(Type.I1)
      fb.current.emitAssign(hasDigit, Op.Load(Type.I1, hasDigitPtr))

      val scaleFracCheckLabel = freshLabel("parsef_scale_check")
      fb.current.setTerminator(Terminator.CondBr(hasDigit, scaleFracCheckLabel, failLabel))

      val scaleFracCheckBlock = fb.newBlock(scaleFracCheckLabel)
      fb.setCurrent(scaleFracCheckBlock)
      val fd = freshTmp(Type.I64)
      fb.current.emitAssign(fd, Op.Load(Type.I64, fracDigitsPtr))
      val hasFrac = freshTmp(Type.I1)
      fb.current.emitAssign(hasFrac, Op.ICmp("sgt", fd, Value.IntConst(0L, Type.I64)))

      val scaleFracLabel = freshLabel("parsef_scale")
      val expCheckLabel = freshLabel("parsef_exp_check")
      fb.current.setTerminator(Terminator.CondBr(hasFrac, scaleFracLabel, expCheckLabel))

      val scaleFracBlock = fb.newBlock(scaleFracLabel)
      fb.setCurrent(scaleFracBlock)
      val fdD = freshTmp(Type.Double)
      fb.current.emitAssign(fdD, Op.Cast("sitofp", Type.Double, fd))
      val pow10 = freshTmp(Type.Double)
      fb.current.emitAssign(pow10, Op.Call(Type.Double, "llvm.pow.f64", List(ten, fdD)))
      val vRaw = freshTmp(Type.Double)
      fb.current.emitAssign(vRaw, Op.Load(Type.Double, valuePtr))
      val vScaled = freshTmp(Type.Double)
      fb.current.emitAssign(vScaled, Op.Bin("fdiv", Type.Double, vRaw, pow10))
      fb.current.emitStore(vScaled, valuePtr)
      fb.current.setTerminator(Terminator.Br(expCheckLabel))

      // Optional exponent.
      val expCheckBlock = fb.newBlock(expCheckLabel)
      fb.setCurrent(expCheckBlock)
      val eIdx = freshTmp(Type.I64)
      fb.current.emitAssign(eIdx, Op.Load(Type.I64, idxPtr))
      val inRangeE = freshTmp(Type.I1)
      fb.current.emitAssign(inRangeE, Op.ICmp("slt", eIdx, end))
      val expCharLabel = freshLabel("parsef_exp_char")
      val finishLabel = freshLabel("parsef_finish")
      fb.current.setTerminator(Terminator.CondBr(inRangeE, expCharLabel, finishLabel))

      val expCharBlock = fb.newBlock(expCharLabel)
      fb.setCurrent(expCharBlock)
      val eCh = stringCharPayloadI64(strPtr, eIdx, fb)
      val isLowerE = freshTmp(Type.I1)
      fb.current.emitAssign(isLowerE, Op.ICmp("eq", eCh, Value.IntConst(101L, Type.I64))) // 'e'
      val isUpperE = freshTmp(Type.I1)
      fb.current.emitAssign(isUpperE, Op.ICmp("eq", eCh, Value.IntConst(69L, Type.I64))) // 'E'
      val isE = freshTmp(Type.I1)
      fb.current.emitAssign(isE, Op.Bin("or", Type.I1, isLowerE, isUpperE))

      val expConsumeLabel = freshLabel("parsef_exp_consume")
      fb.current.setTerminator(Terminator.CondBr(isE, expConsumeLabel, finishLabel))

      val expConsumeBlock = fb.newBlock(expConsumeLabel)
      fb.setCurrent(expConsumeBlock)
      val eNext = freshTmp(Type.I64)
      fb.current.emitAssign(eNext, Op.Bin("add", Type.I64, eIdx, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(eNext, idxPtr)

      val expNegPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(expNegPtr, Op.Alloca(Type.I1))
      fb.current.emitStore(Value.IntConst(0L, Type.I1), expNegPtr)

      val expValPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(expValPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(Value.IntConst(0L, Type.I64), expValPtr)

      val expHasPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(expHasPtr, Op.Alloca(Type.I1))
      fb.current.emitStore(Value.IntConst(0L, Type.I1), expHasPtr)

      val expIdx0 = freshTmp(Type.I64)
      fb.current.emitAssign(expIdx0, Op.Load(Type.I64, idxPtr))
      val expInRange0 = freshTmp(Type.I1)
      fb.current.emitAssign(expInRange0, Op.ICmp("slt", expIdx0, end))
      val expSignCheckLabel = freshLabel("parsef_exp_sign_check")
      fb.current.setTerminator(Terminator.CondBr(expInRange0, expSignCheckLabel, failLabel))

      val expSignCheckBlock = fb.newBlock(expSignCheckLabel)
      fb.setCurrent(expSignCheckBlock)
      val expCh0 = stringCharPayloadI64(strPtr, expIdx0, fb)
      val expIsMinus = freshTmp(Type.I1)
      fb.current.emitAssign(expIsMinus, Op.ICmp("eq", expCh0, Value.IntConst(45L, Type.I64)))
      val expIsPlus = freshTmp(Type.I1)
      fb.current.emitAssign(expIsPlus, Op.ICmp("eq", expCh0, Value.IntConst(43L, Type.I64)))
      val expIsSign = freshTmp(Type.I1)
      fb.current.emitAssign(expIsSign, Op.Bin("or", Type.I1, expIsMinus, expIsPlus))

      val expSignConsumeLabel = freshLabel("parsef_exp_sign_consume")
      val expDigitsLoopLabel = freshLabel("parsef_exp_digits_loop")
      fb.current.setTerminator(Terminator.CondBr(expIsSign, expSignConsumeLabel, expDigitsLoopLabel))

      val expSignConsumeBlock = fb.newBlock(expSignConsumeLabel)
      fb.setCurrent(expSignConsumeBlock)
      val expMinusLabel = freshLabel("parsef_exp_minus")
      val expPlusLabel = freshLabel("parsef_exp_plus")
      val expSetIdxLabel = freshLabel("parsef_exp_setidx")
      fb.current.setTerminator(Terminator.CondBr(expIsMinus, expMinusLabel, expPlusLabel))

      val expMinusBlock = fb.newBlock(expMinusLabel)
      fb.setCurrent(expMinusBlock)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), expNegPtr)
      fb.current.setTerminator(Terminator.Br(expSetIdxLabel))

      val expPlusBlock = fb.newBlock(expPlusLabel)
      fb.setCurrent(expPlusBlock)
      fb.current.setTerminator(Terminator.Br(expSetIdxLabel))

      val expSetIdxBlock = fb.newBlock(expSetIdxLabel)
      fb.setCurrent(expSetIdxBlock)
      val expIdxNext0 = freshTmp(Type.I64)
      fb.current.emitAssign(expIdxNext0, Op.Bin("add", Type.I64, expIdx0, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(expIdxNext0, idxPtr)
      fb.current.setTerminator(Terminator.Br(expDigitsLoopLabel))

      // Exponent digits loop.
      val expDigitsLoopBlock = fb.newBlock(expDigitsLoopLabel)
      fb.setCurrent(expDigitsLoopBlock)
      val expIdx = freshTmp(Type.I64)
      fb.current.emitAssign(expIdx, Op.Load(Type.I64, idxPtr))
      val expInRange = freshTmp(Type.I1)
      fb.current.emitAssign(expInRange, Op.ICmp("slt", expIdx, end))
      val expDigitCheckLabel = freshLabel("parsef_exp_digit_check")
      val expAfterDigitsLabel = freshLabel("parsef_exp_after_digits")
      fb.current.setTerminator(Terminator.CondBr(expInRange, expDigitCheckLabel, expAfterDigitsLabel))

      val expDigitCheckBlock = fb.newBlock(expDigitCheckLabel)
      fb.setCurrent(expDigitCheckBlock)
      val expCh = stringCharPayloadI64(strPtr, expIdx, fb)
      val expNumLo = freshTmp(Type.I1)
      fb.current.emitAssign(expNumLo, Op.ICmp("sge", expCh, Value.IntConst(48L, Type.I64)))
      val expNumHi = freshTmp(Type.I1)
      fb.current.emitAssign(expNumHi, Op.ICmp("sle", expCh, Value.IntConst(57L, Type.I64)))
      val expIsDigit = freshTmp(Type.I1)
      fb.current.emitAssign(expIsDigit, Op.Bin("and", Type.I1, expNumLo, expNumHi))
      val expDigitBodyLabel = freshLabel("parsef_exp_digit_body")
      fb.current.setTerminator(Terminator.CondBr(expIsDigit, expDigitBodyLabel, expAfterDigitsLabel))

      val expDigitBodyBlock = fb.newBlock(expDigitBodyLabel)
      fb.setCurrent(expDigitBodyBlock)
      val expDigitI64 = freshTmp(Type.I64)
      fb.current.emitAssign(expDigitI64, Op.Bin("sub", Type.I64, expCh, Value.IntConst(48L, Type.I64)))
      val expVal0 = freshTmp(Type.I64)
      fb.current.emitAssign(expVal0, Op.Load(Type.I64, expValPtr))
      val expMul = freshTmp(Type.I64)
      fb.current.emitAssign(expMul, Op.Bin("mul", Type.I64, expVal0, Value.IntConst(10L, Type.I64)))
      val expValNext = freshTmp(Type.I64)
      fb.current.emitAssign(expValNext, Op.Bin("add", Type.I64, expMul, expDigitI64))
      fb.current.emitStore(expValNext, expValPtr)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), expHasPtr)
      val expIdxNext = freshTmp(Type.I64)
      fb.current.emitAssign(expIdxNext, Op.Bin("add", Type.I64, expIdx, Value.IntConst(1L, Type.I64)))
      fb.current.emitStore(expIdxNext, idxPtr)
      fb.current.setTerminator(Terminator.Br(expDigitsLoopLabel))

      val expAfterDigitsBlock = fb.newBlock(expAfterDigitsLabel)
      fb.setCurrent(expAfterDigitsBlock)
      val expHas = freshTmp(Type.I1)
      fb.current.emitAssign(expHas, Op.Load(Type.I1, expHasPtr))

      val expApplyLabel = freshLabel("parsef_exp_apply")
      fb.current.setTerminator(Terminator.CondBr(expHas, expApplyLabel, failLabel))

      val expApplyBlock = fb.newBlock(expApplyLabel)
      fb.setCurrent(expApplyBlock)
      val expValRaw = freshTmp(Type.I64)
      fb.current.emitAssign(expValRaw, Op.Load(Type.I64, expValPtr))
      val expNeg = freshTmp(Type.I1)
      fb.current.emitAssign(expNeg, Op.Load(Type.I1, expNegPtr))

      val expSignedPtr = freshTmp(Type.Ptr)
      fb.current.emitAssign(expSignedPtr, Op.Alloca(Type.I64))
      fb.current.emitStore(expValRaw, expSignedPtr)

      val expNegLabel2 = freshLabel("parsef_exp_neg")
      val expSignedDoneLabel = freshLabel("parsef_exp_signed_done")
      fb.current.setTerminator(Terminator.CondBr(expNeg, expNegLabel2, expSignedDoneLabel))

      val expNegBlock2 = fb.newBlock(expNegLabel2)
      fb.setCurrent(expNegBlock2)
      val expSigned = freshTmp(Type.I64)
      fb.current.emitAssign(expSigned, Op.Bin("sub", Type.I64, Value.IntConst(0L, Type.I64), expValRaw))
      fb.current.emitStore(expSigned, expSignedPtr)
      fb.current.setTerminator(Terminator.Br(expSignedDoneLabel))

      val expSignedDoneBlock = fb.newBlock(expSignedDoneLabel)
      fb.setCurrent(expSignedDoneBlock)
      val expFinal = freshTmp(Type.I64)
      fb.current.emitAssign(expFinal, Op.Load(Type.I64, expSignedPtr))
      val expD = freshTmp(Type.Double)
      fb.current.emitAssign(expD, Op.Cast("sitofp", Type.Double, expFinal))
      val powExp = freshTmp(Type.Double)
      fb.current.emitAssign(powExp, Op.Call(Type.Double, "llvm.pow.f64", List(ten, expD)))
      val vPreExp = freshTmp(Type.Double)
      fb.current.emitAssign(vPreExp, Op.Load(Type.Double, valuePtr))
      val vPostExp = freshTmp(Type.Double)
      fb.current.emitAssign(vPostExp, Op.Bin("fmul", Type.Double, vPreExp, powExp))
      fb.current.emitStore(vPostExp, valuePtr)
      fb.current.setTerminator(Terminator.Br(finishLabel))

      // Finish: must consume all characters.
      val finishBlock = fb.newBlock(finishLabel)
      fb.setCurrent(finishBlock)
      val finalIdx = freshTmp(Type.I64)
      fb.current.emitAssign(finalIdx, Op.Load(Type.I64, idxPtr))
      val atEnd = freshTmp(Type.I1)
      fb.current.emitAssign(atEnd, Op.ICmp("eq", finalIdx, end))

      val signApplyLabel = freshLabel("parsef_sign_apply")
      fb.current.setTerminator(Terminator.CondBr(atEnd, signApplyLabel, failLabel))

      val signApplyBlock = fb.newBlock(signApplyLabel)
      fb.setCurrent(signApplyBlock)
      val neg = freshTmp(Type.I1)
      fb.current.emitAssign(neg, Op.Load(Type.I1, negPtr))

      val negApplyLabel = freshLabel("parsef_neg_apply")
      val posApplyLabel = freshLabel("parsef_pos_apply")
      val okSetLabel = freshLabel("parsef_ok_set")
      fb.current.setTerminator(Terminator.CondBr(neg, negApplyLabel, posApplyLabel))

      val negApplyBlock = fb.newBlock(negApplyLabel)
      fb.setCurrent(negApplyBlock)
      val vRaw2 = freshTmp(Type.Double)
      fb.current.emitAssign(vRaw2, Op.Load(Type.Double, valuePtr))
      val vNeg = freshTmp(Type.Double)
      fb.current.emitAssign(vNeg, Op.Bin("fsub", Type.Double, zeroD, vRaw2))
      fb.current.emitStore(vNeg, valuePtr)
      fb.current.setTerminator(Terminator.Br(okSetLabel))

      val posApplyBlock = fb.newBlock(posApplyLabel)
      fb.setCurrent(posApplyBlock)
      fb.current.setTerminator(Terminator.Br(okSetLabel))

      val okSetBlock = fb.newBlock(okSetLabel)
      fb.setCurrent(okSetBlock)
      fb.current.emitStore(Value.IntConst(1L, Type.I1), okPtr)
      fb.current.setTerminator(Terminator.Br(endLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      val ok = freshTmp(Type.I1)
      fb.current.emitAssign(ok, Op.Load(Type.I1, okPtr))
      val okPayload = freshTmp(Type.I64)
      fb.current.emitAssign(okPayload, Op.Cast("zext", Type.I64, ok))

      val vFinalD = freshTmp(Type.Double)
      fb.current.emitAssign(vFinalD, Op.Load(Type.Double, valuePtr))

      val valuePayload = if (is32) {
        val vF32 = freshTmp(Type.Float)
        fb.current.emitAssign(vF32, Op.Cast("fptrunc", Type.Float, vFinalD))
        boxToI64(vF32, SimpleType.Float32, fb)
      } else {
        boxToI64(vFinalD, SimpleType.Float64, fb)
      }

      allocTuple2(okPayload, valuePayload, fb)
    }

    private def emitBinary(op: BinaryOp, a: Value, b: Value, fb: FunBuilder): Value = op match {
      case SemanticOp.BoolOp.And =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.Bin("and", Type.I1, a, b))
        tmp

      case SemanticOp.BoolOp.Or =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.Bin("or", Type.I1, a, b))
        tmp

      case SemanticOp.BoolOp.Eq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("eq", a, b))
        tmp

      case SemanticOp.BoolOp.Neq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("ne", a, b))
        tmp

      case SemanticOp.Int32Op.Add =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Bin("add", Type.I32, a, b))
        tmp

      case SemanticOp.Int32Op.Sub =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Bin("sub", Type.I32, a, b))
        tmp

      case SemanticOp.Int32Op.Mul =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Bin("mul", Type.I32, a, b))
        tmp

      case SemanticOp.Int32Op.Div =>
        emitInt32Div(a, b, fb)

      case SemanticOp.Int32Op.Rem =>
        emitInt32Rem(a, b, fb)

      case SemanticOp.Int32Op.Exp =>
        emitIntExp(a, b, resultBits = 32, fb)

      case SemanticOp.Int32Op.And =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Bin("and", Type.I32, a, b))
        tmp

      case SemanticOp.Int32Op.Or =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Bin("or", Type.I32, a, b))
        tmp

      case SemanticOp.Int32Op.Xor =>
        val tmp = freshTmp(Type.I32)
        fb.current.emitAssign(tmp, Op.Bin("xor", Type.I32, a, b))
        tmp

      case SemanticOp.Int32Op.Shl =>
        emitMaskedShiftLeft(Type.I32, a, b, maskBits = 5, fb)

      case SemanticOp.Int32Op.Shr =>
        emitMaskedShiftRight(Type.I32, a, b, maskBits = 5, fb)

      case SemanticOp.Int32Op.Eq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("eq", a, b))
        tmp

      case SemanticOp.Int32Op.Neq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("ne", a, b))
        tmp

      case SemanticOp.Int32Op.Lt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("slt", a, b))
        tmp

      case SemanticOp.Int32Op.Le =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sle", a, b))
        tmp

      case SemanticOp.Int32Op.Gt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sgt", a, b))
        tmp

      case SemanticOp.Int32Op.Ge =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sge", a, b))
        tmp

      case SemanticOp.Int64Op.Add =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Bin("add", Type.I64, a, b))
        tmp

      case SemanticOp.Int64Op.Sub =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Bin("sub", Type.I64, a, b))
        tmp

      case SemanticOp.Int64Op.Mul =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Bin("mul", Type.I64, a, b))
        tmp

      case SemanticOp.Int64Op.Div =>
        emitInt64Div(a, b, fb)

      case SemanticOp.Int64Op.Rem =>
        emitInt64Rem(a, b, fb)

      case SemanticOp.Int64Op.Exp =>
        emitIntExp(a, b, resultBits = 64, fb)

      case SemanticOp.Int64Op.And =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Bin("and", Type.I64, a, b))
        tmp

      case SemanticOp.Int64Op.Or =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Bin("or", Type.I64, a, b))
        tmp

      case SemanticOp.Int64Op.Xor =>
        val tmp = freshTmp(Type.I64)
        fb.current.emitAssign(tmp, Op.Bin("xor", Type.I64, a, b))
        tmp

      case SemanticOp.Int64Op.Shl =>
        emitMaskedShiftLeft(Type.I64, a, b, maskBits = 6, fb)

      case SemanticOp.Int64Op.Shr =>
        emitMaskedShiftRight(Type.I64, a, b, maskBits = 6, fb)

      case SemanticOp.Int64Op.Eq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("eq", a, b))
        tmp

      case SemanticOp.Int64Op.Neq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("ne", a, b))
        tmp

      case SemanticOp.Int64Op.Lt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("slt", a, b))
        tmp

      case SemanticOp.Int64Op.Le =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sle", a, b))
        tmp

      case SemanticOp.Int64Op.Gt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sgt", a, b))
        tmp

      case SemanticOp.Int64Op.Ge =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sge", a, b))
        tmp

      case SemanticOp.Int8Op.Add =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Bin("add", Type.I8, a, b))
        tmp

      case SemanticOp.Int8Op.Sub =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Bin("sub", Type.I8, a, b))
        tmp

      case SemanticOp.Int8Op.Mul =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Bin("mul", Type.I8, a, b))
        tmp

      case SemanticOp.Int8Op.Div =>
        emitSmallIntDiv(Type.I8, a, b, fb)

      case SemanticOp.Int8Op.Rem =>
        emitSmallIntRem(Type.I8, a, b, fb)

      case SemanticOp.Int8Op.Exp =>
        emitSmallIntExp(Type.I8, a, b, fb)

      case SemanticOp.Int8Op.And =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Bin("and", Type.I8, a, b))
        tmp

      case SemanticOp.Int8Op.Or =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Bin("or", Type.I8, a, b))
        tmp

      case SemanticOp.Int8Op.Xor =>
        val tmp = freshTmp(Type.I8)
        fb.current.emitAssign(tmp, Op.Bin("xor", Type.I8, a, b))
        tmp

      case SemanticOp.Int8Op.Shl =>
        emitSmallIntShiftLeft(Type.I8, a, b, fb)

      case SemanticOp.Int8Op.Shr =>
        emitSmallIntShiftRight(Type.I8, a, b, fb)

      case SemanticOp.Int8Op.Eq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("eq", a, b))
        tmp

      case SemanticOp.Int8Op.Neq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("ne", a, b))
        tmp

      case SemanticOp.Int8Op.Lt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("slt", a, b))
        tmp

      case SemanticOp.Int8Op.Le =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sle", a, b))
        tmp

      case SemanticOp.Int8Op.Gt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sgt", a, b))
        tmp

      case SemanticOp.Int8Op.Ge =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sge", a, b))
        tmp

      case SemanticOp.Int16Op.Add =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Bin("add", Type.I16, a, b))
        tmp

      case SemanticOp.Int16Op.Sub =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Bin("sub", Type.I16, a, b))
        tmp

      case SemanticOp.Int16Op.Mul =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Bin("mul", Type.I16, a, b))
        tmp

      case SemanticOp.Int16Op.Div =>
        emitSmallIntDiv(Type.I16, a, b, fb)

      case SemanticOp.Int16Op.Rem =>
        emitSmallIntRem(Type.I16, a, b, fb)

      case SemanticOp.Int16Op.Exp =>
        emitSmallIntExp(Type.I16, a, b, fb)

      case SemanticOp.Int16Op.And =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Bin("and", Type.I16, a, b))
        tmp

      case SemanticOp.Int16Op.Or =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Bin("or", Type.I16, a, b))
        tmp

      case SemanticOp.Int16Op.Xor =>
        val tmp = freshTmp(Type.I16)
        fb.current.emitAssign(tmp, Op.Bin("xor", Type.I16, a, b))
        tmp

      case SemanticOp.Int16Op.Shl =>
        emitSmallIntShiftLeft(Type.I16, a, b, fb)

      case SemanticOp.Int16Op.Shr =>
        emitSmallIntShiftRight(Type.I16, a, b, fb)

      case SemanticOp.Int16Op.Eq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("eq", a, b))
        tmp

      case SemanticOp.Int16Op.Neq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("ne", a, b))
        tmp

      case SemanticOp.Int16Op.Lt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("slt", a, b))
        tmp

      case SemanticOp.Int16Op.Le =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sle", a, b))
        tmp

      case SemanticOp.Int16Op.Gt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sgt", a, b))
        tmp

      case SemanticOp.Int16Op.Ge =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("sge", a, b))
        tmp

      case SemanticOp.CharOp.Eq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("eq", a, b))
        tmp

      case SemanticOp.CharOp.Neq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("ne", a, b))
        tmp

      case SemanticOp.CharOp.Lt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("ult", a, b))
        tmp

      case SemanticOp.CharOp.Le =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("ule", a, b))
        tmp

      case SemanticOp.CharOp.Gt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("ugt", a, b))
        tmp

      case SemanticOp.CharOp.Ge =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.ICmp("uge", a, b))
        tmp

      case SemanticOp.CharOp.Digit =>
        // Bring-up: ASCII only. Returns -1 if not representable.
        val ch = a
        val radix = b

        val radixLo = freshTmp(Type.I1)
        fb.current.emitAssign(radixLo, Op.ICmp("slt", radix, Value.IntConst(2L, Type.I32)))
        val radixHi = freshTmp(Type.I1)
        fb.current.emitAssign(radixHi, Op.ICmp("sgt", radix, Value.IntConst(36L, Type.I32)))
        val radixBad = freshTmp(Type.I1)
        fb.current.emitAssign(radixBad, Op.Bin("or", Type.I1, radixLo, radixHi))

        val badRadixLabel = freshLabel("cdigit_bad_radix")
        val computeLabel = freshLabel("cdigit_compute")
        val endLabel = freshLabel("cdigit_end")
        fb.current.setTerminator(Terminator.CondBr(radixBad, badRadixLabel, computeLabel))

        val incomings = mutable.ArrayBuffer.empty[(Value, String)]

        val badRadixBlock = fb.newBlock(badRadixLabel)
        fb.setCurrent(badRadixBlock)
        val badRadixRes = Value.IntConst(-1L, Type.I32)
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((badRadixRes, badRadixLabel))

        val computeBlock = fb.newBlock(computeLabel)
        fb.setCurrent(computeBlock)

        val isNumLo = freshTmp(Type.I1)
        fb.current.emitAssign(isNumLo, Op.ICmp("uge", ch, Value.IntConst(48L, Type.I32))) // '0'
        val isNumHi = freshTmp(Type.I1)
        fb.current.emitAssign(isNumHi, Op.ICmp("ule", ch, Value.IntConst(57L, Type.I32))) // '9'
        val isNum = freshTmp(Type.I1)
        fb.current.emitAssign(isNum, Op.Bin("and", Type.I1, isNumLo, isNumHi))

        val numLabel = freshLabel("cdigit_num")
        val lowerCheckLabel = freshLabel("cdigit_lower_check")
        fb.current.setTerminator(Terminator.CondBr(isNum, numLabel, lowerCheckLabel))

        val digitIncomings = mutable.ArrayBuffer.empty[(Value, String)]
        val digitEndLabel = freshLabel("cdigit_digit_end")

        val numBlock = fb.newBlock(numLabel)
        fb.setCurrent(numBlock)
        val dNum = freshTmp(Type.I32)
        fb.current.emitAssign(dNum, Op.Bin("sub", Type.I32, ch, Value.IntConst(48L, Type.I32)))
        fb.current.setTerminator(Terminator.Br(digitEndLabel))
        digitIncomings.addOne((dNum, numLabel))

        val lowerCheckBlock = fb.newBlock(lowerCheckLabel)
        fb.setCurrent(lowerCheckBlock)
        val isLowerLo = freshTmp(Type.I1)
        fb.current.emitAssign(isLowerLo, Op.ICmp("uge", ch, Value.IntConst(97L, Type.I32))) // 'a'
        val isLowerHi = freshTmp(Type.I1)
        fb.current.emitAssign(isLowerHi, Op.ICmp("ule", ch, Value.IntConst(122L, Type.I32))) // 'z'
        val isLower = freshTmp(Type.I1)
        fb.current.emitAssign(isLower, Op.Bin("and", Type.I1, isLowerLo, isLowerHi))

        val lowerLabel = freshLabel("cdigit_lower")
        val upperCheckLabel = freshLabel("cdigit_upper_check")
        fb.current.setTerminator(Terminator.CondBr(isLower, lowerLabel, upperCheckLabel))

        val lowerBlock = fb.newBlock(lowerLabel)
        fb.setCurrent(lowerBlock)
        val dLower0 = freshTmp(Type.I32)
        fb.current.emitAssign(dLower0, Op.Bin("sub", Type.I32, ch, Value.IntConst(97L, Type.I32)))
        val dLower = freshTmp(Type.I32)
        fb.current.emitAssign(dLower, Op.Bin("add", Type.I32, dLower0, Value.IntConst(10L, Type.I32)))
        fb.current.setTerminator(Terminator.Br(digitEndLabel))
        digitIncomings.addOne((dLower, lowerLabel))

        val upperCheckBlock = fb.newBlock(upperCheckLabel)
        fb.setCurrent(upperCheckBlock)
        val isUpperLo = freshTmp(Type.I1)
        fb.current.emitAssign(isUpperLo, Op.ICmp("uge", ch, Value.IntConst(65L, Type.I32))) // 'A'
        val isUpperHi = freshTmp(Type.I1)
        fb.current.emitAssign(isUpperHi, Op.ICmp("ule", ch, Value.IntConst(90L, Type.I32))) // 'Z'
        val isUpper = freshTmp(Type.I1)
        fb.current.emitAssign(isUpper, Op.Bin("and", Type.I1, isUpperLo, isUpperHi))

        val upperLabel = freshLabel("cdigit_upper")
        val invalidLabel = freshLabel("cdigit_invalid")
        fb.current.setTerminator(Terminator.CondBr(isUpper, upperLabel, invalidLabel))

        val upperBlock = fb.newBlock(upperLabel)
        fb.setCurrent(upperBlock)
        val dUpper0 = freshTmp(Type.I32)
        fb.current.emitAssign(dUpper0, Op.Bin("sub", Type.I32, ch, Value.IntConst(65L, Type.I32)))
        val dUpper = freshTmp(Type.I32)
        fb.current.emitAssign(dUpper, Op.Bin("add", Type.I32, dUpper0, Value.IntConst(10L, Type.I32)))
        fb.current.setTerminator(Terminator.Br(digitEndLabel))
        digitIncomings.addOne((dUpper, upperLabel))

        val invalidBlock = fb.newBlock(invalidLabel)
        fb.setCurrent(invalidBlock)
        val invalidDigit = Value.IntConst(-1L, Type.I32)
        fb.current.setTerminator(Terminator.Br(digitEndLabel))
        digitIncomings.addOne((invalidDigit, invalidLabel))

        val digitEndBlock = fb.newBlock(digitEndLabel)
        fb.setCurrent(digitEndBlock)
        val digitPhi = freshTmp(Type.I32)
        digitEndBlock.emitPhi(digitPhi, digitIncomings.toList)

        val nonNeg = freshTmp(Type.I1)
        fb.current.emitAssign(nonNeg, Op.ICmp("sge", digitPhi, Value.IntConst(0L, Type.I32)))
        val ltRadix = freshTmp(Type.I1)
        fb.current.emitAssign(ltRadix, Op.ICmp("slt", digitPhi, radix))
        val okDigit = freshTmp(Type.I1)
        fb.current.emitAssign(okDigit, Op.Bin("and", Type.I1, nonNeg, ltRadix))

        val okLabel = freshLabel("cdigit_ok")
        val badLabel = freshLabel("cdigit_bad")
        fb.current.setTerminator(Terminator.CondBr(okDigit, okLabel, badLabel))

        val okBlock = fb.newBlock(okLabel)
        fb.setCurrent(okBlock)
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((digitPhi, okLabel))

        val badBlock = fb.newBlock(badLabel)
        fb.setCurrent(badBlock)
        val badRes = Value.IntConst(-1L, Type.I32)
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((badRes, badLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        val phi = freshTmp(Type.I32)
        endBlock.emitPhi(phi, incomings.toList)
        phi

      case SemanticOp.CharOp.ForDigit =>
        // Bring-up: ASCII only. Returns '\\u0000' if not representable.
        val n = a
        val radix = b

        val radixLo = freshTmp(Type.I1)
        fb.current.emitAssign(radixLo, Op.ICmp("slt", radix, Value.IntConst(2L, Type.I32)))
        val radixHi = freshTmp(Type.I1)
        fb.current.emitAssign(radixHi, Op.ICmp("sgt", radix, Value.IntConst(36L, Type.I32)))
        val radixBad = freshTmp(Type.I1)
        fb.current.emitAssign(radixBad, Op.Bin("or", Type.I1, radixLo, radixHi))

        val badLabel = freshLabel("cfordigit_bad")
        val nCheckLabel = freshLabel("cfordigit_ncheck")
        val endLabel = freshLabel("cfordigit_end")
        fb.current.setTerminator(Terminator.CondBr(radixBad, badLabel, nCheckLabel))

        val incomings = mutable.ArrayBuffer.empty[(Value, String)]

        val badBlock = fb.newBlock(badLabel)
        fb.setCurrent(badBlock)
        val zeroChar = Value.IntConst(0L, Type.I32)
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((zeroChar, badLabel))

        val nCheckBlock = fb.newBlock(nCheckLabel)
        fb.setCurrent(nCheckBlock)
        val nNeg = freshTmp(Type.I1)
        fb.current.emitAssign(nNeg, Op.ICmp("slt", n, Value.IntConst(0L, Type.I32)))
        val nGe = freshTmp(Type.I1)
        fb.current.emitAssign(nGe, Op.ICmp("sge", n, radix))
        val nBad = freshTmp(Type.I1)
        fb.current.emitAssign(nBad, Op.Bin("or", Type.I1, nNeg, nGe))

        val computeLabel = freshLabel("cfordigit_compute")
        fb.current.setTerminator(Terminator.CondBr(nBad, badLabel, computeLabel))

        val computeBlock = fb.newBlock(computeLabel)
        fb.setCurrent(computeBlock)
        val lt10 = freshTmp(Type.I1)
        fb.current.emitAssign(lt10, Op.ICmp("slt", n, Value.IntConst(10L, Type.I32)))
        val digitLabel = freshLabel("cfordigit_digit")
        val alphaLabel = freshLabel("cfordigit_alpha")
        fb.current.setTerminator(Terminator.CondBr(lt10, digitLabel, alphaLabel))

        val digitBlock = fb.newBlock(digitLabel)
        fb.setCurrent(digitBlock)
        val chDigit = freshTmp(Type.I32)
        fb.current.emitAssign(chDigit, Op.Bin("add", Type.I32, n, Value.IntConst(48L, Type.I32))) // '0'
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((chDigit, digitLabel))

        val alphaBlock = fb.newBlock(alphaLabel)
        fb.setCurrent(alphaBlock)
        val n10 = freshTmp(Type.I32)
        fb.current.emitAssign(n10, Op.Bin("sub", Type.I32, n, Value.IntConst(10L, Type.I32)))
        val chAlpha = freshTmp(Type.I32)
        fb.current.emitAssign(chAlpha, Op.Bin("add", Type.I32, n10, Value.IntConst(97L, Type.I32))) // 'a'
        fb.current.setTerminator(Terminator.Br(endLabel))
        incomings.addOne((chAlpha, alphaLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        val phi = freshTmp(Type.I32)
        endBlock.emitPhi(phi, incomings.toList)
        phi

      case SemanticOp.StringOp.Concat =>
        val s1Ptr = castValue(a, Type.Ptr, fb)
        val s2Ptr = castValue(b, Type.Ptr, fb)

        val len1Ptr = freshTmp(Type.Ptr)
        fb.current.emitAssign(len1Ptr, Op.Gep(Type.I64, s1Ptr, Value.IntConst(0L, Type.I64)))
        val len1 = freshTmp(Type.I64)
        fb.current.emitAssign(len1, Op.Load(Type.I64, len1Ptr))

        val len2Ptr = freshTmp(Type.Ptr)
        fb.current.emitAssign(len2Ptr, Op.Gep(Type.I64, s2Ptr, Value.IntConst(0L, Type.I64)))
        val len2 = freshTmp(Type.I64)
        fb.current.emitAssign(len2, Op.Load(Type.I64, len2Ptr))

        val newLen = freshTmp(Type.I64)
        fb.current.emitAssign(newLen, Op.Bin("add", Type.I64, len1, len2))

        val slots = freshTmp(Type.I64)
        fb.current.emitAssign(slots, Op.Bin("add", Type.I64, newLen, Value.IntConst(1L, Type.I64)))
        val sizeBytes = freshTmp(Type.I64)
        fb.current.emitAssign(sizeBytes, Op.Bin("mul", Type.I64, slots, Value.IntConst(8L, Type.I64)))

        val strPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(strPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))

        val outLenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(outLenPtr, Op.Gep(Type.I64, strPtr, Value.IntConst(0L, Type.I64)))
        fb.current.emitStore(newLen, outLenPtr)

        val iPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(iPtr, Op.Alloca(Type.I64))
        fb.current.emitStore(Value.IntConst(0L, Type.I64), iPtr)

        val loop1Label = freshLabel("sconcat_loop1")
        val body1Label = freshLabel("sconcat_body1")
        val end1Label = freshLabel("sconcat_end1")
        val loop2Label = freshLabel("sconcat_loop2")
        val body2Label = freshLabel("sconcat_body2")
        val end2Label = freshLabel("sconcat_end2")
        val contLabel = freshLabel("sconcat_cont")

        fb.current.setTerminator(Terminator.Br(loop1Label))

        val loop1Block = fb.newBlock(loop1Label)
        fb.setCurrent(loop1Block)
        val iVal = freshTmp(Type.I64)
        fb.current.emitAssign(iVal, Op.Load(Type.I64, iPtr))
        val cond1 = freshTmp(Type.I1)
        fb.current.emitAssign(cond1, Op.ICmp("slt", iVal, len1))
        fb.current.setTerminator(Terminator.CondBr(cond1, body1Label, end1Label))

        val body1Block = fb.newBlock(body1Label)
        fb.setCurrent(body1Block)
        val srcIdx1 = freshTmp(Type.I64)
        fb.current.emitAssign(srcIdx1, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
        val srcPtr1 = freshTmp(Type.Ptr)
        fb.current.emitAssign(srcPtr1, Op.Gep(Type.I64, s1Ptr, srcIdx1))
        val payload1 = freshTmp(Type.I64)
        fb.current.emitAssign(payload1, Op.Load(Type.I64, srcPtr1))
        val dstPtr1 = freshTmp(Type.Ptr)
        fb.current.emitAssign(dstPtr1, Op.Gep(Type.I64, strPtr, srcIdx1))
        fb.current.emitStore(payload1, dstPtr1)
        val iNext1 = freshTmp(Type.I64)
        fb.current.emitAssign(iNext1, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
        fb.current.emitStore(iNext1, iPtr)
        fb.current.setTerminator(Terminator.Br(loop1Label))

        val end1Block = fb.newBlock(end1Label)
        fb.setCurrent(end1Block)
        fb.current.emitStore(Value.IntConst(0L, Type.I64), iPtr)
        fb.current.setTerminator(Terminator.Br(loop2Label))

        val loop2Block = fb.newBlock(loop2Label)
        fb.setCurrent(loop2Block)
        val jVal = freshTmp(Type.I64)
        fb.current.emitAssign(jVal, Op.Load(Type.I64, iPtr))
        val cond2 = freshTmp(Type.I1)
        fb.current.emitAssign(cond2, Op.ICmp("slt", jVal, len2))
        fb.current.setTerminator(Terminator.CondBr(cond2, body2Label, end2Label))

        val body2Block = fb.newBlock(body2Label)
        fb.setCurrent(body2Block)
        val srcIdx2 = freshTmp(Type.I64)
        fb.current.emitAssign(srcIdx2, Op.Bin("add", Type.I64, jVal, Value.IntConst(1L, Type.I64)))
        val srcPtr2 = freshTmp(Type.Ptr)
        fb.current.emitAssign(srcPtr2, Op.Gep(Type.I64, s2Ptr, srcIdx2))
        val payload2 = freshTmp(Type.I64)
        fb.current.emitAssign(payload2, Op.Load(Type.I64, srcPtr2))

        val dstIdx2a = freshTmp(Type.I64)
        fb.current.emitAssign(dstIdx2a, Op.Bin("add", Type.I64, len1, jVal))
        val dstIdx2 = freshTmp(Type.I64)
        fb.current.emitAssign(dstIdx2, Op.Bin("add", Type.I64, dstIdx2a, Value.IntConst(1L, Type.I64)))
        val dstPtr2 = freshTmp(Type.Ptr)
        fb.current.emitAssign(dstPtr2, Op.Gep(Type.I64, strPtr, dstIdx2))
        fb.current.emitStore(payload2, dstPtr2)

        val jNext2 = freshTmp(Type.I64)
        fb.current.emitAssign(jNext2, Op.Bin("add", Type.I64, jVal, Value.IntConst(1L, Type.I64)))
        fb.current.emitStore(jNext2, iPtr)
        fb.current.setTerminator(Terminator.Br(loop2Label))

        val end2Block = fb.newBlock(end2Label)
        fb.setCurrent(end2Block)
        fb.current.setTerminator(Terminator.Br(contLabel))

        val contBlock = fb.newBlock(contLabel)
        fb.setCurrent(contBlock)
        strPtr

      case SemanticOp.StringOp.CharAt =>
        val strPtr = castValue(a, Type.Ptr, fb)
        val idxI64 = castValue(b, Type.I64, fb)

        val lenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, strPtr, Value.IntConst(0L, Type.I64)))
        val lenI64 = freshTmp(Type.I64)
        fb.current.emitAssign(lenI64, Op.Load(Type.I64, lenPtr))

        val neg = freshTmp(Type.I1)
        fb.current.emitAssign(neg, Op.ICmp("slt", idxI64, Value.IntConst(0L, Type.I64)))
        val ge = freshTmp(Type.I1)
        fb.current.emitAssign(ge, Op.ICmp("sge", idxI64, lenI64))
        val oob = freshTmp(Type.I1)
        fb.current.emitAssign(oob, Op.Bin("or", Type.I1, neg, ge))

        val okLabel = freshLabel("scharat_ok")
        val badLabel = freshLabel("scharat_bad")
        val endLabel = freshLabel("scharat_end")

        fb.current.setTerminator(Terminator.CondBr(oob, badLabel, okLabel))

        val badBlock = fb.newBlock(badLabel)
        fb.setCurrent(badBlock)
        fb.current.emitTrap()
        fb.current.setTerminator(Terminator.Unreachable)

        val okBlock = fb.newBlock(okLabel)
        fb.setCurrent(okBlock)
        val slotIdx = freshTmp(Type.I64)
        fb.current.emitAssign(slotIdx, Op.Bin("add", Type.I64, idxI64, Value.IntConst(1L, Type.I64)))
        val slotPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(slotPtr, Op.Gep(Type.I64, strPtr, slotIdx))
        val payload = freshTmp(Type.I64)
        fb.current.emitAssign(payload, Op.Load(Type.I64, slotPtr))
        val ch = unboxFromI64(payload, SimpleType.Char, fb)
        if (!fb.current.isTerminated) fb.current.setTerminator(Terminator.Br(endLabel))

        val endBlock = fb.newBlock(endLabel)
        fb.setCurrent(endBlock)
        ch

      case SemanticOp.StringOp.Repeat =>
        val strPtr0 = castValue(a, Type.Ptr, fb)
        val nI64 = castValue(b, Type.I64, fb)

        val lenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(lenPtr, Op.Gep(Type.I64, strPtr0, Value.IntConst(0L, Type.I64)))
        val lenI64 = freshTmp(Type.I64)
        fb.current.emitAssign(lenI64, Op.Load(Type.I64, lenPtr))

        val isNeg = freshTmp(Type.I1)
        fb.current.emitAssign(isNeg, Op.ICmp("slt", nI64, Value.IntConst(0L, Type.I64)))

        val negLabel = freshLabel("srep_neg")
        val okLabel = freshLabel("srep_ok")
        val contLabel = freshLabel("srep_cont")

        fb.current.setTerminator(Terminator.CondBr(isNeg, negLabel, okLabel))

        val negBlock = fb.newBlock(negLabel)
        fb.setCurrent(negBlock)
        val emptyPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(emptyPtr, Op.Call(Type.Ptr, "malloc", List(Value.IntConst(8L, Type.I64))))
        val emptyLenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(emptyLenPtr, Op.Gep(Type.I64, emptyPtr, Value.IntConst(0L, Type.I64)))
        fb.current.emitStore(Value.IntConst(0L, Type.I64), emptyLenPtr)
        fb.current.setTerminator(Terminator.Br(contLabel))

        val okBlock = fb.newBlock(okLabel)
        fb.setCurrent(okBlock)

        val newLen = freshTmp(Type.I64)
        fb.current.emitAssign(newLen, Op.Bin("mul", Type.I64, lenI64, nI64))
        val slots = freshTmp(Type.I64)
        fb.current.emitAssign(slots, Op.Bin("add", Type.I64, newLen, Value.IntConst(1L, Type.I64)))
        val sizeBytes = freshTmp(Type.I64)
        fb.current.emitAssign(sizeBytes, Op.Bin("mul", Type.I64, slots, Value.IntConst(8L, Type.I64)))

        val outPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(outPtr, Op.Call(Type.Ptr, "malloc", List(sizeBytes)))
        val outLenPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(outLenPtr, Op.Gep(Type.I64, outPtr, Value.IntConst(0L, Type.I64)))
        fb.current.emitStore(newLen, outLenPtr)

        val rPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(rPtr, Op.Alloca(Type.I64))
        fb.current.emitStore(Value.IntConst(0L, Type.I64), rPtr)

        val iPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(iPtr, Op.Alloca(Type.I64))
        fb.current.emitStore(Value.IntConst(0L, Type.I64), iPtr)

        val loopRLabel = freshLabel("srep_loop_r")
        val bodyRLabel = freshLabel("srep_body_r")
        val endRLabel = freshLabel("srep_end_r")
        val loopILabel = freshLabel("srep_loop_i")
        val bodyILabel = freshLabel("srep_body_i")
        val endILabel = freshLabel("srep_end_i")

        fb.current.setTerminator(Terminator.Br(loopRLabel))

        val loopRBlock = fb.newBlock(loopRLabel)
        fb.setCurrent(loopRBlock)
        val rVal = freshTmp(Type.I64)
        fb.current.emitAssign(rVal, Op.Load(Type.I64, rPtr))
        val condR = freshTmp(Type.I1)
        fb.current.emitAssign(condR, Op.ICmp("slt", rVal, nI64))
        fb.current.setTerminator(Terminator.CondBr(condR, bodyRLabel, endRLabel))

        val bodyRBlock = fb.newBlock(bodyRLabel)
        fb.setCurrent(bodyRBlock)
        fb.current.emitStore(Value.IntConst(0L, Type.I64), iPtr)
        fb.current.setTerminator(Terminator.Br(loopILabel))

        val loopIBlock = fb.newBlock(loopILabel)
        fb.setCurrent(loopIBlock)
        val iVal = freshTmp(Type.I64)
        fb.current.emitAssign(iVal, Op.Load(Type.I64, iPtr))
        val condI = freshTmp(Type.I1)
        fb.current.emitAssign(condI, Op.ICmp("slt", iVal, lenI64))
        fb.current.setTerminator(Terminator.CondBr(condI, bodyILabel, endILabel))

        val bodyIBlock = fb.newBlock(bodyILabel)
        fb.setCurrent(bodyIBlock)
        val srcIdx = freshTmp(Type.I64)
        fb.current.emitAssign(srcIdx, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
        val srcPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(srcPtr, Op.Gep(Type.I64, strPtr0, srcIdx))
        val payload = freshTmp(Type.I64)
        fb.current.emitAssign(payload, Op.Load(Type.I64, srcPtr))

        val base = freshTmp(Type.I64)
        fb.current.emitAssign(base, Op.Bin("mul", Type.I64, rVal, lenI64))
        val dstIdx0 = freshTmp(Type.I64)
        fb.current.emitAssign(dstIdx0, Op.Bin("add", Type.I64, base, iVal))
        val dstIdx = freshTmp(Type.I64)
        fb.current.emitAssign(dstIdx, Op.Bin("add", Type.I64, dstIdx0, Value.IntConst(1L, Type.I64)))
        val dstPtr = freshTmp(Type.Ptr)
        fb.current.emitAssign(dstPtr, Op.Gep(Type.I64, outPtr, dstIdx))
        fb.current.emitStore(payload, dstPtr)

        val iNext = freshTmp(Type.I64)
        fb.current.emitAssign(iNext, Op.Bin("add", Type.I64, iVal, Value.IntConst(1L, Type.I64)))
        fb.current.emitStore(iNext, iPtr)
        fb.current.setTerminator(Terminator.Br(loopILabel))

        val endIBlock = fb.newBlock(endILabel)
        fb.setCurrent(endIBlock)
        val rNext = freshTmp(Type.I64)
        fb.current.emitAssign(rNext, Op.Bin("add", Type.I64, rVal, Value.IntConst(1L, Type.I64)))
        fb.current.emitStore(rNext, rPtr)
        fb.current.setTerminator(Terminator.Br(loopRLabel))

        val endRBlock = fb.newBlock(endRLabel)
        fb.setCurrent(endRBlock)
        fb.current.setTerminator(Terminator.Br(contLabel))

        val contBlock = fb.newBlock(contLabel)
        fb.setCurrent(contBlock)

        val phi = freshTmp(Type.Ptr)
        // Note: the ok path reaches contLabel from endRLabel, not okLabel.
        contBlock.emitPhi(phi, List((emptyPtr, negLabel), (outPtr, endRLabel)))
        phi

      case SemanticOp.Float32Op.Add =>
        val tmp = freshTmp(Type.Float)
        fb.current.emitAssign(tmp, Op.Bin("fadd", Type.Float, a, b))
        tmp

      case SemanticOp.Float32Op.Sub =>
        val tmp = freshTmp(Type.Float)
        fb.current.emitAssign(tmp, Op.Bin("fsub", Type.Float, a, b))
        tmp

      case SemanticOp.Float32Op.Mul =>
        val tmp = freshTmp(Type.Float)
        fb.current.emitAssign(tmp, Op.Bin("fmul", Type.Float, a, b))
        tmp

      case SemanticOp.Float32Op.Div =>
        val tmp = freshTmp(Type.Float)
        fb.current.emitAssign(tmp, Op.Bin("fdiv", Type.Float, a, b))
        tmp

      case SemanticOp.Float32Op.Exp =>
        val tmp = freshTmp(Type.Float)
        fb.current.emitAssign(tmp, Op.Call(Type.Float, "llvm.pow.f32", List(a, b)))
        tmp

      case SemanticOp.Float32Op.Eq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("oeq", a, b))
        tmp

      case SemanticOp.Float32Op.Neq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("une", a, b))
        tmp

      case SemanticOp.Float32Op.Lt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("olt", a, b))
        tmp

      case SemanticOp.Float32Op.Le =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("ole", a, b))
        tmp

      case SemanticOp.Float32Op.Gt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("ogt", a, b))
        tmp

      case SemanticOp.Float32Op.Ge =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("oge", a, b))
        tmp

      case SemanticOp.Float64Op.Add =>
        val tmp = freshTmp(Type.Double)
        fb.current.emitAssign(tmp, Op.Bin("fadd", Type.Double, a, b))
        tmp

      case SemanticOp.Float64Op.Sub =>
        val tmp = freshTmp(Type.Double)
        fb.current.emitAssign(tmp, Op.Bin("fsub", Type.Double, a, b))
        tmp

      case SemanticOp.Float64Op.Mul =>
        val tmp = freshTmp(Type.Double)
        fb.current.emitAssign(tmp, Op.Bin("fmul", Type.Double, a, b))
        tmp

      case SemanticOp.Float64Op.Div =>
        val tmp = freshTmp(Type.Double)
        fb.current.emitAssign(tmp, Op.Bin("fdiv", Type.Double, a, b))
        tmp

      case SemanticOp.Float64Op.Exp =>
        val tmp = freshTmp(Type.Double)
        fb.current.emitAssign(tmp, Op.Call(Type.Double, "llvm.pow.f64", List(a, b)))
        tmp

      case SemanticOp.Float64Op.Eq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("oeq", a, b))
        tmp

      case SemanticOp.Float64Op.Neq =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("une", a, b))
        tmp

      case SemanticOp.Float64Op.Lt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("olt", a, b))
        tmp

      case SemanticOp.Float64Op.Le =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("ole", a, b))
        tmp

      case SemanticOp.Float64Op.Gt =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("ogt", a, b))
        tmp

      case SemanticOp.Float64Op.Ge =>
        val tmp = freshTmp(Type.I1)
        fb.current.emitAssign(tmp, Op.FCmp("oge", a, b))
        tmp

      case _ =>
        fb.current.emitTrap()
        Value.Undef(Type.I64)
    }

    private def isIntType(tpe: Type): Boolean = tpe match {
      case Type.I1 | Type.I8 | Type.I16 | Type.I32 | Type.I64 => true
      case _ => false
    }

    private def castValue(v: Value, expectedTpe: Type, fb: FunBuilder): Value = {
      if (v.tpe == expectedTpe) return v

      (v.tpe, expectedTpe) match {
        case (Type.Ptr, Type.I64) =>
          val tmp = freshTmp(Type.I64)
          fb.current.emitAssign(tmp, Op.Cast("ptrtoint", Type.I64, v))
          tmp

        case (Type.I64, Type.Ptr) =>
          val tmp = freshTmp(Type.Ptr)
          fb.current.emitAssign(tmp, Op.Cast("inttoptr", Type.Ptr, v))
          tmp

        case (from, to) if isIntType(from) && isIntType(to) =>
          val tmp = freshTmp(to)
          val opcode = (from, to) match {
            case (Type.I1, Type.I64) => "zext"
            case (Type.I1, _) => "zext"
            case (_, Type.I1) => "trunc"
            case _ => if (intBits(from) < intBits(to)) "sext" else "trunc"
          }
          fb.current.emitAssign(tmp, Op.Cast(opcode, to, v))
          tmp

        case _ =>
          v
      }
    }

    private def emitMaskedShiftLeft(valueTpe: Type, a: Value, b: Value, maskBits: Int, fb: FunBuilder): Value = {
      val mask = (1L << maskBits) - 1L
      val masked = freshTmp(Type.I32)
      fb.current.emitAssign(masked, Op.Bin("and", Type.I32, b, Value.IntConst(mask, Type.I32)))

      val shiftAmount = valueTpe match {
        case Type.I32 => masked
        case Type.I64 =>
          val tmp = freshTmp(Type.I64)
          fb.current.emitAssign(tmp, Op.Cast("zext", Type.I64, masked))
          tmp
        case other =>
          fb.current.emitTrap()
          return Value.Undef(other)
      }

      val tmp = freshTmp(valueTpe)
      fb.current.emitAssign(tmp, Op.Bin("shl", valueTpe, a, shiftAmount))
      tmp
    }

    private def emitMaskedShiftRight(valueTpe: Type, a: Value, b: Value, maskBits: Int, fb: FunBuilder): Value = {
      val mask = (1L << maskBits) - 1L
      val masked = freshTmp(Type.I32)
      fb.current.emitAssign(masked, Op.Bin("and", Type.I32, b, Value.IntConst(mask, Type.I32)))

      val shiftAmount = valueTpe match {
        case Type.I32 => masked
        case Type.I64 =>
          val tmp = freshTmp(Type.I64)
          fb.current.emitAssign(tmp, Op.Cast("zext", Type.I64, masked))
          tmp
        case other =>
          fb.current.emitTrap()
          return Value.Undef(other)
      }

      val tmp = freshTmp(valueTpe)
      fb.current.emitAssign(tmp, Op.Bin("ashr", valueTpe, a, shiftAmount))
      tmp
    }

    private def emitSmallIntShiftLeft(valueTpe: Type, a: Value, b: Value, fb: FunBuilder): Value = {
      val a32 = freshTmp(Type.I32)
      fb.current.emitAssign(a32, Op.Cast("sext", Type.I32, a))

      val masked = freshTmp(Type.I32)
      fb.current.emitAssign(masked, Op.Bin("and", Type.I32, b, Value.IntConst(31L, Type.I32)))

      val shifted = freshTmp(Type.I32)
      fb.current.emitAssign(shifted, Op.Bin("shl", Type.I32, a32, masked))

      val tmp = freshTmp(valueTpe)
      fb.current.emitAssign(tmp, Op.Cast("trunc", valueTpe, shifted))
      tmp
    }

    private def emitSmallIntShiftRight(valueTpe: Type, a: Value, b: Value, fb: FunBuilder): Value = {
      val a32 = freshTmp(Type.I32)
      fb.current.emitAssign(a32, Op.Cast("sext", Type.I32, a))

      val masked = freshTmp(Type.I32)
      fb.current.emitAssign(masked, Op.Bin("and", Type.I32, b, Value.IntConst(31L, Type.I32)))

      val shifted = freshTmp(Type.I32)
      fb.current.emitAssign(shifted, Op.Bin("ashr", Type.I32, a32, masked))

      val tmp = freshTmp(valueTpe)
      fb.current.emitAssign(tmp, Op.Cast("trunc", valueTpe, shifted))
      tmp
    }

    private def emitSmallIntDiv(valueTpe: Type, a: Value, b: Value, fb: FunBuilder): Value = {
      val isZero = freshTmp(Type.I1)
      fb.current.emitAssign(isZero, Op.ICmp("eq", b, Value.IntConst(0L, valueTpe)))

      val okLabel = freshLabel("div_ok")
      val badLabel = freshLabel("div_bad")
      fb.current.setTerminator(Terminator.CondBr(isZero, badLabel, okLabel))

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      val okBlock = fb.newBlock(okLabel)
      fb.setCurrent(okBlock)

      val a32 = freshTmp(Type.I32)
      fb.current.emitAssign(a32, Op.Cast("sext", Type.I32, a))
      val b32 = freshTmp(Type.I32)
      fb.current.emitAssign(b32, Op.Cast("sext", Type.I32, b))
      val div32 = freshTmp(Type.I32)
      fb.current.emitAssign(div32, Op.Bin("sdiv", Type.I32, a32, b32))
      val tmp = freshTmp(valueTpe)
      fb.current.emitAssign(tmp, Op.Cast("trunc", valueTpe, div32))
      tmp
    }

    private def emitSmallIntRem(valueTpe: Type, a: Value, b: Value, fb: FunBuilder): Value = {
      val isZero = freshTmp(Type.I1)
      fb.current.emitAssign(isZero, Op.ICmp("eq", b, Value.IntConst(0L, valueTpe)))

      val okLabel = freshLabel("rem_ok")
      val badLabel = freshLabel("rem_bad")
      fb.current.setTerminator(Terminator.CondBr(isZero, badLabel, okLabel))

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      val okBlock = fb.newBlock(okLabel)
      fb.setCurrent(okBlock)

      val a32 = freshTmp(Type.I32)
      fb.current.emitAssign(a32, Op.Cast("sext", Type.I32, a))
      val b32 = freshTmp(Type.I32)
      fb.current.emitAssign(b32, Op.Cast("sext", Type.I32, b))
      val rem32 = freshTmp(Type.I32)
      fb.current.emitAssign(rem32, Op.Bin("srem", Type.I32, a32, b32))
      val tmp = freshTmp(valueTpe)
      fb.current.emitAssign(tmp, Op.Cast("trunc", valueTpe, rem32))
      tmp
    }

    private def emitSmallIntExp(valueTpe: Type, a: Value, b: Value, fb: FunBuilder): Value = {
      val a32 = freshTmp(Type.I32)
      fb.current.emitAssign(a32, Op.Cast("sext", Type.I32, a))
      val b32 = freshTmp(Type.I32)
      fb.current.emitAssign(b32, Op.Cast("sext", Type.I32, b))

      val aD = freshTmp(Type.Double)
      fb.current.emitAssign(aD, Op.Cast("sitofp", Type.Double, a32))
      val bD = freshTmp(Type.Double)
      fb.current.emitAssign(bD, Op.Cast("sitofp", Type.Double, b32))

      val powD = freshTmp(Type.Double)
      fb.current.emitAssign(powD, Op.Call(Type.Double, "llvm.pow.f64", List(aD, bD)))

      val asI32 = fpToInt32Saturating(powD, fb)

      val tmp = freshTmp(valueTpe)
      fb.current.emitAssign(tmp, Op.Cast("trunc", valueTpe, asI32))
      tmp
    }

    private def emitInt32Div(a: Value, b: Value, fb: FunBuilder): Value = {
      val isZero = freshTmp(Type.I1)
      fb.current.emitAssign(isZero, Op.ICmp("eq", b, Value.IntConst(0L, Type.I32)))

      val okLabel = freshLabel("idiv_ok")
      val badLabel = freshLabel("idiv_bad")
      fb.current.setTerminator(Terminator.CondBr(isZero, badLabel, okLabel))

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      val okBlock = fb.newBlock(okLabel)
      fb.setCurrent(okBlock)

      val a64 = freshTmp(Type.I64)
      fb.current.emitAssign(a64, Op.Cast("sext", Type.I64, a))
      val b64 = freshTmp(Type.I64)
      fb.current.emitAssign(b64, Op.Cast("sext", Type.I64, b))
      val div64 = freshTmp(Type.I64)
      fb.current.emitAssign(div64, Op.Bin("sdiv", Type.I64, a64, b64))
      val tmp = freshTmp(Type.I32)
      fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I32, div64))
      tmp
    }

    private def emitInt32Rem(a: Value, b: Value, fb: FunBuilder): Value = {
      val isZero = freshTmp(Type.I1)
      fb.current.emitAssign(isZero, Op.ICmp("eq", b, Value.IntConst(0L, Type.I32)))

      val okLabel = freshLabel("irem_ok")
      val badLabel = freshLabel("irem_bad")
      fb.current.setTerminator(Terminator.CondBr(isZero, badLabel, okLabel))

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      val okBlock = fb.newBlock(okLabel)
      fb.setCurrent(okBlock)

      val a64 = freshTmp(Type.I64)
      fb.current.emitAssign(a64, Op.Cast("sext", Type.I64, a))
      val b64 = freshTmp(Type.I64)
      fb.current.emitAssign(b64, Op.Cast("sext", Type.I64, b))
      val rem64 = freshTmp(Type.I64)
      fb.current.emitAssign(rem64, Op.Bin("srem", Type.I64, a64, b64))
      val tmp = freshTmp(Type.I32)
      fb.current.emitAssign(tmp, Op.Cast("trunc", Type.I32, rem64))
      tmp
    }

    private def emitInt64Div(a: Value, b: Value, fb: FunBuilder): Value = {
      val isZero = freshTmp(Type.I1)
      fb.current.emitAssign(isZero, Op.ICmp("eq", b, Value.IntConst(0L, Type.I64)))

      val checkLabel = freshLabel("ldiv_check")
      val badLabel = freshLabel("ldiv_bad")
      fb.current.setTerminator(Terminator.CondBr(isZero, badLabel, checkLabel))

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      val checkBlock = fb.newBlock(checkLabel)
      fb.setCurrent(checkBlock)

      val isMin = freshTmp(Type.I1)
      fb.current.emitAssign(isMin, Op.ICmp("eq", a, Value.IntConst(Long.MinValue, Type.I64)))
      val isNegOne = freshTmp(Type.I1)
      fb.current.emitAssign(isNegOne, Op.ICmp("eq", b, Value.IntConst(-1L, Type.I64)))
      val overflow = freshTmp(Type.I1)
      fb.current.emitAssign(overflow, Op.Bin("and", Type.I1, isMin, isNegOne))

      val overflowLabel = freshLabel("ldiv_ovf")
      val computeLabel = freshLabel("ldiv_compute")
      val endLabel = freshLabel("ldiv_end")
      fb.current.setTerminator(Terminator.CondBr(overflow, overflowLabel, computeLabel))

      val incomings = mutable.ArrayBuffer.empty[(Value, String)]

      val ovfBlock = fb.newBlock(overflowLabel)
      fb.setCurrent(ovfBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((Value.IntConst(Long.MinValue, Type.I64), overflowLabel))

      val computeBlock = fb.newBlock(computeLabel)
      fb.setCurrent(computeBlock)
      val div = freshTmp(Type.I64)
      fb.current.emitAssign(div, Op.Bin("sdiv", Type.I64, a, b))
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((div, computeLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      val phi = freshTmp(Type.I64)
      endBlock.emitPhi(phi, incomings.toList)
      phi
    }

    private def emitInt64Rem(a: Value, b: Value, fb: FunBuilder): Value = {
      val isZero = freshTmp(Type.I1)
      fb.current.emitAssign(isZero, Op.ICmp("eq", b, Value.IntConst(0L, Type.I64)))

      val checkLabel = freshLabel("lrem_check")
      val badLabel = freshLabel("lrem_bad")
      fb.current.setTerminator(Terminator.CondBr(isZero, badLabel, checkLabel))

      val badBlock = fb.newBlock(badLabel)
      fb.setCurrent(badBlock)
      fb.current.emitTrap()
      fb.current.setTerminator(Terminator.Unreachable)

      val checkBlock = fb.newBlock(checkLabel)
      fb.setCurrent(checkBlock)

      val isNegOne = freshTmp(Type.I1)
      fb.current.emitAssign(isNegOne, Op.ICmp("eq", b, Value.IntConst(-1L, Type.I64)))

      val zeroLabel = freshLabel("lrem_zero")
      val computeLabel = freshLabel("lrem_compute")
      val endLabel = freshLabel("lrem_end")
      fb.current.setTerminator(Terminator.CondBr(isNegOne, zeroLabel, computeLabel))

      val incomings = mutable.ArrayBuffer.empty[(Value, String)]

      val zeroBlock = fb.newBlock(zeroLabel)
      fb.setCurrent(zeroBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((Value.IntConst(0L, Type.I64), zeroLabel))

      val computeBlock = fb.newBlock(computeLabel)
      fb.setCurrent(computeBlock)
      val rem = freshTmp(Type.I64)
      fb.current.emitAssign(rem, Op.Bin("srem", Type.I64, a, b))
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((rem, computeLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      val phi = freshTmp(Type.I64)
      endBlock.emitPhi(phi, incomings.toList)
      phi
    }

    private def emitIntExp(a: Value, b: Value, resultBits: Int, fb: FunBuilder): Value = {
      val aD = freshTmp(Type.Double)
      fb.current.emitAssign(aD, Op.Cast("sitofp", Type.Double, a))
      val bD = freshTmp(Type.Double)
      fb.current.emitAssign(bD, Op.Cast("sitofp", Type.Double, b))

      val powD = freshTmp(Type.Double)
      fb.current.emitAssign(powD, Op.Call(Type.Double, "llvm.pow.f64", List(aD, bD)))

      resultBits match {
        case 32 => fpToInt32Saturating(powD, fb)
        case 64 => fpToInt64Saturating(powD, fb)
        case _ =>
          fb.current.emitTrap()
          Value.Undef(Type.I64)
      }
    }

    private def fpToInt32Saturating(x: Value, fb: FunBuilder): Value = {
      val (maxPlusOne, minValue) = x.tpe match {
        case Type.Float =>
          val maxPlusOne = Value.Float32Const(java.lang.Float.floatToRawIntBits(2147483648.0f))
          val minValue = Value.Float32Const(java.lang.Float.floatToRawIntBits(-2147483648.0f))
          (maxPlusOne, minValue)
        case Type.Double =>
          val maxPlusOne = Value.Float64Const(java.lang.Double.doubleToRawLongBits(2147483648.0))
          val minValue = Value.Float64Const(java.lang.Double.doubleToRawLongBits(-2147483648.0))
          (maxPlusOne, minValue)
        case _ =>
          fb.current.emitTrap()
          return Value.Undef(Type.I32)
      }

      val isNaN = freshTmp(Type.I1)
      fb.current.emitAssign(isNaN, Op.FCmp("uno", x, x))

      val nanLabel = freshLabel("fp_nan")
      val notNanLabel = freshLabel("fp_notnan")
      val endLabel = freshLabel("fp_end")
      fb.current.setTerminator(Terminator.CondBr(isNaN, nanLabel, notNanLabel))

      val incomings = mutable.ArrayBuffer.empty[(Value, String)]

      val nanBlock = fb.newBlock(nanLabel)
      fb.setCurrent(nanBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((Value.IntConst(0L, Type.I32), nanLabel))

      val notNanBlock = fb.newBlock(notNanLabel)
      fb.setCurrent(notNanBlock)

      val tooBig = freshTmp(Type.I1)
      fb.current.emitAssign(tooBig, Op.FCmp("oge", x, maxPlusOne))

      val bigLabel = freshLabel("fp_big")
      val checkSmallLabel = freshLabel("fp_check_small")
      fb.current.setTerminator(Terminator.CondBr(tooBig, bigLabel, checkSmallLabel))

      val bigBlock = fb.newBlock(bigLabel)
      fb.setCurrent(bigBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((Value.IntConst(Int.MaxValue.toLong, Type.I32), bigLabel))

      val checkSmallBlock = fb.newBlock(checkSmallLabel)
      fb.setCurrent(checkSmallBlock)

      val tooSmall = freshTmp(Type.I1)
      fb.current.emitAssign(tooSmall, Op.FCmp("olt", x, minValue))

      val smallLabel = freshLabel("fp_small")
      val inRangeLabel = freshLabel("fp_inrange")
      fb.current.setTerminator(Terminator.CondBr(tooSmall, smallLabel, inRangeLabel))

      val smallBlock = fb.newBlock(smallLabel)
      fb.setCurrent(smallBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((Value.IntConst(Int.MinValue.toLong, Type.I32), smallLabel))

      val inRangeBlock = fb.newBlock(inRangeLabel)
      fb.setCurrent(inRangeBlock)
      val asI32 = freshTmp(Type.I32)
      fb.current.emitAssign(asI32, Op.Cast("fptosi", Type.I32, x))
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((asI32, inRangeLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      val phi = freshTmp(Type.I32)
      endBlock.emitPhi(phi, incomings.toList)
      phi
    }

    private def fpToInt64Saturating(x: Value, fb: FunBuilder): Value = {
      val (maxPlusOne, minValue) = x.tpe match {
        case Type.Float =>
          val maxPlusOne = Value.Float32Const(java.lang.Float.floatToRawIntBits(9223372036854775808.0f))
          val minValue = Value.Float32Const(java.lang.Float.floatToRawIntBits(-9223372036854775808.0f))
          (maxPlusOne, minValue)
        case Type.Double =>
          val maxPlusOne = Value.Float64Const(java.lang.Double.doubleToRawLongBits(9223372036854775808.0))
          val minValue = Value.Float64Const(java.lang.Double.doubleToRawLongBits(-9223372036854775808.0))
          (maxPlusOne, minValue)
        case _ =>
          fb.current.emitTrap()
          return Value.Undef(Type.I64)
      }

      val isNaN = freshTmp(Type.I1)
      fb.current.emitAssign(isNaN, Op.FCmp("uno", x, x))

      val nanLabel = freshLabel("fp_nan")
      val notNanLabel = freshLabel("fp_notnan")
      val endLabel = freshLabel("fp_end")
      fb.current.setTerminator(Terminator.CondBr(isNaN, nanLabel, notNanLabel))

      val incomings = mutable.ArrayBuffer.empty[(Value, String)]

      val nanBlock = fb.newBlock(nanLabel)
      fb.setCurrent(nanBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((Value.IntConst(0L, Type.I64), nanLabel))

      val notNanBlock = fb.newBlock(notNanLabel)
      fb.setCurrent(notNanBlock)

      val tooBig = freshTmp(Type.I1)
      fb.current.emitAssign(tooBig, Op.FCmp("oge", x, maxPlusOne))

      val bigLabel = freshLabel("fp_big")
      val checkSmallLabel = freshLabel("fp_check_small")
      fb.current.setTerminator(Terminator.CondBr(tooBig, bigLabel, checkSmallLabel))

      val bigBlock = fb.newBlock(bigLabel)
      fb.setCurrent(bigBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((Value.IntConst(Long.MaxValue, Type.I64), bigLabel))

      val checkSmallBlock = fb.newBlock(checkSmallLabel)
      fb.setCurrent(checkSmallBlock)

      val tooSmall = freshTmp(Type.I1)
      fb.current.emitAssign(tooSmall, Op.FCmp("olt", x, minValue))

      val smallLabel = freshLabel("fp_small")
      val inRangeLabel = freshLabel("fp_inrange")
      fb.current.setTerminator(Terminator.CondBr(tooSmall, smallLabel, inRangeLabel))

      val smallBlock = fb.newBlock(smallLabel)
      fb.setCurrent(smallBlock)
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((Value.IntConst(Long.MinValue, Type.I64), smallLabel))

      val inRangeBlock = fb.newBlock(inRangeLabel)
      fb.setCurrent(inRangeBlock)
      val asI64 = freshTmp(Type.I64)
      fb.current.emitAssign(asI64, Op.Cast("fptosi", Type.I64, x))
      fb.current.setTerminator(Terminator.Br(endLabel))
      incomings.addOne((asI64, inRangeLabel))

      val endBlock = fb.newBlock(endLabel)
      fb.setCurrent(endBlock)
      val phi = freshTmp(Type.I64)
      endBlock.emitPhi(phi, incomings.toList)
      phi
    }

    private def intBits(tpe: Type): Int = tpe match {
      case Type.I1 => 1
      case Type.I8 => 8
      case Type.I16 => 16
      case Type.I32 => 32
      case Type.I64 => 64
      case _ => 0
    }

    /**
      * Local function builder utilities.
      */
    private final class FunBuilder {
      private val blocks = mutable.ArrayBuffer.empty[BlockBuilder]
      private val blockMap = mutable.Map.empty[String, BlockBuilder]

      var current: BlockBuilder = _

      def newBlock(label: String): BlockBuilder = {
        val b = new BlockBuilder(label)
        blocks.addOne(b)
        blockMap.put(label, b)
        b
      }

      def setCurrent(b: BlockBuilder): Unit = {
        current = b
      }

      def result(): List[LlvmIr.Block] = {
        blocks.toList.map(_.toBlock)
      }
    }

    private final class BlockBuilder(val label: String) {
      private val phis = mutable.ArrayBuffer.empty[Instr.Phi]
      private val instrs = mutable.ArrayBuffer.empty[Instr]
      private var term: Option[Terminator] = None

      def isTerminated: Boolean = term.nonEmpty

      def emitAssign(dest: Value.Local, op: Op): Unit = {
        ensureNotTerminated()
        instrs.addOne(Instr.Assign(dest, op))
      }

      def emitStore(value: Value, addr: Value): Unit = {
        ensureNotTerminated()
        instrs.addOne(Instr.Store(value, addr))
      }

      def emitCallVoid(name: String, args: List[Value]): Unit = {
        ensureNotTerminated()
        instrs.addOne(Instr.CallVoid(name, args))
      }

      def emitPhi(dest: Value.Local, incomings: List[(Value, String)]): Unit = {
        ensureNotTerminated()
        if (instrs.nonEmpty) {
          throw new IllegalStateException(s"Phi inserted after non-phi instructions in block '$label'.")
        }
        phis.addOne(Instr.Phi(dest, incomings))
      }

      def emitTrap(): Unit = {
        ensureNotTerminated()
        instrs.addOne(Instr.CallVoid("llvm.trap", Nil))
      }

      def setTerminator(t: Terminator): Unit = {
        ensureNotTerminated()
        term = Some(t)
      }

      private def ensureNotTerminated(): Unit = {
        if (term.nonEmpty) {
          throw new IllegalStateException(s"Cannot emit into terminated block '$label'.")
        }
      }

      def toBlock: LlvmIr.Block = {
        val t = term.getOrElse {
          throw new IllegalStateException(s"Block '$label' missing terminator.")
        }
        LlvmIr.Block(label, phis.toList, instrs.toList, t)
      }
    }
  }

  private object LlvmNames {
    def defName(sym: Symbol.DefnSym): String =
      s"flix_${LlvmNamesInternal.mangle(sym.toString)}"

    def frameApplyName(sym: Symbol.DefnSym): String =
      s"flix_frame_apply_${LlvmNamesInternal.mangle(sym.toString)}"

    def closureInvokeName(sym: Symbol.DefnSym): String =
      s"flix_clo_invoke_${LlvmNamesInternal.mangle(sym.toString)}"

    def thunkInvokeName(sym: Symbol.DefnSym): String =
      s"flix_thunk_invoke_${LlvmNamesInternal.mangle(sym.toString)}"

    def thunkApplyClosureName(argTpe: Type): String =
      s"flix_thunk_apply_clo_${LlvmNamesInternal.mangle(argTpe.render)}"

    def paramName(i: Int): String =
      s"a$i"
  }

  private object LlvmNamesInternal {
    /**
      * LLVM-safe name mangling: keep alphanumerics and `_`, replace everything else with `_`.
      */
    def mangle(s: String): String = {
      val b = new StringBuilder(s.length + 8)
      s.foreach {
        case c if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' =>
          b.append(c)
        case _ => b.append('_')
      }
      if (b.isEmpty) "_"
      else {
        val head = b.charAt(0)
        if ((head >= '0' && head <= '9')) "_" + b.toString() else b.toString()
      }
    }
  }
}
