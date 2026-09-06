const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_layout = @import("session_layout.zig");
const session_store = @import("session_store.zig");
const summary_codec = @import("session_summary_codec.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const magic = "fx-resume-catalog-v1\n";
const file_name = ".resume-catalog";
const max_bytes = 64 * 1024 * 1024;
const max_records = 100_000;
const Fingerprint = [Sha256.digest_length]u8;

pub const Entry = struct {
    fingerprint: ?Fingerprint,
    value: union(enum) { visible: session_store.SessionSummary, excluded: []u8 },

    fn id(self: Entry) []const u8 {
        return switch (self.value) {
            .visible => |summary| summary.id,
            .excluded => |name| name,
        };
    }

    pub fn deinit(self: *Entry, alloc: Allocator) void {
        switch (self.value) {
            .visible => |*summary| summary.deinit(alloc),
            .excluded => |name| alloc.free(name),
        }
        self.* = undefined;
    }
};

const Summary = struct {
    workspace_root: ?[]const u8,
    origin_workspace_root: ?[]const u8,
    title: ?[]const u8,
    preview: ?[]const u8,
    display_metadata_present: bool,
    created_at_ms: i64,
    updated_at_ms: i64,
    history_len: u64,
    language: []const u8,
    has_checkpoint: bool,
    has_managed_children: bool,

    fn from(source: *const session_store.SessionSummary) Summary {
        return .{
            .workspace_root = source.workspace_root,
            .origin_workspace_root = source.origin_workspace_root,
            .title = source.title,
            .preview = source.preview,
            .display_metadata_present = source.display_metadata_present,
            .created_at_ms = source.created_at_ms,
            .updated_at_ms = source.updated_at_ms,
            .history_len = source.history_len,
            .language = source.conversation_language.view(),
            .has_checkpoint = source.has_checkpoint,
            .has_managed_children = source.has_managed_children,
        };
    }

    fn clone(self: Summary, alloc: Allocator, id: []const u8) !session_store.SessionSummary {
        return summary_codec.cloneSessionSummary(alloc, .{
            .id = @constCast(id),
            .workspace_root = if (self.workspace_root) |value| @constCast(value) else null,
            .origin_workspace_root = if (self.origin_workspace_root) |value| @constCast(value) else null,
            .title = if (self.title) |value| @constCast(value) else null,
            .preview = if (self.preview) |value| @constCast(value) else null,
            .display_metadata_present = self.display_metadata_present,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .history_len = std.math.cast(usize, self.history_len) orelse return error.InvalidCatalogCache,
            .conversation_language = try session.ConversationLanguage.fromSlice(self.language),
            .has_checkpoint = self.has_checkpoint,
            .has_managed_children = self.has_managed_children,
        });
    }
};

const Row = struct { id: []const u8, fingerprint: []const u8, summary: ?Summary };

/// Owns parsed cache bytes. Reused entries are separately owned by the caller.
pub const Loaded = struct {
    bytes: ?[]u8 = null,
    parsed: ?std.json.Parsed([]Row) = null,
    index: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        self.index.deinit(alloc);
        if (self.parsed) |*parsed| parsed.deinit();
        if (self.bytes) |bytes| alloc.free(bytes);
        self.* = .{};
    }

    pub fn count(self: *const Loaded) usize {
        return self.index.count();
    }
    pub fn present(self: *const Loaded) bool {
        return self.parsed != null;
    }
    pub fn contains(self: *const Loaded, id: []const u8) bool {
        return self.index.contains(id);
    }

    pub fn load(alloc: Allocator, dir: ?io_mod.VerifiedDir, cancelled: ?*const std.atomic.Value(bool)) !Loaded {
        const root = dir orelse return .{};
        return loadChecked(alloc, root.dir, cancelled) catch |err| switch (err) {
            error.OutOfMemory, error.Cancelled => return err,
            error.FileNotFound => .{},
            else => blk: {
                debug_trace.logf("core", "session catalog cache ignored err={s}", .{@errorName(err)});
                break :blk .{};
            },
        };
    }

    fn loadChecked(alloc: Allocator, dir: std.Io.Dir, cancelled: ?*const std.atomic.Value(bool)) !Loaded {
        var file = try dir.openFile(io_mod.getIo(), file_name, .{ .follow_symlinks = false, .allow_directory = false, .resolve_beneath = true });
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        if (stat.kind != .file or stat.nlink > 1 or (stat.permissions.toMode() & 0o077) != 0 or stat.size > max_bytes) return error.InvalidCatalogCache;
        const bytes = try alloc.alloc(u8, @intCast(stat.size));
        errdefer alloc.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (cancelled) |stop| if (stop.load(.acquire)) return error.Cancelled;
            const end = @min(bytes.len, offset + 64 * 1024);
            const read = try file.readPositionalAll(io_mod.getIo(), bytes[offset..end], offset);
            if (read != end - offset) return error.InvalidCatalogCache;
            offset = end;
        }
        if (bytes.len < magic.len + Sha256.digest_length or !std.mem.startsWith(u8, bytes, magic)) return error.InvalidCatalogCache;
        const payload = bytes[magic.len + Sha256.digest_length ..];
        var digest: Fingerprint = undefined;
        Sha256.hash(payload, &digest, .{});
        if (!std.mem.eql(u8, &digest, bytes[magic.len..][0..Sha256.digest_length])) return error.InvalidCatalogCache;
        const parsed = try std.json.parseFromSlice([]Row, alloc, payload, .{ .allocate = .alloc_if_needed, .ignore_unknown_fields = false, .max_value_len = max_bytes });
        errdefer parsed.deinit();
        if (parsed.value.len > max_records) return error.InvalidCatalogCache;
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        errdefer index.deinit(alloc);
        try index.ensureTotalCapacity(alloc, @intCast(parsed.value.len));
        for (parsed.value, 0..) |row, i| {
            if (cancelled) |stop| if (stop.load(.acquire)) return error.Cancelled;
            try session_layout.validateSessionId(row.id);
            if (row.fingerprint.len != 64) return error.InvalidCatalogCache;
            var fingerprint_bytes: Fingerprint = undefined;
            _ = std.fmt.hexToBytes(&fingerprint_bytes, row.fingerprint) catch return error.InvalidCatalogCache;
            if (row.summary) |summary| {
                if (summary.created_at_ms < 0 or summary.updated_at_ms < summary.created_at_ms) return error.InvalidCatalogCache;
                if (summary.history_len == 0 and !summary.has_checkpoint) return error.InvalidCatalogCache;
                _ = try session.ConversationLanguage.fromSlice(summary.language);
                _ = std.math.cast(usize, summary.history_len) orelse return error.InvalidCatalogCache;
                if (summary.title) |title| {
                    if (title.len > session_codec.max_session_title_bytes or !std.unicode.utf8ValidateSlice(title)) return error.InvalidCatalogCache;
                }
                for ([_]?[]const u8{ summary.workspace_root, summary.origin_workspace_root }) |root| {
                    if (root) |path| {
                        if (!std.fs.path.isAbsolute(path) or path.len > std.Io.Dir.max_path_bytes) return error.InvalidCatalogCache;
                    }
                }
            }
            const entry = index.getOrPutAssumeCapacity(row.id);
            if (entry.found_existing) return error.InvalidCatalogCache;
            entry.value_ptr.* = i;
        }
        return .{ .bytes = bytes, .parsed = parsed, .index = index };
    }

    pub fn reuse(self: *const Loaded, alloc: Allocator, id: []const u8, fingerprint_value: Fingerprint) !?Entry {
        const position = self.index.get(id) orelse return null;
        const row = self.parsed.?.value[position];
        const hex = std.fmt.bytesToHex(fingerprint_value, .lower);
        if (!std.mem.eql(u8, row.fingerprint, &hex)) return null;
        return try cloneRow(alloc, row, fingerprint_value);
    }

    fn cloneRow(alloc: Allocator, row: Row, value: Fingerprint) !Entry {
        return .{ .fingerprint = value, .value = if (row.summary) |summary|
            .{ .visible = try summary.clone(alloc, row.id) }
        else
            .{ .excluded = try alloc.dupe(u8, row.id) } };
    }
};

