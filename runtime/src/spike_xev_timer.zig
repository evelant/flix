const std = @import("std");
const xev = @import("xev");

const Suspension = struct {
    resumed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn flix_resume_ok(susp: *Suspension) void {
    susp.resumed.store(true, .release);
}

fn timerCallback(
    userdata: ?*Suspension,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = loop;
    _ = c;
    _ = result catch unreachable;

    const susp: *Suspension = userdata.?;
    std.debug.print("[xev] timer fired; resuming suspension\n", .{});
    flix_resume_ok(susp);
    return .disarm;
}

pub fn main() !void {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const timer = try xev.Timer.init();
    defer timer.deinit();

    var susp = Suspension{};
    var completion: xev.Completion = undefined;

    // Run a short timer and treat its completion as "host resumes a suspended computation".
    timer.run(&loop, &completion, 50, Suspension, &susp, &timerCallback);

    try loop.run(.until_done);

    if (!susp.resumed.load(.acquire)) {
        return error.SuspensionNotResumed;
    }

    std.debug.print("[xev] done\n", .{});
}
