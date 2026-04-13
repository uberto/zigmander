const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const Panel = @import("panel.zig").Panel;
const fs = @import("fs.zig");

// Color palette
const col_dir: vaxis.Color = .{ .index = 12 };
const col_sel: vaxis.Color = .{ .index = 3 };
const col_bar_fg: vaxis.Color = .{ .index = 0 };
const col_bar_bg: vaxis.Color = .{ .index = 6 };
const col_key_fg: vaxis.Color = .{ .index = 0 };
const col_key_bg: vaxis.Color = .{ .index = 15 };

pub fn draw(state: *const AppState, win: vaxis.Window) void {
    const w = win.width;
    const h = win.height;
    if (h < 3 or w < 10) return;

    const panel_h: u16 = h - 1;

    switch (state.split) {
        .vertical => drawVertical(state, win, panel_h, w),
        .horizontal => drawHorizontal(state, win, panel_h, w),
    }

    // Status bar (always at bottom)
    const bar_win = win.child(.{
        .x_off = 0,
        .y_off = @as(i17, @intCast(h - 1)),
        .width = w,
        .height = 1,
    });
    drawStatusBar(bar_win, state);

    // Modals on top of everything
    switch (state.modal) {
        .none => {},
        .confirm_delete => |path| drawConfirmModal(win, path),
        .mkdir_prompt => |*mp| drawInputModal(win, "New directory:", mp.text()),
        .rename_prompt => |*rp| drawInputModal(win, "Rename:", rp.prompt.text()),
        .help => drawHelpModal(win),
    }
}

fn drawVertical(state: *const AppState, win: vaxis.Window, panel_h: u16, w: u16) void {
    const half: u16 = w / 2;

    // Vertical divider
    var row: u16 = 0;
    while (row < panel_h) : (row += 1) {
        _ = win.print(
            &.{.{ .text = "│", .style = .{} }},
            .{ .row_offset = row, .col_offset = half, .wrap = .none },
        );
    }

    // Left panel
    if (half > 1) {
        const left_win = win.child(.{ .x_off = 0, .y_off = 0, .width = half, .height = panel_h });
        drawPanel(left_win, &state.panels[0], state.active == 0);
    }

    // Right panel
    const right_x: u16 = half + 1;
    const right_w: u16 = if (w > right_x) w - right_x else 0;
    if (right_w > 1) {
        const right_win = win.child(.{
            .x_off = right_x, .y_off = 0, .width = right_w, .height = panel_h,
        });
        drawPanel(right_win, &state.panels[1], state.active == 1);
    }
}

fn drawHorizontal(state: *const AppState, win: vaxis.Window, panel_h: u16, w: u16) void {
    const top_h: u16 = panel_h / 2;
    const div_y: u16 = top_h;
    const bot_y: u16 = div_y + 1;
    const bot_h: u16 = if (panel_h > bot_y) panel_h - bot_y else 0;

    // Horizontal divider
    var c: u16 = 0;
    while (c < w) : (c += 1) {
        _ = win.print(
            &.{.{ .text = "─", .style = .{} }},
            .{ .row_offset = div_y, .col_offset = c, .wrap = .none },
        );
    }

    // Top panel
    if (top_h > 1) {
        const top_win = win.child(.{ .x_off = 0, .y_off = 0, .width = w, .height = top_h });
        drawPanel(top_win, &state.panels[0], state.active == 0);
    }

    // Bottom panel
    if (bot_h > 1) {
        const bot_win = win.child(.{
            .x_off = 0, .y_off = @as(i17, @intCast(bot_y)), .width = w, .height = bot_h,
        });
        drawPanel(bot_win, &state.panels[1], state.active == 1);
    }
}

fn sortLabel(mode: fs.SortMode) []const u8 {
    return switch (mode) {
        .name_asc  => "",
        .name_desc => "N\u{2193}", // N↓
        .size_asc  => "S\u{2191}", // S↑
        .size_desc => "S\u{2193}", // S↓
    };
}

