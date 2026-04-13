const std = @import("std");
const Panel = @import("panel.zig").Panel;
const fs = @import("fs.zig");
const input = @import("input.zig");

pub const SplitMode = enum { vertical, horizontal };

pub const TextPrompt = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const TextPrompt) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn appendChar(self: *TextPrompt, c: u8) void {
        if (self.len < self.buf.len - 1) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    pub fn backspace(self: *TextPrompt) void {
        if (self.len > 0) self.len -= 1;
    }
};

pub const Modal = union(enum) {
    none,
    confirm_delete: []u8,
    mkdir_prompt: TextPrompt,
    rename_prompt: struct {
        prompt: TextPrompt,
        src: []u8,
    },
    help,
};

pub const ApplyResult = enum { none, quit };

pub const AppState = struct {
    allocator: std.mem.Allocator,
    panels: [2]Panel,
    active: u1,
    modal: Modal,
    fn_mode: bool,
    split: SplitMode,
    status_msg: ?[]u8,

    pub fn init(allocator: std.mem.Allocator) !AppState {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        var left = try Panel.init(allocator, home);
        errdefer left.deinit();
        var right = try Panel.init(allocator, home);
        errdefer right.deinit();

        return .{
            .allocator = allocator,
            .panels = .{ left, right },
            .active = 0,
            .modal = .none,
            .fn_mode = false,
            .split = .vertical,
            .status_msg = null,
        };
    }

    pub fn deinit(self: *AppState) void {
        self.panels[0].deinit();
        self.panels[1].deinit();
        if (self.status_msg) |msg| self.allocator.free(msg);
        self.freeModal();
    }

    fn freeModal(self: *AppState) void {
        switch (self.modal) {
            .none, .mkdir_prompt, .help => {},
            .confirm_delete => |path| self.allocator.free(path),
            .rename_prompt => |rp| self.allocator.free(rp.src),
        }
    }

    pub fn activePanel(self: *AppState) *Panel {
        return &self.panels[self.active];
    }

    pub fn inactivePanel(self: *AppState) *Panel {
        return &self.panels[self.active ^ 1];
    }

    pub fn isInModal(self: *const AppState) bool {
        return switch (self.modal) {
            .none => false,
            else => true,
        };
    }

    pub fn setStatusMsg(self: *AppState, comptime fmt: []const u8, args: anytype) void {
        if (self.status_msg) |msg| self.allocator.free(msg);
        self.status_msg = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
    }

    fn clearStatusMsg(self: *AppState) void {
        if (self.status_msg) |msg| {
            self.allocator.free(msg);
            self.status_msg = null;
        }
    }

    pub fn apply(self: *AppState, action: input.Action, visible_rows: usize) ApplyResult {
        self.clearStatusMsg();

        if (self.isInModal()) {
            self.applyModal(action);
            return .none;
        }

        const panel = self.activePanel();

        switch (action) {
            .cursor_up => panel.moveCursor(-1, visible_rows),
            .cursor_down => panel.moveCursor(1, visible_rows),

            .enter => {
                const entry = panel.currentEntry() orelse return .none;
                if (entry.kind == .directory) {
                    panel.enter() catch |err| {
                        self.setStatusMsg("Cannot enter: {s}", .{@errorName(err)});
                    };
                } else {
                    // Copy full path to clipboard instead of opening editor
                    const full_path = std.fs.path.join(
                        self.allocator,
                        &.{ panel.path, entry.name },
                    ) catch {
                        self.setStatusMsg("Error building path", .{});
                        return .none;
                    };
                    defer self.allocator.free(full_path);
                    copyPathToClipboard(self.allocator, full_path) catch |err| {
                        self.setStatusMsg("Clipboard error: {s}", .{@errorName(err)});
                        return .none;
                    };
                    self.setStatusMsg("Copied path: {s}", .{entry.name});
                }
            },

            .go_parent => {
                panel.goParent() catch |err| {
                    self.setStatusMsg("Cannot go up: {s}", .{@errorName(err)});
                };
            },

            .switch_panel => self.active ^= 1,

            .toggle_select => {
                panel.toggleSelection() catch |err| {
                    self.setStatusMsg("Selection error: {s}", .{@errorName(err)});
                };
            },

            .copy => {
                const paths = panel.selectedPaths() catch |err| {
                    self.setStatusMsg("Copy failed: {s}", .{@errorName(err)});
                    return .none;
                };
                defer {
                    for (paths) |p| self.allocator.free(p);
                    self.allocator.free(paths);
                }
                const dest = self.inactivePanel().path;
                var copied: usize = 0;
                for (paths) |p| {
                    fs.copyEntry(self.allocator, p, dest) catch |err| {
                        self.setStatusMsg("Copy failed: {s}", .{@errorName(err)});
                        return .none;
                    };
                    copied += 1;
                }
                panel.clearSelections();
                self.inactivePanel().reload();
                self.setStatusMsg("Copied {d} item(s) to {s}", .{ copied, dest });
            },

            .move => {
                const paths = panel.selectedPaths() catch |err| {
                    self.setStatusMsg("Move failed: {s}", .{@errorName(err)});
                    return .none;
                };
                defer {
                    for (paths) |p| self.allocator.free(p);
                    self.allocator.free(paths);
                }
                const dest = self.inactivePanel().path;
                var moved: usize = 0;
                for (paths) |p| {
                    fs.moveEntry(self.allocator, p, dest) catch |err| {
                        self.setStatusMsg("Move failed: {s}", .{@errorName(err)});
                        return .none;
                    };
                    moved += 1;
                }
                panel.clearSelections();
                panel.reload();
                self.inactivePanel().reload();
                self.setStatusMsg("Moved {d} item(s) to {s}", .{ moved, dest });
            },

            .rename => {
                const entry = panel.currentEntry() orelse return .none;
                const src = std.fs.path.join(
                    self.allocator,
                    &.{ panel.path, entry.name },
                ) catch |err| {
                    self.setStatusMsg("Error: {s}", .{@errorName(err)});
                    return .none;
                };
                var prompt = TextPrompt{};
                const copy_len = @min(entry.name.len, prompt.buf.len - 1);
                @memcpy(prompt.buf[0..copy_len], entry.name[0..copy_len]);
                prompt.len = copy_len;
                self.freeModal();
                self.modal = .{ .rename_prompt = .{ .prompt = prompt, .src = src } };
            },

            .delete => {
                const entry = panel.currentEntry() orelse return .none;
                const path = std.fs.path.join(
                    self.allocator,
                    &.{ panel.path, entry.name },
                ) catch |err| {
                    self.setStatusMsg("Error: {s}", .{@errorName(err)});
                    return .none;
                };
                self.freeModal();
                self.modal = .{ .confirm_delete = path };
            },

            .mkdir => {
                self.freeModal();
                self.modal = .{ .mkdir_prompt = .{} };
            },

            .toggle_hidden => {
                panel.toggleHidden();
                const label: []const u8 = if (panel.show_hidden) "shown" else "hidden";
                self.setStatusMsg("Hidden files: {s}", .{label});
            },

            .cycle_sort => {
                panel.cycleSortMode();
                const label: []const u8 = switch (panel.sort_mode) {
                    .name_asc  => "name A→Z",
                    .name_desc => "name Z→A",
                    .size_asc  => "size small→large",
                    .size_desc => "size large→small",
                };
                self.setStatusMsg("Sort: {s}", .{label});
            },

            .toggle_split => {
                self.split = if (self.split == .vertical) .horizontal else .vertical;
                const label: []const u8 = if (self.split == .vertical) "vertical" else "horizontal";
                self.setStatusMsg("Split: {s}", .{label});
            },

            .toggle_fn_mode => self.fn_mode = !self.fn_mode,

            .show_help => {
                self.freeModal();
                self.modal = .help;
            },

            .quit => return .quit,

            .modal_confirm, .modal_cancel, .modal_backspace => {},
            .modal_char => |_| {},
        }

        return .none;
    }

    fn applyModal(self: *AppState, action: input.Action) void {
        switch (self.modal) {
            .none => {},

            .confirm_delete => |path| {
                switch (action) {
                    .modal_confirm => {
                        self.modal = .none;
                        fs.deleteEntry(self.allocator, path) catch |err| {
                            self.setStatusMsg("Delete failed: {s}", .{@errorName(err)});
                        };
                        self.allocator.free(path);
                        self.activePanel().reload();
                    },
                    .modal_cancel => {
                        self.modal = .none;
                        self.allocator.free(path);
                    },
                    else => {},
                }
            },

            .mkdir_prompt => |*mp| {
                switch (action) {
                    .modal_confirm => {
                        var name_buf: [256]u8 = undefined;
                        const name_len = @min(mp.len, name_buf.len);
                        @memcpy(name_buf[0..name_len], mp.buf[0..name_len]);
                        const name = name_buf[0..name_len];
                        self.modal = .none;
                        if (name.len > 0) {
                            fs.makeDir(self.allocator, self.activePanel().path, name) catch |err| {
                                self.setStatusMsg("mkdir failed: {s}", .{@errorName(err)});
                            };
                            self.activePanel().reload();
                        }
                    },
                    .modal_cancel => self.modal = .none,
                    .modal_char => |c| mp.appendChar(c),
                    .modal_backspace => mp.backspace(),
                    else => {},
                }
            },

            .rename_prompt => |*rp| {
                switch (action) {
                    .modal_confirm => {
                        var name_buf: [256]u8 = undefined;
                        const name_len = @min(rp.prompt.len, name_buf.len);
                        @memcpy(name_buf[0..name_len], rp.prompt.buf[0..name_len]);
                        const new_name = name_buf[0..name_len];
                        const src = rp.src;
                        self.modal = .none;
                        if (new_name.len > 0) {
                            fs.renameEntry(self.allocator, src, new_name) catch |err| {
                                self.setStatusMsg("Rename failed: {s}", .{@errorName(err)});
                            };
                            self.activePanel().reload();
                        }
                        self.allocator.free(src);
                    },
                    .modal_cancel => {
                        const src = rp.src;
                        self.modal = .none;
                        self.allocator.free(src);
                    },
                    .modal_char => |c| rp.prompt.appendChar(c),
                    .modal_backspace => rp.prompt.backspace(),
                    else => {},
                }
            },

            // Any key closes help
            .help => self.modal = .none,
        }
    }
};

fn copyPathToClipboard(allocator: std.mem.Allocator, path: []const u8) !void {
    var child = std.process.Child.init(&.{"pbcopy"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    if (child.stdin) |stdin| {
        _ = stdin.write(path) catch {};
        stdin.close();
        child.stdin = null;
    }
    _ = try child.wait();
}
