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
fn decode8086(bytes: []const u8, output_writer: anytype) !void {
    try output_writer.writeAll("bits 16\n\n");

    var bytes_read: usize = 0;
    while (bytes_read < bytes.len) {
        const start_bytes_read = bytes_read;

        bytes_read += try Parsers.MOV_RegMemToFromReg   (bytes[bytes_read..], output_writer);
        bytes_read += try Parsers.MOV_ImmediateToRegMem (bytes[bytes_read..], output_writer);
        bytes_read += try Parsers.MOV_ImmediateToReg    (bytes[bytes_read..], output_writer);
        bytes_read += try Parsers.MOV_MemAccumulator    (bytes[bytes_read..], output_writer);

        // if no bytes were consumed we have an unknown instruction
        if (bytes_read <= start_bytes_read) {
            return error.UnknownInstruction;
        }
    }
}

/// Each parser parses only one instruction from given bytes.
/// Assumes that the instruction starts at the beginning of given buffer
/// and will not search past first byte and does not skip any bytes.
/// Writes parsed instruction to output_writer and returns parsed bytes count.
const Parsers = struct { // this struct is used only as a namespace
    /// Registers table, pass w and reg to get the register name
    const regs = &[_][]const []const u8 {
        &[_][]const u8{ "al", "cl", "dl", "bl", "ah", "ch", "dh", "bh", },
        &[_][]const u8{ "ax", "cx", "dx", "bx", "sp", "bp", "si", "di", },
    };

    /// effective address calculation where index is the R/M field
    const rms = &[_][]const u8 { "bx + si", "bx + di", "bp + si", "bp + di", "si", "di", "bp", "bx" };

    /// Will try to extract given HeaderType struct from given bytes and if
    /// that's possible will validate its type, advance bytes by the extracted
    /// amount and return extracted header.
    fn extractHeader(bytes: *[]const u8, comptime HeaderType: type, validate_type: u8) ?HeaderType {
        // test if we have enough bytes
        if (bytes.*.len < @sizeOf(HeaderType)) {
            return null;
        }

        // if so extract the header
        const header = @ptrCast(*align(1) const HeaderType, bytes.*.ptr).*;
        // and validate type value
        const header_type: u8 = header.type;
        if (header_type != validate_type) {
          return null;
        }

        // type is valid so advance the bytes slice by the header size
        bytes.* = bytes.*[@sizeOf(HeaderType)..];

        // and return
        return header;
    }

    /// Will use mov_header to calculate displacement size (if any) and extract
    /// its value (if any) and advance buffer by the amout of extracted bytes.
    /// If there is not enough bytes it will return error.
    fn extractMOVDisplacement(bytes: *[]const u8, mov_header: anytype) !i16 {
        var displacement_size: usize =
             if (mov_header.mod == 0b00 and mov_header.rm == 0b110) 2 // special case
        else if (mov_header.mod == 0b01) 1
        else if (mov_header.mod == 0b10) 2
        else 0;

        if (displacement_size == 0) {
            return 0;
        }

        if (bytes.*.len < displacement_size) {
            debug.print(
                "not enough bytes for {d}-bit displacement\n" ++
                "MOV: {}\n" ++
                "bytes left ({}): [{x}]\n",
                .{displacement_size*8, mov_header, bytes.*.len, fmt.fmtSliceHexLower(bytes.*)}
            );
            return error.NotEnoughBytes;
        }
        const displacement: i16 = if (displacement_size == 1)
                  @ptrCast(*align(1) const  i8, bytes.*.ptr).*
            else  @ptrCast(*align(1) const i16, bytes.*.ptr).*;
        bytes.* = bytes.*[displacement_size..];

        return displacement;
    }

    /// Helper method for outputting MOV instructions which can have reversed
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

    /// Extracts common logic for outputing MOV based on the MOD field
    fn outputMOVbasedOnMode(
        d:   u1,
        mod: u2,
        rm:  u3,
        displacement: i16,
        comptime value_format:        []const u8, value_data:          anytype,
        comptime register_mode_format:[]const u8, register_mode_value: anytype,
        output_writer: anytype,
    ) !void {
        switch (mod) {
            // memory mode
            0b00 => {
                // 16-bit direct address
                if (rm == 0b110) {
                    // in here the displacement is interpreted as direct address
                    const direct_address = displacement;

                    try outputMOV( d,
                        "[{d}]",      .{direct_address},
                        value_format, value_data,
                        output_writer );
                } else {
                    try outputMOV( d,
                        "[{s}]",      .{rms[rm]},
                        value_format, value_data,
                        output_writer );
                }
            },

            // memory mode with 8-bit or 16-bit displacement
            0b01, 0b10 => {
                if (displacement == 0) {
                    try outputMOV( d,
                        "[{s}]",      .{rms[rm]},
                        value_format, value_data,
                        output_writer );
                } else {
                    if (displacement < 0) {
                        try outputMOV( d,
                            "[{s} - {d}]", .{rms[rm], displacement*-1},
                            value_format,  value_data,
                            output_writer );
                    } else {
                        try outputMOV( d,
                            "[{s} + {d}]", .{rms[rm], displacement},
                            value_format,  value_data,
                            output_writer );
                    }
                }
            },

            // register mode
            0b11 => {
                try outputMOV( d,
                    register_mode_format, .{register_mode_value},
                    value_format,         value_data,
                    output_writer );
            },
        }
    }

    /// MOV Register/memory to/from register
    pub fn MOV_RegMemToFromReg(bytes: []const u8, output_writer: anytype) !usize {
        const MOV = packed struct {
            w: u1, d: u1, type: u6,
            rm: u3, reg: u3, mod: u2,
        };

        var work_buffer = bytes;
        const mov = extractHeader(&work_buffer, MOV, 0b00_100010)
            orelse return 0;

        const displacement = try extractMOVDisplacement(&work_buffer, mov);

        try outputMOVbasedOnMode(
            mov.d,
            mov.mod,
            mov.rm,
            displacement,
            "{s}", .{regs[mov.w][mov.reg]},
            "{s}", regs[mov.w][mov.rm],
            output_writer,
        );

        return bytes.len - work_buffer.len;
    }

    /// MOV Immediate to register/memory
    pub fn MOV_ImmediateToRegMem(bytes: []const u8, output_writer: anytype) !usize {
        const MOV = packed struct {
            w: u1, type: u7,
            rm: u3, unused: u3, mod: u2,
        };

        var work_buffer = bytes;
        const mov = extractHeader(&work_buffer, MOV, 0b0_1100011)
            orelse return 0;

        // extract displacement here because after it we have data which we
        // also would like to extract before the switch to have it in one place
        const displacement = try extractMOVDisplacement(&work_buffer, mov);

        // have to cast to not overflow in the add below
        const data_size: u8 = @as(u8, mov.w)+1;
        if (work_buffer.len < data_size) {
            debug.print(
                "found immediate to register/memory MOV but not enough bytes for {d}-bit data\n" ++
                "MOV: {}\n" ++
                "bytes left ({}): [{x}]\n",
                .{data_size*8, mov, work_buffer.len, fmt.fmtSliceHexLower(work_buffer)}
            );
            return error.NotEnoughBytes;
        }
        const data: i16 = if (mov.w == 0)
                 @ptrCast(*align(1) const  i8, work_buffer.ptr).*
            else @ptrCast(*align(1) const i16, work_buffer.ptr).*;
        work_buffer = work_buffer[data_size..];
        const data_prefix = if (mov.w == 0) "byte" else "word ";

        try outputMOVbasedOnMode(
            0,
            mov.mod,
            mov.rm,
            displacement,
            "{s} {d}", .{data_prefix, data},
            "[{s}]", rms[mov.rm],
            output_writer,
        );

        return bytes.len - work_buffer.len;
    }

    /// MOV Immediate to register
    pub fn MOV_ImmediateToReg(bytes: []const u8, output_writer: anytype) !usize {
        const MOV = packed struct {
            reg: u3, w: u1, type: u4,
        };

        var work_buffer = bytes;
        const mov = extractHeader(&work_buffer, MOV, 0b000_1011)
            orelse return 0;

        // do we have enough bytes
        const data_size: u8 = @as(u8, mov.w)+1;
        if (work_buffer.len < data_size) {
            debug.print(
                "found immediate to register MOV but not enough bytes for {d}-bit data\n" ++
                "MOV: {}\n" ++
                "bytes left ({}): [{x}]\n",
                .{data_size*8, mov, work_buffer.len, fmt.fmtSliceHexLower(work_buffer)}
            );
            return error.NotEnoughBytes;
        }
        const data = if (mov.w == 0)   // \/ we are signed this time
                 @ptrCast(*align(1) const  i8, work_buffer.ptr).*
            else @ptrCast(*align(1) const i16, work_buffer.ptr).*;
        // move by the data size - at least 1 byte, if mov.w is 1 then we have two bytes
        work_buffer = work_buffer[data_size..];

        try outputMOV( 0,
            "{s}", .{regs[mov.w][mov.reg]},
            "{d}", .{data},
            output_writer );

        return bytes.len - work_buffer.len;
    }

    /// MOV Memory to accumulator and Accumulator to Memory
    /// Two accmulator instructions in one function.
    /// The only difference is the order so the output will be
    /// flipped around depending on the instruction type.
    pub fn MOV_MemAccumulator(bytes: []const u8, output_writer: anytype) !usize {
        const MOV = packed struct {
            w: u1, type: u7,
        };

        var work_buffer = bytes;
        const mov = extractHeader(&work_buffer, MOV, 0b0_1010000)
             orelse extractHeader(&work_buffer, MOV, 0b0_1010001)
             orelse return 0;

        // do we have enough bytes
        const address_size: u8 = @as(u8, mov.w)+1;
        if (work_buffer.len < address_size) {
            debug.print(
                "found memory to accumulator MOV but not enough bytes for {d}-bit address\n" ++
                "MOV: {}\n" ++
                "bytes left ({}): [{x}]\n",
                .{address_size*8, mov, work_buffer.len, fmt.fmtSliceHexLower(work_buffer)}
            );
            return error.NotEnoughBytes;
        }
        const address = if (mov.w == 0)
                 @ptrCast(*align(1) const  u8, work_buffer.ptr).*
            else @ptrCast(*align(1) const u16, work_buffer.ptr).*;
        work_buffer = work_buffer[address_size..];

        const flip: u1 = if (mov.type == 0b0_1010001) 1 else 0;
        try outputMOV( flip,
             "ax",   .{},
            "[{d}]", .{address},
            output_writer );

        return bytes.len - work_buffer.len;
    }
};

