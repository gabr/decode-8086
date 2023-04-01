const std     = @import("std");
const io      = std.io;
const fs      = std.fs;
const fmt     = std.fmt;
const mem     = std.mem;
const meta    = std.meta;
const math    = std.math;
const heap    = std.heap;
const debug   = std.debug;
const process = std.process;
const testing = std.testing;

pub fn main() !void {
    // just get memory in pages and free all at the end
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
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
    //debug.print("bytes to decode ({}): {x}\n", .{file_content.len, fmt.fmtSliceHexLower(file_content)});

    // create output writer - we are writing to standard output
    const stdout_file = io.getStdOut().writer();
    var bw = io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    // start by writting filename comment
    try stdout.print("; {s}\n\n", .{file_path});

    // then decode the binary file into asm
    decode8086(file_content, stdout) catch |err| {
        // and flush the buffered output
        try bw.flush();
        return err;
    };

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

    /// effective address calculation where index is the R/M field
    const rms = &[_][]const u8 { "bx + si", "bx + di", "bp + si", "bp + di", "si", "di", "bp", "bx" };

    /// Helper method for outputing MOV instructions which can have reversed
    /// source with destination based on 'd' field.
    fn outputMOV(
        d: u1,
        comptime dest_format: []const u8, dest_data: anytype,
        comptime  src_format: []const u8,  src_data: anytype,
        output_writer: anytype
    ) !void {
        try output_writer.writeAll("mov ");
        if (d == 0) {
            try output_writer.print(dest_format, dest_data);
            try output_writer.writeAll(", ");
            try output_writer.print(src_format, src_data);
        } else {
            try output_writer.print(src_format, src_data);
            try output_writer.writeAll(", ");
            try output_writer.print(dest_format, dest_data);
        }
        try output_writer.writeAll("\n");
    }

    /// MOV Register/memory to/from register
    pub fn MOV_RegMemToFromReg(bytes: []const u8, output_writer: anytype) !usize {
        const MOV = packed struct {
            w: u1, d: u1, type: u6,
            rm: u3, reg: u3, mod: u2,
        };

        var work_buffer = bytes;
        while (true) {
            // do we have enough bytes
            if (work_buffer.len < @sizeOf(MOV)) {
                break;
            }

            // cast to struct
            const mov = @ptrCast(*align(1) const MOV, work_buffer.ptr).*;
            //debug.print("MOV: {}\n", .{mov});

            // validate type
            if (mov.type != 0b100010) { // register/memory to/from register MOV
              break;
            }

            switch (mov.mod) {
                // memory mode
                0b00 => {
                    // 16-bit direct address
                    if (mov.rm == 0b110) {
                        // do we have enough bytes
                        if (work_buffer.len < @sizeOf(MOV) + 2) {
                            debug.print(
                                "found MOV with mod: 00 and R/M: 110 but not enough bytes for 16-bit direct address\n" ++
                                "MOV: {}\n" ++
                                "bytes left ({}): [{x}]\n",
                                .{mov, work_buffer.len, fmt.fmtSliceHexLower(work_buffer)});
                            return error.NotEnoughBytes;
                        }

                        work_buffer = work_buffer[@sizeOf(MOV)..];

                        // "direct address" from two additional bytes
                        const direct_address = @ptrCast(*align(1) const u16, work_buffer.ptr).*;
                        work_buffer = work_buffer[@sizeOf(u16)..];

                        try outputMOV( mov.d,
                            "[{d}]", .{direct_address},
                             "{s}",  .{regs[mov.w][mov.reg]},
                            output_writer);
                    } else {
                        work_buffer = work_buffer[@sizeOf(MOV)..];
                        try outputMOV(
                            mov.d,
                            "[{s}]", .{rms[mov.rm]},
                             "{s}",  .{regs[mov.w][mov.reg]},
                            output_writer);
                    }
                },

                // memory mode with 8-bit or 16-bit displacement
                0b01, 0b10 => {
                    // do we have enough bytes
                    const additional_bytes: u8 = mov.mod; // have to cast to not overflow in the add below
                    if (work_buffer.len < @sizeOf(MOV) + additional_bytes) {
                        debug.print(
                            "found MOV with mod: 01 but not enough bytes for {d}-bit displacement\n" ++
                            "MOV: {}\n" ++
                            "bytes left ({}): [{x}]\n",
                            .{additional_bytes*8, mov, work_buffer.len, fmt.fmtSliceHexLower(work_buffer)});
                        return error.NotEnoughBytes;
                    }
                    work_buffer = work_buffer[@sizeOf(MOV)..];

                    // displacement from additional bytes
                    var displacement: u16 = if (mov.mod == 1)
                             @ptrCast(*align(1) const  u8, work_buffer.ptr).*
                        else @ptrCast(*align(1) const u16, work_buffer.ptr).*;
                    work_buffer = work_buffer[mov.mod..];

                    if (displacement == 0) {
                        try outputMOV( mov.d,
                            "[{s}]", .{rms[mov.rm]},
                             "{s}",  .{regs[mov.w][mov.reg]},
                            output_writer);
                    } else {
                        try outputMOV( mov.d,
                            "[{s} + {d}]", .{rms[mov.rm], displacement},
                             "{s}",        .{regs[mov.w][mov.reg]},
                            output_writer);
                    }
                },

                // register mode
                0b11 => {
                    work_buffer = work_buffer[@sizeOf(MOV)..];
                    try outputMOV(
                        mov.d,
                        "{s}", .{regs[mov.w][mov.rm]},
                        "{s}", .{regs[mov.w][mov.reg]},
                        output_writer);
                },
            }
        }

        return bytes.len - work_buffer.len;
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
    var fbs = io.fixedBufferStream(&output_buffer);
    var output_writer = fbs.writer();

    const bytes_read = try Parsers.MOV_RegMemToFromReg(&bytes, output_writer);

    try testing.expectEqual(bytes.len, bytes_read);
    try testing.expectEqualSlices(u8, expected_output[0..], output_buffer[0..]);
}
