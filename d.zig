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
const testing = std.testing;

pub fn main() !void {
    // just get memory in pages and free all at the end
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit(); // TODO: remove all defers? do I really need those?
    const allocator = arena.allocator();

    // handle args
    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    //debug.print("args: {d}:\n  {s}\n", .{args.len, try mem.join(allocator, "\n  ", args)});
    if (args.len < 2) return error.MissingPath;
    var simulate_option:  ?bool = null;
    var file_path_option: ?[]u8 = null;
    var ai: usize = 1; while ((simulate_option == null or file_path_option == null) and ai < args.len) : (ai+=1) {
             if (mem.eql(u8, args[ai], "--simulate")) { simulate_option = true; }
        else if (mem.startsWith(u8, args[ai], "-"))   { debug.print("Unrecognized option: '{s}'\n", .{args[ai]}); }
        else                                          { file_path_option = args[ai]; }
    }
    const simulate  = simulate_option orelse false;
    const file_path = file_path_option orelse return error.MissingPath;
    if (mem.endsWith(u8, fs.path.extension(file_path), ".asm")) return error.UnexpectedAsmExtension;

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

    //try CPU8086.printInstructionDefinitions(io.getStdErr().writer());

    if (simulate) {
        debug.print("simulating...\n", .{});
        var simulator = mem.zeroes(CPU8086.Simulator);
        // put "mov cl, 12" instruction into memory
        std.mem.copyForwards(u8, &simulator.memory, "\xB1\x0C");
        try simulator.run(stdout_file);
        try simulator.setRegisterValue(.ah, 0x0011);
        try simulator.printRegisters();
    }
    else { // decode
        try stdout.print("; {s}\n\n", .{file_path}); // start by writting filename comment
        try stdout.writeAll("bits 16\n\n");          // and the header which is necessary for nasm
        // read instructions from file and print them out as ASM
        while (try CPU8086.decode(file_reader)) |instruction| {
            try CPU8086.writeAsm(instruction, stdout);
            try stdout.print("\n", .{});
        }
    }
}

