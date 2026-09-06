const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const command_environment = @import("../execution/command_environment.zig");
const io_mod = @import("../shared/io.zig");
const self_exe = @import("../shared/self_exe.zig");

const Allocator = std.mem.Allocator;

pub const ResolveError = error{
    MissingLoginShell,
    RelativeShellPath,
    UnsupportedShell,
};

pub const Profile = command_environment.Profile;
pub const Environment = command_environment.Environment;

const rush_executable_token = "fx";

const ShellKind = enum { bash, zsh };

fn shellKind(path: []const u8) ?ShellKind {
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, "bash")) return .bash;
    if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    return null;
}

fn fallbackLoginShell() []const u8 {
    return if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash";
}

fn supportedLoginShell(configured_login_shell: ?[]const u8) ResolveError![]const u8 {
    const path = configured_login_shell orelse return error.MissingLoginShell;
    if (!std.fs.path.isAbsolute(path)) return error.RelativeShellPath;
    return if (shellKind(path) != null) path else fallbackLoginShell();
}

pub const Invocation = struct {
    path: []const u8,
    values: [6][]const u8 = @splat(""),
    len: usize = 0,

    pub fn argv(self: *const Invocation) []const []const u8 {
        return self.values[0..self.len];
    }

    fn append(self: *Invocation, value: []const u8) void {
        self.values[self.len] = value;
        self.len += 1;
    }

    pub fn setCommand(self: *Invocation, command: []const u8) void {
        self.append("-c");
        self.append(command);
    }
};
pub const rush_internal_mode = "--fx-internal-rush";

/// Builds the argv used to re-exec the embedded Rush app through fx.
///
/// `self_executable` is comptime so release callers can provide the absolute
/// fx path from build configuration without discovering it at runtime. Tests
/// and development builds may pass null, which deliberately uses the stable
/// internal executable token.
pub fn rushInvocation(
    self_executable: ?[]const u8,
    clean_start: bool,
) ResolveError!Invocation {
    const executable = self_executable orelse rush_executable_token;
    if (self_executable != null and !std.fs.path.isAbsolute(executable)) {
        return error.RelativeShellPath;
    }

    var result = Invocation{ .path = executable };
    result.append(executable);
    result.append(rush_internal_mode);
    if (!clean_start) result.append("--login");
    result.append("-i");
    return result;
}

pub fn capturedRushInvocation(
    self_executable: ?[]const u8,
    clean_start: bool,
    command: []const u8,
) ResolveError!Invocation {
    var invocation = try rushInvocation(self_executable, clean_start);
    removeInteractiveFlag(&invocation);
    invocation.setCommand(command);
    return invocation;
}

/// Builds the argv that re-executes this omfx process as the embedded rush
/// shell, resolving the on-disk self path so spawns do not depend on PATH.
pub fn capturedSelfInvocation(
    alloc: Allocator,
    clean_start: bool,
    command: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
    // pathForReexec consults the OS for the on-disk executable; on macOS the
    // underlying query carries a wide error set, which collapses here so the
    // public resolver error set stays small.
    const self_path = self_exe.pathForReexec(alloc) catch return error.UnsupportedShell;
    var invocation = try rushInvocation(self_path, clean_start);
    removeInteractiveFlag(&invocation);
    invocation.setCommand(command);
    return invocation;
}

pub fn resolve(
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) ResolveError!Invocation {
    const Selection = struct { path: []const u8, clean_start: bool };
    const selection: Selection = switch (shell) {
        .user_login => .{ .path = try supportedLoginShell(configured_login_shell), .clean_start = false },
        .executable => |value| .{ .path = value.path, .clean_start = value.clean_start },
    };
    if (!std.fs.path.isAbsolute(selection.path)) return error.RelativeShellPath;
    const kind = shellKind(selection.path) orelse return error.UnsupportedShell;
    var result = Invocation{ .path = selection.path };
    result.append(selection.path);
    switch (kind) {
        .bash => {
            if (selection.clean_start) {
                result.append("--noprofile");
                result.append("--norc");
            } else result.append("--login");
            result.append("-i");
        },
        .zsh => {
            if (selection.clean_start) result.append("-f") else result.append("-l");
            result.append("-i");
        },
    }
    return result;
}

