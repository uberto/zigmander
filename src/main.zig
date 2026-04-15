const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("app.zig");
const input_mod = @import("input.zig");
const render = @import("render.zig");
const panel_mod = @import("panel.zig");
const fs = @import("fs.zig");

const AppState = app_mod.AppState;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --dump [path]        : plain-text table of entry data (no TUI)
    // --dump-render [path] : text-buffer simulation of what the TUI panel renders
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args[1..], 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--dump")) {
            const path = if (i + 1 < args[1..].len) args[1..][i + 1]
                         else try std.process.getCwdAlloc(allocator);
            try dumpPanel(allocator, path);
            return;
        }
        if (std.mem.eql(u8, arg, "--dump-render")) {
            const path = if (i + 1 < args[1..].len) args[1..][i + 1]
                         else try std.process.getCwdAlloc(allocator);
            try dumpRender(allocator, path);
            return;
        }
    }

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminalSend(tty.writer());

    var state = try AppState.init(allocator);
    defer state.deinit();

    var term_height: usize = 24;

    while (true) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                const in_modal = state.isInModal();
                const action = input_mod.keyToAction(key, state.fn_mode, in_modal) orelse continue;

                const visible_rows: usize = if (term_height > 2) term_height - 2 else 1;
                const result = state.apply(action, visible_rows);

                if (result == .quit) break;
            },

            .winsize => |ws| {
                try vx.resize(allocator, tty.writer(), ws);
                term_height = ws.rows;
                const visible: usize = if (term_height > 2) term_height - 2 else 1;
                for (&state.panels) |*p| p.updateScroll(visible);
            },
        }

        renderFrame(&vx, &tty, &state);
    }
}

fn renderFrame(vx: *vaxis.Vaxis, tty: *vaxis.Tty, state: *const AppState) void {
    const win = vx.window();
    win.clear();
    render.draw(state, win);
    vx.render(tty.writer()) catch {};
}

// ── --dump mode ────────────────────────────────────────────────────────────

/// Prints a plain-text columnar listing of `path` with all optional columns
/// (permissions, mtime, btime, size) to stdout, then exits.  No TUI involved.
fn dumpPanel(allocator: std.mem.Allocator, path: []const u8) !void {
    var panel = try panel_mod.Panel.init(allocator, path);
    defer panel.deinit();

    panel.show_permissions = true;
    panel.show_mtime       = true;
    panel.show_btime       = true;

    var out_buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&out_buf);
    const stdout = &fw.interface;
    defer stdout.flush() catch {};

    const sep = "─" ** 80;

    try stdout.print("Path: {s}\n", .{panel.path});
    try stdout.print("{s}\n", .{sep});
    try stdout.print("{s:<32} {s:<4}  {s:<9}  {s:<10}  {s:<10}  {s:>10}\n",
        .{ "Name", "Type", "Perms", "Modified", "Created", "Size" });
    try stdout.print("{s}\n", .{sep});

    for (panel.entries) |entry| {
        const kind_str: []const u8 = switch (entry.kind) {
            .directory => "DIR",
            .file      => "file",
            .other     => "othr",
        };

        var perm_buf: [9]u8 = undefined;
        const perm = fs.formatPermissions(entry.mode, &perm_buf);

        var mtime_buf: [10]u8 = undefined;
        const mtime = fs.formatDate(entry.mtime, &mtime_buf);

        var btime_buf: [10]u8 = undefined;
        const btime = fs.formatDate(entry.btime, &btime_buf);

        var size_buf: [20]u8 = undefined;
        const size_str: []const u8 = if (entry.kind == .file)
            std.fmt.bufPrint(&size_buf, "{d}", .{entry.size}) catch "?"
        else
            "";

        const name = entry.name;
        const name_trunc = name[0..@min(name.len, 32)];

        try stdout.print("{s:<32} {s:<4}  {s}  {s}  {s}  {s:>10}\n",
            .{ name_trunc, kind_str, perm, mtime, btime, size_str });
    }
    try stdout.print("{s}\n", .{sep});
    try stdout.print("{d} entries\n", .{panel.entries.len});
}

// ── --dump-render mode ─────────────────────────────────────────────────────

/// Simulates what the TUI panel renders by placing text in a char array at the
/// exact column positions computed by computeLayout, then prints each row.
/// All optional columns enabled; width defaults to 80.
fn dumpRender(allocator: std.mem.Allocator, path: []const u8) !void {
    const render_mod = @import("render.zig");

    var panel = try panel_mod.Panel.init(allocator, path);
    defer panel.deinit();
    panel.show_permissions = true;
    panel.show_mtime       = true;
    panel.show_btime       = true;

    var out_buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&out_buf);
    const stdout = &fw.interface;
    defer stdout.flush() catch {};

    const pw: u16 = 75;
    const layout = render_mod.computeLayoutPub(pw, &panel);

    try stdout.print("pw={d}  name_w={d}  type_col={d}  perm_col={d}  btime_col={d}  mtime_col={d}  size_w={d}\n",
        .{ layout.pw, layout.name_w, layout.type_col, layout.perm_col,
           layout.btime_col, layout.mtime_col, layout.size_w });
    try stdout.print("{s}\n", .{"─" ** 80});

    var row_buf: [256]u8 = undefined;

    for (panel.entries) |*entry| {
        @memset(&row_buf, ' ');

        // cursor marker
        row_buf[0] = ' ';
        row_buf[1] = ' ';

        // name
        var name_tmp: [256]u8 = undefined;
        const name_str = render_mod.truncatedNamePub(&name_tmp, entry.name, layout.name_w);
        const name_len = @min(name_str.len, @as(usize, layout.name_w));
        @memcpy(row_buf[2..][0..name_len], name_str[0..name_len]);

        // type
        if (layout.type_col > 0 and layout.type_col < pw) {
            var tb: [4]u8 = undefined;
            const ts = render_mod.entryTypeLabelPub(&tb, entry);
            const tl = @min(ts.len, 4);
            @memcpy(row_buf[layout.type_col..][0..tl], ts[0..tl]);
        }

        // permissions
        if (layout.perm_col > 0 and layout.perm_col + 9 <= pw) {
            var pb: [9]u8 = undefined;
            const ps = fs.formatPermissions(entry.mode, &pb);
            @memcpy(row_buf[layout.perm_col..][0..9], ps[0..9]);
        }

        // btime
        if (layout.btime_col > 0 and layout.btime_col + 10 <= pw) {
            var db: [10]u8 = undefined;
            const ds = fs.formatDate(entry.btime, &db);
            @memcpy(row_buf[layout.btime_col..][0..10], ds[0..10]);
        }

        // mtime
        if (layout.mtime_col > 0 and layout.mtime_col + 10 <= pw) {
            var db: [10]u8 = undefined;
            const ds = fs.formatDate(entry.mtime, &db);
            @memcpy(row_buf[layout.mtime_col..][0..10], ds[0..10]);
        }

        // size (right-aligned)
        if (layout.size_w > 0 and entry.kind != .directory) {
            var sb: [20]u8 = undefined;
            const raw = fs.formatSize(entry.size, &sb);
            const tl = @min(raw.len, @as(usize, layout.size_w));
            const col = @as(usize, pw) - tl;
            @memcpy(row_buf[col..][0..tl], raw[0..tl]);
        }

        try stdout.print("{s}\n", .{row_buf[0..pw]});
    }
}
