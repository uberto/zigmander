const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("app.zig");
const input_mod = @import("input.zig");
const render = @import("render.zig");

const AppState = app_mod.AppState;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
