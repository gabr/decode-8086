const std     = @import("std");
const mem     = std.mem;
const debug   = std.debug;
const process = std.process;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Validate if the build is being run with the expected compiler version
    validateZigVersion(b, "0.11.0-dev");

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "d",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "d.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    exe.install();

    // This *creates* a RunStep in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = exe.run();

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    } else {
        // default args if nothing was specified
        run_cmd.addArg("../materials_repo/perfaware/part1/listing_0038_many_register_mov");
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing.
    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "d.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

/// Runs "zig version" and compares with given value
/// If versions are not equal it will halt the build process.
fn validateZigVersion(b: *std.Build, expected_version_prefix: []const u8) void {
    const version = mem.trimRight(u8, b.exec(&[_][]const u8{ b.zig_exe, "version" }), "\n\t\r");
    if (false == mem.startsWith(u8, version, expected_version_prefix)) {
        debug.print(
            "\n" ++
            "  Stop, stop, stop!\n" ++
            "  You're going to take someone's eye out.\n" ++
            "  Besides, you're executing it wrong.\n" ++
            "  It's zig version: {s}*\n" ++
            "               not: {s}\n" ++
            "\n" ++
            "  Make sure to use the zig compiler in version: {s}\n\n",
            .{ expected_version_prefix, version, expected_version_prefix } );
        process.exit(1);
    }
}
