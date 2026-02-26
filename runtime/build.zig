const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xev_dep = b.dependency("libxev", .{ .target = target, .optimize = optimize });

    const handshake_exe = b.addExecutable(.{
        .name = "flix-spike-handshake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_handshake.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(handshake_exe);

    const xev_exe = b.addExecutable(.{
        .name = "flix-spike-xev-timer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_xev_timer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "xev", .module = xev_dep.module("xev") },
            },
        }),
    });
    b.installArtifact(xev_exe);

    const http_exe = b.addExecutable(.{
        .name = "flix-spike-xev-http-get",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_xev_http_get.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "xev", .module = xev_dep.module("xev") },
            },
        }),
    });
    b.installArtifact(http_exe);

    const http_wire_exe = b.addExecutable(.{
        .name = "flix-spike-xev-http-wire-v0",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_xev_http_wire_v0.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "xev", .module = xev_dep.module("xev") },
            },
        }),
    });
    b.installArtifact(http_wire_exe);

    const http_sys_exe = b.addExecutable(.{
        .name = "flix-spike-xev-http-syscall-v0",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_xev_http_syscall_v0.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "xev", .module = xev_dep.module("xev") },
            },
        }),
    });
    b.installArtifact(http_sys_exe);

    const run_handshake = b.addRunArtifact(handshake_exe);
    run_handshake.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_handshake.addArgs(args);
    const run_handshake_step = b.step("run-handshake", "Run the pollcheck/handshake spike");
    run_handshake_step.dependOn(&run_handshake.step);

    const run_xev = b.addRunArtifact(xev_exe);
    run_xev.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_xev.addArgs(args);
    const run_xev_step = b.step("run-xev-timer", "Run the libxev timer→resume spike");
    run_xev_step.dependOn(&run_xev.step);

    const run_http = b.addRunArtifact(http_exe);
    run_http.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_http.addArgs(args);
    const run_http_step = b.step("run-xev-http-get", "Run the libxev HTTP/1.1 GET spike");
    run_http_step.dependOn(&run_http.step);

    const run_http_wire = b.addRunArtifact(http_wire_exe);
    run_http_wire.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_http_wire.addArgs(args);
    const run_http_wire_step = b.step("run-xev-http-wire", "Run the HTTP wire-format v0 spike (over libxev)");
    run_http_wire_step.dependOn(&run_http_wire.step);

    const run_http_sys = b.addRunArtifact(http_sys_exe);
    run_http_sys.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_http_sys.addArgs(args);
    const run_http_sys_step = b.step("run-xev-http-syscall", "Run the v0 http_request syscall-style spike");
    run_http_sys_step.dependOn(&run_http_sys.step);
}
