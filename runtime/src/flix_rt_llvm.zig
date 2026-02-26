const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("regex.h");
});

fn allocFlixStringFromAscii(bytes: []const u8) *anyopaque {
    const len: usize = bytes.len;
    const slots: usize = len + 1;
    const size: usize = slots * @sizeOf(i64);

    const mem = c.malloc(size) orelse @panic("malloc failed");
    const slots_ptr: [*]i64 = @ptrCast(@alignCast(mem));

    slots_ptr[0] = @intCast(len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        slots_ptr[i + 1] = @intCast(bytes[i]);
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
    const slots: usize = len + 1;
    const size: usize = slots * @sizeOf(i64);

    const mem = c.malloc(size) orelse @panic("malloc failed");
    const slots_ptr: [*]i64 = @ptrCast(@alignCast(mem));

    slots_ptr[0] = @intCast(len);
    var j: usize = 0;
    while (j < len) : (j += 1) {
        slots_ptr[j + 1] = @intCast(code_units.items[j]);
    }

    return mem;
}

fn allocFlixTupleFromPayloads(payloads: []const i64) *anyopaque {
    const slots: usize = payloads.len;
    const size: usize = slots * @sizeOf(i64);

    const mem = c.malloc(size) orelse @panic("malloc failed");
    const slots_ptr: [*]i64 = @ptrCast(@alignCast(mem));

    var i: usize = 0;
    while (i < slots) : (i += 1) {
        slots_ptr[i] = payloads[i];
    }

    return mem;
}

fn allocFlixArrayFromPayloads(payloads: []const i64) *anyopaque {
    const len: usize = payloads.len;
    const slots: usize = len + 1;
    const size: usize = slots * @sizeOf(i64);

    const mem = c.malloc(size) orelse @panic("malloc failed");
    const slots_ptr: [*]i64 = @ptrCast(@alignCast(mem));

    slots_ptr[0] = @intCast(len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        slots_ptr[i + 1] = payloads[i];
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

fn flixStringSlots(ptr: *anyopaque) [*]i64 {
    return @ptrCast(@alignCast(ptr));
}

fn flixStringLen(ptr: *anyopaque) usize {
    return @intCast(flixStringSlots(ptr)[0]);
}

fn flixStringToAsciiZ(ptr: *anyopaque) [:0]u8 {
    const slots = flixStringSlots(ptr);
    const len: usize = @intCast(slots[0]);

    const mem = c.malloc(len + 1) orelse @panic("malloc failed");
    const bytes: [*]u8 = @ptrCast(mem);

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const cu: u64 = @intCast(slots[i + 1]);
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
    const slots: usize = len + 1;
    const size: usize = slots * @sizeOf(i64);

    const mem = c.malloc(size) orelse @panic("malloc failed");
    const slots_ptr: [*]i64 = @ptrCast(@alignCast(mem));

    slots_ptr[0] = @intCast(len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        slots_ptr[i + 1] = @intCast(@intFromPtr(ptrs[i]));
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
        return allocFlixTupleFromPayloads(&payloads);
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
    return allocFlixTupleFromPayloads(&payloads);
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

export fn flix_regex_new_matcher(rgx_ptr: *anyopaque, input_ptr: *anyopaque) *anyopaque {
    const rgx: *RegexObj = @ptrCast(@alignCast(rgx_ptr));
    const input = flixStringToAsciiZ(input_ptr);

    const m = std.heap.c_allocator.create(MatcherObj) catch @panic("oom");
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
    m.matches = std.heap.c_allocator.alloc(c.regmatch_t, nmatch) catch @panic("oom");
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

export fn flix_regex_matcher_set_bounds(m_ptr: *anyopaque, start: i32, end: i32) i64 {
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
    const mem = c.malloc(len + 1) orelse @panic("malloc failed");
    const bytes: [*]u8 = @ptrCast(mem);
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

export fn flix_regex_split(rgx_ptr: *anyopaque, input_ptr: *anyopaque) *anyopaque {
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

    return allocFlixArrayFromPtrPayloads(parts.items);
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
    chan.mutex.lock();
    defer chan.mutex.unlock();

    if (chan.capacity == 0) {
        while (chan.rv_has_msg) {
            chan.not_full.wait(&chan.mutex);
        }
        chan.rv_payload = payload;
        chan.rv_has_msg = true;
        chan.not_empty.signal();

        while (chan.rv_has_msg) {
            chan.not_full.wait(&chan.mutex);
        }
        return 0;
    }

    const buf = chan.buf orelse @panic("missing buffer");
    while (chan.count == chan.capacity) {
        chan.not_full.wait(&chan.mutex);
    }

    buf[chan.tail] = payload;
    chan.tail = (chan.tail + 1) % chan.capacity;
    chan.count += 1;
    chan.not_empty.signal();
    return 0;
}

export fn flix_channel_get(chan_ptr: *anyopaque) i64 {
    const chan: *ChannelObj = @ptrCast(@alignCast(chan_ptr));
    chan.mutex.lock();
    defer chan.mutex.unlock();

    if (chan.capacity == 0) {
        while (!chan.rv_has_msg) {
            chan.not_empty.wait(&chan.mutex);
        }
        const payload = chan.rv_payload;
        chan.rv_has_msg = false;
        chan.not_full.signal();
        return payload;
    }

    const buf = chan.buf orelse @panic("missing buffer");
    while (chan.count == 0) {
        chan.not_empty.wait(&chan.mutex);
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

    file.writeAll(slice) catch @panic("write failed");
    if (newline) file.writeAll("\n") catch @panic("write failed");
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
    const line_opt = reader.interface.takeDelimiter('\n') catch @panic("readln failed");
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
    std.Thread.sleep(ns);
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

export fn flix_env_get_args(_: *anyopaque) *anyopaque {
    if (g_argc <= 1 or g_argv == null) {
        return allocFlixArrayFromPayloads(&.{});
    }

    const n: usize = @intCast(g_argc - 1);
    const slots: usize = n + 1;
    const size: usize = slots * @sizeOf(i64);

    const mem = c.malloc(size) orelse @panic("malloc failed");
    const slots_ptr: [*]i64 = @ptrCast(@alignCast(mem));
    slots_ptr[0] = @intCast(n);

    const argv = g_argv.?;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const arg_z = argv[i + 1];
        const arg = std.mem.span(arg_z);
        const s_ptr = allocFlixStringFromUtf8Lossy(arg);
        slots_ptr[i + 1] = payloadFromPtr(s_ptr);
    }

    return mem;
}

export fn flix_env_get_env_pairs(_: *anyopaque) *anyopaque {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var env = std.process.getEnvMap(alloc) catch {
        return allocFlixArrayFromPayloads(&.{});
    };
    defer env.deinit();

    const pair_count: usize = env.count();
    const len: usize = pair_count * 2;
    const slots: usize = len + 1;
    const size: usize = slots * @sizeOf(i64);

    const mem = c.malloc(size) orelse @panic("malloc failed");
    const slots_ptr: [*]i64 = @ptrCast(@alignCast(mem));
    slots_ptr[0] = @intCast(len);

    var idx: usize = 0;
    var it = env.iterator();
    while (it.next()) |entry| {
        const k_bytes = entry.key_ptr.*;
        const v_bytes = entry.value_ptr.*;
        const k_ptr = allocFlixStringFromUtf8Lossy(k_bytes);
        const v_ptr = allocFlixStringFromUtf8Lossy(v_bytes);
        slots_ptr[idx + 1] = payloadFromPtr(k_ptr);
        slots_ptr[idx + 2] = payloadFromPtr(v_ptr);
        idx += 2;
    }

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

export fn flix_tcp_socket_read(_: i64, _: *anyopaque) *anyopaque {
    const msg = stubMsg("TCP_SOCKET_READ");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, payloadFromPtr(msg) });
}

export fn flix_tcp_socket_write(_: i64, _: *anyopaque) *anyopaque {
    const msg = stubMsg("TCP_SOCKET_WRITE");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, payloadFromPtr(msg) });
}

export fn flix_tcp_socket_connect(_: *anyopaque, _: i32) *anyopaque {
    const msg = stubMsg("TCP_SOCKET_CONNECT");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, 12, payloadFromPtr(msg) });
}

export fn flix_tcp_socket_close(_: i64) *anyopaque {
    const msg = stubMsg("TCP_SOCKET_CLOSE");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), payloadFromPtr(msg) });
}