const CPU8086 = struct {
    pub const Register = enum(u8) { // DO NOT CHANGE THE ORDER
        al, ax, cl, cx, dl, dx, bl, bx, ah, sp, ch, bp, dh, si, bh, di,

        pub fn is8bit(self: @This()) bool {
            return self == .al or self == .ah or
                   self == .bl or self == .bh or
                   self == .cl or self == .ch or
                   self == .dl or self == .dh;
        }
    };

    pub const RegisterTarget = struct {
        register:   Register,

        pub fn fromFields(reg: u3, w: u1) RegisterTarget {
            const byte_reg: u8 = @intCast(reg);
            return .{ .register = @enumFromInt((byte_reg*2)+w) }; // ASSUMES SPECIFIC ORDER OF ENUM VALUES
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
            return .{ .is_wide = w == 1, .address = @bitCast([_]u8{addr_lo, addr_hi}) };
        }

        pub fn writeAsm(self: @This(), writer: anytype) !void {
            try writer.print("[{d}]", .{self.address});
        }
    };

    pub const EffectiveAddress = enum(u8) { bx_si, bx_di, bp_si, bp_di, si, di, bp, bx, };
    pub const EffectiveAddressTarget = struct {
        type:        EffectiveAddress,
        disp_offset: i16,

        pub fn fromFields(rm: u3, mod: u2, disp_lo: u8, disp_hi: u8) EffectiveAddressTarget {
            const disp_offset: i16 =
                     if (mod == 0b00) 0
                else if (mod == 0b01) @as(i8, @bitCast(disp_lo))
                else if (mod == 0b10) @bitCast([_]u8{disp_lo, disp_hi})
                else unreachable;

            return .{
                .type        = @enumFromInt(rm),
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
            return if (mod == 0b11)                 .{ .register = RegisterTarget.fromFields(rm, w) }
              else if (mod == 0b00 and rm == 0b110) .{ .address = AddressTarget.fromFields(1, disp_lo, disp_hi) }
              else                                  .{ .effective_address = EffectiveAddressTarget.fromFields(rm, mod, disp_lo, disp_hi) };
        }
    };

    pub const Instruction = struct {
        type: InstructionType,
        dst:  InstructionTarget,
        src:  InstructionTarget,
        size: u8,
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
                debug.print("failed on bytes({d}) [{x}]", .{
                    instruction_bytes.len,
                    fmt.fmtSliceHexLower(instruction_bytes.constSlice()), });
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
        instruction.size = instruction_bytes.len;

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
        try writer.print("{s}", .{@tagName(instruction.type)});
        if (instruction.type == .nop or instruction.type == .hlt) return;
        _ = try writer.write(" ");
        try writeAsmTarget(instruction.dst, false, writer);
        _ = try writer.write(", "); // separator between destination and target
        const InstructionTargetTag = @typeInfo(InstructionTarget).Union.tag_type.?;
        const dst_tag = @as(InstructionTargetTag, instruction.dst);
        const print_size = dst_tag == InstructionTargetTag.effective_address or
                           dst_tag == InstructionTargetTag.address;
        try writeAsmTarget(instruction.src, print_size, writer);
    }
    fn writeAsmTarget(target: InstructionTarget, print_size: bool, writer: anytype) !void {
        // NOTE: can I make it so that I don't have to unpack it?
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

    /// Simulate instructions within the memory.
    /// The simulated instructions have to be loaded into the .memory and
    /// instruction pointer .ip has to be set to the index of the first
    /// instruction:
    ///
    ///     var simulator = std.mem.zeroes(CPU8086.Simulator);
    ///     // put "mov cl, 12" instruction into memory
    ///     std.mem.copyForwards(u8, simulator.memory, "\xB1\x0C");
    ///     // instruction pointer already has value of 0 so it points
    ///     // at the first instruction
    ///     try simulator.run(logger); // run, the logger is any type which
    ///                                // implements io/writer.zig from std
    ///
    pub const Simulator = struct {
        memory:    [math.maxInt(u16)]u8,
        registers: [registers_count]u16,
        ip:        u16,

        const registers_count = 8+4; // 8 regular registers (abcd + sp, si, bp, di) and 4 segment registers (page 24)

        pub fn getRegisterValue(self: @This(), register: Register) u16 {
            return switch (register) {
                .ah => (self.registers[0]&0xff00)>>8, .al => self.registers[0]&0x00ff, .ax => self.registers[0],
                .bh => (self.registers[1]&0xff00)>>8, .bl => self.registers[1]&0x00ff, .bx => self.registers[1],
                .ch => (self.registers[2]&0xff00)>>8, .cl => self.registers[2]&0x00ff, .cx => self.registers[2],
                .dh => (self.registers[3]&0xff00)>>8, .dl => self.registers[3]&0x00ff, .dx => self.registers[3],
                .sp => self.registers[4], .bp => self.registers[5], .si => self.registers[6], .di => self.registers[7],
            };
        }

        pub fn setRegisterValue(self: *@This(), register: Register, value: u16) !void {
            if (register.is8bit() and (value&0xff00!=0)) return error.nonZeroHighValueFor8bitRegister;
            return switch (register) {
                .ah => self.registers[0]=(self.registers[0]&0x00ff)|(value<<8), .al => self.registers[0]=(self.registers[0]&0xff00)|value,
                .bh => self.registers[1]=(self.registers[1]&0x00ff)|(value<<8), .bl => self.registers[1]=(self.registers[1]&0xff00)|value,
                .ch => self.registers[2]=(self.registers[2]&0x00ff)|(value<<8), .cl => self.registers[2]=(self.registers[2]&0xff00)|value,
                .dh => self.registers[3]=(self.registers[3]&0x00ff)|(value<<8), .dl => self.registers[3]=(self.registers[3]&0xff00)|value,
                .ax => self.registers[0]=value, .bx => self.registers[1]=value, .cx => self.registers[2]=value, .dx => self.registers[3]=value,
                .sp => self.registers[4]=value, .bp => self.registers[5]=value, .si => self.registers[6]=value, .di => self.registers[7]=value,
            };
        }

        pub fn getSegmentRegisterValue(self: @This(), register: SegmentRegister) u16 {
            return self.registers[8+@as(u8, @intFromEnum(register))];
        }

        pub fn setSegmentRegisterValue(self: *@This(), register: SegmentRegister, value: u16) void {
            self.registers[8+@as(u8, @intFromEnum(register))] = value;
        }

        pub fn printRegisters(self: @This()) !void {
            debug.print( "ip: 0x{x:0>4}\n", .{self.ip});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.ax),        self.getRegisterValue(Register.ax)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.bx),        self.getRegisterValue(Register.bx)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.cx),        self.getRegisterValue(Register.cx)});
            debug.print("{s}: 0x{x:0>4}\n", .{@tagName(Register.dx),        self.getRegisterValue(Register.dx)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.sp),        self.getRegisterValue(Register.sp)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.bp),        self.getRegisterValue(Register.bp)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.si),        self.getRegisterValue(Register.si)});
            debug.print("{s}: 0x{x:0>4}\n", .{@tagName(Register.di),        self.getRegisterValue(Register.di)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(SegmentRegister.es), self.getSegmentRegisterValue(SegmentRegister.es)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(SegmentRegister.cs), self.getSegmentRegisterValue(SegmentRegister.cs)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(SegmentRegister.ss), self.getSegmentRegisterValue(SegmentRegister.ss)});
            debug.print("{s}: 0x{x:0>4}\n", .{@tagName(SegmentRegister.ds), self.getSegmentRegisterValue(SegmentRegister.ds)});
        }

        pub fn run(self: *@This(), logger: anytype) !void {
            _ = try logger.write("simulator run...\n");
            while (true) {
                var memory_steram = io.fixedBufferStream(self.memory[self.ip..]);
                if (try decode(memory_steram.reader())) |instruction| {
                    try CPU8086.writeAsm(instruction, logger);
                    _ = try logger.write("  ; ");
                    switch (instruction.type) {
                        .nop => {}, // do nothing
                        .mov => try self.mov(instruction.dst, instruction.src, logger),
                        .add => try self.add(instruction.dst, instruction.src, logger),
                        .sub => try self.sub(instruction.dst, instruction.src, logger),
                        //.cmp => ,
                        .hlt => break,
                        else => unreachable,
                    }
                    self.ip += instruction.size;
                } else break;
                _ = try logger.write("\n");
            }
            _ = try logger.write("\nsimulation end\n");
        }

        fn add(self: *@This(), dst: InstructionTarget, src: InstructionTarget, logger: anytype) !void {
            const src_value = try self.getSrcValue(dst, src, logger);
            _ = try logger.write(", ");
            var dst_value = try self.getSrcValue(dst, dst, logger);
            _ = try logger.write(", ");
            dst_value.val += src_value.val; // TODO: overflow
            try self.setDstValue(dst, dst_value, logger);
        }

        fn sub(self: *@This(), dst: InstructionTarget, src: InstructionTarget, logger: anytype) !void {
            const src_value = try self.getSrcValue(dst, src, logger);
            _ = try logger.write(", ");
            var dst_value = try self.getSrcValue(dst, dst, logger);
            _ = try logger.write(", ");
            dst_value.val -= src_value.val; // TODO: underflow
            try self.setDstValue(dst, dst_value, logger);
        }

        fn mov(self: *@This(), dst: InstructionTarget, src: InstructionTarget, logger: anytype) !void {
            const src_value = try self.getSrcValue(dst, src, logger);
            _ = try logger.write(", ");
            try self.setDstValue(dst, src_value, logger);
        }

        const Value = struct { val: u16, wide: bool, };
        fn getSrcValue(self: @This(), dst: InstructionTarget, src: InstructionTarget, logger: anytype) !Value {
            _ = try logger.write("get ");
            var v = Value {
                .val  = undefined,
                .wide = undefined,
            };
            switch (src) {
                .register => |i| {
                    v.val  = self.getRegisterValue(i.register);
                    v.wide = i.register.is8bit() == false;
                    try logger.print("register {s}", .{@tagName(i.register)});
                },
                .segment_register => |i| {
                    v.val  = self.getSegmentRegisterValue(i.register);
                    v.wide = true;
                    try logger.print("segment register {s}", .{@tagName(i.register)});
                },
                .address => |i| {
                    v.wide = i.is_wide and switch (dst) {
                        .register => |d| d.register.is8bit() == false,
                        else => true,
                    };
                    v.val = if (v.wide) @as(u16, @bitCast([_]u8{self.memory[i.address+1],self.memory[i.address]}))
                            else        @as(u16, @intCast(self.memory[i.address]));
                    try logger.print("{s}address {d} (0x{x:0>4})", .{ (if (i.is_wide) "wide " else ""), i.address, i.address });
                },
                .immediate => |i| {
                    v.val = if (i.is_wide) @as(u16, @bitCast(i.data)) // is that LISP (O.O)
                            else           @as(u16, @intCast(@as(u8,  @bitCast(@as(i8, @intCast(i.data))))));
                    v.wide = i.is_wide;
                    try logger.print("immedate {s}value {d}", .{ (if (i.is_wide) "wide " else ""), i.data });
                },
                .effective_address => |i| {
                    v.wide = switch (dst) {
                        .register          => |d| d.register.is8bit() == false,
                        .segment_register  => |_| true,
                        .address           => |d| d.is_wide,
                        .effective_address => |_| true,
                        .immediate         => |_| return error.UnknownWideForImmediate,
                    };
                    const address = try self.getEffectiveAddress(i, logger);
                    v.val = if (v.wide) @as(u16, @bitCast([_]u8{self.memory[address+1],self.memory[address]}))
                            else        @as(u16, @intCast(self.memory[address]));
                    try logger.print(" effective address {d} (0x{x:0>4})", .{ address, address });
                },
            }
            try logger.print(" - {s}value {d} (0x{x:0>4})", .{(if (v.wide) "wide " else ""), v.val, v.val});
            return v;
        }

        fn setDstValue(self: *@This(), dst: InstructionTarget, v: Value, logger: anytype) !void {
            _ = try logger.write("set ");
            switch (dst) {
                .register => |i| {
                    try self.setRegisterValue(i.register, v.val);
                    try logger.print("register {s}", .{@tagName(i.register)});
                },
                .segment_register => |i| {
                    self.setSegmentRegisterValue(i.register, v.val);
                    try logger.print("segment register {s}", .{@tagName(i.register)});
                },
                .address => |i| {
                    const data: [2]u8 = @bitCast(v.val);
                    if (v.wide) { self.memory[i.address] = data[1];  self.memory[i.address+1] = data[0]; }
                    else        { self.memory[i.address] = data[0]; }
                    try logger.print("{s}address {d} (0x{x:0>4})", .{ (if (i.is_wide) "wide " else ""), i.address, i.address });
                },
                .effective_address => |i| {
                    const data: [2]u8 = @bitCast(v.val);
                    const address = try self.getEffectiveAddress(i, logger);
                    if (v.wide) { self.memory[address] = data[1];  self.memory[address+1] = data[0]; }
                    else        { self.memory[address] = data[0]; }
                    try logger.print(" effective address {d} (0x{x:0>4})", .{ address, address });
                },
                .immediate => |_| return error.ImmediateUnsupported,
            }
            try logger.print(" = {s} {d} (0x{x:0>4})", .{(if (v.wide) "word " else "byte"), v.val, v.val});
        }

        fn logAndAddRegisters(self: @This(), r1: Register, r2: Register, logger: anytype) !i32 {
            const v1: i32 = @intCast(self.getRegisterValue(r1));
            const v2: i32 = @intCast(self.getRegisterValue(r2));
            try logger.print("{d}+{d}", .{v1, v2});
            return v1 + v2;
        }
        fn logRegister(self: @This(), r: Register, logger: anytype) !i32 {
            const v: i32 = @intCast(self.getRegisterValue(r));
            try logger.print("{d}", .{v});
            return v;
        }
        fn getEffectiveAddress(self: @This(), target: EffectiveAddressTarget, logger: anytype) !u16 {
            _ = try logger.write("[");
            var address: i32 = switch (target.type) {
                .bx_si => try self.logAndAddRegisters(.bx, .si, logger),
                .bx_di => try self.logAndAddRegisters(.bx, .di, logger),
                .bp_si => try self.logAndAddRegisters(.bp, .si, logger),
                .bp_di => try self.logAndAddRegisters(.bp, .di, logger),
                .si    => try self.logRegister(.si, logger),
                .di    => try self.logRegister(.di, logger),
                .bp    => try self.logRegister(.bp, logger),
                .bx    => try self.logRegister(.bx, logger),
            };
            if (target.disp_offset > 0) { try logger.print("+{d}", .{ target.disp_offset}); }
            else                        { try logger.print("-{d}", .{-target.disp_offset}); }
            _ = try logger.write("]");
            address += target.disp_offset;
            return  if (address < 0)                return @as(u16, 0)
               else if (address > math.maxInt(u16)) return math.maxInt(u16)
               else                                 return @intCast(address);
        }
    };

    pub const InstructionType = enum(u8) { hlt, nop, mov, add, sub, cmp };
    const instruction_definitions_separators = " |";
    const instruction_definitions_strings: []const []const u8 = &.{
        "hlt 11110100", // halt the program
        "nop 10010000", // 0x90 do nothing instruction in fact it is a ax to ax move

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
                .rm, .sr, .data_lo, .addr_lo, .addr_hi   => true,
                .disp_lo => (rm == 0b110 and mod == 0b00) or mod == 0b01 or mod == 0b10,
                .disp_hi => (rm == 0b110 and mod == 0b00) or mod == 0b10,
                .data_hi => w == 0b1,
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

    pub fn printInstructionDefinitions(writer: anytype) !void {
        for (instruction_definitions) |d| {
            try writer.print( "type: {}\nfields({d}): [\n", .{ d.type, d.fields_count });
            for (d.fields_buffer[0..d.fields_count]) |f| { try writer.print("  {{ {}, {b}, {d} }}\n", .{f.type, f.value, f.bits_count}); }
            try writer.print("]\n", .{});
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


test "8086.decode" {
    // setup
    const TestCase = struct {
        bytes:  []const u8,
        output: []const u8,
        src: std.builtin.SourceLocation,
    };
    const test_cases = [_]TestCase{
        .{ .src = @src(), .bytes = "\xf4", .output = "hlt" },
        .{ .src = @src(), .bytes = "\x90", .output = "nop" },
          // basic register to register moves
        .{ .src = @src(), .bytes = "\x89\xd9", .output = "mov cx, bx" },
        .{ .src = @src(), .bytes = "\x88\xe5", .output = "mov ch, ah" },
        .{ .src = @src(), .bytes = "\x89\xda", .output = "mov dx, bx" },
        .{ .src = @src(), .bytes = "\x89\xde", .output = "mov si, bx" },
        .{ .src = @src(), .bytes = "\x89\xfb", .output = "mov bx, di" },
        .{ .src = @src(), .bytes = "\x88\xc8", .output = "mov al, cl" },
        .{ .src = @src(), .bytes = "\x88\xed", .output = "mov ch, ch" },
        .{ .src = @src(), .bytes = "\x89\xc3", .output = "mov bx, ax" },
        .{ .src = @src(), .bytes = "\x89\xf3", .output = "mov bx, si" },
        .{ .src = @src(), .bytes = "\x89\xfc", .output = "mov sp, di" },
        .{ .src = @src(), .bytes = "\x89\xc5", .output = "mov bp, ax" },
        .{ .src = @src(), .bytes = "\x89\xde", .output = "mov si, bx" },
        .{ .src = @src(), .bytes = "\x88\xc6", .output = "mov dh, al" },
          // 8-bit immediate-to-register
        .{ .src = @src(), .bytes = "\xb1\x0c", .output = "mov cl, 12" },
        .{ .src = @src(), .bytes = "\xb5\xf4", .output = "mov ch, -12" },
          // 16-bit immediate-to-register
        .{ .src = @src(), .bytes = "\xb8\x34\x12", .output = "mov ax, 4660" },
        .{ .src = @src(), .bytes = "\xb9\x0c\x00", .output = "mov cx, 12" },
        .{ .src = @src(), .bytes = "\xb9\xf4\xff", .output = "mov cx, -12" },
        .{ .src = @src(), .bytes = "\xba\x6c\x0f", .output = "mov dx, 3948" },
        .{ .src = @src(), .bytes = "\xba\x94\xf0", .output = "mov dx, -3948" },
          // Source address calculation
        .{ .src = @src(), .bytes = "\x8a\x00",     .output = "mov al, [bx + si]" },
        .{ .src = @src(), .bytes = "\x8b\x1b",     .output = "mov bx, [bp + di]" },
        .{ .src = @src(), .bytes = "\x8b\x56\x00", .output = "mov dx, [bp]"      },
          // Source address calculation plus 8-bit displacement
        .{ .src = @src(), .bytes = "\x8a\x60\x04", .output = "mov ah, [bx + si + 4]" },
          // Source address calculation plus 16-bit displacement
        .{ .src = @src(), .bytes = "\x8a\x80\x87\x13", .output = "mov al, [bx + si + 4999]" },
          // Dest address calculation
        .{ .src = @src(), .bytes = "\x89\x09",     .output = "mov [bx + di], cx" },
        .{ .src = @src(), .bytes = "\x88\x0a",     .output = "mov [bp + si], cl" },
        .{ .src = @src(), .bytes = "\x88\x6e\x00", .output = "mov [bp], ch"      },
          // Signed displacements
        .{ .src = @src(), .bytes = "\x8b\x41\xdb",     .output = "mov ax, [bx + di - 37]" },
        .{ .src = @src(), .bytes = "\x89\x8c\xd4\xfe", .output = "mov [si - 300], cx"     },
        .{ .src = @src(), .bytes = "\x8b\x57\xe0",     .output = "mov dx, [bx - 32]"      },
          // Explicit sizes
        .{ .src = @src(), .bytes = "\xc6\x03\x07",             .output = "mov [bp + di], byte 7"    },
        .{ .src = @src(), .bytes = "\xc7\x85\x85\x03\x5b\x01", .output = "mov [di + 901], word 347" },
          // Direct address
        .{ .src = @src(), .bytes = "\x8b\x2e\x05\x00", .output = "mov bp, [5]" },
        .{ .src = @src(), .bytes = "\x8b\x1e\x82\x0d", .output = "mov bx, [3458]" },
          // Memory-to-accumulator test
        .{ .src = @src(), .bytes = "\xa1\xfb\x09",     .output = "mov ax, [2555]" },
        .{ .src = @src(), .bytes = "\xa1\x10\x00",     .output = "mov ax, [16]" },
        .{ .src = @src(), .bytes = "\xa0\x00\xf0",     .output = "mov al, [61440]" },
        .{ .src = @src(), .bytes = "\x8a\x26\x00\xf0", .output = "mov ah, [61440]" },
          // Accumulator-to-memory test
        .{ .src = @src(), .bytes = "\xa3\xfa\x09", .output = "mov [2554], ax" },
        .{ .src = @src(), .bytes = "\xa3\x0f\x00", .output = "mov [15], ax" },
          // adds
        .{ .src = @src(), .bytes = "\x03\x18", .output = "add bx, [bx + si]" },
        .{ .src = @src(), .bytes = "\x03\x5e\x00", .output = "add bx, [bp]" },    // id     sw  mod type rm
        .{ .src = @src(), .bytes = "\x83\xc6\x01\x00", .output = "add si, 1" },
        .{ .src = @src(), .bytes = "\x83\xc6\x02\x00", .output = "add si, 2" },
        .{ .src = @src(), .bytes = "\x83\xc5\x02\x00", .output = "add bp, 2" },
        .{ .src = @src(), .bytes = "\x83\xc1\x08\x00", .output = "add cx, 8" },
        .{ .src = @src(), .bytes = "\x03\x5e\x00", .output = "add bx, [bp]" },
        .{ .src = @src(), .bytes = "\x03\x4f\x02", .output = "add cx, [bx + 2]" },
        .{ .src = @src(), .bytes = "\x02\x7a\x04", .output = "add bh, [bp + si + 4]" },
        .{ .src = @src(), .bytes = "\x03\x7b\x06", .output = "add di, [bp + di + 6]" },
        .{ .src = @src(), .bytes = "\x01\x18", .output = "add [bx + si], bx" },
        .{ .src = @src(), .bytes = "\x01\x5e\x00", .output = "add [bp], bx" },
        .{ .src = @src(), .bytes = "\x01\x5e\x00", .output = "add [bp], bx" },
        .{ .src = @src(), .bytes = "\x01\x4f\x02", .output = "add [bx + 2], cx" },
        .{ .src = @src(), .bytes = "\x00\x7a\x04", .output = "add [bp + si + 4], bh" },
        .{ .src = @src(), .bytes = "\x01\x7b\x06", .output = "add [bp + di + 6], di" },
        .{ .src = @src(), .bytes = "\x80\x07\x22", .output = "add [bx], byte 34" },
        .{ .src = @src(), .bytes = "\x83\x82\xe8\x03\x1d\x00", .output = "add [bp + si + 1000], word 29" },
        .{ .src = @src(), .bytes = "\x03\x46\x00", .output = "add ax, [bp]" },
        .{ .src = @src(), .bytes = "\x02\x00", .output = "add al, [bx + si]" },
        .{ .src = @src(), .bytes = "\x01\xd8", .output = "add ax, bx" },
        .{ .src = @src(), .bytes = "\x00\xe0", .output = "add al, ah" },
        .{ .src = @src(), .bytes = "\x83\xc0\x00\x00", .output = "add ax, 0" },
        .{ .src = @src(), .bytes = "\x05\xe8\x03",     .output = "add ax, 1000" },
        .{ .src = @src(), .bytes = "\x04\xe2", .output = "add al, -30" },
        .{ .src = @src(), .bytes = "\x04\x09", .output = "add al, 9" },
          // subs
        .{ .src = @src(), .bytes = "\x2b\x18", .output = "sub bx, [bx + si]" },
        .{ .src = @src(), .bytes = "\x2b\x5e\x00", .output = "sub bx, [bp]" },
        .{ .src = @src(), .bytes = "\x83\xee\x02\x00", .output = "sub si, 2" },
        .{ .src = @src(), .bytes = "\x83\xed\x02\x00", .output = "sub bp, 2" },
        .{ .src = @src(), .bytes = "\x83\xe9\x08\x00", .output = "sub cx, 8" },
        .{ .src = @src(), .bytes = "\x2b\x5e\x00", .output = "sub bx, [bp]" },
        .{ .src = @src(), .bytes = "\x2b\x4f\x02", .output = "sub cx, [bx + 2]" },
        .{ .src = @src(), .bytes = "\x2a\x7a\x04", .output = "sub bh, [bp + si + 4]" },
        .{ .src = @src(), .bytes = "\x2b\x7b\x06", .output = "sub di, [bp + di + 6]" },
        .{ .src = @src(), .bytes = "\x29\x18", .output = "sub [bx + si], bx" },
        .{ .src = @src(), .bytes = "\x29\x5e\x00", .output = "sub [bp], bx" },
        .{ .src = @src(), .bytes = "\x29\x5e\x00", .output = "sub [bp], bx" },
        .{ .src = @src(), .bytes = "\x29\x4f\x02", .output = "sub [bx + 2], cx" },
        .{ .src = @src(), .bytes = "\x28\x7a\x04", .output = "sub [bp + si + 4], bh" },
        .{ .src = @src(), .bytes = "\x29\x7b\x06", .output = "sub [bp + di + 6], di" },
        .{ .src = @src(), .bytes = "\x80\x2f\x22", .output = "sub [bx], byte 34" },
        .{ .src = @src(), .bytes = "\x83\x29\x1d\x00", .output = "sub [bx + di], word 29" },
        .{ .src = @src(), .bytes = "\x2b\x46\x00", .output = "sub ax, [bp]" },
        .{ .src = @src(), .bytes = "\x2a\x00", .output = "sub al, [bx + si]" },
        .{ .src = @src(), .bytes = "\x29\xd8", .output = "sub ax, bx" },
        .{ .src = @src(), .bytes = "\x28\xe0", .output = "sub al, ah" },
        .{ .src = @src(), .bytes = "\x2d\xe8\x03", .output = "sub ax, 1000" },
        .{ .src = @src(), .bytes = "\x2c\xe2", .output = "sub al, -30" },
        .{ .src = @src(), .bytes = "\x2c\x09", .output = "sub al, 9" },
          // cmp
        .{ .src = @src(), .bytes = "\x3b\x18", .output = "cmp bx, [bx + si]" },
        .{ .src = @src(), .bytes = "\x3b\x5e\x00", .output = "cmp bx, [bp]" },
        .{ .src = @src(), .bytes = "\x83\xfe\x02\x00", .output = "cmp si, 2" },
        .{ .src = @src(), .bytes = "\x83\xfd\x02\x00", .output = "cmp bp, 2" },
        .{ .src = @src(), .bytes = "\x83\xf9\x08\x00", .output = "cmp cx, 8" },
        .{ .src = @src(), .bytes = "\x3b\x5e\x00", .output = "cmp bx, [bp]" },
        .{ .src = @src(), .bytes = "\x3b\x4f\x02", .output = "cmp cx, [bx + 2]" },
        .{ .src = @src(), .bytes = "\x3a\x7a\x04", .output = "cmp bh, [bp + si + 4]" },
        .{ .src = @src(), .bytes = "\x3b\x7b\x06", .output = "cmp di, [bp + di + 6]" },
        .{ .src = @src(), .bytes = "\x39\x18", .output = "cmp [bx + si], bx" },
        .{ .src = @src(), .bytes = "\x39\x5e\x00", .output = "cmp [bp], bx" },
        .{ .src = @src(), .bytes = "\x39\x5e\x00", .output = "cmp [bp], bx" },
        .{ .src = @src(), .bytes = "\x39\x4f\x02", .output = "cmp [bx + 2], cx" },
        .{ .src = @src(), .bytes = "\x38\x7a\x04", .output = "cmp [bp + si + 4], bh" },
        .{ .src = @src(), .bytes = "\x39\x7b\x06", .output = "cmp [bp + di + 6], di" },
        .{ .src = @src(), .bytes = "\x80\x3f\x22", .output = "cmp [bx], byte 34" },
        .{ .src = @src(), .bytes = "\x83\x3e\xe2\x12\x1d\x00", .output = "cmp [4834], word 29" },
        .{ .src = @src(), .bytes = "\x3b\x46\x00", .output = "cmp ax, [bp]" },
        .{ .src = @src(), .bytes = "\x3a\x00", .output = "cmp al, [bx + si]" },
        .{ .src = @src(), .bytes = "\x39\xd8", .output = "cmp ax, bx" },
        .{ .src = @src(), .bytes = "\x38\xe0", .output = "cmp al, ah" },
        .{ .src = @src(), .bytes = "\x3d\xe8\x03", .output = "cmp ax, 1000" },
        .{ .src = @src(), .bytes = "\x3c\xe2", .output = "cmp al, -30" },
        .{ .src = @src(), .bytes = "\x3c\x09", .output = "cmp al, 9" },
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
            debug.print("test {d} (line {d}) failed, bytes: {x}, expected ({d}): '{s}', got: {any}\n", .{
                index,
                test_case.src.line,
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
            debug.print("test {d} (line {d}) failed, bytes: {x}, expected ({d}): '{s}', got({d}): '{s}'\n", .{
                index+1,
                test_case.src.line,
                fmt.fmtSliceHexLower(test_case.bytes),
                test_case.output.len, test_case.output,
                output.len, output
            });
        }
    }

    // summary if any failed
    if (failed_tests > 0) {
        debug.print("\nrun {d} tests; passed: {d}; failed: {d}\n", .{
            test_cases.len,
            test_cases.len - failed_tests,
            failed_tests
        });
    }

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

        // compare and print output if any failed
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
        }
    }
}

test "8086.Simulator" {
    var simulator = std.mem.zeroes(CPU8086.Simulator);

    // check if by default everything is zeroed out
    inline for (@typeInfo(CPU8086.Register).Enum.fields) |field| {
        const reg: CPU8086.Register = @enumFromInt(field.value);
        try testing.expectEqual(simulator.getRegisterValue(reg), 0x0000);
    }
    try testing.expectEqual(simulator.ip, 0x0000);
    for (simulator.memory) |m| { try testing.expectEqual(m, 0x00); }

    // test registers set/get
    var vi: u4 = 0;
    inline for (@typeInfo(CPU8086.Register).Enum.fields) |field| {
        const reg: CPU8086.Register = @enumFromInt(field.value);
        if (vi == 0xf) vi = 1 else vi += 1;
        var v: u16 = 0; v += vi; v <<= 4; v+= vi;
        if (!reg.is8bit()) v = (v<<8)+v;
        try simulator.setRegisterValue(reg, v);
        try testing.expectEqual(simulator.getRegisterValue(reg), v);
    }
    inline for (@typeInfo(CPU8086.SegmentRegister).Enum.fields) |field| {
        const reg: CPU8086.SegmentRegister = @enumFromInt(field.value);
        if (vi == 0xf) vi = 1 else vi += 1;
        var v: u16 = 0; v += vi; v <<= 4; v+= vi; v = (v<<8)+v;
        simulator.setSegmentRegisterValue(reg, v);
        try testing.expectEqual(simulator.getSegmentRegisterValue(reg), v);
    }

    // zero out our existing simulator by casting to bytes array and iterating over it
    // NOTE: not necessary by any means but I'm leaving that bit of black magic
    //       spell casting for future reference in case I need it <evil laugh>
    const simbytes = @as([*]u8, @ptrCast(&simulator))[0..@sizeOf(@TypeOf(simulator))];
    for (0..simbytes.len)|i|{simbytes[i]=0;}

    // test instructions execution
    const TestCase = struct {
        mem: []const u8,       // input memory for the simulator
        reg: CPU8086.Register, // the tested register
        val: u16,              // expected value after simulation
        msg: []const u8,       // what to print in case of failure
        src: std.builtin.SourceLocation,
    };
    const test_cases = [_]TestCase{
        // 8-bit immediate-to-register
        .{ .src = @src(), .mem = "\xb1\x0c", .reg = .cl, .val = 0x0c,   .msg = "mov cl, 12" },
        .{ .src = @src(), .mem = "\xb5\xf4", .reg = .ch, .val = 0xf4,   .msg = "mov ch, -12" },
        .{ .src = @src(), .mem = "",         .reg = .cx, .val = 0xf40c, .msg = "cx 0xf40c" },
        // 16-bit immediate-to-register
        .{ .src = @src(), .mem = "\xb9\x0c\x00", .reg = .cx, .val = 0x000c, .msg = "mov cx, 12" },
        .{ .src = @src(), .mem = "\xb9\xf4\xff", .reg = .cx, .val = 0xfff4, .msg = "mov cx, -12" },
        .{ .src = @src(), .mem = "\xba\x6c\x0f", .reg = .dx, .val = 0x0f6c, .msg = "mov dx, 3948" },
        .{ .src = @src(), .mem = "\xba\x94\xf0", .reg = .dx, .val = 0xf094, .msg = "mov dx, -3948" },
        // setup for next tests
        .{ .src = @src(), .mem = "\xb8\x34\x12", .reg = .ax, .val = 0x1234, .msg = "mov ax, 4660" },
        // basic register to register moves
        .{ .src = @src(), .mem = "\x88\xc0", .reg = .al, .val = 0x34, .msg = "mov al, al" },
        .{ .src = @src(), .mem = "\x88\xc1", .reg = .cl, .val = 0x34, .msg = "mov cl, al" },
        .{ .src = @src(), .mem = "\x88\xc2", .reg = .dl, .val = 0x34, .msg = "mov dl, al" },
        .{ .src = @src(), .mem = "\x88\xc3", .reg = .bl, .val = 0x34, .msg = "mov bl, al" },
        .{ .src = @src(), .mem = "\x88\xc4", .reg = .ah, .val = 0x34, .msg = "mov ah, al" },
        .{ .src = @src(), .mem = "\x88\xc5", .reg = .ch, .val = 0x34, .msg = "mov ch, al" },
        .{ .src = @src(), .mem = "\x88\xc6", .reg = .dh, .val = 0x34, .msg = "mov dh, al" },
        .{ .src = @src(), .mem = "\x88\xc7", .reg = .bh, .val = 0x34, .msg = "mov bh, al" },
        // reset register ax before continuing
        .{ .src = @src(), .mem = "\xb8\x34\x12", .reg = .ax, .val = 0x1234, .msg = "mov ax, 4660" },
        .{ .src = @src(), .mem = "\x89\xc0", .reg = .ax, .val = 0x1234, .msg = "mov ax, ax" },
        .{ .src = @src(), .mem = "\x89\xc1", .reg = .cx, .val = 0x1234, .msg = "mov cx, ax" },
        .{ .src = @src(), .mem = "\x89\xc2", .reg = .dx, .val = 0x1234, .msg = "mov dx, ax" },
        .{ .src = @src(), .mem = "\x89\xc3", .reg = .bx, .val = 0x1234, .msg = "mov bx, ax" },
        .{ .src = @src(), .mem = "\x89\xc4", .reg = .sp, .val = 0x1234, .msg = "mov sp, ax" },
        .{ .src = @src(), .mem = "\x89\xc5", .reg = .bp, .val = 0x1234, .msg = "mov bp, ax" },
        .{ .src = @src(), .mem = "\x89\xc6", .reg = .si, .val = 0x1234, .msg = "mov si, ax" },
        .{ .src = @src(), .mem = "\x89\xc7", .reg = .di, .val = 0x1234, .msg = "mov di, ax" },
        // Accumulator-to-memory test
        .{ .src = @src(), .mem = "\xb8\x34\x12", .reg = .ax, .val = 0x1234, .msg = "mov ax, 4660" },
        .{ .src = @src(), .mem = "\xa3\x00\xf0", .reg = .ax, .val = 0x1234, .msg = "mov [61440], ax" },
        .{ .src = @src(), .mem = "\xb8\x00\x00", .reg = .ax, .val = 0x0000, .msg = "mov ax, 0" },
        .{ .src = @src(), .mem = "\xa1\x00\xf0", .reg = .ax, .val = 0x1234, .msg = "mov ax, [61440]" },
        .{ .src = @src(), .mem = "\xa3\x64\x00", .reg = .ax, .val = 0x1234, .msg = "mov [100], ax" },
        .{ .src = @src(), .mem = "\xb8\x00\x00", .reg = .ax, .val = 0x0000, .msg = "mov ax, 0" },
        .{ .src = @src(), .mem = "\xa1\x64\x00", .reg = .ax, .val = 0x1234, .msg = "mov ax, [100]" },
        // Direct address
        .{ .src = @src(), .mem = "\x8b\x2e\x64\x00", .reg = .bp, .val = 0x1234, .msg = "mov bp, [100]" },
        .{ .src = @src(), .mem = "\x8b\x1e\x00\xf0", .reg = .bx, .val = 0x1234, .msg = "mov bx, [61440]" },
        // setup for next tests
        .{ .src = @src(), .mem = "\xb8\x34\x12", .reg = .ax, .val = 0x1234, .msg = "mov ax, 4660" },
        .{ .src = @src(), .mem = "\xa3\x00\xf0", .reg = .ax, .val = 0x1234, .msg = "mov [61440], ax" },
        .{ .src = @src(), .mem = "\xbb\xd8\xef", .reg = .bx, .val = 0xefd8, .msg = "mov bx, 61400" },
        .{ .src = @src(), .mem = "\xbe\x28\x00", .reg = .si, .val = 0x0028, .msg = "mov si, 40" },
        .{ .src = @src(), .mem = "\xbd\xd8\xef", .reg = .bx, .val = 0xefd8, .msg = "mov bp, 61400" },
        .{ .src = @src(), .mem = "\xbf\x28\x00", .reg = .si, .val = 0x0028, .msg = "mov di, 40" },
        .{ .src = @src(), .mem = "\xa3\xd8\xef", .reg = .ax, .val = 0x1234, .msg = "mov [61400], ax" },
        // Source address calculation
        .{ .src = @src(), .mem = "\x8a\x00",     .reg = .al, .val = 0x12,   .msg = "mov al, [bx + si]" },
        .{ .src = @src(), .mem = "\x8b\x1b",     .reg = .bx, .val = 0x1234, .msg = "mov bx, [bp + di]" },
        .{ .src = @src(), .mem = "\x8b\x56\x00", .reg = .dx, .val = 0x1234, .msg = "mov dx, [bp]" },
        // test source address calculation plus 8-bit displacement
        .{ .src = @src(), .mem = "\xb8\x34\x12", .reg = .ax, .val = 0x1234, .msg = "mov ax, 4660" },
        .{ .src = @src(), .mem = "\xa3\x08\xf0", .reg = .ax, .val = 0x1234, .msg = "mov [61448], ax" },
        .{ .src = @src(), .mem = "\xbb\xd8\xef", .reg = .bx, .val = 0xefd8, .msg = "mov bx, 61400" },
        .{ .src = @src(), .mem = "\xbe\x28\x00", .reg = .si, .val = 0x0028, .msg = "mov si, 40" },
        .{ .src = @src(), .mem = "\x8a\x60\x08", .reg = .ah, .val = 0x12,   .msg = "mov ah, [bx + si + 8]" },
        // Source address calculation plus 16-bit displacement
        .{ .src = @src(), .mem = "\xbb\xfa\xaf",     .reg = .bx, .val = 0xaffa, .msg = "mov bx, 45050" },
        .{ .src = @src(), .mem = "\xbe\x06\x00",     .reg = .si, .val = 0x0006, .msg = "mov si, 6" },
        .{ .src = @src(), .mem = "\x8a\x80\x00\x40", .reg = .al, .val = 0x12,   .msg = "mov al, [bx + si + 16384]" },
        // Dest address calculation setup and tests
        .{ .src = @src(), .mem = "\xbd\xd8\xef", .reg = .bp, .val = 0xefd8, .msg = "mov bp, 61400" },
        .{ .src = @src(), .mem = "\xbb\xd8\xef", .reg = .bx, .val = 0xefd8, .msg = "mov bx, 61400" },
        .{ .src = @src(), .mem = "\xbe\x28\x00", .reg = .si, .val = 0x0028, .msg = "mov si, 40" },
        .{ .src = @src(), .mem = "\xbf\x28\x00", .reg = .di, .val = 0x0028, .msg = "mov di, 40" },
        // first test
        .{ .src = @src(), .mem = "\xb8\x00\x00", .reg = .ax, .val = 0x0000, .msg = "mov ax, 0" },
        .{ .src = @src(), .mem = "\xb9\x34\x12", .reg = .cx, .val = 0x1234, .msg = "mov cx, 0x1234" },
        .{ .src = @src(), .mem = "\x89\x09",     .reg = .ax, .val = 0x0000, .msg = "mov [bx + di], cx" },
        .{ .src = @src(), .mem = "\xa1\x00\xf0", .reg = .ax, .val = 0x1234, .msg = "mov ax, [61440]" },
        // second test
        .{ .src = @src(), .mem = "\xb8\x00\x00", .reg = .ax, .val = 0x0000, .msg = "mov ax, 0" },
        .{ .src = @src(), .mem = "\xb1\x66",     .reg = .cl, .val = 0x66,   .msg = "mov cl, 0x66" },
        .{ .src = @src(), .mem = "\x88\x0a",     .reg = .ax, .val = 0x0000, .msg = "mov [bp + si], cl" },
        .{ .src = @src(), .mem = "\xa1\x00\xf0", .reg = .ax, .val = 0x6634, .msg = "mov ax, [61440]" },
        // third test
        .{ .src = @src(), .mem = "\xb8\x00\x00", .reg = .ax, .val = 0x0000, .msg = "mov ax, 0" },
        .{ .src = @src(), .mem = "\xb5\x77",     .reg = .ch, .val = 0x77,   .msg = "mov ch, 0x77" },
        .{ .src = @src(), .mem = "\x88\x6e\x00", .reg = .ax, .val = 0x0000, .msg = "mov [bp], ch" },
        .{ .src = @src(), .mem = "\xa1\xd8\xef", .reg = .ax, .val = 0x7734, .msg = "mov ax, [61400]" },
        // Signed displacements setup and tests
        // first test
        .{ .src = @src(), .mem = "\xb8\x34\x12", .reg = .ax, .val = 0x1234, .msg = "mov ax, 4660" },
        .{ .src = @src(), .mem = "\xa3\x00\xf0", .reg = .ax, .val = 0x1234, .msg = "mov [61440], ax" },
        .{ .src = @src(), .mem = "\xb8\x00\x00", .reg = .ax, .val = 0x0000, .msg = "mov ax, 0" },
        .{ .src = @src(), .mem = "\xbb\xd8\xef", .reg = .bx, .val = 0xefd8, .msg = "mov bx, 61400" },
        .{ .src = @src(), .mem = "\xbf\x50\x00", .reg = .di, .val = 0x0050, .msg = "mov di, 80" },
        .{ .src = @src(), .mem = "\x8b\x41\xd8", .reg = .ax, .val = 0x1234, .msg = "mov ax, [bx + di - 40]" },
        // second test
        .{ .src = @src(), .mem = "\xb9\x34\x12",     .reg = .cx, .val = 0x1234, .msg = "mov cx, 4660" },
        .{ .src = @src(), .mem = "\xbe\x28\xf0",     .reg = .si, .val = 0xf028, .msg = "mov si, 61480" },
        .{ .src = @src(), .mem = "\x89\x4c\xd8",     .reg = .cx, .val = 0x1234, .msg = "mov [si - 40], cx" },
        .{ .src = @src(), .mem = "\xb9\x00\x00",     .reg = .cx, .val = 0x0000, .msg = "mov cx, 0" },
        .{ .src = @src(), .mem = "\x8b\x0e\x00\xf0", .reg = .cx, .val = 0x1234, .msg = "mov cx, [61440]" },
        // third test
        .{ .src = @src(), .mem = "\xb8\x34\x12", .reg = .ax, .val = 0x1234, .msg = "mov ax, 4660" },
        .{ .src = @src(), .mem = "\xa3\x00\xf0", .reg = .ax, .val = 0x1234, .msg = "mov [61440], ax" },
        .{ .src = @src(), .mem = "\xbb\x28\xf0", .reg = .bx, .val = 0xf028, .msg = "mov bx, 61480" },
        .{ .src = @src(), .mem = "\x8b\x57\xd8", .reg = .dx, .val = 0x1234, .msg = "mov dx, [bx - 40]" },
        // Explicit sizes setup and tests
        // first test
        .{ .src = @src(), .mem = "\xbd\xd8\xef",     .reg = .bp, .val = 0xefd8, .msg = "mov bp, 61400" },
        .{ .src = @src(), .mem = "\xbf\x28\x00",     .reg = .di, .val = 0x0028, .msg = "mov di, 40" },
        .{ .src = @src(), .mem = "\xb0\x00",         .reg = .al, .val = 0x00,   .msg = "mov al, 0" },
        .{ .src = @src(), .mem = "\xc6\x03\x07",     .reg = .al, .val = 0x00,   .msg = "mov [bp + di], byte 7" },
        .{ .src = @src(), .mem = "\xa0\x00\xf0",     .reg = .al, .val = 0x07,   .msg = "mov al, [61440]" },
        .{ .src = @src(), .mem = "\x8a\x26\x00\xf0", .reg = .ah, .val = 0x07,   .msg = "mov ah, [61440]" },
        // second test
        .{ .src = @src(), .mem = "\xbf\xd8\xef",         .reg = .di, .val = 0xefd8, .msg = "mov di, 61400" },
        .{ .src = @src(), .mem = "\xb8\x00\x00",         .reg = .ax, .val = 0x0000, .msg = "mov ax, 0" },
        .{ .src = @src(), .mem = "\xc7\x45\x28\x34\x12", .reg = .ax, .val = 0x0000, .msg = "mov [di + 40], word 4660" },
        .{ .src = @src(), .mem = "\xa1\x00\xf0",         .reg = .ax, .val = 0x1234, .msg = "mov ax, [61440]" },
        // Accumulator-to-memory test
        .{ .src = @src(), .mem = "\xb8\x34\x12",     .reg = .ax, .val = 0x1234, .msg = "mov ax, 4660" },
        .{ .src = @src(), .mem = "\xa3\xfa\x09",     .reg = .ax, .val = 0x1234, .msg = "mov [2554], ax" },
        .{ .src = @src(), .mem = "\xbb\x00\x00",     .reg = .bx, .val = 0x0000, .msg = "mov bx, 0" },
        .{ .src = @src(), .mem = "\x8b\x1e\xfa\x09", .reg = .bx, .val = 0x1234, .msg = "mov bx, [2554]" },
        .{ .src = @src(), .mem = "\xa3\x0f\x00",     .reg = .ax, .val = 0x1234, .msg = "mov [15], ax" },
        .{ .src = @src(), .mem = "\xbb\x00\x00",     .reg = .bx, .val = 0x0000, .msg = "mov bx, 0" },
        .{ .src = @src(), .mem = "\x8b\x1e\x0f\x00", .reg = .bx, .val = 0x1234, .msg = "mov bx, [15]" },
        // add tests
        // simple registers add
        // setup and test
        .{ .src = @src(), .mem = "\xb8\x01\x00",     .reg = .ax, .val = 0x0001, .msg = "mov ax, 1" },
        .{ .src = @src(), .mem = "\xbb\x01\x00",     .reg = .bx, .val = 0x0001, .msg = "mov bx, 1" },
        .{ .src = @src(), .mem = "\x01\xd8",         .reg = .ax, .val = 0x0002, .msg = "add ax, bx" },
        // setup and test
        .{ .src = @src(), .mem = "\xb8\x00\xf0",     .reg = .ax, .val = 0xf000, .msg = "mov ax, 61440" },
        .{ .src = @src(), .mem = "\xbb\x00\x0f",     .reg = .bx, .val = 0x0f00, .msg = "mov bx, 3840" },
        .{ .src = @src(), .mem = "\x01\xd8",         .reg = .ax, .val = 0xff00, .msg = "add ax, bx" },
        // setup and test
        .{ .src = @src(), .mem = "\xbe\x01\x00",     .reg = .si, .val = 0x0001, .msg = "mov si, 1" },
        .{ .src = @src(), .mem = "\x83\xc6\x01\x00", .reg = .si, .val = 0x0002, .msg = "add si, 1" },
        .{ .src = @src(), .mem = "\x83\xc6\x02\x00", .reg = .si, .val = 0x0004, .msg = "add si, 2" },
        // setup and test
        .{ .src = @src(), .mem = "\xbd\x01\x00",     .reg = .bp, .val = 0x0001, .msg = "mov bp, 1" },
        .{ .src = @src(), .mem = "\x83\xc5\x02\x00", .reg = .bp, .val = 0x0003, .msg = "add bp, 2" },
        // setup and test
        .{ .src = @src(), .mem = "\xb9\x01\x00",     .reg = .cx, .val = 0x0001, .msg = "mov cx, 1" },
        .{ .src = @src(), .mem = "\x83\xc1\x08\x00", .reg = .cx, .val = 0x0009, .msg = "add cx, 8" },
        // half registers add
        .{ .src = @src(), .mem = "\xb0\x01", .reg = .al, .val = 0x01,   .msg = "mov al, 1" },
        .{ .src = @src(), .mem = "\xb3\x01", .reg = .bl, .val = 0x01,   .msg = "mov bl, 1" },
        .{ .src = @src(), .mem = "\x00\xd8", .reg = .al, .val = 0x02,   .msg = "add al, bl" },
        // memory to register add
        .{ .src = @src(), .mem = "\xb8\x34\x12",     .reg = .ax, .val = 0x1234, .msg = "mov ax, 4660" },
        .{ .src = @src(), .mem = "\xa3\x00\xf0",     .reg = .ax, .val = 0x1234, .msg = "mov [61440], ax" },
        .{ .src = @src(), .mem = "\xbb\x01\x00",     .reg = .bx, .val = 0x0001, .msg = "mov bx, 1" },
        .{ .src = @src(), .mem = "\xbe\xff\xef",     .reg = .si, .val = 0xefff, .msg = "mov si, 61439" },
        .{ .src = @src(), .mem = "\x03\x18",         .reg = .bx, .val = 0x1235, .msg = "add bx, [bx + si]" },
        // setup and test
        .{ .src = @src(), .mem = "\xbd\x00\xf0",             .reg = .bp, .val = 0xf000, .msg = "mov bp, 61440" },
        .{ .src = @src(), .mem = "\xc7\x06\x00\xf0\x01\x00", .reg = .bp, .val = 0xf000, .msg = "mov [61440], word 1" },
        .{ .src = @src(), .mem = "\xa1\x00\xf0",             .reg = .ax, .val = 0x0001, .msg = "mov ax, [61440]" },
        .{ .src = @src(), .mem = "\xbb\x00\x00",             .reg = .bx, .val = 0x0000, .msg = "mov bx, 0" },
        .{ .src = @src(), .mem = "\x03\x5e\x00",             .reg = .bx, .val = 0x0001, .msg = "add bx, [bp]" },
        .{ .src = @src(), .mem = "\x03\x5e\x00",             .reg = .bx, .val = 0x0002, .msg = "add bx, [bp]" },
        // memory with offset to register add
        .{ .src = @src(), .mem = "\xbb\xfe\xef",             .reg = .bx, .val = 0xeffe, .msg = "mov bx, 61438" },
        .{ .src = @src(), .mem = "\xc7\x06\x00\xf0\x01\x00", .reg = .bp, .val = 0xf000, .msg = "mov [61440], word 1" },
        .{ .src = @src(), .mem = "\xb9\x01\x00",             .reg = .cx, .val = 0x0001, .msg = "mov cx, 1" },
        .{ .src = @src(), .mem = "\x03\x4f\x02",             .reg = .cx, .val = 0x0002, .msg = "add cx, [bx + 2]" },
        // memory with effective address calculation and offset to register add
        .{ .src = @src(), .mem = "\xbd\xf6\xef",         .reg = .bp, .val = 0xeff6, .msg = "mov bp, 61430" },
        .{ .src = @src(), .mem = "\xbe\x06\x00",         .reg = .si, .val = 0x0006, .msg = "mov si, 6" },
        .{ .src = @src(), .mem = "\xc6\x06\x00\xf0\x01", .reg = .bp, .val = 0xeff6, .msg = "mov [61440], byte 1" },
        .{ .src = @src(), .mem = "\xb7\x01",             .reg = .bh, .val = 0x01,   .msg = "mov bh, 1" },
        .{ .src = @src(), .mem = "\x02\x7a\x04",         .reg = .bh, .val = 0x02,   .msg = "add bh, [bp + si + 4]" },
        // setup and test
        .{ .src = @src(), .mem = "\xbd\xf6\xef",             .reg = .bp, .val = 0xeff6, .msg = "mov bp, 61430" },
        .{ .src = @src(), .mem = "\xbf\x04\x00",             .reg = .di, .val = 0x04,   .msg = "mov di, 4" },
        .{ .src = @src(), .mem = "\xc7\x06\x00\xf0\x01\x00", .reg = .bp, .val = 0xeff6, .msg = "mov [61440], word 1" },
        .{ .src = @src(), .mem = "\x03\x7b\x06",             .reg = .di, .val = 0x0005, .msg = "add di, [bp + di + 6]" },
        // register to memory address add
        .{ .src = @src(), .mem = "\xbb\xf6\xef",             .reg = .bx, .val = 0xeff6, .msg = "mov bx, 61430" },
        .{ .src = @src(), .mem = "\xbe\x0a\x00",             .reg = .si, .val = 0x000a, .msg = "mov si, 10" },
        .{ .src = @src(), .mem = "\xc7\x06\x00\xf0\x00\x00", .reg = .si, .val = 0x000a, .msg = "mov [61440], word 0" },
        .{ .src = @src(), .mem = "\x01\x18",                 .reg = .si, .val = 0x000a, .msg = "add [bx + si], bx" },
        .{ .src = @src(), .mem = "\xb8\x00\x00",             .reg = .ax, .val = 0x0000, .msg = "mov ax, 0" },
        .{ .src = @src(), .mem = "\x03\x00",                 .reg = .ax, .val = 0xeff6, .msg = "add ax, [bx + si]" },
        // setup and test
        .{ .src = @src(), .mem = "\xbd\x00\xf0",         .reg = .bp, .val = 0xf000, .msg = "mov bp, 61440" },
        .{ .src = @src(), .mem = "\xbb\x01\x00",         .reg = .bx, .val = 0x0001, .msg = "mov bx, 1" },
        .{ .src = @src(), .mem = "\xc7\x46\x00\x00\x00", .reg = .bx, .val = 0x0001, .msg = "mov [bp], word 0" },
        .{ .src = @src(), .mem = "\x01\x5e\x00",         .reg = .bx, .val = 0x0001, .msg = "add [bp], bx" },
        .{ .src = @src(), .mem = "\x01\x5e\x00",         .reg = .bx, .val = 0x0001, .msg = "add [bp], bx" },
        .{ .src = @src(), .mem = "\x01\x5e\x00",         .reg = .bx, .val = 0x0001, .msg = "add [bp], bx" },
        // setup and test
        .{ .src = @src(), .mem = "\x8b\x5e\x00",             .reg = .bx, .val = 0x0003, .msg = "mov bx, [bp]" },
        .{ .src = @src(), .mem = "\xbb\xfe\xef",             .reg = .bx, .val = 0xeffe, .msg = "mov bx, 61438" },
        .{ .src = @src(), .mem = "\xc7\x06\x00\xf0\x07\x00", .reg = .bx, .val = 0xeffe, .msg = "mov [61440], word 7" },
        .{ .src = @src(), .mem = "\xb9\x01\x00",             .reg = .cx, .val = 0x0001, .msg = "mov cx, 1" },
        .{ .src = @src(), .mem = "\x01\x4f\x02",             .reg = .cx, .val = 0x0001, .msg = "add [bx + 2], cx" },
        .{ .src = @src(), .mem = "\x8b\x4f\x02",             .reg = .cx, .val = 0x0008, .msg = "mov cx, [bx + 2]" },
        // setup and test
        //.{ .src = @src(), .bytes = "\x00\x7a\x04", .output = "add [bp + si + 4], bh" },
        //.{ .src = @src(), .bytes = "\x01\x7b\x06", .output = "add [bp + di + 6], di" },
        //.{ .src = @src(), .bytes = "\x80\x07\x22", .output = "add [bx], byte 34" },
        //.{ .src = @src(), .bytes = "\x83\x82\xe8\x03\x1d\x00", .output = "add [bp + si + 1000], word 29" },
        //.{ .src = @src(), .bytes = "\x03\x46\x00", .output = "add ax, [bp]" },
        //.{ .src = @src(), .bytes = "\x02\x00", .output = "add al, [bx + si]" },
        //.{ .src = @src(), .bytes = "\x00\xe0", .output = "add al, ah" },
        //.{ .src = @src(), .bytes = "\x05\xe8\x03", .output = "add ax, 1000" },
        //.{ .src = @src(), .bytes = "\x04\xe2", .output = "add al, -30" },
        //.{ .src = @src(), .bytes = "\x04\x09", .output = "add al, 9" },
    };
    var output_buffer: [1024*1024]u8 = undefined;
    var fbs = io.fixedBufferStream(&output_buffer);
    const logger = fbs.writer();

    for (test_cases, 0..) |test_case, index| {
        // reset the buffer at the end of the loop
        defer fbs.reset();
        // print details on failure
        errdefer debug.print("failed on test case {d} (line {d}): {s}\n",
            .{index+1, test_case.src.line, test_case.msg});
        // NOTE: change to just defer to have complete run output for debugging
        errdefer debug.print("{s}\n", .{output_buffer[0..fbs.pos]});
        // setup - we do not reset or override memory - only append to it
        mem.copyForwards(u8, simulator.memory[simulator.ip..], test_case.mem);
        simulator.memory[simulator.ip + test_case.mem.len] = 0xf4; // hlt at the end
        // run and validate
        try simulator.run(logger);
        try testing.expectEqual(test_case.val, simulator.getRegisterValue(test_case.reg));
    }
}
