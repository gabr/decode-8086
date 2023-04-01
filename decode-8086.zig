const std     = @import("std");
const fs      = std.fs;
const mem     = std.mem;
const math    = std.math;
const process = std.process;
const debug   = std.debug;
const testing = std.testing;

pub fn main() !void {
    // just get memory in pages and free all at the end
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // handle args
    var args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len < 2) {
        return error.MissingPath;
    }

    const file_path = args[1];
    debug.print("decoding file: {s}\n", .{file_path});

    if (mem.endsWith(u8, fs.path.extension(file_path), ".asm")) {
        return error.UnexpectedAsmExtension;
    }

    // open file
    var file_absolute_path = try fs.path.resolve(allocator, &[_][]const u8{file_path});
    const file = try fs.openFileAbsolute(file_absolute_path, .{});
    defer file.close();

    const file_content = try file.readToEndAlloc(allocator, math.maxInt(usize));
    //debug.print("bytes to decode ({}): {x}\n", .{file_content.len, std.fmt.fmtSliceHexLower(file_content)});

    // create output writer - we are writing to standard output
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    // start by writting filename comment
    try stdout.print("; {s}\n\n", .{file_path});

    // then decode the binary file into asm
    try decode8086(file_content, stdout);

    // and flush the buffered output
    try bw.flush();
}

/// Decodes 8086 instructions and writes ASM representation to given output writer
fn decode8086(bytes: []u8, output_writer: anytype) !void {
    try output_writer.writeAll("bits 16\n\n");

    var bytes_read: usize = 0;
    while (bytes_read < bytes.len) {
        const start_bytes_read = bytes_read;

        bytes_read += try Parsers.MOV_RegMemToFromReg(bytes[bytes_read..], output_writer);

        // if no bytes were consumed we have an unknown instruction
        if (bytes_read <= start_bytes_read) {
            return error.UnknownInstruction;
        }
    }
}

/// Each parser parses as many instructions after each other as possible.
/// Assumes that the first instruction starts at the beginning of given bytes
/// and will not search past first byte and does not skip any bytes.
/// Writes parsed instructions to output_writer and returns parsed bytes count.
const Parsers = struct { // this struct is used only as a namespace
    /// Registers table, pass w and reg to get the register name
    const regs = &[_][]const []const u8 {
        &[_][]const u8{ "al", "cl", "dl", "bl", "ah", "ch", "dh", "bh", },
        &[_][]const u8{ "ax", "cx", "dx", "bx", "sp", "bp", "si", "di", },
    };

    /// MOV Register/memory to/from register
    pub fn MOV_RegMemToFromReg(bytes: []const u8, output_writer: anytype) !usize {
        const MOV = packed struct {
            w: u1, d: u1, type: u6,
            rm: u3, reg: u3, mod: u2,
        };

        var bytes_read: usize = 0;
        while (true) {
            // do we have enough bytes
            if (bytes.len - bytes_read < @sizeOf(MOV)) {
                break;
            }

            // cast to struct
            const mov = @ptrCast(*align(1) const MOV, bytes.ptr + bytes_read).*;
            //debug.print("MOV: {}\n", .{mov});

            // validate type
            if (mov.type != 0b100010) { // register/memory to/from register MOV
              break;
            }

            switch (mov.mod) {
                // register mode
                0b11 => {
                    // found instruction so move the bytes
                    bytes_read += @sizeOf(MOV);

                    // output parsed instruction
                    if (mov.d == 0) { // source is in reg field
                        try output_writer.print("mov {s}, {s}\n", .{
                            regs[mov.w][mov.rm],
                            regs[mov.w][mov.reg] });
                    } else {
                        try output_writer.print("mov {s}, {s}\n", .{
                            regs[mov.w][mov.reg],
                            regs[mov.w][mov.rm] });
                    }
                },
                else => return error.UnsupportedMod,
            }
        }

        return bytes_read;
    }
};

test "MOV_RegMemToFromReg" {
    const expected_output =
        \\mov cx, bx
        \\mov ch, ah
        \\mov dx, bx
        \\mov si, bx
        \\mov bx, di
        \\mov al, cl
        \\mov ch, ch
        \\mov bx, ax
        \\mov bx, si
        \\mov sp, di
        \\mov bp, ax
        \\
    ;

    const bytes = [_]u8 {
        0x89, 0xD9, // mov cx, bx
        0x88, 0xE5, // mov ch, ah
        0x89, 0xDA, // mov dx, bx
        0x89, 0xDE, // mov si, bx
        0x89, 0xFB, // mov bx, di
        0x88, 0xC8, // mov al, cl
        0x88, 0xED, // mov ch, ch
        0x89, 0xC3, // mov bx, ax
        0x89, 0xF3, // mov bx, si
        0x89, 0xFC, // mov sp, di
        0x89, 0xC5, // mov bp, ax
    };

    var output_buffer: [expected_output.len]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output_buffer);
    var output_writer = fbs.writer();

    const bytes_read = try Parsers.MOV_RegMemToFromReg(&bytes, output_writer);

    try testing.expectEqual(bytes.len, bytes_read);
    try testing.expectEqualSlices(u8, expected_output[0..], output_buffer[0..]);
}