/// A narrow cache-writing handle obtained only from a writable app store.
pub const Writer = struct {
    dir: io_mod.VerifiedDir,

    pub fn init(store: session_store.Store) !?Writer {
        if (store.canonical_root.mode != .writable) return null;
        const root = store.canonical_root.sessions orelse return null;
        return .{ .dir = .{ .dir = try root.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) } };
    }
    pub fn deinit(self: *Writer) void {
        self.dir.close();
    }

    pub fn save(self: *Writer, alloc: Allocator, entries: []const Entry, cancelled: *const std.atomic.Value(bool)) !void {
        var payload: std.Io.Writer.Allocating = .init(alloc);
        defer payload.deinit();
        try payload.writer.writeByte('[');
        var written: usize = 0;
        for (entries) |*entry| {
            if (cancelled.load(.acquire)) return error.Cancelled;
            const value = entry.fingerprint orelse continue;
            if (written == max_records) return error.CatalogCacheTooLarge;
            if (written != 0) try payload.writer.writeByte(',');
            const hex = std.fmt.bytesToHex(value, .lower);
            try std.json.Stringify.value(Row{ .id = entry.id(), .fingerprint = &hex, .summary = switch (entry.value) {
                .visible => |*summary| Summary.from(summary),
                .excluded => null,
            } }, .{}, &payload.writer);
            written += 1;
            if (payload.written().len > max_bytes - magic.len - Sha256.digest_length - 1) return error.CatalogCacheTooLarge;
        }
        try payload.writer.writeByte(']');
        if (cancelled.load(.acquire)) return error.Cancelled;
        var digest: Fingerprint = undefined;
        Sha256.hash(payload.written(), &digest, .{});
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(magic);
        try out.writer.writeAll(&digest);
        try out.writer.writeAll(payload.written());
        try io_mod.durableReplaceVerified(alloc, &self.dir, file_name, out.written());
    }
};

