/// 8086 CPU decoder v2
const std     = @import("std");
const io      = std.io;
const fs      = std.fs;
const mem     = std.mem;
const fmt     = std.fmt;
const math    = std.math;
const meta    = std.meta;
const heap    = std.heap;
const debug   = std.debug;
const process = std.process;

pub fn main() !void {
    // just get memory in pages and free all at the end
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // handle args
    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    //debug.print("args: {d}:\n  {s}\n", .{args.len, try mem.join(allocator, "\n  ", args)});

    if (args.len < 2) {
        return error.MissingPath;
    }

    const file_path = args[1];
    //debug.print("decoding file: {s}\n", .{file_path});

    if (mem.endsWith(u8, fs.path.extension(file_path), ".asm")) {
        return error.UnexpectedAsmExtension;
    }

    // open file
    const cwd = try process.getCwdAlloc(allocator);
    const file_absolute_path = try fs.path.resolve(allocator, &[_][]const u8{cwd, file_path});
    //debug.print("file_absolute_path: {s}\n", .{file_absolute_path});
    const file = try fs.openFileAbsolute(file_absolute_path, .{});
    defer file.close();

    //const file_content = try file.readToEndAlloc(allocator, @max(usize));
    //debug.print("bytes to decode ({}): {x}\n", .{file_content.len, fmt.fmtSliceHexLower(file_content)});
    //try file.seekTo(0);
    // create input reader
    const file_reader = file.reader();

    // create output writer - we are writing to standard output
    const stdout_file = io.getStdOut().writer();
    var bw = io.bufferedWriter(stdout_file);
    // flush on program end and in case of errors
    defer bw.flush() catch unreachable;
    const stdout = bw.writer();

    // start by writting filename comment
    try stdout.print("; {s}\n\n", .{file_path});

    // and the header which is necessary for nasm
    try stdout.writeAll("bits 16\n\n");

    //CPU8086.debugPrintInstructionDefinitions();

    // read instructions from file and print them out as ASM
    while (try CPU8086.decode(file_reader)) |instruction| {
        try CPU8086.writeAsm(instruction, stdout);
        try stdout.print("\n", .{});
    }
}

