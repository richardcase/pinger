const std = @import("std");

pub fn build(b: *std.Build) void {
    // Zig 0.16's linker chokes on the .sframe section in the host glibc crt1.o
    // (binutils/gcc 15), so default to the bundled musl ABI on Linux. This also
    // yields static binaries, matching the release build goals.
    const default_target: std.Target.Query = if (@import("builtin").target.os.tag == .linux)
        .{ .abi = .musl }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "version string embedded in the binary") orelse "dev";
    const integration = b.option(bool, "integration", "enable integration tests (needs root/CAP_NET_RAW)") orelse false;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "integration", integration);
    const options_mod = options.createModule();

    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });
    const toml_mod = toml_dep.module("toml");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("build_options", options_mod);
    exe_mod.addImport("toml", toml_mod);

    const exe = b.addExecutable(.{
        .name = "pinger",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run pinger");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("build_options", options_mod);
    test_mod.addImport("toml", toml_mod);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests touch raw sockets and the filesystem, so they need
    // root/CAP_NET_RAW and must be run as a standalone binary (the `zig build`
    // test runner's IPC can't host them). Build with:
    //   zig build itest -Dintegration && sudo ./zig-out/bin/pinger-itest
    const itest = b.addTest(.{ .name = "pinger-itest", .root_module = test_mod });
    const install_itest = b.addInstallArtifact(itest, .{});
    const itest_step = b.step("itest", "Install the integration test binary (use with -Dintegration, run as root)");
    itest_step.dependOn(&install_itest.step);
}
