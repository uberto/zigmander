const std = @import("std");
const fs = @import("fs.zig");

/// Controls how file sizes are presented in the panel.
pub const SizeDisplay = enum { abbrev, bytes, none };

pub const Panel = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    entries: []fs.Entry,
    cursor: usize,
    scroll_offset: usize,
    selections: std.StringHashMapUnmanaged(void),
    show_hidden: bool,
    sort_mode: fs.SortMode,
    size_display: SizeDisplay,
    show_permissions: bool,
    show_mtime: bool,
    show_btime: bool,

    /// Initialises a panel rooted at `path` with default settings.
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Panel {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const entries = try fs.listDir(allocator, path, false, .name_asc);
        errdefer fs.freeEntries(allocator, entries);

        return .{
            .allocator        = allocator,
            .path             = owned_path,
            .entries          = entries,
            .cursor           = 0,
            .scroll_offset    = 0,
            .selections       = .{},
            .show_hidden      = false,
            .sort_mode        = .name_asc,
            .size_display     = .abbrev,
            .show_permissions = false,
            .show_mtime       = false,
            .show_btime       = false,
        };
    }

    pub fn deinit(self: *Panel) void {
        fs.freeEntries(self.allocator, self.entries);
        self.allocator.free(self.path);
        clearSelectionsMap(self.allocator, &self.selections);
        self.selections.deinit(self.allocator);
    }

    // ── Directory navigation ───────────────────────────────────────────────

    /// Re-reads the current directory, trying to keep the cursor on the same entry.
    pub fn reload(self: *Panel) void {
        const saved_name = currentName(self);
        const new_entries = fs.listDir(
            self.allocator, self.path, self.show_hidden, self.sort_mode,
        ) catch return;
        fs.freeEntries(self.allocator, self.entries);
        self.entries = new_entries;

        if (saved_name) |name| {
            if (findEntryIndex(self.entries, name)) |i| {
                self.cursor = i;
                return;
            }
        }
        self.clampCursor();
    }

    /// Enters the directory currently under the cursor.
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

    /// Navigates to the parent of the current directory.
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

    // ── Cursor movement ────────────────────────────────────────────────────

    /// Moves the cursor by `delta` rows and adjusts scroll to keep it visible.
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

    /// Adjusts `scroll_offset` so the cursor row stays within the visible window.
    pub fn updateScroll(self: *Panel, visible_rows: usize) void {
        if (self.cursor < self.scroll_offset) {
            self.scroll_offset = self.cursor;
        }
        if (visible_rows > 0 and self.cursor >= self.scroll_offset + visible_rows) {
            self.scroll_offset = self.cursor - visible_rows + 1;
        }
    }

    /// Ensures `cursor` is a valid index (or 0 for an empty list).
    pub fn clampCursor(self: *Panel) void {
        if (self.entries.len == 0) {
            self.cursor = 0;
        } else if (self.cursor >= self.entries.len) {
            self.cursor = self.entries.len - 1;
        }
    }

    // ── Entry access ───────────────────────────────────────────────────────

    /// Returns the entry under the cursor, or null if the list is empty.
    pub fn currentEntry(self: *const Panel) ?*const fs.Entry {
        if (self.entries.len == 0 or self.cursor >= self.entries.len) return null;
        return &self.entries[self.cursor];
    }

    /// Returns the absolute path of the entry under the cursor (caller must free).
    pub fn currentPath(self: *const Panel) ![]u8 {
        const entry = self.currentEntry() orelse return error.NoEntry;
        return std.fs.path.join(self.allocator, &.{ self.path, entry.name });
    }

    // ── View settings ──────────────────────────────────────────────────────

    /// Toggles visibility of hidden (dot-prefixed) files and reloads.
    pub fn toggleHidden(self: *Panel) void {
        self.show_hidden = !self.show_hidden;
        self.reload();
    }

    /// Advances to the next sort mode in the cycle and reloads.
    pub fn cycleSortMode(self: *Panel) void {
        self.sort_mode = switch (self.sort_mode) {
            .name_asc  => .name_desc,
            .name_desc => .size_desc,
            .size_desc => .size_asc,
            .size_asc  => .name_asc,
        };
        self.reload();
    }

    /// Cycles through size display modes: abbreviated → exact bytes → hidden.
    pub fn cycleSizeDisplay(self: *Panel) void {
        self.size_display = switch (self.size_display) {
            .abbrev => .bytes,
            .bytes  => .none,
            .none   => .abbrev,
        };
    }

    /// Toggles the Unix permissions column (rwxr-xr-x) on or off.
    pub fn togglePermissions(self: *Panel) void {
        self.show_permissions = !self.show_permissions;
    }

    /// Toggles the last-modified date column on or off.
    pub fn toggleMtime(self: *Panel) void {
        self.show_mtime = !self.show_mtime;
    }

    /// Toggles the birth (creation) date column on or off.
    pub fn toggleBtime(self: *Panel) void {
        self.show_btime = !self.show_btime;
    }

    // ── Selections ─────────────────────────────────────────────────────────

    /// Toggles the selection state of the entry under the cursor.
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

    /// Removes all selections without freeing the panel itself.
    pub fn clearSelections(self: *Panel) void {
        clearSelectionsMap(self.allocator, &self.selections);
    }

    /// Returns owned absolute paths for all selected entries, or the current entry
    /// if nothing is selected. Caller must free each path and the slice.
    pub fn selectedPaths(self: *const Panel) ![][]u8 {
        if (self.selections.count() > 0) {
            return self.selectedEntryPaths();
        }
        const p = try self.currentPath();
        const paths = try self.allocator.alloc([]u8, 1);
        paths[0] = p;
        return paths;
    }

    /// Builds absolute paths for every explicitly selected entry.
    fn selectedEntryPaths(self: *const Panel) ![][]u8 {
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
    }
};

// ── Module-level helpers ───────────────────────────────────────────────────

/// Returns the name of the entry under the cursor, or null if list is empty.
fn currentName(panel: *const Panel) ?[]const u8 {
    if (panel.cursor < panel.entries.len) return panel.entries[panel.cursor].name;
    return null;
}

/// Searches entries for one whose name matches; returns its index or null.
fn findEntryIndex(entries: []const fs.Entry, name: []const u8) ?usize {
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, name)) return i;
    }
    return null;
}

/// Frees all keys in a selections map and clears it (does not deinit the map).
fn clearSelectionsMap(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(void),
) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    map.clearRetainingCapacity();
}
