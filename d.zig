/// 8086 CPU decoder
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
    debug.print("decoding file: {s}\n", .{file_path});

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
    const file_size = try file.getEndPos();

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

    // read instructions from file till the end of the file
    var bytes_read: u64 = 0;
    while (bytes_read < file_size) {
        const instruction = try CPU8086.decode(file_reader);
        bytes_read += instruction.bytes_count;
        //try CPU8086.writeAsm(instruction, stdout);
    }
}

const CPU8086 = struct {
    pub const InstructionType = enum(u8) {
        MOV,
    };

    pub const Register = enum(u8) {
        AL, AX, // REG 000 W 0 and 1
        CL, CX, // REG 001 W 0 and 1
        DL, DX, // REG 010 W 0 and 1
        BL, BX, // REG 011 W 0 and 1
        AH, SP, // REG 100 W 0 and 1
        CH, BP, // REG 101 W 0 and 1
        DH, SI, // REG 110 W 0 and 1
        BH, DI, // REG 111 W 0 and 1

        pub fn fromFields(reg: u3, w: u1) Register {
            const byte_reg: u8 = @intCast(reg);
            return @enumFromInt((byte_reg*2)+w);
        }
    };

    pub const SegmentRegister = enum(u2) {
        ES, CS, SS, DS,

        pub fn fromFields(sr: u2) SegmentRegister {
            return @enumFromInt(sr);
        }
    };

    pub const AddressTarget = struct {
        is_wide: bool,
        address: u16,

        pub fn fromFields(w: u1, addr_lo: u8, addr_hi: u8) AddressTarget {
            return if (w == 0) .{ .is_wide = false, .address = @intCast(addr_lo) }
                   else        .{ .is_wide = true,  .address = @bitCast([_]u8{addr_hi, addr_lo}) };
        }
    };

    pub const EffectiveAddress = enum(u8) {
        bx_si, bx_di, bp_si, bp_di, si, di, bp, bx,
    };

    pub const EffectiveAddressTarget = struct {
        type:            EffectiveAddress,
        has_disp_offset: bool,
        is_wide:         bool,
        disp_offset:     u16,

        pub fn fromFields(rm: u3, mod: u2, disp_lo: u8, disp_hi: u8) EffectiveAddressTarget {
            const disp_offset: u16 =
                     if (mod == 0b00) 0
                else if (mod == 0b01) @intCast(disp_lo)
                else if (mod == 0b10) @bitCast([_]u8{disp_hi, disp_lo})
                else unreachable;

            return .{
                .type            = @enumFromInt(rm),
                .has_disp_offset = mod != 0b00,
                .is_wide         = mod == 0b10,
                .disp_offset     = disp_offset,
            };
        }
    };

    pub const ImmediateTarget = struct {
        is_wide: bool,
        data:    u16,

        pub fn fromFields(w: u1, data_lo: u8, data_hi: u8) ImmediateTarget {
            return if (w == 0) .{ .is_wide = false, .data = @intCast(data_lo) }
                   else        .{ .is_wide = true,  .data = @bitCast([_]u8{data_hi, data_lo}) };
        }
    };

    pub const InstructionTarget = union(enum) {
        register:          Register,
        segment_register:  SegmentRegister,
        address:           AddressTarget,
        effective_address: EffectiveAddressTarget,
        immediate:         ImmediateTarget,

        pub fn fromFields(mod: u2, rm: u3, w: u1, disp_lo: u8, disp_hi: u8) InstructionTarget {
            if (mod == 0b11) return InstructionTarget {
                .register = Register.fromFields(rm, w)
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
        type:        InstructionType,
        dst:         InstructionTarget,
        src:         InstructionTarget,
        bytes_count: u8,
    };

    /// Decodes single instruction from the given reader
    pub fn decode(reader: anytype) !Instruction {
        // buffer for instruction bytes which assumes maximum capacity of maximum amout of fields * 2 and start with 0
        var instruction_bytes = try std.BoundedArray(u8, instruction_definitions[0].fields_buffer.len * 2).init(0);

        // put first byte into the instruction bytes - we always need at least one
        try instruction_bytes.append(try reader.readByte());

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
                                @intCast(field_values[@intFromEnum(FieldType.w)]))) {
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
                debug.print("failed on bytes({d}) [{x}]", .{
                    instruction_bytes.len,
                    fmt.fmtSliceHexLower(instruction_bytes.constSlice()), });
                return error.UnknownInstruction;
            };

        debug.print("definition for bytes({d}) [{x}]: [{d}] {s}\n", .{
            instruction_bytes.len,
            fmt.fmtSliceHexLower(instruction_bytes.constSlice()),
            definition_index,
            instruction_definitions_strings[definition_index] });

        // determine destination and source
        var instruction: Instruction = undefined;
        instruction.type = instruction_definition.type;
        instruction.bytes_count = @intCast(instruction_bytes.len);

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

        if (instruction_definition.type == .MOV) {
            // dst
            if (instruction_definition.hasField(.sr)) {
                instruction.dst = InstructionTarget { .segment_register = SegmentRegister.fromFields(sr) };
            } else if (instruction_definition.hasField(.reg)) {
                instruction.dst = InstructionTarget { .register = Register.fromFields(reg, w) };
            } else if (instruction_definition.hasField(.disp_lo)) {
                instruction.dst = InstructionTarget.fromFields(mod, rm, w, disp_lo, disp_hi);
            } else if (instruction_definition.hasField(.addr_lo)) {
                instruction.dst = InstructionTarget { .address = AddressTarget.fromFields(w, addr_lo, addr_hi) };
            } else { unreachable; }
            // src
            if (instruction_definition.hasField(.data_lo)) {
                instruction.src = InstructionTarget { .immediate = ImmediateTarget.fromFields(w, data_lo, data_hi) };
            } else if (instruction_definition.hasField(.disp_lo)) {
                instruction.src = InstructionTarget.fromFields(mod, rm, w, disp_lo, disp_hi);
            } else {                                             // accumulator reg = 0b000
                instruction.src = InstructionTarget { .register = Register.fromFields(0b000, w) };
            }
            // swap src with dst if necessary
            if (d == 0) { const tmp = instruction.src; instruction.src = instruction.dst; instruction.dst = tmp; }
        } else {
            return error.OnlyMovInstructionsAreSupported;
        }

        return instruction;
    }

    // Writes given instruction in Assembly representation using given writer
    pub fn writeAsm(instruction: Instruction, writer: anytype) !void {
        // TODO(agabrys)
        try writer.print( "{}:  dest  {any} | src   {any}\n", .{
            instruction.type,
            instruction.dest,
            instruction.src,
         });
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

    const instruction_definitions_separators = " |";
    const instruction_definitions_strings: []const []const u8 = &.{
        "MOV 100010 d w | mod reg rm  | disp_lo | disp_hi",
        "MOV 1000101  w | mod 000 rm  | disp_lo | disp_hi | data_lo | data_hi",
        "MOV 1011 w reg | data_lo     | data_hi",
        // the definitions for memory and segmented registers were altered to
        // include the 'd' field which specifies what is source and what is
        // the destination - it simplifies the parsing of instructions
        "MOV 101000 d w | addr_lo     | addr_hi",
        "MOV 100011 d 0 | mod 0 sr rm | disp_lo | disp_hi",
    };

    const FieldType = enum(u8) {
        constant, d, w, mod, reg, rm, sr,
        disp_lo, disp_hi, data_lo, data_hi, addr_lo, addr_hi,

        pub fn getSize(self: FieldType) u8 {
            return switch(self) {
                .constant => 0,
                .d        => 1,
                .w        => 1,
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

        pub fn isPresent(self: Field, mod: u2, w: u1) bool {
            //debug.print("isPresent({}, mod: {}, w: {})\n", .{ self.type, mod, w });
            return switch(self.type) {
                .constant, .d, .w, .mod, .reg,
                .rm, .sr, .data_lo, .addr_lo   => true,
                .disp_lo                       => mod == 0b01 or mod == 0b10,
                .disp_hi                       => mod == 0b10,
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