export fn flix_tcp_server_bind(_: *anyopaque, _: i32) *anyopaque {
    const msg = stubMsg("TCP_SERVER_BIND");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, 12, payloadFromPtr(msg) });
}

export fn flix_tcp_server_accept(_: i64) *anyopaque {
    const msg = stubMsg("TCP_SERVER_ACCEPT");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, 12, payloadFromPtr(msg) });
}

export fn flix_tcp_server_close(_: i64) *anyopaque {
    const msg = stubMsg("TCP_SERVER_CLOSE");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), payloadFromPtr(msg) });
}

export fn flix_process_stdin_write(_: i64, _: *anyopaque) *anyopaque {
    const msg = stubMsg("PROCESS_STDIN_WRITE");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, payloadFromPtr(msg) });
}

export fn flix_process_exec(_: *anyopaque, _: bool, _: *anyopaque, _: *anyopaque) *anyopaque {
    const msg = stubMsg("PROCESS_EXEC");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, 12, payloadFromPtr(msg) });
}

export fn flix_process_exit_value(_: i64) *anyopaque {
    const msg = stubMsg("PROCESS_EXIT_VALUE");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, 12, payloadFromPtr(msg) });
}

export fn flix_process_is_alive(_: i64) *anyopaque {
    const msg = stubMsg("PROCESS_IS_ALIVE");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), payloadFromBool(false), 12, payloadFromPtr(msg) });
}

