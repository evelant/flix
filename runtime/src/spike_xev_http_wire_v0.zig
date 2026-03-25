const std = @import("std");

const wire = @import("http_wire_v0.zig");
const http = @import("http_request_std_wire_v0.zig");

fn parseHeaderLine(line: []const u8) !wire.Header {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
    const key = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (key.len == 0) return error.InvalidHeader;
    return .{ .key = key, .value = value };
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

    const outcome = try http.httpRequest(alloc, req_blob, null);
    const resp_blob = switch (outcome) {
        .completed => |blob| blob,
        .canceled => return error.Canceled,
    };
    defer alloc.free(resp_blob);

    var resp = try wire.decodeResponse(alloc, resp_blob);
    defer resp.deinit(alloc);

    std.debug.print("[wire] ok={any} status={d} headers={d} err_kind={d}\n", .{
        resp.ok,
        resp.status,
        resp.headers.len,
        resp.err_kind,
    });

    if (!resp.ok) {
        std.debug.print("[wire] err_msg={s}\n", .{resp.err_msg});
        return;
    }

    const preview_len: usize = @min(resp.body.len, 200);
    if (preview_len > 0) {
        std.debug.print("[wire] body (first {d} bytes):\n{s}\n", .{ preview_len, resp.body[0..preview_len] });
    }
}
