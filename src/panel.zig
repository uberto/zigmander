const std = @import("std");
const fs = @import("fs.zig");

pub const Panel = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    entries: []fs.Entry,
    cursor: usize,
    scroll_offset: usize,
    selections: std.StringHashMapUnmanaged(void),
    show_hidden: bool,
    sort_mode: fs.SortMode,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Panel {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const entries = try fs.listDir(allocator, path, false, .name_asc);
        errdefer fs.freeEntries(allocator, entries);

        return .{
            .allocator = allocator,
            .path = owned_path,
            .entries = entries,
            .cursor = 0,
            .scroll_offset = 0,
            .selections = .{},
            .show_hidden = false,
            .sort_mode = .name_asc,
        };
    }

    pub fn deinit(self: *Panel) void {
        fs.freeEntries(self.allocator, self.entries);
        self.allocator.free(self.path);
        var it = self.selections.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.selections.deinit(self.allocator);
    }

    pub fn reload(self: *Panel) void {
        const saved_name: ?[]const u8 = if (self.cursor < self.entries.len)
            self.entries[self.cursor].name
        else
            null;

        const new_entries = fs.listDir(
            self.allocator, self.path, self.show_hidden, self.sort_mode,
        ) catch return;
        fs.freeEntries(self.allocator, self.entries);
        self.entries = new_entries;

        if (saved_name) |name| {
            for (self.entries, 0..) |e, i| {
                if (std.mem.eql(u8, e.name, name)) {
                    self.cursor = i;
                    return;
                }
            }
        }
        self.clampCursor();
    }

    pub fn toggleHidden(self: *Panel) void {
        self.show_hidden = !self.show_hidden;
        self.reload();
    }

    pub fn cycleSortMode(self: *Panel) void {
        self.sort_mode = switch (self.sort_mode) {
            .name_asc  => .name_desc,
            .name_desc => .size_desc,
            .size_desc => .size_asc,
            .size_asc  => .name_asc,
        };
        self.reload();
    }

    pub fn clampCursor(self: *Panel) void {
        if (self.entries.len == 0) {
            self.cursor = 0;
        } else if (self.cursor >= self.entries.len) {
            self.cursor = self.entries.len - 1;
        }
    }

    pub fn moveCursor(self: *Panel, delta: i32, visible_rows: usize) void {
        if (self.entries.len == 0) return;
        if (delta > 0) {
            const d: usize = @intCast(delta);
            self.cursor = @min(self.cursor + d, self.entries.len - 1);
        } else {
            const d: usize = @intCast(-delta);
            self.cursor = if (self.cursor >= d) self.cursor - d else 0;
        }
        self.updateScroll(visible_rows);
    }

    pub fn updateScroll(self: *Panel, visible_rows: usize) void {
        if (self.cursor < self.scroll_offset) {
            self.scroll_offset = self.cursor;
        }
        if (visible_rows > 0 and self.cursor >= self.scroll_offset + visible_rows) {
            self.scroll_offset = self.cursor - visible_rows + 1;
        }
    }

    pub fn currentEntry(self: *const Panel) ?*const fs.Entry {
        if (self.entries.len == 0 or self.cursor >= self.entries.len) return null;
        return &self.entries[self.cursor];
    }

    pub fn currentPath(self: *const Panel) ![]u8 {
        const entry = self.currentEntry() orelse return error.NoEntry;
        return std.fs.path.join(self.allocator, &.{ self.path, entry.name });
    }

    pub fn enter(self: *Panel) !void {
        const entry = self.currentEntry() orelse return;
        if (entry.kind != .directory) return error.NotADirectory;

        const new_path = try std.fs.path.join(self.allocator, &.{ self.path, entry.name });
        defer self.allocator.free(new_path);

        const new_entries = try fs.listDir(
            self.allocator, new_path, self.show_hidden, self.sort_mode,
        );
        fs.freeEntries(self.allocator, self.entries);
        self.entries = new_entries;

        self.allocator.free(self.path);
        self.path = try self.allocator.dupe(u8, new_path);
        self.cursor = 0;
        self.scroll_offset = 0;
    }

    pub fn goParent(self: *Panel) !void {
        const parent = std.fs.path.dirname(self.path) orelse return;

        const new_path = try self.allocator.dupe(u8, parent);
        errdefer self.allocator.free(new_path);

        const new_entries = try fs.listDir(
            self.allocator, new_path, self.show_hidden, self.sort_mode,
        );
        fs.freeEntries(self.allocator, self.entries);
        self.entries = new_entries;

        self.allocator.free(self.path);
        self.path = new_path;
        self.cursor = 0;
        self.scroll_offset = 0;
    }

    pub fn toggleSelection(self: *Panel) !void {
        const entry = self.currentEntry() orelse return;
        const name = entry.name;

        if (self.selections.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
        } else {
            const key = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(key);
            try self.selections.put(self.allocator, key, {});
        }
    }

    pub fn clearSelections(self: *Panel) void {
        var it = self.selections.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.selections.clearRetainingCapacity();
    }

    /// Returns owned slice of absolute paths. Caller must free each path and the slice.
    pub fn selectedPaths(self: *const Panel) ![][]u8 {
        if (self.selections.count() > 0) {
            var paths = try self.allocator.alloc([]u8, self.selections.count());
            var it = self.selections.keyIterator();
            var i: usize = 0;
            errdefer {
                for (paths[0..i]) |p| self.allocator.free(p);
                self.allocator.free(paths);
            }
            while (it.next()) |k| {
                paths[i] = try std.fs.path.join(self.allocator, &.{ self.path, k.* });
                i += 1;
            }
            return paths;
        } else {
            const p = try self.currentPath();
            const paths = try self.allocator.alloc([]u8, 1);
            paths[0] = p;
            return paths;
        }
    }
};
