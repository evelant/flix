const std = @import("std");
const xev = @import("xev");

const wire = @import("http_wire_v0.zig");

const IoErrorKind = struct {
    const connection_failed: i32 = 1;
    const interrupted: i32 = 2;
    const invalid_input: i32 = 4;
    const invalid_data: i32 = 5;
    const timeout: i32 = 10;
    const unsupported: i32 = 12;
    const unknown_host: i32 = 13;
    const other: i32 = 14;
};

const ParsedHttpUrl = struct {
    host: []const u8,
    port: u16,
    path_and_query: []const u8,
};

fn parseHttpUrl(url: []const u8) !ParsedHttpUrl {
    const scheme = "http://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.UnsupportedScheme;

    const rest = url[scheme.len..];
    if (rest.len == 0) return error.InvalidUrl;

    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash_idx];
    if (host_port.len == 0) return error.InvalidUrl;

    const path_and_query = if (slash_idx == rest.len) "/" else rest[slash_idx..];

    var host: []const u8 = host_port;
    var port: u16 = 80;

    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon_idx| {
        host = host_port[0..colon_idx];
        const port_str = host_port[colon_idx + 1 ..];
        if (host.len == 0 or port_str.len == 0) return error.InvalidUrl;
        port = try std.fmt.parseInt(u16, port_str, 10);
    }

    return .{ .host = host, .port = port, .path_and_query = path_and_query };
}

fn containsCrlf(s: []const u8) bool {
    return (std.mem.indexOfScalar(u8, s, '\r') != null) or (std.mem.indexOfScalar(u8, s, '\n') != null);
}

fn hasHeader(headers: []const wire.Header, needle: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.key, needle)) return true;
    }
    return false;
}

fn mapResolveError(err: anyerror) i32 {
    return switch (err) {
        error.UnknownHostName,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.ServiceUnavailable,
        => IoErrorKind.unknown_host,
        else => IoErrorKind.other,
    };
}

fn mapConnectError(err: anyerror) i32 {
    return switch (err) {
        error.ConnectionRefused,
        error.HostUnreachable,
        => IoErrorKind.connection_failed,
        error.TimedOut => IoErrorKind.timeout,
        error.Canceled => IoErrorKind.interrupted,
        else => IoErrorKind.other,
    };
}

fn mapReadWriteError(err: anyerror) i32 {
    return switch (err) {
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        => IoErrorKind.connection_failed,
        error.Canceled => IoErrorKind.interrupted,
        else => IoErrorKind.other,
    };
}

const ParsedBody = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    fn bytes(self: ParsedBody) []const u8 {
        return switch (self) {
            .borrowed => |b| b,
            .owned => |b| b,
        };
    }

    fn deinit(self: *ParsedBody, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .borrowed => {},
            .owned => |b| alloc.free(b),
        }
        self.* = .{ .borrowed = "" };
    }
};

fn headerValue(headers: []const u8, needle: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next(); // status line

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, needle)) return val;
    }

    return null;
}

fn hasChunkedEncoding(value: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (std.ascii.eqlIgnoreCase(t, "chunked")) return true;
    }
    return false;
}

fn decodeChunked(alloc: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (true) {
        const line_end_rel = std.mem.indexOf(u8, encoded[i..], "\r\n") orelse return error.InvalidChunkedEncoding;
        const line = encoded[i .. i + line_end_rel];
        i += line_end_rel + 2;

        const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const size_str = std.mem.trim(u8, line[0..semi], " \t");
        if (size_str.len == 0) return error.InvalidChunkedEncoding;

        const size = try std.fmt.parseInt(usize, size_str, 16);
        if (size == 0) {
            // Optional trailers until a blank line.
            while (true) {
                const t_end_rel = std.mem.indexOf(u8, encoded[i..], "\r\n") orelse return error.InvalidChunkedEncoding;
                if (t_end_rel == 0) {
                    i += 2;
                    break;
                }
                i += t_end_rel + 2;
            }
            break;
        }

        if (i + size + 2 > encoded.len) return error.InvalidChunkedEncoding;
        try out.appendSlice(alloc, encoded[i .. i + size]);
        i += size;

        if (!std.mem.eql(u8, encoded[i .. i + 2], "\r\n")) return error.InvalidChunkedEncoding;
        i += 2;
    }

    return out.toOwnedSlice(alloc);
}

