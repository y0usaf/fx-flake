const std = @import("std");
const genome = @import("genome");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const whitespace = " \t\r\n";
const max_source_bytes: usize = 2 * 1024 * 1024;
const max_output_bytes: usize = 256 * 1024;

pub const Input = struct {
    path: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = .{ .path = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "ast_symbols arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "ast_symbols arguments must be an object") };
    }
    const path_value = parsed.value.object.get("path") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "ast_symbols requires string field \"path\"") };
    };
    if (path_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "ast_symbols field \"path\" must be a string") };
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .path = try ctx.allocator.dupe(u8, path_value.string) };
    errdefer input.deinit(ctx.allocator);
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    const trimmed = std.mem.trim(u8, input.path, whitespace);
    if (!std.mem.eql(u8, input.path, trimmed)) {
        const owned = try ctx.allocator.dupe(u8, trimmed);
        ctx.allocator.free(input.path);
        input.path = owned;
    }
    if (input.path.len == 0) {
        return try ctx.allocator.dupe(u8, "ast_symbols field \"path\" must not be empty");
    }
    if (genome.detectLanguage(input.path) == null) {
        return try ctx.allocator.dupe(u8, "ast_symbols supports .ts, .mts, .cts, .tsx, .py, .pyi, .go, .rs, .nix, and .zig files");
    }
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const language = genome.detectLanguage(input.path) orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "ast_symbols could not detect a supported language from the path") };
    };

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "ast_symbols failed to resolve {s}: {s}", .{ input.path, @errorName(err) }) };
    };
    const zio = io_mod.getIo();
    var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), target, .no_follow) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "ast_symbols failed to open {s}: {s}", .{ input.path, @errorName(err) }) };
    };
    defer file.close(zio);

    const source = io_mod.readFileToEnd(arena, &file, max_source_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "ast_symbols source exceeds {d} bytes: {s}", .{ max_source_bytes, input.path }) },
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "ast_symbols failed to read {s}: {s}", .{ input.path, @errorName(err) }) },
    };
    if (!text_utils.isModelSafeText(source)) {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "ast_symbols requires a UTF-8 text file: {s}", .{input.path}) };
    }

    const symbols = genome.extract(arena, language, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "ast_symbols failed to parse {s}: {s}", .{ input.path, @errorName(err) }) },
    };
    const display_path = pathing.workspaceRelativePath(arena, ctx.workspace_root, target) catch input.path;
    return .{ .success = try formatSymbols(ctx.allocator, display_path, symbols) };
}

fn formatSymbols(alloc: Allocator, path: []const u8, symbols: []const genome.Symbol) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.print("[ast] {d} symbols in {s}\n", .{ symbols.len, path }) catch return error.OutOfMemory;
    for (symbols) |symbol| {
        out.writer.print("{s}:{d}: {s} {s}\n", .{
            path,
            symbol.start_row + 1,
            kindLabel(symbol.kind),
            symbol.name,
        }) catch return error.OutOfMemory;
        if (out.written().len > max_output_bytes) {
            out.writer.writeAll("... symbols truncated\n") catch return error.OutOfMemory;
            break;
        }
    }
    return try out.toOwnedSlice();
}

fn kindLabel(kind: genome.SymbolKind) []const u8 {
    return switch (kind) {
        .function => "function",
        .method => "method",
        .class => "class",
        .interface => "interface",
        .struct_ => "struct",
        .trait => "trait",
        .type_alias => "type_alias",
        .binding => "binding",
    };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "ast_symbols call parses an external source file outside the primary workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    try tmp.dir.createDirPath(std.testing.io, "external");
    {
        var file = try tmp.dir.createFile(std.testing.io, "external/lib.rs", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "pub fn external_symbol() {}\n");
    }

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external_file = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external/lib.rs");
    defer alloc.free(external_file);

    var input = Input{ .path = try alloc.dupe(u8, external_file) };
    defer input.deinit(alloc);
    const erased = tool_dispatch.ToolInput{ .ptr = &input, .deinit_fn = testNoopInputDeinit };
    var result = try call(.{
        .allocator = alloc,
        .workspace_root = workspace,
    }, erased);
    defer result.deinit(alloc);
    switch (result) {
        .success => |output| try std.testing.expect(std.mem.indexOf(u8, output, "function external_symbol") != null),
        .failure => |failure| return std.testing.expectEqualStrings("expected success", failure),
        .rich => return error.TestUnexpectedResult,
    }
}

fn testNoopInputDeinit(_: *anyopaque, _: Allocator) void {}

test "ast_symbols formatSymbols renders one-based declaration locations" {
    const symbols = [_]genome.Symbol{
        .{ .name = "Wallet", .kind = .class, .start_byte = 0, .end_byte = 6, .start_row = 2 },
        .{ .name = "deposit", .kind = .method, .start_byte = 10, .end_byte = 17, .start_row = 4 },
    };
    const output = try formatSymbols(std.testing.allocator, "src/wallet.ts", &symbols);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "[ast] 2 symbols in src/wallet.ts\n" ++
            "src/wallet.ts:3: class Wallet\n" ++
            "src/wallet.ts:5: method deposit\n",
        output,
    );
}