export fn flix_process_pid(_: i64) *anyopaque {
    const msg = stubMsg("PROCESS_PID");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, 12, payloadFromPtr(msg) });
}

export fn flix_process_stop(_: i64) *anyopaque {
    const msg = stubMsg("PROCESS_STOP");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, 12, payloadFromPtr(msg) });
}

export fn flix_process_wait_for(_: i64) *anyopaque {
    const msg = stubMsg("PROCESS_WAIT_FOR");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, 12, payloadFromPtr(msg) });
}

export fn flix_process_wait_for_timeout(_: i64, _: i64) *anyopaque {
    const msg = stubMsg("PROCESS_WAIT_FOR_TIMEOUT");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), payloadFromBool(false), 12, payloadFromPtr(msg) });
}

export fn flix_process_stdout_read(_: i64, _: *anyopaque) *anyopaque {
    const msg = stubMsg("PROCESS_STDOUT_READ");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, payloadFromPtr(msg) });
}

export fn flix_process_stderr_read(_: i64, _: *anyopaque) *anyopaque {
    const msg = stubMsg("PROCESS_STDERR_READ");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), 0, payloadFromPtr(msg) });
}

export fn flix_process_release(_: i64) *anyopaque {
    const msg = stubMsg("PROCESS_RELEASE");
    return allocFlixTupleFromPayloads(&.{ payloadFromBool(false), payloadFromPtr(msg) });
}

export fn flix_http_request(_: *anyopaque, _: *anyopaque, _: *anyopaque, _: bool, _: *anyopaque) *anyopaque {
    const msg = stubMsg("HTTP_REQUEST");
    const empty_pairs = allocFlixArrayFromPayloads(&.{});
    const empty_body = allocFlixStringFromAscii("");
    return allocFlixTupleFromPayloads(&.{
        payloadFromBool(false), // ok
        0, // status
        payloadFromPtr(empty_pairs), // respPairs
        payloadFromPtr(empty_body), // respBody
        12, // kindCode (Unsupported)
        payloadFromPtr(msg), // msg
    });
}

const FlixResult = extern struct {
    tag: i64,
    payload: i64,
};

const RESULT_TAG_VALUE: i64 = 1;
const RESULT_TAG_THUNK: i64 = 2;
const RESULT_TAG_SUSPENSION: i64 = 3;
const RESULT_TAG_EXCEPTION: i64 = 4;

const InvokeFn = *const fn (ctx: *anyopaque, self: *anyopaque, arg0: i64) callconv(.c) FlixResult;

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

fn invokeThunk(ctx: *anyopaque, thunk: *anyopaque, arg0: i64) FlixResult {
    const slots: [*]i64 = @ptrCast(@alignCast(thunk));
    const code_bits: u64 = @bitCast(slots[0]);
    const fn_ptr: InvokeFn = @ptrFromInt(@as(usize, @intCast(code_bits)));
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
    const mem = c.malloc(2 * @sizeOf(i64)) orelse @panic("malloc failed");
    const slots: [*]i64 = @ptrCast(@alignCast(mem));
    slots[0] = payloadFromPtr(frame);
    slots[1] = payloadFromNullablePtrOrZero(prefix);
    return mem;
}

export fn flix_frames_reverse_onto(prefix: ?*anyopaque, onto: ?*anyopaque) ?*anyopaque {
    var p = prefix;
    var acc = onto;
    while (p) |node| {
        const slots: [*]i64 = @ptrCast(@alignCast(node));
        const head_ptr = ptrFromPayload(slots[0]);
        const tail_ptr = nullablePtrFromPayload(slots[1]);
        acc = flix_frames_push(head_ptr, acc);
        p = tail_ptr;
    }
    return acc;
}

export fn flix_frame_copy(frame: *anyopaque) *anyopaque {
    const src: [*]i64 = @ptrCast(@alignCast(frame));
    const slots_i64: i64 = src[1];
    if (slots_i64 <= 0) @panic("invalid frame size");

    const slots: usize = @intCast(slots_i64);
    const size: usize = slots * @sizeOf(i64);
    const mem = c.malloc(size) orelse @panic("malloc failed");
    const dst: [*]i64 = @ptrCast(@alignCast(mem));

    var i: usize = 0;
    while (i < slots) : (i += 1) {
        dst[i] = src[i];
    }
    return mem;
}