pub fn configuredLoginShellInto(buffer: []u8) ?[]const u8 {
    if (comptime !builtin.link_libc or builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return null;
    }
    var entry: std.c.passwd = undefined;
    var scratch: [4096]u8 = undefined;
    var found: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(
        std.c.getuid(),
        &entry,
        &scratch,
        scratch.len,
        &found,
    ) != 0) return null;
    const record = found orelse return null;
    const shell_ptr = record.shell orelse return null;
    const shell = std.mem.span(shell_ptr);
    if (shell.len == 0 or shell.len > buffer.len) return null;
    @memcpy(buffer[0..shell.len], shell);
    return buffer[0..shell.len];
}

pub fn environment(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: ?Profile,
) (ResolveError || Allocator.Error)!Environment {
    _ = configured_login_shell;
    const selected = profile orelse .user;
    return switch (selected) {
        .clean => .{ .clean = try alloc.dupe(u8, rush_executable_token) },
        .user => .{ .user = try alloc.dupe(u8, rush_executable_token) },
    };
}

pub fn environmentForShellSpec(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) (ResolveError || Allocator.Error)!Environment {
    const invocation = try resolve(configured_login_shell, shell);
    return switch (shell) {
        .user_login => .{ .user = try alloc.dupe(u8, invocation.path) },
        .executable => |value| if (value.clean_start)
            .{ .clean = try alloc.dupe(u8, invocation.path) }
        else
            .{ .user = try alloc.dupe(u8, invocation.path) },
    };
}

pub fn profileShell(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: Profile,
) (ResolveError || Allocator.Error)!contracts.ShellSpec {
    return switch (profile) {
        .clean => blk: {
            const path = try supportedLoginShell(configured_login_shell);
            _ = try resolve(null, .{ .executable = .{ .path = path, .clean_start = true } });
            break :blk .{ .executable = .{
                .path = try alloc.dupe(u8, path),
                .clean_start = true,
            } };
        },
        .user => blk: {
            const configured = configured_login_shell orelse break :blk .user_login;
            const path = try supportedLoginShell(configured);
            if (std.mem.eql(u8, path, configured)) break :blk .user_login;
            break :blk .{ .executable = .{ .path = try alloc.dupe(u8, path) } };
        },
    };
}

pub fn capturedInvocation(
    alloc: Allocator,
    environment_value: Environment,
    command: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
    switch (environment_value) {
        .legacy, .workspace_clean => return error.UnsupportedShell,
        .clean => |path| {
            if (std.mem.eql(u8, path, rush_executable_token))
                return capturedSelfInvocation(alloc, true, command);
            var invocation = try resolve(null, .{ .executable = .{ .path = path, .clean_start = true } });
            removeInteractiveFlag(&invocation);
            invocation.setCommand(command);
            return invocation;
        },
        .user => |path| {
            if (std.mem.eql(u8, path, rush_executable_token))
                return capturedSelfInvocation(alloc, false, command);
            var invocation = try resolve(path, .user_login);
            if (shellKind(path) == .bash) {
                removeInteractiveFlag(&invocation);
                invocation.append("-O");
                invocation.append("expand_aliases");
            }
            invocation.setCommand(command);
            return invocation;
        },
    }
}

pub fn formatInvocationCommand(
    alloc: Allocator,
    invocation: *const Invocation,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    for (invocation.argv(), 0..) |word, index| {
        if (index != 0) try output.append(alloc, ' ');
        try appendShellWord(&output, alloc, word);
    }
    return output.toOwnedSlice(alloc);
}

fn removeInteractiveFlag(invocation: *Invocation) void {
    std.debug.assert(invocation.len > 0);
    std.debug.assert(std.mem.eql(u8, invocation.values[invocation.len - 1], "-i"));
    invocation.len -= 1;
}

pub fn buildBootstrap(
    alloc: Allocator,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    command_path: ?[]const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);

    try output.appendSlice(alloc, "set +x; ");
    if (command_path) |path| {
        try output.appendSlice(alloc, "fx_terminal_command=$(< ");
        try appendShellWord(&output, alloc, path);
        try output.appendSlice(alloc, ") || exit 125; ");
    }
    try appendMarker(&output, alloc, executable, control_path, nonce, "shell-ready");
    if (command_path) |_| {
        try output.appendSlice(alloc, " || exit 125; ");
        try appendMarker(
            &output,
            alloc,
            executable,
            control_path,
            nonce,
            "command-started",
        );
        try output.appendSlice(
            alloc,
            " || exit 125; builtin eval -- \"$fx_terminal_command\"; " ++
                "fx_terminal_status=$?; exit \"$fx_terminal_status\"\n",
        );
    } else {
        try output.appendSlice(alloc, " || exit 125\n");
    }
    return output.toOwnedSlice(alloc);
}

