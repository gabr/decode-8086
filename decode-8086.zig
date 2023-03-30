const std     = @import("std");
const fs      = std.fs;
const mem     = std.mem;
const math    = std.math;
const process = std.process;

pub fn main() !void {
    // just get memory in pages and free all at the end
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // handle args
    var args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Expected path to binary file\n", .{});
        return;
    }

    const asm_file_path = args[1];
    std.debug.print("decoding file: {s}\n", .{asm_file_path});

    if (mem.endsWith(u8, fs.path.extension(asm_file_path), ".asm")) {
        std.debug.print("Expected binary file but got an .asm one!\n", .{});
        return;
    }

    // open file
    var asm_file_absolute_path = try fs.path.resolve(allocator, &[_][]const u8{asm_file_path});
    const asm_file = try fs.openFileAbsolute(asm_file_absolute_path, .{});
    defer asm_file.close();

    const asm_file_content = try asm_file.readToEndAlloc(allocator, math.maxInt(usize));
    std.debug.print("bytes to decode ({}): {x}\n", .{asm_file_content.len, std.fmt.fmtSliceHexLower(asm_file_content)});


    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    // start by writting filename comment
    try stdout.print("; {s}\n\n", .{asm_file_path});

    // then decode the binary file into asm
    try decode8086(asm_file_content, stdout);

    // and flush the buffered output into the stdout
    try bw.flush();
}

/// Decodes 8086 instructios and writes ASM representation to given output stream
fn decode8086(bytes: []u8, outputWriter: anytype) !void {
    try outputWriter.writeAll("bits 16\n\n");
    _ = bytes;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