fn applyFrameSnapshot(ctx: *anyopaque, frame_snapshot: *anyopaque, resume_payload: i64) FlixResult {
    const fresh = flix_frame_copy(frame_snapshot);
    return invokeThunk(ctx, fresh, resume_payload);
}

fn allocResumptionCons(eff_sym: i64, handler: *anyopaque, frames: ?*anyopaque, tail: ?*anyopaque) *anyopaque {
    const mem = c.malloc(4 * @sizeOf(i64)) orelse @panic("malloc failed");
    const slots: [*]i64 = @ptrCast(@alignCast(mem));
    slots[0] = eff_sym;
    slots[1] = payloadFromPtr(handler);
    slots[2] = payloadFromNullablePtrOrZero(frames);
    slots[3] = payloadFromNullablePtrOrZero(tail);
    return mem;
}

fn allocSuspensionLike(src_susp: *anyopaque, prefix: ?*anyopaque, resumption: ?*anyopaque) *anyopaque {
    const src: [*]i64 = @ptrCast(@alignCast(src_susp));
    const eff_sym: i64 = src[0];
    const op_index: i64 = src[1];
    const arg_count_i64: i64 = src[4];
    if (arg_count_i64 < 0) @panic("invalid suspension argCount");
    const arg_count: usize = @intCast(arg_count_i64);

    const slots_total: usize = 5 + arg_count;
    const size: usize = slots_total * @sizeOf(i64);
    const mem = c.malloc(size) orelse @panic("malloc failed");
    const dst: [*]i64 = @ptrCast(@alignCast(mem));

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
                const slots: [*]i64 = @ptrCast(@alignCast(node));
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
                const susp_slots: [*]i64 = @ptrCast(@alignCast(susp_ptr));
                const susp_eff_sym: i64 = susp_slots[0];
                const prefix_ptr = nullablePtrFromPayload(susp_slots[2]);
                const susp_resumption = nullablePtrFromPayload(susp_slots[3]);

                const combined_frames = flix_frames_reverse_onto(prefix_ptr, frames);
                const resumption_cons = allocResumptionCons(eff_sym, handler, combined_frames, susp_resumption);

                if (susp_eff_sym == eff_sym) {
                    const op_index_i64: i64 = susp_slots[1];
                    if (op_index_i64 < 0) @panic("invalid opIndex");
                    const op_index: usize = @intCast(op_index_i64);

                    const handler_slots: [*]i64 = @ptrCast(@alignCast(handler));
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
    const r0 = invokeThunk(ctx, thunk, 0);
    return installHandlerResult(ctx, eff_sym, handler, frames, r0);
}

export fn flix_resumption_rewind(ctx: *anyopaque, resumption0: ?*anyopaque, v: i64) FlixResult {
    if (resumption0 == null) {
        return FlixResult{ .tag = RESULT_TAG_VALUE, .payload = v };
    }

    const resumption = resumption0.?;
    const slots: [*]i64 = @ptrCast(@alignCast(resumption));
    const eff_sym: i64 = slots[0];
    const handler_ptr = ptrFromPayload(slots[1]);
    const frames_ptr = nullablePtrFromPayload(slots[2]);
    const tail_ptr = nullablePtrFromPayload(slots[3]);

    const tail_result = flix_resumption_rewind(ctx, tail_ptr, v);
    return installHandlerResult(ctx, eff_sym, handler_ptr, frames_ptr, tail_result);
}

const SpawnArgs = struct {
    ctx: *anyopaque,
    clo: *anyopaque,
};

fn spawnThreadMain(args: SpawnArgs) void {
    const slots: [*]i64 = @ptrCast(@alignCast(args.clo));
    const code_bits: u64 = @bitCast(slots[0]);
    const fn_ptr: InvokeFn = @ptrFromInt(@as(usize, @intCast(code_bits)));
    var r = fn_ptr(args.ctx, args.clo, 0);

    // Unwind thunks to completion (bring-up: ignore Suspension/Exception).
    while (r.tag == 2) {
        const payload_bits: u64 = @bitCast(r.payload);
        const thunk_ptr: *anyopaque = @ptrFromInt(@as(usize, @intCast(payload_bits)));
        const thunk_slots: [*]i64 = @ptrCast(@alignCast(thunk_ptr));
        const thunk_code_bits: u64 = @bitCast(thunk_slots[0]);
        const thunk_fn_ptr: InvokeFn = @ptrFromInt(@as(usize, @intCast(thunk_code_bits)));
        r = thunk_fn_ptr(args.ctx, thunk_ptr, 0);
    }
}

export fn flix_spawn(ctx: *anyopaque, clo: *anyopaque) i64 {
    const t = std.Thread.spawn(.{}, spawnThreadMain, .{SpawnArgs{ .ctx = ctx, .clo = clo }}) catch @panic("spawn failed");
    t.detach();
    return 0;
}