test "decode8086" {
    // setup
    const TestCase = struct {
        bytes:  []const u8,
        output: []const u8,
    };
    const test_cases = [_]TestCase{
        .{ .bytes = &[_]u8{ 0x89, 0xD9 },              .output = "mov cx, bx" },
        .{ .bytes = &[_]u8{ 0x88, 0xE5 },              .output = "mov ch, ah" },
        .{ .bytes = &[_]u8{ 0x89, 0xDA },              .output = "mov dx, bx" },
        .{ .bytes = &[_]u8{ 0x89, 0xDE },              .output = "mov si, bx" },
        .{ .bytes = &[_]u8{ 0x89, 0xFB },              .output = "mov bx, di" },
        .{ .bytes = &[_]u8{ 0x88, 0xC8 },              .output = "mov al, cl" },
        .{ .bytes = &[_]u8{ 0x88, 0xED },              .output = "mov ch, ch" },
        .{ .bytes = &[_]u8{ 0x89, 0xC3 },              .output = "mov bx, ax" },
        .{ .bytes = &[_]u8{ 0x89, 0xF3 },              .output = "mov bx, si" },
        .{ .bytes = &[_]u8{ 0x89, 0xFC },              .output = "mov sp, di" },
        .{ .bytes = &[_]u8{ 0x89, 0xC5 },              .output = "mov bp, ax" },
        .{ .bytes = &[_]u8{ 0x89, 0xDE },              .output = "mov si, bx" },
        .{ .bytes = &[_]u8{ 0x88, 0xC6 },              .output = "mov dh, al" },
        .{ .bytes = &[_]u8{ 0xB1, 0x0C },              .output = "mov cl, 12" },
        .{ .bytes = &[_]u8{ 0xB5, 0xF4 },              .output = "mov ch, -12" },
        .{ .bytes = &[_]u8{ 0xB9, 0x0C, 0x00 },        .output = "mov cx, 12" },
        .{ .bytes = &[_]u8{ 0xB9, 0xF4, 0xFF },        .output = "mov cx, -12" },
        .{ .bytes = &[_]u8{ 0xBA, 0x6C, 0x0F },        .output = "mov dx, 3948" },
        .{ .bytes = &[_]u8{ 0xBA, 0x94, 0xF0 },        .output = "mov dx, -3948" },
        .{ .bytes = &[_]u8{ 0x8A, 0x00 },              .output = "mov al, [bx + si]" },
        .{ .bytes = &[_]u8{ 0x8B, 0x1B },              .output = "mov bx, [bp + di]" },
        .{ .bytes = &[_]u8{ 0x8B, 0x56, 0x00 },        .output = "mov dx, [bp]" },
        .{ .bytes = &[_]u8{ 0x8A, 0x60, 0x04 },        .output = "mov ah, [bx + si + 4]" },
        .{ .bytes = &[_]u8{ 0x8A, 0x80, 0x87, 0x13 },  .output = "mov al, [bx + si + 4999]" },
        .{ .bytes = &[_]u8{ 0x89, 0x09 },              .output = "mov [bx + di], cx" },
        .{ .bytes = &[_]u8{ 0x88, 0x0A },              .output = "mov [bp + si], cl" },
        .{ .bytes = &[_]u8{ 0x88, 0x6E, 0x00 },        .output = "mov [bp], ch" },
    };

    const header = "bits 16\n\n";
    var failed_tests: usize = 0;

    var output_buffer: [header.len+(test_cases.len*32)]u8 = undefined;
    var fbs = io.fixedBufferStream(&output_buffer);
    var output_writer = fbs.writer();

    // run tests
    for (test_cases) |test_case, index| {
        // reset the buffer at the end of the loop
        defer fbs.reset();

        // decode
        decode8086(test_case.bytes, output_writer) catch |err| {
            // print details on decode fail but continue with the tests
            failed_tests += 1;
            debug.print("test {d} failed, bytes: {x}, expected ({d}): '{s}', got: {}\n", .{
                index,
                fmt.fmtSliceHexLower(test_case.bytes),
                test_case.output.len, test_case.output,
                err
            });
            if (@errorReturnTrace()) |stack| {
                debug.dumpStackTrace(stack.*);
            }
            continue;
        };

        // skip the header to get just the generated instruction
        // and trim the new line at the end
        const output = output_buffer[header.len..fbs.pos-1];

        // compare
        if (mem.eql(u8, test_case.output, output) == false) {
            failed_tests += 1;
            debug.print("test {d} failed, bytes: {x}, expected ({d}): '{s}', got({d}): '{s}'\n", .{
                index,
                fmt.fmtSliceHexLower(test_case.bytes),
                test_case.output.len, test_case.output,
                output.len, output
            });
        }
    }

    // summary
    debug.print("\nrun {d} tests; passed: {d}; failed: {d}\n", .{
        test_cases.len,
        test_cases.len - failed_tests,
        failed_tests
    });

    // if all succeeded then do the combined test
    if (failed_tests == 0) {
        // merge the data
        var bytes_buffer           : [output_buffer.len]u8 = undefined;
        var expected_output_buffer : [output_buffer.len]u8 = undefined;

        var bytes           : []u8 = bytes_buffer          [0..];
        var expected_output : []u8 = expected_output_buffer[0..];

        var total_bytes_count : usize = 0;
        var total_output_len  : usize = 0;

        mem.copy(u8, expected_output, header);
        expected_output = expected_output[header.len..];
        total_output_len += header.len;

        for (test_cases) |test_case| {
            mem.copy(u8, bytes, test_case.bytes);
            bytes = bytes[test_case.bytes.len..];
            total_bytes_count += test_case.bytes.len;

            mem.copy(u8, expected_output, test_case.output);
            expected_output = expected_output[test_case.output.len..];
            total_output_len += test_case.output.len;
            mem.copy(u8, expected_output, "\n");
            expected_output = expected_output["\n".len..];
            total_output_len += "\n".len;
        }

        bytes           = bytes_buffer          [0..total_bytes_count];
        expected_output = expected_output_buffer[0..total_output_len];

        // decode
        fbs.reset();
        decode8086(bytes, output_writer) catch |err| {
            // print details on decode fail but continue with the tests
            failed_tests += 1;
            debug.print("combined test failed with {}\n", .{err});
            if (@errorReturnTrace()) |stack| {
                debug.dumpStackTrace(stack.*);
            }
            return;
        };

        // compare
        const output = fbs.getWritten();
        if (mem.eql(u8, expected_output, output) == false) {
            debug.print("combined test failed\n" ++
                "expected ({d}):\n" ++
                "--------------------------------------------------------------------------------\n" ++
                "{s}\n" ++
                "--------------------------------------------------------------------------------\n" ++
                "got ({d}):\n" ++
                "--------------------------------------------------------------------------------\n" ++
                "{s}\n" ++
                "--------------------------------------------------------------------------------\n",
                .{
                    expected_output.len,
                    expected_output,
                    output.len,
                    output,
                }
            );
        } else {
            debug.print("combined test passed\n", .{});
        }
    }
}
