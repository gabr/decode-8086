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

    // and the header which is necessary for nasm
    try stdout.writeAll("bits 16\n\n");

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
    var bytes_read: usize = 0;
    while (bytes_read < bytes.len) {
        const start_bytes_read = bytes_read;

        bytes_read += try Parsers.RegMemToFromReg        (bytes[bytes_read..], output_writer);
        bytes_read += try Parsers.ImmediateToRegMem      (bytes[bytes_read..], output_writer);
        bytes_read += try Parsers.ImmediateToAccumulator (bytes[bytes_read..], output_writer);
        bytes_read += try Parsers.MOV_ImmediateToReg     (bytes[bytes_read..], output_writer);
        bytes_read += try Parsers.MOV_MemAccumulator     (bytes[bytes_read..], output_writer);

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
    /// that's possible will validate its id, advance bytes by the extracted
    /// amount and return extracted header.
    fn extractHeader(bytes: *[]const u8, comptime HeaderType: type, expected_ids: []const u8) ?HeaderType {
        if (bytes.*.len < @sizeOf(HeaderType)) {
            return null;
        }

        const header = @ptrCast(*align(1) const HeaderType, bytes.*.ptr).*;
        const header_id: u8 = header.id;
        for (expected_ids) |expected_id| {
            if (header_id == expected_id) break;
        } else return null;

        bytes.* = bytes.*[@sizeOf(HeaderType)..];
        return header;
    }

    /// Will use header to calculate displacement size (if any) and extract
    /// its value (if any) and advance buffer by the amout of extracted bytes.
    /// If there is not enough bytes it will return error.
    fn extractDisplacement(bytes: *[]const u8, header: anytype) !i16 {
        var displacement_size: usize =
             if (header.mod == 0b00 and header.rm == 0b110) 2 // special case
        else if (header.mod == 0b01) 1
        else if (header.mod == 0b10) 2
        else 0;

        if (displacement_size == 0) {
            return 0;
        }

        if (bytes.*.len < displacement_size) {
            debug.print(
                "not enough bytes for {d}-bit displacement\n" ++
                "header: {}\n" ++
                "bytes left ({}): [{x}]\n",
                .{displacement_size*8, header, bytes.*.len, fmt.fmtSliceHexLower(bytes.*)}
            );
            return error.NotEnoughBytes;
        }
        const displacement: i16 = if (displacement_size == 1)
                  @ptrCast(*align(1) const  i8, bytes.*.ptr).*
            else  @ptrCast(*align(1) const i16, bytes.*.ptr).*;
        bytes.* = bytes.*[displacement_size..];

        return displacement;
    }

    /// Helper method for outputting instructions which can have reversed
    /// source with destination based on 'd' field.
    fn output(
        instruction: []const u8,
        d: u1, // d == 1 flips dest with src
        comptime dest_format: []const u8, dest_data: anytype,
        comptime  src_format: []const u8,  src_data: anytype,
        output_writer: anytype
    ) !void {
        try output_writer.writeAll(instruction);
        try output_writer.writeAll(" ");
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

    /// Extracts common logic for outputing instruction based on the MOD field
    fn outputBasedOnMode(
        instruction: []const u8,
        d:   u1,
        mod: u2,
        rm:  u3,
        displacement: i16,
        data_prefix: []const u8,
        comptime value_format:        []const u8, value:               anytype,
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

                    try output(
                        instruction, d,
                        "[{d}]", .{direct_address},
                        "{s}" ++ value_format, .{data_prefix, value},
                        output_writer );
                } else {
                    try output(
                        instruction, d,
                        "[{s}]", .{rms[rm]},
                        "{s}" ++ value_format, .{data_prefix, value},
                        output_writer );
                }
            },

            // memory mode with 8-bit or 16-bit displacement
            0b01, 0b10 => {
                if (displacement == 0) {
                    try output(
                        instruction, d,
                        "[{s}]",      .{rms[rm]},
                        "{s}" ++ value_format, .{data_prefix, value},
                        output_writer );
                } else {
                    if (displacement < 0) {
                        try output(
                            instruction, d,
                            "[{s} - {d}]", .{rms[rm], displacement*-1},
                            "{s}" ++ value_format, .{data_prefix, value},
                            output_writer );
                    } else {
                        try output(
                            instruction, d,
                            "[{s} + {d}]", .{rms[rm], displacement},
                            "{s}" ++ value_format, .{data_prefix, value},
                            output_writer );
                    }
                }
            },

            // register mode
            0b11 => {
                try output(
                    instruction, d,
                    register_mode_format, .{register_mode_value},
                    value_format,         .{value},
                    output_writer );
            },
        }
    }

    /// MOV/ADD/SUB/CMP Register/memory to/from register
    pub fn RegMemToFromReg(bytes: []const u8, output_writer: anytype) !usize {
        const Header = packed struct {
            w: u1, d: u1, id: u6,
            rm: u3, reg: u3, mod: u2,
        };

        var work_buffer = bytes;
        const header = extractHeader(&work_buffer, Header, &[_]u8{
            0b00_100010,
            0b00_000000,
            0b00_001010,
            0b00_001110,
        }) orelse return 0;

        const instruction = switch (header.id) {
            0b100010 => "mov",
            0b000000 => "add",
            0b001010 => "sub",
            0b001110 => "cmp",
            else => return 0,
        };

        const displacement = try extractDisplacement(&work_buffer, header);

        try outputBasedOnMode(
            instruction,
            header.d,
            header.mod,
            header.rm,
            displacement,
            "",
            "{s}", regs[header.w][header.reg],
            "{s}", regs[header.w][header.rm],
            output_writer,
        );

        return bytes.len - work_buffer.len;
    }

    /// MOV/ADD/SUB/CMP Immediate to register/memory
    pub fn ImmediateToRegMem(bytes: []const u8, output_writer: anytype) !usize {
        const Header = packed struct {
            w: u1, s:u1, id: u6,
            rm: u3, type: u3, mod: u2,
        };

        var work_buffer = bytes;
        const header = extractHeader(&work_buffer, Header, &[_]u8{
            0b00_110001,
            0b00_100000,
            0b00_100000,
            0b00_100000,
        }) orelse return 0;

        const instruction =
            if (header.id == 0b110001 and header.s == 0b1) "mov"
            else switch (header.type) {
                0b000 => "add",
                0b101 => "sub",
                0b111 => "cmp",
                else => return 0,
            };

        const displacement = try extractDisplacement(&work_buffer, header);

        // have to cast to not overflow in the add below
        const data_size: u8 = @as(u8, header.w)+1;
        if (work_buffer.len < data_size) {
            debug.print(
                "found immediate to register/memory {s} but not enough bytes for {d}-bit data\n" ++
                "header: {}\n" ++
                "bytes left ({}): [{x}]\n",
                .{instruction, data_size*8, header, work_buffer.len, fmt.fmtSliceHexLower(work_buffer)}
            );
            return error.NotEnoughBytes;
        }
        // TODO(agabrys): handle header.s sign
        const data: i16 = if (header.w == 0)
                 @ptrCast(*align(1) const  i8, work_buffer.ptr).*
            else @ptrCast(*align(1) const i16, work_buffer.ptr).*;
        work_buffer = work_buffer[data_size..];
        const data_prefix = if (header.w == 0) "byte " else "word ";

        try outputBasedOnMode(
            instruction,
            0,
            header.mod,
            header.rm,
            displacement,
            data_prefix,
            "{d}", data,
            "{s}", regs[header.w][header.rm],
            output_writer,
        );

        return bytes.len - work_buffer.len;
    }

    /// ADD/SUB/CMP Immediate to accumulator
    pub fn ImmediateToAccumulator(bytes: []const u8, output_writer: anytype) !usize {
        const Header = packed struct {
            w: u1, id: u7,
        };

        var work_buffer = bytes;
        const header = extractHeader(&work_buffer, Header, &[_]u8{
            0b0_0000010,
            0b0_0010110,
            0b0_0011110,
        }) orelse return 0;

        const instruction = switch (header.id) {
            0b0000010 => "add",
            0b0010110 => "sub",
            0b0011110 => "cmp",
            else => return 0,
        };

        const register = if (header.w == 0) "al" else "ax";

        // do we have enough bytes
        const data_size: u8 = @as(u8, header.w)+1;
        if (work_buffer.len < data_size) {
            debug.print(
                "found immediate to register {s} but not enough bytes for {d}-bit data\n" ++
                "header: {}\n" ++
                "bytes left ({}): [{x}]\n",
                .{instruction, data_size*8, header, work_buffer.len, fmt.fmtSliceHexLower(work_buffer)}
            );
            return error.NotEnoughBytes;
        }
        const data = if (header.w == 0)   // \/ we are signed this time
                 @ptrCast(*align(1) const  i8, work_buffer.ptr).*
            else @ptrCast(*align(1) const i16, work_buffer.ptr).*;
        work_buffer = work_buffer[data_size..];

        try output( instruction, 0,
            "{s}", .{register},
            "{d}", .{data},
            output_writer );

        return bytes.len - work_buffer.len;
    }

    /// MOV Immediate to register
    pub fn MOV_ImmediateToReg(bytes: []const u8, output_writer: anytype) !usize {
        const Header = packed struct {
            reg: u3, w: u1, id: u4,
        };

        var work_buffer = bytes;
        const header = extractHeader(&work_buffer, Header, &[_]u8{ 0b000_1011 })
            orelse return 0;

        // do we have enough bytes
        const data_size: u8 = @as(u8, header.w)+1;
        if (work_buffer.len < data_size) {
            debug.print(
                "found immediate to register MOV but not enough bytes for {d}-bit data\n" ++
                "header: {}\n" ++
                "bytes left ({}): [{x}]\n",
                .{data_size*8, header, work_buffer.len, fmt.fmtSliceHexLower(work_buffer)}
            );
            return error.NotEnoughBytes;
        }
        const data = if (header.w == 0)   // \/ we are signed this time
                 @ptrCast(*align(1) const  i8, work_buffer.ptr).*
            else @ptrCast(*align(1) const i16, work_buffer.ptr).*;
        work_buffer = work_buffer[data_size..];

        try output( "mov", 0,
            "{s}", .{regs[header.w][header.reg]},
            "{d}", .{data},
            output_writer );

        return bytes.len - work_buffer.len;
    }

    /// MOV Memory to accumulator and Accumulator to Memory
    /// Two accmulator instructions in one function.
    /// The only difference is the order so the output will be
    /// flipped around depending on the instruction id.
    pub fn MOV_MemAccumulator(bytes: []const u8, output_writer: anytype) !usize {
        const Header = packed struct {
            w: u1, id: u7,
        };

        var work_buffer = bytes;
        const header = extractHeader(&work_buffer, Header, &[_]u8{0b0_1010000, 0b0_1010001})
             orelse return 0;

        // do we have enough bytes
        const address_size: u8 = @as(u8, header.w)+1;
        if (work_buffer.len < address_size) {
            debug.print(
                "found memory to accumulator MOV but not enough bytes for {d}-bit address\n" ++
                "header: {}\n" ++
                "bytes left ({}): [{x}]\n",
                .{address_size*8, header, work_buffer.len, fmt.fmtSliceHexLower(work_buffer)}
            );
            return error.NotEnoughBytes;
        }
        const address = if (header.w == 0)
                 @ptrCast(*align(1) const  u8, work_buffer.ptr).*
            else @ptrCast(*align(1) const u16, work_buffer.ptr).*;
        work_buffer = work_buffer[address_size..];

        const flip: u1 = if (header.id == 0b0_1010001) 1 else 0;
        try output( "mov",
            flip,
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
          // basic register to register moves
        .{ .bytes = &[_]u8{ 0x89, 0xD9 }, .output = "mov cx, bx" },
        .{ .bytes = &[_]u8{ 0x88, 0xE5 }, .output = "mov ch, ah" },
        .{ .bytes = &[_]u8{ 0x89, 0xDA }, .output = "mov dx, bx" },
        .{ .bytes = &[_]u8{ 0x89, 0xDE }, .output = "mov si, bx" },
        .{ .bytes = &[_]u8{ 0x89, 0xFB }, .output = "mov bx, di" },
        .{ .bytes = &[_]u8{ 0x88, 0xC8 }, .output = "mov al, cl" },
        .{ .bytes = &[_]u8{ 0x88, 0xED }, .output = "mov ch, ch" },
        .{ .bytes = &[_]u8{ 0x89, 0xC3 }, .output = "mov bx, ax" },
        .{ .bytes = &[_]u8{ 0x89, 0xF3 }, .output = "mov bx, si" },
        .{ .bytes = &[_]u8{ 0x89, 0xFC }, .output = "mov sp, di" },
        .{ .bytes = &[_]u8{ 0x89, 0xC5 }, .output = "mov bp, ax" },
        .{ .bytes = &[_]u8{ 0x89, 0xDE }, .output = "mov si, bx" },
        .{ .bytes = &[_]u8{ 0x88, 0xC6 }, .output = "mov dh, al" },

          // 8-bit immediate-to-register
        .{ .bytes = &[_]u8{ 0xB1, 0x0C }, .output = "mov cl, 12" },
        .{ .bytes = &[_]u8{ 0xB5, 0xF4 }, .output = "mov ch, -12" },

          // 16-bit immediate-to-register
        .{ .bytes = &[_]u8{ 0xB9, 0x0C, 0x00 }, .output = "mov cx, 12" },
        .{ .bytes = &[_]u8{ 0xB9, 0xF4, 0xFF }, .output = "mov cx, -12" },
        .{ .bytes = &[_]u8{ 0xBA, 0x6C, 0x0F }, .output = "mov dx, 3948" },
        .{ .bytes = &[_]u8{ 0xBA, 0x94, 0xF0 }, .output = "mov dx, -3948" },

          // Source address calculation
        .{ .bytes = &[_]u8{ 0x8A, 0x00 },       .output = "mov al, [bx + si]" },
        .{ .bytes = &[_]u8{ 0x8B, 0x1B },       .output = "mov bx, [bp + di]" },
        .{ .bytes = &[_]u8{ 0x8B, 0x56, 0x00 }, .output = "mov dx, [bp]" },

          // Source address calculation plus 8-bit displacement
        .{ .bytes = &[_]u8{ 0x8A, 0x60, 0x04 }, .output = "mov ah, [bx + si + 4]" },

          // Source address calculation plus 16-bit displacement
        .{ .bytes = &[_]u8{ 0x8A, 0x80, 0x87, 0x13 }, .output = "mov al, [bx + si + 4999]" },

          // Dest address calculation
        .{ .bytes = &[_]u8{ 0x89, 0x09 },       .output = "mov [bx + di], cx" },
        .{ .bytes = &[_]u8{ 0x88, 0x0A },       .output = "mov [bp + si], cl" },
        .{ .bytes = &[_]u8{ 0x88, 0x6E, 0x00 }, .output = "mov [bp], ch" },

          // Signed displacements
        .{ .bytes = &[_]u8{ 0x8B, 0x41, 0xDB},        .output = "mov ax, [bx + di - 37]" },
        .{ .bytes = &[_]u8{ 0x89, 0x8C, 0xD4, 0xFE }, .output = "mov [si - 300], cx" },
        .{ .bytes = &[_]u8{ 0x8B, 0x57, 0xE0},        .output = "mov dx, [bx - 32]" },

          // Explicit sizes
        .{ .bytes = &[_]u8{ 0xC6, 0x03, 0x07 },                   .output = "mov [bp + di], byte 7" },
        .{ .bytes = &[_]u8{ 0xC7, 0x85, 0x85, 0x03, 0x5B, 0x01 }, .output = "mov [di + 901], word 347" },

          // Direct address
        .{ .bytes = &[_]u8{ 0x8B, 0x2E, 0x05, 0x00 }, .output = "mov bp, [5]" },
        .{ .bytes = &[_]u8{ 0x8B, 0x1E, 0x82, 0x0D }, .output = "mov bx, [3458]" },

          // Memory-to-accumulator test
        .{ .bytes = &[_]u8{ 0xA1, 0xFB, 0x09 }, .output = "mov ax, [2555]" },
        .{ .bytes = &[_]u8{ 0xA1, 0x10, 0x00 }, .output = "mov ax, [16]" },

          // Accumulator-to-memory test
        .{ .bytes = &[_]u8{ 0xA3, 0xFA, 0x09 }, .output = "mov [2554], ax" },
        .{ .bytes = &[_]u8{ 0xA3, 0x0F, 0x00 }, .output = "mov [15], ax" },

          // adds
        .{ .bytes = &[_]u8{ 0x03, 0x18 }, .output = "add bx, [bx + si]" },
        .{ .bytes = &[_]u8{ 0x03, 0x5E, 0x00 }, .output = "add bx, [bp]" },    // id     sw  mod type rm
        .{ .bytes = &[_]u8{ 0x83, 0xC6, 0x02, 0x00 }, .output = "add si, 2" },
        .{ .bytes = &[_]u8{ 0x83, 0xC5, 0x02, 0x00 }, .output = "add bp, 2" },
        .{ .bytes = &[_]u8{ 0x83, 0xC1, 0x08, 0x00 }, .output = "add cx, 8" },
        .{ .bytes = &[_]u8{ 0x03, 0x5E, 0x00 }, .output = "add bx, [bp]" },
        .{ .bytes = &[_]u8{ 0x03, 0x4F, 0x02 }, .output = "add cx, [bx + 2]" },
        .{ .bytes = &[_]u8{ 0x02, 0x7A, 0x04 }, .output = "add bh, [bp + si + 4]" },
        .{ .bytes = &[_]u8{ 0x03, 0x7B, 0x06 }, .output = "add di, [bp + di + 6]" },
        .{ .bytes = &[_]u8{ 0x01, 0x18 }, .output = "add [bx + si], bx" },
        .{ .bytes = &[_]u8{ 0x01, 0x5E, 0x00 }, .output = "add [bp], bx" },
        .{ .bytes = &[_]u8{ 0x01, 0x5E, 0x00 }, .output = "add [bp], bx" },
        .{ .bytes = &[_]u8{ 0x01, 0x4F, 0x02 }, .output = "add [bx + 2], cx" },
        .{ .bytes = &[_]u8{ 0x00, 0x7A, 0x04 }, .output = "add [bp + si + 4], bh" },
        .{ .bytes = &[_]u8{ 0x01, 0x7B, 0x06 }, .output = "add [bp + di + 6], di" },
        .{ .bytes = &[_]u8{ 0x80, 0x07, 0x22 }, .output = "add [bx], byte 34" },
        .{ .bytes = &[_]u8{ 0x83, 0x82, 0xE8, 0x03, 0x1D, 0x00 }, .output = "add [bp + si + 1000], word 29" },
        .{ .bytes = &[_]u8{ 0x03, 0x46, 0x00 }, .output = "add ax, [bp]" },
        .{ .bytes = &[_]u8{ 0x02, 0x00 }, .output = "add al, [bx + si]" },
        .{ .bytes = &[_]u8{ 0x01, 0xD8 }, .output = "add ax, bx" },
        .{ .bytes = &[_]u8{ 0x00, 0xE0 }, .output = "add al, ah" },
        .{ .bytes = &[_]u8{ 0x05, 0xE8, 0x03 }, .output = "add ax, 1000" },
        .{ .bytes = &[_]u8{ 0x04, 0xE2 }, .output = "add al, -30" },
        .{ .bytes = &[_]u8{ 0x04, 0x09 }, .output = "add al, 9" },

          // subs
        .{ .bytes = &[_]u8{ 0x2B, 0x18 }, .output = "sub bx, [bx + si]" },
        .{ .bytes = &[_]u8{ 0x2B, 0x5E, 0x00 }, .output = "sub bx, [bp]" },
        .{ .bytes = &[_]u8{ 0x83, 0xEE, 0x02, 0x00 }, .output = "sub si, 2" },
        .{ .bytes = &[_]u8{ 0x83, 0xED, 0x02, 0x00 }, .output = "sub bp, 2" },
        .{ .bytes = &[_]u8{ 0x83, 0xE9, 0x08, 0x00 }, .output = "sub cx, 8" },
        .{ .bytes = &[_]u8{ 0x2B, 0x5E, 0x00 }, .output = "sub bx, [bp]" },
        .{ .bytes = &[_]u8{ 0x2B, 0x4F, 0x02 }, .output = "sub cx, [bx + 2]" },
        .{ .bytes = &[_]u8{ 0x2A, 0x7A, 0x04 }, .output = "sub bh, [bp + si + 4]" },
        .{ .bytes = &[_]u8{ 0x2B, 0x7B, 0x06 }, .output = "sub di, [bp + di + 6]" },
        .{ .bytes = &[_]u8{ 0x29, 0x18 }, .output = "sub [bx + si], bx" },
        .{ .bytes = &[_]u8{ 0x29, 0x5E, 0x00 }, .output = "sub [bp], bx" },
        .{ .bytes = &[_]u8{ 0x29, 0x5E, 0x00 }, .output = "sub [bp], bx" },
        .{ .bytes = &[_]u8{ 0x29, 0x4F, 0x02 }, .output = "sub [bx + 2], cx" },
        .{ .bytes = &[_]u8{ 0x28, 0x7A, 0x04 }, .output = "sub [bp + si + 4], bh" },
        .{ .bytes = &[_]u8{ 0x29, 0x7B, 0x06 }, .output = "sub [bp + di + 6], di" },
        .{ .bytes = &[_]u8{ 0x80, 0x2F, 0x22 }, .output = "sub [bx], byte 34" },
        .{ .bytes = &[_]u8{ 0x83, 0x29, 0x1D, 0x00 }, .output = "sub [bx + di], word 29" },
        .{ .bytes = &[_]u8{ 0x2B, 0x46, 0x00 }, .output = "sub ax, [bp]" },
        .{ .bytes = &[_]u8{ 0x2A, 0x00 }, .output = "sub al, [bx + si]" },
        .{ .bytes = &[_]u8{ 0x29, 0xD8 }, .output = "sub ax, bx" },
        .{ .bytes = &[_]u8{ 0x28, 0xE0 }, .output = "sub al, ah" },
        .{ .bytes = &[_]u8{ 0x2D, 0xE8, 0x03 }, .output = "sub ax, 1000" },
        .{ .bytes = &[_]u8{ 0x2C, 0xE2 }, .output = "sub al, -30" },
        .{ .bytes = &[_]u8{ 0x2C, 0x09 }, .output = "sub al, 9" },

          // cmp
        .{ .bytes = &[_]u8{ 0x3B, 0x18 }, .output = "cmp bx, [bx + si]" },
        .{ .bytes = &[_]u8{ 0x3B, 0x5E, 0x00 }, .output = "cmp bx, [bp]" },
        .{ .bytes = &[_]u8{ 0x83, 0xFE, 0x02, 0x00 }, .output = "cmp si, 2" },
        .{ .bytes = &[_]u8{ 0x83, 0xFD, 0x02, 0x00 }, .output = "cmp bp, 2" },
        .{ .bytes = &[_]u8{ 0x83, 0xF9, 0x08, 0x00 }, .output = "cmp cx, 8" },
        .{ .bytes = &[_]u8{ 0x3B, 0x5E, 0x00 }, .output = "cmp bx, [bp]" },
        .{ .bytes = &[_]u8{ 0x3B, 0x4F, 0x02 }, .output = "cmp cx, [bx + 2]" },
        .{ .bytes = &[_]u8{ 0x3A, 0x7A, 0x04 }, .output = "cmp bh, [bp + si + 4]" },
        .{ .bytes = &[_]u8{ 0x3B, 0x7B, 0x06 }, .output = "cmp di, [bp + di + 6]" },
        .{ .bytes = &[_]u8{ 0x39, 0x18 }, .output = "cmp [bx + si], bx" },
        .{ .bytes = &[_]u8{ 0x39, 0x5E, 0x00 }, .output = "cmp [bp], bx" },
        .{ .bytes = &[_]u8{ 0x39, 0x5E, 0x00 }, .output = "cmp [bp], bx" },
        .{ .bytes = &[_]u8{ 0x39, 0x4F, 0x02 }, .output = "cmp [bx + 2], cx" },
        .{ .bytes = &[_]u8{ 0x38, 0x7A, 0x04 }, .output = "cmp [bp + si + 4], bh" },
        .{ .bytes = &[_]u8{ 0x39, 0x7B, 0x06 }, .output = "cmp [bp + di + 6], di" },
        .{ .bytes = &[_]u8{ 0x80, 0x3F, 0x22 }, .output = "cmp [bx], byte 34" },
        .{ .bytes = &[_]u8{ 0x83, 0x3E, 0xE2, 0x12, 0x1D, 0x00 }, .output = "cmp [4834], word 29" },
        .{ .bytes = &[_]u8{ 0x3B, 0x46, 0x00 }, .output = "cmp ax, [bp]" },
        .{ .bytes = &[_]u8{ 0x3A, 0x00 }, .output = "cmp al, [bx + si]" },
        .{ .bytes = &[_]u8{ 0x39, 0xD8 }, .output = "cmp ax, bx" },
        .{ .bytes = &[_]u8{ 0x38, 0xE0 }, .output = "cmp al, ah" },
        .{ .bytes = &[_]u8{ 0x3D, 0xE8, 0x03 }, .output = "cmp ax, 1000" },
        .{ .bytes = &[_]u8{ 0x3C, 0xE2 }, .output = "cmp al, -30" },
        .{ .bytes = &[_]u8{ 0x3C, 0x09 }, .output = "cmp al, 9" },
    };

    var output_buffer: [test_cases.len*32]u8 = undefined;
    var fbs = io.fixedBufferStream(&output_buffer);
    var output_writer = fbs.writer();

    // run tests
    var failed_tests: usize = 0;
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

        // trim the new line at the end
        const output = output_buffer[0..fbs.pos-1];

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
    // This combined test is important to make sure that we do not consume too
    // many bytes when decoding instruction and that we output them in correct
    // order and with new lines and so on.
    if (failed_tests == 0) {
        // merge the data
        var bytes_buffer           : [output_buffer.len]u8 = undefined;
        var expected_output_buffer : [output_buffer.len]u8 = undefined;

        var bytes           : []u8 = bytes_buffer          [0..];
        var expected_output : []u8 = expected_output_buffer[0..];

        var total_bytes_count : usize = 0;
        var total_output_len  : usize = 0;

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
                "-----------------------------n" ++
                "{s}\n" ++
                "-----------------------------n" ++
                "got ({d}):\n" ++
                "-----------------------------n" ++
                "{s}\n" ++
                "-----------------------------n",
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
