const std = @import("std");
const protobuf = @import("protobuf");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    /////////////////////
    // Targets Section
    /////////////////////

    const lib = b.addStaticLibrary(.{
        .name = "experiment",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "experiment",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (target.query.os_tag == .emscripten) {
        const emsdk_path = std.posix.getenv("EMSDK").?;
        const include_path = b.pathJoin(&.{ emsdk_path, "/upstream/emscripten/cache/sysroot/include" });
        lib.addSystemIncludePath(.{ .cwd_relative = include_path });
    }

    const arrow_includes = b.option([]const []const u8, "arrow_includes", "Arrow include paths") orelse &[_][]const u8{
        "arrow/cpp/src",
        "arrow-build/src",
        ".",
    };

    const arrow_libraries = [_][]const u8{"arrow-build/release"};

    for (arrow_includes) |path| {
        lib.addSystemIncludePath(b.path(path));
        exe.addSystemIncludePath(b.path(path));
    }

    for (arrow_libraries) |path| {
        lib.addLibraryPath(b.path(path));
        exe.addLibraryPath(b.path(path));
    }

    lib.linkLibCpp();
    exe.linkSystemLibrary("arrow");
    exe.linkLibrary(lib);

    /////////////////////
    // Protobuf Section
    /////////////////////

    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    const gen_proto = b.step("gen-proto", "generates zig files from protocol buffer definitions");
    const protoc_step = protobuf.RunProtocStep.create(b, protobuf_dep.builder, b.graph.host, .{
        // out directory for the generated zig files
        .destination_directory = b.path("src/generated_protos"),
        .source_files = &.{
            "protos/perspective.proto",
        },
        .include_directories = &.{},
    });

    gen_proto.dependOn(&protoc_step.step);
    // lib.step.dependOn(&protoc_step.step);
    // exe.step.dependOn(&protoc_step.step);

    lib.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));

    /////////////////////
    // Install Section
    /////////////////////

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    if (target.result.os.tag != .emscripten) {
        // b.installArtifact(exe);
    }
    // This is segfaulting zig lol
    // _ = lib.getEmittedH();
    b.installArtifact(lib);

    /////////////////////
    // Run Section
    /////////////////////

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    /////////////////
    // Test Section
    /////////////////

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    for (arrow_includes) |path| {
        lib_unit_tests.addSystemIncludePath(b.path(path));
    }

    for (arrow_libraries) |path| {
        lib_unit_tests.addLibraryPath(b.path(path));
    }

    lib_unit_tests.linkLibCpp();
    lib_unit_tests.linkSystemLibrary("arrow");
    lib_unit_tests.addCSourceFile(.{
        .file = b.path("ffi/bridge.cpp"),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
