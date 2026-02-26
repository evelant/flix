const std = @import("std");

const wire = @import("http_wire_v0.zig");
const sys = @import("http_syscall_v0.zig");

fn parseHeaderLine(line: []const u8) !wire.Header {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (key.len == 0) return error.InvalidHeader;
    return .{ .key = key, .value = value };
}

fn parseUsize(arg: []const u8) !usize {
    return std.fmt.parseInt(usize, arg, 10);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // exe name

    var method: []const u8 = "GET";
    var url: ?[]const u8 = null;
    var body: []const u8 = "";
    var has_body: bool = false;
    var resp_buf_cap: usize = 1024 * 1024; // 1MiB default

    var headers: std.ArrayList(wire.Header) = .empty;
    defer headers.deinit(alloc);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--method") or std.mem.eql(u8, arg, "-X")) {
            method = args.next() orelse return error.MissingMethod;
            continue;
        }

        if (std.mem.eql(u8, arg, "--header") or std.mem.eql(u8, arg, "-H")) {
            const line = args.next() orelse return error.MissingHeader;
            try headers.append(alloc, try parseHeaderLine(line));
            continue;
        }

        if (std.mem.eql(u8, arg, "--body") or std.mem.eql(u8, arg, "--data")) {
            body = args.next() orelse return error.MissingBody;
            has_body = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--resp-buf")) {
            resp_buf_cap = try parseUsize(args.next() orelse return error.MissingRespBuf);
            continue;
        }

        // First positional argument is the URL.
        if (url == null) {
            url = arg;
            continue;
        }

        return error.UnexpectedArgument;
    }

    const url1 = url orelse "http://example.com/";

    const req_blob = try wire.encodeRequest(
        alloc,
        method,
        url1,
        headers.items,
        has_body,
        body,
    );
    defer alloc.free(req_blob);

    var resp_buf = try alloc.alloc(u8, resp_buf_cap);
    defer alloc.free(resp_buf);

    var out_len: u32 = 0;
    const res = sys.http_request(alloc, req_blob, resp_buf, &out_len);
    std.debug.print("[sys] status={any} err_code={d} out_len={d}\n", .{ res.status, res.err_code, out_len });

    if (res.status != .ok) return error.SyscallFailed;

    var resp = try wire.decodeResponse(alloc, resp_buf[0..out_len]);
    defer resp.deinit(alloc);

    std.debug.print("[sys] ok={any} status={d} headers={d} err_kind={d}\n", .{
        resp.ok,
        resp.status,
        resp.headers.len,
        resp.err_kind,
    });

    if (!resp.ok) {
        std.debug.print("[sys] err_msg={s}\n", .{resp.err_msg});
        return;
    }

    const preview_len: usize = @min(resp.body.len, 200);
    if (preview_len > 0) {
        std.debug.print("[sys] body (first {d} bytes):\n{s}\n", .{ preview_len, resp.body[0..preview_len] });
    }
}