/// Stats are freshness evidence only. Cache misses still use canonical discovery and admission.
pub fn fingerprint(dir: std.Io.Dir, id: []const u8) !?Fingerprint {
    try session_layout.validateSessionId(id);
    const before = (try statOptional(dir, id)) orelse return null;
    if (before.kind != .directory) return null;
    var digest = Sha256.init(.{});
    addStat(&digest, before);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "session.json", "events.jsonl" }) |name| {
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ id, name });
        const stat = (try statOptional(dir, path)) orelse return null;
        if (stat.kind != .file or stat.nlink != 1) return null;
        addStat(&digest, stat);
    }
    const child_path = try std.fmt.bufPrint(&path_buffer, "{s}/subagent", .{id});
    const child = try statOptional(dir, child_path);
    if (child) |stat| {
        if (stat.kind != .directory) return null;
        digest.update(&.{1});
        addStat(&digest, stat);
        for ([_][]const u8{ "owner.json", "control.json" }) |name| {
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/subagent/{s}", .{ id, name });
            if (try statOptional(dir, path)) |marker| {
                if (marker.kind != .file or marker.nlink != 1) return null;
                digest.update(&.{1});
                addStat(&digest, marker);
            } else digest.update(&.{0});
        }
    } else digest.update(&.{0});
    const after = (try statOptional(dir, id)) orelse return null;
    if (!sameStat(before, after)) return null;
    var value: Fingerprint = undefined;
    digest.final(&value);
    return value;
}

fn statOptional(dir: std.Io.Dir, path: []const u8) !?std.Io.File.Stat {
    return dir.statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => err,
    };
}

