const std = @import("std");
const builtin = @import("builtin");

const is_wasm: bool = builtin.target.cpu.arch.isWasm();

// Allocator for runtime metadata and temporary buffers.
// - On wasm32-freestanding we must not depend on libc.
// - On native we prefer the C allocator for now.
const rt_alloc: std.mem.Allocator = if (is_wasm) std.heap.page_allocator else std.heap.c_allocator;

// ----------------------------------------------------------------------------
// Target substrate abstractions.
//
// The runtime is compiled for both native and wasm32-freestanding. The wasm target is
// single-threaded in v0 (no wasm-threads), so we provide no-op mutex/condvar and
// non-atomic "atomics" to keep the core runtime code shared.
// ----------------------------------------------------------------------------

const RtMutex = if (is_wasm) struct {
    pub fn lock(_: *@This()) void {}
    pub fn unlock(_: *@This()) void {}
} else std.Thread.Mutex;

const RtCondition = if (is_wasm) struct {
    pub fn wait(_: *@This(), _: *RtMutex) void {}
    pub fn signal(_: *@This()) void {}
    pub fn broadcast(_: *@This()) void {}
} else std.Thread.Condition;

const RtThread = if (is_wasm) struct {
    task_id: u64,
    pub fn join(_: @This()) void {}
} else std.Thread;

fn RtAtomic(comptime T: type) type {
    if (is_wasm) {
        return struct {
            raw: T,

            pub inline fn init(v: T) @This() {
                return .{ .raw = v };
            }

            pub inline fn load(self: *const @This(), comptime _: std.builtin.AtomicOrder) T {
                return self.raw;
            }

            pub inline fn store(self: *@This(), v: T, comptime _: std.builtin.AtomicOrder) void {
                self.raw = v;
            }

            pub inline fn swap(self: *@This(), v: T, comptime _: std.builtin.AtomicOrder) T {
                const prev = self.raw;
                self.raw = v;
                return prev;
            }

            pub inline fn fetchAdd(self: *@This(), operand: T, comptime _: std.builtin.AtomicOrder) T {
                const prev = self.raw;
                if (@typeInfo(T) != .int) @compileError("fetchAdd only supported for integer types");
                self.raw = prev +% operand;
                return prev;
            }

            pub inline fn fetchSub(self: *@This(), operand: T, comptime _: std.builtin.AtomicOrder) T {
                const prev = self.raw;
                if (@typeInfo(T) != .int) @compileError("fetchSub only supported for integer types");
                self.raw = prev -% operand;
                return prev;
            }
        };
    }

    return std.atomic.Value(T);
}

// ----------------------------------------------------------------------------
// wasm32-freestanding support: minimal libc surface expected by `runtime/src/wit/flix.c`.
//
// The generated WIT C glue uses `free`, `memcpy`, `strlen`, and may use `realloc` via a weak
// `cabi_realloc` definition. For browser-first bring-up (no WASI libc), we provide these symbols.
//
// Note: This is *not* the Flix GC heap; it is a small general-purpose allocator for canonical ABI
// buffers (strings/lists) and for legacy runtime helper allocations.
// ----------------------------------------------------------------------------

const WasmCHeader = extern struct {
    size: usize,
    alignment: usize,
    offset: usize,
};

fn wasmCAlloc(alignment_bytes: usize, size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) return @ptrFromInt(alignment_bytes);
    const alignment = if (alignment_bytes == 0) 1 else alignment_bytes;
    const pad = alignment - 1;
    const total = size + @sizeOf(WasmCHeader) + pad;

    const base = rt_alloc.rawAlloc(total, .@"8", @returnAddress()) orelse return null;
    const base_addr: usize = @intFromPtr(base);
    const after_header = base_addr + @sizeOf(WasmCHeader);
    const aligned_addr = (after_header + pad) & ~pad;
    const aligned_ptr: *anyopaque = @ptrFromInt(aligned_addr);

    const hdr_addr = aligned_addr - @sizeOf(WasmCHeader);
    const hdr: *WasmCHeader = @ptrFromInt(hdr_addr);
    hdr.* = .{ .size = total, .alignment = 8, .offset = aligned_addr - base_addr };

    return aligned_ptr;
}

fn wasmMalloc(size: usize) callconv(.c) ?*anyopaque {
    return wasmCAlloc(16, size);
}

fn wasmCFree(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    const addr: usize = @intFromPtr(p);
    const hdr_addr = addr - @sizeOf(WasmCHeader);
    const hdr: *const WasmCHeader = @ptrFromInt(hdr_addr);
    const base_addr = addr - hdr.offset;
    const base: [*]u8 = @ptrFromInt(base_addr);
    rt_alloc.rawFree(base[0..hdr.size], .@"8", @returnAddress());
}

fn wasmCRealloc(ptr: ?*anyopaque, new_size: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) return wasmCAlloc(16, new_size);
    if (new_size == 0) return @ptrFromInt(16);

    const p = ptr.?;
    const addr: usize = @intFromPtr(p);
    const hdr_addr = addr - @sizeOf(WasmCHeader);
    const hdr: *const WasmCHeader = @ptrFromInt(hdr_addr);
    const old_total = hdr.size;
    const old_user = old_total - @sizeOf(WasmCHeader) - (hdr.offset - @sizeOf(WasmCHeader));
    const copy_n: usize = if (new_size < old_user) new_size else old_user;

    const new_ptr = wasmCAlloc(16, new_size) orelse return null;
    const dst: [*]u8 = @ptrCast(new_ptr);
    const src: [*]const u8 = @ptrCast(p);
    std.mem.copyForwards(u8, dst[0..copy_n], src[0..copy_n]);
    wasmCFree(p);
    return new_ptr;
}

fn wasmMemcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    const d = dest orelse return null;
    const s = src orelse return dest;
    const db: [*]u8 = @ptrCast(d);
    const sb: [*]const u8 = @ptrCast(s);
    std.mem.copyForwards(u8, db[0..n], sb[0..n]);
    return dest;
}

fn wasmStrlen(s0: [*:0]const u8) callconv(.c) usize {
    var i: usize = 0;
    while (s0[i] != 0) : (i += 1) {}
    return i;
}

fn wasmAbort() callconv(.c) noreturn {
    @panic("abort");
}

fn wasmExit(code: i32) callconv(.c) noreturn {
    _ = code;
    @panic("exit");
}

fn wasmCabiRealloc(ptr: ?*anyopaque, old_size: usize, alignment: usize, new_size: usize) callconv(.c) ?*anyopaque {
    // Match wit-bindgen's C ABI expectation: new_size==0 returns `alignment` as a sentinel.
    if (new_size == 0) return @ptrFromInt(alignment);
    if (ptr == null) return wasmCAlloc(alignment, new_size);

    // Allocate+copy+free; correctness over performance (bring-up).
    const p = ptr.?;
    const new_ptr = wasmCAlloc(alignment, new_size) orelse return null;
    const dst: [*]u8 = @ptrCast(new_ptr);
    const src: [*]const u8 = @ptrCast(p);
    const copy_n: usize = if (old_size < new_size) old_size else new_size;
    std.mem.copyForwards(u8, dst[0..copy_n], src[0..copy_n]);
    wasmCFree(p);
    return new_ptr;
}

fn wasmPow(x: f64, y: f64) callconv(.c) f64 {
    // Provide `pow` for LLVM wasm builds (libm is unavailable in wasm32-freestanding).
    return std.math.pow(f64, x, y);
}

fn wasmPowf(x: f32, y: f32) callconv(.c) f32 {
    // Provide `powf` for LLVM wasm builds (libm is unavailable in wasm32-freestanding).
    return std.math.pow(f32, x, y);
}

comptime {
    if (is_wasm) {
        @export(&wasmMalloc, .{ .name = "malloc" });
        @export(&wasmCFree, .{ .name = "free" });
        @export(&wasmCRealloc, .{ .name = "realloc" });
        @export(&wasmMemcpy, .{ .name = "memcpy" });
        @export(&wasmStrlen, .{ .name = "strlen" });
        @export(&wasmAbort, .{ .name = "abort" });
        @export(&wasmExit, .{ .name = "exit" });
        @export(&wasmCabiRealloc, .{ .name = "cabi_realloc" });
        @export(&wasmPow, .{ .name = "pow" });
        @export(&wasmPowf, .{ .name = "powf" });
    }
}

const c = if (is_wasm) struct {
    // Minimal surface used by the runtime in wasm32-freestanding builds.
    pub fn getenv(_: [*:0]const u8) ?[*:0]const u8 {
        return null;
    }
    pub fn malloc(size: usize) ?*anyopaque {
        return wasmCAlloc(16, size);
    }
    pub fn free(ptr: ?*anyopaque) void {
        wasmCFree(ptr);
    }
    pub fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
        return wasmCRealloc(ptr, size);
    }
    pub fn abort() noreturn {
        wasmAbort();
    }
    pub fn exit(code: i32) noreturn {
        wasmExit(code);
    }

    // Regex support for wasm32-freestanding: implemented in pure Zig (`runtime/src/rt_regex.zig`).
    pub const regex_t = struct {
        re_nsub: usize = 0,
        prog: ?*rt_regex.Program = null,
    };
    pub const regmatch_t = extern struct { rm_so: i32 = 0, rm_eo: i32 = 0 };
    pub const REG_EXTENDED: i32 = 1;
    pub const REG_ICASE: i32 = rt_regex.REG_ICASE;

    const REG_NOMATCH: i32 = 1;
    const REG_BADPAT: i32 = 2;
    const REG_EPAREN: i32 = 3;
    const REG_EBRACK: i32 = 4;
    const REG_BADRPT: i32 = 5;
    const REG_ESPACE: i32 = 6;

    pub fn regcomp(preg: *regex_t, pattern: [*:0]const u8, cflags: i32) i32 {
        const pat = std.mem.span(pattern);
        const prog = rt_regex.compile(rt_alloc, pat, cflags) catch |e| switch (e) {
            error.BadPattern => return REG_BADPAT,
            error.UnbalancedParen => return REG_EPAREN,
            error.UnbalancedBracket => return REG_EBRACK,
            error.BadRepeat => return REG_BADRPT,
            error.OutOfMemory => return REG_ESPACE,
        };

        preg.re_nsub = prog.nsub;
        preg.prog = prog;
        return 0;
    }

    pub fn regexec(preg: *regex_t, str: [*:0]const u8, nmatch: usize, pmatch: [*]regmatch_t, eflags: i32) i32 {
        _ = eflags;
        const prog = preg.prog orelse return REG_NOMATCH;
        const input = std.mem.span(str);

        const ncap: usize = prog.ncap;
        const caps = rt_alloc.alloc(i32, ncap) catch return REG_ESPACE;
        defer rt_alloc.free(caps);
        @memset(caps, -1);

        const ok = rt_regex.execFirst(rt_alloc, prog, input, caps);
        if (!ok) return REG_NOMATCH;

        const want: usize = if (nmatch < (prog.nsub + 1)) nmatch else (prog.nsub + 1);
        var i: usize = 0;
        while (i < want) : (i += 1) {
            const so: i32 = caps[2 * i];
            const eo: i32 = caps[2 * i + 1];
            pmatch[i].rm_so = so;
            pmatch[i].rm_eo = eo;
        }
        while (i < nmatch) : (i += 1) {
            pmatch[i].rm_so = -1;
            pmatch[i].rm_eo = -1;
        }

        return 0;
    }

    pub fn regerror(errcode: i32, _: *regex_t, buf: [*]u8, size: usize) usize {
        const msg = switch (errcode) {
            REG_NOMATCH => "no match",
            REG_BADPAT => "invalid pattern",
            REG_EPAREN => "unbalanced parentheses",
            REG_EBRACK => "unbalanced bracket expression",
            REG_BADRPT => "invalid repetition operator",
            REG_ESPACE => "out of memory",
            else => "regex error",
        };

        const n: usize = msg.len;
        if (size == 0) return n;
        const to_copy: usize = if (n < (size - 1)) n else (size - 1);
        std.mem.copyForwards(u8, buf[0..to_copy], msg[0..to_copy]);
        buf[to_copy] = 0;
        return n;
    }

    pub fn regfree(preg: *regex_t) void {
        if (preg.prog) |p| {
            var pp: *rt_regex.Program = p;
            pp.deinit(rt_alloc);
            preg.prog = null;
            preg.re_nsub = 0;
        }
    }
} else @cImport({
    @cInclude("stdlib.h");
    @cInclude("regex.h");
});

const unicode_case = @import("unicode_case_tables.zig");
const rt_regex = @import("rt_regex.zig");

// ----------------------------------------------------------------------------
// WIT sys imports (wasm only).
//
// These are implemented by the generated glue `runtime/src/wit/flix.c` and map to host imports
// from `flix:sys/sys@0.1.0`.
// ----------------------------------------------------------------------------

const WitString = extern struct {
    ptr: [*]const u8,
    len: usize,
};

extern fn flix_sys_sys_log(level: u8, msg: *WitString) void;
extern fn flix_sys_sys_time_now_ms() i64;
extern fn flix_sys_sys_get_args(ret: *flix_list_string_t) void;
extern fn flix_list_string_free(ptr: *flix_list_string_t) void;

// ============================================================================
// GC Heap (bring-up): non-moving mark/sweep, STW at pollchecks.
//
// Key constraints:
// - Allocation may happen anywhere (generated code + runtime helpers).
// - Collection is triggered and executed only at pollchecks, so we never need
//   to conservatively scan the Zig stack for roots.
// - Roots come from: explicit root stacks (per ctx), handles, live regions'
//   remembered sets, and a small set of runtime-managed global pointers.
// ============================================================================

const TraceFn = *const fn (ctx: *anyopaque, obj: *anyopaque) callconv(.c) void;

const GcMeta = struct {
    size_bytes: usize,
    marked: bool,
};

var g_gc_initialized: bool = false;
var g_gc_mutex: RtMutex = .{};
var g_gc_objects: std.AutoHashMap(usize, GcMeta) = undefined;
var g_gc_bytes: usize = 0;
var g_gc_threshold_bytes: usize = 64 * 1024 * 1024; // default: 64 MiB
var g_gc_stress: bool = false;
var g_gc_requested: RtAtomic(bool) = .init(false);
var g_gc_collecting: RtAtomic(bool) = .init(false);

fn envTruthy(name: [*:0]const u8) bool {
    const v = c.getenv(name) orelse return false;
    const s = std.mem.span(v);
    if (s.len == 0) return false;
    if (std.mem.eql(u8, s, "0")) return false;
    if (std.ascii.eqlIgnoreCase(s, "false")) return false;
    if (std.ascii.eqlIgnoreCase(s, "no")) return false;
    return true;
}

fn envParseUsize(name: [*:0]const u8) ?usize {
    const v = c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    if (s.len == 0) return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

// ----------------------------------------------------------------------------
// Runtime debug logging (opt-in via env var).
// ----------------------------------------------------------------------------

var g_rt_debug_initialized: bool = false;
var g_rt_debug: bool = false;
var g_rt_debug_mutex: RtMutex = .{};

var g_gc_debug_initialized: bool = false;
var g_gc_debug: bool = false;
var g_gc_debug_mutex: RtMutex = .{};

fn ensureRtDebugInitialized() void {
    if (g_rt_debug_initialized) return;
    g_rt_debug_mutex.lock();
    defer g_rt_debug_mutex.unlock();
    if (g_rt_debug_initialized) return;
    g_rt_debug = envTruthy("FLIX_DEBUG_RUNTIME");
    g_rt_debug_initialized = true;
}

fn ensureGcDebugInitialized() void {
    if (g_gc_debug_initialized) return;
    g_gc_debug_mutex.lock();
    defer g_gc_debug_mutex.unlock();
    if (g_gc_debug_initialized) return;
    g_gc_debug = envTruthy("FLIX_DEBUG_GC");
    g_gc_debug_initialized = true;
}

fn dbg(comptime fmt: []const u8, args: anytype) void {
    ensureRtDebugInitialized();
    if (!g_rt_debug) return;
    if (is_wasm) {
        return;
    } else {
        std.debug.print(fmt, args);
    }
}

fn dbgGc(comptime fmt: []const u8, args: anytype) void {
    ensureGcDebugInitialized();
    if (!g_gc_debug) return;
    if (is_wasm) {
        return;
    } else {
        std.debug.print(fmt, args);
    }
}

fn ensureGcInitialized() void {
    if (g_gc_initialized) return;
    g_gc_mutex.lock();
    defer g_gc_mutex.unlock();
    if (g_gc_initialized) return;

    g_gc_objects = std.AutoHashMap(usize, GcMeta).init(rt_alloc);
    g_gc_stress = envTruthy("FLIX_GC_STRESS");
    if (envParseUsize("FLIX_GC_HEAP_LIMIT_BYTES")) |n| g_gc_threshold_bytes = n;
    g_gc_initialized = true;
}

fn gcMaybeRequest() void {
    // The heap is global; requesting is cheap and can be done from any thread.
    if (g_gc_stress or g_gc_bytes > g_gc_threshold_bytes) {
        g_gc_requested.store(true, .release);
    }
}

fn gcAllocBytes(size_bytes: usize, ti: *const FlixTypeInfo) *anyopaque {
    ensureGcInitialized();

    g_gc_mutex.lock();
    defer g_gc_mutex.unlock();

    const mem = c.malloc(size_bytes) orelse @panic("malloc failed");
    g_gc_objects.put(@intFromPtr(mem), .{ .size_bytes = size_bytes, .marked = false }) catch @panic("oom");
    g_gc_bytes += size_bytes;
    gcMaybeRequest();

    const obj: *FlixObj = @ptrCast(@alignCast(mem));
    obj.typeinfo = ti;
    if (@hasField(FlixObj, "_pad")) obj._pad = 0;
    return mem;
}

fn allocFlixStringFromAscii(bytes: []const u8) *anyopaque {
    const len: usize = bytes.len;
    if (len > std.math.maxInt(u32)) @panic("string too long");
    const size_bytes: usize = @sizeOf(FlixStringHeader) + len * @sizeOf(u16);

    const mem = gcAllocBytes(size_bytes, &flix_ti_string);
    const header: *FlixStringHeader = @ptrCast(@alignCast(mem));
    header.len = @intCast(len);
    header.reserved = 0;

    const base: [*]u8 = @ptrCast(mem);
    const units_ptr: [*]u16 = @ptrCast(@alignCast(base + @sizeOf(FlixStringHeader)));
    var i: usize = 0;
    while (i < len) : (i += 1) {
        units_ptr[i] = @intCast(bytes[i]);
    }

    return mem;
}

fn appendUtf16FromCodepoint(list: *std.ArrayList(u16), alloc: std.mem.Allocator, cp: u21) std.mem.Allocator.Error!void {
    // Reject surrogate code points.
    if (cp >= 0xD800 and cp <= 0xDFFF) {
        try list.append(alloc, 0xFFFD);
        return;
    }

    if (cp <= 0xFFFF) {
        try list.append(alloc, @intCast(cp));
        return;
    }

    const x: u32 = @intCast(cp - 0x10000);
    const hi: u16 = @intCast(0xD800 + ((x >> 10) & 0x3FF));
    const lo: u16 = @intCast(0xDC00 + (x & 0x3FF));
    try list.append(alloc, hi);
    try list.append(alloc, lo);
}

fn allocFlixStringFromUtf8Lossy(bytes: []const u8) *anyopaque {
    var code_units: std.ArrayList(u16) = .empty;
    defer code_units.deinit(rt_alloc);

    var i: usize = 0;
    while (i < bytes.len) {
        const first = bytes[i];
        const seqlen = std.unicode.utf8ByteSequenceLength(first) catch {
            appendUtf16FromCodepoint(&code_units, rt_alloc, 0xFFFD) catch @panic("oom");
            i += 1;
            continue;
        };

        if (i + seqlen > bytes.len) {
            appendUtf16FromCodepoint(&code_units, rt_alloc, 0xFFFD) catch @panic("oom");
            break;
        }

        const slice = bytes[i .. i + seqlen];
        const cp = std.unicode.utf8Decode(slice) catch {
            appendUtf16FromCodepoint(&code_units, rt_alloc, 0xFFFD) catch @panic("oom");
            i += 1;
            continue;
        };

        appendUtf16FromCodepoint(&code_units, rt_alloc, cp) catch @panic("oom");
        i += seqlen;
    }

    const len: usize = code_units.items.len;
    if (len > std.math.maxInt(u32)) @panic("string too long");
    const size_bytes: usize = @sizeOf(FlixStringHeader) + len * @sizeOf(u16);

    const mem = gcAllocBytes(size_bytes, &flix_ti_string);
    const header: *FlixStringHeader = @ptrCast(@alignCast(mem));
    header.len = @intCast(len);
    header.reserved = 0;

    const base: [*]u8 = @ptrCast(mem);
    const units_ptr: [*]u16 = @ptrCast(@alignCast(base + @sizeOf(FlixStringHeader)));
    var j: usize = 0;
    while (j < len) : (j += 1) {
        units_ptr[j] = code_units.items[j];
    }

    return mem;
}

var g_tuple_typeinfo_mutex: RtMutex = .{};
var g_tuple_typeinfo_initialized: bool = false;
var g_tuple_typeinfo_table: std.AutoHashMap(u128, *const FlixTypeInfo) = undefined;
var g_tuple_typeinfo_next_id: u32 = 1;

fn ensureTupleTypeInfoInitialized() void {
    if (g_tuple_typeinfo_initialized) return;
    g_tuple_typeinfo_mutex.lock();
    defer g_tuple_typeinfo_mutex.unlock();
    if (g_tuple_typeinfo_initialized) return;
    g_tuple_typeinfo_table = std.AutoHashMap(u128, *const FlixTypeInfo).init(rt_alloc);
    g_tuple_typeinfo_initialized = true;
}

fn tupleTypeInfoKey(arity: usize, ptr_mask: u64) u128 {
    return (@as(u128, @intCast(arity)) << 64) | @as(u128, ptr_mask);
}

fn getTupleTypeInfo(arity: usize, ptr_mask: u64) *const FlixTypeInfo {
    if (arity > 64) @panic("tuple arity too large");
    ensureTupleTypeInfoInitialized();

    g_tuple_typeinfo_mutex.lock();
    defer g_tuple_typeinfo_mutex.unlock();

    const key = tupleTypeInfoKey(arity, ptr_mask);
    if (g_tuple_typeinfo_table.get(key)) |ti| return ti;

    // Count pointer slots and build ptr_offs array.
    var ptr_count: usize = 0;
    var i: usize = 0;
    while (i < arity) : (i += 1) {
        if ((ptr_mask & (@as(u64, 1) << @intCast(i))) != 0) ptr_count += 1;
    }

    var ptr_offs_ptr: ?[*]const u32 = null;
    if (ptr_count > 0) {
        const offs = rt_alloc.alloc(u32, ptr_count) catch @panic("oom");
        var j: usize = 0;
        i = 0;
        while (i < arity) : (i += 1) {
            if ((ptr_mask & (@as(u64, 1) << @intCast(i))) != 0) {
                offs[j] = @intCast(@sizeOf(FlixObj) + i * @sizeOf(i64));
                j += 1;
            }
        }
        ptr_offs_ptr = offs.ptr;
    }

    const ti = rt_alloc.create(FlixTypeInfo) catch @panic("oom");
    const size_bytes: u32 = @intCast(@sizeOf(FlixObj) + arity * @sizeOf(i64));
    const type_id: u32 = g_tuple_typeinfo_next_id;
    g_tuple_typeinfo_next_id += 1;
    ti.* = .{
        .type_id = type_id,
        .size_bytes = size_bytes,
        .ptr_count = @intCast(ptr_count),
        .ptr_offs = ptr_offs_ptr,
        .trace = null,
        .invoke = null,
        .apply = null,
        .copy = null,
    };

    g_tuple_typeinfo_table.put(key, ti) catch @panic("oom");
    return ti;
}

fn allocFlixTupleFromPayloads(payloads: []const i64, ptr_mask: u64) *anyopaque {
    const arity: usize = payloads.len;
    const ti = getTupleTypeInfo(arity, ptr_mask);
    if (ti.size_bytes == 0) @panic("allocFlixTupleFromPayloads: invalid tuple typeinfo size");
    const size: usize = @intCast(ti.size_bytes);

    const mem = gcAllocBytes(size, ti);

    const base: [*]u8 = @ptrCast(mem);
    const slots_ptr: [*]i64 = @ptrCast(@alignCast(base + @sizeOf(FlixObj)));
    var i: usize = 0;
    while (i < arity) : (i += 1) {
        slots_ptr[i] = payloads[i];
    }

    return mem;
}

fn allocFlixArrayFromPayloads(payloads: []const i64) *anyopaque {
    const len: usize = payloads.len;
    const size_bytes: usize = @sizeOf(FlixArrayHeader) + len * @sizeOf(i64);

    const mem = gcAllocBytes(size_bytes, &flix_ti_array_prim);
    const header: *FlixArrayHeader = @ptrCast(@alignCast(mem));
    header.len = @intCast(len);
    header.elem_size = @intCast(@sizeOf(i64));

    const slots_ptr: [*]i64 = flixArraySlots(@ptrCast(mem));
    var i: usize = 0;
    while (i < len) : (i += 1) {
        slots_ptr[i] = payloads[i];
    }

    return mem;
}

fn payloadFromPtr(ptr: *anyopaque) i64 {
    const bits: u64 = @intCast(@intFromPtr(ptr));
    return @bitCast(bits);
}

fn payloadFromNullablePtr(ptr: ?*anyopaque) i64 {
    return if (ptr) |p| payloadFromPtr(p) else 0;
}

fn payloadFromBool(b: bool) i64 {
    return if (b) 1 else 0;
}

fn objPayloadSlots(obj_ptr: *anyopaque) [*]i64 {
    const base: [*]u8 = @ptrCast(obj_ptr);
    return @ptrCast(@alignCast(base + @sizeOf(FlixObj)));
}

// ============================================================================
// Boxing (bring-up): represent primitives as heap objects at AnyType/Object boundaries.
//
// This is required for the future GC scanning story: pointer-like slots must contain pointers,
// not raw immediates. The v0 plan is to box primitives when they flow into erased types
// (AnyType/Object), which matches JVM semantics and keeps remembered-set scanning precise.
// ============================================================================

const BOX_TAG_BOOL: i64 = 1;
const BOX_TAG_CHAR: i64 = 2;
const BOX_TAG_INT8: i64 = 3;
const BOX_TAG_INT16: i64 = 4;
const BOX_TAG_INT32: i64 = 5;
const BOX_TAG_INT64: i64 = 6;
const BOX_TAG_FLOAT32: i64 = 7;
const BOX_TAG_FLOAT64: i64 = 8;

fn allocBox(tag: i64, payload: i64) *anyopaque {
    const size: usize = 2 * @sizeOf(i64);
    const mem = c.malloc(size) orelse @panic("malloc failed");
    const slots: [*]i64 = @ptrCast(@alignCast(mem));
    slots[0] = tag;
    slots[1] = payload;
    return mem;
}

fn requireBoxPayload(box_payload: i64, expected_tag: i64) i64 {
    if (box_payload == 0) @panic("unbox: null payload");
    const box_ptr = ptrFromPayload(box_payload);
    const slots: [*]i64 = @ptrCast(@alignCast(box_ptr));
    if (slots[0] != expected_tag) @panic("unbox: tag mismatch");
    return slots[1];
}

export fn flix_box_bool(v: bool) i64 {
    return payloadFromPtr(allocBox(BOX_TAG_BOOL, payloadFromBool(v)));
}

export fn flix_box_char(v: u32) i64 {
    return payloadFromPtr(allocBox(BOX_TAG_CHAR, @intCast(v)));
}

export fn flix_box_int8(v: i8) i64 {
    return payloadFromPtr(allocBox(BOX_TAG_INT8, @intCast(v)));
}

export fn flix_box_int16(v: i16) i64 {
    return payloadFromPtr(allocBox(BOX_TAG_INT16, @intCast(v)));
}

export fn flix_box_int32(v: i32) i64 {
    return payloadFromPtr(allocBox(BOX_TAG_INT32, @intCast(v)));
}

export fn flix_box_int64(v: i64) i64 {
    return payloadFromPtr(allocBox(BOX_TAG_INT64, v));
}

export fn flix_box_float32(v: f32) i64 {
    const bits_u32: u32 = @bitCast(v);
    const payload: i64 = @intCast(bits_u32);
    return payloadFromPtr(allocBox(BOX_TAG_FLOAT32, payload));
}

export fn flix_box_float64(v: f64) i64 {
    const payload: i64 = @bitCast(v);
    return payloadFromPtr(allocBox(BOX_TAG_FLOAT64, payload));
}

export fn flix_unbox_bool(box_payload: i64) i64 {
    return requireBoxPayload(box_payload, BOX_TAG_BOOL);
}

export fn flix_unbox_char(box_payload: i64) i64 {
    return requireBoxPayload(box_payload, BOX_TAG_CHAR);
}

export fn flix_unbox_int8(box_payload: i64) i64 {
    return requireBoxPayload(box_payload, BOX_TAG_INT8);
}

export fn flix_unbox_int16(box_payload: i64) i64 {
    return requireBoxPayload(box_payload, BOX_TAG_INT16);
}

export fn flix_unbox_int32(box_payload: i64) i64 {
    return requireBoxPayload(box_payload, BOX_TAG_INT32);
}

export fn flix_unbox_int64(box_payload: i64) i64 {
    return requireBoxPayload(box_payload, BOX_TAG_INT64);
}

export fn flix_unbox_float32(box_payload: i64) i64 {
    return requireBoxPayload(box_payload, BOX_TAG_FLOAT32);
}

export fn flix_unbox_float64(box_payload: i64) i64 {
    return requireBoxPayload(box_payload, BOX_TAG_FLOAT64);
}

// ============================================================================
// C ABI Helpers (bring-up)
// ============================================================================

const FlixHandleKind = enum(u8) {
    /// The handle payload is pointer bits to a runtime-managed heap object.
    Ptr = 0,
    /// The handle payload is an immediate 64-bit value payload (internal `flix_value_t` bits).
    I64 = 1,
};

const FlixHandleEntry = struct {
    kind: FlixHandleKind,
    payload: i64,
    ref_count: u32,
};

const FlixRootKind = enum(u8) {
    /// Slot holds a `flix_value_t` (i64) whose bits are pointer bits to a GC heap object.
    ValueI64 = 0,
    /// Slot holds a raw `ptr` to a GC heap object.
    Ptr = 1,
};

const FlixRootEntry = struct {
    kind: FlixRootKind,
    slot_ptr: *anyopaque,
};

const GcMarker = struct {
    worklist: std.ArrayListUnmanaged(*anyopaque),
};

const FlixCtx = struct {
    // Pollcheck bookkeeping (per `docs/planning/native-backend/pollcheck-handshake-spec.md`).
    //
    // Invariant: each OS thread that runs generated Flix code must have a distinct `FlixCtx`.
    // (Host embedding is expected to follow the same rule.)
    seen_epoch: RtAtomic(u64),
    blocked: RtAtomic(bool),
    gc_marker: ?*GcMarker,
    next_handle: i64,
    handles_mutex: RtMutex,
    handles: std.AutoHashMap(i64, FlixHandleEntry),
    cancel_exn: ?*anyopaque,
    // Explicit roots (shadow stack): stack of registered root slots owned by this context.
    roots: std.ArrayListUnmanaged(FlixRootEntry),
};

fn requireCtx(ctx_ptr: *anyopaque) *FlixCtx {
    return @ptrCast(@alignCast(ctx_ptr));
}

threadlocal var current_ctx: ?*FlixCtx = null;

// ============================================================================
// Pollcheck + Handshake (v0, FUGC foundation)
// ============================================================================

const HandshakeCallbackId = enum(u8) {
    Nop = 0,
    ScanRoots = 1,
    Park = 2,
};

var g_handshake_request_epoch: RtAtomic(u64) = .init(0);
var g_handshake_release_epoch: RtAtomic(u64) = .init(0);
var g_handshake_ack_count: RtAtomic(u32) = .init(0);
var g_handshake_cb_id: RtAtomic(u8) = .init(@intFromEnum(HandshakeCallbackId.Nop));
var g_handshake_stw: RtAtomic(bool) = .init(false);

// Pending spawn roots: closure pointers passed to new OS threads before the thread has a chance to
// register a `FlixCtx` and publish its explicit roots. These pointers live on a foreign stack and
// are otherwise invisible to the GC (we do not conservatively scan stacks).
var g_spawn_roots_initialized: bool = false;
var g_spawn_roots_mutex: RtMutex = .{};
var g_spawn_roots: std.AutoHashMap(usize, u8) = undefined;

// Registered thread contexts (best-effort bring-up registry; GC will use this later).
var g_ctx_registry_initialized: bool = false;
var g_ctx_registry_mutex: RtMutex = .{};
var g_ctx_registry: std.AutoHashMap(usize, u8) = undefined;

fn ensureSpawnRootsInitialized() void {
    if (g_spawn_roots_initialized) return;
    g_spawn_roots_mutex.lock();
    defer g_spawn_roots_mutex.unlock();
    if (g_spawn_roots_initialized) return;
    g_spawn_roots = std.AutoHashMap(usize, u8).init(rt_alloc);
    g_spawn_roots_initialized = true;
}

fn spawnRootsAdd(ptr: *anyopaque) void {
    ensureSpawnRootsInitialized();
    g_spawn_roots_mutex.lock();
    defer g_spawn_roots_mutex.unlock();
    g_spawn_roots.put(@intFromPtr(ptr), 0) catch @panic("oom");
}

fn spawnRootsRemove(ptr: *anyopaque) void {
    if (!g_spawn_roots_initialized) return;
    g_spawn_roots_mutex.lock();
    defer g_spawn_roots_mutex.unlock();
    _ = g_spawn_roots.remove(@intFromPtr(ptr));
}

fn ensureCtxRegistryInitialized() void {
    if (g_ctx_registry_initialized) return;
    g_ctx_registry_mutex.lock();
    defer g_ctx_registry_mutex.unlock();
    if (g_ctx_registry_initialized) return;
    g_ctx_registry = std.AutoHashMap(usize, u8).init(rt_alloc);
    g_ctx_registry_initialized = true;
}

fn registerCtx(ctx: *FlixCtx) void {
    ensureCtxRegistryInitialized();
    g_ctx_registry_mutex.lock();
    defer g_ctx_registry_mutex.unlock();
    g_ctx_registry.put(@intFromPtr(ctx), 0) catch @panic("oom");
}

fn deregisterCtx(ctx: *FlixCtx) void {
    if (!g_ctx_registry_initialized) return;
    g_ctx_registry_mutex.lock();
    defer g_ctx_registry_mutex.unlock();
    _ = g_ctx_registry.remove(@intFromPtr(ctx));
}

fn gcMarkerMarkPtr(marker: *GcMarker, ptr: *anyopaque) void {
    const addr: usize = @intFromPtr(ptr);
    if (g_gc_objects.getPtr(addr)) |meta| {
        if (!meta.marked) {
            meta.marked = true;
            marker.worklist.append(rt_alloc, ptr) catch @panic("oom");
        }
    }
}

fn gcMarkerMarkPayload(marker: *GcMarker, payload: i64) void {
    if (payload == 0) return;
    gcMarkerMarkPtr(marker, ptrFromPayload(payload));
}

fn gcMarkerTraceObject(ctx: *FlixCtx, marker: *GcMarker, obj_ptr: *anyopaque) void {
    const obj: *FlixObj = @ptrCast(@alignCast(obj_ptr));
    const ti = obj.typeinfo;

    const ptr_count: usize = @intCast(ti.ptr_count);
    if (ptr_count > 0) {
        const offs_ptr = ti.ptr_offs orelse @panic("typeinfo has ptr_count but null ptr_offs");
        var i: usize = 0;
        while (i < ptr_count) : (i += 1) {
            const offs: usize = @intCast(offs_ptr[i]);
            const base: [*]u8 = @ptrCast(obj_ptr);
            const slot: *i64 = @ptrCast(@alignCast(base + offs));
            gcMarkerMarkPayload(marker, slot.*);
        }
    }

    if (ti.trace) |trace_raw| {
        const trace_fn: TraceFn = @ptrCast(@alignCast(trace_raw));
        trace_fn(@ptrCast(ctx), obj_ptr);
    }
}

fn gcMarkCtxRoots(marker: *GcMarker, ctx: *FlixCtx) void {
    if (ctx.cancel_exn) |p| gcMarkerMarkPtr(marker, p);

    ctx.handles_mutex.lock();
    var hit = ctx.handles.iterator();
    while (hit.next()) |e| {
        gcMarkerMarkPayload(marker, e.value_ptr.payload);
    }
    ctx.handles_mutex.unlock();

    for (ctx.roots.items) |e| {
        switch (e.kind) {
            .ValueI64 => {
                const slot: *i64 = @ptrCast(@alignCast(e.slot_ptr));
                gcMarkerMarkPayload(marker, slot.*);
            },
            .Ptr => {
                const slot: *?*anyopaque = @ptrCast(@alignCast(e.slot_ptr));
                if (slot.*) |p| gcMarkerMarkPtr(marker, p);
            },
        }
    }
}

fn gcMarkAllRoots(marker: *GcMarker) void {
    // Context roots (explicit root stacks + handles + cancellation exception cache).
    if (g_ctx_registry_initialized) {
        g_ctx_registry_mutex.lock();
        var it = g_ctx_registry.iterator();
        while (it.next()) |e| {
            const ctx_ptr: *FlixCtx = @ptrFromInt(e.key_ptr.*);
            gcMarkCtxRoots(marker, ctx_ptr);
        }
        g_ctx_registry_mutex.unlock();
    }

    // Live regions (remembered sets + cancellation/child exception pointers).
    if (g_region_registry_initialized) {
        g_region_registry_mutex.lock();
        var it = g_region_registry.iterator();
        while (it.next()) |e| {
            const region: *FlixRegion = @ptrFromInt(e.key_ptr.*);

            if (region.cancel_cause) |p| gcMarkerMarkPtr(marker, p);
            if (region.child_exn) |p| gcMarkerMarkPtr(marker, p);
            if (region.exit_initialized) gcMarkerMarkPayload(marker, region.exit_body_payload);

            for (region.remembered_slots.items) |slot_ptr| {
                gcMarkerMarkPayload(marker, slot_ptr.*);
            }
            for (region.remembered_ptr_arrays.items) |arr| {
                var i: usize = 0;
                while (i < arr.count) : (i += 1) {
                    gcMarkerMarkPayload(marker, arr.base[i]);
                }
            }
        }
        g_region_registry_mutex.unlock();
    }

    // Pending spawn roots (closure pointers in flight to new OS threads).
    if (g_spawn_roots_initialized) {
        g_spawn_roots_mutex.lock();
        var it = g_spawn_roots.iterator();
        while (it.next()) |e| {
            const clo_ptr: *anyopaque = @ptrFromInt(e.key_ptr.*);
            gcMarkerMarkPtr(marker, clo_ptr);
        }
        g_spawn_roots_mutex.unlock();
    }

    // Live channels (queued message payloads).
    //
    // Note: Channels are currently allocated outside the GC heap, so we treat their internal
    // buffers as additional root sources.
    if (g_channel_registry_initialized) {
        g_channel_registry_mutex.lock();
        var it = g_channel_registry.iterator();
        while (it.next()) |e| {
            const chan: *ChannelObj = @ptrFromInt(e.key_ptr.*);
            // Unbuffered rendezvous slot.
            if (chan.rv_has_msg) {
                gcMarkerMarkPayload(marker, chan.rv_payload);
            }
            // Buffered ring buffer payloads.
            if (chan.capacity > 0) {
                if (chan.buf) |buf| {
                    var i: usize = 0;
                    while (i < chan.count) : (i += 1) {
                        const idx = (chan.head + i) % chan.capacity;
                        gcMarkerMarkPayload(marker, buf[idx]);
                    }
                }
            }
        }
        g_channel_registry_mutex.unlock();
    }
}

fn gcMarkSweep(ctx: *FlixCtx) void {
    if (!g_gc_initialized) return;

    var marker: GcMarker = .{ .worklist = .{} };
    defer marker.worklist.deinit(rt_alloc);
    marker.worklist.ensureTotalCapacity(rt_alloc, 4096) catch @panic("oom");

    ctx.gc_marker = &marker;
    defer ctx.gc_marker = null;

    gcMarkAllRoots(&marker);

    // Drain the mark stack.
    while (marker.worklist.items.len > 0) {
        const obj_ptr = marker.worklist.items[marker.worklist.items.len - 1];
        marker.worklist.items.len -= 1;
        gcMarkerTraceObject(ctx, &marker, obj_ptr);
    }

    // Sweep.
    var to_free: std.ArrayListUnmanaged(usize) = .{};
    defer to_free.deinit(rt_alloc);

    var it = g_gc_objects.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.marked) {
            entry.value_ptr.marked = false;
        } else {
            to_free.append(rt_alloc, entry.key_ptr.*) catch @panic("oom");
        }
    }

    for (to_free.items) |addr| {
        if (g_gc_objects.fetchRemove(addr)) |kv| {
            g_gc_bytes -= kv.value.size_bytes;
            c.free(@ptrFromInt(addr));
        }
    }
}

fn handshakeRequestStw(cb: HandshakeCallbackId) u64 {
    g_handshake_cb_id.store(@intFromEnum(cb), .release);
    g_handshake_stw.store(true, .release);
    g_handshake_ack_count.store(0, .release);
    const epoch = g_handshake_request_epoch.fetchAdd(1, .acq_rel) + 1;
    // Ensure that a thread that sees this epoch will park until we release it.
    g_handshake_release_epoch.store(epoch - 1, .release);
    return epoch;
}

fn handshakeWaitStw(epoch: u64, self: *FlixCtx) void {
    // Wait for every non-blocked context to observe the epoch and park at its pollcheck.
    while (true) {
        var all_stopped = true;
        if (g_ctx_registry_initialized) {
            g_ctx_registry_mutex.lock();
            var it = g_ctx_registry.iterator();
            while (it.next()) |e| {
                const ctx_ptr: *FlixCtx = @ptrFromInt(e.key_ptr.*);
                if (ctx_ptr == self) continue;
                if (ctx_ptr.blocked.load(.acquire)) continue;
                if (ctx_ptr.seen_epoch.load(.acquire) < epoch) {
                    all_stopped = false;
                    break;
                }
            }
            g_ctx_registry_mutex.unlock();
        }
        if (all_stopped) return;
        std.atomic.spinLoopHint();
    }
}

fn handshakeReleaseStw(epoch: u64) void {
    g_handshake_release_epoch.store(epoch, .release);
    g_handshake_stw.store(false, .release);
    g_handshake_cb_id.store(@intFromEnum(HandshakeCallbackId.Nop), .release);
}

fn gcCollectStw(ctx: *FlixCtx) void {
    ensureGcInitialized();

    const epoch = handshakeRequestStw(.Park);
    // Mark the collector as having cooperated with this epoch.
    ctx.seen_epoch.store(epoch, .release);

    handshakeWaitStw(epoch, ctx);
    defer handshakeReleaseStw(epoch);

    // World is stopped; collect.
    dbgGc("gc: stw start bytes={} threshold={}\n", .{ g_gc_bytes, g_gc_threshold_bytes });
    g_gc_mutex.lock();
    defer g_gc_mutex.unlock();
    gcMarkSweep(ctx);
    dbgGc("gc: stw done bytes={} threshold={}\n", .{ g_gc_bytes, g_gc_threshold_bytes });
}

fn gcPollcheckMaybeCollect(ctx: *FlixCtx) void {
    // A blocked thread is in a native/runtime section that may not be GC-safe to collect from.
    // It must not initiate collection; it will cooperate with any in-flight STW at unblock time.
    if (ctx.blocked.load(.acquire)) return;
    if (!g_gc_requested.load(.acquire)) return;

    // Ensure only one collector.
    if (g_gc_collecting.swap(true, .acq_rel)) return;
    defer g_gc_collecting.store(false, .release);

    // Consume the request (may be re-requested by subsequent allocations).
    g_gc_requested.store(false, .release);

    gcCollectStw(ctx);
}

fn pollcheckCooperate(ctx: *FlixCtx) void {
    const req = g_handshake_request_epoch.load(.acquire);
    if (req == ctx.seen_epoch.load(.acquire)) return;

    ctx.seen_epoch.store(req, .release);

    const cb_raw = g_handshake_cb_id.load(.acquire);
    const cb: HandshakeCallbackId = @enumFromInt(cb_raw);
    switch (cb) {
        .Nop => {},
        .ScanRoots => {
            // Scan the thread's explicit roots (shadow stack). GC integration will enqueue these
            // roots into the marker; for bring-up this is a no-op scan over registered slots.
            for (ctx.roots.items) |e| {
                switch (e.kind) {
                    .ValueI64 => {
                        const slot: *i64 = @ptrCast(@alignCast(e.slot_ptr));
                        _ = slot.*;
                    },
                    .Ptr => {
                        const slot: *?*anyopaque = @ptrCast(@alignCast(e.slot_ptr));
                        _ = slot.*;
                    },
                }
            }
        },
        .Park => {},
    }

    _ = g_handshake_ack_count.fetchAdd(1, .acq_rel);

    if (g_handshake_stw.load(.acquire)) {
        while (g_handshake_release_epoch.load(.acquire) < req) {
            std.atomic.spinLoopHint();
        }
    }
}

const BlockedGuard = struct {
    ctx: ?*FlixCtx,

    fn enter(ctx_opt: ?*FlixCtx) BlockedGuard {
        if (ctx_opt) |ctx| ctx.blocked.store(true, .release);
        return .{ .ctx = ctx_opt };
    }

    fn exitAndCooperate(self: *BlockedGuard) void {
        if (self.ctx) |ctx| {
            pollcheckCooperate(ctx);
            ctx.blocked.store(false, .release);
        }
    }

    fn exitNoCooperate(self: *BlockedGuard) void {
        if (self.ctx) |ctx| ctx.blocked.store(false, .release);
    }
};

export fn flix_gc_pollcheck(ctx_ptr: *anyopaque) void {
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    pollcheckCooperate(ctx);

    // GC is triggered at pollchecks (bring-up): if a collection was requested and we can become
    // the collector thread, perform an STW mark/sweep using the handshake machinery.
    gcPollcheckMaybeCollect(ctx);
}

export fn flix_ctx_new() *anyopaque {
    const ctx = rt_alloc.create(FlixCtx) catch @panic("oom");
    const req = g_handshake_request_epoch.load(.acquire);
    const initial_seen = if (req > 0) req - 1 else 0;
    ctx.* = .{
        .seen_epoch = .init(initial_seen),
        .blocked = .init(false),
        .gc_marker = null,
        .next_handle = 1,
        .handles_mutex = .{},
        .handles = std.AutoHashMap(i64, FlixHandleEntry).init(rt_alloc),
        .cancel_exn = null,
        .roots = .{},
    };
    // Avoid allocations in the hot path of root push/pop.
    ctx.roots.ensureTotalCapacity(rt_alloc, 2048) catch @panic("oom");
    registerCtx(ctx);
    current_ctx = ctx;
    dbg("ctx_new: {x}\n", .{@intFromPtr(ctx)});
    return ctx;
}

export fn flix_ctx_free(ctx_ptr0: ?*anyopaque) void {
    const ctx_ptr = ctx_ptr0 orelse return;
    dbg("ctx_free: {x} start\n", .{@intFromPtr(ctx_ptr)});
    // If a handshake is in-flight, cooperate once before deregistering.
    flix_gc_pollcheck(ctx_ptr);
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    deregisterCtx(ctx);
    if (current_ctx == ctx) current_ctx = null;
    ctx.handles_mutex.lock();
    ctx.handles.deinit();
    ctx.handles_mutex.unlock();
    ctx.roots.deinit(rt_alloc);
    rt_alloc.destroy(ctx);
    dbg("ctx_free: {x} done\n", .{@intFromPtr(ctx_ptr)});
}

export fn flix_gc_push_root_value_i64(ctx_ptr: *anyopaque, slot_ptr0: ?*anyopaque) void {
    const slot_ptr = slot_ptr0 orelse @panic("flix_gc_push_root_value_i64: null slot");
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.roots.append(rt_alloc, .{ .kind = .ValueI64, .slot_ptr = slot_ptr }) catch @panic("oom");
}

export fn flix_gc_push_root_ptr(ctx_ptr: *anyopaque, slot_ptr0: ?*anyopaque) void {
    const slot_ptr = slot_ptr0 orelse @panic("flix_gc_push_root_ptr: null slot");
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.roots.append(rt_alloc, .{ .kind = .Ptr, .slot_ptr = slot_ptr }) catch @panic("oom");
}

export fn flix_gc_pop_roots(ctx_ptr: *anyopaque, count0: i64) void {
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    if (count0 < 0) @panic("flix_gc_pop_roots: negative count");
    const count: usize = @intCast(count0);
    if (count == 0) return;
    if (count > ctx.roots.items.len) @panic("flix_gc_pop_roots: underflow");
    ctx.roots.items.len -= count;
}

export fn flix_trace_ptr_array(ctx_ptr: *anyopaque, obj_ptr: *anyopaque) void {
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    const marker = ctx.gc_marker orelse return;

    const len: usize = flixArrayLen(obj_ptr);
    const slots: [*]i64 = flixArraySlots(obj_ptr);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        gcMarkerMarkPayload(marker, slots[i]);
    }
}

export fn flix_trace_handler(ctx_ptr: *anyopaque, obj_ptr: *anyopaque) void {
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    const marker = ctx.gc_marker orelse return;

    const slots: [*]i64 = objPayloadSlots(obj_ptr);
    const op_count_i64: i64 = slots[1];
    if (op_count_i64 <= 0) return;
    const op_count: usize = @intCast(op_count_i64);

    var i: usize = 0;
    while (i < op_count) : (i += 1) {
        const clo_bits: i64 = slots[2 + i * 2 + 1];
        gcMarkerMarkPayload(marker, clo_bits);
    }
}

export fn flix_trace_suspension(ctx_ptr: *anyopaque, obj_ptr: *anyopaque) void {
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    const marker = ctx.gc_marker orelse return;

    const slots: [*]i64 = objPayloadSlots(obj_ptr);
    // slots[0]=effSym, slots[1]=opIndex, slots[2]=prefix frames, slots[3]=resumption, slots[4]=argCount, slots[5..]=args
    gcMarkerMarkPayload(marker, slots[2]);
    gcMarkerMarkPayload(marker, slots[3]);

    const arg_count_i64: i64 = slots[4];
    if (arg_count_i64 <= 0) return;
    const arg_count: usize = @intCast(arg_count_i64);
    var i: usize = 0;
    while (i < arg_count) : (i += 1) {
        gcMarkerMarkPayload(marker, slots[5 + i]);
    }
}

export fn flix_cancel_requested(ctx_ptr: *anyopaque) bool {
    _ = ctx_ptr;
    var r = current_region;
    while (r) |region| {
        if (region.cancel_requested.load(.acquire)) return true;
        r = region.parent;
    }
    return false;
}

export fn flix_cancel_exn(ctx_ptr: *anyopaque, cancelled_kind_id: i64, exn_ti0: ?*const FlixTypeInfo, exn_tag_id: i64) *anyopaque {
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    if (ctx.cancel_exn) |p| return p;
    const exn_ti = exn_ti0 orelse @panic("flix_cancel_exn: null exn typeinfo");

    var r = current_region;
    while (r) |region| {
        if (!region.cancel_requested.load(.acquire)) {
            r = region.parent;
            continue;
        }

        region.mutex.lock();
        const cause_ptr = region.cancel_cause orelse region.child_exn orelse @panic("cancellation has no cause");
        region.mutex.unlock();

        const payload_mem = c.malloc(1 * @sizeOf(i64)) orelse @panic("malloc failed");
        const payload_slots: [*]i64 = @ptrCast(@alignCast(payload_mem));
        payload_slots[0] = payloadFromPtr(cause_ptr);

        const trace_ptr = captureTrace();

        const exn_mem = flix_alloc(ctx_ptr, exn_ti);
        const exn_slots = objPayloadSlots(exn_mem);
        // Layout: payload[0]=tag word, payload[1]=kind_id, payload[2]=payload ptr, payload[3]=trace ptr.
        exn_slots[0] = exn_tag_id;
        exn_slots[1] = cancelled_kind_id;
        exn_slots[2] = payloadFromPtr(@ptrCast(payload_mem));
        exn_slots[3] = payloadFromPtr(trace_ptr);

        ctx.cancel_exn = exn_mem;
        return exn_mem;
    }

    @panic("cancellation requested, but no cancelled region found");
}

export fn flix_handle_new(ctx_ptr: *anyopaque, obj_ptr0: ?*anyopaque) i64 {
    const obj_ptr = obj_ptr0 orelse return 0;
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.handles_mutex.lock();
    defer ctx.handles_mutex.unlock();

    const h: i64 = ctx.next_handle;
    ctx.next_handle += 1;
    ctx.handles.put(h, .{ .kind = .Ptr, .payload = payloadFromPtr(obj_ptr), .ref_count = 1 }) catch @panic("oom");
    return h;
}

export fn flix_handle_get(ctx_ptr: *anyopaque, handle: i64) *anyopaque {
    if (handle == 0) @panic("null flix handle");
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.handles_mutex.lock();
    defer ctx.handles_mutex.unlock();

    const entry = ctx.handles.get(handle) orelse @panic("invalid flix handle");
    if (entry.kind != .Ptr) @panic("flix handle does not contain a pointer payload");
    const bits: u64 = @bitCast(entry.payload);
    return @ptrFromInt(@as(usize, @intCast(bits)));
}

export fn flix_handle_new_i64(ctx_ptr: *anyopaque, payload: i64) i64 {
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.handles_mutex.lock();
    defer ctx.handles_mutex.unlock();

    const h: i64 = ctx.next_handle;
    ctx.next_handle += 1;
    ctx.handles.put(h, .{ .kind = .I64, .payload = payload, .ref_count = 1 }) catch @panic("oom");
    return h;
}

export fn flix_handle_payload(ctx_ptr: *anyopaque, handle: i64) i64 {
    if (handle == 0) @panic("null flix handle");
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.handles_mutex.lock();
    defer ctx.handles_mutex.unlock();

    const entry = ctx.handles.get(handle) orelse @panic("invalid flix handle");
    return entry.payload;
}

export fn flix_handle_unbox_i64(ctx_ptr: *anyopaque, handle: i64) i64 {
    if (handle == 0) @panic("null flix handle");
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.handles_mutex.lock();
    defer ctx.handles_mutex.unlock();

    const entry = ctx.handles.get(handle) orelse @panic("invalid flix handle");
    if (entry.kind != .I64) @panic("flix handle does not contain an i64 payload");
    return entry.payload;
}

export fn flix_handle_retain(ctx_ptr: *anyopaque, handle: i64) void {
    if (handle == 0) return;
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.handles_mutex.lock();
    defer ctx.handles_mutex.unlock();

    const entry = ctx.handles.getPtr(handle) orelse @panic("invalid flix handle");
    entry.ref_count +|= 1;
}

export fn flix_handle_release(ctx_ptr: *anyopaque, handle: i64) void {
    if (handle == 0) return;
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.handles_mutex.lock();
    defer ctx.handles_mutex.unlock();

    const entry = ctx.handles.getPtr(handle) orelse @panic("invalid flix handle");
    if (entry.ref_count > 1) {
        entry.ref_count -= 1;
        return;
    }

    _ = ctx.handles.remove(handle);
}

export fn flix_free(ptr: ?*anyopaque) void {
    if (ptr) |p| c.free(p);
}

export fn flix_string_from_utf8(ctx_ptr: *anyopaque, bytes_ptr: ?[*]const u8, len: i64) i64 {
    if (len < 0) @panic("flix_string_from_utf8: negative length");
    const n: usize = @intCast(len);
    if (n == 0) return flix_handle_new(ctx_ptr, allocFlixStringFromAscii(""));
    const p = bytes_ptr orelse @panic("flix_string_from_utf8: null pointer");
    const bytes = p[0..n];
    return flix_handle_new(ctx_ptr, allocFlixStringFromUtf8Lossy(bytes));
}

export fn flix_string_to_utf8(ctx_ptr: *anyopaque, str_handle: i64, out_len: *i64) [*]u8 {
    const str_ptr = flix_handle_get(ctx_ptr, str_handle);

    const bytes = flixStringToUtf8Alloc(rt_alloc, str_ptr);
    defer rt_alloc.free(bytes);

    const mem = c.malloc(bytes.len + 1) orelse @panic("malloc failed");
    const out: [*]u8 = @ptrCast(mem);
    std.mem.copyForwards(u8, out[0..bytes.len], bytes);
    out[bytes.len] = 0;

    out_len.* = @intCast(bytes.len);
    return out;
}

export fn flix_i8_array_from_bytes(ctx_ptr: *anyopaque, bytes_ptr: ?[*]const u8, len: i64) i64 {
    if (len < 0) @panic("flix_i8_array_from_bytes: negative length");
    const n: usize = @intCast(len);
    if (n == 0) return flix_handle_new(ctx_ptr, allocFlixInt8ArrayFromBytes(&.{}));
    const p = bytes_ptr orelse @panic("flix_i8_array_from_bytes: null pointer");
    const bytes = p[0..n];
    return flix_handle_new(ctx_ptr, allocFlixInt8ArrayFromBytes(bytes));
}

export fn flix_i8_array_to_bytes(ctx_ptr: *anyopaque, arr_handle: i64, out_len: *i64) [*]u8 {
    const arr_ptr = flix_handle_get(ctx_ptr, arr_handle);
    const src = flixInt8ArrayBytesView(arr_ptr);
    const mem = c.malloc(src.len) orelse @panic("malloc failed");
    const out: [*]u8 = @ptrCast(mem);
    std.mem.copyForwards(u8, out[0..src.len], src);
    out_len.* = @intCast(src.len);
    return out;
}

fn parseSciExponent(exp_part: []const u8) i32 {
    if (exp_part.len == 0) @panic("invalid scientific exponent");

    var i: usize = 0;
    var neg: bool = false;
    if (exp_part[0] == '-') {
        neg = true;
        i += 1;
    } else if (exp_part[0] == '+') {
        i += 1;
    }

    if (i >= exp_part.len) @panic("invalid scientific exponent");

    var exp: i32 = 0;
    while (i < exp_part.len) : (i += 1) {
        const ch = exp_part[i];
        if (ch < '0' or ch > '9') @panic("invalid scientific exponent");
        exp = exp * 10 + @as(i32, @intCast(ch - '0'));
    }

    return if (neg) -exp else exp;
}

fn formatJavaLikeFromSci(sci: []const u8, out_buf: []u8) []const u8 {
    const e_pos = std.mem.indexOfScalar(u8, sci, 'e') orelse @panic("missing exponent separator");
    var mantissa = sci[0..e_pos];
    const exp_part = sci[(e_pos + 1)..];

    var neg: bool = false;
    if (mantissa.len > 0 and mantissa[0] == '-') {
        neg = true;
        mantissa = mantissa[1..];
    }
    if (mantissa.len == 0) @panic("invalid scientific mantissa");

    var digits_buf: [64]u8 = undefined;
    var digits_len: usize = 0;
    for (mantissa) |ch| {
        if (ch == '.') continue;
        digits_buf[digits_len] = ch;
        digits_len += 1;
    }
    if (digits_len == 0) @panic("invalid scientific mantissa");

    const exp: i32 = parseSciExponent(exp_part);
    const scientific = !(exp >= -3 and exp < 7);

    var idx: usize = 0;
    if (neg) {
        out_buf[idx] = '-';
        idx += 1;
    }

    if (scientific) {
        // Java requires at least two digits, i.e. always a fractional part.
        out_buf[idx] = digits_buf[0];
        idx += 1;
        out_buf[idx] = '.';
        idx += 1;

        if (digits_len == 1) {
            out_buf[idx] = '0';
            idx += 1;
        } else {
            std.mem.copyForwards(u8, out_buf[idx..][0 .. digits_len - 1], digits_buf[1..digits_len]);
            idx += digits_len - 1;
        }

        out_buf[idx] = 'E';
        idx += 1;

        var exp_abs: i32 = exp;
        if (exp_abs < 0) {
            out_buf[idx] = '-';
            idx += 1;
            exp_abs = -exp_abs;
        }

        var rev: [16]u8 = undefined;
        var rev_len: usize = 0;
        var e: u32 = @intCast(exp_abs);
        if (e == 0) {
            rev[0] = '0';
            rev_len = 1;
        } else {
            while (e != 0) : (e /= 10) {
                rev[rev_len] = @as(u8, @intCast('0' + (e % 10)));
                rev_len += 1;
            }
        }

        var j: usize = 0;
        while (j < rev_len) : (j += 1) {
            out_buf[idx] = rev[rev_len - 1 - j];
            idx += 1;
        }
    } else {
        const point_i32: i32 = exp + 1;
        const n: i32 = @intCast(digits_len);

        if (point_i32 <= 0) {
            out_buf[idx] = '0';
            idx += 1;
            out_buf[idx] = '.';
            idx += 1;

            var zeros: usize = @intCast(-point_i32);
            while (zeros != 0) : (zeros -= 1) {
                out_buf[idx] = '0';
                idx += 1;
            }

            std.mem.copyForwards(u8, out_buf[idx..][0..digits_len], digits_buf[0..digits_len]);
            idx += digits_len;
        } else if (point_i32 >= n) {
            std.mem.copyForwards(u8, out_buf[idx..][0..digits_len], digits_buf[0..digits_len]);
            idx += digits_len;

            var zeros: usize = @intCast(point_i32 - n);
            while (zeros != 0) : (zeros -= 1) {
                out_buf[idx] = '0';
                idx += 1;
            }

            out_buf[idx] = '.';
            idx += 1;
            out_buf[idx] = '0';
            idx += 1;
        } else {
            const point: usize = @intCast(point_i32);
            std.mem.copyForwards(u8, out_buf[idx..][0..point], digits_buf[0..point]);
            idx += point;
            out_buf[idx] = '.';
            idx += 1;
            std.mem.copyForwards(u8, out_buf[idx..][0 .. digits_len - point], digits_buf[point..digits_len]);
            idx += digits_len - point;
        }
    }

    return out_buf[0..idx];
}

fn flixFloatToString(comptime T: type, x: T) *anyopaque {
    if (std.math.isNan(x)) {
        return allocFlixStringFromAscii("NaN");
    }
    if (std.math.isInf(x)) {
        return if (@abs(x) == x) allocFlixStringFromAscii("Infinity") else allocFlixStringFromAscii("-Infinity");
    }

    var sci_buf: [96]u8 = undefined;
    const sci = std.fmt.bufPrint(&sci_buf, "{e}", .{x}) catch @panic("scientific formatting failed");

    var out_buf: [128]u8 = undefined;
    const out = formatJavaLikeFromSci(sci, &out_buf);
    return allocFlixStringFromAscii(out);
}

export fn flix_float32_to_string(x: f32) *anyopaque {
    return flixFloatToString(f32, x);
}

export fn flix_float64_to_string(x: f64) *anyopaque {
    return flixFloatToString(f64, x);
}

// ============================================================================
// BigInt (portable, bring-up)
// ============================================================================

const big_int = std.math.big.int;
const BigIntLimb = std.math.big.Limb;
const bigint_limb_bits: usize = @typeInfo(BigIntLimb).int.bits;

const FlixBigIntHeader = extern struct {
    obj: FlixObj,
    len: u32,
    positive: u32,
};

fn flixBigIntHeader(ptr: *anyopaque) *FlixBigIntHeader {
    return @ptrCast(@alignCast(ptr));
}

fn flixBigIntLen(ptr: *anyopaque) usize {
    return @intCast(flixBigIntHeader(ptr).len);
}

fn flixBigIntLimbs(ptr: *anyopaque) [*]BigIntLimb {
    const base: [*]u8 = @ptrCast(ptr);
    return @ptrCast(@alignCast(base + @sizeOf(FlixBigIntHeader)));
}

fn flixBigIntToConst(ptr: *anyopaque) big_int.Const {
    const hdr = flixBigIntHeader(ptr);
    const n: usize = @intCast(hdr.len);
    const positive: bool = hdr.positive != 0;
    const limbs = flixBigIntLimbs(ptr)[0..n];
    return .{ .limbs = limbs, .positive = positive };
}

fn storeBigIntHeader(ptr: *anyopaque, m: big_int.Mutable) void {
    const hdr = flixBigIntHeader(ptr);
    if (m.len > std.math.maxInt(u32)) @panic("bigint too large");
    hdr.len = @intCast(m.len);
    const is_zero = (m.len == 1 and m.limbs[0] == 0);
    hdr.positive = @intFromBool(m.positive or is_zero);
}

fn allocBigIntWithCapacity(limb_capacity0: usize) *anyopaque {
    const limb_capacity: usize = if (limb_capacity0 == 0) 1 else limb_capacity0;
    if (limb_capacity > std.math.maxInt(u32)) @panic("bigint too large");
    const size_bytes: usize = @sizeOf(FlixBigIntHeader) + limb_capacity * @sizeOf(BigIntLimb);
    const mem = gcAllocBytes(size_bytes, &flix_ti_bigint);
    const hdr = flixBigIntHeader(mem);
    hdr.len = 1;
    hdr.positive = 1;
    const limbs = flixBigIntLimbs(mem);
    limbs[0] = 0;
    return mem;
}

fn i32FromBitCount(bits: usize) i32 {
    if (bits > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(bits);
}

fn trapDivByZero() noreturn {
    @trap();
}

export fn flix_bigint_from_i64(ctx_ptr: *anyopaque, x: i64) *anyopaque {
    _ = ctx_ptr;
    const cap: usize = big_int.calcTwosCompLimbCount(@bitSizeOf(i64));
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    const m = big_int.Mutable.init(limbs, x);
    storeBigIntHeader(mem, m);
    return mem;
}

export fn flix_bigint_try_parse(ctx_ptr: *anyopaque, str_ptr: *anyopaque) ?*anyopaque {
    _ = ctx_ptr;
    const len: usize = flixStringLen(str_ptr);
    const units = flixStringCodeUnits(str_ptr);

    var start: usize = 0;
    while (start < len and units[start] <= 32) : (start += 1) {}

    var end: usize = len;
    while (end > start and units[end - 1] <= 32) : (end -= 1) {}

    if (start >= end) return null;

    var has_minus: bool = false;
    if (units[start] == @as(u16, '+')) {
        start += 1;
    } else if (units[start] == @as(u16, '-')) {
        has_minus = true;
        start += 1;
    }

    if (start >= end) return null;

    const digits_len: usize = end - start;
    const out_len: usize = digits_len + @intFromBool(has_minus);

    const buf = rt_alloc.alloc(u8, out_len) catch @panic("oom");
    defer rt_alloc.free(buf);

    var idx: usize = 0;
    if (has_minus) {
        buf[0] = '-';
        idx = 1;
    }

    var i: usize = start;
    while (i < end) : (i += 1) {
        const cu: u16 = units[i];
        if (cu > 0x7F) return null;
        const b: u8 = @intCast(cu);
        if (b == '_') return null;
        if (b < '0' or b > '9') return null;
        buf[idx] = b;
        idx += 1;
    }

    const cap: usize = big_int.calcSetStringLimbCount(10, digits_len);
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var m = big_int.Mutable.init(limbs, 0);

    const tmp_len: usize = big_int.calcSetStringLimbsBufferLen(10, digits_len);
    const tmp = rt_alloc.alloc(BigIntLimb, tmp_len) catch @panic("oom");
    defer rt_alloc.free(tmp);

    m.setString(10, buf, tmp, null) catch return null;
    if (m.eqlZero()) m.positive = true;

    storeBigIntHeader(mem, m);
    return mem;
}

export fn flix_bigint_from_string(ctx_ptr: *anyopaque, str_ptr: *anyopaque) *anyopaque {
    return flix_bigint_try_parse(ctx_ptr, str_ptr) orelse @panic("invalid bigint string");
}

export fn flix_bigint_to_string(ctx_ptr: *anyopaque, bigint_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(bigint_ptr);
    const bytes = a.toStringAlloc(rt_alloc, 10, .lower) catch @panic("oom");
    defer rt_alloc.free(bytes);
    return allocFlixStringFromAscii(bytes);
}

export fn flix_bigint_neg(ctx_ptr: *anyopaque, bigint_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(bigint_ptr);
    const cap: usize = a.limbs.len;
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var r = big_int.Mutable.init(limbs, 0);
    r.copy(a.negate());
    storeBigIntHeader(mem, r);
    return mem;
}

export fn flix_bigint_not(ctx_ptr: *anyopaque, bigint_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(bigint_ptr);
    const cap: usize = a.limbs.len + 1;
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var r = big_int.Mutable.init(limbs, 0);
    r.copy(a.negate());
    r.addScalar(r.toConst(), -1);
    storeBigIntHeader(mem, r);
    return mem;
}

export fn flix_bigint_add(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    const b = flixBigIntToConst(b_ptr);
    const cap: usize = @max(a.limbs.len, b.limbs.len) + 1;
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var r = big_int.Mutable.init(limbs, 0);
    r.add(a, b);
    storeBigIntHeader(mem, r);
    return mem;
}

export fn flix_bigint_sub(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    const b = flixBigIntToConst(b_ptr);
    const cap: usize = @max(a.limbs.len, b.limbs.len) + 1;
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var r = big_int.Mutable.init(limbs, 0);
    r.sub(a, b);
    storeBigIntHeader(mem, r);
    return mem;
}

export fn flix_bigint_mul(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    const b = flixBigIntToConst(b_ptr);
    const cap: usize = a.limbs.len + b.limbs.len;
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var r = big_int.Mutable.init(limbs, 0);
    r.mulNoAlias(a, b, null);
    storeBigIntHeader(mem, r);
    return mem;
}

export fn flix_bigint_div(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    const b = flixBigIntToConst(b_ptr);
    if (big_int.Const.eqlZero(b)) trapDivByZero();

    const q_cap: usize = @max(a.limbs.len, 1);
    const r_cap: usize = @max(b.limbs.len, 1);

    const mem = allocBigIntWithCapacity(q_cap);
    const q_limbs = flixBigIntLimbs(mem)[0..q_cap];
    var q = big_int.Mutable.init(q_limbs, 0);

    const r_buf = rt_alloc.alloc(BigIntLimb, r_cap) catch @panic("oom");
    defer rt_alloc.free(r_buf);
    var r = big_int.Mutable.init(r_buf, 0);

    const tmp_len: usize = big_int.calcDivLimbsBufferLen(a.limbs.len, b.limbs.len);
    const tmp = rt_alloc.alloc(BigIntLimb, tmp_len) catch @panic("oom");
    defer rt_alloc.free(tmp);

    big_int.Mutable.divTrunc(&q, &r, a, b, tmp);
    storeBigIntHeader(mem, q);
    return mem;
}

export fn flix_bigint_rem(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    const b = flixBigIntToConst(b_ptr);
    if (big_int.Const.eqlZero(b)) trapDivByZero();

    const q_cap: usize = @max(a.limbs.len, 1);
    const r_cap: usize = @max(b.limbs.len, 1);

    const mem = allocBigIntWithCapacity(r_cap);
    const r_limbs = flixBigIntLimbs(mem)[0..r_cap];
    var r = big_int.Mutable.init(r_limbs, 0);

    const q_buf = rt_alloc.alloc(BigIntLimb, q_cap) catch @panic("oom");
    defer rt_alloc.free(q_buf);
    var q = big_int.Mutable.init(q_buf, 0);

    const tmp_len: usize = big_int.calcDivLimbsBufferLen(a.limbs.len, b.limbs.len);
    const tmp = rt_alloc.alloc(BigIntLimb, tmp_len) catch @panic("oom");
    defer rt_alloc.free(tmp);

    big_int.Mutable.divTrunc(&q, &r, a, b, tmp);
    storeBigIntHeader(mem, r);
    return mem;
}

fn bigintShiftAbs(shift: i32) usize {
    const s: i64 = shift;
    return if (s >= 0) @intCast(s) else @intCast(-s);
}

export fn flix_bigint_shl(ctx_ptr: *anyopaque, a_ptr: *anyopaque, shift: i32) *anyopaque {
    const a = flixBigIntToConst(a_ptr);

    const s: i64 = shift;
    if (s == 0) {
        const cap: usize = @max(a.limbs.len, 1);
        const mem = allocBigIntWithCapacity(cap);
        const limbs = flixBigIntLimbs(mem)[0..cap];
        var r = big_int.Mutable.init(limbs, 0);
        r.copy(a);
        storeBigIntHeader(mem, r);
        return mem;
    }

    if (s < 0) {
        const cap: usize = @max(a.limbs.len, 1);
        const mem = allocBigIntWithCapacity(cap);
        const limbs = flixBigIntLimbs(mem)[0..cap];
        var r = big_int.Mutable.init(limbs, 0);
        r.shiftRight(a, @intCast(-s));
        storeBigIntHeader(mem, r);
        return mem;
    }

    if (big_int.Const.eqlZero(a)) {
        return flix_bigint_from_i64(ctx_ptr, 0);
    }

    const s_abs: usize = @intCast(s);
    const limb_shift: usize = s_abs / bigint_limb_bits;
    const cap: usize = a.limbs.len + limb_shift + 1;
    if (cap > std.math.maxInt(u32)) @trap();

    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var r = big_int.Mutable.init(limbs, 0);
    r.shiftLeft(a, s_abs);
    storeBigIntHeader(mem, r);
    return mem;
}

export fn flix_bigint_shr(ctx_ptr: *anyopaque, a_ptr: *anyopaque, shift: i32) *anyopaque {
    const a = flixBigIntToConst(a_ptr);

    const s: i64 = shift;
    if (s == 0) {
        const cap: usize = @max(a.limbs.len, 1);
        const mem = allocBigIntWithCapacity(cap);
        const limbs = flixBigIntLimbs(mem)[0..cap];
        var r = big_int.Mutable.init(limbs, 0);
        r.copy(a);
        storeBigIntHeader(mem, r);
        return mem;
    }

    if (s < 0) {
        if (big_int.Const.eqlZero(a)) {
            return flix_bigint_from_i64(ctx_ptr, 0);
        }

        const s_abs: usize = @intCast(-s);
        const limb_shift: usize = s_abs / bigint_limb_bits;
        const cap: usize = a.limbs.len + limb_shift + 1;
        if (cap > std.math.maxInt(u32)) @trap();

        const mem = allocBigIntWithCapacity(cap);
        const limbs = flixBigIntLimbs(mem)[0..cap];
        var r = big_int.Mutable.init(limbs, 0);
        r.shiftLeft(a, s_abs);
        storeBigIntHeader(mem, r);
        return mem;
    }

    const cap: usize = @max(a.limbs.len, 1);
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var r = big_int.Mutable.init(limbs, 0);
    r.shiftRight(a, @intCast(s));
    storeBigIntHeader(mem, r);
    return mem;
}

export fn flix_bigint_and(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    const b = flixBigIntToConst(b_ptr);
    const cap: usize = @max(a.limbs.len, b.limbs.len) + 1;
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var r = big_int.Mutable.init(limbs, 0);
    r.bitAnd(a, b);
    storeBigIntHeader(mem, r);
    return mem;
}

export fn flix_bigint_or(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    const b = flixBigIntToConst(b_ptr);
    const cap: usize = @max(a.limbs.len, b.limbs.len) + 1;
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var r = big_int.Mutable.init(limbs, 0);
    r.bitOr(a, b);
    storeBigIntHeader(mem, r);
    return mem;
}

export fn flix_bigint_xor(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    const b = flixBigIntToConst(b_ptr);
    const cap: usize = @max(a.limbs.len, b.limbs.len) + 1;
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var r = big_int.Mutable.init(limbs, 0);
    r.bitXor(a, b);
    storeBigIntHeader(mem, r);
    return mem;
}

export fn flix_bigint_cmp(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) i32 {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    const b = flixBigIntToConst(b_ptr);
    return switch (big_int.Const.order(a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

export fn flix_bigint_bit_length(ctx_ptr: *anyopaque, a_ptr: *anyopaque) i32 {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    if (big_int.Const.eqlZero(a)) return 0;
    if (a.positive) {
        return i32FromBitCount(a.bitCountAbs());
    }
    const bits = a.bitCountTwosComp();
    return i32FromBitCount(bits - 1);
}

export fn flix_bigint_hash(ctx_ptr: *anyopaque, a_ptr: *anyopaque) i32 {
    _ = ctx_ptr;
    const a = flixBigIntToConst(a_ptr);
    if (big_int.Const.eqlZero(a)) return 0;

    var h: u32 = 0;
    if (comptime bigint_limb_bits == 32) {
        var i: usize = a.limbs.len;
        while (i > 0) : (i -= 1) {
            const w: u32 = @intCast(a.limbs[i - 1]);
            h = h *% 31 +% w;
        }
    } else if (comptime bigint_limb_bits == 64) {
        var i: usize = a.limbs.len;
        while (i > 0) : (i -= 1) {
            const limb: u64 = @intCast(a.limbs[i - 1]);
            const hi: u32 = @intCast(limb >> 32);
            const lo: u32 = @intCast(limb & 0xFFFF_FFFF);

            if (i == a.limbs.len) {
                if (hi != 0) {
                    h = h *% 31 +% hi;
                    h = h *% 31 +% lo;
                } else {
                    h = h *% 31 +% lo;
                }
            } else {
                h = h *% 31 +% hi;
                h = h *% 31 +% lo;
            }
        }
    } else {
        @panic("unsupported bigint limb size");
    }

    if (!a.positive) {
        h = 0 -% h;
    }
    return @bitCast(h);
}

// ============================================================================
// BigDecimal (portable, bring-up)
// ============================================================================

const FlixBigDecimalHeader = extern struct {
    obj: FlixObj,
    scale: i32,
    reserved: i32,
    unscaled: *anyopaque,
};

const BigDecimalRoundMode = enum {
    ceil,
    floor,
    half_even,
};

fn flixBigDecimalHeader(ptr: *anyopaque) *FlixBigDecimalHeader {
    return @ptrCast(@alignCast(ptr));
}

fn flixBigDecimalScale(ptr: *anyopaque) i32 {
    return flixBigDecimalHeader(ptr).scale;
}

fn flixBigDecimalUnscaled(ptr: *anyopaque) *anyopaque {
    return flixBigDecimalHeader(ptr).unscaled;
}

fn allocBigDecimal(unscaled_ptr: *anyopaque, scale: i32) *anyopaque {
    const mem = gcAllocBytes(@sizeOf(FlixBigDecimalHeader), &flix_ti_bigdecimal);
    const hdr = flixBigDecimalHeader(mem);
    hdr.scale = scale;
    hdr.reserved = 0;
    hdr.unscaled = unscaled_ptr;
    return mem;
}

export fn flix_trace_bigdecimal(ctx_ptr: *anyopaque, obj_ptr: *anyopaque) void {
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    const marker = ctx.gc_marker orelse return;
    gcMarkerMarkPayload(marker, payloadFromPtr(flixBigDecimalUnscaled(obj_ptr)));
}

fn tryAllocBigIntFromDecimalBytes(bytes: []const u8) ?*anyopaque {
    if (bytes.len == 0) return null;
    const digits_len: usize = if (bytes[0] == '-') bytes.len - 1 else bytes.len;
    if (digits_len == 0) return null;

    const cap: usize = big_int.calcSetStringLimbCount(10, digits_len);
    const mem = allocBigIntWithCapacity(cap);
    const limbs = flixBigIntLimbs(mem)[0..cap];
    var m = big_int.Mutable.init(limbs, 0);

    const tmp_len: usize = big_int.calcSetStringLimbsBufferLen(10, digits_len);
    const tmp = rt_alloc.alloc(BigIntLimb, tmp_len) catch @panic("oom");
    defer rt_alloc.free(tmp);

    m.setString(10, bytes, tmp, null) catch return null;
    if (m.eqlZero()) m.positive = true;

    storeBigIntHeader(mem, m);
    return mem;
}

fn bigIntPow10(ctx_ptr: *anyopaque, n: usize) *anyopaque {
    if (n == 0) return flix_bigint_from_i64(ctx_ptr, 1);
    const buf = rt_alloc.alloc(u8, n + 1) catch @panic("oom");
    defer rt_alloc.free(buf);
    buf[0] = '1';
    @memset(buf[1..], '0');
    return tryAllocBigIntFromDecimalBytes(buf) orelse @panic("invalid pow10");
}

fn bigIntIsZero(ptr: *anyopaque) bool {
    return big_int.Const.eqlZero(flixBigIntToConst(ptr));
}

fn bigIntSignum(ptr: *anyopaque) i32 {
    const a = flixBigIntToConst(ptr);
    if (big_int.Const.eqlZero(a)) return 0;
    return if (a.positive) 1 else -1;
}

fn bigIntAbsPtr(ctx_ptr: *anyopaque, ptr: *anyopaque) *anyopaque {
    return if (bigIntSignum(ptr) < 0) flix_bigint_neg(ctx_ptr, ptr) else ptr;
}

fn bigIntAbsDigitsAlloc(ptr: *anyopaque) []u8 {
    const bytes = flixBigIntToConst(ptr).toStringAlloc(rt_alloc, 10, .lower) catch @panic("oom");
    if (bytes.len > 0 and bytes[0] == '-') {
        const out = rt_alloc.alloc(u8, bytes.len - 1) catch @panic("oom");
        @memcpy(out, bytes[1..]);
        rt_alloc.free(bytes);
        return out;
    }
    return bytes;
}

fn bigIntGcd(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    const zero = flix_bigint_from_i64(ctx_ptr, 0);
    var x = bigIntAbsPtr(ctx_ptr, a_ptr);
    var y = bigIntAbsPtr(ctx_ptr, b_ptr);
    while (flix_bigint_cmp(ctx_ptr, y, zero) != 0) {
        const r = flix_bigint_rem(ctx_ptr, x, y);
        x = y;
        y = r;
    }
    return x;
}

fn i32FromCount(n: usize) i32 {
    if (n > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(n);
}

fn bigDecimalSignum(ptr: *anyopaque) i32 {
    return bigIntSignum(flixBigDecimalUnscaled(ptr));
}

fn bigDecimalScaleDiff(scale_hi: i32, scale_lo: i32) usize {
    const diff: i64 = @as(i64, scale_hi) - @as(i64, scale_lo);
    if (diff < 0) @panic("negative scale diff");
    return @intCast(diff);
}

fn bigDecimalAlignUnscaled(ctx_ptr: *anyopaque, bigint_ptr: *anyopaque, from_scale: i32, to_scale: i32) *anyopaque {
    if (from_scale == to_scale) return bigint_ptr;
    const diff = bigDecimalScaleDiff(to_scale, from_scale);
    const pow10 = bigIntPow10(ctx_ptr, diff);
    return flix_bigint_mul(ctx_ptr, bigint_ptr, pow10);
}

fn bigDecimalCompare(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) i32 {
    const scale_a = flixBigDecimalScale(a_ptr);
    const scale_b = flixBigDecimalScale(b_ptr);
    const unscaled_a = flixBigDecimalUnscaled(a_ptr);
    const unscaled_b = flixBigDecimalUnscaled(b_ptr);

    if (scale_a == scale_b) {
        return flix_bigint_cmp(ctx_ptr, unscaled_a, unscaled_b);
    }

    if (scale_a > scale_b) {
        const aligned_b = bigDecimalAlignUnscaled(ctx_ptr, unscaled_b, scale_b, scale_a);
        return flix_bigint_cmp(ctx_ptr, unscaled_a, aligned_b);
    } else {
        const aligned_a = bigDecimalAlignUnscaled(ctx_ptr, unscaled_a, scale_a, scale_b);
        return flix_bigint_cmp(ctx_ptr, aligned_a, unscaled_b);
    }
}

fn bigDecimalSetScaleZero(ctx_ptr: *anyopaque, bigdec_ptr: *anyopaque, mode: BigDecimalRoundMode) *anyopaque {
    const scale = flixBigDecimalScale(bigdec_ptr);
    const unscaled = flixBigDecimalUnscaled(bigdec_ptr);

    if (scale == 0) return allocBigDecimal(unscaled, 0);

    if (scale < 0) {
        const pow10 = bigIntPow10(ctx_ptr, @intCast(-@as(i64, scale)));
        const scaled = flix_bigint_mul(ctx_ptr, unscaled, pow10);
        return allocBigDecimal(scaled, 0);
    }

    const divisor = bigIntPow10(ctx_ptr, @intCast(@as(i64, scale)));
    var q = flix_bigint_div(ctx_ptr, unscaled, divisor);
    const r = flix_bigint_rem(ctx_ptr, unscaled, divisor);
    if (bigIntIsZero(r)) return allocBigDecimal(q, 0);

    switch (mode) {
        .ceil => {
            if (bigDecimalSignum(bigdec_ptr) > 0) {
                q = flix_bigint_add(ctx_ptr, q, flix_bigint_from_i64(ctx_ptr, 1));
            }
        },
        .floor => {
            if (bigDecimalSignum(bigdec_ptr) < 0) {
                q = flix_bigint_sub(ctx_ptr, q, flix_bigint_from_i64(ctx_ptr, 1));
            }
        },
        .half_even => {
            const abs_r = bigIntAbsPtr(ctx_ptr, r);
            const twice_abs_r = flix_bigint_add(ctx_ptr, abs_r, abs_r);
            const cmp_half = flix_bigint_cmp(ctx_ptr, twice_abs_r, divisor);
            if (cmp_half > 0) {
                if (bigDecimalSignum(bigdec_ptr) < 0) {
                    q = flix_bigint_sub(ctx_ptr, q, flix_bigint_from_i64(ctx_ptr, 1));
                } else {
                    q = flix_bigint_add(ctx_ptr, q, flix_bigint_from_i64(ctx_ptr, 1));
                }
            } else if (cmp_half == 0) {
                const rem2 = flix_bigint_rem(ctx_ptr, q, flix_bigint_from_i64(ctx_ptr, 2));
                if (!bigIntIsZero(rem2)) {
                    if (bigDecimalSignum(bigdec_ptr) < 0) {
                        q = flix_bigint_sub(ctx_ptr, q, flix_bigint_from_i64(ctx_ptr, 1));
                    } else {
                        q = flix_bigint_add(ctx_ptr, q, flix_bigint_from_i64(ctx_ptr, 1));
                    }
                }
            }
        },
    }

    return allocBigDecimal(q, 0);
}

fn bigDecimalPlainStringAlloc(ptr: *anyopaque) []u8 {
    const sign = bigDecimalSignum(ptr);
    const scale = flixBigDecimalScale(ptr);
    const digits = bigIntAbsDigitsAlloc(flixBigDecimalUnscaled(ptr));
    defer rt_alloc.free(digits);

    if (scale == 0) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(rt_alloc);
        if (sign < 0) out.append(rt_alloc, '-') catch @panic("oom");
        out.appendSlice(rt_alloc, digits) catch @panic("oom");
        return out.toOwnedSlice(rt_alloc) catch @panic("oom");
    }

    if (scale < 0) {
        if (sign == 0) return rt_alloc.dupe(u8, "0") catch @panic("oom");
        const zeros: usize = @intCast(-@as(i64, scale));
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(rt_alloc);
        if (sign < 0) out.append(rt_alloc, '-') catch @panic("oom");
        out.appendSlice(rt_alloc, digits) catch @panic("oom");
        out.appendNTimes(rt_alloc, '0', zeros) catch @panic("oom");
        return out.toOwnedSlice(rt_alloc) catch @panic("oom");
    }

    const insertion_point: i64 = @as(i64, @intCast(digits.len)) - @as(i64, scale);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(rt_alloc);
    if (insertion_point > 0) {
        if (sign < 0) out.append(rt_alloc, '-') catch @panic("oom");
        out.appendSlice(rt_alloc, digits[0..@intCast(insertion_point)]) catch @panic("oom");
        out.append(rt_alloc, '.') catch @panic("oom");
        out.appendSlice(rt_alloc, digits[@intCast(insertion_point)..]) catch @panic("oom");
    } else if (insertion_point == 0) {
        if (sign < 0) out.appendSlice(rt_alloc, "-0.") catch @panic("oom") else out.appendSlice(rt_alloc, "0.") catch @panic("oom");
        out.appendSlice(rt_alloc, digits) catch @panic("oom");
    } else {
        if (sign < 0) out.appendSlice(rt_alloc, "-0.") catch @panic("oom") else out.appendSlice(rt_alloc, "0.") catch @panic("oom");
        out.appendNTimes(rt_alloc, '0', @intCast(-insertion_point)) catch @panic("oom");
        out.appendSlice(rt_alloc, digits) catch @panic("oom");
    }
    return out.toOwnedSlice(rt_alloc) catch @panic("oom");
}

fn bigDecimalStringAlloc(ptr: *anyopaque) []u8 {
    const sign = bigDecimalSignum(ptr);
    const scale = flixBigDecimalScale(ptr);
    const digits = bigIntAbsDigitsAlloc(flixBigDecimalUnscaled(ptr));
    defer rt_alloc.free(digits);

    const adjusted_exp: i64 = @as(i64, @intCast(digits.len)) - 1 - @as(i64, scale);
    if (scale >= 0 and adjusted_exp >= -6) {
        return bigDecimalPlainStringAlloc(ptr);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(rt_alloc);
    if (sign < 0) out.append(rt_alloc, '-') catch @panic("oom");
    out.append(rt_alloc, digits[0]) catch @panic("oom");
    if (digits.len > 1) {
        out.append(rt_alloc, '.') catch @panic("oom");
        out.appendSlice(rt_alloc, digits[1..]) catch @panic("oom");
    }
    out.append(rt_alloc, 'E') catch @panic("oom");
    if (adjusted_exp >= 0) out.append(rt_alloc, '+') catch @panic("oom") else out.append(rt_alloc, '-') catch @panic("oom");
    const exp_abs: i64 = if (adjusted_exp < 0) -adjusted_exp else adjusted_exp;
    const exp_str = std.fmt.allocPrint(rt_alloc, "{d}", .{exp_abs}) catch @panic("oom");
    defer rt_alloc.free(exp_str);
    out.appendSlice(rt_alloc, exp_str) catch @panic("oom");
    return out.toOwnedSlice(rt_alloc) catch @panic("oom");
}

export fn flix_bigdec_try_parse(ctx_ptr: *anyopaque, str_ptr: *anyopaque) ?*anyopaque {
    _ = ctx_ptr;
    const len: usize = flixStringLen(str_ptr);
    const units = flixStringCodeUnits(str_ptr);

    var start: usize = 0;
    while (start < len and units[start] <= 32) : (start += 1) {}

    var end: usize = len;
    while (end > start and units[end - 1] <= 32) : (end -= 1) {}
    if (start >= end) return null;

    var neg: bool = false;
    if (units[start] == @as(u16, '+')) {
        start += 1;
    } else if (units[start] == @as(u16, '-')) {
        neg = true;
        start += 1;
    }
    if (start >= end) return null;

    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(rt_alloc);
    var frac_digits: i64 = 0;
    var saw_digit = false;
    var saw_dot = false;
    var i: usize = start;
    while (i < end) : (i += 1) {
        const cu: u16 = units[i];
        if (cu > 0x7F) return null;
        const b: u8 = @intCast(cu);
        if (b >= '0' and b <= '9') {
            digits.append(rt_alloc, b) catch @panic("oom");
            saw_digit = true;
            if (saw_dot) frac_digits += 1;
            continue;
        }
        if (b == '.') {
            if (saw_dot) return null;
            saw_dot = true;
            continue;
        }
        break;
    }

    if (!saw_digit) return null;

    var exponent: i64 = 0;
    if (i < end) {
        const cu: u16 = units[i];
        if (cu > 0x7F) return null;
        const b: u8 = @intCast(cu);
        if (b != 'e' and b != 'E') return null;
        i += 1;
        if (i >= end) return null;

        var exp_neg = false;
        const sign_cu: u16 = units[i];
        if (sign_cu > 0x7F) return null;
        const sign_b: u8 = @intCast(sign_cu);
        if (sign_b == '+') {
            i += 1;
        } else if (sign_b == '-') {
            exp_neg = true;
            i += 1;
        }
        if (i >= end) return null;

        var exp_digits = false;
        while (i < end) : (i += 1) {
            const exp_cu: u16 = units[i];
            if (exp_cu > 0x7F) return null;
            const exp_b: u8 = @intCast(exp_cu);
            if (exp_b < '0' or exp_b > '9') return null;
            exponent = exponent * 10 + (exp_b - '0');
            exp_digits = true;
        }
        if (!exp_digits) return null;
        if (exp_neg) exponent = -exponent;
    }

    if (i != end) return null;

    const scale64: i64 = frac_digits - exponent;
    if (scale64 < std.math.minInt(i32) or scale64 > std.math.maxInt(i32)) return null;

    const digits_slice = digits.items;
    if (digits_slice.len == 0) return null;

    const has_nonzero = blk: {
        for (digits_slice) |d| {
            if (d != '0') break :blk true;
        }
        break :blk false;
    };

    const unscaled_buf = rt_alloc.alloc(u8, digits_slice.len + @intFromBool(neg and has_nonzero)) catch @panic("oom");
    defer rt_alloc.free(unscaled_buf);

    var out_i: usize = 0;
    if (neg and has_nonzero) {
        unscaled_buf[0] = '-';
        out_i = 1;
    }
    @memcpy(unscaled_buf[out_i..], digits_slice);

    const unscaled = tryAllocBigIntFromDecimalBytes(unscaled_buf) orelse return null;
    return allocBigDecimal(unscaled, @intCast(scale64));
}

export fn flix_bigdec_from_string(ctx_ptr: *anyopaque, str_ptr: *anyopaque) *anyopaque {
    return flix_bigdec_try_parse(ctx_ptr, str_ptr) orelse @panic("invalid bigdecimal string");
}

export fn flix_bigdec_to_string(ctx_ptr: *anyopaque, bigdec_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const bytes = bigDecimalStringAlloc(bigdec_ptr);
    defer rt_alloc.free(bytes);
    return allocFlixStringFromAscii(bytes);
}

export fn flix_bigdec_to_plain_string(ctx_ptr: *anyopaque, bigdec_ptr: *anyopaque) *anyopaque {
    _ = ctx_ptr;
    const bytes = bigDecimalPlainStringAlloc(bigdec_ptr);
    defer rt_alloc.free(bytes);
    return allocFlixStringFromAscii(bytes);
}

export fn flix_bigdec_neg(ctx_ptr: *anyopaque, bigdec_ptr: *anyopaque) *anyopaque {
    const unscaled = flixBigDecimalUnscaled(bigdec_ptr);
    const negated = flix_bigint_neg(ctx_ptr, unscaled);
    return allocBigDecimal(negated, flixBigDecimalScale(bigdec_ptr));
}

export fn flix_bigdec_add(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    const scale_a = flixBigDecimalScale(a_ptr);
    const scale_b = flixBigDecimalScale(b_ptr);
    const out_scale = @max(scale_a, scale_b);
    const ua = bigDecimalAlignUnscaled(ctx_ptr, flixBigDecimalUnscaled(a_ptr), scale_a, out_scale);
    const ub = bigDecimalAlignUnscaled(ctx_ptr, flixBigDecimalUnscaled(b_ptr), scale_b, out_scale);
    const sum = flix_bigint_add(ctx_ptr, ua, ub);
    return allocBigDecimal(sum, out_scale);
}

export fn flix_bigdec_sub(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    const scale_a = flixBigDecimalScale(a_ptr);
    const scale_b = flixBigDecimalScale(b_ptr);
    const out_scale = @max(scale_a, scale_b);
    const ua = bigDecimalAlignUnscaled(ctx_ptr, flixBigDecimalUnscaled(a_ptr), scale_a, out_scale);
    const ub = bigDecimalAlignUnscaled(ctx_ptr, flixBigDecimalUnscaled(b_ptr), scale_b, out_scale);
    const diff = flix_bigint_sub(ctx_ptr, ua, ub);
    return allocBigDecimal(diff, out_scale);
}

export fn flix_bigdec_mul(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    const scale64: i64 = @as(i64, flixBigDecimalScale(a_ptr)) + @as(i64, flixBigDecimalScale(b_ptr));
    if (scale64 < std.math.minInt(i32) or scale64 > std.math.maxInt(i32)) @panic("bigdecimal scale overflow");
    const unscaled = flix_bigint_mul(ctx_ptr, flixBigDecimalUnscaled(a_ptr), flixBigDecimalUnscaled(b_ptr));
    return allocBigDecimal(unscaled, @intCast(scale64));
}

fn flixBigDecDivExact(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    const divisor_unscaled = flixBigDecimalUnscaled(b_ptr);
    if (bigIntIsZero(divisor_unscaled)) return flix_bigdec_from_string(ctx_ptr, allocFlixStringFromAscii("0"));

    var num = flixBigDecimalUnscaled(a_ptr);
    var den = divisor_unscaled;

    const gcd = bigIntGcd(ctx_ptr, num, den);
    num = flix_bigint_div(ctx_ptr, num, gcd);
    den = flix_bigint_div(ctx_ptr, den, gcd);

    const zero = flix_bigint_from_i64(ctx_ptr, 0);
    if (flix_bigint_cmp(ctx_ptr, den, zero) < 0) {
        num = flix_bigint_neg(ctx_ptr, num);
        den = flix_bigint_neg(ctx_ptr, den);
    }

    const two = flix_bigint_from_i64(ctx_ptr, 2);
    const five = flix_bigint_from_i64(ctx_ptr, 5);
    const one = flix_bigint_from_i64(ctx_ptr, 1);

    var twos: usize = 0;
    var fives: usize = 0;
    var den_term = den;
    while (bigIntIsZero(flix_bigint_rem(ctx_ptr, den_term, two))) {
        den_term = flix_bigint_div(ctx_ptr, den_term, two);
        twos += 1;
    }
    while (bigIntIsZero(flix_bigint_rem(ctx_ptr, den_term, five))) {
        den_term = flix_bigint_div(ctx_ptr, den_term, five);
        fives += 1;
    }
    if (flix_bigint_cmp(ctx_ptr, den_term, one) != 0) {
        @panic("non-terminating bigdecimal division");
    }

    const k: usize = @max(twos, fives);
    const scale64: i64 = @as(i64, flixBigDecimalScale(a_ptr)) - @as(i64, flixBigDecimalScale(b_ptr)) + @as(i64, @intCast(k));
    if (scale64 < std.math.minInt(i32) or scale64 > std.math.maxInt(i32)) @panic("bigdecimal scale overflow");

    const scaled_num = if (k == 0) num else flix_bigint_mul(ctx_ptr, num, bigIntPow10(ctx_ptr, k));
    const unscaled = flix_bigint_div(ctx_ptr, scaled_num, den);
    return allocBigDecimal(unscaled, @intCast(scale64));
}

export fn flix_bigdec_div(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) *anyopaque {
    return flixBigDecDivExact(ctx_ptr, a_ptr, b_ptr);
}

export fn flix_bigdec_cmp(ctx_ptr: *anyopaque, a_ptr: *anyopaque, b_ptr: *anyopaque) i32 {
    return bigDecimalCompare(ctx_ptr, a_ptr, b_ptr);
}

export fn flix_bigdec_hash(ctx_ptr: *anyopaque, a_ptr: *anyopaque) i32 {
    const bigint_hash = flix_bigint_hash(ctx_ptr, flixBigDecimalUnscaled(a_ptr));
    const h: u32 = @as(u32, @bitCast(bigint_hash)) *% 31 +% @as(u32, @bitCast(flixBigDecimalScale(a_ptr)));
    return @bitCast(h);
}

export fn flix_bigdec_scale(ctx_ptr: *anyopaque, a_ptr: *anyopaque) i32 {
    _ = ctx_ptr;
    return flixBigDecimalScale(a_ptr);
}

export fn flix_bigdec_precision(ctx_ptr: *anyopaque, a_ptr: *anyopaque) i32 {
    _ = ctx_ptr;
    const digits = bigIntAbsDigitsAlloc(flixBigDecimalUnscaled(a_ptr));
    defer rt_alloc.free(digits);
    return i32FromCount(digits.len);
}

export fn flix_bigdec_ceil(ctx_ptr: *anyopaque, a_ptr: *anyopaque) *anyopaque {
    return bigDecimalSetScaleZero(ctx_ptr, a_ptr, .ceil);
}

export fn flix_bigdec_floor(ctx_ptr: *anyopaque, a_ptr: *anyopaque) *anyopaque {
    return bigDecimalSetScaleZero(ctx_ptr, a_ptr, .floor);
}

export fn flix_bigdec_round(ctx_ptr: *anyopaque, a_ptr: *anyopaque) *anyopaque {
    return bigDecimalSetScaleZero(ctx_ptr, a_ptr, .half_even);
}

export fn flix_bigdec_to_bigint(ctx_ptr: *anyopaque, a_ptr: *anyopaque) *anyopaque {
    const scale = flixBigDecimalScale(a_ptr);
    const unscaled = flixBigDecimalUnscaled(a_ptr);
    if (scale == 0) return unscaled;
    if (scale < 0) {
        const pow10 = bigIntPow10(ctx_ptr, @intCast(-@as(i64, scale)));
        return flix_bigint_mul(ctx_ptr, unscaled, pow10);
    }
    const pow10 = bigIntPow10(ctx_ptr, @intCast(@as(i64, scale)));
    return flix_bigint_div(ctx_ptr, unscaled, pow10);
}

// ============================================================================
// Regex (bring-up)
// ============================================================================

const RegexObj = struct {
    re: c.regex_t,
    pattern_ascii: []u8,
    flags: i32,
};

const MatcherObj = struct {
    rgx: *RegexObj,
    input: [:0]u8,
    input_len: usize,
    region: [:0]u8,
    region_start: usize,
    region_end: usize,
    next_start: usize,
    last_start: isize,
    last_end: isize,
    matches: []c.regmatch_t,
};

const FlixStringHeader = extern struct {
    obj: FlixObj,
    len: u32,
    reserved: u32,
};

fn flixStringHeader(ptr: *anyopaque) *FlixStringHeader {
    return @ptrCast(@alignCast(ptr));
}

fn flixStringLen(ptr: *anyopaque) usize {
    return @intCast(flixStringHeader(ptr).len);
}

fn flixStringCodeUnits(ptr: *anyopaque) [*]u16 {
    const base: [*]u8 = @ptrCast(ptr);
    return @ptrCast(@alignCast(base + @sizeOf(FlixStringHeader)));
}

fn mapSimpleCase(cp: u32, from: []const u32, to: []const u32) u32 {
    // `from` must be sorted ascending and the same length as `to`.
    var lo: usize = 0;
    var hi: usize = from.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        const k: u32 = from[mid];
        if (cp < k) {
            hi = mid;
        } else if (cp > k) {
            lo = mid + 1;
        } else {
            return to[mid];
        }
    }
    return cp;
}

fn lookupIndex(cp: u32, keys: []const u32) ?usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        const k: u32 = keys[mid];
        if (cp < k) {
            hi = mid;
        } else if (cp > k) {
            lo = mid + 1;
        } else {
            return mid;
        }
    }
    return null;
}

fn inSortedList(cp: u32, keys: []const u32) bool {
    return lookupIndex(cp, keys) != null;
}

fn inRanges(cp: u32, ranges: []const unicode_case.Range) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.start) {
            hi = mid;
        } else if (cp > r.end) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn lookupSpecialUnits(cp: u32, cases: []const unicode_case.SpecialCase, values: []const u16) ?[]const u16 {
    var lo: usize = 0;
    var hi: usize = cases.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        const k: u32 = cases[mid].key;
        if (cp < k) {
            hi = mid;
        } else if (cp > k) {
            lo = mid + 1;
        } else {
            const off: usize = @intCast(cases[mid].offset);
            const len: usize = @intCast(cases[mid].len);
            return values[off .. off + len];
        }
    }
    return null;
}

fn unicodeToLowerSimple(cp: u32) u32 {
    return mapSimpleCase(cp, unicode_case.lower_simple_from[0..], unicode_case.lower_simple_to[0..]);
}

fn unicodeToUpperSimple(cp: u32) u32 {
    return mapSimpleCase(cp, unicode_case.upper_simple_from[0..], unicode_case.upper_simple_to[0..]);
}

fn unicodeToTitleSimple(cp: u32) u32 {
    return mapSimpleCase(cp, unicode_case.title_simple_from[0..], unicode_case.title_simple_to[0..]);
}

fn unicodeIsCased(cp: u32) bool {
    return inRanges(cp, unicode_case.cased_ranges[0..]);
}

fn unicodeIsCaseIgnorable(cp: u32) bool {
    return inRanges(cp, unicode_case.case_ignorable_ranges[0..]);
}

fn unicodeIsLetter(cp: u32) bool {
    return inRanges(cp, unicode_case.letter_ranges[0..]);
}

fn unicodeIsDigit(cp: u32) bool {
    return inRanges(cp, unicode_case.digit_ranges[0..]);
}

fn unicodeIsLowerCase(cp: u32) bool {
    return inRanges(cp, unicode_case.lowercase_ranges[0..]);
}

fn unicodeIsUpperCase(cp: u32) bool {
    return inRanges(cp, unicode_case.uppercase_ranges[0..]);
}

fn unicodeIsTitleCase(cp: u32) bool {
    return inRanges(cp, unicode_case.titlecase_ranges[0..]);
}

fn unicodeIsWhitespace(cp: u32) bool {
    return inRanges(cp, unicode_case.whitespace_ranges[0..]);
}

fn unicodeIsAlphabetic(cp: u32) bool {
    return inRanges(cp, unicode_case.alphabetic_ranges[0..]);
}

fn unicodeIsDefined(cp: u32) bool {
    return inRanges(cp, unicode_case.defined_ranges[0..]);
}

fn unicodeIsIdeographic(cp: u32) bool {
    return inRanges(cp, unicode_case.ideographic_ranges[0..]);
}

fn unicodeIsMirrored(cp: u32) bool {
    return inRanges(cp, unicode_case.mirrored_ranges[0..]);
}

fn unicodeDigitValue(cp: u32) i32 {
    if (lookupIndex(cp, unicode_case.digit_value_from[0..])) |idx| {
        return @intCast(unicode_case.digit_value_to[idx]);
    }
    return -1;
}

fn unicodeNumericValue(cp: u32) i32 {
    if (lookupIndex(cp, unicode_case.numeric_int_from[0..])) |idx| {
        return unicode_case.numeric_int_to[idx];
    }
    if (inSortedList(cp, unicode_case.numeric_nonint_from[0..])) {
        return -2;
    }
    return -1;
}

fn unicodeDirectName(cp: u32) ?[]const u8 {
    if (lookupIndex(cp, unicode_case.name_from[0..])) |idx| {
        const offset: usize = @intCast(unicode_case.name_offsets[idx]);
        const len: usize = unicode_case.name_lengths[idx];
        return unicode_case.name_bytes[offset .. offset + len];
    }
    return null;
}

fn unicodeBlockName(cp: u32) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = unicode_case.unicode_blocks.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        const block = unicode_case.unicode_blocks[mid];
        if (cp < block.start) {
            hi = mid;
        } else if (cp > block.end) {
            lo = mid + 1;
        } else {
            const offset: usize = @intCast(block.name_offset);
            const len: usize = block.name_len;
            return unicode_case.unicode_block_name_bytes[offset .. offset + len];
        }
    }
    return null;
}

fn allocCodePointName(ctx_ptr: *anyopaque, cp: u32) ?*anyopaque {
    _ = ctx_ptr;
    if (cp > 0x10FFFF or !unicodeIsDefined(cp)) return null;
    if (unicodeDirectName(cp)) |name| {
        return allocFlixStringFromAscii(name);
    }

    const hex = std.fmt.allocPrint(rt_alloc, "{X}", .{cp}) catch @panic("oom");
    defer rt_alloc.free(hex);

    if (unicodeBlockName(cp)) |block_name| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(rt_alloc);
        out.appendSlice(rt_alloc, block_name) catch @panic("oom");
        out.append(rt_alloc, ' ') catch @panic("oom");
        out.appendSlice(rt_alloc, hex) catch @panic("oom");
        const bytes = out.toOwnedSlice(rt_alloc) catch @panic("oom");
        defer rt_alloc.free(bytes);
        return allocFlixStringFromAscii(bytes);
    }

    return allocFlixStringFromAscii(hex);
}

const DecodedCpAt = struct { cp: u32, len: usize };
const DecodedCpBefore = struct { cp: u32, start: usize, len: usize };

fn decodeCodePointAt(units: []const u16, i: usize) DecodedCpAt {
    const cu0: u16 = units[i];
    if (std.unicode.utf16IsHighSurrogate(cu0) and i + 1 < units.len) {
        const cu1: u16 = units[i + 1];
        if (std.unicode.utf16IsLowSurrogate(cu1)) {
            const pair = [_]u16{ cu0, cu1 };
            const cp: u32 = std.unicode.utf16DecodeSurrogatePair(&pair) catch unreachable;
            return .{ .cp = cp, .len = 2 };
        }
    }
    return .{ .cp = cu0, .len = 1 };
}

fn decodeCodePointBefore(units: []const u16, end: usize) DecodedCpBefore {
    if (end == 0) @panic("decodeCodePointBefore: end==0");
    const cu1: u16 = units[end - 1];
    if (std.unicode.utf16IsLowSurrogate(cu1) and end >= 2) {
        const cu0: u16 = units[end - 2];
        if (std.unicode.utf16IsHighSurrogate(cu0)) {
            const pair = [_]u16{ cu0, cu1 };
            const cp: u32 = std.unicode.utf16DecodeSurrogatePair(&pair) catch unreachable;
            return .{ .cp = cp, .start = end - 2, .len = 2 };
        }
    }
    return .{ .cp = cu1, .start = end - 1, .len = 1 };
}

fn skipCaseIgnorableForwards(units: []const u16, start: usize) usize {
    var i: usize = start;
    while (i < units.len) {
        const d = decodeCodePointAt(units, i);
        if (!unicodeIsCaseIgnorable(d.cp)) break;
        i += d.len;
    }
    return i;
}

fn skipCaseIgnorableBackwards(units: []const u16, end: usize) usize {
    var i: usize = end;
    while (i > 0) {
        const d = decodeCodePointBefore(units, i);
        if (!unicodeIsCaseIgnorable(d.cp)) break;
        i = d.start;
    }
    return i;
}

fn isFinalSigma(units: []const u16, sigma_start: usize, sigma_len: usize) bool {
    // Unicode Default Case Algorithms: `Final_Sigma` condition.
    const before_end = skipCaseIgnorableBackwards(units, sigma_start);
    const has_cased_before = before_end > 0 and unicodeIsCased(decodeCodePointBefore(units, before_end).cp);

    const after_start = skipCaseIgnorableForwards(units, sigma_start + sigma_len);
    const has_cased_after = after_start < units.len and unicodeIsCased(decodeCodePointAt(units, after_start).cp);

    return has_cased_before and !has_cased_after;
}

fn appendUtf16FromCodepointRaw(list: *std.ArrayList(u16), alloc: std.mem.Allocator, cp: u32) std.mem.Allocator.Error!void {
    if (cp <= 0xFFFF) {
        try list.append(alloc, @intCast(cp));
        return;
    }
    if (cp > 0x10FFFF) {
        try list.append(alloc, 0xFFFD);
        return;
    }
    const x: u32 = cp - 0x10000;
    const hi: u16 = @intCast(0xD800 + ((x >> 10) & 0x3FF));
    const lo: u16 = @intCast(0xDC00 + (x & 0x3FF));
    try list.append(alloc, hi);
    try list.append(alloc, lo);
}

fn allocFlixStringFromUtf16Units(ctx_ptr: *anyopaque, units: []const u16) *anyopaque {
    if (units.len > std.math.maxInt(u32)) @panic("string too long");
    const size_bytes: usize = @sizeOf(FlixStringHeader) + units.len * @sizeOf(u16);
    const mem = flix_alloc_flex(ctx_ptr, &flix_ti_string, @intCast(size_bytes));
    const header: *FlixStringHeader = @ptrCast(@alignCast(mem));
    header.len = @intCast(units.len);
    header.reserved = 0;

    const dst_units: [*]u16 = flixStringCodeUnits(mem);
    @memcpy(dst_units[0..units.len], units);
    return mem;
}

export fn flix_char_to_lower_case(ch: i32) i32 {
    if (ch < 0) return ch;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return ch;
    const mapped: u32 = unicodeToLowerSimple(cp);
    return if (mapped <= 0xFFFF) @intCast(mapped) else ch;
}

export fn flix_char_to_upper_case(ch: i32) i32 {
    if (ch < 0) return ch;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return ch;
    const mapped: u32 = unicodeToUpperSimple(cp);
    return if (mapped <= 0xFFFF) @intCast(mapped) else ch;
}

export fn flix_char_to_title_case(ch: i32) i32 {
    if (ch < 0) return ch;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return ch;

    const title: u32 = unicodeToTitleSimple(cp);
    if (title != cp and title <= 0xFFFF) return @intCast(title);

    const upper: u32 = unicodeToUpperSimple(cp);
    return if (upper <= 0xFFFF) @intCast(upper) else ch;
}

export fn flix_char_is_letter(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return false;
    return unicodeIsLetter(cp);
}

export fn flix_char_is_digit(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return false;
    return unicodeIsDigit(cp);
}

export fn flix_char_is_letter_or_digit(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return false;
    return unicodeIsLetter(cp) or unicodeIsDigit(cp);
}

export fn flix_char_is_lower_case(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return false;
    return unicodeIsLowerCase(cp);
}

export fn flix_char_is_upper_case(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return false;
    return unicodeIsUpperCase(cp);
}

export fn flix_char_is_title_case(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return false;
    return unicodeIsTitleCase(cp);
}

export fn flix_char_is_whitespace(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return false;
    return unicodeIsWhitespace(cp);
}

export fn flix_char_is_defined(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return false;
    return unicodeIsDefined(cp);
}

export fn flix_char_is_iso_control(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return false;
    return (cp <= 0x1F) or (cp >= 0x7F and cp <= 0x9F);
}

export fn flix_char_is_mirrored(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return false;
    return unicodeIsMirrored(cp);
}

export fn flix_char_is_surrogate(ch: i32) bool {
    if (ch < 0) return false;
    const cp: u32 = @intCast(ch);
    return (cp >= 0xD800 and cp <= 0xDFFF);
}

export fn flix_char_is_surrogate_pair(high: i32, low: i32) bool {
    if (high < 0 or low < 0) return false;
    const hi: u32 = @intCast(high);
    const lo: u32 = @intCast(low);
    return (hi >= 0xD800 and hi <= 0xDBFF) and (lo >= 0xDC00 and lo <= 0xDFFF);
}

export fn flix_char_to_code_point(high: i32, low: i32) i32 {
    // NOTE: No validation (matches the Flix stdlib contract).
    const hi: u32 = @intCast(high);
    const lo: u32 = @intCast(low);
    const cp: u32 = ((hi - 0xD800) << 10) + (lo - 0xDC00) + 0x10000;
    return @intCast(cp);
}

export fn flix_char_get_numeric_value(ch: i32) i32 {
    if (ch < 0) return -1;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return -1;

    // Java-compatible fast path for ASCII + fullwidth letters/digits.
    if (cp >= 0x0030 and cp <= 0x0039) return @intCast(cp - 0x0030);
    if (cp >= 0x0041 and cp <= 0x005A) return @intCast(cp - 0x0041 + 10);
    if (cp >= 0x0061 and cp <= 0x007A) return @intCast(cp - 0x0061 + 10);
    if (cp >= 0xFF10 and cp <= 0xFF19) return @intCast(cp - 0xFF10);
    if (cp >= 0xFF21 and cp <= 0xFF3A) return @intCast(cp - 0xFF21 + 10);
    if (cp >= 0xFF41 and cp <= 0xFF5A) return @intCast(cp - 0xFF41 + 10);

    return unicodeNumericValue(cp);
}

export fn flix_codepoint_is_letter(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return unicodeIsLetter(ucp);
}

export fn flix_codepoint_is_digit(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return unicodeIsDigit(ucp);
}

export fn flix_codepoint_is_lower_case(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return unicodeIsLowerCase(ucp);
}

export fn flix_codepoint_is_upper_case(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return unicodeIsUpperCase(ucp);
}

export fn flix_codepoint_is_title_case(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return unicodeIsTitleCase(ucp);
}

export fn flix_codepoint_is_whitespace(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return unicodeIsWhitespace(ucp);
}

export fn flix_codepoint_is_alphabetic(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return unicodeIsAlphabetic(ucp);
}

export fn flix_codepoint_is_defined(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return unicodeIsDefined(ucp);
}

export fn flix_codepoint_is_ideographic(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return unicodeIsIdeographic(ucp);
}

export fn flix_codepoint_is_iso_control(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return (ucp <= 0x1F) or (ucp >= 0x7F and ucp <= 0x9F);
}

export fn flix_codepoint_is_mirrored(cp: i32) bool {
    if (cp < 0) return false;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return false;
    return unicodeIsMirrored(ucp);
}

export fn flix_codepoint_to_lower_case(cp: i32) i32 {
    if (cp < 0) return cp;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return cp;
    return @intCast(unicodeToLowerSimple(ucp));
}

export fn flix_codepoint_to_upper_case(cp: i32) i32 {
    if (cp < 0) return cp;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return cp;
    return @intCast(unicodeToUpperSimple(ucp));
}

export fn flix_codepoint_to_title_case(cp: i32) i32 {
    if (cp < 0) return cp;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return cp;
    const title = unicodeToTitleSimple(ucp);
    return if (title != ucp) @intCast(title) else @intCast(unicodeToUpperSimple(ucp));
}

export fn flix_codepoint_get_name(ctx_ptr: *anyopaque, cp: i32) ?*anyopaque {
    if (cp < 0) return null;
    return allocCodePointName(ctx_ptr, @intCast(cp));
}

export fn flix_codepoint_get_numeric_value(cp: i32) i32 {
    if (cp < 0) return -1;
    const ucp: u32 = @intCast(cp);
    if (ucp > 0x10FFFF) return -1;

    if (ucp >= 0x0030 and ucp <= 0x0039) return @intCast(ucp - 0x0030);
    if (ucp >= 0x0041 and ucp <= 0x005A) return @intCast(ucp - 0x0041 + 10);
    if (ucp >= 0x0061 and ucp <= 0x007A) return @intCast(ucp - 0x0061 + 10);
    if (ucp >= 0xFF10 and ucp <= 0xFF19) return @intCast(ucp - 0xFF10);
    if (ucp >= 0xFF21 and ucp <= 0xFF3A) return @intCast(ucp - 0xFF21 + 10);
    if (ucp >= 0xFF41 and ucp <= 0xFF5A) return @intCast(ucp - 0xFF41 + 10);

    return unicodeNumericValue(ucp);
}

export fn flix_char_digit(ch: i32, radix: i32) i32 {
    if (radix < 2 or radix > 36) return -1;
    if (ch < 0) return -1;
    const cp: u32 = @intCast(ch);
    if (cp > 0xFFFF) return -1;

    var v: i32 = -1;

    // ASCII + fullwidth digits/letters (Java compatible).
    if (cp >= 0x0030 and cp <= 0x0039) { // '0'..'9'
        v = @intCast(cp - 0x0030);
    } else if (cp >= 0x0041 and cp <= 0x005A) { // 'A'..'Z'
        v = @intCast(cp - 0x0041 + 10);
    } else if (cp >= 0x0061 and cp <= 0x007A) { // 'a'..'z'
        v = @intCast(cp - 0x0061 + 10);
    } else if (cp >= 0xFF10 and cp <= 0xFF19) { // fullwidth '0'..'9'
        v = @intCast(cp - 0xFF10);
    } else if (cp >= 0xFF21 and cp <= 0xFF3A) { // fullwidth 'A'..'Z'
        v = @intCast(cp - 0xFF21 + 10);
    } else if (cp >= 0xFF41 and cp <= 0xFF5A) { // fullwidth 'a'..'z'
        v = @intCast(cp - 0xFF41 + 10);
    } else {
        v = unicodeDigitValue(cp);
    }

    if (v >= 0 and v < radix) return v;
    return -1;
}

export fn flix_string_to_lower_case(ctx_ptr: *anyopaque, str_ptr: *anyopaque) *anyopaque {
    const in_len: usize = flixStringLen(str_ptr);
    const in_units_ptr: [*]const u16 = flixStringCodeUnits(str_ptr);
    const in_units: []const u16 = in_units_ptr[0..in_len];

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt_alloc);
    out.ensureTotalCapacity(rt_alloc, in_len) catch @panic("oom");

    var i: usize = 0;
    while (i < in_units.len) {
        const d = decodeCodePointAt(in_units, i);
        const cp = d.cp;

        // Full special casing (unconditional) from SpecialCasing.txt.
        if (lookupSpecialUnits(cp, unicode_case.lower_full_cases[0..], unicode_case.lower_full_values[0..])) |seq| {
            out.appendSlice(rt_alloc, seq) catch @panic("oom");
            i += d.len;
            continue;
        }

        // Context-sensitive final sigma.
        if (cp == 0x03A3) { // Σ
            const mapped: u32 = if (isFinalSigma(in_units, i, d.len)) 0x03C2 else 0x03C3;
            appendUtf16FromCodepointRaw(&out, rt_alloc, mapped) catch @panic("oom");
            i += d.len;
            continue;
        }

        const mapped: u32 = unicodeToLowerSimple(cp);
        appendUtf16FromCodepointRaw(&out, rt_alloc, mapped) catch @panic("oom");
        i += d.len;
    }

    return allocFlixStringFromUtf16Units(ctx_ptr, out.items);
}

export fn flix_string_to_upper_case(ctx_ptr: *anyopaque, str_ptr: *anyopaque) *anyopaque {
    const in_len: usize = flixStringLen(str_ptr);
    const in_units_ptr: [*]const u16 = flixStringCodeUnits(str_ptr);
    const in_units: []const u16 = in_units_ptr[0..in_len];

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt_alloc);
    out.ensureTotalCapacity(rt_alloc, in_len) catch @panic("oom");

    var i: usize = 0;
    while (i < in_units.len) {
        const d = decodeCodePointAt(in_units, i);
        const cp = d.cp;

        // Full special casing (unconditional) from SpecialCasing.txt.
        if (lookupSpecialUnits(cp, unicode_case.upper_full_cases[0..], unicode_case.upper_full_values[0..])) |seq| {
            out.appendSlice(rt_alloc, seq) catch @panic("oom");
            i += d.len;
            continue;
        }

        const mapped: u32 = unicodeToUpperSimple(cp);
        appendUtf16FromCodepointRaw(&out, rt_alloc, mapped) catch @panic("oom");
        i += d.len;
    }

    return allocFlixStringFromUtf16Units(ctx_ptr, out.items);
}

const FlixArrayHeader = extern struct {
    obj: FlixObj,
    len: u32,
    elem_size: u32,
};

fn flixArrayHeader(ptr: *anyopaque) *FlixArrayHeader {
    return @ptrCast(@alignCast(ptr));
}

fn flixArraySlots(ptr: *anyopaque) [*]i64 {
    if (flixArrayElemSize(ptr) != @sizeOf(i64)) @panic("expected slot array");
    const base: [*]u8 = @ptrCast(ptr);
    return @ptrCast(@alignCast(base + @sizeOf(FlixArrayHeader)));
}

fn flixArrayLen(ptr: *anyopaque) usize {
    return @intCast(flixArrayHeader(ptr).len);
}

fn flixArrayElemSize(ptr: *anyopaque) usize {
    return @intCast(flixArrayHeader(ptr).elem_size);
}

fn flixInt8ArrayBytesView(arr_ptr: *anyopaque) []const u8 {
    if (flixArrayElemSize(arr_ptr) != 1) @panic("expected int8 byte array");
    const len: usize = flixArrayLen(arr_ptr);
    const base: [*]const u8 = @ptrCast(arr_ptr);
    const bytes_ptr: [*]const u8 = base + @sizeOf(FlixArrayHeader);
    return bytes_ptr[0..len];
}

fn flixInt8ArrayBytesViewMut(arr_ptr: *anyopaque) []u8 {
    if (flixArrayElemSize(arr_ptr) != 1) @panic("expected int8 byte array");
    const len: usize = flixArrayLen(arr_ptr);
    const base: [*]u8 = @ptrCast(arr_ptr);
    const bytes_ptr: [*]u8 = base + @sizeOf(FlixArrayHeader);
    return bytes_ptr[0..len];
}

fn flixInt8ArrayToBytes(allocator: std.mem.Allocator, arr_ptr: *anyopaque) []u8 {
    const src = flixInt8ArrayBytesView(arr_ptr);
    return allocator.dupe(u8, src) catch @panic("oom");
}

fn allocFlixInt8ArrayFromBytes(bytes: []const u8) *anyopaque {
    const len: usize = bytes.len;
    const size_bytes: usize = @sizeOf(FlixArrayHeader) + len;

    const mem = gcAllocBytes(size_bytes, &flix_ti_array_prim);
    const header: *FlixArrayHeader = @ptrCast(@alignCast(mem));
    header.len = @intCast(len);
    header.elem_size = 1;

    const base: [*]u8 = @ptrCast(mem);
    const dst_ptr: [*]u8 = base + @sizeOf(FlixArrayHeader);
    std.mem.copyForwards(u8, dst_ptr[0..len], bytes);

    return mem;
}

fn allocFlixInt8ArrayFromBytesInRegion(ctx: *anyopaque, region_ptr0: ?*anyopaque, bytes: []const u8) *anyopaque {
    const len: usize = bytes.len;
    const size_bytes_i64: i64 = @intCast(@sizeOf(FlixArrayHeader) + len);

    const mem = flix_region_alloc_flex(ctx, region_ptr0, &flix_ti_array_prim, size_bytes_i64);
    const header: *FlixArrayHeader = @ptrCast(@alignCast(mem));
    header.len = @intCast(len);
    header.elem_size = 1;

    const base: [*]u8 = @ptrCast(mem);
    const dst_ptr: [*]u8 = base + @sizeOf(FlixArrayHeader);
    std.mem.copyForwards(u8, dst_ptr[0..len], bytes);

    return mem;
}

fn flixWriteBytesToInt8Array(arr_ptr: *anyopaque, bytes: []const u8) void {
    var dst = flixInt8ArrayBytesViewMut(arr_ptr);
    const n: usize = @min(dst.len, bytes.len);
    std.mem.copyForwards(u8, dst[0..n], bytes[0..n]);
}

fn parsePortOrInvalid(port: i32) ?u16 {
    if (port < 0 or port > std.math.maxInt(u16)) return null;
    return @intCast(port);
}

fn flixStringToAsciiZ(ptr: *anyopaque) [:0]u8 {
    const len: usize = flixStringLen(ptr);
    const units: [*]const u16 = flixStringCodeUnits(ptr);

    const mem = c.malloc(len + 1) orelse @panic("malloc failed");
    const bytes: [*]u8 = @ptrCast(mem);

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const cu: u16 = units[i];
        if (cu > 0x7f) @panic("regex bring-up: non-ASCII string not supported");
        bytes[i] = @intCast(cu);
    }
    bytes[len] = 0;

    return bytes[0..len :0];
}

fn flixStringToAsciiZInRegion(ctx: *anyopaque, region_ptr0: ?*anyopaque, ptr: *anyopaque) [:0]u8 {
    const len: usize = flixStringLen(ptr);
    const units: [*]const u16 = flixStringCodeUnits(ptr);

    const size_bytes_i64: i64 = @intCast(len + 1);
    const mem = flix_region_malloc(ctx, region_ptr0, size_bytes_i64);
    const bytes: [*]u8 = @ptrCast(@alignCast(mem));

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const cu: u16 = units[i];
        if (cu > 0x7f) @panic("regex bring-up: non-ASCII string not supported");
        bytes[i] = @intCast(cu);
    }
    bytes[len] = 0;

    return bytes[0..len :0];
}

fn flagsToPosix(flags: i32) i32 {
    var f: i32 = c.REG_EXTENDED;
    if ((flags & 2) != 0) { // Pattern.CASE_INSENSITIVE
        f |= c.REG_ICASE;
    }
    return f;
}

fn isRegexMeta(ch: u8) bool {
    return switch (ch) {
        '\\', '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

fn quoteRegexAscii(bytes: []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(rt_alloc);

    for (bytes) |ch| {
        if (isRegexMeta(ch)) out.append(rt_alloc, '\\') catch @panic("oom");
        out.append(rt_alloc, ch) catch @panic("oom");
    }

    return out.toOwnedSlice(rt_alloc) catch @panic("oom");
}

fn allocFlixArrayFromPtrPayloads(ptrs: []const *anyopaque) *anyopaque {
    const len: usize = ptrs.len;
    const size_bytes: usize = @sizeOf(FlixArrayHeader) + len * @sizeOf(i64);

    const mem = gcAllocBytes(size_bytes, &flix_ti_array_ptr);
    const header: *FlixArrayHeader = @ptrCast(@alignCast(mem));
    header.len = @intCast(len);
    header.elem_size = @intCast(@sizeOf(i64));

    const slots_ptr: [*]i64 = flixArraySlots(@ptrCast(mem));
    var i: usize = 0;
    while (i < len) : (i += 1) {
        slots_ptr[i] = payloadFromPtr(ptrs[i]);
    }

    return mem;
}

fn allocFlixArrayFromPtrPayloadsInRegion(ctx: *anyopaque, region_ptr0: ?*anyopaque, ptrs: []const *anyopaque) *anyopaque {
    const len: usize = ptrs.len;
    const size_bytes_i64: i64 = @intCast(@sizeOf(FlixArrayHeader) + len * @sizeOf(i64));

    const mem = flix_region_alloc_flex(ctx, region_ptr0, &flix_ti_array_ptr, size_bytes_i64);
    const header: *FlixArrayHeader = @ptrCast(@alignCast(mem));
    header.len = @intCast(len);
    header.elem_size = @intCast(@sizeOf(i64));

    const slots_ptr: [*]i64 = flixArraySlots(mem);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        flix_store_ptr(ctx, @ptrCast(&slots_ptr[i]), payloadFromPtr(ptrs[i]));
    }

    if (len > 0) {
        flix_region_remember_ptr_array(ctx, region_ptr0, @ptrCast(slots_ptr), @intCast(len));
    }
    return mem;
}

fn allocFlixArrayFromPayloadsInRegion(ctx: *anyopaque, region_ptr0: ?*anyopaque, payloads: []const i64) *anyopaque {
    const len: usize = payloads.len;
    const size_bytes_i64: i64 = @intCast(@sizeOf(FlixArrayHeader) + len * @sizeOf(i64));

    const mem = flix_region_alloc_flex(ctx, region_ptr0, &flix_ti_array_prim, size_bytes_i64);
    const header: *FlixArrayHeader = @ptrCast(@alignCast(mem));
    header.len = @intCast(len);
    header.elem_size = @intCast(@sizeOf(i64));

    const slots_ptr: [*]i64 = flixArraySlots(mem);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        slots_ptr[i] = payloads[i];
    }

    return mem;
}

export fn flix_regex_compile(pattern_ptr: *anyopaque) *anyopaque {
    return flix_regex_compile_with_flags(0, pattern_ptr);
}

export fn flix_regex_compile_with_flags(flags: i32, pattern_ptr: *anyopaque) *anyopaque {
    const pat_z = flixStringToAsciiZ(pattern_ptr);
    defer c.free(@ptrCast(pat_z.ptr));

    const pat_copy = rt_alloc.dupe(u8, pat_z[0..pat_z.len]) catch @panic("oom");

    const literal = (flags & 16) != 0; // Pattern.LITERAL
    var quoted: []u8 = &.{};
    defer if (quoted.len != 0) rt_alloc.free(quoted);

    const pat_ptr: [*:0]const u8 = if (literal) blk: {
        quoted = quoteRegexAscii(pat_z[0..pat_z.len]);
        // Ensure zero-termination for C.
        const mem = c.malloc(quoted.len + 1) orelse @panic("malloc failed");
        const bytes: [*]u8 = @ptrCast(mem);
        std.mem.copyForwards(u8, bytes[0..quoted.len], quoted);
        bytes[quoted.len] = 0;
        break :blk @ptrCast(bytes);
    } else pat_z.ptr;

    defer if (literal) c.free(@ptrCast(@constCast(pat_ptr)));

    const obj = rt_alloc.create(RegexObj) catch @panic("oom");
    obj.pattern_ascii = pat_copy;
    obj.flags = flags;

    const rc = c.regcomp(&obj.re, pat_ptr, flagsToPosix(flags));
    if (rc != 0) @panic("regex compilation failed");

    return obj;
}

export fn flix_regex_try_compile(pattern_ptr: *anyopaque) *anyopaque {
    return flix_regex_try_compile_with_flags(0, pattern_ptr);
}

export fn flix_regex_try_compile_with_flags(flags: i32, pattern_ptr: *anyopaque) *anyopaque {
    const pat_z = flixStringToAsciiZ(pattern_ptr);
    defer c.free(@ptrCast(pat_z.ptr));

    const pat_copy = rt_alloc.dupe(u8, pat_z[0..pat_z.len]) catch @panic("oom");

    const literal = (flags & 16) != 0; // Pattern.LITERAL
    var quoted: []u8 = &.{};
    defer if (quoted.len != 0) rt_alloc.free(quoted);

    const pat_ptr: [*:0]const u8 = if (literal) blk: {
        quoted = quoteRegexAscii(pat_z[0..pat_z.len]);
        const mem = c.malloc(quoted.len + 1) orelse @panic("malloc failed");
        const bytes: [*]u8 = @ptrCast(mem);
        std.mem.copyForwards(u8, bytes[0..quoted.len], quoted);
        bytes[quoted.len] = 0;
        break :blk @ptrCast(bytes);
    } else pat_z.ptr;

    defer if (literal) c.free(@ptrCast(@constCast(pat_ptr)));

    var re: c.regex_t = undefined;
    const rc = c.regcomp(&re, pat_ptr, flagsToPosix(flags));
    if (rc != 0) {
        rt_alloc.free(pat_copy);
        var buf: [256]u8 = undefined;
        _ = c.regerror(rc, &re, &buf, buf.len);
        const msg_len: usize = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
        const msg_ptr = allocFlixStringFromAscii(buf[0..msg_len]);

        const payloads = [_]i64{
            0, // ok = false
            0, // regex = null
            @bitCast(@as(u64, @intCast(@intFromPtr(msg_ptr)))),
        };
        return allocFlixTupleFromPayloads(&payloads, 0b110);
    }

    const obj = rt_alloc.create(RegexObj) catch @panic("oom");
    obj.re = re;
    obj.pattern_ascii = pat_copy;
    obj.flags = flags;

    const empty_msg = allocFlixStringFromAscii("");
    const payloads = [_]i64{
        1, // ok = true
        @bitCast(@as(u64, @intCast(@intFromPtr(obj)))),
        @bitCast(@as(u64, @intCast(@intFromPtr(empty_msg)))),
    };
    return allocFlixTupleFromPayloads(&payloads, 0b110);
}

export fn flix_regex_quote(input_ptr: *anyopaque) *anyopaque {
    const in_z = flixStringToAsciiZ(input_ptr);
    defer c.free(@ptrCast(in_z.ptr));

    const quoted = quoteRegexAscii(in_z[0..in_z.len]);
    defer rt_alloc.free(quoted);
    return allocFlixStringFromAscii(quoted);
}

export fn flix_regex_pattern(rgx_ptr: *anyopaque) *anyopaque {
    const rgx: *RegexObj = @ptrCast(@alignCast(rgx_ptr));
    return allocFlixStringFromAscii(rgx.pattern_ascii);
}

export fn flix_regex_flags(rgx_ptr: *anyopaque) i32 {
    const rgx: *RegexObj = @ptrCast(@alignCast(rgx_ptr));
    return rgx.flags;
}

export fn flix_regex_new_matcher(ctx: *anyopaque, region_ptr0: ?*anyopaque, rgx_ptr: *anyopaque, input_ptr: *anyopaque) *anyopaque {
    const rgx: *RegexObj = @ptrCast(@alignCast(rgx_ptr));
    const input = flixStringToAsciiZInRegion(ctx, region_ptr0, input_ptr);

    const m_mem = flix_region_malloc(ctx, region_ptr0, @intCast(@sizeOf(MatcherObj)));
    const m: *MatcherObj = @ptrCast(@alignCast(m_mem));
    m.rgx = rgx;
    m.input = input;
    m.input_len = input.len;
    m.region = input;
    m.region_start = 0;
    m.region_end = input.len;
    m.next_start = 0;
    m.last_start = -1;
    m.last_end = -1;
    const nmatch: usize = @as(usize, @intCast(rgx.re.re_nsub)) + 1;
    const matches_mem = flix_region_malloc(ctx, region_ptr0, @intCast(nmatch * @sizeOf(c.regmatch_t)));
    const matches_ptr: [*]c.regmatch_t = @ptrCast(@alignCast(matches_mem));
    m.matches = matches_ptr[0..nmatch];
    return m;
}

fn matcherExecAt(m: *MatcherObj, start_abs: usize) bool {
    if (start_abs < m.region_start or start_abs > m.region_end) return false;
    const local_offset: usize = start_abs - m.region_start;
    if (local_offset > (m.region_end - m.region_start)) return false;

    const rc = c.regexec(&m.rgx.re, m.region.ptr + local_offset, m.matches.len, m.matches.ptr, 0);
    if (rc != 0) return false;

    const base: isize = @intCast(start_abs);
    for (m.matches) |*mm| {
        const so: isize = @intCast(mm.rm_so);
        const eo: isize = @intCast(mm.rm_eo);
        if (so < 0 or eo < 0) continue;
        mm.rm_so = @intCast(base + so);
        mm.rm_eo = @intCast(base + eo);
    }

    m.last_start = @intCast(m.matches[0].rm_so);
    m.last_end = @intCast(m.matches[0].rm_eo);
    return true;
}

export fn flix_regex_matcher_matches(m_ptr: *anyopaque) bool {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    const ok = matcherExecAt(m, m.region_start);
    if (!ok) return false;
    const so: isize = @intCast(m.matches[0].rm_so);
    const eo: isize = @intCast(m.matches[0].rm_eo);
    return so == @as(isize, @intCast(m.region_start)) and eo == @as(isize, @intCast(m.region_end));
}

export fn flix_regex_matcher_find(m_ptr: *anyopaque) bool {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    const start_abs: usize = if (m.next_start < m.region_start) m.region_start else m.next_start;
    if (start_abs > m.region_end) return false;

    const ok = matcherExecAt(m, start_abs);
    if (!ok) return false;

    const start: usize = @intCast(m.matches[0].rm_so);
    const end: usize = @intCast(m.matches[0].rm_eo);

    if (end > start) {
        m.next_start = end;
    } else {
        m.next_start = start + 1;
    }

    return true;
}

export fn flix_regex_matcher_find_from(m_ptr: *anyopaque, pos: i32) bool {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    const p_abs: usize = if (pos <= 0) 0 else @intCast(pos);
    const start_abs: usize = if (p_abs < m.region_start) m.region_start else p_abs;
    if (start_abs > m.region_end) return false;

    m.next_start = start_abs;
    return flix_regex_matcher_find(m_ptr);
}

export fn flix_regex_matcher_looking_at(m_ptr: *anyopaque) bool {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    const ok = matcherExecAt(m, m.region_start);
    if (!ok) return false;
    const so: isize = @intCast(m.matches[0].rm_so);
    return so == @as(isize, @intCast(m.region_start));
}

export fn flix_regex_matcher_replace_all(m_ptr: *anyopaque, replacement_ptr: *anyopaque) *anyopaque {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    const repl_z = flixStringToAsciiZ(replacement_ptr);
    defer c.free(@ptrCast(repl_z.ptr));
    const repl = repl_z[0..repl_z.len];

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt_alloc);

    var offset: usize = 0;
    var match: [1]c.regmatch_t = undefined;

    while (offset <= m.input_len) {
        const rc = c.regexec(&m.rgx.re, m.input.ptr + offset, 1, &match, 0);
        if (rc != 0) break;

        const so: usize = @intCast(match[0].rm_so);
        const eo: usize = @intCast(match[0].rm_eo);
        const start = offset + so;
        const end = offset + eo;

        out.appendSlice(rt_alloc, m.input[offset..start]) catch @panic("oom");
        out.appendSlice(rt_alloc, repl) catch @panic("oom");

        offset = end;
        if (eo == so) offset += 1; // avoid infinite loop on empty matches.
    }

    if (offset <= m.input_len) {
        out.appendSlice(rt_alloc, m.input[offset..m.input_len]) catch @panic("oom");
    }

    return allocFlixStringFromAscii(out.items);
}

export fn flix_regex_matcher_replace_first(m_ptr: *anyopaque, replacement_ptr: *anyopaque) *anyopaque {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    const repl_z = flixStringToAsciiZ(replacement_ptr);
    defer c.free(@ptrCast(repl_z.ptr));
    const repl = repl_z[0..repl_z.len];

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt_alloc);

    var match: [1]c.regmatch_t = undefined;
    const rc = c.regexec(&m.rgx.re, m.input.ptr, 1, &match, 0);
    if (rc != 0) {
        return allocFlixStringFromAscii(m.input[0..m.input_len]);
    }

    const so: usize = @intCast(match[0].rm_so);
    const eo: usize = @intCast(match[0].rm_eo);

    out.appendSlice(rt_alloc, m.input[0..so]) catch @panic("oom");
    out.appendSlice(rt_alloc, repl) catch @panic("oom");
    out.appendSlice(rt_alloc, m.input[eo..m.input_len]) catch @panic("oom");

    return allocFlixStringFromAscii(out.items);
}

export fn flix_regex_matcher_set_bounds(ctx: *anyopaque, region_ptr0: ?*anyopaque, m_ptr: *anyopaque, start: i32, end: i32) i64 {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    const s: usize = @intCast(start);
    const e: usize = @intCast(end);
    if (s > e or e > m.input_len) @panic("invalid bounds");

    m.region_start = s;
    m.region_end = e;
    m.next_start = s;
    m.last_start = -1;
    m.last_end = -1;

    const len: usize = e - s;
    const mem = flix_region_malloc(ctx, region_ptr0, @intCast(len + 1));
    const bytes: [*]u8 = @ptrCast(@alignCast(mem));
    std.mem.copyForwards(u8, bytes[0..len], m.input[s..e]);
    bytes[len] = 0;
    m.region = bytes[0..len :0];
    return 0;
}

export fn flix_regex_matcher_start(m_ptr: *anyopaque) i32 {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    return @intCast(m.last_start);
}

export fn flix_regex_matcher_end(m_ptr: *anyopaque) i32 {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    return @intCast(m.last_end);
}

export fn flix_regex_matcher_group_count(m_ptr: *anyopaque) i32 {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    return @intCast(m.rgx.re.re_nsub);
}

export fn flix_regex_matcher_group(m_ptr: *anyopaque, idx: i32) ?*anyopaque {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    if (idx < 0) return null;
    const i: usize = @intCast(idx);
    if (i >= m.matches.len) return null;

    const so: isize = @intCast(m.matches[i].rm_so);
    const eo: isize = @intCast(m.matches[i].rm_eo);
    if (so < 0 or eo < 0 or eo < so) return null;

    const start: usize = @intCast(so);
    const end: usize = @intCast(eo);
    if (end > m.input_len) return null;
    return allocFlixStringFromAscii(m.input[start..end]);
}

export fn flix_regex_split(ctx: *anyopaque, region_ptr0: ?*anyopaque, rgx_ptr: *anyopaque, input_ptr: *anyopaque) *anyopaque {
    const rgx: *RegexObj = @ptrCast(@alignCast(rgx_ptr));
    const input_z = flixStringToAsciiZ(input_ptr);
    defer c.free(@ptrCast(input_z.ptr));
    const input = input_z[0..input_z.len];

    var parts: std.ArrayList(*anyopaque) = .empty;
    defer parts.deinit(rt_alloc);

    var offset: usize = 0;
    var match: [1]c.regmatch_t = undefined;

    while (offset <= input.len) {
        const rc = c.regexec(&rgx.re, input_z.ptr + offset, 1, &match, 0);
        if (rc != 0) break;

        const so: usize = @intCast(match[0].rm_so);
        const eo: usize = @intCast(match[0].rm_eo);
        const start = offset + so;
        const end = offset + eo;

        const part = allocFlixStringFromAscii(input[offset..start]);
        parts.append(rt_alloc, part) catch @panic("oom");

        offset = end;
        if (eo == so) offset += 1; // avoid infinite loop on empty matches.
    }

    const tail = allocFlixStringFromAscii(input[offset..input.len]);
    parts.append(rt_alloc, tail) catch @panic("oom");

    return allocFlixArrayFromPtrPayloadsInRegion(ctx, region_ptr0, parts.items);
}

// ============================================================================
// Channels (bring-up)
// ============================================================================

const ChannelWaiter = struct {
    task_id: u64,
    susp_handle: i64,
};

const ChannelObj = struct {
    capacity: usize,
    mutex: RtMutex = .{},
    not_empty: RtCondition = .{},
    not_full: RtCondition = .{},

    // Cooperative (wasm) wait queues.
    //
    // These store blocked task ids + their suspension handles (the put payload is stored
    // inside the suspension object args).
    wait_getters: std.ArrayListUnmanaged(ChannelWaiter) = .{},
    wait_getters_head: usize = 0,
    wait_putters: std.ArrayListUnmanaged(ChannelWaiter) = .{},
    wait_putters_head: usize = 0,

    // Buffered channel state (capacity > 0).
    buf: ?[]i64 = null,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    // Unbuffered (rendezvous) channel state (capacity == 0).
    rv_has_msg: bool = false,
    rv_payload: i64 = 0,
};

// Internal (wasm-only) suspension tags for cooperative channel ops.
const WasmChanEffSymId: i64 = -2;
const WasmChanOpGet: i64 = 1;
const WasmChanOpPut: i64 = 2;

// Registered live channels (GC root source for queued payloads).
var g_channel_registry_initialized: bool = false;
var g_channel_registry_mutex: RtMutex = .{};
var g_channel_registry: std.AutoHashMap(usize, u8) = undefined;

fn ensureChannelRegistryInitialized() void {
    if (g_channel_registry_initialized) return;
    g_channel_registry_mutex.lock();
    defer g_channel_registry_mutex.unlock();
    if (g_channel_registry_initialized) return;
    g_channel_registry = std.AutoHashMap(usize, u8).init(rt_alloc);
    g_channel_registry_initialized = true;
}

fn registerChannel(chan: *ChannelObj) void {
    ensureChannelRegistryInitialized();
    g_channel_registry_mutex.lock();
    defer g_channel_registry_mutex.unlock();
    g_channel_registry.put(@intFromPtr(chan), 0) catch @panic("oom");
}

fn deregisterChannel(chan: *ChannelObj) void {
    if (!g_channel_registry_initialized) return;
    g_channel_registry_mutex.lock();
    defer g_channel_registry_mutex.unlock();
    _ = g_channel_registry.remove(@intFromPtr(chan));
}

fn channelQueueAppend(list: *std.ArrayListUnmanaged(ChannelWaiter), w: ChannelWaiter) void {
    list.append(rt_alloc, w) catch @panic("oom");
}

fn channelQueuePop(list: *std.ArrayListUnmanaged(ChannelWaiter), head: *usize) ?ChannelWaiter {
    if (head.* >= list.items.len) return null;
    const w = list.items[head.*];
    head.* += 1;

    // Compact occasionally to avoid unbounded growth from head advancement.
    if (head.* > 64 and head.* * 2 >= list.items.len) {
        const rem = list.items.len - head.*;
        if (rem > 0) {
            std.mem.copyForwards(ChannelWaiter, list.items[0..rem], list.items[head.* .. list.items.len]);
        }
        list.items.len = rem;
        head.* = 0;
    }

    return w;
}

fn channelInit(capacity: usize) *ChannelObj {
    const obj = rt_alloc.create(ChannelObj) catch @panic("oom");
    obj.* = .{ .capacity = capacity };
    if (capacity > 0) {
        obj.buf = rt_alloc.alloc(i64, capacity) catch @panic("oom");
    }
    registerChannel(obj);
    return obj;
}

export fn flix_channel_new(capacity: i32) *anyopaque {
    const cap: usize = if (capacity <= 0) 0 else @intCast(capacity);
    return channelInit(cap);
}

export fn flix_channel_put(chan_ptr: *anyopaque, payload: i64) i64 {
    const chan: *ChannelObj = @ptrCast(@alignCast(chan_ptr));
    const ctx_opt = current_ctx;

    // If we block (buffer full / unbuffered rendezvous), the payload may be the only reference
    // to a GC object. Since the collector does not scan the Zig stack, root the payload explicitly.
    var payload_root: i64 = payload;
    if (ctx_opt) |ctx| {
        flix_gc_push_root_value_i64(@ptrCast(ctx), @ptrCast(&payload_root));
        defer flix_gc_pop_roots(@ptrCast(ctx), 1);
    }

    chan.mutex.lock();
    defer chan.mutex.unlock();

    if (chan.capacity == 0) {
        while (chan.rv_has_msg) {
            if (ctx_opt) |ctx| ctx.blocked.store(true, .release);
            chan.not_full.wait(&chan.mutex);
            chan.mutex.unlock();
            if (ctx_opt) |ctx| pollcheckCooperate(ctx);
            chan.mutex.lock();
            if (ctx_opt) |ctx| ctx.blocked.store(false, .release);
        }
        chan.rv_payload = payload_root;
        chan.rv_has_msg = true;
        chan.not_empty.signal();

        while (chan.rv_has_msg) {
            if (ctx_opt) |ctx| ctx.blocked.store(true, .release);
            chan.not_full.wait(&chan.mutex);
            chan.mutex.unlock();
            if (ctx_opt) |ctx| pollcheckCooperate(ctx);
            chan.mutex.lock();
            if (ctx_opt) |ctx| ctx.blocked.store(false, .release);
        }
        return 0;
    }

    const buf = chan.buf orelse @panic("missing buffer");
    while (chan.count == chan.capacity) {
        if (ctx_opt) |ctx| ctx.blocked.store(true, .release);
        chan.not_full.wait(&chan.mutex);
        chan.mutex.unlock();
        if (ctx_opt) |ctx| pollcheckCooperate(ctx);
        chan.mutex.lock();
        if (ctx_opt) |ctx| ctx.blocked.store(false, .release);
    }

    buf[chan.tail] = payload_root;
    chan.tail = (chan.tail + 1) % chan.capacity;
    chan.count += 1;
    chan.not_empty.signal();
    return 0;
}

export fn flix_channel_get(chan_ptr: *anyopaque) i64 {
    const chan: *ChannelObj = @ptrCast(@alignCast(chan_ptr));
    const ctx_opt = current_ctx;
    chan.mutex.lock();
    defer chan.mutex.unlock();

    if (chan.capacity == 0) {
        while (!chan.rv_has_msg) {
            if (ctx_opt) |ctx| ctx.blocked.store(true, .release);
            chan.not_empty.wait(&chan.mutex);
            chan.mutex.unlock();
            if (ctx_opt) |ctx| pollcheckCooperate(ctx);
            chan.mutex.lock();
            if (ctx_opt) |ctx| ctx.blocked.store(false, .release);
        }
        const payload = chan.rv_payload;
        chan.rv_has_msg = false;
        chan.not_full.signal();
        return payload;
    }

    const buf = chan.buf orelse @panic("missing buffer");
    while (chan.count == 0) {
        if (ctx_opt) |ctx| ctx.blocked.store(true, .release);
        chan.not_empty.wait(&chan.mutex);
        chan.mutex.unlock();
        if (ctx_opt) |ctx| pollcheckCooperate(ctx);
        chan.mutex.lock();
        if (ctx_opt) |ctx| ctx.blocked.store(false, .release);
    }

    const payload = buf[chan.head];
    chan.head = (chan.head + 1) % chan.capacity;
    chan.count -= 1;
    chan.not_full.signal();
    return payload;
}

fn allocWasmChannelSuspension(op_index: i64, args: []const i64) *anyopaque {
    const slots_total: usize = 5 + args.len;
    const size_bytes: usize = @sizeOf(FlixObj) + slots_total * @sizeOf(i64);
    const mem = gcAllocBytes(size_bytes, &flix_ti_suspension);
    const slots: [*]i64 = objPayloadSlots(mem);

    slots[0] = WasmChanEffSymId;
    slots[1] = op_index;
    slots[2] = 0; // prefix frames (filled in by codegen when returning the suspension)
    slots[3] = 0; // resumption = null (resume yields resumePayload directly)
    slots[4] = @intCast(args.len);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        slots[5 + i] = args[i];
    }
    return mem;
}

fn wasmChannelRegisterWaiter(ctx_rep: *exports_flix_runtime_runtime_ctx_t, task_id: u64, susp_handle: i64) void {
    const susp_ptr = flix_handle_get(ctx_rep.flix_ctx, susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    if (slots[0] != WasmChanEffSymId) return;

    const op_index: i64 = slots[1];
    const argc: i64 = slots[4];
    if (argc < 1) return;

    const chan_ptr = ptrFromPayload(slots[5]);
    const chan: *ChannelObj = @ptrCast(@alignCast(chan_ptr));

    switch (op_index) {
        WasmChanOpGet => channelQueueAppend(&chan.wait_getters, .{ .task_id = task_id, .susp_handle = susp_handle }),
        WasmChanOpPut => channelQueueAppend(&chan.wait_putters, .{ .task_id = task_id, .susp_handle = susp_handle }),
        else => {},
    }
}

fn wasmChannelPopValidWaiter(ctx_rep: *exports_flix_runtime_runtime_ctx_t, chan: *ChannelObj, want_putter: bool) ?ChannelWaiter {
    const list = if (want_putter) &chan.wait_putters else &chan.wait_getters;
    const head = if (want_putter) &chan.wait_putters_head else &chan.wait_getters_head;

    while (true) {
        const w = channelQueuePop(list, head) orelse return null;
        const task_ptr = ctx_rep.tasks.getPtr(w.task_id) orelse continue;
        switch (task_ptr.state) {
            .Blocked => |st| {
                if (st.susp_handle != w.susp_handle) continue;
                return w;
            },
            else => continue,
        }
    }
}

fn wasmResumeTaskOk(ctx_rep: *exports_flix_runtime_runtime_ctx_t, w: ChannelWaiter, resume_payload: i64) void {
    const task_ptr = ctx_rep.tasks.getPtr(w.task_id) orelse return;
    switch (task_ptr.state) {
        .Blocked => |st| {
            if (st.susp_handle != w.susp_handle) return;
        },
        else => return,
    }

    const resume_handle = flix_handle_new_i64(ctx_rep.flix_ctx, resume_payload);
    task_ptr.state = .{ .ReadyResumeOk = .{ .susp_handle = w.susp_handle, .resume_handle = resume_handle } };
    taskQueuePush(ctx_rep, w.task_id);
}

fn wasmChannelPutterPayload(ctx_rep: *exports_flix_runtime_runtime_ctx_t, w: ChannelWaiter, chan_bits: i64) i64 {
    const susp_ptr = flix_handle_get(ctx_rep.flix_ctx, w.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    // args: [chan_ptr_bits, payload]
    if (slots[0] != WasmChanEffSymId or slots[1] != WasmChanOpPut) return 0;
    if (slots[4] != 2) return 0;
    if (slots[5] != chan_bits) return 0;
    return slots[6];
}

fn wasmChannelTryPut(ctx_rep: *exports_flix_runtime_runtime_ctx_t, chan: *ChannelObj, chan_bits: i64, payload: i64) bool {
    _ = chan_bits;
    if (chan.capacity == 0) {
        if (wasmChannelPopValidWaiter(ctx_rep, chan, false)) |w| {
            wasmResumeTaskOk(ctx_rep, w, payload);
            return true;
        }
        return false;
    }

    // Buffered channel.
    if (chan.count < chan.capacity) {
        // Deliver directly to a blocked getter if the buffer is empty.
        if (chan.count == 0) {
            if (wasmChannelPopValidWaiter(ctx_rep, chan, false)) |w| {
                wasmResumeTaskOk(ctx_rep, w, payload);
                return true;
            }
        }

        const buf = chan.buf orelse @panic("missing buffer");
        buf[chan.tail] = payload;
        chan.tail = (chan.tail + 1) % chan.capacity;
        chan.count += 1;

        // Best-effort: if we somehow have a blocked getter, hand off the oldest buffered payload.
        if (wasmChannelPopValidWaiter(ctx_rep, chan, false)) |w| {
            const p = buf[chan.head];
            chan.head = (chan.head + 1) % chan.capacity;
            chan.count -= 1;
            wasmResumeTaskOk(ctx_rep, w, p);
        }

        return true;
    }

    return false;
}

fn wasmChannelTryGet(ctx_rep: *exports_flix_runtime_runtime_ctx_t, chan: *ChannelObj, chan_bits: i64) ?i64 {
    if (chan.capacity == 0) {
        if (wasmChannelPopValidWaiter(ctx_rep, chan, true)) |w| {
            const p = wasmChannelPutterPayload(ctx_rep, w, chan_bits);
            wasmResumeTaskOk(ctx_rep, w, 0);
            return p;
        }
        return null;
    }

    // Buffered channel.
    if (chan.count == 0) return null;

    const buf = chan.buf orelse @panic("missing buffer");
    const payload = buf[chan.head];
    chan.head = (chan.head + 1) % chan.capacity;
    chan.count -= 1;

    // If a putter is blocked on a full buffer, enqueue its payload now that we have space.
    if (chan.count < chan.capacity) {
        if (wasmChannelPopValidWaiter(ctx_rep, chan, true)) |w| {
            const p = wasmChannelPutterPayload(ctx_rep, w, chan_bits);
            buf[chan.tail] = p;
            chan.tail = (chan.tail + 1) % chan.capacity;
            chan.count += 1;
            wasmResumeTaskOk(ctx_rep, w, 0);
        }
    }

    return payload;
}

export fn flix_channel_put_resumable(ctx: *anyopaque, chan_ptr: *anyopaque, payload: i64) FlixResult {
    _ = ctx;
    const chan: *ChannelObj = @ptrCast(@alignCast(chan_ptr));
    if (!is_wasm) {
        _ = flix_channel_put(chan_ptr, payload);
        return FlixResult{ .tag = RESULT_TAG_VALUE, .payload = 0 };
    }

    const ctx_rep = current_wit_ctx orelse @panic("flix_channel_put_resumable: missing wasm WIT context");
    const chan_bits = payloadFromPtr(chan_ptr);
    if (wasmChannelTryPut(ctx_rep, chan, chan_bits, payload)) {
        return FlixResult{ .tag = RESULT_TAG_VALUE, .payload = 0 };
    }

    const susp_ptr = allocWasmChannelSuspension(WasmChanOpPut, &.{ chan_bits, payload });
    return FlixResult{ .tag = RESULT_TAG_SUSPENSION, .payload = payloadFromPtr(susp_ptr) };
}

export fn flix_channel_get_resumable(ctx: *anyopaque, chan_ptr: *anyopaque) FlixResult {
    _ = ctx;
    const chan: *ChannelObj = @ptrCast(@alignCast(chan_ptr));
    if (!is_wasm) {
        const payload = flix_channel_get(chan_ptr);
        return FlixResult{ .tag = RESULT_TAG_VALUE, .payload = payload };
    }

    const ctx_rep = current_wit_ctx orelse @panic("flix_channel_get_resumable: missing wasm WIT context");
    const chan_bits = payloadFromPtr(chan_ptr);
    if (wasmChannelTryGet(ctx_rep, chan, chan_bits)) |payload| {
        return FlixResult{ .tag = RESULT_TAG_VALUE, .payload = payload };
    }

    const susp_ptr = allocWasmChannelSuspension(WasmChanOpGet, &.{chan_bits});
    return FlixResult{ .tag = RESULT_TAG_SUSPENSION, .payload = payloadFromPtr(susp_ptr) };
}

// ============================================================================
// IO + Spawn (bring-up)
// ============================================================================

var g_next_id: RtAtomic(i64) = .init(0);
var g_argc: i32 = 0;
var g_argv: ?[*][*:0]u8 = null;
var g_stdin_buf: [65536]u8 = undefined;
var g_stdin_reader: std.fs.File.Reader = undefined;
var g_stdin_reader_ready: bool = false;

export fn flix_init(argc: i32, argv: *anyopaque) void {
    g_argc = argc;
    g_argv = @ptrCast(@alignCast(argv));
    if (!is_wasm) {
        // Keep a persistent buffered reader for stdin. Creating a fresh reader on each `readln`
        // risks dropping any bytes that were buffered past the delimiter.
        g_stdin_reader = std.fs.File.stdin().readerStreaming(g_stdin_buf[0..]);
        g_stdin_reader_ready = true;
    }
}

fn writeText(fd: enum { stdout, stderr }, s_ptr: *anyopaque, newline: bool) void {
    if (is_wasm) {
        // Browser/WASI: route to host logging via WIT (`flix:sys/sys@0.1.0#log`).
        const level: u8 = switch (fd) {
            .stdout => 2, // INFO
            .stderr => 4, // ERROR
        };

        const bytes = flixStringToUtf8Alloc(rt_alloc, s_ptr);
        defer rt_alloc.free(bytes);

        if (newline) {
            const out = rt_alloc.alloc(u8, bytes.len + 1) catch @panic("oom");
            defer rt_alloc.free(out);
            std.mem.copyForwards(u8, out[0..bytes.len], bytes);
            out[bytes.len] = '\n';
            var s: WitString = .{ .ptr = out.ptr, .len = out.len };
            flix_sys_sys_log(level, &s);
        } else {
            var s: WitString = .{ .ptr = bytes.ptr, .len = bytes.len };
            flix_sys_sys_log(level, &s);
        }
        return;
    } else {
        // Native: emit UTF-8 so console output matches JVM/wasm behavior.
        const slice = flixStringToUtf8Alloc(rt_alloc, s_ptr);
        defer rt_alloc.free(slice);

        const file = switch (fd) {
            .stdout => std.fs.File.stdout(),
            .stderr => std.fs.File.stderr(),
        };

        {
            var guard = BlockedGuard.enter(current_ctx);
            defer guard.exitAndCooperate();
            file.writeAll(slice) catch @panic("write failed");
        }
        if (newline) {
            var guard = BlockedGuard.enter(current_ctx);
            defer guard.exitAndCooperate();
            file.writeAll("\n") catch @panic("write failed");
        }
    }
}

export fn flix_print(s_ptr: *anyopaque) i64 {
    writeText(.stdout, s_ptr, false);
    return 0;
}

export fn flix_eprint(s_ptr: *anyopaque) i64 {
    writeText(.stderr, s_ptr, false);
    return 0;
}

export fn flix_println(s_ptr: *anyopaque) i64 {
    writeText(.stdout, s_ptr, true);
    return 0;
}

export fn flix_eprintln(s_ptr: *anyopaque) i64 {
    writeText(.stderr, s_ptr, true);
    return 0;
}

export fn flix_readln(_: i64) *anyopaque {
    if (is_wasm) {
        // Browser/wasm environments generally lack a stable stdin concept.
        // Treat `readln` as EOF (empty string) rather than trapping so portable programs
        // can degrade gracefully. A future host-backed suspension op can provide real input.
        return allocFlixStringFromAscii("");
    } else {
        if (!g_stdin_reader_ready) {
            g_stdin_reader = std.fs.File.stdin().readerStreaming(g_stdin_buf[0..]);
            g_stdin_reader_ready = true;
        }
        const line_opt = (blk: {
            var guard = BlockedGuard.enter(current_ctx);
            defer guard.exitAndCooperate();
            break :blk g_stdin_reader.interface.takeDelimiter('\n');
        }) catch @panic("readln failed");
        if (line_opt == null) return allocFlixStringFromAscii("");

        var bytes = line_opt.?;
        if (bytes.len != 0 and bytes[bytes.len - 1] == '\r') {
            bytes = bytes[0 .. bytes.len - 1];
        }
        return allocFlixStringFromAscii(bytes);
    }
}

export fn flix_sleep_millis(ms: i64) i64 {
    if (is_wasm) {
        return 0;
    } else {
        if (ms <= 0) return 0;
        const ms_u64: u64 = @intCast(ms);
        const ns: u64 = ms_u64 * std.time.ns_per_ms;
        {
            var guard = BlockedGuard.enter(current_ctx);
            defer guard.exitAndCooperate();
            std.Thread.sleep(ns);
        }
        return 0;
    }
}

export fn flix_exit(code: i32) void {
    c.exit(code);
}

export fn flix_new_id(_: i64) i64 {
    return g_next_id.fetchAdd(1, .monotonic);
}

export fn flix_time_now_ms(_: i64) i64 {
    if (is_wasm) {
        return flix_sys_sys_time_now_ms();
    } else {
        return std.time.milliTimestamp();
    }
}

// ============================================================================
// Portable IO primops (bring-up stubs + basic Env)
// ============================================================================

fn stubMsg(op: []const u8) *anyopaque {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}: unsupported on llvm-native", .{op}) catch op;
    return allocFlixStringFromAscii(s);
}

export fn flix_env_get_args(ctx: *anyopaque, region_ptr0: ?*anyopaque) *anyopaque {
    if (is_wasm) {
        var args: flix_list_string_t = .{ .ptr = undefined, .len = 0 };
        flix_sys_sys_get_args(&args);
        defer flix_list_string_free(&args);

        if (args.len == 0) {
            return allocFlixArrayFromPtrPayloadsInRegion(ctx, region_ptr0, &[_]*anyopaque{});
        }

        const n: usize = args.len;
        const size_bytes_i64: i64 = @intCast(@sizeOf(FlixArrayHeader) + n * @sizeOf(i64));

        const mem = flix_region_alloc_flex(ctx, region_ptr0, &flix_ti_array_ptr, size_bytes_i64);
        const header: *FlixArrayHeader = @ptrCast(@alignCast(mem));
        header.len = @intCast(n);
        header.elem_size = @intCast(@sizeOf(i64));

        const slots_ptr: [*]i64 = flixArraySlots(mem);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const arg = args.ptr[i];
            const bytes = arg.ptr[0..arg.len];
            const s_ptr = allocFlixStringFromUtf8Lossy(bytes);
            flix_store_ptr(ctx, @ptrCast(&slots_ptr[i]), payloadFromPtr(s_ptr));
        }

        flix_region_remember_ptr_array(ctx, region_ptr0, @ptrCast(&slots_ptr[0]), @intCast(n));
        return mem;
    }

    if (g_argc <= 1 or g_argv == null) {
        return allocFlixArrayFromPtrPayloadsInRegion(ctx, region_ptr0, &[_]*anyopaque{});
    }

    const n: usize = @intCast(g_argc - 1);
    const size_bytes_i64: i64 = @intCast(@sizeOf(FlixArrayHeader) + n * @sizeOf(i64));

    const mem = flix_region_alloc_flex(ctx, region_ptr0, &flix_ti_array_ptr, size_bytes_i64);
    const header: *FlixArrayHeader = @ptrCast(@alignCast(mem));
    header.len = @intCast(n);
    header.elem_size = @intCast(@sizeOf(i64));

    const slots_ptr: [*]i64 = flixArraySlots(mem);

    const argv = g_argv.?;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const arg_z = argv[i + 1];
        const arg = std.mem.span(arg_z);
        const s_ptr = allocFlixStringFromUtf8Lossy(arg);
        flix_store_ptr(ctx, @ptrCast(&slots_ptr[i]), payloadFromPtr(s_ptr));
    }

    flix_region_remember_ptr_array(ctx, region_ptr0, @ptrCast(&slots_ptr[0]), @intCast(n));
    return mem;
}

export fn flix_env_get_env_pairs(ctx: *anyopaque, region_ptr0: ?*anyopaque) *anyopaque {
    if (is_wasm) {
        // No environment variables in wasm32-freestanding (browser-first bring-up).
        return allocFlixArrayFromPtrPayloadsInRegion(ctx, region_ptr0, &[_]*anyopaque{});
    } else {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const alloc = gpa.allocator();

        var env = std.process.getEnvMap(alloc) catch {
            return allocFlixArrayFromPtrPayloadsInRegion(ctx, region_ptr0, &[_]*anyopaque{});
        };
        defer env.deinit();

        const pair_count: usize = env.count();
        const len: usize = pair_count * 2;
        const size_bytes_i64: i64 = @intCast(@sizeOf(FlixArrayHeader) + len * @sizeOf(i64));

        const mem = flix_region_alloc_flex(ctx, region_ptr0, &flix_ti_array_ptr, size_bytes_i64);
        const header: *FlixArrayHeader = @ptrCast(@alignCast(mem));
        header.len = @intCast(len);
        header.elem_size = @intCast(@sizeOf(i64));

        const slots_ptr: [*]i64 = flixArraySlots(mem);

        var idx: usize = 0;
        var it = env.iterator();
        while (it.next()) |entry| {
            const k_bytes = entry.key_ptr.*;
            const v_bytes = entry.value_ptr.*;
            const k_ptr = allocFlixStringFromUtf8Lossy(k_bytes);
            const v_ptr = allocFlixStringFromUtf8Lossy(v_bytes);
            flix_store_ptr(ctx, @ptrCast(&slots_ptr[idx]), payloadFromPtr(k_ptr));
            flix_store_ptr(ctx, @ptrCast(&slots_ptr[idx + 1]), payloadFromPtr(v_ptr));
            idx += 2;
        }

        flix_region_remember_ptr_array(ctx, region_ptr0, @ptrCast(&slots_ptr[0]), @intCast(len));
        return mem;
    }
}

export fn flix_env_get_var(name_ptr: *anyopaque) ?*anyopaque {
    const name_z = flixStringToAsciiZ(name_ptr);
    defer c.free(@ptrCast(name_z.ptr));

    const name_c: [*:0]const u8 = @ptrCast(name_z.ptr);
    const val_z_opt = c.getenv(name_c);
    if (val_z_opt == null) return null;

    const val = std.mem.span(val_z_opt.?);
    return allocFlixStringFromUtf8Lossy(val);
}

fn envGetenvStr(name_z: [*:0]const u8) ?[]const u8 {
    const v_opt = c.getenv(name_z);
    if (v_opt == null) return null;
    return std.mem.span(v_opt.?);
}

export fn flix_env_get_prop(name_ptr: *anyopaque) ?*anyopaque {
    const name_z = flixStringToAsciiZ(name_ptr);
    defer c.free(@ptrCast(name_z.ptr));
    const name = name_z[0..name_z.len];

    if (std.mem.eql(u8, name, "os.name")) {
        const os_name: []const u8 = switch (builtin.os.tag) {
            .windows => "Windows",
            .linux => "Linux",
            .macos => "Mac OS X",
            else => @tagName(builtin.os.tag),
        };
        return allocFlixStringFromAscii(os_name);
    }

    if (std.mem.eql(u8, name, "os.arch")) {
        return allocFlixStringFromAscii(@tagName(builtin.cpu.arch));
    }

    if (std.mem.eql(u8, name, "os.version")) {
        return null;
    }

    if (std.mem.eql(u8, name, "user.dir")) {
        if (is_wasm) {
            return null;
        } else {
            const cwd = std.fs.cwd().realpathAlloc(rt_alloc, ".") catch return null;
            defer rt_alloc.free(cwd);
            return allocFlixStringFromUtf8Lossy(cwd);
        }
    }

    if (std.mem.eql(u8, name, "java.io.tmpdir")) {
        const tmp = envGetenvStr("TMPDIR") orelse envGetenvStr("TMP") orelse envGetenvStr("TEMP") orelse envGetenvStr("TMP") orelse "/tmp";
        return allocFlixStringFromUtf8Lossy(tmp);
    }

    if (std.mem.eql(u8, name, "user.name")) {
        if (envGetenvStr("USER")) |u| return allocFlixStringFromUtf8Lossy(u);
        if (envGetenvStr("USERNAME")) |u| return allocFlixStringFromUtf8Lossy(u);
        return null;
    }

    if (std.mem.eql(u8, name, "user.home")) {
        if (envGetenvStr("HOME")) |h| return allocFlixStringFromUtf8Lossy(h);
        if (envGetenvStr("USERPROFILE")) |h| return allocFlixStringFromUtf8Lossy(h);
        return null;
    }

    return null;
}

export fn flix_env_virtual_processors(_: i64) i32 {
    if (is_wasm) {
        return 1;
    } else {
        const n = std.Thread.getCpuCount() catch 1;
        if (n == 0) return 1;
        if (n > std.math.maxInt(i32)) return std.math.maxInt(i32);
        return @intCast(n);
    }
}

const NativeFsTcp = if (is_wasm) struct {} else struct {
// ============================================================================
// File System (bring-up)
// ============================================================================

const IOERR_ALREADY_EXISTS: i64 = 0;
const IOERR_INVALID_PATH: i64 = 3;
const IOERR_NOT_DIRECTORY: i64 = 8;
const IOERR_UNSUPPORTED: i64 = 12;
const IOERR_OTHER: i64 = 14;

fn isInvalidPathError(err: anyerror) bool {
    return switch (err) {
        error.BadPathName,
        error.NameTooLong,
        error.InvalidUtf8,
        error.InvalidWtf8,
        => true,
        else => false,
    };
}

fn isUnsupportedError(err: anyerror) bool {
    return switch (err) {
        error.Unsupported,
        => true,
        else => false,
    };
}

fn fileOkBool(value: bool) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), payloadFromBool(value), IOERR_OTHER, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

fn fileOkInt64(value: i64) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), value, IOERR_OTHER, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

fn fileOkStr(str_ptr: *anyopaque) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), payloadFromPtr(str_ptr), IOERR_OTHER, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1010);
}

fn fileOkArray(arr_ptr: *anyopaque) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), payloadFromPtr(arr_ptr), IOERR_OTHER, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1010);
}

fn fileOkUnit() *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), 0, IOERR_OTHER, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

fn fileFailBool(kind: i64, msg: []const u8) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), payloadFromBool(false), kind, payloadFromPtr(allocFlixStringFromAscii(msg)) }, 0b1000);
}

fn fileFailInt64(kind: i64, msg: []const u8) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), @as(i64, 0), kind, payloadFromPtr(allocFlixStringFromAscii(msg)) }, 0b1000);
}

fn fileFailStr(kind: i64, msg: []const u8) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), payloadFromPtr(allocFlixStringFromAscii("")), kind, payloadFromPtr(allocFlixStringFromAscii(msg)) }, 0b1010);
}

fn fileFailArray(ctx: *anyopaque, region_ptr0: ?*anyopaque, kind: i64, msg: []const u8) *anyopaque {
    const empty_arr = allocFlixInt8ArrayFromBytesInRegion(ctx, region_ptr0, &.{});
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), payloadFromPtr(empty_arr), kind, payloadFromPtr(allocFlixStringFromAscii(msg)) }, 0b1010);
}

fn fileFailUnit(kind: i64, msg: []const u8) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, kind, payloadFromPtr(allocFlixStringFromAscii(msg)) }, 0b1000);
}

fn fileKindForErr(err: anyerror) i64 {
    if (isInvalidPathError(err)) return IOERR_INVALID_PATH;
    if (isUnsupportedError(err)) return IOERR_UNSUPPORTED;
    return IOERR_OTHER;
}

export fn flix_file_exists(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const stat_res = blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().statFile(path);
    };
    _ = stat_res catch |err| {
        if (isInvalidPathError(err)) return fileFailBool(IOERR_INVALID_PATH, @errorName(err));
        return fileOkBool(false);
    };
    return fileOkBool(true);
}

export fn flix_file_is_directory(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const st = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().statFile(path);
    }) catch |err| {
        if (isInvalidPathError(err)) return fileFailBool(IOERR_INVALID_PATH, @errorName(err));
        return fileOkBool(false);
    };
    return fileOkBool(st.kind == .directory);
}

export fn flix_file_is_regular_file(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const st = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().statFile(path);
    }) catch |err| {
        if (isInvalidPathError(err)) return fileFailBool(IOERR_INVALID_PATH, @errorName(err));
        return fileOkBool(false);
    };
    return fileOkBool(st.kind == .file);
}

export fn flix_file_is_readable(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    std.fs.cwd().access(path, .{ .mode = .read_only }) catch |err| {
        if (isInvalidPathError(err)) return fileFailBool(IOERR_INVALID_PATH, @errorName(err));
        return fileOkBool(false);
    };
    return fileOkBool(true);
}

export fn flix_file_is_symbolic_link(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.fs.cwd().readLink(path, buf[0..]) catch |err| {
        if (err == error.NotLink) return fileOkBool(false);
        if (isInvalidPathError(err)) return fileFailBool(IOERR_INVALID_PATH, @errorName(err));
        return fileOkBool(false);
    };
    return fileOkBool(true);
}

export fn flix_file_is_writable(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    std.fs.cwd().access(path, .{ .mode = .write_only }) catch |err| {
        if (isInvalidPathError(err)) return fileFailBool(IOERR_INVALID_PATH, @errorName(err));
        return fileOkBool(false);
    };
    return fileOkBool(true);
}

export fn flix_file_is_executable(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    std.posix.faccessat(std.fs.cwd().fd, path, std.posix.X_OK, 0) catch |err| {
        if (isInvalidPathError(err)) return fileFailBool(IOERR_INVALID_PATH, @errorName(err));
        return fileOkBool(false);
    };
    return fileOkBool(true);
}

export fn flix_file_access_time(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const st = std.fs.cwd().statFile(path) catch |err| return fileFailInt64(fileKindForErr(err), @errorName(err));
    const ms: i64 = @intCast(@divTrunc(st.atime, @as(i128, std.time.ns_per_ms)));
    return fileOkInt64(ms);
}

export fn flix_file_creation_time(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const st = std.fs.cwd().statFile(path) catch |err| return fileFailInt64(fileKindForErr(err), @errorName(err));

    // Note: Zig's portable stat surface does not expose "birth time". We use ctime
    // (metadata change time) as the best-effort approximation.
    const ms: i64 = @intCast(@divTrunc(st.ctime, @as(i128, std.time.ns_per_ms)));
    return fileOkInt64(ms);
}

export fn flix_file_modification_time(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const st = std.fs.cwd().statFile(path) catch |err| return fileFailInt64(fileKindForErr(err), @errorName(err));
    const ms: i64 = @intCast(@divTrunc(st.mtime, @as(i128, std.time.ns_per_ms)));
    return fileOkInt64(ms);
}

export fn flix_file_size(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const st = std.fs.cwd().statFile(path) catch |err| return fileFailInt64(fileKindForErr(err), @errorName(err));

    const max_i64_u64: u64 = @intCast(std.math.maxInt(i64));
    const size_i64: i64 = if (st.size > max_i64_u64) std.math.maxInt(i64) else @intCast(st.size);
    return fileOkInt64(size_i64);
}

export fn flix_file_read(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const bytes = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().readFileAlloc(alloc, path, std.math.maxInt(usize));
    }) catch |err| return fileFailStr(fileKindForErr(err), @errorName(err));
    defer alloc.free(bytes);

    const s_ptr = allocFlixStringFromUtf8Lossy(bytes);
    return fileOkStr(s_ptr);
}

export fn flix_file_read_lines(ctx: *anyopaque, region_ptr0: ?*anyopaque, path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const bytes = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().readFileAlloc(alloc, path, std.math.maxInt(usize));
    }) catch |err| return fileFailArray(ctx, region_ptr0, fileKindForErr(err), @errorName(err));
    defer alloc.free(bytes);

    var lines: std.ArrayList(*anyopaque) = .empty;
    defer lines.deinit(alloc);

    var i: usize = 0;
    var start: usize = 0;
    while (i < bytes.len) {
        const ch = bytes[i];
        if (ch == '\n' or ch == '\r') {
            const seg = bytes[start..i];
            const line_ptr = allocFlixStringFromUtf8Lossy(seg);
            lines.append(alloc, line_ptr) catch return fileFailArray(ctx, region_ptr0, IOERR_OTHER, "out of memory");

            if (ch == '\r' and (i + 1) < bytes.len and bytes[i + 1] == '\n') {
                i += 1;
            }

            i += 1;
            start = i;
            continue;
        }
        i += 1;
    }

    // Last line (if the file did not end with a newline).
    if (start < bytes.len) {
        const seg = bytes[start..bytes.len];
        const line_ptr = allocFlixStringFromUtf8Lossy(seg);
        lines.append(alloc, line_ptr) catch return fileFailArray(ctx, region_ptr0, IOERR_OTHER, "out of memory");
    }

    const arr_ptr = allocFlixArrayFromPtrPayloadsInRegion(ctx, region_ptr0, lines.items);
    return fileOkArray(arr_ptr);
}

export fn flix_file_read_bytes(ctx: *anyopaque, region_ptr0: ?*anyopaque, path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const bytes = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().readFileAlloc(alloc, path, std.math.maxInt(usize));
    }) catch |err| return fileFailArray(ctx, region_ptr0, fileKindForErr(err), @errorName(err));
    defer alloc.free(bytes);

    const arr_ptr = allocFlixInt8ArrayFromBytesInRegion(ctx, region_ptr0, bytes);
    return fileOkArray(arr_ptr);
}

export fn flix_file_list(ctx: *anyopaque, region_ptr0: ?*anyopaque, dir_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, dir_ptr);

    const st = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().statFile(path);
    }) catch |err| {
        if (isInvalidPathError(err)) return fileFailArray(ctx, region_ptr0, IOERR_INVALID_PATH, @errorName(err));
        return fileFailArray(ctx, region_ptr0, IOERR_NOT_DIRECTORY, "not a directory");
    };

    if (st.kind != .directory) {
        return fileFailArray(ctx, region_ptr0, IOERR_NOT_DIRECTORY, "not a directory");
    }

    var dir = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().openDir(path, .{ .iterate = true });
    }) catch |err| return fileFailArray(ctx, region_ptr0, fileKindForErr(err), @errorName(err));
    defer dir.close();

    var names: std.ArrayList(*anyopaque) = .empty;
    defer names.deinit(alloc);

    var it = dir.iterate();
    while (true) {
        const entry_opt = (blk: {
            var guard = BlockedGuard.enter(current_ctx);
            defer guard.exitAndCooperate();
            break :blk it.next();
        }) catch |err| return fileFailArray(ctx, region_ptr0, IOERR_OTHER, @errorName(err));
        if (entry_opt == null) break;
        const entry = entry_opt.?;
        const name_ptr = allocFlixStringFromUtf8Lossy(entry.name);
        names.append(alloc, name_ptr) catch return fileFailArray(ctx, region_ptr0, IOERR_OTHER, "out of memory");
    }

    const arr_ptr = allocFlixArrayFromPtrPayloadsInRegion(ctx, region_ptr0, names.items);
    return fileOkArray(arr_ptr);
}

export fn flix_file_write(data_ptr: *anyopaque, path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const data = flixStringToUtf8Alloc(alloc, data_ptr);

    var file = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().createFile(path, .{ .truncate = true });
    }) catch |err| return fileFailUnit(fileKindForErr(err), @errorName(err));
    defer file.close();

    const write_res = blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk file.writeAll(data);
    };
    _ = write_res catch |err| return fileFailUnit(fileKindForErr(err), @errorName(err));
    return fileOkUnit();
}

export fn flix_file_write_bytes(bytes_ptr: *anyopaque, path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const bytes = flixInt8ArrayToBytes(alloc, bytes_ptr);
    defer alloc.free(bytes);

    var file = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().createFile(path, .{ .truncate = true });
    }) catch |err| return fileFailUnit(fileKindForErr(err), @errorName(err));
    defer file.close();

    const write_res = blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk file.writeAll(bytes);
    };
    _ = write_res catch |err| return fileFailUnit(fileKindForErr(err), @errorName(err));
    return fileOkUnit();
}

export fn flix_file_append(data_ptr: *anyopaque, path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const data = flixStringToUtf8Alloc(alloc, data_ptr);

    var file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |err| {
        return fileFailUnit(fileKindForErr(err), @errorName(err));
    };
    defer file.close();

    file.seekFromEnd(0) catch |err| return fileFailUnit(fileKindForErr(err), @errorName(err));
    file.writeAll(data) catch |err| return fileFailUnit(fileKindForErr(err), @errorName(err));
    return fileOkUnit();
}

export fn flix_file_append_bytes(bytes_ptr: *anyopaque, path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const bytes = flixInt8ArrayToBytes(alloc, bytes_ptr);
    defer alloc.free(bytes);

    var file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |err| {
        return fileFailUnit(fileKindForErr(err), @errorName(err));
    };
    defer file.close();

    file.seekFromEnd(0) catch |err| return fileFailUnit(fileKindForErr(err), @errorName(err));
    file.writeAll(bytes) catch |err| return fileFailUnit(fileKindForErr(err), @errorName(err));
    return fileOkUnit();
}

export fn flix_file_truncate(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    var file = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().openFile(path, .{ .mode = .write_only });
    }) catch |err| return fileFailUnit(fileKindForErr(err), @errorName(err));
    defer file.close();

    const trunc_res = blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk file.setEndPos(0);
    };
    _ = trunc_res catch |err| return fileFailUnit(fileKindForErr(err), @errorName(err));
    return fileOkUnit();
}

export fn flix_file_mkdir(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const mk_res = blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().makeDir(path);
    };
    _ = mk_res catch |err| {
        if (err == error.PathAlreadyExists) return fileFailUnit(IOERR_ALREADY_EXISTS, @errorName(err));
        return fileFailUnit(fileKindForErr(err), @errorName(err));
    };
    return fileOkUnit();
}

export fn flix_file_mkdirs(path_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = flixStringToUtf8Alloc(alloc, path_ptr);
    const mkp_res = blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.fs.cwd().makePath(path);
    };
    _ = mkp_res catch |err| {
        if (err == error.NotDir) return fileFailUnit(IOERR_ALREADY_EXISTS, @errorName(err));
        return fileFailUnit(fileKindForErr(err), @errorName(err));
    };
    return fileOkUnit();
}

export fn flix_file_mk_temp_dir(prefix_ptr: *anyopaque) *anyopaque {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prefix = flixStringToUtf8Alloc(alloc, prefix_ptr);

    if (prefix.len < 3) {
        return fileFailStr(IOERR_INVALID_PATH, "prefix too short");
    }

    // Treat path separators and embedded NULs as invalid.
    if (std.mem.indexOfScalar(u8, prefix, 0) != null or
        std.mem.indexOfScalar(u8, prefix, '/') != null or
        std.mem.indexOfScalar(u8, prefix, '\\') != null)
    {
        return fileFailStr(IOERR_INVALID_PATH, "invalid prefix");
    }

    const tmp_base = envGetenvStr("TMPDIR") orelse envGetenvStr("TMP") orelse envGetenvStr("TEMP") orelse "/tmp";

    var attempt: usize = 0;
    while (attempt < 128) : (attempt += 1) {
        var r: [8]u8 = undefined;
        std.crypto.random.bytes(&r);
        const hex = std.fmt.bytesToHex(r, .lower);

        const name = alloc.alloc(u8, prefix.len + 1 + hex.len) catch return fileFailStr(IOERR_OTHER, "out of memory");
        @memcpy(name[0..prefix.len], prefix);
        name[prefix.len] = '-';
        @memcpy(name[prefix.len + 1 ..], hex[0..]);

        const full = std.fs.path.join(alloc, &.{ tmp_base, name }) catch return fileFailStr(IOERR_OTHER, "out of memory");

        const mk_res = blk: {
            var guard = BlockedGuard.enter(current_ctx);
            defer guard.exitAndCooperate();
            break :blk std.fs.cwd().makeDir(full);
        };
        _ = mk_res catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return fileFailStr(fileKindForErr(err), @errorName(err)),
        };

        const out_ptr = allocFlixStringFromUtf8Lossy(full);
        return fileOkStr(out_ptr);
    }

    return fileFailStr(IOERR_OTHER, "could not create temp directory");
}

const TcpSocketEntry = struct {
    stream: std.net.Stream,
};

const TcpServerEntry = struct {
    server: std.net.Server,
};

var g_tcp_initialized: bool = false;
var g_tcp_mutex: RtMutex = .{};
var g_tcp_sockets: std.AutoHashMap(i64, TcpSocketEntry) = undefined;
var g_tcp_servers: std.AutoHashMap(i64, TcpServerEntry) = undefined;

fn ensureTcpInitialized() void {
    if (g_tcp_initialized) return;
    g_tcp_mutex.lock();
    defer g_tcp_mutex.unlock();
    if (g_tcp_initialized) return;
    g_tcp_sockets = std.AutoHashMap(i64, TcpSocketEntry).init(std.heap.c_allocator);
    g_tcp_servers = std.AutoHashMap(i64, TcpServerEntry).init(std.heap.c_allocator);
    g_tcp_initialized = true;
}

fn tcpFail3(msg: []const u8) *anyopaque {
    const msg_ptr = allocFlixStringFromAscii(msg);
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, payloadFromPtr(msg_ptr) }, 0b100);
}

fn tcpFail4(kind: i64, msg: []const u8) *anyopaque {
    const msg_ptr = allocFlixStringFromAscii(msg);
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, kind, payloadFromPtr(msg_ptr) }, 0b1000);
}

export fn flix_tcp_socket_read(id: i64, buf_ptr: *anyopaque) *anyopaque {
    ensureTcpInitialized();

    var stream: std.net.Stream = undefined;
    {
        g_tcp_mutex.lock();
        defer g_tcp_mutex.unlock();
        const entry = g_tcp_sockets.get(id) orelse {
            return tcpFail3("invalid TCP socket handle.");
        };
        stream = entry.stream;
    }

    const cap: usize = flixArrayLen(buf_ptr);
    const tmp = std.heap.c_allocator.alloc(u8, cap) catch return tcpFail3("out of memory");
    defer std.heap.c_allocator.free(tmp);

    const n_usize = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk stream.read(tmp);
    }) catch |err| return tcpFail3(@errorName(err));

    flixWriteBytesToInt8Array(buf_ptr, tmp[0..n_usize]);

    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), @intCast(n_usize), payloadFromPtr(allocFlixStringFromAscii("")) }, 0b100);
}

export fn flix_tcp_socket_write(id: i64, buf_ptr: *anyopaque) *anyopaque {
    ensureTcpInitialized();

    var stream: std.net.Stream = undefined;
    {
        g_tcp_mutex.lock();
        defer g_tcp_mutex.unlock();
        const entry = g_tcp_sockets.get(id) orelse {
            return tcpFail3("invalid TCP socket handle.");
        };
        stream = entry.stream;
    }

    const bytes = flixInt8ArrayToBytes(std.heap.c_allocator, buf_ptr);
    defer std.heap.c_allocator.free(bytes);

    const write_res = blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk stream.writeAll(bytes);
    };
    _ = write_res catch |err| return tcpFail3(@errorName(err));

    if (bytes.len > std.math.maxInt(i32)) {
        return tcpFail3("write too large");
    }
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), @as(i64, @intCast(bytes.len)), payloadFromPtr(allocFlixStringFromAscii("")) }, 0b100);
}

export fn flix_tcp_socket_connect(ip_bytes_ptr: *anyopaque, port: i32) *anyopaque {
    ensureTcpInitialized();

    const port_u16 = parsePortOrInvalid(port) orelse {
        return tcpFail4(4, "invalid port");
    };

    const ip_bytes = flixInt8ArrayBytesView(ip_bytes_ptr);

    var addr: std.net.Address = undefined;
    if (ip_bytes.len == 4) {
        var ip: [4]u8 = undefined;
        std.mem.copyForwards(u8, ip[0..], ip_bytes[0..4]);
        addr = std.net.Address.initIp4(ip, port_u16);
    } else if (ip_bytes.len == 16) {
        var ip6: [16]u8 = undefined;
        std.mem.copyForwards(u8, ip6[0..], ip_bytes[0..16]);
        addr = std.net.Address.initIp6(ip6, port_u16, 0, 0);
    } else {
        return tcpFail4(4, "invalid IP byte array length");
    }

    const stream = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.net.tcpConnectToAddress(addr);
    }) catch |err| return tcpFail4(14, @errorName(err));

    const id: i64 = g_next_id.fetchAdd(1, .monotonic);
    {
        g_tcp_mutex.lock();
        defer g_tcp_mutex.unlock();
        g_tcp_sockets.put(id, .{ .stream = stream }) catch return tcpFail4(14, "out of memory");
    }

    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), id, 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

export fn flix_tcp_socket_close(id: i64) *anyopaque {
    ensureTcpInitialized();

    var removed: ?std.AutoHashMap(i64, TcpSocketEntry).KV = null;
    {
        g_tcp_mutex.lock();
        defer g_tcp_mutex.unlock();
        removed = g_tcp_sockets.fetchRemove(id);
    }

    if (removed) |kv| {
        kv.value.stream.close();
    }

    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), payloadFromPtr(allocFlixStringFromAscii("")) }, 0b10);
}

export fn flix_tcp_server_bind(ip_bytes_ptr: *anyopaque, port: i32) *anyopaque {
    ensureTcpInitialized();

    const port_u16 = parsePortOrInvalid(port) orelse {
        return tcpFail4(4, "invalid port");
    };

    const ip_bytes = flixInt8ArrayBytesView(ip_bytes_ptr);

    var addr: std.net.Address = undefined;
    if (ip_bytes.len == 4) {
        var ip: [4]u8 = undefined;
        std.mem.copyForwards(u8, ip[0..], ip_bytes[0..4]);
        addr = std.net.Address.initIp4(ip, port_u16);
    } else if (ip_bytes.len == 16) {
        var ip6: [16]u8 = undefined;
        std.mem.copyForwards(u8, ip6[0..], ip_bytes[0..16]);
        addr = std.net.Address.initIp6(ip6, port_u16, 0, 0);
    } else {
        return tcpFail4(4, "invalid IP byte array length");
    }

    const server = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk std.net.Address.listen(addr, .{ .kernel_backlog = 50 });
    }) catch |err| return tcpFail4(14, @errorName(err));

    const id: i64 = g_next_id.fetchAdd(1, .monotonic);
    {
        g_tcp_mutex.lock();
        defer g_tcp_mutex.unlock();
        g_tcp_servers.put(id, .{ .server = server }) catch return tcpFail4(14, "out of memory");
    }

    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), id, 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

export fn flix_tcp_server_local_port(id: i64) *anyopaque {
    ensureTcpInitialized();

    var server: std.net.Server = undefined;
    {
        g_tcp_mutex.lock();
        defer g_tcp_mutex.unlock();
        const entry = g_tcp_servers.get(id) orelse {
            return tcpFail3("invalid TCP server handle.");
        };
        server = entry.server;
    }

    const port_u16: u16 = server.listen_address.getPort();
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), @as(i64, @intCast(port_u16)), payloadFromPtr(allocFlixStringFromAscii("")) }, 0b100);
}

export fn flix_tcp_server_accept(id: i64) *anyopaque {
    ensureTcpInitialized();

    var server: std.net.Server = undefined;
    {
        g_tcp_mutex.lock();
        defer g_tcp_mutex.unlock();
        const entry = g_tcp_servers.get(id) orelse {
            return tcpFail4(14, "invalid TCP server handle.");
        };
        server = entry.server;
    }

    const conn = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk server.accept();
    }) catch |err| {
        const kind: i64 = switch (err) {
            error.WouldBlock => 10,
            else => 14,
        };
        return tcpFail4(kind, @errorName(err));
    };

    const sock_id: i64 = g_next_id.fetchAdd(1, .monotonic);
    {
        g_tcp_mutex.lock();
        defer g_tcp_mutex.unlock();
        g_tcp_sockets.put(sock_id, .{ .stream = conn.stream }) catch return tcpFail4(14, "out of memory");
    }

    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), sock_id, 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

export fn flix_tcp_server_close(id: i64) *anyopaque {
    ensureTcpInitialized();

    var removed: ?std.AutoHashMap(i64, TcpServerEntry).KV = null;
    {
        g_tcp_mutex.lock();
        defer g_tcp_mutex.unlock();
        removed = g_tcp_servers.fetchRemove(id);
    }

    if (removed) |kv| {
        var s = kv.value.server;
        s.deinit();
    }

    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), payloadFromPtr(allocFlixStringFromAscii("")) }, 0b10);
}

}; // NativeFsTcp

fn flixStringToUtf16LeAlloc(allocator: std.mem.Allocator, ptr: *anyopaque) []u16 {
    const len: usize = flixStringLen(ptr);
    const units: [*]const u16 = flixStringCodeUnits(ptr);
    const out = allocator.alloc(u16, len) catch @panic("oom");
    var i: usize = 0;
    while (i < len) : (i += 1) {
        out[i] = std.mem.nativeToLittle(u16, units[i]);
    }
    return out;
}

fn flixStringToUtf8Alloc(allocator: std.mem.Allocator, ptr: *anyopaque) []u8 {
    const len: usize = flixStringLen(ptr);
    const units: [*]const u16 = flixStringCodeUnits(ptr);

    // Note: Flix (like the JVM) can contain unpaired surrogates. For portable I/O we
    // use a lossy conversion and replace malformed surrogate sequences with U+FFFD.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    out.ensureUnusedCapacity(allocator, len) catch @panic("oom");

    var i: usize = 0;
    while (i < len) {
        const cu0: u16 = units[i];
        var cp: u21 = undefined;

        if (std.unicode.utf16IsHighSurrogate(cu0)) {
            if (i + 1 < len and std.unicode.utf16IsLowSurrogate(units[i + 1])) {
                var pair: [2]u16 = .{ cu0, units[i + 1] };
                cp = std.unicode.utf16DecodeSurrogatePair(&pair) catch @panic("invalid surrogate pair");
                i += 2;
            } else {
                cp = std.unicode.replacement_character;
                i += 1;
            }
        } else if (std.unicode.utf16IsLowSurrogate(cu0)) {
            cp = std.unicode.replacement_character;
            i += 1;
        } else {
            cp = @intCast(cu0);
            i += 1;
        }

        var buf: [4]u8 = undefined;
        const n_u3 = std.unicode.utf8Encode(cp, buf[0..]) catch unreachable;
        const n: usize = @intCast(n_u3);
        out.appendSlice(allocator, buf[0..n]) catch @panic("oom");
    }

    return out.toOwnedSlice(allocator) catch @panic("oom");
}

const NativeProcHttp = if (is_wasm) struct {} else struct {
const ProcessObj = struct {
    ref_count: RtAtomic(u32) = .init(1),
    mutex: RtMutex = .{},
    cv: RtCondition = .{},

    // Stable process id (pid on POSIX, process id on Windows).
    os_pid: i64,

    // Backing allocations for argv/env/cwd etc.
    arena: std.heap.ArenaAllocator,
    env_map: std.process.EnvMap,
    child: std.process.Child,

    done: bool = false,
    term: ?std.process.Child.Term = null,
    wait_err: ?[]const u8 = null,
};

var g_proc_initialized: bool = false;
var g_proc_mutex: RtMutex = .{};
var g_procs: std.AutoHashMap(i64, *ProcessObj) = undefined;

fn ensureProcInitialized() void {
    if (g_proc_initialized) return;
    g_proc_mutex.lock();
    defer g_proc_mutex.unlock();
    if (g_proc_initialized) return;
    g_procs = std.AutoHashMap(i64, *ProcessObj).init(std.heap.c_allocator);
    g_proc_initialized = true;
}

fn procRetain(proc: *ProcessObj) void {
    _ = proc.ref_count.fetchAdd(1, .acq_rel);
}

fn procRelease(proc: *ProcessObj) void {
    const prev = proc.ref_count.fetchSub(1, .acq_rel);
    if (prev != 1) return;

    // Last reference.
    if (proc.child.stdin) |*stdin_file| {
        stdin_file.close();
        proc.child.stdin = null;
    }
    if (proc.child.stdout) |*stdout_file| {
        stdout_file.close();
        proc.child.stdout = null;
    }
    if (proc.child.stderr) |*stderr_file| {
        stderr_file.close();
        proc.child.stderr = null;
    }

    if (builtin.os.tag == .windows) {
        std.posix.close(proc.child.id);
        std.posix.close(proc.child.thread_handle);
    }

    proc.env_map.deinit();
    proc.arena.deinit();
    std.heap.c_allocator.destroy(proc);
}

fn procLookup(id: i64) ?*ProcessObj {
    ensureProcInitialized();
    g_proc_mutex.lock();
    defer g_proc_mutex.unlock();
    const proc = g_procs.get(id) orelse return null;
    procRetain(proc);
    return proc;
}

fn procFail3(msg: []const u8) *anyopaque {
    const msg_ptr = allocFlixStringFromAscii(msg);
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, payloadFromPtr(msg_ptr) }, 0b100);
}

fn procFail4(kind: i64, msg: []const u8) *anyopaque {
    const msg_ptr = allocFlixStringFromAscii(msg);
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, kind, payloadFromPtr(msg_ptr) }, 0b1000);
}

fn procFail4Bool(kind: i64, msg: []const u8) *anyopaque {
    const msg_ptr = allocFlixStringFromAscii(msg);
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), payloadFromBool(false), kind, payloadFromPtr(msg_ptr) }, 0b1000);
}

fn exitCodeFromTerm(term: std.process.Child.Term) i32 {
    return switch (term) {
        .Exited => |code| @intCast(code),
        .Signal => |sig| blk: {
            const x: u64 = 128 + @as(u64, sig);
            break :blk if (x > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(x);
        },
        .Stopped => |sig| blk: {
            const x: u64 = 128 + @as(u64, sig);
            break :blk if (x > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(x);
        },
        .Unknown => |x| @intCast(@min(@as(u32, @intCast(x)), std.math.maxInt(i32))),
    };
}

fn termFromWaitStatus(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        std.process.Child.Term{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        std.process.Child.Term{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        std.process.Child.Term{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        std.process.Child.Term{ .Unknown = status };
}

fn processWaitThread(proc: *ProcessObj) void {
    var term: ?std.process.Child.Term = null;
    var wait_err: ?[]const u8 = null;

    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const wait_res = windows.WaitForSingleObjectEx(proc.child.id, windows.INFINITE, false);
        wait_res catch |err| {
            wait_err = @errorName(err);
        };

        if (wait_err == null) {
            var exit_code: windows.DWORD = undefined;
            if (windows.kernel32.GetExitCodeProcess(proc.child.id, &exit_code) == 0) {
                term = .{ .Unknown = 0 };
            } else {
                term = .{ .Exited = @as(u8, @truncate(exit_code)) };
            }
        }
    } else {
        // POSIX: reap the child to avoid zombies, but do not close stdio pipes.
        const res = std.posix.waitpid(proc.child.id, 0);
        term = termFromWaitStatus(res.status);
    }

    proc.mutex.lock();
    proc.done = true;
    proc.term = term;
    proc.wait_err = wait_err;
    proc.mutex.unlock();

    proc.cv.broadcast();
    procRelease(proc);
}

export fn flix_process_exec(argv_ptr: *anyopaque, has_cwd: bool, cwd_ptr: *anyopaque, env_pairs_ptr: *anyopaque) *anyopaque {
    ensureProcInitialized();

    const argv_len: usize = flixArrayLen(argv_ptr);
    if (argv_len == 0) return procFail4(4, "invalid argv");

    const env_len: usize = flixArrayLen(env_pairs_ptr);
    if ((env_len & 1) != 0) return procFail4(4, "invalid env pairs");

    const proc = std.heap.c_allocator.create(ProcessObj) catch return procFail4(14, "out of memory");
    var destroy_proc: bool = true;
    defer if (destroy_proc) std.heap.c_allocator.destroy(proc);

    proc.* = undefined;
    proc.ref_count = .init(1);
    proc.mutex = .{};
    proc.cv = .{};
    proc.done = false;
    proc.term = null;
    proc.wait_err = null;

    proc.arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    var arena_inited: bool = true;
    defer if (arena_inited) proc.arena.deinit();
    const alloc = proc.arena.allocator();

    proc.env_map = std.process.getEnvMap(alloc) catch return procFail4(14, "failed to read environment");
    var env_inited: bool = true;
    defer if (env_inited) proc.env_map.deinit();

    // Overlay env pairs.
    const env_slots = flixArraySlots(env_pairs_ptr);
    var i: usize = 0;
    while (i < env_len) : (i += 2) {
        const k_ptr = ptrFromPayload(env_slots[i]);
        const v_ptr = ptrFromPayload(env_slots[i + 1]);
        const k = flixStringToUtf8Alloc(alloc, k_ptr);
        const v = flixStringToUtf8Alloc(alloc, v_ptr);
        proc.env_map.put(k, v) catch return procFail4(14, "out of memory");
    }

    // Build argv.
    const argv_slots = flixArraySlots(argv_ptr);
    const argv = alloc.alloc([]const u8, argv_len) catch return procFail4(14, "out of memory");
    var j: usize = 0;
    while (j < argv_len) : (j += 1) {
        const s_ptr = ptrFromPayload(argv_slots[j]);
        argv[j] = flixStringToUtf8Alloc(alloc, s_ptr);
    }

    proc.child = std.process.Child.init(argv, alloc);
    proc.child.stdin_behavior = .Pipe;
    proc.child.stdout_behavior = .Pipe;
    proc.child.stderr_behavior = .Pipe;
    proc.child.env_map = &proc.env_map;

    if (has_cwd) {
        const cwd_bytes = flixStringToUtf8Alloc(alloc, cwd_ptr);
        if (cwd_bytes.len == 0) {
            return procFail4(4, "invalid cwd");
        }
        proc.child.cwd = cwd_bytes;
    } else {
        proc.child.cwd = null;
    }

    const spawn_res = blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk proc.child.spawn();
    };
    _ = spawn_res catch |err| return procFail4(14, @errorName(err));

    const wait_for_spawn_res = blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk proc.child.waitForSpawn();
    };
    _ = wait_for_spawn_res catch |err| {
        {
            var guard = BlockedGuard.enter(current_ctx);
            defer guard.exitAndCooperate();
            _ = proc.child.kill() catch {};
        }
        {
            var guard = BlockedGuard.enter(current_ctx);
            defer guard.exitAndCooperate();
            _ = proc.child.wait() catch {};
        }
        return procFail4(14, @errorName(err));
    };

    // Compute stable pid/process id.
    proc.os_pid = switch (builtin.os.tag) {
        .windows => blk: {
            const windows = std.os.windows;
            const pid_u32 = windows.kernel32.GetProcessId(proc.child.id);
            break :blk @as(i64, @intCast(pid_u32));
        },
        else => @as(i64, @intCast(proc.child.id)),
    };

    const id: i64 = g_next_id.fetchAdd(1, .monotonic);

    // Insert into handle table.
    {
        g_proc_mutex.lock();
        defer g_proc_mutex.unlock();
        g_procs.put(id, proc) catch {
            _ = proc.child.kill() catch {};
            _ = proc.child.wait() catch {};
            return procFail4(14, "out of memory");
        };
    }

    // Ownership transferred to the handle table + reaper thread.
    destroy_proc = false;
    arena_inited = false;
    env_inited = false;

    // Spawn a reaper thread to avoid zombies (and to support non-blocking queries).
    procRetain(proc); // thread ref
    const t = std.Thread.spawn(.{}, processWaitThread, .{proc}) catch {
        // Undo table insertion and terminate process.
        g_proc_mutex.lock();
        _ = g_procs.fetchRemove(id);
        g_proc_mutex.unlock();

        _ = proc.child.kill() catch {};
        if (builtin.os.tag == .windows) {
            std.os.windows.WaitForSingleObjectEx(proc.child.id, std.os.windows.INFINITE, false) catch {};
        } else {
            _ = std.posix.waitpid(proc.child.id, 0);
        }
        procRelease(proc); // drop thread ref
        procRelease(proc); // drop table ref
        return procFail4(14, "failed to spawn reaper thread");
    };
    t.detach();

    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), id, 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

export fn flix_process_exit_value(id: i64) *anyopaque {
    const proc = procLookup(id) orelse return procFail4(14, "invalid process handle.");
    defer procRelease(proc);

    proc.mutex.lock();
    defer proc.mutex.unlock();

    if (!proc.done) {
        return procFail4(14, "process still running");
    }
    if (proc.wait_err) |msg| {
        return procFail4(14, msg);
    }
    const term = proc.term orelse return procFail4(14, "process wait failed");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), @as(i64, exitCodeFromTerm(term)), 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

export fn flix_process_is_alive(id: i64) *anyopaque {
    const proc = procLookup(id) orelse return procFail4Bool(14, "invalid process handle.");
    defer procRelease(proc);

    proc.mutex.lock();
    defer proc.mutex.unlock();

    const alive = !proc.done;
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), payloadFromBool(alive), 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

export fn flix_process_pid(id: i64) *anyopaque {
    const proc = procLookup(id) orelse return procFail4(14, "invalid process handle.");
    defer procRelease(proc);

    proc.mutex.lock();
    const pid = proc.os_pid;
    proc.mutex.unlock();

    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), pid, 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

export fn flix_process_stop(id: i64) *anyopaque {
    const proc = procLookup(id) orelse return procFail4(14, "invalid process handle.");
    defer procRelease(proc);

    proc.mutex.lock();
    const already_done = proc.done;
    proc.mutex.unlock();
    if (already_done) {
        return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), 0, 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
    }

    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        _ = windows.TerminateProcess(proc.child.id, 1) catch {};
    } else {
        std.posix.kill(@intCast(proc.os_pid), std.posix.SIG.TERM) catch {};
    }

    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), 0, 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

export fn flix_process_wait_for(id: i64) *anyopaque {
    const proc = procLookup(id) orelse return procFail4(14, "invalid process handle.");
    defer procRelease(proc);

    const ctx_opt = current_ctx;
    proc.mutex.lock();
    while (!proc.done) {
        if (ctx_opt) |ctx| ctx.blocked.store(true, .release);
        proc.cv.wait(&proc.mutex);
        // Cooperate with any in-flight STW without holding `proc.mutex`.
        proc.mutex.unlock();
        if (ctx_opt) |ctx| pollcheckCooperate(ctx);
        proc.mutex.lock();
        if (ctx_opt) |ctx| ctx.blocked.store(false, .release);
    }

    if (proc.wait_err) |msg| {
        proc.mutex.unlock();
        return procFail4(14, msg);
    }

    const term = proc.term orelse {
        proc.mutex.unlock();
        return procFail4(14, "process wait failed");
    };
    const code: i32 = exitCodeFromTerm(term);
    proc.mutex.unlock();

    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), @as(i64, code), 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

export fn flix_process_wait_for_timeout(id: i64, timeout_ms: i64) *anyopaque {
    const proc = procLookup(id) orelse return procFail4Bool(14, "invalid process handle.");
    defer procRelease(proc);

    if (timeout_ms < 0) return procFail4Bool(4, "invalid timeout");

    const ns_total: u64 = @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms;
    const deadline: u64 = @as(u64, @intCast(std.time.nanoTimestamp())) + ns_total;

    const ctx_opt = current_ctx;
    proc.mutex.lock();
    while (!proc.done) {
        const now: u64 = @as(u64, @intCast(std.time.nanoTimestamp()));
        if (now >= deadline) {
            proc.mutex.unlock();
            return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), payloadFromBool(false), 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
        }
        const remaining = deadline - now;
        if (ctx_opt) |ctx| ctx.blocked.store(true, .release);
        const wait_res = proc.cv.timedWait(&proc.mutex, remaining);
        _ = wait_res catch |err| switch (err) {
            error.Timeout => {
                if (ctx_opt) |ctx| ctx.blocked.store(false, .release);
                proc.mutex.unlock();
                return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), payloadFromBool(false), 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
            },
        };

        // Cooperate with any in-flight STW without holding `proc.mutex`.
        proc.mutex.unlock();
        if (ctx_opt) |ctx| pollcheckCooperate(ctx);
        proc.mutex.lock();
        if (ctx_opt) |ctx| ctx.blocked.store(false, .release);
    }

    proc.mutex.unlock();
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), payloadFromBool(true), 14, payloadFromPtr(allocFlixStringFromAscii("")) }, 0b1000);
}

export fn flix_process_stdin_write(id: i64, buf_ptr: *anyopaque) *anyopaque {
    const proc = procLookup(id) orelse return procFail3("invalid process handle.");
    defer procRelease(proc);

    const bytes = flixInt8ArrayToBytes(std.heap.c_allocator, buf_ptr);
    defer std.heap.c_allocator.free(bytes);

    proc.mutex.lock();
    const stdin_file = proc.child.stdin;
    proc.mutex.unlock();

    if (stdin_file == null) return procFail3("stdin not available");

    const write_res = blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk stdin_file.?.writeAll(bytes);
    };
    _ = write_res catch |err| return procFail3(@errorName(err));

    if (bytes.len > std.math.maxInt(i32)) {
        return procFail3("write too large");
    }
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), @as(i64, @intCast(bytes.len)), payloadFromPtr(allocFlixStringFromAscii("")) }, 0b100);
}

export fn flix_process_stdout_read(id: i64, buf_ptr: *anyopaque) *anyopaque {
    const proc = procLookup(id) orelse return procFail3("invalid process handle.");
    defer procRelease(proc);

    const cap: usize = flixArrayLen(buf_ptr);
    const tmp = std.heap.c_allocator.alloc(u8, cap) catch return procFail3("out of memory");
    defer std.heap.c_allocator.free(tmp);

    proc.mutex.lock();
    const stdout_file = proc.child.stdout;
    proc.mutex.unlock();

    if (stdout_file == null) return procFail3("stdout not available");

    const n = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk stdout_file.?.read(tmp);
    }) catch |err| return procFail3(@errorName(err));

    flixWriteBytesToInt8Array(buf_ptr, tmp[0..n]);
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), @as(i64, @intCast(n)), payloadFromPtr(allocFlixStringFromAscii("")) }, 0b100);
}

export fn flix_process_stderr_read(id: i64, buf_ptr: *anyopaque) *anyopaque {
    const proc = procLookup(id) orelse return procFail3("invalid process handle.");
    defer procRelease(proc);

    const cap: usize = flixArrayLen(buf_ptr);
    const tmp = std.heap.c_allocator.alloc(u8, cap) catch return procFail3("out of memory");
    defer std.heap.c_allocator.free(tmp);

    proc.mutex.lock();
    const stderr_file = proc.child.stderr;
    proc.mutex.unlock();

    if (stderr_file == null) return procFail3("stderr not available");

    const n = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk stderr_file.?.read(tmp);
    }) catch |err| return procFail3(@errorName(err));

    flixWriteBytesToInt8Array(buf_ptr, tmp[0..n]);
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), @as(i64, @intCast(n)), payloadFromPtr(allocFlixStringFromAscii("")) }, 0b100);
}

export fn flix_process_release(id: i64) *anyopaque {
    ensureProcInitialized();

    var removed: ?std.AutoHashMap(i64, *ProcessObj).KV = null;
    {
        g_proc_mutex.lock();
        defer g_proc_mutex.unlock();
        removed = g_procs.fetchRemove(id);
    }

    if (removed) |kv| {
        procRelease(kv.value);
    }

    // Always succeed (matches JVM backend behavior).
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(true), payloadFromPtr(allocFlixStringFromAscii("")) }, 0b10);
}

fn httpFail(ctx: *anyopaque, kind: i64, msg: []const u8) *anyopaque {
    const region_ptr0: ?*anyopaque = if (current_region) |r| @ptrCast(r) else null;
    const empty_pairs = allocFlixArrayFromPtrPayloadsInRegion(ctx, region_ptr0, &[_]*anyopaque{});
    const empty_body = allocFlixStringFromAscii("");
    return allocFlixTupleFromPayloads(&.{
        payloadFromBool(false), // ok
        0, // status
        payloadFromPtr(empty_pairs), // respPairs
        payloadFromPtr(empty_body), // respBody
        kind, // kindCode
        payloadFromPtr(allocFlixStringFromAscii(msg)), // msg
    }, 0b101100);
}

fn httpOk(status: i64, resp_pairs_ptr: *anyopaque, resp_body_ptr: *anyopaque) *anyopaque {
    return allocFlixTupleFromPayloads(&.{
        payloadFromBool(true), // ok
        status, // status
        payloadFromPtr(resp_pairs_ptr), // respPairs
        payloadFromPtr(resp_body_ptr), // respBody
        14, // kindCode (Other)
        payloadFromPtr(allocFlixStringFromAscii("")), // msg
    }, 0b101100);
}

fn httpKindFromErr(err: anyerror) i64 {
    return switch (err) {
        error.UnexpectedCharacter, error.InvalidFormat, error.InvalidPort => 4, // InvalidInput
        error.UriMissingHost, error.UriHostTooLong => 4, // InvalidInput

        error.UnsupportedUriScheme => 12, // Unsupported
        error.HttpContentEncodingUnsupported => 12, // Unsupported
        error.UnsupportedCompressionMethod => 12, // Unsupported

        error.ConnectionTimedOut => 10, // Timeout

        error.UnknownHostName,
        error.HostLacksNetworkAddresses,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        => 13, // UnknownHost

        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.ConnectionResetByPeer,
        error.UnexpectedConnectFailure,
        => 1, // ConnectionFailed

        error.OutOfMemory => 14, // Other

        else => 14, // Other
    };
}

fn isPortableRedirectStatus(status: std.http.Status) bool {
    return switch (status) {
        .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => true,
        else => false,
    };
}

export fn flix_http_request(ctx: *anyopaque, method_ptr: *anyopaque, url_ptr: *anyopaque, req_headers_ptr: *anyopaque, has_body: bool, body_ptr: *anyopaque) *anyopaque {
    // Portable contract: if hasBody is false then the body must be empty.
    if (!has_body and flixStringLen(body_ptr) != 0) {
        return httpFail(ctx, 4, "invalid input");
    }

    const fctx: *FlixCtx = requireCtx(ctx);
    const region_ptr0: ?*anyopaque = if (current_region) |r| @ptrCast(r) else null;

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Decode inputs.
    const method_bytes = flixStringToUtf8Alloc(alloc, method_ptr);
    const url_bytes = flixStringToUtf8Alloc(alloc, url_ptr);
    const body_bytes_opt: ?[]const u8 = if (has_body) flixStringToUtf8Alloc(alloc, body_ptr) else null;

    // Parse method (limited to std.http.Method set).
    const method_up = alloc.alloc(u8, method_bytes.len) catch return httpFail(ctx, 14, "out of memory");
    for (method_bytes, 0..) |ch, i| method_up[i] = std.ascii.toUpper(ch);
    const method0 = std.meta.stringToEnum(std.http.Method, method_up) orelse return httpFail(ctx, 4, "invalid method");

    // Parse URL.
    const uri0 = std.Uri.parse(url_bytes) catch |err| return httpFail(ctx, 4, @errorName(err));

    // Portable contract: only http/https schemes are supported.
    if (!std.ascii.eqlIgnoreCase(uri0.scheme, "http") and !std.ascii.eqlIgnoreCase(uri0.scheme, "https")) {
        return httpFail(ctx, 12, "unsupported URL scheme");
    }

    // Decode request headers (pairs).
    const req_len: usize = flixArrayLen(req_headers_ptr);
    if ((req_len & 1) != 0) return httpFail(ctx, 4, "invalid headers");
    const header_count: usize = req_len / 2;
    const headers = alloc.alloc(std.http.Header, header_count) catch return httpFail(ctx, 14, "out of memory");

    const req_slots = flixArraySlots(req_headers_ptr);
    var hi: usize = 0;
    var idx: usize = 0;
    while (idx < req_len) : (idx += 2) {
        const k_ptr = ptrFromPayload(req_slots[idx]);
        const v_ptr = ptrFromPayload(req_slots[idx + 1]);
        headers[hi] = .{
            .name = flixStringToUtf8Alloc(alloc, k_ptr),
            .value = flixStringToUtf8Alloc(alloc, v_ptr),
        };
        hi += 1;
    }

    // Send request (and follow redirects like HttpClient.Redirect.NORMAL).
    var client: std.http.Client = .{ .allocator = std.heap.c_allocator };
    defer client.deinit();

    const original_is_https = std.ascii.eqlIgnoreCase(uri0.scheme, "https");

    var cur_uri = uri0;
    var cur_method = method0;
    var cur_body = body_bytes_opt;

    var redirects_left: usize = 5;
    while (true) {
        var req = (blk: {
            var guard = BlockedGuard.enter(fctx);
            defer guard.exitAndCooperate();
            break :blk client.request(cur_method, cur_uri, .{
                .redirect_behavior = .unhandled,
                .keep_alive = true,
                // Match JVM behavior more closely: do not implicitly negotiate compression.
                .headers = .{ .accept_encoding = .omit },
                .extra_headers = headers,
                .privileged_headers = &.{},
            });
        }) catch |err| return httpFail(ctx, httpKindFromErr(err), @errorName(err));
        defer req.deinit();

        if (cur_body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            const send_err: ?anyerror = send_blk: {
                var guard = BlockedGuard.enter(fctx);
                defer guard.exitAndCooperate();

                var bw = req.sendBodyUnflushed(&.{}) catch |err| break :send_blk err;
                bw.writer.writeAll(payload) catch |err| break :send_blk err;
                bw.end() catch |err| break :send_blk err;
                req.connection.?.flush() catch |err| break :send_blk err;

                break :send_blk null;
            };
            if (send_err) |err| return httpFail(ctx, httpKindFromErr(err), @errorName(err));
        } else {
            const send_res = blk: {
                var guard = BlockedGuard.enter(fctx);
                defer guard.exitAndCooperate();
                break :blk req.sendBodiless();
            };
            _ = send_res catch |err| return httpFail(ctx, httpKindFromErr(err), @errorName(err));
        }

        var resp = (blk: {
            var guard = BlockedGuard.enter(fctx);
            defer guard.exitAndCooperate();
            break :blk req.receiveHead(&.{});
        }) catch |err| return httpFail(ctx, httpKindFromErr(err), @errorName(err));

        const status = resp.head.status;
        const status_code: i64 = @intCast(@intFromEnum(status));

        // Redirect handling.
        if (isPortableRedirectStatus(status)) {
            if (resp.head.location) |location| {
                // Determine explicit redirect scheme (if any) for policy checks.
                const loc_uri = std.Uri.parse(location) catch std.Uri.parseAfterScheme("", location) catch |err| {
                    return httpFail(ctx, 4, @errorName(err));
                };
                const loc_scheme = loc_uri.scheme;

                // If original request is https and redirect target is explicitly http, reject.
                if (original_is_https and loc_scheme.len != 0 and std.ascii.eqlIgnoreCase(loc_scheme, "http")) {
                    return httpFail(ctx, 9, "redirect disallowed: https -> http");
                }

                // Unsupported redirect target scheme.
                if (loc_scheme.len != 0 and !std.ascii.eqlIgnoreCase(loc_scheme, "http") and !std.ascii.eqlIgnoreCase(loc_scheme, "https")) {
                    return httpFail(ctx, 12, "unsupported redirect scheme");
                }

                if (redirects_left == 0) {
                    return httpFail(ctx, 14, "redirect not followed");
                }
                redirects_left -= 1;

                // Resolve relative redirects against the current URI.
                const base_path_len: usize = switch (cur_uri.path) {
                    .raw => |s| s.len,
                    .percent_encoded => |s| s.len,
                };
                const buf_len: usize = @max(@as(usize, 8192), location.len + base_path_len + 16);
                const buf = alloc.alloc(u8, buf_len) catch return httpFail(ctx, 14, "out of memory");
                var aux_buf: []u8 = buf;
                @memcpy(aux_buf[0..location.len], location);
                const new_uri = cur_uri.resolveInPlace(location.len, &aux_buf) catch |err| {
                    return httpFail(ctx, 14, @errorName(err));
                };

                // Method rewriting rules (match HttpClient.Redirect.NORMAL semantics).
                if (status == .see_other or ((status == .moved_permanently or status == .found) and cur_method == .POST)) {
                    cur_method = .GET;
                    cur_body = null;
                }

                cur_uri = new_uri;
                continue;
            }
        }

        // Collect response headers as (lowercased name, value) pairs.
        var resp_ptrs: std.ArrayList(*anyopaque) = .empty;
        defer resp_ptrs.deinit(alloc);

        var it = resp.head.iterateHeaders();
        while (it.next()) |h| {
            const lower = alloc.alloc(u8, h.name.len) catch return httpFail(ctx, 14, "out of memory");
            for (h.name, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
            const key_ptr = allocFlixStringFromAscii(lower);
            const val_ptr = allocFlixStringFromUtf8Lossy(h.value);
            resp_ptrs.append(alloc, key_ptr) catch return httpFail(ctx, 14, "out of memory");
            resp_ptrs.append(alloc, val_ptr) catch return httpFail(ctx, 14, "out of memory");
        }

        const resp_pairs_ptr = allocFlixArrayFromPtrPayloadsInRegion(ctx, region_ptr0, resp_ptrs.items);

        // Read response body (UTF-8, lossy).
        const should_read_body =
            cur_method != .HEAD and
            status.class() != .informational and
            status != .no_content and
            status != .reset_content and
            status != .not_modified;

        const resp_body_ptr: *anyopaque = if (!should_read_body) blk: {
            break :blk allocFlixStringFromAscii("");
        } else blk: {
            var aw = std.Io.Writer.Allocating.init(alloc);
            defer aw.deinit();

            var transfer_buf: [64]u8 = undefined;
            const reader = req.reader.bodyReader(&transfer_buf, resp.head.transfer_encoding, resp.head.content_length);
            const read_res = io_blk: {
                var guard = BlockedGuard.enter(fctx);
                defer guard.exitAndCooperate();
                break :io_blk reader.streamRemaining(&aw.writer);
            };
            _ = read_res catch |err| return httpFail(ctx, httpKindFromErr(err), @errorName(err));
            break :blk allocFlixStringFromUtf8Lossy(aw.written());
        };

        return httpOk(status_code, resp_pairs_ptr, resp_body_ptr);
    }
}

}; // NativeProcHttp

comptime {
    // Force compilation of native-only portable primops, which are defined inside containers to
    // avoid compiling unsupported code on wasm targets. Without a reference, Zig may not codegen
    // exported decls inside such containers, causing unresolved symbols when linking LLVM-native.
    _ = NativeFsTcp;
    _ = NativeProcHttp;
}

const FlixResult = extern struct {
    tag: i64,
    payload: i64,
};

const RESULT_TAG_VALUE: i64 = 1;
const RESULT_TAG_THUNK: i64 = 2;
const RESULT_TAG_SUSPENSION: i64 = 3;
const RESULT_TAG_EXCEPTION: i64 = 4;

// ----------------------------------------------------------------------------
// Portable logical stack traces (bring-up)
//
// We maintain a per-thread logical stack of Flix function names (C strings),
// pushed/popped by compiler-inserted calls around function entry/exit.
//
// On throw, the compiler calls `flix_exn_with_trace`, which snapshots the current
// logical stack into a Flix heap object and stores it in the exception value.
// ----------------------------------------------------------------------------

const TraceName = [*:0]const u8;

threadlocal var trace_stack: std.ArrayListUnmanaged(TraceName) = .{};

export fn flix_trace_push(name: [*:0]const u8) void {
    if (trace_stack.capacity == 0) {
        trace_stack.ensureTotalCapacity(rt_alloc, 256) catch {};
    }
    trace_stack.append(rt_alloc, name) catch {};
}

export fn flix_trace_pop() void {
    if (trace_stack.items.len == 0) return;
    _ = trace_stack.pop();
}

fn captureTrace() *anyopaque {
    var ptrs: std.ArrayList(*anyopaque) = .empty;
    defer ptrs.deinit(rt_alloc);

    var i: usize = trace_stack.items.len;
    while (i > 0) : (i -= 1) {
        const cstr = trace_stack.items[i - 1];
        const bytes = std.mem.span(cstr);
        const s_ptr = allocFlixStringFromAscii(bytes);
        ptrs.append(rt_alloc, s_ptr) catch @panic("oom");
    }

    return allocFlixArrayFromPtrPayloads(ptrs.items);
}

export fn flix_exn_with_trace(exn0: ?*anyopaque) ?*anyopaque {
    const exn = exn0 orelse return null;
    const obj: *FlixObj = @ptrCast(@alignCast(exn));
    const ti = obj.typeinfo;
    const slots = objPayloadSlots(exn);
    // Layout: payload[0]=tag word, payload[1]=kind_id, payload[2]=payload, payload[3]=trace.
    if (slots[3] != 0) return exn;

    const trace_ptr = captureTrace();
    const trace_bits: i64 = payloadFromPtr(trace_ptr);

    if (ti.size_bytes == 0) @panic("flix_exn_with_trace: flex exceptions not supported");
    const size: usize = @intCast(ti.size_bytes);

    const mem = gcAllocBytes(size, ti);
    const dst = objPayloadSlots(mem);
    dst[0] = slots[0];
    dst[1] = slots[1];
    dst[2] = slots[2];
    dst[3] = trace_bits;
    return mem;
}

export fn flix_exn_report_ptr(exn: *anyopaque) void {
    const slots = objPayloadSlots(exn);
    const kind_id: i64 = slots[1];

    var buf: [128]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "Uncaught Flix exception (kind_id={}):\n", .{kind_id}) catch "Uncaught Flix exception:\n";
    if (is_wasm) {
        writeText(.stderr, allocFlixStringFromAscii(header), false);
    } else {
        std.fs.File.stderr().writeAll(header) catch {};
    }

    const trace_bits: i64 = slots[3];
    if (trace_bits == 0) {
        if (is_wasm) {
            writeText(.stderr, allocFlixStringFromAscii("  (no trace)"), true);
        } else {
            std.fs.File.stderr().writeAll("  (no trace)\n") catch {};
        }
        return;
    }

    const trace_ptr = ptrFromPayload(trace_bits);
    const trace_slots = flixArraySlots(trace_ptr);
    const len: usize = flixArrayLen(trace_ptr);

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const frame_bits: i64 = trace_slots[i];
        if (frame_bits == 0) continue;
        const frame_ptr = ptrFromPayload(frame_bits);
        if (is_wasm) {
            writeText(.stderr, allocFlixStringFromAscii("  at "), false);
        } else {
            std.fs.File.stderr().writeAll("  at ") catch {};
        }
        writeText(.stderr, frame_ptr, true);
    }
}

extern fn flix_effect_name(eff_sym_id: i64) ?[*:0]const u8;
extern fn flix_op_name(eff_sym_id: i64, op_index: i64) ?[*:0]const u8;

export fn flix_suspension_report_ptr(susp: *anyopaque) void {
    const slots: [*]i64 = objPayloadSlots(susp);
    const eff_sym_id: i64 = slots[0];
    const op_index: i64 = slots[1];
    const arg_count: i64 = slots[4];

    const eff_name = flix_effect_name(eff_sym_id);
    const op_name = flix_op_name(eff_sym_id, op_index);

    if (is_wasm) {
        writeText(.stderr, allocFlixStringFromAscii("Unhandled Flix suspension ("), false);
        if (eff_name) |eff_cstr| {
            writeText(.stderr, allocFlixStringFromAscii(std.mem.span(eff_cstr)), false);
            if (op_name) |op_cstr| {
                writeText(.stderr, allocFlixStringFromAscii("."), false);
                writeText(.stderr, allocFlixStringFromAscii(std.mem.span(op_cstr)), false);
            }
            writeText(.stderr, allocFlixStringFromAscii(", "), false);
        }

        var buf: [160]u8 = undefined;
        const tail = std.fmt.bufPrint(&buf, "effSymId={}, opIndex={}, argc={}):\n", .{ eff_sym_id, op_index, arg_count }) catch "):\n";
        writeText(.stderr, allocFlixStringFromAscii(tail), false);
    } else {
        std.fs.File.stderr().writeAll("Unhandled Flix suspension (") catch {};
        if (eff_name) |eff_cstr| {
            std.fs.File.stderr().writeAll(std.mem.span(eff_cstr)) catch {};
            if (op_name) |op_cstr| {
                std.fs.File.stderr().writeAll(".") catch {};
                std.fs.File.stderr().writeAll(std.mem.span(op_cstr)) catch {};
            }
            std.fs.File.stderr().writeAll(", ") catch {};
        }

        var buf: [160]u8 = undefined;
        const tail = std.fmt.bufPrint(&buf, "effSymId={}, opIndex={}, argc={}):\n", .{ eff_sym_id, op_index, arg_count }) catch "):\n";
        std.fs.File.stderr().writeAll(tail) catch {};
    }
}

export fn flix_exn_report(ctx_ptr: *anyopaque, exn_handle: i64) void {
    const exn_ptr = flix_handle_get(ctx_ptr, exn_handle);
    flix_exn_report_ptr(exn_ptr);
}

export fn flix_suspension_report(ctx_ptr: *anyopaque, susp_handle: i64) void {
    const susp_ptr = flix_handle_get(ctx_ptr, susp_handle);
    flix_suspension_report_ptr(susp_ptr);
}

export fn flix_suspension_eff_sym_id(ctx_ptr: *anyopaque, susp_handle: i64) i64 {
    const susp_ptr = flix_handle_get(ctx_ptr, susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    return slots[0];
}

export fn flix_suspension_op_index(ctx_ptr: *anyopaque, susp_handle: i64) i64 {
    const susp_ptr = flix_handle_get(ctx_ptr, susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    return slots[1];
}

export fn flix_suspension_arg_count(ctx_ptr: *anyopaque, susp_handle: i64) i64 {
    const susp_ptr = flix_handle_get(ctx_ptr, susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    return slots[4];
}

export fn flix_suspension_arg_as_i64(ctx_ptr: *anyopaque, susp_handle: i64, idx0: i64) i64 {
    if (idx0 < 0) @panic("suspension arg index must be non-negative");
    const idx: usize = @intCast(idx0);

    const susp_ptr = flix_handle_get(ctx_ptr, susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const arg_count_i64: i64 = slots[4];
    if (arg_count_i64 < 0) @panic("invalid suspension argCount");
    const arg_count: usize = @intCast(arg_count_i64);
    if (idx >= arg_count) @panic("suspension arg index out of bounds");

    const bits: i64 = slots[5 + idx];
    return flix_handle_new_i64(ctx_ptr, bits);
}

export fn flix_suspension_arg_as_ptr(ctx_ptr: *anyopaque, susp_handle: i64, idx0: i64) i64 {
    if (idx0 < 0) @panic("suspension arg index must be non-negative");
    const idx: usize = @intCast(idx0);

    const susp_ptr = flix_handle_get(ctx_ptr, susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const arg_count_i64: i64 = slots[4];
    if (arg_count_i64 < 0) @panic("invalid suspension argCount");
    const arg_count: usize = @intCast(arg_count_i64);
    if (idx >= arg_count) @panic("suspension arg index out of bounds");

    const bits: i64 = slots[5 + idx];
    if (bits == 0) @panic("suspension arg is null pointer");
    const ptr = ptrFromPayload(bits);
    return flix_handle_new(ctx_ptr, ptr);
}

const InvokeFn = *const fn (ctx: *anyopaque, self: *anyopaque, arg0: i64) callconv(.c) FlixResult;

const FlixTypeInfo = extern struct {
    type_id: u32,
    size_bytes: u32,
    ptr_count: u32,
    ptr_offs: ?[*]const u32,
    trace: ?*anyopaque,
    invoke: ?InvokeFn,
    apply: ?*anyopaque,
    copy: ?*anyopaque,
};

extern const flix_ti_array_prim: FlixTypeInfo;
extern const flix_ti_array_ptr: FlixTypeInfo;
extern const flix_ti_string: FlixTypeInfo;
extern const flix_ti_bigint: FlixTypeInfo;
extern const flix_ti_bigdecimal: FlixTypeInfo;
extern const flix_ti_suspension: FlixTypeInfo;

const FlixObj = if (@sizeOf(usize) == 4) extern struct {
    typeinfo: *const FlixTypeInfo,
    _pad: u32,
} else extern struct {
    typeinfo: *const FlixTypeInfo,
};

const EffectHandlerFn = *const fn (ctx: *anyopaque, handler: *anyopaque, resumption: *anyopaque, suspension: *anyopaque) callconv(.c) FlixResult;

fn ptrFromPayload(payload: i64) *anyopaque {
    const bits: u64 = @bitCast(payload);
    return @ptrFromInt(@as(usize, @intCast(bits)));
}

fn nullablePtrFromPayload(payload: i64) ?*anyopaque {
    return if (payload == 0) null else ptrFromPayload(payload);
}

fn payloadFromNullablePtrOrZero(ptr: ?*anyopaque) i64 {
    return if (ptr) |p| payloadFromPtr(p) else 0;
}

export fn flix_alloc(ctx_ptr: *anyopaque, ti: *const FlixTypeInfo) *anyopaque {
    _ = ctx_ptr;
    if (ti.size_bytes == 0) @panic("flix_alloc: flex objects not supported in bring-up");
    const size: usize = @intCast(ti.size_bytes);
    return gcAllocBytes(size, ti);
}

export fn flix_alloc_flex(ctx_ptr: *anyopaque, ti: *const FlixTypeInfo, size_bytes_i64: i64) *anyopaque {
    _ = ctx_ptr;
    if (size_bytes_i64 < 0) @panic("flix_alloc_flex: negative size");
    const size_bytes: usize = @intCast(size_bytes_i64);
    if (size_bytes < @sizeOf(FlixObj)) @panic("flix_alloc_flex: size too small");

    return gcAllocBytes(size_bytes, ti);
}

export fn flix_invoke_thunk(ctx: *anyopaque, thunk: *anyopaque, arg0: i64) FlixResult {
    return invokeThunk(ctx, thunk, arg0);
}

fn invokeThunk(ctx: *anyopaque, thunk: *anyopaque, arg0: i64) FlixResult {
    const obj: *FlixObj = @ptrCast(@alignCast(thunk));
    const ti = obj.typeinfo;
    const fn_ptr = ti.invoke orelse @panic("object has null invoke hook");
    return fn_ptr(ctx, thunk, arg0);
}

// ----------------------------------------------------------------------------
// Frames / Resumptions / Suspensions (bring-up)
//
// Representation (all pointers are to i64 slot arrays; nil = null pointer):
//
// FramesCons:
//   slots[0] = head frame ptr bits
//   slots[1] = tail frames ptr bits
//
// ResumptionCons:
//   slots[0] = effSymId (i64)
//   slots[1] = handler ptr bits
//   slots[2] = frames ptr bits
//   slots[3] = tail resumption ptr bits
//
// Suspension (flex):
//   slots[0] = effSymId (i64)
//   slots[1] = opIndex (i64)
//   slots[2] = prefix frames ptr bits
//   slots[3] = resumption ptr bits
//   slots[4] = argCount (i64)
//   slots[5..] = arg payloads (i64) (length argCount)
//
// Handler (fixed):
//   slots[0] = effSymId (i64)
//   slots[1] = opCount (i64)
//   slots[2 + 2*i]     = EffectHandlerFn ptr bits
//   slots[2 + 2*i + 1] = handler closure ptr bits (opaque to runtime; wrappers interpret)
// ----------------------------------------------------------------------------

export fn flix_frames_push(frame: *anyopaque, prefix: ?*anyopaque) *anyopaque {
    const payloads = [_]i64{
        payloadFromPtr(frame),
        payloadFromNullablePtrOrZero(prefix),
    };
    return allocFlixTupleFromPayloads(payloads[0..], 0b11);
}

export fn flix_frames_reverse_onto(prefix: ?*anyopaque, onto: ?*anyopaque) ?*anyopaque {
    var p = prefix;
    var acc = onto;
    while (p) |node| {
        const slots: [*]i64 = objPayloadSlots(node);
        const head_ptr = ptrFromPayload(slots[0]);
        const tail_ptr = nullablePtrFromPayload(slots[1]);
        acc = flix_frames_push(head_ptr, acc);
        p = tail_ptr;
    }
    return acc;
}

export fn flix_frame_copy(frame: *anyopaque) *anyopaque {
    const obj: *FlixObj = @ptrCast(@alignCast(frame));
    const ti = obj.typeinfo;
    if (ti.size_bytes == 0) @panic("invalid frame size");
    const size: usize = @intCast(ti.size_bytes);

    const mem = gcAllocBytes(size, ti);
    const src_bytes: [*]const u8 = @ptrCast(frame);
    const dst_bytes: [*]u8 = @ptrCast(mem);
    std.mem.copyForwards(u8, dst_bytes[0..size], src_bytes[0..size]);
    return mem;
}

fn applyFrameSnapshot(ctx: *anyopaque, frame_snapshot: *anyopaque, resume_payload: i64) FlixResult {
    const fresh = flix_frame_copy(frame_snapshot);
    return invokeThunk(ctx, fresh, resume_payload);
}

fn allocResumptionCons(eff_sym: i64, handler: *anyopaque, frames: ?*anyopaque, tail: ?*anyopaque) *anyopaque {
    const payloads = [_]i64{
        eff_sym,
        payloadFromPtr(handler),
        payloadFromNullablePtrOrZero(frames),
        payloadFromNullablePtrOrZero(tail),
    };
    // eff_sym is immediate; other three slots are pointers.
    return allocFlixTupleFromPayloads(payloads[0..], 0b1110);
}

fn allocSuspensionLike(src_susp: *anyopaque, prefix: ?*anyopaque, resumption: ?*anyopaque) *anyopaque {
    const src: [*]i64 = objPayloadSlots(src_susp);
    const eff_sym: i64 = src[0];
    const op_index: i64 = src[1];
    const arg_count_i64: i64 = src[4];
    if (arg_count_i64 < 0) @panic("invalid suspension argCount");
    const arg_count: usize = @intCast(arg_count_i64);

    const slots_total: usize = 5 + arg_count;
    const size_bytes: usize = @sizeOf(FlixObj) + slots_total * @sizeOf(i64);
    const src_obj: *FlixObj = @ptrCast(@alignCast(src_susp));
    const mem = gcAllocBytes(size_bytes, src_obj.typeinfo);
    const dst: [*]i64 = objPayloadSlots(mem);

    dst[0] = eff_sym;
    dst[1] = op_index;
    dst[2] = payloadFromNullablePtrOrZero(prefix);
    dst[3] = payloadFromNullablePtrOrZero(resumption);
    dst[4] = arg_count_i64;

    var i: usize = 0;
    while (i < arg_count) : (i += 1) {
        dst[5 + i] = src[5 + i];
    }

    return mem;
}

fn suspensionAttachFramesPrefix(susp: *anyopaque, frames0: ?*anyopaque) void {
    var frames = frames0;
    if (frames == null) return;

    const susp_slots: [*]i64 = objPayloadSlots(susp);
    var prefix_ptr = nullablePtrFromPayload(susp_slots[2]);
    while (frames) |node| {
        const slots: [*]i64 = objPayloadSlots(node);
        const head_frame = ptrFromPayload(slots[0]);
        const tail = nullablePtrFromPayload(slots[1]);
        prefix_ptr = flix_frames_push(head_frame, prefix_ptr);
        frames = tail;
    }
    susp_slots[2] = payloadFromNullablePtrOrZero(prefix_ptr);
}

export fn flix_resume_suspension(ctx: *anyopaque, susp: *anyopaque, resume_payload: i64) FlixResult {
    const slots: [*]i64 = objPayloadSlots(susp);
    const arg_count_i64: i64 = slots[4];
    if (arg_count_i64 < 0) @panic("suspension already resumed");

    const prefix_ptr = nullablePtrFromPayload(slots[2]);
    const resumption_ptr = nullablePtrFromPayload(slots[3]);

    // Consume the suspension so it cannot be resumed twice.
    slots[2] = 0;
    slots[3] = 0;
    slots[4] = -1;

    // Outer continuation frames (innermost-first) to apply after resumption rewinds.
    const frames = flix_frames_reverse_onto(prefix_ptr, null);

    var r: FlixResult = if (resumption_ptr) |rp| flix_resumption_rewind(ctx, rp, resume_payload) else FlixResult{ .tag = RESULT_TAG_VALUE, .payload = resume_payload };

    // Unwind thunks.
    while (r.tag == RESULT_TAG_THUNK) {
        const thunk_ptr = ptrFromPayload(r.payload);
        r = invokeThunk(ctx, thunk_ptr, 0);
    }

    // Apply outer frames.
    var cur_frames = frames;
    while (true) {
        switch (r.tag) {
            RESULT_TAG_VALUE => {
                if (cur_frames == null) return r;
                const node = cur_frames.?;
                const fslots: [*]i64 = objPayloadSlots(node);
                const head_frame = ptrFromPayload(fslots[0]);
                cur_frames = nullablePtrFromPayload(fslots[1]);

                r = applyFrameSnapshot(ctx, head_frame, r.payload);
                while (r.tag == RESULT_TAG_THUNK) {
                    const thunk_ptr = ptrFromPayload(r.payload);
                    r = invokeThunk(ctx, thunk_ptr, 0);
                }
                continue;
            },

            RESULT_TAG_SUSPENSION => {
                const susp_ptr = ptrFromPayload(r.payload);
                suspensionAttachFramesPrefix(susp_ptr, cur_frames);
                return r;
            },

            RESULT_TAG_EXCEPTION => return r,

            else => @panic("unexpected result tag"),
        }
    }
}

fn installHandlerResult(ctx: *anyopaque, eff_sym: i64, handler: *anyopaque, frames0: ?*anyopaque, initial: FlixResult) FlixResult {
    var frames = frames0;
    var r = initial;

    // Unwind thunks.
    while (r.tag == RESULT_TAG_THUNK) {
        const thunk_ptr = ptrFromPayload(r.payload);
        r = invokeThunk(ctx, thunk_ptr, 0);
    }

    // Handle.
    while (true) {
        switch (r.tag) {
            RESULT_TAG_VALUE => {
                if (frames == null) return r;

                const node = frames.?;
                const slots: [*]i64 = objPayloadSlots(node);
                const head_frame = ptrFromPayload(slots[0]);
                frames = nullablePtrFromPayload(slots[1]);

                r = applyFrameSnapshot(ctx, head_frame, r.payload);
                // Unwind thunks produced by the frame.
                while (r.tag == RESULT_TAG_THUNK) {
                    const thunk_ptr = ptrFromPayload(r.payload);
                    r = invokeThunk(ctx, thunk_ptr, 0);
                }
                continue;
            },

            RESULT_TAG_SUSPENSION => {
                const susp_ptr = ptrFromPayload(r.payload);
                const susp_slots: [*]i64 = objPayloadSlots(susp_ptr);
                const susp_eff_sym: i64 = susp_slots[0];
                const prefix_ptr = nullablePtrFromPayload(susp_slots[2]);
                const susp_resumption = nullablePtrFromPayload(susp_slots[3]);

                const combined_frames = flix_frames_reverse_onto(prefix_ptr, frames);
                const resumption_cons = allocResumptionCons(eff_sym, handler, combined_frames, susp_resumption);

                if (susp_eff_sym == eff_sym) {
                    const op_index_i64: i64 = susp_slots[1];
                    if (op_index_i64 < 0) @panic("invalid opIndex");
                    const op_index: usize = @intCast(op_index_i64);

                    const handler_slots: [*]i64 = objPayloadSlots(handler);
                    const op_count_i64: i64 = handler_slots[1];
                    if (op_count_i64 < 0) @panic("invalid opCount");
                    const op_count: usize = @intCast(op_count_i64);
                    if (op_index >= op_count) @panic("opIndex out of range");

                    const wrapper_bits: u64 = @bitCast(handler_slots[2 + op_index * 2]);
                    const wrapper_ptr: EffectHandlerFn = @ptrFromInt(@as(usize, @intCast(wrapper_bits)));
                    return wrapper_ptr(ctx, handler, resumption_cons, susp_ptr);
                }

                // Propagate suspension outward: reset prefix and update resumption.
                const new_susp = allocSuspensionLike(susp_ptr, null, resumption_cons);
                return FlixResult{ .tag = RESULT_TAG_SUSPENSION, .payload = payloadFromPtr(new_susp) };
            },

            RESULT_TAG_EXCEPTION => return r,

            else => @panic("unexpected result tag"),
        }
    }
}

export fn flix_install_handler(ctx: *anyopaque, eff_sym: i64, handler: *anyopaque, frames: ?*anyopaque, thunk: *anyopaque) FlixResult {
    // The body thunk passed from codegen is a v0 object with a `typeinfo.invoke` hook.
    const r0 = invokeThunk(ctx, thunk, 0);
    return installHandlerResult(ctx, eff_sym, handler, frames, r0);
}

export fn flix_resumption_rewind(ctx: *anyopaque, resumption0: ?*anyopaque, v: i64) FlixResult {
    if (resumption0 == null) {
        return FlixResult{ .tag = RESULT_TAG_VALUE, .payload = v };
    }

    const resumption = resumption0.?;
    const slots: [*]i64 = objPayloadSlots(resumption);
    const eff_sym: i64 = slots[0];
    const handler_ptr = ptrFromPayload(slots[1]);
    const frames_ptr = nullablePtrFromPayload(slots[2]);
    const tail_ptr = nullablePtrFromPayload(slots[3]);

    const tail_result = flix_resumption_rewind(ctx, tail_ptr, v);
    return installHandlerResult(ctx, eff_sym, handler_ptr, frames_ptr, tail_result);
}

const SpawnArgs = struct {
    clo: *anyopaque,
    region: ?*FlixRegion,
};

fn spawnThreadMain(args: SpawnArgs) void {
    const region_bits: usize = if (args.region) |r| @intFromPtr(r) else 0;
    dbg("spawn: start region={x}\n", .{region_bits});
    // Each thread owns its own runtime context (per pollcheck/handshake and future root tracking).
    const ctx = flix_ctx_new();
    defer flix_ctx_free(ctx);

    // Inherit the lexical region (if any) for nested region scopes in this thread.
    current_region = args.region;

    // Root the closure object for the duration of this thread. This is required because we do not
    // scan stacks conservatively, and thunks/closures are represented as heap objects.
    var clo_slot: ?*anyopaque = args.clo;
    flix_gc_push_root_ptr(ctx, @ptrCast(&clo_slot));
    defer flix_gc_pop_roots(ctx, 1);

    // Cooperate once before running user code to avoid races with an in-flight STW handshake.
    pollcheckCooperate(requireCtx(ctx));

    // The closure is now visible to the GC via the explicit roots; it is safe to remove the
    // temporary spawn root published by `flix_spawn`.
    spawnRootsRemove(args.clo);

    var r = invokeThunk(ctx, args.clo, 0);

    // Unwind thunks to completion.
    while (r.tag == RESULT_TAG_THUNK) {
        const thunk_ptr = ptrFromPayload(r.payload);
        r = invokeThunk(ctx, thunk_ptr, 0);
    }

    // Report uncaught exceptions (match JVM's default "print and terminate thread" behavior).
    if (r.tag == RESULT_TAG_EXCEPTION) {
        const exn_ptr = ptrFromPayload(r.payload);
        if (args.region) |region| {
            const fctx: *FlixCtx = requireCtx(ctx);
            const is_cancel = if (fctx.cancel_exn) |p| p == exn_ptr else false;

            if (!is_cancel) {
                // First exception wins.
                region.mutex.lock();
                if (region.child_exn == null) {
                    region.child_exn = exn_ptr;
                }
                // Request cooperative cancellation for siblings and parent.
                const cause_ptr = region.child_exn orelse exn_ptr;
                if (region.cancel_cause == null) region.cancel_cause = cause_ptr;
                region.cancel_requested.store(true, .release);
                region.mutex.unlock();
            }
        } else {
            flix_exn_report_ptr(exn_ptr);
        }
        return;
    }

    // Bring-up: suspensions from spawned threads are not yet supported.
    if (r.tag == RESULT_TAG_SUSPENSION) {
        const susp_ptr = ptrFromPayload(r.payload);
        flix_suspension_report_ptr(susp_ptr);
        return;
    }

    dbg("spawn: end\n", .{});
}

// ----------------------------------------------------------------------------
// Regions (bring-up): structured concurrency + region arenas.
//
// v0 semantics: region exit joins attached children and propagates the first
// child exception (if any), taking precedence over the parent outcome.
//
// Note: The allocator is currently mutex-protected for correctness across
// multi-threaded region-attached spawns (performance tuning later).
// ----------------------------------------------------------------------------

const FlixRegionState = enum(u8) {
    Open = 0,
    Closing = 1,
    Closed = 2,
};

const RememberedPtrArray = struct {
    base: [*]i64,
    count: usize,
};

const FlixRegion = struct {
    parent: ?*FlixRegion,
    state: FlixRegionState,
    cancel_requested: RtAtomic(bool),
    cancel_cause: ?*anyopaque,
    mutex: RtMutex,
    arena: std.heap.ArenaAllocator,
    children: std.ArrayListUnmanaged(RtThread),
    child_exn: ?*anyopaque,
    exit_initialized: bool,
    exit_body_tag: i64,
    exit_body_payload: i64,
    remembered_slots: std.ArrayListUnmanaged(*i64),
    remembered_ptr_arrays: std.ArrayListUnmanaged(RememberedPtrArray),
};

threadlocal var current_region: ?*FlixRegion = null;

// Registered live regions (GC root source via remembered sets).
var g_region_registry_initialized: bool = false;
var g_region_registry_mutex: RtMutex = .{};
var g_region_registry: std.AutoHashMap(usize, u8) = undefined;

fn ensureRegionRegistryInitialized() void {
    if (g_region_registry_initialized) return;
    g_region_registry_mutex.lock();
    defer g_region_registry_mutex.unlock();
    if (g_region_registry_initialized) return;
    g_region_registry = std.AutoHashMap(usize, u8).init(rt_alloc);
    g_region_registry_initialized = true;
}

fn registerRegion(region: *FlixRegion) void {
    ensureRegionRegistryInitialized();
    g_region_registry_mutex.lock();
    defer g_region_registry_mutex.unlock();
    g_region_registry.put(@intFromPtr(region), 0) catch @panic("oom");
}

fn deregisterRegion(region: *FlixRegion) void {
    if (!g_region_registry_initialized) return;
    g_region_registry_mutex.lock();
    defer g_region_registry_mutex.unlock();
    _ = g_region_registry.remove(@intFromPtr(region));
}

export fn flix_region_enter(ctx: *anyopaque) *anyopaque {
    _ = ctx;

    const parent = current_region;
    const region = rt_alloc.create(FlixRegion) catch @panic("oom");
    region.* = .{
        .parent = parent,
        .state = .Open,
        .cancel_requested = .init(false),
        .cancel_cause = null,
        .mutex = .{},
        .arena = std.heap.ArenaAllocator.init(rt_alloc),
        .children = .{},
        .child_exn = null,
        .exit_initialized = false,
        .exit_body_tag = 0,
        .exit_body_payload = 0,
        .remembered_slots = .{},
        .remembered_ptr_arrays = .{},
    };

    current_region = region;
    registerRegion(region);
    const parent_bits: usize = if (parent) |p| @intFromPtr(p) else 0;
    dbg("region_enter: {x} parent={x}\n", .{ @intFromPtr(region), parent_bits });
    return region;
}

export fn flix_region_exit(ctx: *anyopaque, region_ptr0: ?*anyopaque, body_tag: i64, body_payload: i64) FlixResult {
    const fctx: *FlixCtx = requireCtx(ctx);
    var body_outcome: FlixResult = .{ .tag = body_tag, .payload = body_payload };

    // `body_outcome` may carry a pointer payload that is not otherwise present in the explicit root
    // stack (it is passed by value across the region delimiter). Since `region_exit` may block while
    // joining children, we root it explicitly for the duration of this function.
    const roots_len0 = fctx.roots.items.len;
    var outcome_payload_slot: i64 = body_outcome.payload;
    fctx.roots.append(rt_alloc, .{ .kind = .ValueI64, .slot_ptr = @ptrCast(&outcome_payload_slot) }) catch @panic("oom");
    defer fctx.roots.items.len = roots_len0;

    const region_ptr = region_ptr0 orelse return body_outcome;
    const region: *FlixRegion = @ptrCast(@alignCast(region_ptr));
    dbg("region_exit: {x} start\n", .{@intFromPtr(region)});

    if (is_wasm) {
        const ctx_rep = current_wit_ctx orelse @panic("flix_region_exit: missing wasm WIT context");

        // Close the region (idempotent) and cache the body outcome for retries.
        region.mutex.lock();
        switch (region.state) {
            .Open => {
                if (current_region != region) {
                    @panic("flix_region_exit: region mismatch");
                }

                // `Region` is a delimiter: only VALUE or EXCEPTION outcomes are legal.
                if (body_outcome.tag != RESULT_TAG_VALUE and body_outcome.tag != RESULT_TAG_EXCEPTION) {
                    @panic("flix_region_exit: invalid body outcome");
                }

                region.exit_initialized = true;
                region.exit_body_tag = body_outcome.tag;
                region.exit_body_payload = body_outcome.payload;
                outcome_payload_slot = body_outcome.payload;

                // Pop the region from the thread-local stack early so nested unwinding uses the parent.
                current_region = region.parent;

                region.state = .Closing;
            },

            .Closing => {
                if (!region.exit_initialized) @panic("flix_region_exit: closing without stored body outcome");
                body_outcome = .{ .tag = region.exit_body_tag, .payload = region.exit_body_payload };
                outcome_payload_slot = body_outcome.payload;
            },

            .Closed => @panic("flix_region_exit: region already closed"),
        }

        // Request cooperative cancellation iff a child has thrown.
        //
        // Important: we intentionally do *not* request cancellation solely because the parent is exiting exceptionally.
        // This preserves the JVM backend behavior where children are allowed to run to completion and any child
        // exception takes precedence over the parent exception at region exit.
        if (region.child_exn) |cause_ptr| {
            if (region.cancel_cause == null) region.cancel_cause = cause_ptr;
            region.cancel_requested.store(true, .release);
        }

        region.mutex.unlock();

        // Join all attached children before reclaiming arena memory. On wasm this may suspend.
        for (region.children.items) |t| {
            const task_id = t.task_id;
            const tptr = ctx_rep.tasks.getPtr(task_id) orelse continue;
            switch (tptr.state) {
                .Completed => {},
                else => {
                    const susp = allocTimerSleepSuspension(0);
                    return FlixResult{ .tag = RESULT_TAG_SUSPENSION, .payload = payloadFromPtr(susp) };
                },
            }
        }
        dbg("region_exit: {x} joined\n", .{@intFromPtr(region)});

        // Child exception takes precedence over parent outcome at region exit.
        region.mutex.lock();
        const out: FlixResult = if (region.child_exn) |exn_ptr|
            FlixResult{ .tag = RESULT_TAG_EXCEPTION, .payload = payloadFromPtr(exn_ptr) }
        else
            body_outcome;
        outcome_payload_slot = out.payload;

        // Release and remove all region-attached child tasks (host-invisible).
        for (region.children.items) |t| {
            const task_id = t.task_id;
            const task_ptr = ctx_rep.tasks.getPtr(task_id) orelse continue;
            switch (task_ptr.state) {
                .Completed => |st| {
                    if (!st.consumed) flix_handle_release(ctx_rep.flix_ctx, st.handle);
                },
                else => @panic("region_exit: unexpected non-completed child at join completion"),
            }
            _ = ctx_rep.tasks.remove(task_id);
        }
        region.children.deinit(rt_alloc);
        region.children = .{};

        region.state = .Closed;
        region.mutex.unlock();

        // Region remembered-set metadata.
        region.remembered_slots.deinit(rt_alloc);
        region.remembered_ptr_arrays.deinit(rt_alloc);

        region.arena.deinit();
        deregisterRegion(region);
        rt_alloc.destroy(region);
        dbg("region_exit: {x} done\n", .{@intFromPtr(region)});
        return out;
    } else {
        if (current_region != region) {
            @panic("flix_region_exit: region mismatch");
        }

        // `Region` is a delimiter: only VALUE or EXCEPTION outcomes are legal.
        if (body_outcome.tag != RESULT_TAG_VALUE and body_outcome.tag != RESULT_TAG_EXCEPTION) {
            @panic("flix_region_exit: invalid body outcome");
        }

        // Pop the region from the thread-local stack early so nested unwinding uses the parent.
        current_region = region.parent;

        // Close region and snapshot children (prevents racy spawn/join).
        region.mutex.lock();
        region.state = .Closing;

        // Request cooperative cancellation iff a child has thrown.
        //
        // Important: we intentionally do *not* request cancellation solely because the parent is exiting exceptionally.
        // This preserves the JVM backend behavior where children are allowed to run to completion and any child
        // exception takes precedence over the parent exception at region exit.
        //
        // (Cancellation requests due to a child exception are also performed eagerly in `spawnThreadMain`.)
        if (region.child_exn) |cause_ptr| {
            if (region.cancel_cause == null) region.cancel_cause = cause_ptr;
            region.cancel_requested.store(true, .release);
        }

        var children = region.children;
        region.children = .{};
        region.mutex.unlock();

        // Join all attached children before reclaiming arena memory.
        fctx.blocked.store(true, .release);
        for (children.items) |t| {
            t.join();
        }
        pollcheckCooperate(fctx);
        fctx.blocked.store(false, .release);
        children.deinit(rt_alloc);
        dbg("region_exit: {x} joined\n", .{@intFromPtr(region)});

        // Child exception takes precedence over parent outcome at region exit.
        region.mutex.lock();
        const child_exn_ptr = region.child_exn;
        region.state = .Closed;
        region.mutex.unlock();

        const out = if (child_exn_ptr) |exn_ptr|
            FlixResult{ .tag = RESULT_TAG_EXCEPTION, .payload = payloadFromPtr(exn_ptr) }
        else
            body_outcome;

        // Region remembered-set metadata.
        region.remembered_slots.deinit(rt_alloc);
        region.remembered_ptr_arrays.deinit(rt_alloc);

        region.arena.deinit();
        deregisterRegion(region);
        rt_alloc.destroy(region);
        dbg("region_exit: {x} done\n", .{@intFromPtr(region)});
        return out;
    }
}

export fn flix_region_malloc(ctx: *anyopaque, region_ptr0: ?*anyopaque, size_bytes_i64: i64) *anyopaque {
    _ = ctx;

    if (size_bytes_i64 < 0) @panic("flix_region_malloc: negative size");
    const size_bytes: usize = @intCast(size_bytes_i64);

    if (region_ptr0) |region_ptr| {
        const region: *FlixRegion = @ptrCast(@alignCast(region_ptr));

        region.mutex.lock();
        defer region.mutex.unlock();

        if (region.state == .Closed) {
            @panic("flix_region_malloc: region is closed");
        }

        const bytes = region.arena.allocator().alignedAlloc(u8, std.mem.Alignment.of(i64), size_bytes) catch @panic("oom");
        return bytes.ptr;
    }

    return c.malloc(size_bytes) orelse @panic("malloc failed");
}

export fn flix_region_alloc(ctx: *anyopaque, region_ptr0: ?*anyopaque, ti: *const FlixTypeInfo) *anyopaque {
    if (ti.size_bytes == 0) @panic("flix_region_alloc: flex objects not supported in bring-up");
    const size_bytes_i64: i64 = @intCast(ti.size_bytes);
    const mem = flix_region_malloc(ctx, region_ptr0, size_bytes_i64);
    const obj: *FlixObj = @ptrCast(@alignCast(mem));
    obj.typeinfo = ti;
    if (@hasField(FlixObj, "_pad")) obj._pad = 0;
    return mem;
}

export fn flix_region_alloc_flex(ctx: *anyopaque, region_ptr0: ?*anyopaque, ti: *const FlixTypeInfo, size_bytes_i64: i64) *anyopaque {
    if (size_bytes_i64 < 0) @panic("flix_region_alloc_flex: negative size");
    const size_bytes: usize = @intCast(size_bytes_i64);
    if (size_bytes < @sizeOf(FlixObj)) @panic("flix_region_alloc_flex: size too small");

    const mem = flix_region_malloc(ctx, region_ptr0, size_bytes_i64);
    const obj: *FlixObj = @ptrCast(@alignCast(mem));
    obj.typeinfo = ti;
    if (@hasField(FlixObj, "_pad")) obj._pad = 0;
    return mem;
}

export fn flix_region_remember_slot(ctx: *anyopaque, region_ptr0: ?*anyopaque, slot_ptr: *anyopaque) void {
    _ = ctx;
    const region_ptr = region_ptr0 orelse return;
    const region: *FlixRegion = @ptrCast(@alignCast(region_ptr));

    region.mutex.lock();
    defer region.mutex.unlock();

    if (region.state == .Closed) {
        @panic("flix_region_remember_slot: region is closed");
    }

    const slot: *i64 = @ptrCast(@alignCast(slot_ptr));
    region.remembered_slots.append(rt_alloc, slot) catch @panic("oom");
}

export fn flix_region_remember_ptr_array(ctx: *anyopaque, region_ptr0: ?*anyopaque, base_ptr: *anyopaque, count_i64: i64) void {
    _ = ctx;
    const region_ptr = region_ptr0 orelse return;
    const region: *FlixRegion = @ptrCast(@alignCast(region_ptr));

    if (count_i64 < 0) @panic("flix_region_remember_ptr_array: negative count");
    const count: usize = @intCast(count_i64);

    region.mutex.lock();
    defer region.mutex.unlock();

    if (region.state == .Closed) {
        @panic("flix_region_remember_ptr_array: region is closed");
    }

    const base_slots: [*]i64 = @ptrCast(@alignCast(base_ptr));
    region.remembered_ptr_arrays.append(rt_alloc, .{ .base = base_slots, .count = count }) catch @panic("oom");
}

export fn flix_store_ptr(ctx: *anyopaque, slot_ptr: *anyopaque, value: i64) void {
    _ = ctx;
    const slot: *i64 = @ptrCast(@alignCast(slot_ptr));
    slot.* = value;
}

export fn flix_spawn(ctx: *anyopaque, region_ptr0: ?*anyopaque, clo: *anyopaque) i64 {
    if (is_wasm) {
        const ctx_rep = current_wit_ctx orelse @panic("flix_spawn: missing wasm WIT context");
        const fctx: *FlixCtx = requireCtx(ctx);
        _ = fctx;

        const region: ?*FlixRegion = if (region_ptr0) |rp| @ptrCast(@alignCast(rp)) else null;

        if (region) |r| {
            r.mutex.lock();
            defer r.mutex.unlock();
            if (r.state != .Open) {
                @panic("flix_spawn: spawn into closing/closed region");
            }
        }

        // Root the closure for the lifetime of the spawned task via a handle.
        const clo_handle = flix_handle_new(ctx, clo);

        const task_id = ctx_rep.next_task_id;
        ctx_rep.next_task_id +%= 1;

        const t: Task = .{
            .kind = .{ .Thunk = clo_handle },
            .args = .{},
            .state = .ReadyStart,
            .region = region,
            .host_visible = false,
        };

        ctx_rep.tasks.put(rt_alloc, task_id, t) catch @panic("oom");
        taskQueuePush(ctx_rep, task_id);

        if (region) |r| {
            r.mutex.lock();
            defer r.mutex.unlock();
            r.children.append(rt_alloc, .{ .task_id = task_id }) catch @panic("oom");
        }

        return 0;
    } else {
        // Publish the closure pointer as a temporary GC root until the new thread has a chance to
        // register its context and root the closure explicitly.
        spawnRootsAdd(clo);
        if (region_ptr0) |region_ptr| {
            const region: *FlixRegion = @ptrCast(@alignCast(region_ptr));

            region.mutex.lock();
            defer region.mutex.unlock();

            if (region.state != .Open) {
                @panic("flix_spawn: spawn into closing/closed region");
            }

            const t = std.Thread.spawn(.{}, spawnThreadMain, .{SpawnArgs{ .clo = clo, .region = region }}) catch @panic("spawn failed");
            region.children.append(rt_alloc, t) catch @panic("oom");
            return 0;
        }

        // Detached spawn in the Static region (represented as null).
        const t = std.Thread.spawn(.{}, spawnThreadMain, .{SpawnArgs{ .clo = clo, .region = null }}) catch @panic("spawn failed");
        t.detach();
        return 0;
    }
}

// ----------------------------------------------------------------------------
// Wasm Component Model (WIT) Runtime Exports (bring-up)
//
// These exports implement `flix:runtime/runtime@0.1.0` as generated by
// `wit-bindgen` (C) in `runtime/src/wit/flix.c`.
//
// Important:
// - These symbols must exist for the wasm component build.
// - For native LLVM builds, these are unused and compiled out via `is_wasm`.
// - The cooperative scheduler is single-threaded (no wasm threads yet).
// ----------------------------------------------------------------------------

// `wit-bindgen` emits a link anchor for a separate `*_component_type.o` object.
// We do not use that object (we embed WIT via `wasm-tools component embed`), so provide a stub.
export fn __component_type_object_force_link_flix() void {}

// WIT canonical ABI string/list shapes.
const flix_string_t = extern struct {
    ptr: [*]u8,
    len: usize,
};

const flix_list_u8_t = extern struct {
    ptr: [*]u8,
    len: usize,
};

const flix_list_string_t = extern struct {
    ptr: [*]flix_string_t,
    len: usize,
};

const flix_option_string_t = extern struct {
    is_some: bool,
    val: flix_string_t,
};

// Resource handles (`own<T>`).
const exports_flix_runtime_runtime_own_ctx_t = extern struct {
    __handle: i32,
};

const exports_flix_runtime_runtime_own_value_t = extern struct {
    __handle: i32,
};

const exports_flix_runtime_runtime_own_suspension_t = extern struct {
    __handle: i32,
};

// Opaque resource reps (we define them here).
const exports_flix_runtime_runtime_ctx_t = struct {
    flix_ctx: *anyopaque,
    next_task_id: u64,
    tasks: std.AutoHashMap(u64, Task).Unmanaged,
    ready: std.ArrayListUnmanaged(u64),
    ready_head: usize,
};

const exports_flix_runtime_runtime_value_t = struct {
    flix_ctx: *anyopaque,
    handle: i64,
};

const exports_flix_runtime_runtime_suspension_t = struct {
    flix_ctx: *anyopaque,
    task_id: u64,
    susp_handle: i64,
};

// Borrow types (`borrow<T>`) are passed as rep pointers by the canonical ABI.
const exports_flix_runtime_runtime_borrow_ctx_t = *exports_flix_runtime_runtime_ctx_t;
const exports_flix_runtime_runtime_borrow_value_t = *exports_flix_runtime_runtime_value_t;
const exports_flix_runtime_runtime_borrow_suspension_t = *exports_flix_runtime_runtime_suspension_t;

// Stable symbol id (effect ids, op ids, def ids, etc).
const exports_flix_runtime_runtime_sym_t = u64;

// Stable exported definition id.
const exports_flix_runtime_runtime_def_id_t = u64;

// Host-visible id for a scheduled task (opaque to the host).
const exports_flix_runtime_runtime_task_id_t = u64;

// Suspension result produced by `invoke`.
const exports_flix_runtime_runtime_suspended_exec_t = extern struct {
    task: exports_flix_runtime_runtime_task_id_t,
    suspension: exports_flix_runtime_runtime_own_suspension_t,
};

// Execution outcome.
const exports_flix_runtime_runtime_exec_t = extern struct {
    tag: u8,
    val: extern union {
        ok: exports_flix_runtime_runtime_own_value_t,
        thrown: exports_flix_runtime_runtime_own_value_t,
        suspended: exports_flix_runtime_runtime_suspended_exec_t,
    },
};

const exports_flix_runtime_runtime_task_outcome_t = extern struct {
    tag: u8,
    val: extern union {
        ok: exports_flix_runtime_runtime_own_value_t,
        thrown: exports_flix_runtime_runtime_own_value_t,
    },
};

// Minimal suspension metadata.
const exports_flix_runtime_runtime_suspension_info_t = extern struct {
    eff_id: exports_flix_runtime_runtime_sym_t,
    op_id: exports_flix_runtime_runtime_sym_t,
};

const exports_flix_runtime_runtime_list_borrow_value_t = extern struct {
    ptr: [*]exports_flix_runtime_runtime_borrow_value_t,
    len: usize,
};

const exports_flix_runtime_runtime_list_own_suspension_t = extern struct {
    ptr: [*]exports_flix_runtime_runtime_own_suspension_t,
    len: usize,
};

// WIT request/response record types.
const exports_flix_runtime_runtime_timer_sleep_req_t = extern struct {
    ms: u64,
};

const exports_flix_runtime_runtime_http_header_t = extern struct {
    name: flix_string_t,
    value: flix_string_t,
};

const exports_flix_runtime_runtime_list_http_header_t = extern struct {
    ptr: [*]exports_flix_runtime_runtime_http_header_t,
    len: usize,
};

const exports_flix_runtime_runtime_http_request_req_t = extern struct {
    method: flix_string_t,
    url: flix_string_t,
    headers: exports_flix_runtime_runtime_list_http_header_t,
    body: flix_option_string_t,
};

const exports_flix_runtime_runtime_http_response_t = extern struct {
    status: u16,
    headers: exports_flix_runtime_runtime_list_http_header_t,
    body: flix_string_t,
};

const exports_flix_runtime_runtime_io_error_t = extern struct {
    kind_code: i32,
    msg: flix_string_t,
};

const exports_flix_runtime_runtime_file_exists_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_is_directory_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_is_regular_file_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_is_readable_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_is_symbolic_link_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_is_writable_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_is_executable_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_access_time_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_creation_time_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_modification_time_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_size_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_read_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_read_lines_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_read_bytes_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_list_req_t = extern struct { path: flix_string_t };

const exports_flix_runtime_runtime_file_write_req_t = extern struct {
    path: flix_string_t,
    data: flix_string_t,
};

const exports_flix_runtime_runtime_file_write_bytes_req_t = extern struct {
    path: flix_string_t,
    bytes: flix_list_u8_t,
};

const exports_flix_runtime_runtime_file_append_req_t = extern struct {
    path: flix_string_t,
    data: flix_string_t,
};

const exports_flix_runtime_runtime_file_append_bytes_req_t = extern struct {
    path: flix_string_t,
    bytes: flix_list_u8_t,
};

const exports_flix_runtime_runtime_file_truncate_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_mkdir_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_mkdirs_req_t = extern struct { path: flix_string_t };
const exports_flix_runtime_runtime_file_mk_temp_dir_req_t = extern struct { prefix: flix_string_t };

const exports_flix_runtime_runtime_process_env_var_t = extern struct {
    key: flix_string_t,
    value: flix_string_t,
};

const exports_flix_runtime_runtime_list_process_env_var_t = extern struct {
    ptr: [*]exports_flix_runtime_runtime_process_env_var_t,
    len: usize,
};

const exports_flix_runtime_runtime_process_exec_req_t = extern struct {
    argv: flix_list_string_t,
    cwd: flix_option_string_t,
    env: exports_flix_runtime_runtime_list_process_env_var_t,
};

const exports_flix_runtime_runtime_process_exit_value_req_t = extern struct { process_id: u64 };
const exports_flix_runtime_runtime_process_is_alive_req_t = extern struct { process_id: u64 };
const exports_flix_runtime_runtime_process_pid_req_t = extern struct { process_id: u64 };
const exports_flix_runtime_runtime_process_stop_req_t = extern struct { process_id: u64 };
const exports_flix_runtime_runtime_process_wait_for_req_t = extern struct { process_id: u64 };
const exports_flix_runtime_runtime_process_wait_for_timeout_req_t = extern struct {
    process_id: u64,
    timeout_ms: i64,
};

const exports_flix_runtime_runtime_process_stdin_write_req_t = extern struct {
    process_id: u64,
    bytes: flix_list_u8_t,
};

const exports_flix_runtime_runtime_process_stdout_read_req_t = extern struct {
    process_id: u64,
    max_bytes: u32,
};

const exports_flix_runtime_runtime_process_stderr_read_req_t = extern struct {
    process_id: u64,
    max_bytes: u32,
};

const exports_flix_runtime_runtime_process_release_req_t = extern struct { process_id: u64 };

const exports_flix_runtime_runtime_tcp_socket_connect_req_t = extern struct {
    ip: flix_list_u8_t,
    port: u16,
};

const exports_flix_runtime_runtime_tcp_socket_read_req_t = extern struct {
    socket_id: u64,
    max_bytes: u32,
};

const exports_flix_runtime_runtime_tcp_socket_write_req_t = extern struct {
    socket_id: u64,
    bytes: flix_list_u8_t,
};

const exports_flix_runtime_runtime_tcp_socket_close_req_t = extern struct {
    socket_id: u64,
};

const exports_flix_runtime_runtime_tcp_server_bind_req_t = extern struct {
    ip: flix_list_u8_t,
    port: u16,
};

const exports_flix_runtime_runtime_tcp_server_accept_req_t = extern struct { server_id: u64 };
const exports_flix_runtime_runtime_tcp_server_local_port_req_t = extern struct { server_id: u64 };
const exports_flix_runtime_runtime_tcp_server_close_req_t = extern struct { server_id: u64 };

const exports_flix_runtime_runtime_unknown_req_t = extern struct {
    eff_id: exports_flix_runtime_runtime_sym_t,
    op_id: exports_flix_runtime_runtime_sym_t,
};

const exports_flix_runtime_runtime_op_request_t = extern struct {
    tag: u8,
    val: extern union {
        timer_sleep: exports_flix_runtime_runtime_timer_sleep_req_t,
        http_request: exports_flix_runtime_runtime_http_request_req_t,
        file_exists: exports_flix_runtime_runtime_file_exists_req_t,
        file_is_directory: exports_flix_runtime_runtime_file_is_directory_req_t,
        file_is_regular_file: exports_flix_runtime_runtime_file_is_regular_file_req_t,
        file_is_readable: exports_flix_runtime_runtime_file_is_readable_req_t,
        file_is_symbolic_link: exports_flix_runtime_runtime_file_is_symbolic_link_req_t,
        file_is_writable: exports_flix_runtime_runtime_file_is_writable_req_t,
        file_is_executable: exports_flix_runtime_runtime_file_is_executable_req_t,
        file_access_time: exports_flix_runtime_runtime_file_access_time_req_t,
        file_creation_time: exports_flix_runtime_runtime_file_creation_time_req_t,
        file_modification_time: exports_flix_runtime_runtime_file_modification_time_req_t,
        file_size: exports_flix_runtime_runtime_file_size_req_t,
        file_read: exports_flix_runtime_runtime_file_read_req_t,
        file_read_lines: exports_flix_runtime_runtime_file_read_lines_req_t,
        file_read_bytes: exports_flix_runtime_runtime_file_read_bytes_req_t,
        file_list: exports_flix_runtime_runtime_file_list_req_t,
        file_write: exports_flix_runtime_runtime_file_write_req_t,
        file_write_bytes: exports_flix_runtime_runtime_file_write_bytes_req_t,
        file_append: exports_flix_runtime_runtime_file_append_req_t,
        file_append_bytes: exports_flix_runtime_runtime_file_append_bytes_req_t,
        file_truncate: exports_flix_runtime_runtime_file_truncate_req_t,
        file_mkdir: exports_flix_runtime_runtime_file_mkdir_req_t,
        file_mkdirs: exports_flix_runtime_runtime_file_mkdirs_req_t,
        file_mk_temp_dir: exports_flix_runtime_runtime_file_mk_temp_dir_req_t,
        process_exec: exports_flix_runtime_runtime_process_exec_req_t,
        process_exit_value: exports_flix_runtime_runtime_process_exit_value_req_t,
        process_is_alive: exports_flix_runtime_runtime_process_is_alive_req_t,
        process_pid: exports_flix_runtime_runtime_process_pid_req_t,
        process_stop: exports_flix_runtime_runtime_process_stop_req_t,
        process_wait_for: exports_flix_runtime_runtime_process_wait_for_req_t,
        process_wait_for_timeout: exports_flix_runtime_runtime_process_wait_for_timeout_req_t,
        process_stdin_write: exports_flix_runtime_runtime_process_stdin_write_req_t,
        process_stdout_read: exports_flix_runtime_runtime_process_stdout_read_req_t,
        process_stderr_read: exports_flix_runtime_runtime_process_stderr_read_req_t,
        process_release: exports_flix_runtime_runtime_process_release_req_t,
        tcp_socket_connect: exports_flix_runtime_runtime_tcp_socket_connect_req_t,
        tcp_socket_read: exports_flix_runtime_runtime_tcp_socket_read_req_t,
        tcp_socket_write: exports_flix_runtime_runtime_tcp_socket_write_req_t,
        tcp_socket_close: exports_flix_runtime_runtime_tcp_socket_close_req_t,
        tcp_server_bind: exports_flix_runtime_runtime_tcp_server_bind_req_t,
        tcp_server_accept: exports_flix_runtime_runtime_tcp_server_accept_req_t,
        tcp_server_local_port: exports_flix_runtime_runtime_tcp_server_local_port_req_t,
        tcp_server_close: exports_flix_runtime_runtime_tcp_server_close_req_t,
        unknown: exports_flix_runtime_runtime_unknown_req_t,
    },
};

// Helper functions from `wit-bindgen` C glue (defined in `runtime/src/wit/flix.c`).
//
// Note: The LLVM-native backend links `flix_rt_llvm.zig` without the WIT C glue. To keep the native
// runtime linkable we provide **weak** stub definitions for these helpers.
//
// When building wasm components, the real (strong) implementations from `runtime/src/wit/flix.c`
// override these stubs.

fn exports_flix_runtime_runtime_ctx_new(rep: *exports_flix_runtime_runtime_ctx_t) callconv(.c) exports_flix_runtime_runtime_own_ctx_t {
    _ = rep;
    @panic("exports_flix_runtime_runtime_ctx_new: WIT glue unavailable (native build)");
}

fn exports_flix_runtime_runtime_ctx_rep(handle: exports_flix_runtime_runtime_own_ctx_t) callconv(.c) *exports_flix_runtime_runtime_ctx_t {
    _ = handle;
    @panic("exports_flix_runtime_runtime_ctx_rep: WIT glue unavailable (native build)");
}

fn exports_flix_runtime_runtime_ctx_drop_own(handle: exports_flix_runtime_runtime_own_ctx_t) callconv(.c) void {
    _ = handle;
}

fn exports_flix_runtime_runtime_value_new(rep: *exports_flix_runtime_runtime_value_t) callconv(.c) exports_flix_runtime_runtime_own_value_t {
    _ = rep;
    @panic("exports_flix_runtime_runtime_value_new: WIT glue unavailable (native build)");
}

fn exports_flix_runtime_runtime_value_rep(handle: exports_flix_runtime_runtime_own_value_t) callconv(.c) *exports_flix_runtime_runtime_value_t {
    _ = handle;
    @panic("exports_flix_runtime_runtime_value_rep: WIT glue unavailable (native build)");
}

fn exports_flix_runtime_runtime_value_drop_own(handle: exports_flix_runtime_runtime_own_value_t) callconv(.c) void {
    _ = handle;
}

fn exports_flix_runtime_runtime_suspension_new(rep: *exports_flix_runtime_runtime_suspension_t) callconv(.c) exports_flix_runtime_runtime_own_suspension_t {
    _ = rep;
    @panic("exports_flix_runtime_runtime_suspension_new: WIT glue unavailable (native build)");
}

fn exports_flix_runtime_runtime_suspension_rep(handle: exports_flix_runtime_runtime_own_suspension_t) callconv(.c) *exports_flix_runtime_runtime_suspension_t {
    _ = handle;
    @panic("exports_flix_runtime_runtime_suspension_rep: WIT glue unavailable (native build)");
}

fn exports_flix_runtime_runtime_suspension_drop_own(handle: exports_flix_runtime_runtime_own_suspension_t) callconv(.c) void {
    _ = handle;
}

comptime {
    // Export the stubs with weak linkage so wasm builds can override them with the real glue.
    @export(&exports_flix_runtime_runtime_ctx_new, .{ .name = "exports_flix_runtime_runtime_ctx_new", .linkage = .weak });
    @export(&exports_flix_runtime_runtime_ctx_rep, .{ .name = "exports_flix_runtime_runtime_ctx_rep", .linkage = .weak });
    @export(&exports_flix_runtime_runtime_ctx_drop_own, .{ .name = "exports_flix_runtime_runtime_ctx_drop_own", .linkage = .weak });

    @export(&exports_flix_runtime_runtime_value_new, .{ .name = "exports_flix_runtime_runtime_value_new", .linkage = .weak });
    @export(&exports_flix_runtime_runtime_value_rep, .{ .name = "exports_flix_runtime_runtime_value_rep", .linkage = .weak });
    @export(&exports_flix_runtime_runtime_value_drop_own, .{ .name = "exports_flix_runtime_runtime_value_drop_own", .linkage = .weak });

    @export(&exports_flix_runtime_runtime_suspension_new, .{ .name = "exports_flix_runtime_runtime_suspension_new", .linkage = .weak });
    @export(&exports_flix_runtime_runtime_suspension_rep, .{ .name = "exports_flix_runtime_runtime_suspension_rep", .linkage = .weak });
    @export(&exports_flix_runtime_runtime_suspension_drop_own, .{ .name = "exports_flix_runtime_runtime_suspension_drop_own", .linkage = .weak });
}

// Module functions emitted by the LLVM backend for the wasm target.
extern fn flix_wasm_invoke_def(ctx: *anyopaque, def_id: i64, args: [*]i64, argc: i32) callconv(.c) FlixResult;
extern fn flix_wasm_resume_ok_def(ctx: *anyopaque, def_id: i64, susp_handle: i64, resume_handle: i64) callconv(.c) FlixResult;
extern fn flix_wasm_resume_throw_def(ctx: *anyopaque, def_id: i64, susp_handle: i64, exn_handle: i64) callconv(.c) FlixResult;

const WasmIoEffSymId: i64 = 0;

const TaskKind = union(enum) {
    Def: i64,
    /// Handle id for a thunk/closure pointer (must be a `.Ptr` handle).
    Thunk: i64,
};

const Task = struct {
    kind: TaskKind,
    args: std.ArrayListUnmanaged(i64),
    state: TaskState,
    region: ?*FlixRegion,
    host_visible: bool,
};

const TaskState = union(enum) {
    ReadyStart: void,
    ReadyResumeOk: struct { susp_handle: i64, resume_handle: i64 },
    ReadyResumeThrow: struct { susp_handle: i64, exn_handle: i64 },
    Blocked: struct { susp_handle: i64 },
    Completed: struct { tag: u8, handle: i64, consumed: bool },
};

threadlocal var current_wit_ctx: ?*exports_flix_runtime_runtime_ctx_t = null;

fn witSetCurrentCtx(ctx_rep: *exports_flix_runtime_runtime_ctx_t) void {
    // Ensure threadlocals used by the runtime point at the correct context for this call.
    current_ctx = @ptrCast(@alignCast(ctx_rep.flix_ctx));
    current_wit_ctx = ctx_rep;
}

fn witBytesToOwned(buf: []const u8) flix_list_u8_t {
    // Canonical ABI post-return frees only if `len > 0`, but Zig's `[*]T` pointers are non-null.
    // For empty lists we can return any non-null, non-dereferenced pointer.
    if (buf.len == 0) return .{ .ptr = @ptrFromInt(1), .len = 0 };
    const mem = c.malloc(buf.len) orelse @panic("malloc failed");
    const out: [*]u8 = @ptrCast(mem);
    std.mem.copyForwards(u8, out[0..buf.len], buf);
    return .{ .ptr = out, .len = buf.len };
}

fn witStringClone(bytes: []const u8) flix_string_t {
    // Canonical ABI post-return frees only if `len > 0`, but Zig's `[*]T` pointers are non-null.
    // For empty strings we can return any non-null, non-dereferenced pointer.
    if (bytes.len == 0) return .{ .ptr = @ptrFromInt(1), .len = 0 };
    const mem = c.malloc(bytes.len) orelse @panic("malloc failed");
    const out: [*]u8 = @ptrCast(mem);
    std.mem.copyForwards(u8, out[0..bytes.len], bytes);
    return .{ .ptr = out, .len = bytes.len };
}

fn witStringFromFlixString(str_ptr: *anyopaque) flix_string_t {
    const bytes = flixStringToUtf8Alloc(rt_alloc, str_ptr);
    defer rt_alloc.free(bytes);
    return witStringClone(bytes);
}

fn flixStringFromWit(s: *const flix_string_t) *anyopaque {
    const n: usize = s.len;
    if (n == 0) return allocFlixStringFromAscii("");
    const slice = s.ptr[0..n];
    return allocFlixStringFromUtf8Lossy(slice);
}

fn witEmptyString() flix_string_t {
    // See `witStringClone` for why we use a non-null dummy pointer for empty strings.
    return .{ .ptr = @ptrFromInt(1), .len = 0 };
}

fn witOptionStringNone() flix_option_string_t {
    return .{ .is_some = false, .val = witEmptyString() };
}

fn witOptionStringSomeFromFlixString(str_ptr: *anyopaque) flix_option_string_t {
    return .{ .is_some = true, .val = witStringFromFlixString(str_ptr) };
}

fn witAllocArray(comptime T: type, n: usize) [*]T {
    // Canonical ABI post-return frees only if `len > 0`, but Zig's `[*]T` pointers are non-null.
    // For empty lists we can return any non-null pointer (never dereferenced nor freed).
    if (n == 0) return @ptrFromInt(@as(usize, @alignOf(T)));
    const mem = c.malloc(n * @sizeOf(T)) orelse @panic("malloc failed");
    return @ptrCast(@alignCast(mem));
}

fn witBuildHeadersFromPairs(req_pairs_ptr: *anyopaque) exports_flix_runtime_runtime_list_http_header_t {
    // Flix headers are `Array[String]` with alternating key/value entries.
    const len: usize = flixArrayLen(req_pairs_ptr);
    const slots: [*]i64 = flixArraySlots(req_pairs_ptr);
    const n_pairs: usize = len / 2;

    const arr_ptr = witAllocArray(exports_flix_runtime_runtime_http_header_t, n_pairs);
    var i: usize = 0;
    while (i < n_pairs) : (i += 1) {
        const k_ptr = ptrFromPayload(slots[i * 2]);
        const v_ptr = ptrFromPayload(slots[i * 2 + 1]);
        arr_ptr[i] = .{
            .name = witStringFromFlixString(k_ptr),
            .value = witStringFromFlixString(v_ptr),
        };
    }
    return .{ .ptr = arr_ptr, .len = n_pairs };
}

fn witBuildStringListFromFlixStringArray(arr_ptr0: *anyopaque) flix_list_string_t {
    const len: usize = flixArrayLen(arr_ptr0);
    const slots: [*]i64 = flixArraySlots(arr_ptr0);
    const out_ptr = witAllocArray(flix_string_t, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const s_ptr = ptrFromPayload(slots[i]);
        out_ptr[i] = witStringFromFlixString(s_ptr);
    }
    return .{ .ptr = out_ptr, .len = len };
}

fn witBuildEnvListFromPairs(pairs_ptr: *anyopaque) exports_flix_runtime_runtime_list_process_env_var_t {
    const len: usize = flixArrayLen(pairs_ptr);
    const slots: [*]i64 = flixArraySlots(pairs_ptr);
    const n_pairs: usize = len / 2;

    const out_ptr = witAllocArray(exports_flix_runtime_runtime_process_env_var_t, n_pairs);
    var i: usize = 0;
    while (i < n_pairs) : (i += 1) {
        const k_ptr = ptrFromPayload(slots[i * 2]);
        const v_ptr = ptrFromPayload(slots[i * 2 + 1]);
        out_ptr[i] = .{
            .key = witStringFromFlixString(k_ptr),
            .value = witStringFromFlixString(v_ptr),
        };
    }
    return .{ .ptr = out_ptr, .len = n_pairs };
}

fn witReqUnknown(eff_id: i64, op_id: i64) exports_flix_runtime_runtime_op_request_t {
    return .{
        .tag = 45, // `unknown`
        .val = .{ .unknown = .{ .eff_id = @intCast(eff_id), .op_id = @intCast(op_id) } },
    };
}

fn taskQueuePush(ctx_rep: *exports_flix_runtime_runtime_ctx_t, task_id: u64) void {
    ctx_rep.ready.append(rt_alloc, task_id) catch @panic("oom");
}

fn taskQueuePop(ctx_rep: *exports_flix_runtime_runtime_ctx_t) ?u64 {
    if (ctx_rep.ready_head >= ctx_rep.ready.items.len) return null;
    const id = ctx_rep.ready.items[ctx_rep.ready_head];
    ctx_rep.ready_head += 1;

    // Occasional compaction.
    if (ctx_rep.ready_head > 1024 and ctx_rep.ready_head * 2 > ctx_rep.ready.items.len) {
        const rem = ctx_rep.ready.items.len - ctx_rep.ready_head;
        std.mem.copyForwards(u64, ctx_rep.ready.items[0..rem], ctx_rep.ready.items[ctx_rep.ready_head..]);
        ctx_rep.ready.items.len = rem;
        ctx_rep.ready_head = 0;
    }

    return id;
}

fn taskReleaseArgs(ctx_ptr: *anyopaque, t: *Task) void {
    for (t.args.items) |h| flix_handle_release(ctx_ptr, h);
    t.args.deinit(rt_alloc);
    t.args = .{};
}

fn taskMarkCompleted(ctx_rep: *exports_flix_runtime_runtime_ctx_t, t: *Task, tag: u8, handle: i64) void {
    // Task no longer needs its original arguments.
    taskReleaseArgs(ctx_rep.flix_ctx, t);
    // If the task was started from a thunk handle, release it now that we are completed.
    switch (t.kind) {
        .Thunk => |th| {
            flix_handle_release(ctx_rep.flix_ctx, th);
            t.kind = .{ .Thunk = 0 };
        },
        else => {},
    }
    // Region-attached tasks propagate their exception to the region (child exception precedence)
    // and request cooperative cancellation.
    if (tag == 1) {
        if (t.region) |region| {
            const exn_ptr = flix_handle_get(ctx_rep.flix_ctx, handle);
            const fctx: *FlixCtx = requireCtx(ctx_rep.flix_ctx);
            const is_cancel = if (fctx.cancel_exn) |p| p == exn_ptr else false;

            if (!is_cancel) {
                // First exception wins.
                region.mutex.lock();
                if (region.child_exn == null) {
                    region.child_exn = exn_ptr;
                }
                // Request cooperative cancellation for siblings and parent.
                const cause_ptr = region.child_exn orelse exn_ptr;
                if (region.cancel_cause == null) region.cancel_cause = cause_ptr;
                region.cancel_requested.store(true, .release);
                region.mutex.unlock();
            }
        }
    }
    t.state = .{ .Completed = .{ .tag = tag, .handle = handle, .consumed = false } };
}

fn allocTimerSleepSuspension(ms: u64) *anyopaque {
    const slots_total: usize = 6;
    const size_bytes: usize = @sizeOf(FlixObj) + slots_total * @sizeOf(i64);
    const mem = gcAllocBytes(size_bytes, &flix_ti_suspension);
    const slots: [*]i64 = objPayloadSlots(mem);

    slots[0] = WasmIoEffSymId;
    slots[1] = 1; // timer-sleep
    slots[2] = 0; // prefix frames (filled in by codegen when returning the suspension)
    slots[3] = 0; // resumption chain (not used for simple yields)
    slots[4] = 1; // arg count
    slots[5] = @intCast(ms);
    return mem;
}

fn taskMakeSuspensionForHost(ctx_rep: *exports_flix_runtime_runtime_ctx_t, task_id: u64, susp_handle: i64) exports_flix_runtime_runtime_own_suspension_t {
    // Retain for the host resource; the task keeps its own reference.
    flix_handle_retain(ctx_rep.flix_ctx, susp_handle);
    const rep = rt_alloc.create(exports_flix_runtime_runtime_suspension_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx_rep.flix_ctx, .task_id = task_id, .susp_handle = susp_handle };
    return exports_flix_runtime_runtime_suspension_new(rep);
}

fn taskHandleSuspension(ctx_rep: *exports_flix_runtime_runtime_ctx_t, task_id: u64, susp_handle: i64) ?exports_flix_runtime_runtime_own_suspension_t {
    const susp_ptr = flix_handle_get(ctx_rep.flix_ctx, susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    if (slots[0] == WasmChanEffSymId) {
        const op_index: i64 = slots[1];
        if (op_index == WasmChanOpGet or op_index == WasmChanOpPut) {
            wasmChannelRegisterWaiter(ctx_rep, task_id, susp_handle);
            return null;
        }
    }
    return taskMakeSuspensionForHost(ctx_rep, task_id, susp_handle);
}

fn withTaskRegion(task: *Task, f: fn () void) void {
    const saved = current_region;
    current_region = task.region;
    defer current_region = saved;
    f();
    task.region = current_region;
}

fn runTaskOnce(ctx_rep: *exports_flix_runtime_runtime_ctx_t, task_id: u64, t: *Task) ?exports_flix_runtime_runtime_own_suspension_t {
    witSetCurrentCtx(ctx_rep);

    const saved_region = current_region;
    current_region = t.region;
    defer {
        t.region = current_region;
        current_region = saved_region;
    }

    switch (t.state) {
        .ReadyStart => {
            switch (t.kind) {
                .Def => |def_id| {
                    // Prepare argv bits for the def dispatcher.
                    const argc: usize = t.args.items.len;
                    const arg_bits = rt_alloc.alloc(i64, argc) catch @panic("oom");
                    defer rt_alloc.free(arg_bits);
                    var i: usize = 0;
                    while (i < argc) : (i += 1) {
                        arg_bits[i] = flix_handle_payload(ctx_rep.flix_ctx, t.args.items[i]);
                    }

                    const r = flix_wasm_invoke_def(ctx_rep.flix_ctx, def_id, arg_bits.ptr, @intCast(argc));
                    switch (r.tag) {
                        RESULT_TAG_VALUE => {
                            taskMarkCompleted(ctx_rep, t, 0, r.payload);
                            return null;
                        },
                        RESULT_TAG_EXCEPTION => {
                            taskMarkCompleted(ctx_rep, t, 1, r.payload);
                            return null;
                        },
                        RESULT_TAG_SUSPENSION => {
                            // Task owns this suspension handle.
                            taskReleaseArgs(ctx_rep.flix_ctx, t);
                            t.state = .{ .Blocked = .{ .susp_handle = r.payload } };
                            return taskHandleSuspension(ctx_rep, task_id, r.payload);
                        },
                        else => @panic("unexpected result tag from flix_wasm_invoke_def"),
                    }
                },

                .Thunk => |thunk_handle| {
                    if (thunk_handle == 0) @panic("runTaskOnce: thunk task has null thunk handle");
                    const thunk_ptr = flix_handle_get(ctx_rep.flix_ctx, thunk_handle);

                    // Invoke the thunk and unwind to a stable non-thunk result.
                    var r0 = invokeThunk(ctx_rep.flix_ctx, thunk_ptr, 0);
                    while (r0.tag == RESULT_TAG_THUNK) {
                        const tptr = ptrFromPayload(r0.payload);
                        r0 = invokeThunk(ctx_rep.flix_ctx, tptr, 0);
                    }

                    switch (r0.tag) {
                        RESULT_TAG_VALUE => {
                            const h = flix_handle_new_i64(ctx_rep.flix_ctx, r0.payload);
                            taskMarkCompleted(ctx_rep, t, 0, h);
                            return null;
                        },
                        RESULT_TAG_EXCEPTION => {
                            const exn_ptr = ptrFromPayload(r0.payload);
                            const h = flix_handle_new(ctx_rep.flix_ctx, exn_ptr);
                            taskMarkCompleted(ctx_rep, t, 1, h);
                            return null;
                        },
                        RESULT_TAG_SUSPENSION => {
                            const susp_ptr = ptrFromPayload(r0.payload);
                            const h = flix_handle_new(ctx_rep.flix_ctx, susp_ptr);
                            t.state = .{ .Blocked = .{ .susp_handle = h } };
                            return taskHandleSuspension(ctx_rep, task_id, h);
                        },
                        else => @panic("unexpected result tag from thunk invocation"),
                    }
                },
            }
        },

        .ReadyResumeOk => |st| {
            const def_id: i64 = switch (t.kind) {
                .Def => |d| d,
                else => 0,
            };
            const r = flix_wasm_resume_ok_def(ctx_rep.flix_ctx, def_id, st.susp_handle, st.resume_handle);
            flix_handle_release(ctx_rep.flix_ctx, st.susp_handle);
            flix_handle_release(ctx_rep.flix_ctx, st.resume_handle);

            switch (r.tag) {
                RESULT_TAG_VALUE => {
                    taskMarkCompleted(ctx_rep, t, 0, r.payload);
                    return null;
                },
                RESULT_TAG_EXCEPTION => {
                    taskMarkCompleted(ctx_rep, t, 1, r.payload);
                    return null;
                },
                RESULT_TAG_SUSPENSION => {
                    t.state = .{ .Blocked = .{ .susp_handle = r.payload } };
                    return taskHandleSuspension(ctx_rep, task_id, r.payload);
                },
                else => @panic("unexpected result tag from flix_wasm_resume_ok_def"),
            }
        },

        .ReadyResumeThrow => |st| {
            const def_id: i64 = switch (t.kind) {
                .Def => |d| d,
                else => 0,
            };
            const r = flix_wasm_resume_throw_def(ctx_rep.flix_ctx, def_id, st.susp_handle, st.exn_handle);
            flix_handle_release(ctx_rep.flix_ctx, st.susp_handle);
            flix_handle_release(ctx_rep.flix_ctx, st.exn_handle);

            switch (r.tag) {
                RESULT_TAG_VALUE => {
                    taskMarkCompleted(ctx_rep, t, 0, r.payload);
                    return null;
                },
                RESULT_TAG_EXCEPTION => {
                    taskMarkCompleted(ctx_rep, t, 1, r.payload);
                    return null;
                },
                RESULT_TAG_SUSPENSION => {
                    t.state = .{ .Blocked = .{ .susp_handle = r.payload } };
                    return taskHandleSuspension(ctx_rep, task_id, r.payload);
                },
                else => @panic("unexpected result tag from flix_wasm_resume_throw_def"),
            }
        },

        else => return null,
    }
}

fn resumeTaskWithHandle(ctx_rep: *exports_flix_runtime_runtime_ctx_t, susp: exports_flix_runtime_runtime_own_suspension_t, resume_handle: i64, is_throw: bool) void {
    witSetCurrentCtx(ctx_rep);

    const srep = exports_flix_runtime_runtime_suspension_rep(susp);
    const task_id = srep.task_id;
    const susp_handle = srep.susp_handle;

    const task_ptr = ctx_rep.tasks.getPtr(task_id) orelse @panic("resume on unknown task-id");

    // Ensure task is blocked (best-effort sanity).
    switch (task_ptr.state) {
        .Blocked => |st| {
            if (st.susp_handle != susp_handle) @panic("resume suspension mismatch");
        },
        else => @panic("resume on non-blocked task"),
    }

    // Move to ready state and enqueue.
    if (is_throw) {
        task_ptr.state = .{ .ReadyResumeThrow = .{ .susp_handle = susp_handle, .exn_handle = resume_handle } };
    } else {
        task_ptr.state = .{ .ReadyResumeOk = .{ .susp_handle = susp_handle, .resume_handle = resume_handle } };
    }
    taskQueuePush(ctx_rep, task_id);

    // Consume the WIT resource handle; destructor releases the host retain.
    exports_flix_runtime_runtime_suspension_drop_own(susp);
}

fn resumeTaskWithHandleSync(ctx_rep: *exports_flix_runtime_runtime_ctx_t, susp: exports_flix_runtime_runtime_own_suspension_t, resume_handle: i64, is_throw: bool, ret: *exports_flix_runtime_runtime_exec_t) void {
    witSetCurrentCtx(ctx_rep);

    const srep = exports_flix_runtime_runtime_suspension_rep(susp);
    const task_id = srep.task_id;
    const susp_handle = srep.susp_handle;

    const task_ptr = ctx_rep.tasks.getPtr(task_id) orelse @panic("resume-sync on unknown task-id");

    switch (task_ptr.state) {
        .Blocked => |st| {
            if (st.susp_handle != susp_handle) @panic("resume-sync suspension mismatch");
        },
        else => @panic("resume-sync on non-blocked task"),
    }

    if (is_throw) {
        task_ptr.state = .{ .ReadyResumeThrow = .{ .susp_handle = susp_handle, .exn_handle = resume_handle } };
    } else {
        task_ptr.state = .{ .ReadyResumeOk = .{ .susp_handle = susp_handle, .resume_handle = resume_handle } };
    }

    // Consume the old suspension resource before resuming.
    exports_flix_runtime_runtime_suspension_drop_own(susp);

    if (runTaskOnce(ctx_rep, task_id, task_ptr)) |own_susp| {
        ret.* = .{
            .tag = 2,
            .val = .{ .suspended = .{ .task = task_id, .suspension = own_susp } },
        };
        return;
    }

    switch (task_ptr.state) {
        .Completed => |st| {
            const own_v = makeOwnRuntimeValue(ctx_rep, st.handle);
            if (st.tag == 0) {
                ret.* = .{ .tag = 0, .val = .{ .ok = own_v } };
            } else {
                ret.* = .{ .tag = 1, .val = .{ .thrown = own_v } };
            }
            _ = ctx_rep.tasks.remove(task_id);
        },
        else => @panic("resume-sync: unexpected task state"),
    }
}

fn makeIoTuple2(ok: bool, msg: *anyopaque) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(ok), payloadFromPtr(msg) }, 0b10);
}

fn makeIoTuple3Bool(ok: bool, x: i64, msg: *anyopaque) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(ok), x, payloadFromPtr(msg) }, 0b100);
}

fn makeIoTuple4Bool(ok: bool, x: i64, kind: i64, msg: *anyopaque) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(ok), x, kind, payloadFromPtr(msg) }, 0b1000);
}

fn makeIoTuple4Ptr(ok: bool, x_ptr: *anyopaque, kind: i64, msg: *anyopaque) *anyopaque {
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(ok), payloadFromPtr(x_ptr), kind, payloadFromPtr(msg) }, 0b1010);
}

fn makeHttpTuple(ok: bool, status: i64, resp_pairs_ptr: *anyopaque, resp_body_ptr: *anyopaque, kind: i64, msg_ptr: *anyopaque) *anyopaque {
    return allocFlixTupleFromPayloads(&.{
        payloadFromBool(ok),
        status,
        payloadFromPtr(resp_pairs_ptr),
        payloadFromPtr(resp_body_ptr),
        kind,
        payloadFromPtr(msg_ptr),
    }, 0b101100);
}

fn makeHandleForPtr(ctx_ptr: *anyopaque, ptr: *anyopaque) i64 {
    return flix_handle_new(ctx_ptr, ptr);
}

fn makeHandleForI64(ctx_ptr: *anyopaque, payload: i64) i64 {
    return flix_handle_new_i64(ctx_ptr, payload);
}

fn makeOwnRuntimeValue(ctx_rep: *exports_flix_runtime_runtime_ctx_t, handle: i64) exports_flix_runtime_runtime_own_value_t {
    const rep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx_rep.flix_ctx, .handle = handle };
    return exports_flix_runtime_runtime_value_new(rep);
}

fn suspensionArgCountRaw(s: exports_flix_runtime_runtime_borrow_suspension_t) usize {
    const susp_ptr = flix_handle_get(s.flix_ctx, s.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const arg_count_i64: i64 = slots[4];
    if (arg_count_i64 < 0) @panic("invalid suspension argCount");
    return @intCast(arg_count_i64);
}

fn suspensionArgBits(s: exports_flix_runtime_runtime_borrow_suspension_t, idx0: u32) i64 {
    const idx: usize = @intCast(idx0);
    const arg_count = suspensionArgCountRaw(s);
    if (idx >= arg_count) @panic("suspension arg index out of bounds");

    const susp_ptr = flix_handle_get(s.flix_ctx, s.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    return slots[5 + idx];
}

fn witScalarBits(v: exports_flix_runtime_runtime_borrow_value_t, comptime ptr_unbox: fn (i64) callconv(.c) i64) i64 {
    const ctx: *FlixCtx = requireCtx(v.flix_ctx);
    ctx.handles_mutex.lock();
    defer ctx.handles_mutex.unlock();

    const entry = ctx.handles.get(v.handle) orelse @panic("invalid flix handle");
    return switch (entry.kind) {
        .I64 => entry.payload,
        .Ptr => ptr_unbox(entry.payload),
    };
}

// Exported Functions from `flix:runtime/runtime@0.1.0`
export fn exports_flix_runtime_runtime_new_ctx() exports_flix_runtime_runtime_own_ctx_t {
    if (!is_wasm) @panic("exports_flix_runtime_runtime_new_ctx: wasm-only");

    const rep = rt_alloc.create(exports_flix_runtime_runtime_ctx_t) catch @panic("oom");
    const flix_ctx_ptr = flix_ctx_new();

    rep.* = .{
        .flix_ctx = flix_ctx_ptr,
        .next_task_id = 1,
        .tasks = .{},
        .ready = .{},
        .ready_head = 0,
    };
    // Avoid reallocations in the ready queue for typical use.
    rep.ready.ensureTotalCapacity(rt_alloc, 1024) catch @panic("oom");

    witSetCurrentCtx(rep);
    return exports_flix_runtime_runtime_ctx_new(rep);
}

export fn exports_flix_runtime_runtime_ctx_destructor(rep: *exports_flix_runtime_runtime_ctx_t) void {
    if (!is_wasm) return;

    witSetCurrentCtx(rep);

    // Best-effort: release all task-owned handles.
    var it = rep.tasks.iterator();
    while (it.next()) |e| {
        var t = e.value_ptr.*;
        taskReleaseArgs(rep.flix_ctx, &t);
        switch (t.kind) {
            .Thunk => |th| if (th != 0) flix_handle_release(rep.flix_ctx, th),
            else => {},
        }
        switch (t.state) {
            .Blocked => |st| flix_handle_release(rep.flix_ctx, st.susp_handle),
            .ReadyResumeOk => |st| {
                flix_handle_release(rep.flix_ctx, st.susp_handle);
                flix_handle_release(rep.flix_ctx, st.resume_handle);
            },
            .ReadyResumeThrow => |st| {
                flix_handle_release(rep.flix_ctx, st.susp_handle);
                flix_handle_release(rep.flix_ctx, st.exn_handle);
            },
            .Completed => |st| if (!st.consumed) flix_handle_release(rep.flix_ctx, st.handle),
            else => {},
        }
    }
    rep.tasks.deinit(rt_alloc);
    rep.ready.deinit(rt_alloc);

    flix_ctx_free(rep.flix_ctx);
    rt_alloc.destroy(rep);
}

export fn exports_flix_runtime_runtime_value_destructor(rep: *exports_flix_runtime_runtime_value_t) void {
    if (!is_wasm) return;
    flix_handle_release(rep.flix_ctx, rep.handle);
    rt_alloc.destroy(rep);
}

export fn exports_flix_runtime_runtime_suspension_destructor(rep: *exports_flix_runtime_runtime_suspension_t) void {
    if (!is_wasm) return;
    flix_handle_release(rep.flix_ctx, rep.susp_handle);
    rt_alloc.destroy(rep);
}

export fn exports_flix_runtime_runtime_box_i8(ctx: exports_flix_runtime_runtime_borrow_ctx_t, x: i8) exports_flix_runtime_runtime_own_value_t {
    if (!is_wasm) @panic("box-i8: wasm-only");
    witSetCurrentCtx(ctx);

    const h = makeHandleForI64(ctx.flix_ctx, @as(i64, x));
    const rep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = h };
    return exports_flix_runtime_runtime_value_new(rep);
}

export fn exports_flix_runtime_runtime_unbox_i8(ctx: exports_flix_runtime_runtime_borrow_ctx_t, v: exports_flix_runtime_runtime_borrow_value_t) i8 {
    _ = ctx;
    const bits = witScalarBits(v, flix_unbox_int8);
    return @intCast(@as(i8, @truncate(bits)));
}

export fn exports_flix_runtime_runtime_box_i16(ctx: exports_flix_runtime_runtime_borrow_ctx_t, x: i16) exports_flix_runtime_runtime_own_value_t {
    if (!is_wasm) @panic("box-i16: wasm-only");
    witSetCurrentCtx(ctx);

    const h = makeHandleForI64(ctx.flix_ctx, @as(i64, x));
    const rep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = h };
    return exports_flix_runtime_runtime_value_new(rep);
}

export fn exports_flix_runtime_runtime_unbox_i16(ctx: exports_flix_runtime_runtime_borrow_ctx_t, v: exports_flix_runtime_runtime_borrow_value_t) i16 {
    _ = ctx;
    const bits = witScalarBits(v, flix_unbox_int16);
    return @intCast(@as(i16, @truncate(bits)));
}

export fn exports_flix_runtime_runtime_box_i32(ctx: exports_flix_runtime_runtime_borrow_ctx_t, x: i32) exports_flix_runtime_runtime_own_value_t {
    if (!is_wasm) @panic("box-i32: wasm-only");
    witSetCurrentCtx(ctx);

    const h = makeHandleForI64(ctx.flix_ctx, @as(i64, x));
    const rep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = h };
    return exports_flix_runtime_runtime_value_new(rep);
}

export fn exports_flix_runtime_runtime_unbox_i32(ctx: exports_flix_runtime_runtime_borrow_ctx_t, v: exports_flix_runtime_runtime_borrow_value_t) i32 {
    _ = ctx;
    const bits = witScalarBits(v, flix_unbox_int32);
    return @intCast(@as(i32, @truncate(bits)));
}

export fn exports_flix_runtime_runtime_box_i64(ctx: exports_flix_runtime_runtime_borrow_ctx_t, x: i64) exports_flix_runtime_runtime_own_value_t {
    if (!is_wasm) @panic("box-i64: wasm-only");
    witSetCurrentCtx(ctx);

    const h = makeHandleForI64(ctx.flix_ctx, x);
    const rep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = h };
    return exports_flix_runtime_runtime_value_new(rep);
}

export fn exports_flix_runtime_runtime_unbox_i64(ctx: exports_flix_runtime_runtime_borrow_ctx_t, v: exports_flix_runtime_runtime_borrow_value_t) i64 {
    _ = ctx;
    return witScalarBits(v, flix_unbox_int64);
}

export fn exports_flix_runtime_runtime_box_f32(ctx: exports_flix_runtime_runtime_borrow_ctx_t, x: f32) exports_flix_runtime_runtime_own_value_t {
    if (!is_wasm) @panic("box-f32: wasm-only");
    witSetCurrentCtx(ctx);

    const bits_u32: u32 = @bitCast(x);
    const h = makeHandleForI64(ctx.flix_ctx, @as(i64, bits_u32));
    const rep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = h };
    return exports_flix_runtime_runtime_value_new(rep);
}

export fn exports_flix_runtime_runtime_unbox_f32(ctx: exports_flix_runtime_runtime_borrow_ctx_t, v: exports_flix_runtime_runtime_borrow_value_t) f32 {
    _ = ctx;
    const bits = witScalarBits(v, flix_unbox_float32);
    const bits_u32: u32 = @truncate(@as(u64, @bitCast(bits)));
    return @bitCast(bits_u32);
}

export fn exports_flix_runtime_runtime_box_f64(ctx: exports_flix_runtime_runtime_borrow_ctx_t, x: f64) exports_flix_runtime_runtime_own_value_t {
    if (!is_wasm) @panic("box-f64: wasm-only");
    witSetCurrentCtx(ctx);

    const bits_i64: i64 = @bitCast(x);
    const h = makeHandleForI64(ctx.flix_ctx, bits_i64);
    const rep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = h };
    return exports_flix_runtime_runtime_value_new(rep);
}

export fn exports_flix_runtime_runtime_unbox_f64(ctx: exports_flix_runtime_runtime_borrow_ctx_t, v: exports_flix_runtime_runtime_borrow_value_t) f64 {
    _ = ctx;
    const bits = witScalarBits(v, flix_unbox_float64);
    return @bitCast(bits);
}

export fn exports_flix_runtime_runtime_box_bool(ctx: exports_flix_runtime_runtime_borrow_ctx_t, b: bool) exports_flix_runtime_runtime_own_value_t {
    if (!is_wasm) @panic("box-bool: wasm-only");
    witSetCurrentCtx(ctx);

    const h = makeHandleForI64(ctx.flix_ctx, if (b) 1 else 0);
    const rep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = h };
    return exports_flix_runtime_runtime_value_new(rep);
}

export fn exports_flix_runtime_runtime_unbox_bool(ctx: exports_flix_runtime_runtime_borrow_ctx_t, v: exports_flix_runtime_runtime_borrow_value_t) bool {
    _ = ctx;
    const bits = witScalarBits(v, flix_unbox_bool);
    return bits != 0;
}

export fn exports_flix_runtime_runtime_box_string(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: *flix_string_t) exports_flix_runtime_runtime_own_value_t {
    if (!is_wasm) @panic("box-string: wasm-only");
    witSetCurrentCtx(ctx);

    const str_ptr = flixStringFromWit(s);
    const h = makeHandleForPtr(ctx.flix_ctx, str_ptr);
    const rep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = h };
    return exports_flix_runtime_runtime_value_new(rep);
}

export fn exports_flix_runtime_runtime_unbox_string(ctx: exports_flix_runtime_runtime_borrow_ctx_t, v: exports_flix_runtime_runtime_borrow_value_t, ret: *flix_string_t) void {
    _ = ctx;
    const bits = flix_handle_payload(v.flix_ctx, v.handle);
    const str_ptr = ptrFromPayload(bits);
    ret.* = witStringFromFlixString(str_ptr);
}

export fn exports_flix_runtime_runtime_box_bytes(ctx: exports_flix_runtime_runtime_borrow_ctx_t, bytes: *flix_list_u8_t) exports_flix_runtime_runtime_own_value_t {
    if (!is_wasm) @panic("box-bytes: wasm-only");
    witSetCurrentCtx(ctx);

    const slice = bytes.ptr[0..bytes.len];
    const arr_ptr = allocFlixInt8ArrayFromBytes(slice);
    const h = makeHandleForPtr(ctx.flix_ctx, arr_ptr);
    const rep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
    rep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = h };
    return exports_flix_runtime_runtime_value_new(rep);
}

export fn exports_flix_runtime_runtime_unbox_bytes(ctx: exports_flix_runtime_runtime_borrow_ctx_t, v: exports_flix_runtime_runtime_borrow_value_t, ret: *flix_list_u8_t) void {
    _ = ctx;
    const bits = flix_handle_payload(v.flix_ctx, v.handle);
    const arr_ptr = ptrFromPayload(bits);
    ret.* = witBytesToOwned(flixInt8ArrayBytesView(arr_ptr));
}

export fn exports_flix_runtime_runtime_start_task(ctx: exports_flix_runtime_runtime_borrow_ctx_t, def_id: exports_flix_runtime_runtime_def_id_t, args: *exports_flix_runtime_runtime_list_borrow_value_t) exports_flix_runtime_runtime_task_id_t {
    if (!is_wasm) @panic("start-task: wasm-only");
    witSetCurrentCtx(ctx);

    const task_id = ctx.next_task_id;
    ctx.next_task_id +%= 1;

    var t: Task = .{
        .kind = .{ .Def = @intCast(def_id) },
        .args = .{},
        .state = .ReadyStart,
        .region = current_region,
        .host_visible = true,
    };
    // Capture args (retain handles so they survive until task runs).
    t.args.ensureTotalCapacity(rt_alloc, args.len) catch @panic("oom");
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const vrep = args.ptr[i];
        flix_handle_retain(ctx.flix_ctx, vrep.handle);
        t.args.appendAssumeCapacity(vrep.handle);
    }

    ctx.tasks.put(rt_alloc, task_id, t) catch @panic("oom");
    taskQueuePush(ctx, task_id);
    return task_id;
}

export fn exports_flix_runtime_runtime_sched_step(ctx: exports_flix_runtime_runtime_borrow_ctx_t, budget: u32, ret: *exports_flix_runtime_runtime_list_own_suspension_t) void {
    if (!is_wasm) @panic("sched-step: wasm-only");
    witSetCurrentCtx(ctx);

    var out = std.ArrayListUnmanaged(exports_flix_runtime_runtime_own_suspension_t){};
    defer out.deinit(rt_alloc);

    var steps: u32 = 0;
    while (steps < budget) : (steps += 1) {
        const task_id = taskQueuePop(ctx) orelse break;
        const tptr = ctx.tasks.getPtr(task_id) orelse continue;

        // Skip tasks that are no longer runnable.
        switch (tptr.state) {
            .ReadyStart, .ReadyResumeOk, .ReadyResumeThrow => {},
            else => continue,
        }

        const own_susp_opt = runTaskOnce(ctx, task_id, tptr);
        if (own_susp_opt) |s| {
            out.append(rt_alloc, s) catch @panic("oom");
        }

        // Auto-cleanup for detached, host-invisible tasks (spawn in Static region).
        //
        // Region-attached tasks are joined and cleaned up by `flix_region_exit`.
        if (!tptr.host_visible and tptr.region == null) {
            switch (tptr.state) {
                .Completed => |st| {
                    if (st.tag == 1) {
                        const exn_ptr = flix_handle_get(ctx.flix_ctx, st.handle);
                        const fctx: *FlixCtx = requireCtx(ctx.flix_ctx);
                        const is_cancel = if (fctx.cancel_exn) |p| p == exn_ptr else false;
                        if (!is_cancel) flix_exn_report_ptr(exn_ptr);
                    }

                    if (!st.consumed) flix_handle_release(ctx.flix_ctx, st.handle);
                    _ = ctx.tasks.remove(task_id);
                },
                else => {},
            }
        }
    }

    // Return as a malloc-owned array (freed by `cabi_post_*`).
    const n: usize = out.items.len;
    const mem_ptr = witAllocArray(exports_flix_runtime_runtime_own_suspension_t, n);
    if (n > 0) {
        std.mem.copyForwards(exports_flix_runtime_runtime_own_suspension_t, mem_ptr[0..n], out.items[0..n]);
    }
    ret.* = .{ .ptr = mem_ptr, .len = n };
}

export fn exports_flix_runtime_runtime_poll_task(ctx: exports_flix_runtime_runtime_borrow_ctx_t, task_id: exports_flix_runtime_runtime_task_id_t, ret: *exports_flix_runtime_runtime_task_outcome_t) bool {
    if (!is_wasm) @panic("poll-task: wasm-only");
    witSetCurrentCtx(ctx);

    const tptr = ctx.tasks.getPtr(task_id) orelse return false;
    switch (tptr.state) {
        .Completed => |st| {
            if (st.consumed) return false;

            // Transfer ownership of the result handle into a value resource.
            const vrep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
            vrep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = st.handle };
            const own_v = exports_flix_runtime_runtime_value_new(vrep);

            if (st.tag == 0) {
                ret.* = .{ .tag = 0, .val = .{ .ok = own_v } };
            } else {
                ret.* = .{ .tag = 1, .val = .{ .thrown = own_v } };
            }

            // Remove task without releasing the transferred handle.
            _ = ctx.tasks.remove(task_id);
            return true;
        },
        else => return false,
    }
}

export fn exports_flix_runtime_runtime_invoke(ctx: exports_flix_runtime_runtime_borrow_ctx_t, def_id: exports_flix_runtime_runtime_def_id_t, args: *exports_flix_runtime_runtime_list_borrow_value_t, ret: *exports_flix_runtime_runtime_exec_t) void {
    if (!is_wasm) @panic("invoke: wasm-only");
    witSetCurrentCtx(ctx);

    // Run a single task step inline. If it suspends, materialize a pollable task-id.
    const task_id = ctx.next_task_id;
    ctx.next_task_id +%= 1;

    var t: Task = .{
        .kind = .{ .Def = @intCast(def_id) },
        .args = .{},
        .state = .ReadyStart,
        .region = current_region,
        .host_visible = true,
    };
    t.args.ensureTotalCapacity(rt_alloc, args.len) catch @panic("oom");
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const vrep = args.ptr[i];
        flix_handle_retain(ctx.flix_ctx, vrep.handle);
        t.args.appendAssumeCapacity(vrep.handle);
    }

    // Insert into task table only if we suspend.
    if (runTaskOnce(ctx, task_id, &t)) |own_susp| {
        ctx.tasks.put(rt_alloc, task_id, t) catch @panic("oom");
        ret.* = .{
            .tag = 2,
            .val = .{ .suspended = .{ .task = task_id, .suspension = own_susp } },
        };
        return;
    }

    // Completed inline; return ok/thrown and drop the ephemeral task.
    switch (t.state) {
        .Completed => |st| {
            const vrep = rt_alloc.create(exports_flix_runtime_runtime_value_t) catch @panic("oom");
            vrep.* = .{ .flix_ctx = ctx.flix_ctx, .handle = st.handle };
            const own_v = exports_flix_runtime_runtime_value_new(vrep);

            if (st.tag == 0) {
                ret.* = .{ .tag = 0, .val = .{ .ok = own_v } };
            } else {
                ret.* = .{ .tag = 1, .val = .{ .thrown = own_v } };
            }
        },
        else => @panic("invoke: unexpected task state"),
    }
}

export fn exports_flix_runtime_runtime_suspension_peek(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_borrow_suspension_t, ret: *exports_flix_runtime_runtime_suspension_info_t) void {
    _ = ctx;
    const susp_ptr = flix_handle_get(s.flix_ctx, s.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    ret.* = .{ .eff_id = @intCast(slots[0]), .op_id = @intCast(slots[1]) };
}

export fn exports_flix_runtime_runtime_suspension_request(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_borrow_suspension_t, ret: *exports_flix_runtime_runtime_op_request_t) void {
    _ = ctx;
    const susp_ptr = flix_handle_get(s.flix_ctx, s.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const eff_sym: i64 = slots[0];
    const op_index: i64 = slots[1];

    if (eff_sym != WasmIoEffSymId or op_index <= 0) {
        ret.* = witReqUnknown(eff_sym, op_index);
        return;
    }

    const op: usize = @intCast(op_index);
    const arg_count: usize = @intCast(slots[4]);
    const args_ptr: [*]const i64 = slots + 5;

    switch (op) {
        1 => { // timer-sleep
            const ms: u64 = @intCast(args_ptr[0]);
            ret.* = .{ .tag = 0, .val = .{ .timer_sleep = .{ .ms = ms } } };
        },
        2 => { // http-request
            if (arg_count != 5) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const method_ptr = ptrFromPayload(args_ptr[0]);
            const url_ptr = ptrFromPayload(args_ptr[1]);
            const headers_arr_ptr = ptrFromPayload(args_ptr[2]);
            const has_body = args_ptr[3] != 0;
            const body_ptr = ptrFromPayload(args_ptr[4]);

            const headers = witBuildHeadersFromPairs(headers_arr_ptr);
            const body_opt = if (has_body) witOptionStringSomeFromFlixString(body_ptr) else witOptionStringNone();

            ret.* = .{
                .tag = 1,
                .val = .{
                    .http_request = .{
                        .method = witStringFromFlixString(method_ptr),
                        .url = witStringFromFlixString(url_ptr),
                        .headers = headers,
                        .body = body_opt,
                    },
                },
            };
        },

        3, 4, 5, 6, 7, 8, 9, // file predicates
        10, 11, 12, 13, // file time/size
        14, // file-read
        22, 23, 24, // truncate/mkdir/mkdirs
        => {
            if (arg_count != 1) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const path_ptr = ptrFromPayload(args_ptr[0]);
            const path = witStringFromFlixString(path_ptr);

            const tag: u8 = @intCast(op - 1);
            // Map to the corresponding request record.
            switch (tag) {
                2 => ret.* = .{ .tag = tag, .val = .{ .file_exists = .{ .path = path } } },
                3 => ret.* = .{ .tag = tag, .val = .{ .file_is_directory = .{ .path = path } } },
                4 => ret.* = .{ .tag = tag, .val = .{ .file_is_regular_file = .{ .path = path } } },
                5 => ret.* = .{ .tag = tag, .val = .{ .file_is_readable = .{ .path = path } } },
                6 => ret.* = .{ .tag = tag, .val = .{ .file_is_symbolic_link = .{ .path = path } } },
                7 => ret.* = .{ .tag = tag, .val = .{ .file_is_writable = .{ .path = path } } },
                8 => ret.* = .{ .tag = tag, .val = .{ .file_is_executable = .{ .path = path } } },
                9 => ret.* = .{ .tag = tag, .val = .{ .file_access_time = .{ .path = path } } },
                10 => ret.* = .{ .tag = tag, .val = .{ .file_creation_time = .{ .path = path } } },
                11 => ret.* = .{ .tag = tag, .val = .{ .file_modification_time = .{ .path = path } } },
                12 => ret.* = .{ .tag = tag, .val = .{ .file_size = .{ .path = path } } },
                13 => ret.* = .{ .tag = tag, .val = .{ .file_read = .{ .path = path } } },
                21 => ret.* = .{ .tag = tag, .val = .{ .file_truncate = .{ .path = path } } },
                22 => ret.* = .{ .tag = tag, .val = .{ .file_mkdir = .{ .path = path } } },
                23 => ret.* = .{ .tag = tag, .val = .{ .file_mkdirs = .{ .path = path } } },
                else => ret.* = witReqUnknown(eff_sym, op_index),
            }
        },

        15, 16, 17 => { // file-read-lines, file-read-bytes, file-list
            if (arg_count != 2) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const path_ptr = ptrFromPayload(args_ptr[1]);
            const path = witStringFromFlixString(path_ptr);
            const tag: u8 = @intCast(op - 1);
            switch (tag) {
                14 => ret.* = .{ .tag = tag, .val = .{ .file_read_lines = .{ .path = path } } },
                15 => ret.* = .{ .tag = tag, .val = .{ .file_read_bytes = .{ .path = path } } },
                16 => ret.* = .{ .tag = tag, .val = .{ .file_list = .{ .path = path } } },
                else => ret.* = witReqUnknown(eff_sym, op_index),
            }
        },

        18, 20 => { // file-write, file-append
            if (arg_count != 2) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const data_ptr = ptrFromPayload(args_ptr[0]);
            const path_ptr = ptrFromPayload(args_ptr[1]);
            const tag: u8 = @intCast(op - 1);
            if (tag == 17) {
                ret.* = .{ .tag = tag, .val = .{ .file_write = .{ .path = witStringFromFlixString(path_ptr), .data = witStringFromFlixString(data_ptr) } } };
            } else {
                ret.* = .{ .tag = tag, .val = .{ .file_append = .{ .path = witStringFromFlixString(path_ptr), .data = witStringFromFlixString(data_ptr) } } };
            }
        },

        19, 21 => { // file-write-bytes, file-append-bytes
            if (arg_count != 2) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const bytes_arr_ptr = ptrFromPayload(args_ptr[0]);
            const path_ptr = ptrFromPayload(args_ptr[1]);
            const bytes = flixInt8ArrayBytesView(bytes_arr_ptr);
            const list_bytes = witBytesToOwned(bytes);
            const tag: u8 = @intCast(op - 1);
            if (tag == 18) {
                ret.* = .{ .tag = tag, .val = .{ .file_write_bytes = .{ .path = witStringFromFlixString(path_ptr), .bytes = list_bytes } } };
            } else {
                ret.* = .{ .tag = tag, .val = .{ .file_append_bytes = .{ .path = witStringFromFlixString(path_ptr), .bytes = list_bytes } } };
            }
        },

        25 => { // file-mk-temp-dir
            if (arg_count != 1) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const prefix_ptr = ptrFromPayload(args_ptr[0]);
            ret.* = .{ .tag = 24, .val = .{ .file_mk_temp_dir = .{ .prefix = witStringFromFlixString(prefix_ptr) } } };
        },

        26 => { // process-exec
            if (arg_count != 4) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }

            const argv_ptr = ptrFromPayload(args_ptr[0]);
            const has_cwd = args_ptr[1] != 0;
            const cwd_ptr = ptrFromPayload(args_ptr[2]);
            const env_pairs_ptr = ptrFromPayload(args_ptr[3]);

            const argv = witBuildStringListFromFlixStringArray(argv_ptr);
            const cwd = if (has_cwd) witOptionStringSomeFromFlixString(cwd_ptr) else witOptionStringNone();
            const env = witBuildEnvListFromPairs(env_pairs_ptr);

            ret.* = .{ .tag = 25, .val = .{ .process_exec = .{ .argv = argv, .cwd = cwd, .env = env } } };
        },

        27, 28, 29, 30, 31, 36 => { // process-id unary ops (exit/is-alive/pid/stop/wait-for/release)
            if (arg_count != 1) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const pid: u64 = @intCast(args_ptr[0]);
            const tag: u8 = @intCast(op - 1);
            switch (tag) {
                26 => ret.* = .{ .tag = tag, .val = .{ .process_exit_value = .{ .process_id = pid } } },
                27 => ret.* = .{ .tag = tag, .val = .{ .process_is_alive = .{ .process_id = pid } } },
                28 => ret.* = .{ .tag = tag, .val = .{ .process_pid = .{ .process_id = pid } } },
                29 => ret.* = .{ .tag = tag, .val = .{ .process_stop = .{ .process_id = pid } } },
                30 => ret.* = .{ .tag = tag, .val = .{ .process_wait_for = .{ .process_id = pid } } },
                35 => ret.* = .{ .tag = tag, .val = .{ .process_release = .{ .process_id = pid } } },
                else => ret.* = witReqUnknown(eff_sym, op_index),
            }
        },

        32 => { // process-wait-for-timeout
            if (arg_count != 2) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const pid: u64 = @intCast(args_ptr[0]);
            const timeout_ms: i64 = args_ptr[1];
            ret.* = .{ .tag = 31, .val = .{ .process_wait_for_timeout = .{ .process_id = pid, .timeout_ms = timeout_ms } } };
        },

        33 => { // process-stdin-write
            if (arg_count != 2) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const pid: u64 = @intCast(args_ptr[0]);
            const buf_ptr = ptrFromPayload(args_ptr[1]);
            const bytes = flixInt8ArrayBytesView(buf_ptr);
            ret.* = .{ .tag = 32, .val = .{ .process_stdin_write = .{ .process_id = pid, .bytes = witBytesToOwned(bytes) } } };
        },

        34, 35 => { // stdout-read / stderr-read
            if (arg_count != 2) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const pid: u64 = @intCast(args_ptr[0]);
            const buf_ptr = ptrFromPayload(args_ptr[1]);
            const cap: usize = flixArrayLen(buf_ptr);
            const max_bytes: u32 = if (cap > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(cap);
            const tag: u8 = @intCast(op - 1);
            if (tag == 33) {
                ret.* = .{ .tag = tag, .val = .{ .process_stdout_read = .{ .process_id = pid, .max_bytes = max_bytes } } };
            } else {
                ret.* = .{ .tag = tag, .val = .{ .process_stderr_read = .{ .process_id = pid, .max_bytes = max_bytes } } };
            }
        },

        37, 41 => { // tcp-socket-connect / tcp-server-bind
            if (arg_count != 2) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const ip_arr_ptr = ptrFromPayload(args_ptr[0]);
            const port_i32: i32 = @intCast(@as(i32, @truncate(args_ptr[1])));
            const port_u16 = parsePortOrInvalid(port_i32) orelse 0;
            const ip_bytes = flixInt8ArrayBytesView(ip_arr_ptr);
            const ip_list = witBytesToOwned(ip_bytes);
            const tag: u8 = @intCast(op - 1);
            if (tag == 36) {
                ret.* = .{ .tag = tag, .val = .{ .tcp_socket_connect = .{ .ip = ip_list, .port = port_u16 } } };
            } else {
                ret.* = .{ .tag = tag, .val = .{ .tcp_server_bind = .{ .ip = ip_list, .port = port_u16 } } };
            }
        },

        38 => { // tcp-socket-read
            if (arg_count != 2) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const sock_id: u64 = @intCast(args_ptr[0]);
            const buf_ptr = ptrFromPayload(args_ptr[1]);
            const cap: usize = flixArrayLen(buf_ptr);
            const max_bytes: u32 = if (cap > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(cap);
            ret.* = .{ .tag = 37, .val = .{ .tcp_socket_read = .{ .socket_id = sock_id, .max_bytes = max_bytes } } };
        },

        39 => { // tcp-socket-write
            if (arg_count != 2) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const sock_id: u64 = @intCast(args_ptr[0]);
            const buf_ptr = ptrFromPayload(args_ptr[1]);
            const bytes = flixInt8ArrayBytesView(buf_ptr);
            ret.* = .{ .tag = 38, .val = .{ .tcp_socket_write = .{ .socket_id = sock_id, .bytes = witBytesToOwned(bytes) } } };
        },

        40 => { // tcp-socket-close
            if (arg_count != 1) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const sock_id: u64 = @intCast(args_ptr[0]);
            ret.* = .{ .tag = 39, .val = .{ .tcp_socket_close = .{ .socket_id = sock_id } } };
        },

        42, 43, 44 => { // tcp-server-accept / local-port / close
            if (arg_count != 1) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            const server_id: u64 = @intCast(args_ptr[0]);
            const tag: u8 = @intCast(op - 1);
            switch (tag) {
                41 => ret.* = .{ .tag = tag, .val = .{ .tcp_server_accept = .{ .server_id = server_id } } },
                42 => ret.* = .{ .tag = tag, .val = .{ .tcp_server_local_port = .{ .server_id = server_id } } },
                43 => ret.* = .{ .tag = tag, .val = .{ .tcp_server_close = .{ .server_id = server_id } } },
                else => ret.* = witReqUnknown(eff_sym, op_index),
            }
        },

        45 => { // console-readln
            if (arg_count != 0 and arg_count != 1) {
                ret.* = witReqUnknown(eff_sym, op_index);
                return;
            }
            ret.* = std.mem.zeroes(exports_flix_runtime_runtime_op_request_t);
            ret.tag = 44;
        },

        else => ret.* = witReqUnknown(eff_sym, op_index),
    }
}

export fn exports_flix_runtime_runtime_suspension_arg_count(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_borrow_suspension_t) u32 {
    _ = ctx;
    const n = suspensionArgCountRaw(s);
    if (n > std.math.maxInt(u32)) @panic("suspension arg count exceeds u32");
    return @intCast(n);
}

export fn exports_flix_runtime_runtime_suspension_arg_as_i64(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_borrow_suspension_t, idx: u32) exports_flix_runtime_runtime_own_value_t {
    const bits = suspensionArgBits(s, idx);
    const h = makeHandleForI64(ctx.flix_ctx, bits);
    return makeOwnRuntimeValue(ctx, h);
}

export fn exports_flix_runtime_runtime_suspension_arg_as_ptr(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_borrow_suspension_t, idx: u32) exports_flix_runtime_runtime_own_value_t {
    const bits = suspensionArgBits(s, idx);
    if (bits == 0) @panic("suspension arg is null pointer");
    const h = makeHandleForPtr(ctx.flix_ctx, ptrFromPayload(bits));
    return makeOwnRuntimeValue(ctx, h);
}

export fn exports_flix_runtime_runtime_resume_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, v: exports_flix_runtime_runtime_borrow_value_t) void {
    if (!is_wasm) @panic("resume-ok: wasm-only");
    // Resume payload is the *Flix value bits* stored in the handle.
    const bits = flix_handle_payload(v.flix_ctx, v.handle);
    const resume_handle = makeHandleForI64(ctx.flix_ctx, bits);
    resumeTaskWithHandle(ctx, s, resume_handle, false);
}

export fn exports_flix_runtime_runtime_resume_throw(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, e: exports_flix_runtime_runtime_borrow_value_t) void {
    if (!is_wasm) @panic("resume-throw: wasm-only");
    // Throw payload is expected to be an exception value handle; pass the handle through.
    flix_handle_retain(ctx.flix_ctx, e.handle);
    resumeTaskWithHandle(ctx, s, e.handle, true);
}

export fn exports_flix_runtime_runtime_resume_ok_sync(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, v: exports_flix_runtime_runtime_borrow_value_t, ret: *exports_flix_runtime_runtime_exec_t) void {
    if (!is_wasm) @panic("resume-ok-sync: wasm-only");
    const bits = flix_handle_payload(v.flix_ctx, v.handle);
    const resume_handle = makeHandleForI64(ctx.flix_ctx, bits);
    resumeTaskWithHandleSync(ctx, s, resume_handle, false, ret);
}

export fn exports_flix_runtime_runtime_resume_throw_sync(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, e: exports_flix_runtime_runtime_borrow_value_t, ret: *exports_flix_runtime_runtime_exec_t) void {
    if (!is_wasm) @panic("resume-throw-sync: wasm-only");
    flix_handle_retain(ctx.flix_ctx, e.handle);
    resumeTaskWithHandleSync(ctx, s, e.handle, true, ret);
}

export fn exports_flix_runtime_runtime_resume_timer_sleep(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    if (!is_wasm) @panic("resume-timer-sleep: wasm-only");
    const h = makeHandleForI64(ctx.flix_ctx, 0); // Unit
    resumeTaskWithHandle(ctx, s, h, false);
}

export fn exports_flix_runtime_runtime_resume_console_readln_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, line: *flix_string_t) void {
    if (!is_wasm) @panic("resume-console-readln-ok: wasm-only");
    const str_ptr = flixStringFromWit(line);
    const h = makeHandleForPtr(ctx.flix_ctx, str_ptr);
    resumeTaskWithHandle(ctx, s, h, false);
}

// --- typed resumers (portable IO primops) ---

fn resumeIoOkTuple4Bool(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, ok: bool, x: i64, kind: i64, msg: *anyopaque) void {
    const tup_ptr = makeIoTuple4Bool(ok, x, kind, msg);
    const h = makeHandleForPtr(ctx.flix_ctx, tup_ptr);
    resumeTaskWithHandle(ctx, s, h, false);
}

fn resumeIoOkTuple4Ptr(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, ok: bool, x_ptr: *anyopaque, kind: i64, msg: *anyopaque) void {
    const tup_ptr = makeIoTuple4Ptr(ok, x_ptr, kind, msg);
    const h = makeHandleForPtr(ctx.flix_ctx, tup_ptr);
    resumeTaskWithHandle(ctx, s, h, false);
}

fn resumeIoOkTuple3(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, ok: bool, x: i64, msg: *anyopaque) void {
    const tup_ptr = makeIoTuple3Bool(ok, x, msg);
    const h = makeHandleForPtr(ctx.flix_ctx, tup_ptr);
    resumeTaskWithHandle(ctx, s, h, false);
}

fn resumeIoOkTuple2(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, ok: bool, msg: *anyopaque) void {
    const tup_ptr = makeIoTuple2(ok, msg);
    const h = makeHandleForPtr(ctx.flix_ctx, tup_ptr);
    resumeTaskWithHandle(ctx, s, h, false);
}

fn ioMsgFromWit(err: *const exports_flix_runtime_runtime_io_error_t) *anyopaque {
    return flixStringFromWit(&err.msg);
}

export fn exports_flix_runtime_runtime_resume_http_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, resp: *exports_flix_runtime_runtime_http_response_t) void {
    if (!is_wasm) @panic("resume-http-ok: wasm-only");

    // Allocate in the task's current region (if any).
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const task_ptr = ctx.tasks.getPtr(srep.task_id) orelse @panic("unknown task");
    const saved = current_region;
    current_region = task_ptr.region;
    defer current_region = saved;

    const region_ptr0: ?*anyopaque = if (current_region) |r| @ptrCast(r) else null;

    // Flatten headers into alternating key/value strings.
    const n: usize = resp.headers.len;
    const kv_count: usize = n * 2;
    var kv = std.ArrayListUnmanaged(*anyopaque){};
    defer kv.deinit(rt_alloc);
    kv.ensureTotalCapacity(rt_alloc, kv_count) catch @panic("oom");

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const h = resp.headers.ptr[i];
        kv.appendAssumeCapacity(flixStringFromWit(&h.name));
        kv.appendAssumeCapacity(flixStringFromWit(&h.value));
    }

    const resp_pairs_ptr = allocFlixArrayFromPtrPayloadsInRegion(ctx.flix_ctx, region_ptr0, kv.items);
    const resp_body_ptr = flixStringFromWit(&resp.body);
    const msg_ptr = allocFlixStringFromAscii("");
    const tup_ptr = makeHttpTuple(true, @intCast(resp.status), resp_pairs_ptr, resp_body_ptr, 14, msg_ptr);

    const h = makeHandleForPtr(ctx.flix_ctx, tup_ptr);
    resumeTaskWithHandle(ctx, s, h, false);
}

export fn exports_flix_runtime_runtime_resume_http_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    if (!is_wasm) @panic("resume-http-err: wasm-only");

    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const task_ptr = ctx.tasks.getPtr(srep.task_id) orelse @panic("unknown task");
    const saved = current_region;
    current_region = task_ptr.region;
    defer current_region = saved;

    const region_ptr0: ?*anyopaque = if (current_region) |r| @ptrCast(r) else null;
    const empty_pairs = allocFlixArrayFromPtrPayloadsInRegion(ctx.flix_ctx, region_ptr0, &[_]*anyopaque{});
    const empty_body = allocFlixStringFromAscii("");
    const msg_ptr = ioMsgFromWit(err_);
    const tup_ptr = makeHttpTuple(false, 0, empty_pairs, empty_body, err_.kind_code, msg_ptr);

    const h = makeHandleForPtr(ctx.flix_ctx, tup_ptr);
    resumeTaskWithHandle(ctx, s, h, false);
}

export fn exports_flix_runtime_runtime_resume_file_exists_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, exists: bool) void {
    resumeIoOkTuple4Bool(ctx, s, true, payloadFromBool(exists), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_exists_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, payloadFromBool(false), err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_is_directory_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, is_directory: bool) void {
    resumeIoOkTuple4Bool(ctx, s, true, payloadFromBool(is_directory), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_is_directory_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, payloadFromBool(false), err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_is_regular_file_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, is_regular_file: bool) void {
    resumeIoOkTuple4Bool(ctx, s, true, payloadFromBool(is_regular_file), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_is_regular_file_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, payloadFromBool(false), err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_is_readable_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, is_readable: bool) void {
    resumeIoOkTuple4Bool(ctx, s, true, payloadFromBool(is_readable), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_is_readable_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, payloadFromBool(false), err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_is_symbolic_link_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, is_symbolic_link: bool) void {
    resumeIoOkTuple4Bool(ctx, s, true, payloadFromBool(is_symbolic_link), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_is_symbolic_link_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, payloadFromBool(false), err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_is_writable_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, is_writable: bool) void {
    resumeIoOkTuple4Bool(ctx, s, true, payloadFromBool(is_writable), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_is_writable_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, payloadFromBool(false), err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_is_executable_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, is_executable: bool) void {
    resumeIoOkTuple4Bool(ctx, s, true, payloadFromBool(is_executable), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_is_executable_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, payloadFromBool(false), err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_access_time_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, ms: i64) void {
    resumeIoOkTuple4Bool(ctx, s, true, ms, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_access_time_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_creation_time_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, ms: i64) void {
    resumeIoOkTuple4Bool(ctx, s, true, ms, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_creation_time_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_modification_time_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, ms: i64) void {
    resumeIoOkTuple4Bool(ctx, s, true, ms, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_modification_time_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_size_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, bytes: i64) void {
    resumeIoOkTuple4Bool(ctx, s, true, bytes, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_size_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_read_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, data: *flix_string_t) void {
    const str_ptr = flixStringFromWit(data);
    resumeIoOkTuple4Ptr(ctx, s, true, str_ptr, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_read_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    const empty = allocFlixStringFromAscii("");
    resumeIoOkTuple4Ptr(ctx, s, false, empty, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_read_lines_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, lines: *flix_list_string_t) void {
    if (!is_wasm) @panic("resume-file-read-lines-ok: wasm-only");
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const region_ptr0 = ptrFromPayload(slots[5]); // arg0 = region

    var ptrs = std.ArrayListUnmanaged(*anyopaque){};
    defer ptrs.deinit(rt_alloc);
    ptrs.ensureTotalCapacity(rt_alloc, lines.len) catch @panic("oom");

    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        ptrs.appendAssumeCapacity(flixStringFromWit(&lines.ptr[i]));
    }

    const arr_ptr = allocFlixArrayFromPtrPayloadsInRegion(ctx.flix_ctx, region_ptr0, ptrs.items);
    resumeIoOkTuple4Ptr(ctx, s, true, arr_ptr, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_read_lines_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    // Use the region argument to allocate an empty array.
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const region_ptr0 = ptrFromPayload(slots[5]);
    const empty = allocFlixArrayFromPtrPayloadsInRegion(ctx.flix_ctx, region_ptr0, &[_]*anyopaque{});
    resumeIoOkTuple4Ptr(ctx, s, false, empty, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_read_bytes_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, bytes: *flix_list_u8_t) void {
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const region_ptr0 = ptrFromPayload(slots[5]);

    const slice = bytes.ptr[0..bytes.len];
    const arr_ptr = allocFlixInt8ArrayFromBytesInRegion(ctx.flix_ctx, region_ptr0, slice);
    resumeIoOkTuple4Ptr(ctx, s, true, arr_ptr, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_read_bytes_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const region_ptr0 = ptrFromPayload(slots[5]);
    const empty = allocFlixInt8ArrayFromBytesInRegion(ctx.flix_ctx, region_ptr0, &.{});
    resumeIoOkTuple4Ptr(ctx, s, false, empty, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_list_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, names: *flix_list_string_t) void {
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const region_ptr0 = ptrFromPayload(slots[5]);

    var ptrs = std.ArrayListUnmanaged(*anyopaque){};
    defer ptrs.deinit(rt_alloc);
    ptrs.ensureTotalCapacity(rt_alloc, names.len) catch @panic("oom");

    var i: usize = 0;
    while (i < names.len) : (i += 1) {
        ptrs.appendAssumeCapacity(flixStringFromWit(&names.ptr[i]));
    }

    const arr_ptr = allocFlixArrayFromPtrPayloadsInRegion(ctx.flix_ctx, region_ptr0, ptrs.items);
    resumeIoOkTuple4Ptr(ctx, s, true, arr_ptr, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_list_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const region_ptr0 = ptrFromPayload(slots[5]);
    const empty = allocFlixArrayFromPtrPayloadsInRegion(ctx.flix_ctx, region_ptr0, &[_]*anyopaque{});
    resumeIoOkTuple4Ptr(ctx, s, false, empty, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_write_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple4Bool(ctx, s, true, 0, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_write_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_write_bytes_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple4Bool(ctx, s, true, 0, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_write_bytes_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_append_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple4Bool(ctx, s, true, 0, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_append_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_append_bytes_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple4Bool(ctx, s, true, 0, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_append_bytes_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_truncate_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple4Bool(ctx, s, true, 0, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_truncate_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_mkdir_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple4Bool(ctx, s, true, 0, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_mkdir_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_mkdirs_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple4Bool(ctx, s, true, 0, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_mkdirs_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_file_mk_temp_dir_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, path: *flix_string_t) void {
    const str_ptr = flixStringFromWit(path);
    resumeIoOkTuple4Ptr(ctx, s, true, str_ptr, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_file_mk_temp_dir_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    const empty = allocFlixStringFromAscii("");
    resumeIoOkTuple4Ptr(ctx, s, false, empty, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_exec_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, process_id: u64) void {
    resumeIoOkTuple4Bool(ctx, s, true, @intCast(process_id), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_exec_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_exit_value_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, code: i32) void {
    resumeIoOkTuple4Bool(ctx, s, true, @intCast(code), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_exit_value_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_is_alive_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, is_alive: bool) void {
    resumeIoOkTuple4Bool(ctx, s, true, payloadFromBool(is_alive), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_is_alive_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, payloadFromBool(false), err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_pid_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, pid: i64) void {
    resumeIoOkTuple4Bool(ctx, s, true, pid, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_pid_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_stop_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple4Bool(ctx, s, true, 0, 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_stop_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_wait_for_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, code: i32) void {
    resumeIoOkTuple4Bool(ctx, s, true, @intCast(code), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_wait_for_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_wait_for_timeout_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, finished: bool) void {
    resumeIoOkTuple4Bool(ctx, s, true, payloadFromBool(finished), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_wait_for_timeout_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, payloadFromBool(false), err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_stdin_write_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const buf_ptr = ptrFromPayload(slots[6]); // arg1 = buffer
    const n: i64 = @intCast(flixArrayLen(buf_ptr));
    resumeIoOkTuple3(ctx, s, true, n, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_stdin_write_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple3(ctx, s, false, 0, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_stdout_read_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, bytes: *flix_list_u8_t) void {
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const buf_ptr = ptrFromPayload(slots[6]); // arg1 = buffer

    const slice = bytes.ptr[0..bytes.len];
    flixWriteBytesToInt8Array(buf_ptr, slice);
    const n: i64 = @intCast(@min(bytes.len, flixArrayLen(buf_ptr)));
    resumeIoOkTuple3(ctx, s, true, n, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_stdout_read_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple3(ctx, s, false, 0, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_stderr_read_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, bytes: *flix_list_u8_t) void {
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const buf_ptr = ptrFromPayload(slots[6]); // arg1 = buffer

    const slice = bytes.ptr[0..bytes.len];
    flixWriteBytesToInt8Array(buf_ptr, slice);
    const n: i64 = @intCast(@min(bytes.len, flixArrayLen(buf_ptr)));
    resumeIoOkTuple3(ctx, s, true, n, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_stderr_read_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple3(ctx, s, false, 0, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_process_release_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple2(ctx, s, true, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_process_release_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    // Best-effort: map to (false, msg).
    resumeIoOkTuple2(ctx, s, false, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_tcp_socket_connect_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, socket_id: u64) void {
    resumeIoOkTuple4Bool(ctx, s, true, @intCast(socket_id), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_tcp_socket_connect_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_tcp_socket_read_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, bytes: *flix_list_u8_t) void {
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const buf_ptr = ptrFromPayload(slots[6]); // arg1 = buffer

    const slice = bytes.ptr[0..bytes.len];
    flixWriteBytesToInt8Array(buf_ptr, slice);
    const n: i64 = @intCast(@min(bytes.len, flixArrayLen(buf_ptr)));
    resumeIoOkTuple3(ctx, s, true, n, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_tcp_socket_read_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple3(ctx, s, false, 0, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_tcp_socket_write_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    const srep = exports_flix_runtime_runtime_suspension_rep(s);
    const susp_ptr = flix_handle_get(ctx.flix_ctx, srep.susp_handle);
    const slots: [*]i64 = objPayloadSlots(susp_ptr);
    const buf_ptr = ptrFromPayload(slots[6]);
    const n: i64 = @intCast(flixArrayLen(buf_ptr));
    resumeIoOkTuple3(ctx, s, true, n, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_tcp_socket_write_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple3(ctx, s, false, 0, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_tcp_socket_close_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple2(ctx, s, true, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_tcp_socket_close_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple2(ctx, s, false, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_tcp_server_bind_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, server_id: u64) void {
    resumeIoOkTuple4Bool(ctx, s, true, @intCast(server_id), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_tcp_server_bind_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_tcp_server_accept_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, socket_id: u64) void {
    resumeIoOkTuple4Bool(ctx, s, true, @intCast(socket_id), 14, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_tcp_server_accept_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple4Bool(ctx, s, false, 0, err_.kind_code, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_tcp_server_local_port_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, port: u16) void {
    resumeIoOkTuple3(ctx, s, true, @intCast(port), allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_tcp_server_local_port_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple3(ctx, s, false, 0, ioMsgFromWit(err_));
}

export fn exports_flix_runtime_runtime_resume_tcp_server_close_ok(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t) void {
    resumeIoOkTuple2(ctx, s, true, allocFlixStringFromAscii(""));
}

export fn exports_flix_runtime_runtime_resume_tcp_server_close_err(ctx: exports_flix_runtime_runtime_borrow_ctx_t, s: exports_flix_runtime_runtime_own_suspension_t, err_: *exports_flix_runtime_runtime_io_error_t) void {
    resumeIoOkTuple2(ctx, s, false, ioMsgFromWit(err_));
}
