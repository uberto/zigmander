const std = @import("std");

pub const EntryKind = enum { directory, file, other };

pub const Entry = struct {
    name: []u8,
    kind: EntryKind,
    size: u64,
};

pub const SortMode = enum { name_asc, name_desc, size_asc, size_desc };

// ── Sorting ────────────────────────────────────────────────────────────────

/// Case-insensitive lexicographic comparison of two name strings.
fn nameLt(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return ca < cb;
    }
    return a.len < b.len;
}

const SortCtx = struct { mode: SortMode };

/// Comparison function for std.mem.sort: directories sort before files,
/// then entries are ordered according to `ctx.mode`.
fn sortEntries(ctx: SortCtx, a: Entry, b: Entry) bool {
    const a_dir = a.kind == .directory;
    const b_dir = b.kind == .directory;
    if (a_dir != b_dir) return a_dir; // dirs first

    return switch (ctx.mode) {
        .name_asc  => nameLt(a.name, b.name),
        .name_desc => nameLt(b.name, a.name),
        .size_asc  => if (a.size != b.size) a.size < b.size else nameLt(a.name, b.name),
        .size_desc => if (a.size != b.size) a.size > b.size else nameLt(a.name, b.name),
    };
}

// ── Directory listing ──────────────────────────────────────────────────────

/// Returns an owned slice of entries for `path`.
/// Caller owns the slice and each entry's `name`; use `freeEntries` to release.
pub fn listDir(
    allocator: std.mem.Allocator,
    path: []const u8,
    show_hidden: bool,
    sort_mode: SortMode,
) ![]Entry {
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var list: std.ArrayListUnmanaged(Entry) = .{};
    errdefer {
        for (list.items) |e| allocator.free(e.name);
        list.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |de| {
        if (!show_hidden and de.name.len > 0 and de.name[0] == '.') continue;
        try list.append(allocator, try readDirEntry(allocator, &dir, de));
    }

    std.mem.sort(Entry, list.items, SortCtx{ .mode = sort_mode }, sortEntries);
    return list.toOwnedSlice(allocator);
}

/// Builds an `Entry` from a raw directory iterator entry, stat-ing files for size.
fn readDirEntry(
    allocator: std.mem.Allocator,
    dir: *std.fs.Dir,
    de: std.fs.Dir.Entry,
) !Entry {
    const name = try allocator.dupe(u8, de.name);
    errdefer allocator.free(name);

    const kind: EntryKind = switch (de.kind) {
        .directory => .directory,
        .file      => .file,
        else       => .other,
    };

    const size: u64 = if (de.kind == .file) blk: {
        const stat = dir.statFile(de.name) catch break :blk 0;
        break :blk stat.size;
    } else 0;

    return .{ .name = name, .kind = kind, .size = size };
}

/// Releases all memory owned by an entries slice.
pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| allocator.free(e.name);
    allocator.free(entries);
}

// ── Size formatting ────────────────────────────────────────────────────────

/// Formats a byte count into a short human-readable string (e.g. "3K", "12M").
pub fn formatSize(size: u64, buf: []u8) []u8 {
    if (size < 1024)
        return std.fmt.bufPrint(buf, "{d}B",  .{size})                       catch buf[0..0];
    if (size < 1024 * 1024)
        return std.fmt.bufPrint(buf, "{d}K",  .{size / 1024})                catch buf[0..0];
    if (size < 1024 * 1024 * 1024)
        return std.fmt.bufPrint(buf, "{d}M",  .{size / (1024 * 1024)})       catch buf[0..0];
    return     std.fmt.bufPrint(buf, "{d}G",  .{size / (1024 * 1024 * 1024)}) catch buf[0..0];
}

// ── File operations ────────────────────────────────────────────────────────

/// Recursively copies a directory tree from `src` to `dest`.
fn copyDirRecursive(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    try std.fs.makeDirAbsolute(dest);
    var src_dir = try std.fs.openDirAbsolute(src, .{ .iterate = true });
    defer src_dir.close();

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        const src_child  = try std.fs.path.join(allocator, &.{ src,  entry.name });
        defer allocator.free(src_child);
        const dest_child = try std.fs.path.join(allocator, &.{ dest, entry.name });
        defer allocator.free(dest_child);

        switch (entry.kind) {
            .directory => try copyDirRecursive(allocator, src_child, dest_child),
            else       => try std.fs.copyFileAbsolute(src_child, dest_child, .{}),
        }
    }
}

/// Copies a file or directory `src` into `dest_dir` (preserving the basename).
pub fn copyEntry(allocator: std.mem.Allocator, src: []const u8, dest_dir: []const u8) !void {
    const base = std.fs.path.basename(src);
    const dest = try std.fs.path.join(allocator, &.{ dest_dir, base });
    defer allocator.free(dest);

    std.fs.copyFileAbsolute(src, dest, .{}) catch |err| {
        if (err == error.IsDir) {
            try copyDirRecursive(allocator, src, dest);
        } else return err;
    };
}

/// Moves `src` into `dest_dir`. Falls back to copy+delete across mount points.
pub fn moveEntry(allocator: std.mem.Allocator, src: []const u8, dest_dir: []const u8) !void {
    const base = std.fs.path.basename(src);
    const dest = try std.fs.path.join(allocator, &.{ dest_dir, base });
    defer allocator.free(dest);

    std.fs.renameAbsolute(src, dest) catch |err| {
        if (err == error.RenameAcrossMountPoints) {
            try copyEntry(allocator, src, dest_dir);
            try deleteEntry(allocator, src);
        } else return err;
    };
}

/// Renames `path` to `new_name` within the same parent directory.
pub fn renameEntry(allocator: std.mem.Allocator, path: []const u8, new_name: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const dest   = try std.fs.path.join(allocator, &.{ parent, new_name });
    defer allocator.free(dest);
    try std.fs.renameAbsolute(path, dest);
}

/// Deletes a file or directory tree at `path`.
pub fn deleteEntry(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const name        = std.fs.path.basename(path);
    var parent_dir    = try std.fs.openDirAbsolute(parent_path, .{});
    defer parent_dir.close();
    try parent_dir.deleteTree(name);
}

/// Creates a new directory named `name` inside `parent`.
pub fn makeDir(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ parent, name });
    defer allocator.free(path);
    try std.fs.makeDirAbsolute(path);
}