fn sameStat(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.nlink == b.nlink and a.kind == b.kind and a.size == b.size and
        a.permissions.toMode() == b.permissions.toMode() and a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

fn addStat(hash: *Sha256, stat: std.Io.File.Stat) void {
    const values = [_]u128{ stat.inode, stat.nlink, stat.size, @intFromEnum(stat.kind), stat.permissions.toMode(), @bitCast(@as(i128, stat.mtime.nanoseconds)), @bitCast(@as(i128, stat.ctime.nanoseconds)) };
    var bytes: [16]u8 = undefined;
    for (values) |value| {
        std.mem.writeInt(u128, &bytes, value, .little);
        hash.update(&bytes);
    }
}

test "catalog cache round trips owned rows and ignores incomplete observations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = Writer{ .dir = .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }) } };
    defer writer.deinit();
    var entries = [_]Entry{
        .{ .fingerprint = @splat(1), .value = .{ .visible = try summary_codec.cloneSessionSummary(alloc, .{
            .id = @constCast("visible"),
            .workspace_root = @constCast("/workspace"),
            .origin_workspace_root = @constCast("/origin"),
            .title = @constCast("Saved title"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .history_len = 3,
            .conversation_language = .literal("en"),
        }) } },
        .{ .fingerprint = @splat(2), .value = .{ .excluded = try alloc.dupe(u8, "private") } },
        .{ .fingerprint = null, .value = .{ .excluded = try alloc.dupe(u8, "temporary-failure") } },
    };
    defer for (&entries) |*entry| entry.deinit(alloc);
    var stopped = std.atomic.Value(bool).init(false);
    try writer.save(alloc, &entries, &stopped);
    var loaded = try Loaded.load(alloc, writer.dir, null);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.present());
    try std.testing.expectEqual(@as(usize, 2), loaded.count());
    try std.testing.expect(!loaded.contains("temporary-failure"));
    var visible = (try loaded.reuse(alloc, "visible", @splat(1))).?;
    defer visible.deinit(alloc);
    try std.testing.expectEqualStrings("Saved title", visible.value.visible.title.?);
    try std.testing.expectEqual(@as(usize, 3), visible.value.visible.history_len);
    try std.testing.expect((try loaded.reuse(alloc, "visible", @splat(3))) == null);
    var excluded = (try loaded.reuse(alloc, "private", @splat(2))).?;
    defer excluded.deinit(alloc);
    try std.testing.expectEqualStrings("private", excluded.value.excluded);
    stopped.store(true, .release);
    try std.testing.expectError(error.Cancelled, writer.save(alloc, &.{}, &stopped));
    var retained = try Loaded.load(alloc, writer.dir, null);
    defer retained.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), retained.count());
}

test "catalog cache corruption and duplicate identifiers require rebuilding" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = Writer{ .dir = .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }) } };
    defer writer.deinit();
    const duplicate = Entry{ .fingerprint = @splat(4), .value = .{ .excluded = @constCast("duplicate") } };
    var stopped = std.atomic.Value(bool).init(false);
    try writer.save(alloc, &.{ duplicate, duplicate }, &stopped);
    var invalid = try Loaded.load(alloc, writer.dir, null);
    defer invalid.deinit(alloc);
    try std.testing.expect(!invalid.present());
    try io_mod.durableReplaceVerified(alloc, &writer.dir, file_name, "corrupt cache");
    var corrupt = try Loaded.load(alloc, writer.dir, null);
    defer corrupt.deinit(alloc);
    try std.testing.expect(!corrupt.present());
}

test "catalog fingerprint detects event appends and child directory permissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "session/subagent");
    for ([_][]const u8{ "session/session.json", "session/events.jsonl" }) |path| {
        var file = try tmp.dir.createFile(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}\n");
    }
    const first = (try fingerprint(tmp.dir, "session")).?;
    var events = try tmp.dir.openFile(std.testing.io, "session/events.jsonl", .{ .mode = .read_write });
    defer events.close(std.testing.io);
    try events.writePositionalAll(std.testing.io, "more\n", 3);
    const appended = (try fingerprint(tmp.dir, "session")).?;
    try std.testing.expect(!std.mem.eql(u8, &first, &appended));
    var child = try tmp.dir.openDir(std.testing.io, "session/subagent", .{ .iterate = true });
    defer child.close(std.testing.io);
    try child.setPermissions(std.testing.io, .fromMode(0o700));
    const private = (try fingerprint(tmp.dir, "session")).?;
    try child.setPermissions(std.testing.io, .fromMode(0o755));
    const changed = (try fingerprint(tmp.dir, "session")).?;
    try std.testing.expect(!std.mem.eql(u8, &private, &changed));
}