fn parseHttpResponse(raw: []const u8) !struct { status: i32, headers: []const u8, body: []const u8 } {
    const sep = "\r\n\r\n";
    const header_end = std.mem.indexOf(u8, raw, sep) orelse return error.InvalidHttpResponse;
    const headers = raw[0..header_end];
    const body = raw[header_end + sep.len ..];

    const line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return error.InvalidHttpResponse;
    const status_line = headers[0..line_end];

    var it = std.mem.splitScalar(u8, status_line, ' ');
    _ = it.next() orelse return error.InvalidHttpResponse;
    const status_str = it.next() orelse return error.InvalidHttpResponse;
    const status_u16 = try std.fmt.parseInt(u16, status_str, 10);

    return .{ .status = @intCast(status_u16), .headers = headers, .body = body };
}

fn parseHttpBody(alloc: std.mem.Allocator, headers: []const u8, body: []const u8) !ParsedBody {
    if (headerValue(headers, "Transfer-Encoding")) |enc| {
        if (hasChunkedEncoding(enc)) {
            const decoded = try decodeChunked(alloc, body);
            return .{ .owned = decoded };
        }
    }

    if (headerValue(headers, "Content-Length")) |len_str| {
        if (std.fmt.parseInt(usize, len_str, 10)) |n| {
            const n1 = @min(n, body.len);
            return .{ .borrowed = body[0..n1] };
        } else |_| {}
    }

    return .{ .borrowed = body };
}

fn collectHeaderPairs(alloc: std.mem.Allocator, headers_blob: []const u8) ![]wire.Header {
    var pairs: std.ArrayList(wire.Header) = .empty;
    errdefer pairs.deinit(alloc);

    var lines = std.mem.splitSequence(u8, headers_blob, "\r\n");
    _ = lines.next(); // status line

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        try pairs.append(alloc, .{ .key = key, .value = val });
    }

    return pairs.toOwnedSlice(alloc);
}

fn sanitizeUtf8IfNeeded(alloc: std.mem.Allocator, input: []const u8) !ParsedBody {
    if (std.unicode.utf8ValidateSlice(input)) {
        return .{ .borrowed = input };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < input.len) {
        const first = input[i];
        const seqlen = std.unicode.utf8ByteSequenceLength(first) catch {
            try out.appendSlice(alloc, &std.unicode.replacement_character_utf8);
            i += 1;
            continue;
        };

        if (i + seqlen > input.len) {
            try out.appendSlice(alloc, &std.unicode.replacement_character_utf8);
            break;
        }

        const slice = input[i .. i + seqlen];
        _ = std.unicode.utf8Decode(slice) catch {
            try out.appendSlice(alloc, &std.unicode.replacement_character_utf8);
            i += 1;
            continue;
        };

        try out.appendSlice(alloc, slice);
        i += seqlen;
    }

    return .{ .owned = try out.toOwnedSlice(alloc) };
}

fn encodeErrorResponse(alloc: std.mem.Allocator, kind: i32, msg: []const u8) std.mem.Allocator.Error![]u8 {
    return wire.encodeResponse(alloc, false, 0, &.{}, "", kind, msg);
}