const CPU8086 = struct {
    pub const Register = enum(u8) { al, ax, cl, cx, dl, dx, bl, bx, ah, sp, ch, bp, dh, si, bh, di, };
    pub const RegisterTarget = struct {
        register:   Register,

        pub fn fromFields(reg: u3, w: u1) RegisterTarget {
            const byte_reg: u8 = @intCast(reg);
            return .{ .register = @enumFromInt((byte_reg*2)+w) };
        }

        pub fn writeAsm(self: @This(), writer: anytype) !void {
            _ = try writer.write(@tagName(self.register));
        }
    };

    pub const SegmentRegister = enum(u2) { es, cs, ss, ds, };
    pub const SegmentRegisterTarget = struct {
        register: SegmentRegister,

        pub fn fromFields(sr: u2) SegmentRegisterTarget {
            return .{ .register = @enumFromInt(sr) };
        }

        pub fn writeAsm(self: @This(), writer: anytype) !void {
            _ = try writer.write(@tagName(self.register));
        }
    };

    pub const AddressTarget = struct {
        is_wide: bool,
        address: u16,

        pub fn fromFields(w: u1, addr_lo: u8, addr_hi: u8) AddressTarget {
            return if (w == 0) .{ .is_wide = false, .address = @intCast(addr_lo) }
                   else        .{ .is_wide = true,  .address = @bitCast([_]u8{addr_lo, addr_hi}) };
        }

        pub fn writeAsm(self: @This(), writer: anytype) !void {
            try writer.print("[{d}]", .{self.address});
        }
    };

    pub const EffectiveAddress = enum(u8) { bx_si, bx_di, bp_si, bp_di, si, di, bp, bx, };
    pub const EffectiveAddressTarget = struct {
        type:        EffectiveAddress,
        is_wide:     bool,
        disp_offset: i16,

        pub fn fromFields(rm: u3, mod: u2, disp_lo: u8, disp_hi: u8) EffectiveAddressTarget {
            const disp_offset: i16 =
                     if (mod == 0b00) 0
                else if (mod == 0b01) @as(i8, @bitCast(disp_lo))
                else if (mod == 0b10) @bitCast([_]u8{disp_lo, disp_hi})
                else unreachable;

            return .{
                .type        = @enumFromInt(rm),
                .is_wide     = mod == 0b10,
                .disp_offset = disp_offset,
            };
        }

        pub fn writeAsm(self: @This(), writer: anytype) !void {
            _ = try writer.write("[");

            const name = @tagName(self.type);
            if (name[2] == '_') {
                _ = try writer.write(name[0..2]);
                _ = try writer.write(" + ");
                _ = try writer.write(name[3..5]);
            } else {
                _ = try writer.write(name);
            }

            if (self.disp_offset != 0) {
                if (self.disp_offset < 0) {
                    _ = try writer.write(" - ");
                    try writer.print("{d}", .{-self.disp_offset});
                } else {
                    try writer.print(" + {d}", .{self.disp_offset});
                }
            }

            _ = try writer.write("]");
        }
    };

    pub const ImmediateTarget = struct {
        is_wide: bool,
        data:    i16,

        pub fn fromFields(w: u1, data_lo: u8, data_hi: u8) ImmediateTarget {
            return if (w == 0) .{ .is_wide = false, .data = @as(i8, @bitCast(data_lo)) }
                   else        .{ .is_wide = true,  .data = @bitCast([_]u8{data_lo, data_hi}) };
        }

        pub fn writeAsm(self: @This(), print_size: bool, writer: anytype) !void {
            if (print_size) {
                if (self.is_wide) { _ = try writer.write("word "); }
                else              { _ = try writer.write("byte "); }
            }
            try writer.print("{d}", .{self.data});
        }
    };

    pub const InstructionTarget = union(enum) {
        register:          RegisterTarget,
        segment_register:  SegmentRegisterTarget,
        address:           AddressTarget,
        effective_address: EffectiveAddressTarget,
        immediate:         ImmediateTarget,

        pub fn fromFields(mod: u2, rm: u3, w: u1, disp_lo: u8, disp_hi: u8) InstructionTarget {
            if (mod == 0b11) return InstructionTarget {
                .register = RegisterTarget.fromFields(rm, w)
            };
            if (mod == 0b00 and rm == 0b110) return InstructionTarget {
                .address= AddressTarget.fromFields(1, disp_lo, disp_hi)
            };
            return InstructionTarget {
                .effective_address = EffectiveAddressTarget.fromFields(rm, mod, disp_lo, disp_hi)
            };
        }
    };

    pub const Instruction = struct {
        type: InstructionType,
        dst:  InstructionTarget,
        src:  InstructionTarget,
    };

    /// Decodes single instruction from the given reader
    pub fn decode(reader: anytype) !?Instruction {
        // buffer for instruction bytes which assumes maximum capacity of maximum amout of fields * 2 and start with 0
        var instruction_bytes = try std.BoundedArray(u8, instruction_definitions[0].fields_buffer.len * 2).init(0);

        // put first byte into the instruction bytes - we always need at least one
        const first_byte = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        try instruction_bytes.append(first_byte);

        // map for field values - it has to be zero initialize
        var field_values = [_]u8{0} ** @typeInfo(FieldType).Enum.fields.len;

        // find matching instruction definition and extract variable fields values
        var definition_index: usize = 0;
        const instruction_definition =
            for (instruction_definitions) |definition| {
                var byte_index: u8 = 0;
                var bits_count: u8 = 0;
                var current_byte = instruction_bytes.buffer[byte_index];

                // reset field values - we don't really have to do this as the new values
                // will override the old ones and we don't care if there are left overs
                // from different instructions
                //for (field_values) |*value| { value.* = 0; }

                const all_constant_fields_match =
                    for (definition.fields_buffer[0..definition.fields_count]) |field| {
                        //debug.print("instruction_bytes: [{x}]\n", .{fmt.fmtSliceHexLower(instruction_bytes.slice())});
                        if (false == field.isPresent(
                                @intCast(field_values[@intFromEnum(FieldType.mod)]),
                                @intCast(field_values[@intFromEnum(FieldType.w  )]),
                                @intCast(field_values[@intFromEnum(FieldType.rm )]))) {
                            continue;
                        }

                        // when we go to the next byte reset bits count and read next byte if necessary
                        if (bits_count >= 8) {
                            // should not happen as we validate that during compile time
                            if (bits_count > 8) {
                                return error.FieldSpansAcrossBytes;
                            }
                            bits_count = 0;
                            byte_index += 1;
                            if (byte_index > instruction_bytes.len-1) {
                                // read next byte as the instruction needs more
                                try instruction_bytes.append(try reader.readByte());
                            }
                            current_byte = instruction_bytes.buffer[byte_index];
                        }

                        // extract the field value
                        const mask: u8 = @intCast(((@as(u16, 1) << @intCast(field.bits_count)) - 1) << @intCast(8 - field.bits_count - bits_count));
                        const value: u8 = (current_byte & mask) >> @intCast(8 - bits_count - field.bits_count);
                        //debug.print("current_byte: {b}, mask: {b}, value: {b}\n", .{current_byte, mask, value});
                        bits_count += field.bits_count;

                        // if constant does not match it's not this instruction so break
                        if (field.type == .constant) {
                            if (value != field.value) {
                                break false;
                            }
                        } else {
                            field_values[@intFromEnum(field.type)] = value;
                        }
                    }
                    // if we looped through all fields and all constant matched we found the instructino
                    else true;

                if (all_constant_fields_match) {
                    break definition;
                }
                definition_index += 1;
            } else {
                //debug.print("failed on bytes({d}) [{x}]", .{
                //    instruction_bytes.len,
                //    fmt.fmtSliceHexLower(instruction_bytes.constSlice()), });
                return error.UnknownInstruction;
            };

        //debug.print("definition for bytes({d}) [{x}]: [{d}] {s}\n", .{
        //    instruction_bytes.len,
        //    fmt.fmtSliceHexLower(instruction_bytes.constSlice()),
        //    definition_index,
        //    instruction_definitions_strings[definition_index] });

        // determine destination and source
        var instruction: Instruction = undefined;
        instruction.type = instruction_definition.type;

        // cast field values to expected types to satisfy the mighty compiler \('^')/
        const d       = getFieldInType(u1, FieldType.d,       1, instruction_definition, field_values);
        const w       = getFieldInType(u1, FieldType.w,       1, instruction_definition, field_values);
        const mod     = getFieldInType(u2, FieldType.mod,     0, instruction_definition, field_values);
        const reg     = getFieldInType(u3, FieldType.reg,     0, instruction_definition, field_values);
        const rm      = getFieldInType(u3, FieldType.rm,      0, instruction_definition, field_values);
        const sr      = getFieldInType(u2, FieldType.sr,      0, instruction_definition, field_values);
        const disp_lo = getFieldInType(u8, FieldType.disp_lo, 0, instruction_definition, field_values);
        const disp_hi = getFieldInType(u8, FieldType.disp_hi, 0, instruction_definition, field_values);
        const data_lo = getFieldInType(u8, FieldType.data_lo, 0, instruction_definition, field_values);
        const data_hi = getFieldInType(u8, FieldType.data_hi, 0, instruction_definition, field_values);
        const addr_lo = getFieldInType(u8, FieldType.addr_lo, 0, instruction_definition, field_values);
        const addr_hi = getFieldInType(u8, FieldType.addr_hi, 0, instruction_definition, field_values);

        // determine dst and src
        instruction.dst =
                 if (instruction_definition.hasField(.sr))      InstructionTarget { .segment_register = SegmentRegisterTarget.fromFields(sr) }
            else if (instruction_definition.hasField(.reg))     InstructionTarget { .register = RegisterTarget.fromFields(reg, w) }
            else if (instruction_definition.hasField(.disp_lo)) InstructionTarget.fromFields(mod, rm, w, disp_lo, disp_hi)
            else if (instruction_definition.hasField(.addr_lo)) InstructionTarget { .address = AddressTarget.fromFields(w, addr_lo, addr_hi) }
            else                                                InstructionTarget { .register = RegisterTarget.fromFields(0b000, w) }; // accumulator ax reg = 0b000
        instruction.src =
                 if (instruction_definition.hasField(.data_lo)) InstructionTarget { .immediate = ImmediateTarget.fromFields(w, data_lo, data_hi) }
            else if (instruction_definition.hasField(.disp_lo)) InstructionTarget.fromFields(mod, rm, w, disp_lo, disp_hi)
            else                                                InstructionTarget { .register = RegisterTarget.fromFields(0b000, w) }; // accumulator ax reg = 0b000

        // swap src with dst if necessary
        if (d == 0) { const tmp = instruction.src; instruction.src = instruction.dst; instruction.dst = tmp; }

        //debug.print("parsed instruction: {any}\n", .{instruction});
        return instruction;
    }

    // Writes given instruction in Assembly representation using given writer
    pub fn writeAsm(instruction: Instruction, writer: anytype) !void {
        try writer.print("{s} ", .{@tagName(instruction.type)});
        try writeAsmTarget(instruction.dst, false, writer);
        try writer.print(", ", .{});
        const InstructionTargetTag = @typeInfo(InstructionTarget).Union.tag_type.?;
        const dst_tag = @as(InstructionTargetTag, instruction.dst);
        const print_size = dst_tag == InstructionTargetTag.effective_address or
                           dst_tag == InstructionTargetTag.address;
        try writeAsmTarget(instruction.src, print_size, writer);
    }
    fn writeAsmTarget(target: InstructionTarget, print_size: bool, writer: anytype) !void {
        // TODO: how can I make it so I don't have to unpack it hmm
        switch (target) {
            .register          => |i| try i.writeAsm(writer),
            .segment_register  => |i| try i.writeAsm(writer),
            .address           => |i| try i.writeAsm(writer),
            .effective_address => |i| try i.writeAsm(writer),
            .immediate         => |i| try i.writeAsm(print_size, writer),
        }
    }

    /// A helper method to extract field values from bytes array of field_values
    /// in which fields were stored while determining the instruction_definition.
    /// Allows to get the field value in expected type and specify fallback value
    /// if the field is not part of the instruction_definition.
    fn getFieldInType(
        comptime T: type,
        field: FieldType,
        fallback: T,  // fallback value if instruction definition does not have this field
        instruction_definition: InstructionDefinition,
        field_values: [@typeInfo(FieldType).Enum.fields.len]u8
    ) T {
        if (!instruction_definition.hasField(field)) return fallback;
        const result: T = @intCast(field_values[@intFromEnum(field)]);
        return result;
    }

    pub const InstructionType = enum(u8) { mov, add, sub, cmp };
    const instruction_definitions_separators = " |";
    const instruction_definitions_strings: []const []const u8 = &.{
        "mov 100010 d w | mod reg rm  | disp_lo | disp_hi",
        "mov 1100011  w | mod 000 rm  | disp_lo | disp_hi | data_lo | data_hi",
        "mov 1011 w reg | data_lo     | data_hi",
        // the definitions for memory and segment registers were altered to
        // include the 'd' field which specifies what is source and what is
        // the destination - it simplifies the parsing of instructions
        "mov 101000 d w | addr_lo     | addr_hi",
        "mov 100011 d 0 | mod 0 sr rm | disp_lo | disp_hi",

        "add 000000 d w | mod reg rm  | disp_lo | disp_hi",
        "add 100000 s w | mod 000 rm  | disp_lo | disp_hi | data_lo | data_hi",
        "add 0000010  w | data_lo     | data_hi |",

        "sub 001010 d w | mod reg rm  | disp_lo | disp_hi",
        "sub 100000 s w | mod 101 rm  | disp_lo | disp_hi | data_lo | data_hi",
        "sub 0010110  w | data_lo     | data_hi |",

        "cmp 001110 d w | mod reg rm | disp_lo  | disp_hi",
        "cmp 100000 s w | mod 111 rm | disp_lo  | disp_hi | data_lo | data_hi",
        "cmp 0011110  w | data_lo    | data_hi  |",
    };

    const FieldType = enum(u8) {
        constant, d, w, s, mod, reg, rm, sr,
        disp_lo, disp_hi, data_lo, data_hi, addr_lo, addr_hi,

        pub fn getSize(self: FieldType) u8 {
            return switch(self) {
                .constant => 0,
                .d        => 1,
                .w        => 1,
                .s        => 1,
                .mod      => 2,
                .reg      => 3,
                .rm       => 3,
                .sr       => 2,
                .disp_lo, .disp_hi,
                .data_lo, .data_hi,
                .addr_lo, .addr_hi  => 8,
            };
        }
    };

    const Field = struct {
        type:       FieldType,
        value:      u8,
        bits_count: u8,

        pub fn isPresent(self: Field, mod: u2, w: u1, rm: u3) bool {
            //debug.print("isPresent({}, mod: {}, w: {})\n", .{ self.type, mod, w });
            return switch(self.type) {
                .constant, .d, .w, .s, .mod, .reg,
                .rm, .sr, .data_lo, .addr_lo   => true,
                .disp_lo                       => (rm == 0b110 and mod == 0b00) or mod == 0b01 or mod == 0b10,
                .disp_hi                       => (rm == 0b110 and mod == 0b00) or mod == 0b10,
                .data_hi, .addr_hi             => w == 0b1,
            };
        }
    };

    const InstructionDefinition = result: {
        // extend the amount of branches that can be run in compile time
        @setEvalBranchQuota(100000);

        // to create InstructionDefinition struct we have to count
        // the maximum number of fields in any instruction
        var max_fields: usize = 0;
        for (instruction_definitions_strings) |definition| {
            var fields_iterator = mem.tokenize(u8, definition, instruction_definitions_separators);
            // skip type
            _ = fields_iterator.next().?;
            // count fields
            var fields: usize = 0;
            while (fields_iterator.next()) |_| : (fields += 1) {}
            // save max
            max_fields = @max(max_fields, fields);
        }

        // now we know how big the fields should be
        break :result struct {
            type:            InstructionType,
            fields_buffer:   [max_fields]Field,
            fields_count:    u8,

            pub fn hasField(self: @This(), field_type: FieldType) bool {
                for (self.fields_buffer[0..self.fields_count]) |f| {
                    if (f.type == field_type) return true;
                }
                return false;
            }
        };
    };

    pub fn debugPrintInstructionDefinitions() void {
        for (instruction_definitions) |d| {
            debug.print(
                "type: {}\n" ++
                "fields({d}): [\n",
                .{ d.type, d.fields_count });

            for (d.fields_buffer[0..d.fields_count]) |f| {
                debug.print("  {{ {}, {b}, {d} }}\n", .{f.type, f.value, f.bits_count});
            }

            debug.print("]\n", .{});
        }
    }

    const instruction_definitions = result: {
        // extend the amount of branches that can be run in compile time
        @setEvalBranchQuota(100000);

        // parse the instruction_definitions_strings to actual structs
        var parsed_definitions: [instruction_definitions_strings.len]InstructionDefinition = undefined;

        for (instruction_definitions_strings, 0..) |definition, i| {
            var parsed_definition: InstructionDefinition = undefined;

            var fields_iterator = mem.tokenize(u8, definition, instruction_definitions_separators);

            // parse the type
            const instruction_type_string = fields_iterator.next().?;
            parsed_definition.type = meta.stringToEnum(InstructionType, instruction_type_string)
                orelse @compileError(instruction_type_string ++ " is not a valid InstructionType enum");

            // parse fields
            var field_index = 0;
            var bits_count: u8 = 0;
            parsed_definition.fields_count = 0;
            while (fields_iterator.next()) |field_string| : (field_index += 1) {
                const field =
                    // if field starts with 1 or 0 its a constant
                    if (field_string[0] == '1' or field_string[0] == '0') blk: {
                        break :blk .{
                            .type       = .constant,
                            .value      = fmt.parseInt(u8, field_string, 2) catch unreachable,
                            .bits_count = field_string.len,
                        };
                    }
                    // otherwise it's just a named field so convert it to enum
                    else blk: {
                        const type_enum = meta.stringToEnum(FieldType, field_string)
                            orelse @compileError(field_string ++ " is not a valid FieldType enum");

                        break :blk .{
                            .type       = type_enum,
                            .value      = 0,
                            .bits_count = type_enum.getSize(),
                        };
                    };

                // field validation
                if (field.bits_count > 8) {
                    @compileError("field " ++ field_string ++ " is longer than 8 bits");
                }

                bits_count += field.bits_count;
                if (bits_count == 8) {
                    bits_count = 0;
                } else if (bits_count > 8) {
                    @compileError("field " ++ field_string ++ " spans across bytes! instruction_definition_string: " ++ definition);
                }

                // field is ok
                parsed_definition.fields_buffer[field_index] = field;
                parsed_definition.fields_count = field_index + 1;
                parsed_definitions[i] = parsed_definition;
            }
        }

        break :result parsed_definitions;
    };
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
    for (test_cases, 0..) |test_case, index| {
        // reset the buffer at the end of the loop
        defer fbs.reset();

        // decode
        var input_fixed_buffer_steram = io.fixedBufferStream(test_case.bytes);
        if (CPU8086.decode(input_fixed_buffer_steram.reader())) |optional_instruction| {
            try CPU8086.writeAsm(optional_instruction.?, output_writer);
        } else |err| {
            // print details on decode fail but continue with the tests
            failed_tests += 1;
            debug.print("test {d} failed, bytes: {x}, expected ({d}): '{s}', got: {any}\n", .{
                index,
                fmt.fmtSliceHexLower(test_case.bytes),
                test_case.output.len, test_case.output,
                err
            });
            if (@errorReturnTrace()) |stack| {
                debug.dumpStackTrace(stack.*);
            }
            continue;
        }

        // extract the output from the buffer
        const output = output_buffer[0..fbs.pos];

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
            mem.copyForwards(u8, bytes, test_case.bytes);
            bytes = bytes[test_case.bytes.len..];
            total_bytes_count += test_case.bytes.len;

            mem.copyForwards(u8, expected_output, test_case.output);
            expected_output = expected_output[test_case.output.len..];
            total_output_len += test_case.output.len;
            mem.copyForwards(u8, expected_output, "\n");
            expected_output = expected_output["\n".len..];
            total_output_len += "\n".len;
        }

        bytes           = bytes_buffer          [0..total_bytes_count];
        expected_output = expected_output_buffer[0..total_output_len];

        var input_fixed_buffer_steram = io.fixedBufferStream(bytes);
        const input_reader = input_fixed_buffer_steram.reader();

        // decode
        fbs.reset();
        while (true) {
            if (CPU8086.decode(input_reader)) |optional_instruction| {
                if (optional_instruction) |instruction| {
                    try CPU8086.writeAsm(instruction, output_writer);
                    try output_writer.print("\n", .{});
                } else { break; }
            } else |err| {
                // print details on decode fail but continue with the tests
                failed_tests += 1;
                debug.print("combined test failed with {}\n", .{err});
                if (@errorReturnTrace()) |stack| {
                    debug.dumpStackTrace(stack.*);
                }
                return;
            }
        }

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
