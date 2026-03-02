const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("regex.h");
});

const unicode_case = @import("unicode_case_tables.zig");

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
var g_gc_mutex: std.Thread.Mutex = .{};
var g_gc_objects: std.AutoHashMap(usize, GcMeta) = undefined;
var g_gc_bytes: usize = 0;
var g_gc_threshold_bytes: usize = 64 * 1024 * 1024; // default: 64 MiB
var g_gc_stress: bool = false;
var g_gc_requested: std.atomic.Value(bool) = .init(false);
var g_gc_collecting: std.atomic.Value(bool) = .init(false);

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
var g_rt_debug_mutex: std.Thread.Mutex = .{};

var g_gc_debug_initialized: bool = false;
var g_gc_debug: bool = false;
var g_gc_debug_mutex: std.Thread.Mutex = .{};

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
    std.debug.print(fmt, args);
}

fn dbgGc(comptime fmt: []const u8, args: anytype) void {
    ensureGcDebugInitialized();
    if (!g_gc_debug) return;
    std.debug.print(fmt, args);
}

fn ensureGcInitialized() void {
    if (g_gc_initialized) return;
    g_gc_mutex.lock();
    defer g_gc_mutex.unlock();
    if (g_gc_initialized) return;

    g_gc_objects = std.AutoHashMap(usize, GcMeta).init(std.heap.c_allocator);
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
    defer code_units.deinit(std.heap.c_allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const first = bytes[i];
        const seqlen = std.unicode.utf8ByteSequenceLength(first) catch {
            appendUtf16FromCodepoint(&code_units, std.heap.c_allocator, 0xFFFD) catch @panic("oom");
            i += 1;
            continue;
        };

        if (i + seqlen > bytes.len) {
            appendUtf16FromCodepoint(&code_units, std.heap.c_allocator, 0xFFFD) catch @panic("oom");
            break;
        }

        const slice = bytes[i .. i + seqlen];
        const cp = std.unicode.utf8Decode(slice) catch {
            appendUtf16FromCodepoint(&code_units, std.heap.c_allocator, 0xFFFD) catch @panic("oom");
            i += 1;
            continue;
        };

        appendUtf16FromCodepoint(&code_units, std.heap.c_allocator, cp) catch @panic("oom");
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

var g_tuple_typeinfo_mutex: std.Thread.Mutex = .{};
var g_tuple_typeinfo_initialized: bool = false;
var g_tuple_typeinfo_table: std.AutoHashMap(u128, *const FlixTypeInfo) = undefined;
var g_tuple_typeinfo_next_id: u32 = 1;

fn ensureTupleTypeInfoInitialized() void {
    if (g_tuple_typeinfo_initialized) return;
    g_tuple_typeinfo_mutex.lock();
    defer g_tuple_typeinfo_mutex.unlock();
    if (g_tuple_typeinfo_initialized) return;
    g_tuple_typeinfo_table = std.AutoHashMap(u128, *const FlixTypeInfo).init(std.heap.c_allocator);
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
        const offs = std.heap.c_allocator.alloc(u32, ptr_count) catch @panic("oom");
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

    const ti = std.heap.c_allocator.create(FlixTypeInfo) catch @panic("oom");
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
    seen_epoch: std.atomic.Value(u64),
    blocked: std.atomic.Value(bool),
    gc_marker: ?*GcMarker,
    next_handle: i64,
    handles_mutex: std.Thread.Mutex,
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

var g_handshake_request_epoch: std.atomic.Value(u64) = .init(0);
var g_handshake_release_epoch: std.atomic.Value(u64) = .init(0);
var g_handshake_ack_count: std.atomic.Value(u32) = .init(0);
var g_handshake_cb_id: std.atomic.Value(u8) = .init(@intFromEnum(HandshakeCallbackId.Nop));
var g_handshake_stw: std.atomic.Value(bool) = .init(false);

// Pending spawn roots: closure pointers passed to new OS threads before the thread has a chance to
// register a `FlixCtx` and publish its explicit roots. These pointers live on a foreign stack and
// are otherwise invisible to the GC (we do not conservatively scan stacks).
var g_spawn_roots_initialized: bool = false;
var g_spawn_roots_mutex: std.Thread.Mutex = .{};
var g_spawn_roots: std.AutoHashMap(usize, void) = undefined;

// Registered thread contexts (best-effort bring-up registry; GC will use this later).
var g_ctx_registry_initialized: bool = false;
var g_ctx_registry_mutex: std.Thread.Mutex = .{};
var g_ctx_registry: std.AutoHashMap(usize, void) = undefined;

fn ensureSpawnRootsInitialized() void {
    if (g_spawn_roots_initialized) return;
    g_spawn_roots_mutex.lock();
    defer g_spawn_roots_mutex.unlock();
    if (g_spawn_roots_initialized) return;
    g_spawn_roots = std.AutoHashMap(usize, void).init(std.heap.c_allocator);
    g_spawn_roots_initialized = true;
}

fn spawnRootsAdd(ptr: *anyopaque) void {
    ensureSpawnRootsInitialized();
    g_spawn_roots_mutex.lock();
    defer g_spawn_roots_mutex.unlock();
    g_spawn_roots.put(@intFromPtr(ptr), {}) catch @panic("oom");
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
    g_ctx_registry = std.AutoHashMap(usize, void).init(std.heap.c_allocator);
    g_ctx_registry_initialized = true;
}

fn registerCtx(ctx: *FlixCtx) void {
    ensureCtxRegistryInitialized();
    g_ctx_registry_mutex.lock();
    defer g_ctx_registry_mutex.unlock();
    g_ctx_registry.put(@intFromPtr(ctx), {}) catch @panic("oom");
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
            marker.worklist.append(std.heap.c_allocator, ptr) catch @panic("oom");
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
}

fn gcMarkSweep(ctx: *FlixCtx) void {
    if (!g_gc_initialized) return;

    var marker: GcMarker = .{ .worklist = .{} };
    defer marker.worklist.deinit(std.heap.c_allocator);
    marker.worklist.ensureTotalCapacity(std.heap.c_allocator, 4096) catch @panic("oom");

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
    defer to_free.deinit(std.heap.c_allocator);

    var it = g_gc_objects.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.marked) {
            entry.value_ptr.marked = false;
        } else {
            to_free.append(std.heap.c_allocator, entry.key_ptr.*) catch @panic("oom");
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
    const ctx = std.heap.c_allocator.create(FlixCtx) catch @panic("oom");
    const req = g_handshake_request_epoch.load(.acquire);
    const initial_seen = if (req > 0) req - 1 else 0;
    ctx.* = .{
        .seen_epoch = .init(initial_seen),
        .blocked = .init(false),
        .gc_marker = null,
        .next_handle = 1,
        .handles_mutex = .{},
        .handles = std.AutoHashMap(i64, FlixHandleEntry).init(std.heap.c_allocator),
        .cancel_exn = null,
        .roots = .{},
    };
    // Avoid allocations in the hot path of root push/pop.
    ctx.roots.ensureTotalCapacity(std.heap.c_allocator, 2048) catch @panic("oom");
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
    ctx.roots.deinit(std.heap.c_allocator);
    std.heap.c_allocator.destroy(ctx);
    dbg("ctx_free: {x} done\n", .{@intFromPtr(ctx_ptr)});
}

export fn flix_gc_push_root_value_i64(ctx_ptr: *anyopaque, slot_ptr0: ?*anyopaque) void {
    const slot_ptr = slot_ptr0 orelse @panic("flix_gc_push_root_value_i64: null slot");
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.roots.append(std.heap.c_allocator, .{ .kind = .ValueI64, .slot_ptr = slot_ptr }) catch @panic("oom");
}

export fn flix_gc_push_root_ptr(ctx_ptr: *anyopaque, slot_ptr0: ?*anyopaque) void {
    const slot_ptr = slot_ptr0 orelse @panic("flix_gc_push_root_ptr: null slot");
    const ctx: *FlixCtx = requireCtx(ctx_ptr);
    ctx.roots.append(std.heap.c_allocator, .{ .kind = .Ptr, .slot_ptr = slot_ptr }) catch @panic("oom");
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
    const alloc = std.heap.c_allocator;
    const str_ptr = flix_handle_get(ctx_ptr, str_handle);

    const bytes = flixStringToUtf8Alloc(alloc, str_ptr);
    defer alloc.free(bytes);

    const z = alloc.allocSentinel(u8, bytes.len, 0) catch @panic("oom");
    std.mem.copyForwards(u8, z[0..bytes.len], bytes);

    out_len.* = @intCast(bytes.len);
    return z.ptr;
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
    const bytes = flixInt8ArrayToBytes(std.heap.c_allocator, arr_ptr);
    out_len.* = @intCast(bytes.len);
    return bytes.ptr;
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
// Regex (bring-up)
// ============================================================================

const RegexObj = struct {
    re: c.regex_t,
    pattern: *anyopaque,
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

fn unicodeIsDefined(cp: u32) bool {
    return inRanges(cp, unicode_case.defined_ranges[0..]);
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
    defer out.deinit(std.heap.c_allocator);
    out.ensureTotalCapacity(std.heap.c_allocator, in_len) catch @panic("oom");

    var i: usize = 0;
    while (i < in_units.len) {
        const d = decodeCodePointAt(in_units, i);
        const cp = d.cp;

        // Full special casing (unconditional) from SpecialCasing.txt.
        if (lookupSpecialUnits(cp, unicode_case.lower_full_cases[0..], unicode_case.lower_full_values[0..])) |seq| {
            out.appendSlice(std.heap.c_allocator, seq) catch @panic("oom");
            i += d.len;
            continue;
        }

        // Context-sensitive final sigma.
        if (cp == 0x03A3) { // Σ
            const mapped: u32 = if (isFinalSigma(in_units, i, d.len)) 0x03C2 else 0x03C3;
            appendUtf16FromCodepointRaw(&out, std.heap.c_allocator, mapped) catch @panic("oom");
            i += d.len;
            continue;
        }

        const mapped: u32 = unicodeToLowerSimple(cp);
        appendUtf16FromCodepointRaw(&out, std.heap.c_allocator, mapped) catch @panic("oom");
        i += d.len;
    }

    return allocFlixStringFromUtf16Units(ctx_ptr, out.items);
}

export fn flix_string_to_upper_case(ctx_ptr: *anyopaque, str_ptr: *anyopaque) *anyopaque {
    const in_len: usize = flixStringLen(str_ptr);
    const in_units_ptr: [*]const u16 = flixStringCodeUnits(str_ptr);
    const in_units: []const u16 = in_units_ptr[0..in_len];

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(std.heap.c_allocator);
    out.ensureTotalCapacity(std.heap.c_allocator, in_len) catch @panic("oom");

    var i: usize = 0;
    while (i < in_units.len) {
        const d = decodeCodePointAt(in_units, i);
        const cp = d.cp;

        // Full special casing (unconditional) from SpecialCasing.txt.
        if (lookupSpecialUnits(cp, unicode_case.upper_full_cases[0..], unicode_case.upper_full_values[0..])) |seq| {
            out.appendSlice(std.heap.c_allocator, seq) catch @panic("oom");
            i += d.len;
            continue;
        }

        const mapped: u32 = unicodeToUpperSimple(cp);
        appendUtf16FromCodepointRaw(&out, std.heap.c_allocator, mapped) catch @panic("oom");
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
    errdefer out.deinit(std.heap.c_allocator);

    for (bytes) |ch| {
        if (isRegexMeta(ch)) out.append(std.heap.c_allocator, '\\') catch @panic("oom");
        out.append(std.heap.c_allocator, ch) catch @panic("oom");
    }

    return out.toOwnedSlice(std.heap.c_allocator) catch @panic("oom");
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

    const literal = (flags & 16) != 0; // Pattern.LITERAL
    var quoted: []u8 = &.{};
    defer if (quoted.len != 0) std.heap.c_allocator.free(quoted);

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

    const obj = std.heap.c_allocator.create(RegexObj) catch @panic("oom");
    obj.pattern = pattern_ptr;
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

    const literal = (flags & 16) != 0; // Pattern.LITERAL
    var quoted: []u8 = &.{};
    defer if (quoted.len != 0) std.heap.c_allocator.free(quoted);

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

    const obj = std.heap.c_allocator.create(RegexObj) catch @panic("oom");
    obj.re = re;
    obj.pattern = pattern_ptr;
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
    defer std.heap.c_allocator.free(quoted);
    return allocFlixStringFromAscii(quoted);
}

export fn flix_regex_pattern(rgx_ptr: *anyopaque) *anyopaque {
    const rgx: *RegexObj = @ptrCast(@alignCast(rgx_ptr));
    return rgx.pattern;
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
    defer out.deinit(std.heap.c_allocator);

    var offset: usize = 0;
    var match: [1]c.regmatch_t = undefined;

    while (offset <= m.input_len) {
        const rc = c.regexec(&m.rgx.re, m.input.ptr + offset, 1, &match, 0);
        if (rc != 0) break;

        const so: usize = @intCast(match[0].rm_so);
        const eo: usize = @intCast(match[0].rm_eo);
        const start = offset + so;
        const end = offset + eo;

        out.appendSlice(std.heap.c_allocator, m.input[offset..start]) catch @panic("oom");
        out.appendSlice(std.heap.c_allocator, repl) catch @panic("oom");

        offset = end;
        if (eo == so) offset += 1; // avoid infinite loop on empty matches.
    }

    if (offset <= m.input_len) {
        out.appendSlice(std.heap.c_allocator, m.input[offset..m.input_len]) catch @panic("oom");
    }

    return allocFlixStringFromAscii(out.items);
}

export fn flix_regex_matcher_replace_first(m_ptr: *anyopaque, replacement_ptr: *anyopaque) *anyopaque {
    const m: *MatcherObj = @ptrCast(@alignCast(m_ptr));
    const repl_z = flixStringToAsciiZ(replacement_ptr);
    defer c.free(@ptrCast(repl_z.ptr));
    const repl = repl_z[0..repl_z.len];

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);

    var match: [1]c.regmatch_t = undefined;
    const rc = c.regexec(&m.rgx.re, m.input.ptr, 1, &match, 0);
    if (rc != 0) {
        return allocFlixStringFromAscii(m.input[0..m.input_len]);
    }

    const so: usize = @intCast(match[0].rm_so);
    const eo: usize = @intCast(match[0].rm_eo);

    out.appendSlice(std.heap.c_allocator, m.input[0..so]) catch @panic("oom");
    out.appendSlice(std.heap.c_allocator, repl) catch @panic("oom");
    out.appendSlice(std.heap.c_allocator, m.input[eo..m.input_len]) catch @panic("oom");

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
    defer parts.deinit(std.heap.c_allocator);

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
        parts.append(std.heap.c_allocator, part) catch @panic("oom");

        offset = end;
        if (eo == so) offset += 1; // avoid infinite loop on empty matches.
    }

    const tail = allocFlixStringFromAscii(input[offset..input.len]);
    parts.append(std.heap.c_allocator, tail) catch @panic("oom");

    return allocFlixArrayFromPtrPayloadsInRegion(ctx, region_ptr0, parts.items);
}

// ============================================================================
// Channels (bring-up)
// ============================================================================

const ChannelObj = struct {
    capacity: usize,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    not_full: std.Thread.Condition = .{},

    // Buffered channel state (capacity > 0).
    buf: ?[]i64 = null,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    // Unbuffered (rendezvous) channel state (capacity == 0).
    rv_has_msg: bool = false,
    rv_payload: i64 = 0,
};

fn channelInit(capacity: usize) *ChannelObj {
    const obj = std.heap.c_allocator.create(ChannelObj) catch @panic("oom");
    obj.* = .{ .capacity = capacity };
    if (capacity > 0) {
        obj.buf = std.heap.c_allocator.alloc(i64, capacity) catch @panic("oom");
    }
    return obj;
}

export fn flix_channel_new(capacity: i32) *anyopaque {
    const cap: usize = if (capacity <= 0) 0 else @intCast(capacity);
    return channelInit(cap);
}

export fn flix_channel_put(chan_ptr: *anyopaque, payload: i64) i64 {
    const chan: *ChannelObj = @ptrCast(@alignCast(chan_ptr));
    const ctx_opt = current_ctx;
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
        chan.rv_payload = payload;
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

    buf[chan.tail] = payload;
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

// ============================================================================
// IO + Spawn (bring-up)
// ============================================================================

var g_next_id: std.atomic.Value(i64) = .init(0);
var g_argc: i32 = 0;
var g_argv: ?[*][*:0]u8 = null;

export fn flix_init(argc: i32, argv: *anyopaque) void {
    g_argc = argc;
    g_argv = @ptrCast(@alignCast(argv));
}

fn writeAscii(fd: enum { stdout, stderr }, s_ptr: *anyopaque, newline: bool) void {
    const z = flixStringToAsciiZ(s_ptr);
    defer c.free(@ptrCast(z.ptr));

    const slice = z[0..z.len];
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

export fn flix_print(s_ptr: *anyopaque) i64 {
    writeAscii(.stdout, s_ptr, false);
    return 0;
}

export fn flix_eprint(s_ptr: *anyopaque) i64 {
    writeAscii(.stderr, s_ptr, false);
    return 0;
}

export fn flix_println(s_ptr: *anyopaque) i64 {
    writeAscii(.stdout, s_ptr, true);
    return 0;
}

export fn flix_eprintln(s_ptr: *anyopaque) i64 {
    writeAscii(.stderr, s_ptr, true);
    return 0;
}

export fn flix_readln(_: i64) *anyopaque {
    var buf: [65536]u8 = undefined;
    var reader = std.fs.File.stdin().readerStreaming(buf[0..]);
    const line_opt = (blk: {
        var guard = BlockedGuard.enter(current_ctx);
        defer guard.exitAndCooperate();
        break :blk reader.interface.takeDelimiter('\n');
    }) catch @panic("readln failed");
    if (line_opt == null) return allocFlixStringFromAscii("");

    var bytes = line_opt.?;
    if (bytes.len != 0 and bytes[bytes.len - 1] == '\r') {
        bytes = bytes[0 .. bytes.len - 1];
    }
    return allocFlixStringFromAscii(bytes);
}

export fn flix_sleep_millis(ms: i64) i64 {
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

export fn flix_exit(code: i32) void {
    c.exit(code);
}

export fn flix_new_id(_: i64) i64 {
    return g_next_id.fetchAdd(1, .monotonic);
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

    const builtin = @import("builtin");

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
        const cwd = std.fs.cwd().realpathAlloc(std.heap.c_allocator, ".") catch return null;
        defer std.heap.c_allocator.free(cwd);
        return allocFlixStringFromUtf8Lossy(cwd);
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
    const n = std.Thread.getCpuCount() catch 1;
    if (n == 0) return 1;
    if (n > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(n);
}

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
var g_tcp_mutex: std.Thread.Mutex = .{};
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

const ProcessObj = struct {
    ref_count: std.atomic.Value(u32) = .init(1),
    mutex: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},

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
var g_proc_mutex: std.Thread.Mutex = .{};
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

    const builtin = @import("builtin");
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
    const builtin = @import("builtin");

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
    const builtin = @import("builtin");
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

    const builtin = @import("builtin");
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
        trace_stack.ensureTotalCapacity(std.heap.c_allocator, 256) catch {};
    }
    trace_stack.append(std.heap.c_allocator, name) catch {};
}

export fn flix_trace_pop() void {
    if (trace_stack.items.len == 0) return;
    _ = trace_stack.pop();
}

fn captureTrace() *anyopaque {
    var ptrs: std.ArrayList(*anyopaque) = .empty;
    defer ptrs.deinit(std.heap.c_allocator);

    var i: usize = trace_stack.items.len;
    while (i > 0) : (i -= 1) {
        const cstr = trace_stack.items[i - 1];
        const bytes = std.mem.span(cstr);
        const s_ptr = allocFlixStringFromAscii(bytes);
        ptrs.append(std.heap.c_allocator, s_ptr) catch @panic("oom");
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
    std.fs.File.stderr().writeAll(header) catch {};

    const trace_bits: i64 = slots[3];
    if (trace_bits == 0) {
        std.fs.File.stderr().writeAll("  (no trace)\n") catch {};
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
        std.fs.File.stderr().writeAll("  at ") catch {};
        writeAscii(.stderr, frame_ptr, true);
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
    cancel_requested: std.atomic.Value(bool),
    cancel_cause: ?*anyopaque,
    mutex: std.Thread.Mutex,
    arena: std.heap.ArenaAllocator,
    children: std.ArrayListUnmanaged(std.Thread),
    child_exn: ?*anyopaque,
    remembered_slots: std.ArrayListUnmanaged(*i64),
    remembered_ptr_arrays: std.ArrayListUnmanaged(RememberedPtrArray),
};

threadlocal var current_region: ?*FlixRegion = null;

// Registered live regions (GC root source via remembered sets).
var g_region_registry_initialized: bool = false;
var g_region_registry_mutex: std.Thread.Mutex = .{};
var g_region_registry: std.AutoHashMap(usize, void) = undefined;

fn ensureRegionRegistryInitialized() void {
    if (g_region_registry_initialized) return;
    g_region_registry_mutex.lock();
    defer g_region_registry_mutex.unlock();
    if (g_region_registry_initialized) return;
    g_region_registry = std.AutoHashMap(usize, void).init(std.heap.c_allocator);
    g_region_registry_initialized = true;
}

fn registerRegion(region: *FlixRegion) void {
    ensureRegionRegistryInitialized();
    g_region_registry_mutex.lock();
    defer g_region_registry_mutex.unlock();
    g_region_registry.put(@intFromPtr(region), {}) catch @panic("oom");
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
    const region = std.heap.c_allocator.create(FlixRegion) catch @panic("oom");
    region.* = .{
        .parent = parent,
        .state = .Open,
        .cancel_requested = .init(false),
        .cancel_cause = null,
        .mutex = .{},
        .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        .children = .{},
        .child_exn = null,
        .remembered_slots = .{},
        .remembered_ptr_arrays = .{},
    };

    current_region = region;
    registerRegion(region);
    const parent_bits: usize = if (parent) |p| @intFromPtr(p) else 0;
    dbg("region_enter: {x} parent={x}\n", .{ @intFromPtr(region), parent_bits });
    return region;
}

export fn flix_region_exit(ctx: *anyopaque, region_ptr0: ?*anyopaque, body_outcome: FlixResult) FlixResult {
    const fctx: *FlixCtx = requireCtx(ctx);

    // `body_outcome` may carry a pointer payload that is not otherwise present in the explicit root
    // stack (it is passed by value across the region delimiter). Since `region_exit` may block while
    // joining children, we root it explicitly for the duration of this function.
    const roots_len0 = fctx.roots.items.len;
    var outcome_payload_slot: i64 = body_outcome.payload;
    fctx.roots.append(std.heap.c_allocator, .{ .kind = .ValueI64, .slot_ptr = @ptrCast(&outcome_payload_slot) }) catch @panic("oom");
    defer fctx.roots.items.len = roots_len0;

    const region_ptr = region_ptr0 orelse return body_outcome;
    const region: *FlixRegion = @ptrCast(@alignCast(region_ptr));
    dbg("region_exit: {x} start\n", .{@intFromPtr(region)});

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
    children.deinit(std.heap.c_allocator);
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
    region.remembered_slots.deinit(std.heap.c_allocator);
    region.remembered_ptr_arrays.deinit(std.heap.c_allocator);

    region.arena.deinit();
    deregisterRegion(region);
    std.heap.c_allocator.destroy(region);
    dbg("region_exit: {x} done\n", .{@intFromPtr(region)});
    return out;
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
    region.remembered_slots.append(std.heap.c_allocator, slot) catch @panic("oom");
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
    region.remembered_ptr_arrays.append(std.heap.c_allocator, .{ .base = base_slots, .count = count }) catch @panic("oom");
}

export fn flix_store_ptr(ctx: *anyopaque, slot_ptr: *anyopaque, value: i64) void {
    _ = ctx;
    const slot: *i64 = @ptrCast(@alignCast(slot_ptr));
    slot.* = value;
}

export fn flix_spawn(ctx: *anyopaque, region_ptr0: ?*anyopaque, clo: *anyopaque) i64 {
    _ = ctx;
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
        region.children.append(std.heap.c_allocator, t) catch @panic("oom");
        return 0;
    }

    // Detached spawn in the Static region (represented as null).
    const t = std.Thread.spawn(.{}, spawnThreadMain, .{SpawnArgs{ .clo = clo, .region = null }}) catch @panic("spawn failed");
    t.detach();
    return 0;
}