fn drawPanel(win: vaxis.Window, panel: *const Panel, active: bool) void {
    const pw = win.width;
    const ph = win.height;
    if (ph < 2 or pw < 4) return;

    const hdr_style: vaxis.Style = if (active)
        .{ .bold = true, .reverse = true }
    else
        .{ .fg = .{ .index = 8 } };

    const hdr_win = win.child(.{ .x_off = 0, .y_off = 0, .width = pw, .height = 1 });
    hdr_win.fill(.{ .style = hdr_style });

    // Right-side indicators: sort mode + hidden flag
    const sort_str = sortLabel(panel.sort_mode);
    const hidden_str: []const u8 = if (panel.show_hidden) "H" else "";
    // Each indicator is short; reserve up to 5 cols on the right
    const indicator_w: u16 = blk: {
        var n: u16 = 0;
        if (sort_str.len > 0) n += 3; // "N↓" = 2 display cols + 1 space
        if (hidden_str.len > 0) n += 1;
        break :blk n;
    };

    if (indicator_w > 0 and pw > indicator_w + 2) {
        var ic: u16 = pw - indicator_w;
        if (sort_str.len > 0) {
            _ = hdr_win.print(&.{.{ .text = sort_str, .style = hdr_style }},
                .{ .row_offset = 0, .col_offset = ic, .wrap = .none });
            ic += 3;
        }
        if (hidden_str.len > 0) {
            _ = hdr_win.print(&.{.{ .text = hidden_str, .style = hdr_style }},
                .{ .row_offset = 0, .col_offset = ic, .wrap = .none });
        }
    }

    // Path (truncated from left to fit, leaving room for indicators)
    const path_max: usize = if (pw > indicator_w + 3) pw - indicator_w - 2 else 0;
    const path = panel.path;
    const path_display: []const u8 = if (path.len > path_max and path_max > 0)
        path[path.len - path_max ..]
    else
        path;

    _ = hdr_win.print(
        &.{.{ .text = path_display, .style = hdr_style }},
        .{ .row_offset = 0, .col_offset = 1, .wrap = .none },
    );

    // Entry rows
    const entries_h: u16 = ph - 1;
    if (entries_h == 0) return;

    const entries_win = win.child(.{ .x_off = 0, .y_off = 1, .width = pw, .height = entries_h });

    const visible: usize = entries_win.height;
    const start = panel.scroll_offset;
    const end = @min(start + visible, panel.entries.len);

    const size_width: u16 = 6;

    for (start..end) |i| {
        const r: u16 = @intCast(i - start);
        const entry = &panel.entries[i];
        const is_cursor = (i == panel.cursor);
        const is_sel = panel.selections.contains(entry.name);

        const row_base_style: vaxis.Style = if (is_cursor)
            .{ .reverse = true }
        else if (is_sel)
            .{ .fg = col_sel }
        else
            .{};

        if (is_cursor) {
            const row_win = entries_win.child(.{
                .x_off = 0, .y_off = @as(i17, @intCast(r)), .width = pw, .height = 1,
            });
            row_win.fill(.{ .style = row_base_style });
        }

        const cur_str: []const u8 = if (is_cursor) ">" else " ";
        _ = entries_win.print(&.{.{ .text = cur_str, .style = row_base_style }},
            .{ .row_offset = r, .col_offset = 0, .wrap = .none });

        const sel_str: []const u8 = if (is_sel) "*" else " ";
        _ = entries_win.print(&.{.{ .text = sel_str, .style = row_base_style }},
            .{ .row_offset = r, .col_offset = 1, .wrap = .none });

        const name_style: vaxis.Style = if (is_cursor)
            .{ .reverse = true, .bold = entry.kind == .directory }
        else if (entry.kind == .directory)
            .{ .bold = true, .fg = col_dir }
        else if (is_sel)
            .{ .fg = col_sel }
        else
            .{};

        const name_start: u16 = 2;
        const name_max: usize = if (pw > name_start + size_width + 1)
            pw - name_start - size_width - 1
        else
            0;
        const name_trunc = entry.name[0..@min(entry.name.len, name_max)];
        _ = entries_win.print(&.{.{ .text = name_trunc, .style = name_style }},
            .{ .row_offset = r, .col_offset = name_start, .wrap = .none });

        var size_buf: [8]u8 = undefined;
        const size_text: []const u8 = if (entry.kind == .directory)
            "DIR"
        else
            fs.formatSize(entry.size, &size_buf);

        if (pw >= size_width) {
            const size_col: u16 = pw - size_width;
            _ = entries_win.print(&.{.{ .text = size_text, .style = row_base_style }},
                .{ .row_offset = r, .col_offset = size_col, .wrap = .none });
        }
    }
}