fn buildHttp11Request(
    alloc: std.mem.Allocator,
    req: wire.RequestView,
    url: ParsedHttpUrl,
) ![]u8 {
    if (containsCrlf(req.method) or std.mem.indexOfScalar(u8, req.method, ' ') != null) return error.InvalidInput;

    for (req.headers) |h| {
        if (containsCrlf(h.key) or containsCrlf(h.value)) return error.InvalidInput;
        if (std.mem.indexOfScalar(u8, h.key, ':') != null) return error.InvalidInput;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, req.method);
    try out.appendSlice(alloc, " ");
    try out.appendSlice(alloc, url.path_and_query);
    try out.appendSlice(alloc, " HTTP/1.1\r\n");

    const has_host = hasHeader(req.headers, "Host");
    const has_conn = hasHeader(req.headers, "Connection");
    const has_len = hasHeader(req.headers, "Content-Length");

    if (!has_host) {
        try out.appendSlice(alloc, "Host: ");
        try out.appendSlice(alloc, url.host);
        if (url.port != 80) {
            var buf: [16]u8 = undefined;
            const port_str = try std.fmt.bufPrint(&buf, ":{d}", .{url.port});
            try out.appendSlice(alloc, port_str);
        }
        try out.appendSlice(alloc, "\r\n");
    }

    if (!has_conn) {
        try out.appendSlice(alloc, "Connection: close\r\n");
    }

    for (req.headers) |h| {
        try out.appendSlice(alloc, h.key);
        try out.appendSlice(alloc, ": ");
        try out.appendSlice(alloc, h.value);
        try out.appendSlice(alloc, "\r\n");
    }

    if (req.has_body and !has_len) {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "Content-Length: {d}\r\n", .{req.body.len});
        try out.appendSlice(alloc, s);
    }

    try out.appendSlice(alloc, "\r\n");

    if (req.has_body) {
        try out.appendSlice(alloc, req.body);
    }

    return out.toOwnedSlice(alloc);
}

const Client = struct {
    alloc: std.mem.Allocator,
    tcp: xev.TCP,
    completion: xev.Completion = .{},

    request: []const u8,
    write_off: usize = 0,

    response: std.ArrayList(u8),
    read_buf: [16 * 1024]u8 = undefined,

    done: bool = false,
    err: ?anyerror = null,

    fn connect(self: *Client, loop: *xev.Loop, addr: std.net.Address) void {
        self.tcp.connect(loop, &self.completion, addr, Client, self, connectCb);
    }

    fn connectCb(
        self_opt: ?*Client,
        loop: *xev.Loop,
        c: *xev.Completion,
        _: xev.TCP,
        r: xev.ConnectError!void,
    ) xev.CallbackAction {
        const self = self_opt.?;
        _ = r catch |err| {
            self.err = err;
            self.tcp.close(loop, c, Client, self, closeCb);
            return .disarm;
        };

        self.write_off = 0;
        self.writeNext(loop, c);
        return .disarm;
    }

    fn writeNext(self: *Client, loop: *xev.Loop, c: *xev.Completion) void {
        const remaining = self.request[self.write_off..];
        self.tcp.write(loop, c, .{ .slice = remaining }, Client, self, writeCb);
    }

    fn writeCb(
        self_opt: ?*Client,
        loop: *xev.Loop,
        c: *xev.Completion,
        _: xev.TCP,
        buf: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = self_opt.?;
        _ = buf;

        const n = r catch |err| {
            self.err = err;
            self.tcp.close(loop, c, Client, self, closeCb);
            return .disarm;
        };

        self.write_off += n;
        if (self.write_off < self.request.len) {
            self.writeNext(loop, c);
            return .disarm;
        }

        self.readNext(loop, c);
        return .disarm;
    }

    fn readNext(self: *Client, loop: *xev.Loop, c: *xev.Completion) void {
        const rb = xev.ReadBuffer{ .slice = &self.read_buf };
        self.tcp.read(loop, c, rb, Client, self, readCb);
    }

    fn readCb(
        self_opt: ?*Client,
        loop: *xev.Loop,
        c: *xev.Completion,
        _: xev.TCP,
        buf: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = self_opt.?;

        const n = r catch |err| switch (err) {
            error.EOF => {
                self.tcp.close(loop, c, Client, self, closeCb);
                return .disarm;
            },
            else => {
                self.err = err;
                self.tcp.close(loop, c, Client, self, closeCb);
                return .disarm;
            },
        };

        if (n == 0) {
            self.tcp.close(loop, c, Client, self, closeCb);
            return .disarm;
        }

        self.response.appendSlice(self.alloc, buf.slice[0..n]) catch |err| {
            self.err = err;
            self.tcp.close(loop, c, Client, self, closeCb);
            return .disarm;
        };

        self.readNext(loop, c);
        return .disarm;
    }

    fn closeCb(
        self_opt: ?*Client,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        r: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = self_opt.?;
        _ = r catch {};
        self.done = true;
        return .disarm;
    }
};

