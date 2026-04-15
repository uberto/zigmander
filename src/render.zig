const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const panel_mod = @import("panel.zig");
const Panel = panel_mod.Panel;
const SizeDisplay = panel_mod.SizeDisplay;
const fs = @import("fs.zig");

// ── Frame scratch buffer ───────────────────────────────────────────────────
//
// vaxis stores Cell.Character.grapheme as a []const u8 *pointer* (not a copy).
// Strings formatted into stack-local buffers inside drawEntryRow become
// dangling once the function returns, and vx.render() — called after draw()
// completes — then reads garbage from those freed stack frames.
//
// Fix: copy every formatted string into this module-level buffer before
// passing it to win.print.  The buffer lives for the lifetime of the program
// and is simply reset to position 0 at the start of each draw() call.
var frame_scratch: [65536]u8 = undefined;
var frame_pos: usize = 0;

/// Copies `s` into the frame scratch buffer and returns the stable slice.
/// Returns the original slice unchanged for empty strings (no copy needed).
fn frameDupe(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const start = frame_pos;
    @memcpy(frame_scratch[start..][0..s.len], s);
    frame_pos += s.len;
    return frame_scratch[start..frame_pos];
}

// Color palette
const col_dir: vaxis.Color = .{ .index = 12 };
const col_sel: vaxis.Color = .{ .index = 3 };
const col_bar_fg: vaxis.Color = .{ .index = 0 };
const col_bar_bg: vaxis.Color = .{ .index = 6 };
const col_key_fg: vaxis.Color = .{ .index = 0 };
const col_key_bg: vaxis.Color = .{ .index = 15 };

pub fn draw(state: *const AppState, win: vaxis.Window) void {
    frame_pos = 0; // reclaim scratch space from the previous frame
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

    drawPanelHeader(win, panel, active, pw);

    const entries_h: u16 = ph - 1;
    if (entries_h == 0) return;
    const entries_win = win.child(.{ .x_off = 0, .y_off = 1, .width = pw, .height = entries_h });
    drawPanelEntries(entries_win, panel, pw);
}