pub fn buildSourceCommand(
    alloc: Allocator,
    bootstrap_path: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    try output.appendSlice(alloc, ". ");
    try appendShellWord(&output, alloc, bootstrap_path);
    try output.append(alloc, '\n');
    return output.toOwnedSlice(alloc);
}

fn appendMarker(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    event: []const u8,
) Allocator.Error!void {
    try appendShellWord(output, alloc, executable);
    inline for (.{
        "--fx-internal-terminal-control",
        control_path,
        nonce,
        event,
    }) |word| {
        try output.append(alloc, ' ');
        try appendShellWord(output, alloc, word);
    }
}

fn appendShellWord(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    word: []const u8,
) Allocator.Error!void {
    try output.append(alloc, '\'');
    for (word) |byte| {
        if (byte == '\'') {
            try output.appendSlice(alloc, "'\"'\"'");
        } else {
            try output.append(alloc, byte);
        }
    }
    try output.append(alloc, '\'');
}

test "shell resolver preserves explicit Bash and zsh startup contracts" {
    const bash = try resolve("/bin/bash", .{ .executable = .{ .path = "/opt/bin/bash" } });
    try std.testing.expectEqualStrings("/opt/bin/bash", bash.path);
    try std.testing.expectEqualStrings("/opt/bin/bash", bash.argv()[0]);
    try std.testing.expectEqualStrings("--login", bash.argv()[1]);
    try std.testing.expectEqualStrings("-i", bash.argv()[2]);

    const clean_zsh = try resolve("/bin/zsh", .{ .executable = .{ .path = "/opt/bin/zsh", .clean_start = true } });
    try std.testing.expectEqualStrings("/opt/bin/zsh", clean_zsh.path);
    try std.testing.expectEqualStrings("-f", clean_zsh.argv()[1]);
    try std.testing.expectEqualStrings("-i", clean_zsh.argv()[2]);
}

test "shell resolver keeps default rush clean capture isolated from PATH" {
    const invocation = try capturedInvocation(
        std.testing.allocator,
        .{ .clean = rush_executable_token },
        "printf clean",
    );
    defer std.testing.allocator.free(invocation.path);
    try std.testing.expect(std.fs.path.isAbsolute(invocation.path));
    try std.testing.expectEqualStrings(rush_internal_mode, invocation.argv()[1]);
    try std.testing.expectEqualStrings("-c", invocation.argv()[2]);
    try std.testing.expectEqualStrings("printf clean", invocation.argv()[3]);
}

test "bootstrap quotes private paths and separates command completion" {
    const commandless = try buildBootstrap(
        std.testing.allocator,
        "/tmp/fx'bin",
        "/tmp/control",
        "nonce",
        null,
    );
    defer std.testing.allocator.free(commandless);
    try std.testing.expectEqualStrings(
        "set +x; '/tmp/fx'\"'\"'bin' '--fx-internal-terminal-control' " ++
            "'/tmp/control' 'nonce' 'shell-ready' || exit 125\n",
        commandless,
    );

    const command = try buildBootstrap(
        std.testing.allocator,
        "/tmp/fx",
        "/tmp/control",
        "nonce",
        "/tmp/command",
    );
    defer std.testing.allocator.free(command);
    try std.testing.expect(
        std.mem.find(u8, command, "'command-started'") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, command, "builtin eval --") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, command, "exit \"$fx_terminal_status\"") != null,
    );

    const source = try buildSourceCommand(
        std.testing.allocator,
        "/tmp/bootstrap'file",
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings(
        ". '/tmp/bootstrap'\"'\"'file'\n",
        source,
    );
}
fn checkBootstrapAllocationFailures(alloc: Allocator) !void {
    const bootstrap = try buildBootstrap(
        alloc,
        "/tmp/fx",
        "/tmp/control",
        "nonce",
        "/tmp/command",
    );
    defer alloc.free(bootstrap);
    const source = try buildSourceCommand(alloc, "/tmp/bootstrap");
    defer alloc.free(source);
}