pub fn httpRequest(alloc: std.mem.Allocator, req_blob: []const u8) std.mem.Allocator.Error![]u8 {
    const decoded = wire.decodeRequest(alloc, req_blob) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const kind: i32 = switch (err) {
            error.InvalidInput => IoErrorKind.invalid_input,
            error.InvalidVersion => IoErrorKind.unsupported,
            error.UnexpectedEof => IoErrorKind.invalid_input,
            else => IoErrorKind.other,
        };
        return encodeErrorResponse(alloc, kind, @errorName(err));
    };
    defer {
        var d = decoded;
        d.deinit(alloc);
    }

    const parsed_url = parseHttpUrl(decoded.url) catch |err| {
        const kind: i32 = switch (err) {
            error.UnsupportedScheme => IoErrorKind.unsupported,
            error.InvalidUrl => IoErrorKind.invalid_input,
            else => IoErrorKind.invalid_input,
        };
        return encodeErrorResponse(alloc, kind, @errorName(err));
    };

    const request_bytes = buildHttp11Request(alloc, decoded, parsed_url) catch |err| {
        const kind: i32 = switch (err) {
            error.InvalidInput => IoErrorKind.invalid_input,
            else => IoErrorKind.other,
        };
        return encodeErrorResponse(alloc, kind, @errorName(err));
    };
    defer alloc.free(request_bytes);

    const addr_list = std.net.getAddressList(alloc, parsed_url.host, parsed_url.port) catch |err| {
        return encodeErrorResponse(alloc, mapResolveError(err), @errorName(err));
    };
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) {
        return encodeErrorResponse(alloc, IoErrorKind.unknown_host, "unknown host");
    }

    const addr = addr_list.addrs[0];

    var loop = xev.Loop.init(.{}) catch |err| {
        return encodeErrorResponse(alloc, IoErrorKind.other, @errorName(err));
    };
    defer loop.deinit();

    var client = Client{
        .alloc = alloc,
        .tcp = xev.TCP.init(addr) catch |err| {
            return encodeErrorResponse(alloc, IoErrorKind.other, @errorName(err));
        },
        .request = request_bytes,
        .response = .empty,
    };
    defer client.response.deinit(alloc);

    client.connect(&loop, addr);
    loop.run(.until_done) catch |err| {
        return encodeErrorResponse(alloc, IoErrorKind.other, @errorName(err));
    };

    if (!client.done) {
        return encodeErrorResponse(alloc, IoErrorKind.other, "loop exited early");
    }

    if (client.err) |err| {
        const kind = mapConnectError(err);
        const kind2 = if (kind == IoErrorKind.other) mapReadWriteError(err) else kind;
        return encodeErrorResponse(alloc, kind2, @errorName(err));
    }

    const raw = client.response.items;
    const parsed = parseHttpResponse(raw) catch |err| {
        return encodeErrorResponse(alloc, IoErrorKind.invalid_data, @errorName(err));
    };

    var body = parseHttpBody(alloc, parsed.headers, parsed.body) catch |err| {
        return encodeErrorResponse(alloc, IoErrorKind.invalid_data, @errorName(err));
    };
    defer body.deinit(alloc);

    var body_utf8 = sanitizeUtf8IfNeeded(alloc, body.bytes()) catch |err| {
        return encodeErrorResponse(alloc, IoErrorKind.invalid_data, @errorName(err));
    };
    defer body_utf8.deinit(alloc);

    const resp_headers = collectHeaderPairs(alloc, parsed.headers) catch |err| {
        return encodeErrorResponse(alloc, IoErrorKind.other, @errorName(err));
    };
    defer alloc.free(resp_headers);

    return wire.encodeResponse(alloc, true, parsed.status, resp_headers, body_utf8.bytes(), IoErrorKind.other, "");
}