const bar_style: vaxis.Style = .{ .fg = col_bar_fg, .bg = col_bar_bg };
const key_style: vaxis.Style = .{ .fg = col_key_fg, .bg = col_key_bg, .bold = true };

fn drawStatusBar(win: vaxis.Window, state: *const AppState) void {
    win.fill(.{ .style = bar_style });

    if (state.status_msg) |msg| {
        _ = win.print(&.{.{ .text = msg, .style = bar_style }},
            .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
        return;
    }

    if (state.fn_mode) {
        _ = win.print(&.{
            .{ .text = "F5",    .style = key_style }, .{ .text = " Copy  ",     .style = bar_style },
            .{ .text = "F6",    .style = key_style }, .{ .text = " Move  ",     .style = bar_style },
            .{ .text = "F7",    .style = key_style }, .{ .text = " Mkdir  ",    .style = bar_style },
            .{ .text = "F8",    .style = key_style }, .{ .text = " Del  ",      .style = bar_style },
            .{ .text = "F10",   .style = key_style }, .{ .text = " Quit  ",     .style = bar_style },
            .{ .text = "Opt+F", .style = key_style }, .{ .text = " exit Fn",    .style = bar_style },
        }, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    } else {
        _ = win.print(&.{
            .{ .text = "C", .style = key_style }, .{ .text = "opy  ",    .style = bar_style },
            .{ .text = "M", .style = key_style }, .{ .text = "ove  ",    .style = bar_style },
            .{ .text = "R", .style = key_style }, .{ .text = "en  ",     .style = bar_style },
            .{ .text = "D", .style = key_style }, .{ .text = "el  ",     .style = bar_style },
            .{ .text = "N", .style = key_style }, .{ .text = "ew  ",     .style = bar_style },
            .{ .text = ".", .style = key_style }, .{ .text = "Hidden  ", .style = bar_style },
            .{ .text = "s", .style = key_style }, .{ .text = "Sort  ",   .style = bar_style },
            .{ .text = "|", .style = key_style }, .{ .text = "Split  ",  .style = bar_style },
            .{ .text = "?", .style = key_style }, .{ .text = " Help  ",  .style = bar_style },
            .{ .text = "Q", .style = key_style }, .{ .text = "uit",      .style = bar_style },
        }, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    }
}

fn drawConfirmModal(win: vaxis.Window, path: []const u8) void {
    const mw: u16 = @min(60, if (win.width > 8) win.width - 4 else 0);
    const mh: u16 = 5;
    if (mw < 20 or win.height < mh + 2) return;

    const mx: u16 = (win.width - mw) / 2;
    const my: u16 = (win.height - mh) / 2;

    const modal = win.child(.{
        .x_off = @as(i17, @intCast(mx)), .y_off = @as(i17, @intCast(my)),
        .width = mw, .height = mh,
    });
    modal.fill(.{ .style = .{ .reverse = true } });

    const inner = modal.child(.{ .x_off = 1, .y_off = 1, .width = mw - 2, .height = mh - 2 });
    inner.fill(.{ .style = .{} });

    _ = inner.print(&.{.{ .text = "Delete? (Enter=confirm  Esc=cancel)", .style = .{} }},
        .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

    const path_trunc = path[0..@min(path.len, @as(usize, inner.width))];
    _ = inner.print(&.{.{ .text = path_trunc, .style = .{ .bold = true } }},
        .{ .row_offset = 1, .col_offset = 0, .wrap = .none });
}

fn drawInputModal(win: vaxis.Window, title: []const u8, current_input: []const u8) void {
    const mw: u16 = @min(64, if (win.width > 8) win.width - 4 else 0);
    const mh: u16 = 6;
    if (mw < 20 or win.height < mh + 2) return;

    const mx: u16 = (win.width - mw) / 2;
    const my: u16 = (win.height - mh) / 2;

    const modal = win.child(.{
        .x_off = @as(i17, @intCast(mx)), .y_off = @as(i17, @intCast(my)),
        .width = mw, .height = mh,
    });
    modal.fill(.{ .style = .{ .reverse = true } });

    const inner = modal.child(.{ .x_off = 1, .y_off = 1, .width = mw - 2, .height = mh - 2 });
    inner.fill(.{ .style = .{} });

    _ = inner.print(&.{.{ .text = title, .style = .{ .bold = true } }},
        .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

    const input_win = inner.child(.{ .x_off = 0, .y_off = 2, .width = inner.width, .height = 1 });
    input_win.fill(.{ .style = .{ .reverse = true } });

    const input_trunc = current_input[0..@min(current_input.len, @as(usize, input_win.width))];
    _ = input_win.print(&.{.{ .text = input_trunc, .style = .{ .reverse = true } }},
        .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

    _ = inner.print(&.{.{ .text = "Enter=Confirm  Esc=Cancel", .style = .{ .fg = .{ .index = 8 } } }},
        .{ .row_offset = 3, .col_offset = 0, .wrap = .none });
}

fn drawHelpModal(win: vaxis.Window) void {
    const mw: u16 = @min(62, if (win.width > 4) win.width - 4 else 0);
    const mh: u16 = 28;
    if (mw < 40 or win.height < mh + 2) return;

    const mx: u16 = (win.width - mw) / 2;
    const my: u16 = if (win.height > mh + 2) (win.height - mh) / 2 else 1;

    const modal = win.child(.{
        .x_off = @as(i17, @intCast(mx)), .y_off = @as(i17, @intCast(my)),
        .width = mw, .height = mh,
    });
    modal.fill(.{ .style = .{ .reverse = true } });

    const inner = modal.child(.{ .x_off = 1, .y_off = 1, .width = mw - 2, .height = mh - 2 });
    inner.fill(.{ .style = .{} });

    const h_style: vaxis.Style = .{ .bold = true };
    const k_style: vaxis.Style = .{ .bold = true, .fg = .{ .index = 3 } };
    const d_style: vaxis.Style = .{};
    const dim: vaxis.Style = .{ .fg = .{ .index = 8 } };

    var r: u16 = 0;

    _ = inner.print(&.{.{ .text = "\u{2500}\u{2500} Keyboard Shortcuts \u{2500}\u{2500}", .style = h_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;

    _ = inner.print(&.{.{ .text = "NAVIGATION", .style = h_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  \u{2191}\u{2193}  j k    ", .style = k_style }, .{ .text = "Move cursor up / down", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  Enter \u{2192}  ", .style = k_style }, .{ .text = "Enter dir / copy path to clipboard", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  \u{2190}  Bksp  ", .style = k_style }, .{ .text = "Go to parent directory", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  Tab      ", .style = k_style }, .{ .text = "Switch active panel", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  Space    ", .style = k_style }, .{ .text = "Toggle selection", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;

    r += 1;
    _ = inner.print(&.{.{ .text = "FILE OPERATIONS  (Opt = Option key)", .style = h_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  Opt+C    ", .style = k_style }, .{ .text = "Copy to other panel", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  Opt+M    ", .style = k_style }, .{ .text = "Move to other panel", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  Opt+R    ", .style = k_style }, .{ .text = "Rename (pre-filled prompt)", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  Opt+D    ", .style = k_style }, .{ .text = "Delete with confirmation", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  Opt+N    ", .style = k_style }, .{ .text = "New directory", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;

    r += 1;
    _ = inner.print(&.{.{ .text = "VIEW", .style = h_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  .        ", .style = k_style }, .{ .text = "Show/hide hidden files", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  s        ", .style = k_style }, .{ .text = "Cycle sort: name\u{2191} \u{2192} name\u{2193} \u{2192} size\u{2193} \u{2192} size\u{2191}", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  |        ", .style = k_style }, .{ .text = "Toggle vertical / horizontal split", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;

    r += 1;
    _ = inner.print(&.{.{ .text = "APP", .style = h_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  Opt+F    ", .style = k_style }, .{ .text = "Toggle Fn-key mode", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  Opt+Q    ", .style = k_style }, .{ .text = "Quit", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  ?        ", .style = k_style }, .{ .text = "This help screen", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;

    r += 1;
    _ = inner.print(&.{.{ .text = "FN MODE  (Opt+F to enable)", .style = h_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  F5 Copy  F6 Move  F7 Mkdir  F8 Del  F10 Quit", .style = k_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;

    _ = inner.print(&.{.{ .text = "Press any key to close", .style = dim }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none });
}
