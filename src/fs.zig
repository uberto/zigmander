const std = @import("std");

pub const EntryKind = enum { directory, file, other };

pub const Entry = struct {
    name: []u8,
    kind: EntryKind,
    size: u64,
};

pub const SortMode = enum { name_asc, name_desc, size_asc, size_desc };

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

fn sortEntries(ctx: SortCtx, a: Entry, b: Entry) bool {
    // Directories always precede files regardless of sort mode
    const a_dir = a.kind == .directory;
    const b_dir = b.kind == .directory;
    if (a_dir != b_dir) return a_dir;

    return switch (ctx.mode) {
        .name_asc => nameLt(a.name, b.name),
        .name_desc => nameLt(b.name, a.name),
        .size_asc => if (a.size != b.size) a.size < b.size else nameLt(a.name, b.name),
        .size_desc => if (a.size != b.size) a.size > b.size else nameLt(a.name, b.name),
    };
}

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

        const name = try allocator.dupe(u8, de.name);
        errdefer allocator.free(name);

        const kind: EntryKind = switch (de.kind) {
            .directory => .directory,
            .file => .file,
            else => .other,
        };

        const size: u64 = if (de.kind == .file) blk: {
            const stat = dir.statFile(de.name) catch break :blk 0;
            break :blk stat.size;
        } else 0;

        try list.append(allocator, .{ .name = name, .kind = kind, .size = size });
    }

    std.mem.sort(Entry, list.items, SortCtx{ .mode = sort_mode }, sortEntries);
    return list.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| allocator.free(e.name);
    allocator.free(entries);
}

pub fn formatSize(size: u64, buf: []u8) []u8 {
    if (size < 1024) {
        return std.fmt.bufPrint(buf, "{d}B", .{size}) catch buf[0..0];
    } else if (size < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d}K", .{size / 1024}) catch buf[0..0];
    } else if (size < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d}M", .{size / (1024 * 1024)}) catch buf[0..0];
    } else {
        return std.fmt.bufPrint(buf, "{d}G", .{size / (1024 * 1024 * 1024)}) catch buf[0..0];
    }
}

fn copyDirRecursive(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    try std.fs.makeDirAbsolute(dest);
    var src_dir = try std.fs.openDirAbsolute(src, .{ .iterate = true });
    defer src_dir.close();

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        const src_child = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_child);
        const dest_child = try std.fs.path.join(allocator, &.{ dest, entry.name });
        defer allocator.free(dest_child);

        switch (entry.kind) {
            .directory => try copyDirRecursive(allocator, src_child, dest_child),
            else => try std.fs.copyFileAbsolute(src_child, dest_child, .{}),
        }
    }
}

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

pub fn renameEntry(allocator: std.mem.Allocator, path: []const u8, new_name: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const dest = try std.fs.path.join(allocator, &.{ parent, new_name });
    defer allocator.free(dest);
    try std.fs.renameAbsolute(path, dest);
}

pub fn deleteEntry(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const name = std.fs.path.basename(path);
    var parent_dir = try std.fs.openDirAbsolute(parent_path, .{});
    defer parent_dir.close();
    try parent_dir.deleteTree(name);
}

pub fn makeDir(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ parent, name });
    defer allocator.free(path);
    try std.fs.makeDirAbsolute(path);
}
