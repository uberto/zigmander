const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-mc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));

    // Embed the build timestamp so the help screen can display it.
    const build_options = b.addOptions();
    var ts_buf: [32]u8 = undefined;
    build_options.addOption([]const u8, "build_timestamp",
        buildTimestamp(std.time.timestamp(), &ts_buf));
    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zig-mc");
    run_step.dependOn(&run_cmd.step);
}

/// Formats a Unix timestamp as "YYYY-MM-DD HH:MM UTC" into buf.
/// Called at build time so the result is embedded as a string literal.
fn buildTimestamp(ts: i64, buf: *[32]u8) []const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const yd  = epoch.getEpochDay().calculateYearDay();
    const md  = yd.calculateMonthDay();
    const ds  = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        yd.year,
        @intFromEnum(md.month),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    }) catch "unknown";
}