fn drawPanelHeader(win: vaxis.Window, panel: *const Panel, active: bool, pw: u16) void {
    const hdr_style: vaxis.Style = if (active)
        .{ .bold = true, .reverse = true }
    else
        .{ .fg = .{ .index = 8 } };

    const hdr_win = win.child(.{ .x_off = 0, .y_off = 0, .width = pw, .height = 1 });
    hdr_win.fill(.{ .style = hdr_style });

    // Right-side indicators: sort label + single chars for active view options
    const sort_str = sortLabel(panel.sort_mode);
    const indicators = [_][]const u8{
        if (panel.show_hidden)            "H" else "",
        if (panel.size_display == .bytes) "B" else "",
        if (panel.show_permissions)       "P" else "",
        if (panel.show_mtime)             "M" else "",
        if (panel.show_btime)             "C" else "",
    };
    var indicator_w: u16 = 0;
    if (sort_str.len > 0) indicator_w += 3; // "N↓" = 2 cols + 1 space
    for (indicators) |s| if (s.len > 0) { indicator_w += 1; };

    if (indicator_w > 0 and pw > indicator_w + 2) {
        var ic: u16 = pw - indicator_w;
        if (sort_str.len > 0) {
            _ = hdr_win.print(&.{.{ .text = sort_str, .style = hdr_style }},
                .{ .row_offset = 0, .col_offset = ic, .wrap = .none });
            ic += 3;
        }
        for (indicators) |s| {
            if (s.len > 0) {
                _ = hdr_win.print(&.{.{ .text = s, .style = hdr_style }},
                    .{ .row_offset = 0, .col_offset = ic, .wrap = .none });
                ic += 1;
            }
        }
    }

    // Path truncated from the left to fit
    const path_max: usize = if (pw > indicator_w + 3) pw - indicator_w - 2 else 0;
    const path = panel.path;
    const path_display: []const u8 = if (path.len > path_max and path_max > 0)
        path[path.len - path_max ..]
    else
        path;
    _ = hdr_win.print(&.{.{ .text = path_display, .style = hdr_style }},
        .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
}

// ── Column layout ─────────────────────────────────────────────────────────
//
//   col 0-1    "> *"           cursor and selection markers (always 2 cols)
//   col 2..    name            filename, auto-sized to fill remaining space
//   type slot  " DIR"/" .zig"  1 leading space + up to 4 chars = 5 cols total
//   perm slot  " rwxrwxrwx"   1 leading space + 9 chars = 10 cols (optional, p key)
//   size slot  right-aligned   6 cols (abbrev) or 11 cols (bytes) (optional, b key)
//
// All right-side slots are reserved from the right edge; only name_w changes.

const type_w: u16 = 5; // 1 leading space + 4 chars text

/// Precomputed column positions for one panel render pass.
const Layout = struct {
    name_w:    u16, // max chars for filename (name starts at col 2)
    type_col:  u16, // column where type text starts (after leading space)
    perm_col:  u16, // column where perm text starts  (0 = not shown)
    mtime_col: u16, // column where mtime text starts (0 = not shown)
    btime_col: u16, // column where btime text starts (0 = not shown)
    size_w:    u16, // 0, 6, or 11
    pw:        u16, // panel width (used for size right-alignment)
};

/// Public wrapper for --dump-render mode in main.zig.
pub fn computeLayoutPub(pw: u16, panel: *const Panel) Layout { return computeLayout(pw, panel); }
pub fn truncatedNamePub(buf: []u8, name: []const u8, max_len: usize) []const u8 { return truncatedName(buf, name, max_len); }
pub fn entryTypeLabelPub(buf: *[4]u8, entry: *const fs.Entry) []const u8 { return entryTypeLabel(buf, entry); }

/// Derives all column positions from panel settings and panel width.
/// Columns are reserved right-to-left: size | mtime | btime | perm | type | name
fn computeLayout(pw: u16, panel: *const Panel) Layout {
    const size_w:  u16 = switch (panel.size_display) {
        .none   => 0,
        .abbrev => 6,
        .bytes  => 11,
    };
    const mtime_w: u16 = if (panel.show_mtime) 11 else 0; // 1 space + "YYYY-MM-DD"
    const btime_w: u16 = if (panel.show_btime) 11 else 0;
    const perm_w:  u16 = if (panel.show_permissions) 10 else 0; // 1 space + "rwxrwxrwx"
    const right_w: u16 = type_w + perm_w + btime_w + mtime_w + size_w;

    const name_w: u16 = if (pw > right_w + 2) pw - right_w - 2 else 0;

    // Each column's text start = pw - (sum of cols to its right) + 1  (skips leading space)
    // A value of 0 means the column is not shown.
    const type_col:  u16 = col1(pw, right_w);
    const perm_col:  u16 = if (perm_w  > 0) col1(pw, perm_w  + btime_w + mtime_w + size_w) else 0;
    const btime_col: u16 = if (btime_w > 0) col1(pw, btime_w + mtime_w + size_w) else 0;
    const mtime_col: u16 = if (mtime_w > 0) col1(pw, mtime_w + size_w) else 0;

    return .{ .name_w = name_w, .type_col = type_col, .perm_col = perm_col,
              .mtime_col = mtime_col, .btime_col = btime_col, .size_w = size_w, .pw = pw };
}

/// Returns the text-start column for a slot that occupies the rightmost `slot_w` cols.
/// Skips 1 leading space so text appears 1 col into the slot.
/// Returns 0 when the slot doesn't fit.
inline fn col1(pw: u16, slot_w: u16) u16 {
    return if (pw > slot_w) pw - slot_w + 1 else 0;
}

fn drawPanelEntries(entries_win: vaxis.Window, panel: *const Panel, pw: u16) void {
    const layout = computeLayout(pw, panel);
    const visible: usize = entries_win.height;
    const start = panel.scroll_offset;
    const end = @min(start + visible, panel.entries.len);
    for (start..end) |i| {
        drawEntryRow(entries_win, panel, &panel.entries[i], i, @intCast(i - start), layout);
    }
}

fn drawEntryRow(
    win: vaxis.Window,
    panel: *const Panel,
    entry: *const fs.Entry,
    idx: usize,
    row: u16,
    layout: Layout,
) void {
    const is_cursor = (idx == panel.cursor);
    const is_sel    = panel.selections.contains(entry.name);

    const row_style: vaxis.Style = if (is_cursor) .{ .reverse = true }
                                   else if (is_sel) .{ .fg = col_sel }
                                   else .{};

    if (is_cursor) {
        const row_win = win.child(.{
            .x_off = 0, .y_off = @as(i17, @intCast(row)), .width = layout.pw, .height = 1,
        });
        row_win.fill(.{ .style = row_style });
    }

    // Cursor and selection markers at cols 0–1
    _ = win.print(&.{.{ .text = if (is_cursor) ">" else " ", .style = row_style }},
        .{ .row_offset = row, .col_offset = 0, .wrap = .none });
    _ = win.print(&.{.{ .text = if (is_sel) "*" else " ", .style = row_style }},
        .{ .row_offset = row, .col_offset = 1, .wrap = .none });

    // Filename — truncated with extension preserved
    const name_style: vaxis.Style = if (is_cursor)
        .{ .reverse = true, .bold = entry.kind == .directory }
    else if (entry.kind == .directory)
        .{ .bold = true, .fg = col_dir }
    else if (is_sel)
        .{ .fg = col_sel }
    else .{};
    var name_buf: [256]u8 = undefined;
    _ = win.print(&.{.{ .text = frameDupe(truncatedName(&name_buf, entry.name, layout.name_w)), .style = name_style }},
        .{ .row_offset = row, .col_offset = 2, .wrap = .none });

    // Type column — ALWAYS shown: "DIR" for directories, file extension for files
    if (layout.type_col > 0) {
        var type_buf: [4]u8 = undefined;
        const type_str = frameDupe(entryTypeLabel(&type_buf, entry));
        _ = win.print(&.{.{ .text = type_str, .style = row_style }},
            .{ .row_offset = row, .col_offset = layout.type_col, .wrap = .none });
    }

    // Permissions column — optional (p key)
    if (layout.perm_col > 0) {
        var perm_buf: [9]u8 = undefined;
        const perm_str = frameDupe(fs.formatPermissions(entry.mode, &perm_buf));
        _ = win.print(&.{.{ .text = perm_str, .style = row_style }},
            .{ .row_offset = row, .col_offset = layout.perm_col, .wrap = .none });
    }

    // Modified-date column — optional (m key)
    if (layout.mtime_col > 0) {
        var date_buf: [10]u8 = undefined;
        const date_str = frameDupe(fs.formatDate(entry.mtime, &date_buf));
        _ = win.print(&.{.{ .text = date_str, .style = row_style }},
            .{ .row_offset = row, .col_offset = layout.mtime_col, .wrap = .none });
    }

    // Birth-date column — optional (c key)
    if (layout.btime_col > 0) {
        var date_buf: [10]u8 = undefined;
        const date_str = frameDupe(fs.formatDate(entry.btime, &date_buf));
        _ = win.print(&.{.{ .text = date_str, .style = row_style }},
            .{ .row_offset = row, .col_offset = layout.btime_col, .wrap = .none });
    }

    // Size column — optional (b key), files only, right-aligned within its slot
    if (layout.size_w > 0 and entry.kind != .directory) {
        var size_buf: [20]u8 = undefined;
        const raw: []const u8 = frameDupe(switch (panel.size_display) {
            .abbrev => fs.formatSize(entry.size, &size_buf),
            .bytes  => std.fmt.bufPrint(&size_buf, "{d}", .{entry.size}) catch "?",
            .none   => unreachable,
        });
        const text = raw[0..@min(raw.len, @as(usize, layout.size_w))];
        const col = layout.pw - @as(u16, @intCast(text.len));
        _ = win.print(&.{.{ .text = text, .style = row_style }},
            .{ .row_offset = row, .col_offset = col, .wrap = .none });
    }
}

/// Returns the type label for the type column:
/// "DIR" for directories, the extension without dot for files ("zig", "md", …).
fn entryTypeLabel(buf: *[4]u8, entry: *const fs.Entry) []const u8 {
    if (entry.kind == .directory) return "DIR";
    const ext = std.fs.path.extension(entry.name); // e.g. ".zig"
    if (ext.len > 1) {
        const raw = ext[1..]; // strip leading '.'
        const len = @min(raw.len, 4);
        @memcpy(buf[0..len], raw[0..len]);
        return buf[0..len];
    }
    return "";
}

/// Truncates `name` to at most `max_len` bytes, always keeping the extension visible.
/// Example: "verylongname.zig" → "verylongn.zig" (not "verylongname")
fn truncatedName(buf: []u8, name: []const u8, max_len: usize) []const u8 {
    if (name.len <= max_len or max_len == 0) return name[0..@min(name.len, max_len)];
    // Preserve extension: find last '.' and keep everything from there
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (dot > 0) {
            const ext = name[dot..]; // includes '.'
            if (ext.len < max_len) {
                const prefix_len = max_len - ext.len;
                @memcpy(buf[0..prefix_len], name[0..prefix_len]);
                @memcpy(buf[prefix_len..max_len], ext);
                return buf[0..max_len];
            }
        }
    }
    return name[0..max_len]; // no extension or ext too long: plain truncation
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
            .{ .text = "b", .style = key_style }, .{ .text = "Size  ",   .style = bar_style },
            .{ .text = "p", .style = key_style }, .{ .text = "Perm  ",   .style = bar_style },
            .{ .text = "m", .style = key_style }, .{ .text = "Mod  ",    .style = bar_style },
            .{ .text = "c", .style = key_style }, .{ .text = "Created  ", .style = bar_style },
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
    const mh: u16 = 32;
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
    _ = inner.print(&.{.{ .text = "  b        ", .style = k_style }, .{ .text = "Cycle size: abbrev \u{2192} bytes \u{2192} hidden", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  p        ", .style = k_style }, .{ .text = "Toggle permissions column (rwxr-xr-x)", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  m        ", .style = k_style }, .{ .text = "Toggle modified-date column", .style = d_style }},
        .{ .row_offset = r, .col_offset = 0, .wrap = .none }); r += 1;
    _ = inner.print(&.{.{ .text = "  c        ", .style = k_style }, .{ .text = "Toggle created-date column", .style = d_style }},
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
