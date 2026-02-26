const std = @import("std");
const xev = @import("xev");

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

fn parseHttpResponse(raw: []const u8) !struct { status: u16, headers_len: usize, body: []const u8 } {
    const sep = "\r\n\r\n";
    const header_end = std.mem.indexOf(u8, raw, sep) orelse return error.InvalidHttpResponse;
    const headers = raw[0..header_end];
    const body = raw[header_end + sep.len ..];

    const line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return error.InvalidHttpResponse;
    const status_line = headers[0..line_end];

    var it = std.mem.splitScalar(u8, status_line, ' ');
    _ = it.next() orelse return error.InvalidHttpResponse;
    const status_str = it.next() orelse return error.InvalidHttpResponse;
    const status = try std.fmt.parseInt(u16, status_str, 10);

    return .{ .status = status, .headers_len = headers.len, .body = body };
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

fn parseHttpResponseBody(alloc: std.mem.Allocator, raw: []const u8) !struct { status: u16, body: ParsedBody } {
    const parsed = try parseHttpResponse(raw);
    const body = parsed.body;

    if (headerValue(raw[0..parsed.headers_len], "Transfer-Encoding")) |enc| {
        if (hasChunkedEncoding(enc)) {
            const decoded = try decodeChunked(alloc, body);
            return .{ .status = parsed.status, .body = .{ .owned = decoded } };
        }
    }

    if (headerValue(raw[0..parsed.headers_len], "Content-Length")) |len_str| {
        if (std.fmt.parseInt(usize, len_str, 10)) |n| {
            const n1 = @min(n, body.len);
            return .{ .status = parsed.status, .body = .{ .borrowed = body[0..n1] } };
        } else |_| {}
    }

    return .{ .status = parsed.status, .body = .{ .borrowed = body } };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // exe name

    const url = args.next() orelse "http://example.com/";
    const parsed = try parseHttpUrl(url);

    const req = try std.fmt.allocPrint(
        alloc,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\nUser-Agent: flix-spike-xev-http-get\r\nAccept: */*\r\n\r\n",
        .{ parsed.path_and_query, parsed.host },
    );
    defer alloc.free(req);

    const addr_list = try std.net.getAddressList(alloc, parsed.host, parsed.port);
    defer addr_list.deinit();
    if (addr_list.addrs.len == 0) return error.UnknownHost;
    const addr = addr_list.addrs[0];

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var client = Client{
        .alloc = alloc,
        .tcp = try xev.TCP.init(addr),
        .request = req,
        .response = .empty,
    };
    defer client.response.deinit(alloc);

    client.connect(&loop, addr);
    try loop.run(.until_done);

    if (!client.done) return error.LoopExitedEarly;
    if (client.err) |err| return err;

    const resp = client.response.items;
    var parsed_resp = try parseHttpResponseBody(alloc, resp);
    defer parsed_resp.body.deinit(alloc);

    const body = parsed_resp.body.bytes();
    std.debug.print("[http] url={s} status={d} bytes={d}\n", .{ url, parsed_resp.status, body.len });
    const preview_len: usize = @min(body.len, 200);
    if (preview_len > 0) {
        std.debug.print("[http] body (first {d} bytes):\n{s}\n", .{ preview_len, body[0..preview_len] });
    }
}
