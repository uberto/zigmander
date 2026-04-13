const std = @import("std");
const Panel = @import("panel.zig").Panel;
const fs = @import("fs.zig");
const input = @import("input.zig");

pub const SplitMode = enum { vertical, horizontal };

pub const TextPrompt = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    /// Returns the current text content of the prompt.
    pub fn text(self: *const TextPrompt) []const u8 {
        return self.buf[0..self.len];
    }

    /// Appends a single ASCII character (ignored if buffer is full).
    pub fn appendChar(self: *TextPrompt, c: u8) void {
        if (self.len < self.buf.len - 1) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    /// Removes the last character (no-op if empty).
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

    /// Releases any heap memory owned by the current modal.
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

    /// Allocates and stores a formatted status message, replacing any previous one.
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

    /// Dispatches an action to the appropriate handler.
    /// Returns .quit if the app should exit.
    pub fn apply(self: *AppState, action: input.Action, visible_rows: usize) ApplyResult {
        self.clearStatusMsg();

        if (self.isInModal()) {
            self.applyModal(action);
            return .none;
        }

        const panel = self.activePanel();

        switch (action) {
            .cursor_up        => panel.moveCursor(-1, visible_rows),
            .cursor_down      => panel.moveCursor(1, visible_rows),
            .enter            => self.handleEnter(panel),
            .go_parent        => self.handleGoParent(panel),
            .switch_panel     => self.active ^= 1,
            .toggle_select    => self.handleToggleSelect(panel),
            .copy             => self.handleCopy(panel),
            .move             => self.handleMove(panel),
            .rename           => self.handleRename(panel),
            .delete           => self.handleDelete(panel),
            .mkdir            => self.openMkdirPrompt(),
            .toggle_hidden    => self.handleToggleHidden(panel),
            .cycle_sort       => self.handleCycleSort(panel),
            .toggle_split     => self.handleToggleSplit(),
            .toggle_fn_mode   => self.fn_mode = !self.fn_mode,
            .show_help        => self.openHelp(),
            .quit             => return .quit,
            // Modal-only actions are no-ops outside a modal
            .modal_confirm, .modal_cancel, .modal_backspace => {},
            .modal_char => |_| {},
        }

        return .none;
    }

    // ── Navigation handlers ────────────────────────────────────────────────

    /// Enters a directory or copies a file's full path to the clipboard.
    fn handleEnter(self: *AppState, panel: *Panel) void {
        const entry = panel.currentEntry() orelse return;
        if (entry.kind == .directory) {
            panel.enter() catch |err|
                self.setStatusMsg("Cannot enter: {s}", .{@errorName(err)});
        } else {
            self.copyCurrentPathToClipboard(panel, entry);
        }
    }

    /// Copies the full path of the given entry to the system clipboard.
    fn copyCurrentPathToClipboard(self: *AppState, panel: *Panel, entry: *const fs.Entry) void {
        const full_path = std.fs.path.join(
            self.allocator, &.{ panel.path, entry.name },
        ) catch {
            self.setStatusMsg("Error building path", .{});
            return;
        };
        defer self.allocator.free(full_path);

        copyPathToClipboard(self.allocator, full_path) catch |err| {
            self.setStatusMsg("Clipboard error: {s}", .{@errorName(err)});
            return;
        };
        self.setStatusMsg("Copied path: {s}", .{entry.name});
    }

    fn handleGoParent(self: *AppState, panel: *Panel) void {
        panel.goParent() catch |err|
            self.setStatusMsg("Cannot go up: {s}", .{@errorName(err)});
    }

    fn handleToggleSelect(self: *AppState, panel: *Panel) void {
        panel.toggleSelection() catch |err|
            self.setStatusMsg("Selection error: {s}", .{@errorName(err)});
    }

    // ── File operation handlers ────────────────────────────────────────────

    /// Copies selected (or current) entries to the other panel's directory.
    fn handleCopy(self: *AppState, panel: *Panel) void {
        const paths = panel.selectedPaths() catch |err| {
            self.setStatusMsg("Copy failed: {s}", .{@errorName(err)});
            return;
        };
        defer freePaths(self.allocator, paths);

        const dest = self.inactivePanel().path;
        const copied = self.copyPathsTo(paths, dest) orelse return;

        panel.clearSelections();
        self.inactivePanel().reload();
        self.setStatusMsg("Copied {d} item(s) to {s}", .{ copied, dest });
    }

    /// Copies each path in `paths` into `dest_dir`. Returns count or null on error.
    fn copyPathsTo(self: *AppState, paths: [][]u8, dest_dir: []const u8) ?usize {
        var count: usize = 0;
        for (paths) |p| {
            fs.copyEntry(self.allocator, p, dest_dir) catch |err| {
                self.setStatusMsg("Copy failed: {s}", .{@errorName(err)});
                return null;
            };
            count += 1;
        }
        return count;
    }

    /// Moves selected (or current) entries to the other panel's directory.
    fn handleMove(self: *AppState, panel: *Panel) void {
        const paths = panel.selectedPaths() catch |err| {
            self.setStatusMsg("Move failed: {s}", .{@errorName(err)});
            return;
        };
        defer freePaths(self.allocator, paths);

        const dest = self.inactivePanel().path;
        const moved = self.movePathsTo(paths, dest) orelse return;

        panel.clearSelections();
        panel.reload();
        self.inactivePanel().reload();
        self.setStatusMsg("Moved {d} item(s) to {s}", .{ moved, dest });
    }

    /// Moves each path in `paths` into `dest_dir`. Returns count or null on error.
    fn movePathsTo(self: *AppState, paths: [][]u8, dest_dir: []const u8) ?usize {
        var count: usize = 0;
        for (paths) |p| {
            fs.moveEntry(self.allocator, p, dest_dir) catch |err| {
                self.setStatusMsg("Move failed: {s}", .{@errorName(err)});
                return null;
            };
            count += 1;
        }
        return count;
    }

    /// Opens a rename prompt pre-filled with the current entry's name.
    fn handleRename(self: *AppState, panel: *Panel) void {
        const entry = panel.currentEntry() orelse return;
        const src = std.fs.path.join(
            self.allocator, &.{ panel.path, entry.name },
        ) catch |err| {
            self.setStatusMsg("Error: {s}", .{@errorName(err)});
            return;
        };
        var prompt = TextPrompt{};
        const copy_len = @min(entry.name.len, prompt.buf.len - 1);
        @memcpy(prompt.buf[0..copy_len], entry.name[0..copy_len]);
        prompt.len = copy_len;

        self.freeModal();
        self.modal = .{ .rename_prompt = .{ .prompt = prompt, .src = src } };
    }

    /// Opens a delete confirmation modal for the current entry.
    fn handleDelete(self: *AppState, panel: *Panel) void {
        const entry = panel.currentEntry() orelse return;
        const path = std.fs.path.join(
            self.allocator, &.{ panel.path, entry.name },
        ) catch |err| {
            self.setStatusMsg("Error: {s}", .{@errorName(err)});
            return;
        };
        self.freeModal();
        self.modal = .{ .confirm_delete = path };
    }

    // ── View handlers ──────────────────────────────────────────────────────

    fn handleToggleHidden(self: *AppState, panel: *Panel) void {
        panel.toggleHidden();
        const label: []const u8 = if (panel.show_hidden) "shown" else "hidden";
        self.setStatusMsg("Hidden files: {s}", .{label});
    }

    fn handleCycleSort(self: *AppState, panel: *Panel) void {
        panel.cycleSortMode();
        const label: []const u8 = switch (panel.sort_mode) {
            .name_asc  => "name A→Z",
            .name_desc => "name Z→A",
            .size_asc  => "size small→large",
            .size_desc => "size large→small",
        };
        self.setStatusMsg("Sort: {s}", .{label});
    }

    fn handleToggleSplit(self: *AppState) void {
        self.split = if (self.split == .vertical) .horizontal else .vertical;
        const label: []const u8 = if (self.split == .vertical) "vertical" else "horizontal";
        self.setStatusMsg("Split: {s}", .{label});
    }

    fn openMkdirPrompt(self: *AppState) void {
        self.freeModal();
        self.modal = .{ .mkdir_prompt = .{} };
    }

    fn openHelp(self: *AppState) void {
        self.freeModal();
        self.modal = .help;
    }

    // ── Modal input handling ───────────────────────────────────────────────

    /// Routes actions to the appropriate modal handler.
    fn applyModal(self: *AppState, action: input.Action) void {
        switch (self.modal) {
            .none => {},
            .confirm_delete => |path| self.applyDeleteModal(action, path),
            .mkdir_prompt => |*mp| self.applyMkdirModal(action, mp),
            .rename_prompt => |*rp| self.applyRenameModal(action, rp),
            .help => self.modal = .none, // any key closes help
        }
    }

    fn applyDeleteModal(self: *AppState, action: input.Action, path: []u8) void {
        switch (action) {
            .modal_confirm => {
                self.modal = .none;
                fs.deleteEntry(self.allocator, path) catch |err|
                    self.setStatusMsg("Delete failed: {s}", .{@errorName(err)});
                self.allocator.free(path);
                self.activePanel().reload();
            },
            .modal_cancel => {
                self.modal = .none;
                self.allocator.free(path);
            },
            else => {},
        }
    }

    fn applyMkdirModal(self: *AppState, action: input.Action, mp: *TextPrompt) void {
        switch (action) {
            .modal_confirm => {
                // Copy name before clearing the modal (mp pointer becomes invalid after).
                var name_buf: [256]u8 = undefined;
                const name_len = @min(mp.len, name_buf.len);
                @memcpy(name_buf[0..name_len], mp.buf[0..name_len]);
                const name = name_buf[0..name_len];
                self.modal = .none;
                if (name.len > 0) {
                    fs.makeDir(self.allocator, self.activePanel().path, name) catch |err|
                        self.setStatusMsg("mkdir failed: {s}", .{@errorName(err)});
                    self.activePanel().reload();
                }
            },
            .modal_cancel    => self.modal = .none,
            .modal_char      => |c| mp.appendChar(c),
            .modal_backspace => mp.backspace(),
            else => {},
        }
    }

    fn applyRenameModal(self: *AppState, action: input.Action, rp: anytype) void {
        switch (action) {
            .modal_confirm => {
                // Copy name and src before clearing the modal.
                var name_buf: [256]u8 = undefined;
                const name_len = @min(rp.prompt.len, name_buf.len);
                @memcpy(name_buf[0..name_len], rp.prompt.buf[0..name_len]);
                const new_name = name_buf[0..name_len];
                const src = rp.src;
                self.modal = .none;
                if (new_name.len > 0) {
                    fs.renameEntry(self.allocator, src, new_name) catch |err|
                        self.setStatusMsg("Rename failed: {s}", .{@errorName(err)});
                    self.activePanel().reload();
                }
                self.allocator.free(src);
            },
            .modal_cancel => {
                const src = rp.src;
                self.modal = .none;
                self.allocator.free(src);
            },
            .modal_char      => |c| rp.prompt.appendChar(c),
            .modal_backspace => rp.prompt.backspace(),
            else => {},
        }
    }
};

// ── Helpers ────────────────────────────────────────────────────────────────

/// Frees each path string and then the slice itself.
fn freePaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

/// Pipes `path` into macOS `pbcopy` to put it on the clipboard.
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
