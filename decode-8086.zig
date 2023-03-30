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
    //std.debug.print("bytes to decode ({}): {x}\n", .{asm_file_content.len, std.fmt.fmtSliceHexLower(asm_file_content)});

    // create output writer - we are writing to standard output
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    // start by writting filename comment
    try stdout.print("; {s}\n\n", .{asm_file_path});

    // then decode the binary file into asm
    try decode8086(asm_file_content, stdout);

    // and flush the buffered output
    try bw.flush();
}

/// Decodes 8086 instructions and writes ASM representation to given output writer
fn decode8086(bytes: []u8, output_writer: anytype) !void {
    try output_writer.writeAll("bits 16\n\n");

    var bytes_read: usize = 0;
    while (bytes_read < bytes.len) {
        const start_bytes_read = bytes_read;

        bytes_read += try Parsers.MOV(bytes[bytes_read..], output_writer);

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
    // converts reg and w values to reg string representation
    fn parseReg(reg: u3, w: u1) []const u8 {
        return switch(reg) {
            0b000 => if (w == 0) "al" else "ax",
            0b001 => if (w == 0) "cl" else "cx",
            0b010 => if (w == 0) "dl" else "dx",
            0b011 => if (w == 0) "bl" else "bx",
            0b100 => if (w == 0) "ah" else "sp",
            0b101 => if (w == 0) "ch" else "bp",
            0b110 => if (w == 0) "dh" else "si",
            0b111 => if (w == 0) "bh" else "di",
        };
    }

    pub fn MOV(bytes: []u8, output_writer: anytype) !usize {
        // 1000 1001 1101 1001 -> mov cx, bx
        const MOVRegToReg = packed struct {
            w: u1, d: u1, type: u6,
            rm: u3, reg: u3, mod: u2,
        };

        var bytes_read: usize = 0;
        while (true) {
            // do we have enough bytes
            if (bytes.len + bytes_read < @sizeOf(MOVRegToReg)) {
                break;
            }

            // cast to struct
            const mov = @ptrCast(*align(1) const MOVRegToReg, bytes.ptr + bytes_read).*;
            //std.debug.print("MOV: {}\n", .{mov});

            // validate
            if (mov.type != 0b100010 or  // we support only one mov type
                mov.mod  != 0b11 or      // ane only register mode
                mov.d    != 0) {         // d == 0 means that the source register
                                         // is in src field, no idea what happens if d == 1
              break;
            }

            // found instruction so move the bytes
            bytes_read += @sizeOf(MOVRegToReg);

            // output parsed instruction
            try output_writer.print("mov {s}, {s}\n", .{
                parseReg(mov.rm, mov.w),
                parseReg(mov.reg, mov.w) });
        }

        return bytes_read;
    }
};

test "MOV test" {
    // TODO(agabrys): write test for mov
}
