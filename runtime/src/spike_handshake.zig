const std = @import("std");

const RootStack = struct {
    // Stack of addresses of GC pointer slots (i.e., flix_obj_t**).
    slots: [256]?*?*anyopaque = .{null} ** 256,
    len: usize = 0,

    fn push(self: *RootStack, slot_addr: *?*anyopaque) void {
        std.debug.assert(self.len < self.slots.len);
        self.slots[self.len] = slot_addr;
        self.len += 1;
    }

    fn pop(self: *RootStack, n: usize) void {
        std.debug.assert(self.len >= n);
        self.len -= n;
        // intentionally do not clear for speed (debugging can clear if needed)
    }
};

const ThreadState = struct {
    id: usize,
    roots: RootStack = .{},

    // Stable root slots for the spike (addresses are pushed onto `roots`).
    root_a: ?*anyopaque = null,
    root_b: ?*anyopaque = null,

    // Observability.
    iterations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const Handshake = struct {
    // Monotonic handshake epoch.
    request_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    release_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // How many threads have entered the current handshake.
    ack_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    thread_count: u32,

    // Callback executed by each thread while "stopped".
    cb: *const fn (*ThreadState) void,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn pollcheck(self: *Handshake, state: *ThreadState, seen_epoch: *u64) void {
        const req = self.request_epoch.load(.acquire);
        if (req == seen_epoch.*) return;
        seen_epoch.* = req;

        // "Stop": run per-thread callback, then park until released.
        self.cb(state);
        _ = self.ack_count.fetchAdd(1, .acq_rel);

        while (self.release_epoch.load(.acquire) < req) {
            std.atomic.spinLoopHint();
        }
    }

    fn request(self: *Handshake) u64 {
        self.ack_count.store(0, .release);
        const next = self.request_epoch.fetchAdd(1, .acq_rel) + 1;
        return next;
    }

    fn wait_all(self: *Handshake) void {
        while (self.ack_count.load(.acquire) != self.thread_count) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *Handshake, epoch: u64) void {
        self.release_epoch.store(epoch, .release);
    }
};

fn perThreadStopCallback(state: *ThreadState) void {
    // Simulate root scanning by counting non-null roots currently registered.
    var non_null: usize = 0;
    var i: usize = 0;
    while (i < state.roots.len) : (i += 1) {
        const slot_addr_opt = state.roots.slots[i] orelse break;
        const slot_addr = slot_addr_opt;
        if (slot_addr.* != null) non_null += 1;
    }

    std.debug.print(
        "[handshake] thread={d} roots={d} non_null={d} iters={d}\n",
        .{ state.id, state.roots.len, non_null, state.iterations.load(.acquire) },
    );
}

fn workerMain(handshake: *Handshake, state: *ThreadState) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Allocate two dummy heap objects and register their *slot addresses* as explicit roots.
    const a_ptr = try alloc.create(u8);
    const b_ptr = try alloc.create(u8);
    state.root_a = a_ptr;
    state.root_b = b_ptr;
    state.roots.push(&state.root_a);
    state.roots.push(&state.root_b);

    var seen_epoch: u64 = 0;
    var i: u64 = 0;
    while (!handshake.stop_requested.load(.acquire)) {
        // Busy work.
        i += 1;
        if ((i & 0xFFFF) == 0) {
            state.iterations.store(i, .release);
        }

        // Pollcheck on a "loop backedge".
        handshake.pollcheck(state, &seen_epoch);
    }

    // Unregister roots and free memory.
    state.roots.pop(2);
    alloc.destroy(a_ptr);
    alloc.destroy(b_ptr);
}

pub fn main() !void {
    const thread_count: u32 = 4;

    var handshake = Handshake{
        .thread_count = thread_count,
        .cb = &perThreadStopCallback,
    };

    var states: [thread_count]ThreadState = undefined;
    var threads: [thread_count]std.Thread = undefined;

    for (&states, 0..) |*st, idx| {
        st.* = .{ .id = idx };
    }

    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, workerMain, .{ &handshake, &states[idx] });
    }

    // Give threads a moment to start.
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Request a few stop-the-world handshakes and observe how quickly threads cooperate.
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const epoch = handshake.request();
        handshake.wait_all();
        std.debug.print("[handshake] all threads stopped at epoch={d}\n", .{epoch});
        handshake.release(epoch);
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    handshake.stop_requested.store(true, .release);

    // One final handshake to ensure all threads observe stop_requested at a pollcheck.
    const epoch = handshake.request();
    handshake.wait_all();
    handshake.release(epoch);

    for (threads) |t| t.join();

    std.debug.print("Done.\n", .{});

    // In the real runtime, threads have lifecycle management and the handshake is reused by GC.
}
