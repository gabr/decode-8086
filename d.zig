/// 8086 CPU decoder v2
const std     = @import("std");
const io      = std.io;
const fs      = std.fs;
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

    //debug.print("args: {d}:\n  {s}\n", .{args.len, try std.mem.join(allocator, "\n  ", args)});
    if (args.len < 2) return error.MissingPath;
    var simulate_option:  ?bool = null;
    var file_path_option: ?[]u8 = null;
    var ai: usize = 1; while ((simulate_option == null or file_path_option == null) and ai < args.len) : (ai+=1) {
             if (std.mem.eql(u8, args[ai], "--simulate")) { simulate_option = true; }
        else if (std.mem.startsWith(u8, args[ai], "-"))   { debug.print("Unrecognized option: '{s}'\n", .{args[ai]}); }
        else                                          { file_path_option = args[ai]; }
    }
    const simulate  = simulate_option orelse false;
    const file_path = file_path_option orelse return error.MissingPath;
    if (std.mem.endsWith(u8, fs.path.extension(file_path), ".asm")) return error.UnexpectedAsmExtension;

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
        var simulator = std.mem.zeroes(CPU8086.Simulator);
        // put "mov cl, 12" instruction into memory
        std.mem.copyForwards(u8, &simulator.memory, "\xB1\x0C");
        try simulator.run(stdout_file);
        try simulator.setRegister(.ah, 0x0011);
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
        flags:     u16,

        // NOTE: ony flags needed for cmp instruction
        pub const Flag = enum(u4) { zf=6, sf=7, };

        const registers_count = 8+4; // 8 regular registers (abcd + sp, si, bp, di) and 4 segment registers (page 24)

        pub fn getFlag(self: @This(), flag: Flag) bool {
            return self.flags & (@as(u16, 1)<<@intFromEnum(flag)) != 0;
        }

        pub fn setFlag(self: *@This(), flag: Flag, value: bool) void {
            if (value) { self.flags |=   @as(u16, 1)<<@intFromEnum(flag);  }
            else       { self.flags &= ~(@as(u16, 1)<<@intFromEnum(flag)); }
        }

        pub fn getRegister(self: @This(), register: Register) u16 {
            return switch (register) {
                .ah => (self.registers[0]&0xff00)>>8, .al => self.registers[0]&0x00ff, .ax => self.registers[0],
                .bh => (self.registers[1]&0xff00)>>8, .bl => self.registers[1]&0x00ff, .bx => self.registers[1],
                .ch => (self.registers[2]&0xff00)>>8, .cl => self.registers[2]&0x00ff, .cx => self.registers[2],
                .dh => (self.registers[3]&0xff00)>>8, .dl => self.registers[3]&0x00ff, .dx => self.registers[3],
                .sp => self.registers[4], .bp => self.registers[5], .si => self.registers[6], .di => self.registers[7],
            };
        }

        pub fn setRegister(self: *@This(), register: Register, value: u16) !void {
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

        pub fn getSegmentRegister(self: @This(), register: SegmentRegister) u16 {
            return self.registers[8+@as(u8, @intFromEnum(register))];
        }

        pub fn setSegmentRegister(self: *@This(), register: SegmentRegister, value: u16) void {
            self.registers[8+@as(u8, @intFromEnum(register))] = value;
        }

        pub fn printRegisters(self: @This()) !void {
            debug.print( "ip: 0x{x:0>4}\n", .{self.ip});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.ax),        self.getRegister(Register.ax)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.bx),        self.getRegister(Register.bx)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.cx),        self.getRegister(Register.cx)});
            debug.print("{s}: 0x{x:0>4}\n", .{@tagName(Register.dx),        self.getRegister(Register.dx)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.sp),        self.getRegister(Register.sp)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.bp),        self.getRegister(Register.bp)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(Register.si),        self.getRegister(Register.si)});
            debug.print("{s}: 0x{x:0>4}\n", .{@tagName(Register.di),        self.getRegister(Register.di)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(SegmentRegister.es), self.getSegmentRegister(SegmentRegister.es)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(SegmentRegister.cs), self.getSegmentRegister(SegmentRegister.cs)});
            debug.print("{s}: 0x{x:0>4}  ", .{@tagName(SegmentRegister.ss), self.getSegmentRegister(SegmentRegister.ss)});
            debug.print("{s}: 0x{x:0>4}\n", .{@tagName(SegmentRegister.ds), self.getSegmentRegister(SegmentRegister.ds)});
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
                        .cmp => try self.cmp(instruction.dst, instruction.src, logger),
                        .hlt => break,
                    }
                    self.ip += instruction.size;
                } else break;
                _ = try logger.write("\n");
            }
            _ = try logger.write("\nsimulation end\n");
        }

        fn mov(self: *@This(), dst: InstructionTarget, src: InstructionTarget, logger: anytype) !void {
            const src_value = try self.getSrcValue(dst, src, null, logger);
            _ = try logger.write(", ");
            try self.setDstValue(dst, src_value, logger);
        }

        fn add(self: *@This(), dst: InstructionTarget, src: InstructionTarget, logger: anytype) !void {
            const src_value = try self.getSrcValue(dst, src, null,           logger); _ = try logger.write(", ");
            const dst_value = try self.getSrcValue(dst, dst, src_value.wide, logger); _ = try logger.write(", ");
            const result = dst_value.val + src_value.val; // TODO: handle overflow
            try self.setDstValue(dst, .{ .val = result, .wide = src_value.wide }, logger);
            self.setFlag(.sf, result < 0);
            self.setFlag(.zf, result == 0);
        }

        fn sub(self: *@This(), dst: InstructionTarget, src: InstructionTarget, logger: anytype) !void {
            const src_value = try self.getSrcValue(dst, src, null,           logger); _ = try logger.write(", ");
            const dst_value = try self.getSrcValue(dst, dst, src_value.wide, logger); _ = try logger.write(", ");
            const result = dst_value.val - src_value.val; // TODO: handle underflow
            try self.setDstValue(dst, .{ .val = result, .wide = src_value.wide }, logger);
            self.setFlag(.sf, result < 0);
            self.setFlag(.zf, result == 0);
        }

        fn cmp(self: *@This(), dst: InstructionTarget, src: InstructionTarget, logger: anytype) !void {
            const src_value = try self.getSrcValue(dst, src, null,           logger); _ = try logger.write(", ");
            const dst_value = try self.getSrcValue(dst, dst, src_value.wide, logger); _ = try logger.write(", ");
            const sf = dst_value.val <  src_value.val; self.setFlag(.sf, sf);
            const zf = dst_value.val == src_value.val; self.setFlag(.zf, zf);
            try logger.print(", sf: {s}  zf: {s}", .{ if (sf) "1" else "0", if (zf) "1" else "0" });
        }

        const Value = struct { val: u16, wide: bool, };
        fn getSrcValue(self: @This(), dst: InstructionTarget, src: InstructionTarget, wide: ?bool, logger: anytype) !Value {
            _ = try logger.write("get ");
            var v = Value {
                .val  = undefined,
                .wide = undefined,
            };
            if (wide) |w| v.wide = w;
            switch (src) {
                .register => |i| {
                    v.val  = self.getRegister(i.register);
                    if (wide == null) v.wide = i.register.is8bit() == false;
                    try logger.print("register {s}", .{@tagName(i.register)});
                },
                .segment_register => |i| {
                    v.val  = self.getSegmentRegister(i.register);
                    if (wide == null) v.wide = true;
                    try logger.print("segment register {s}", .{@tagName(i.register)});
                },
                .address => |i| {
                    if (wide == null) v.wide = i.is_wide and switch (dst) {
                        .register => |d| d.register.is8bit() == false,
                        else => true,
                    };
                    v.val = if (v.wide) @as(u16, @bitCast([_]u8{self.memory[i.address+1],self.memory[i.address]}))
                            else        @as(u16, @intCast(self.memory[i.address]));
                    try logger.print("{s}address {d} (0x{x:0>4})", .{ (if (i.is_wide) "wide " else ""), i.address, i.address });
                },
                .immediate => |i| {
                    if (wide == null) v.wide = i.is_wide;
                    v.val = if (i.is_wide) @as(u16, @bitCast(i.data)) // is that LISP (O.O)
                            else           @as(u16, @intCast(@as(u8,  @bitCast(@as(i8, @intCast(i.data))))));
                    try logger.print("immedate {s}value {d}", .{ (if (i.is_wide) "wide " else ""), i.data });
                },
                .effective_address => |i| {
                    if (wide == null) v.wide = switch (dst) {
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
                    try self.setRegister(i.register, v.val);
                    try logger.print("register {s}", .{@tagName(i.register)});
                },
                .segment_register => |i| {
                    self.setSegmentRegister(i.register, v.val);
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
            const v1: i32 = @intCast(self.getRegister(r1));
            const v2: i32 = @intCast(self.getRegister(r2));
            try logger.print("{d}+{d}", .{v1, v2});
            return v1 + v2;
        }
        fn logRegister(self: @This(), r: Register, logger: anytype) !i32 {
            const v: i32 = @intCast(self.getRegister(r));
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
            var fields_iterator = std.mem.tokenize(u8, definition, instruction_definitions_separators);
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

            var fields_iterator = std.mem.tokenize(u8, definition, instruction_definitions_separators);

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
        if (std.mem.eql(u8, test_case.output, output) == false) {
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
            std.mem.copyForwards(u8, bytes, test_case.bytes);
            bytes = bytes[test_case.bytes.len..];
            total_bytes_count += test_case.bytes.len;

            std.mem.copyForwards(u8, expected_output, test_case.output);
            expected_output = expected_output[test_case.output.len..];
            total_output_len += test_case.output.len;
            std.mem.copyForwards(u8, expected_output, "\n");
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
        if (std.mem.eql(u8, expected_output, output) == false) {
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
        try testing.expectEqual(simulator.getRegister(reg), 0x0000);
    }
    try testing.expectEqual(simulator.ip, 0x0000);
    for (simulator.memory) |m| { try testing.expectEqual(m, 0x00); }

    // test flags
    try testing.expectEqual(false, simulator.getFlag(.zf));
    try testing.expectEqual(false, simulator.getFlag(.sf));
    simulator.setFlag(.zf, true);  try testing.expectEqual(true,  simulator.getFlag(.zf));
    simulator.setFlag(.sf, true);  try testing.expectEqual(true,  simulator.getFlag(.sf));
    simulator.setFlag(.zf, false); try testing.expectEqual(false, simulator.getFlag(.zf));
    simulator.setFlag(.sf, false); try testing.expectEqual(false, simulator.getFlag(.sf));

    // test registers set/get
    var vi: u4 = 0;
    inline for (@typeInfo(CPU8086.Register).Enum.fields) |field| {
        const reg: CPU8086.Register = @enumFromInt(field.value);
        if (vi == 0xf) vi = 1 else vi += 1;
        var v: u16 = 0; v += vi; v <<= 4; v+= vi;
        if (!reg.is8bit()) v = (v<<8)+v;
        try simulator.setRegister(reg, v);
        try testing.expectEqual(simulator.getRegister(reg), v);
    }
    inline for (@typeInfo(CPU8086.SegmentRegister).Enum.fields) |field| {
        const reg: CPU8086.SegmentRegister = @enumFromInt(field.value);
        if (vi == 0xf) vi = 1 else vi += 1;
        var v: u16 = 0; v += vi; v <<= 4; v+= vi; v = (v<<8)+v;
        simulator.setSegmentRegister(reg, v);
        try testing.expectEqual(simulator.getSegmentRegister(reg), v);
    }

    // zero out our existing simulator by casting to bytes array and iterating over it
    // NOTE: not necessary by any means but I'm leaving that bit of black magic
    //       spell casting for future reference in case I need it <evil laugh>
    const simbytes = @as([*]u8, @ptrCast(&simulator))[0..@sizeOf(@TypeOf(simulator))];
    for (0..simbytes.len)|i|{simbytes[i]=0;}

    // test instructions execution
    const TC = struct { // TestCase
        src: std.builtin.SourceLocation,

        inst:  ?struct { mem:  []const u8,        txt: []const u8, }, // execute instruction with an asm/text for printing
        mem:   ?struct { addr: u16,               val: []const u8  }, // test if memory addr has provided val
        reg:   ?struct { reg:  CPU8086.Register,  val: u16         }, // test if given register has provided value
        flags: ?struct { zf:   bool,              sf:  bool        }, // test if given flag has provided value

        pub fn Init (src: std.builtin.SourceLocation) @This() { return .{ .src = src, .inst = null, .mem = null, .reg = null, .flags = null, }; }
        pub fn Inst (tc: @This(), mem:  []const u8,       txt: []const u8) @This() { var new = tc; new.inst  = .{ .mem  = mem,  .txt = txt }; return new; }
        pub fn Mem  (tc: @This(), addr: u16,              val: []const u8) @This() { var new = tc; new.mem   = .{ .addr = addr, .val = val }; return new; }
        pub fn Reg  (tc: @This(), reg:  CPU8086.Register, val: u16)        @This() { var new = tc; new.reg   = .{ .reg  = reg,  .val = val }; return new; }
        pub fn Flags(tc: @This(), zf:   bool,              sf: bool)       @This() { var new = tc; new.flags = .{ .zf   = zf,   .sf  =  sf }; return new; }
    };
    const test_cases = [_]TC{
        // 8-bit immediate-to-register
        TC.Init(@src()).Inst("\xb1\x0c", "mov cl, 12")  .Reg(.cl, 0x0c),
        TC.Init(@src()).Inst("\xb5\xf4", "mov ch, -12") .Reg(.ch, 0xf4),
        TC.Init(@src()).Reg(.cx, 0xf40c),
        // 16-bit immediate-to-register
        TC.Init(@src()).Inst("\xb9\x0c\x00", "mov cx, 12")    .Reg(.cx, 0x000c),
        TC.Init(@src()).Inst("\xb9\xf4\xff", "mov cx, -12")   .Reg(.cx, 0xfff4),
        TC.Init(@src()).Inst("\xba\x6c\x0f", "mov dx, 3948")  .Reg(.dx, 0x0f6c),
        TC.Init(@src()).Inst("\xba\x94\xf0", "mov dx, -3948") .Reg(.dx, 0xf094),
        // setup for next tests
        TC.Init(@src()).Inst("\xb8\x34\x12", "mov ax, 4660") .Reg(.ax, 0x1234),
        // basic register to register moves
        TC.Init(@src()).Inst("\x88\xc0", "mov al, al") .Reg(.al, 0x34),
        TC.Init(@src()).Inst("\x88\xc1", "mov cl, al") .Reg(.cl, 0x34),
        TC.Init(@src()).Inst("\x88\xc2", "mov dl, al") .Reg(.dl, 0x34),
        TC.Init(@src()).Inst("\x88\xc3", "mov bl, al") .Reg(.bl, 0x34),
        TC.Init(@src()).Inst("\x88\xc4", "mov ah, al") .Reg(.ah, 0x34),
        TC.Init(@src()).Inst("\x88\xc5", "mov ch, al") .Reg(.ch, 0x34),
        TC.Init(@src()).Inst("\x88\xc6", "mov dh, al") .Reg(.dh, 0x34),
        TC.Init(@src()).Inst("\x88\xc7", "mov bh, al") .Reg(.bh, 0x34),
        // reset register ax before continuing
        TC.Init(@src()).Inst("\xb8\x34\x12", "mov ax, 4660") .Reg(.ax, 0x1234),
        TC.Init(@src()).Inst("\x89\xc0",     "mov ax, ax")   .Reg(.ax, 0x1234),
        TC.Init(@src()).Inst("\x89\xc1",     "mov cx, ax")   .Reg(.cx, 0x1234),
        TC.Init(@src()).Inst("\x89\xc2",     "mov dx, ax")   .Reg(.dx, 0x1234),
        TC.Init(@src()).Inst("\x89\xc3",     "mov bx, ax")   .Reg(.bx, 0x1234),
        TC.Init(@src()).Inst("\x89\xc4",     "mov sp, ax")   .Reg(.sp, 0x1234),
        TC.Init(@src()).Inst("\x89\xc5",     "mov bp, ax")   .Reg(.bp, 0x1234),
        TC.Init(@src()).Inst("\x89\xc6",     "mov si, ax")   .Reg(.si, 0x1234),
        TC.Init(@src()).Inst("\x89\xc7",     "mov di, ax")   .Reg(.di, 0x1234),
        // Accumulator-to-memory test
        TC.Init(@src()).Inst("\xb8\x34\x12", "mov ax, 4660")    .Reg(.ax, 0x1234),
        TC.Init(@src()).Inst("\xa3\x00\xf0", "mov [61440], ax") .Mem(61440, "\x12\x34"),
        TC.Init(@src()).Inst("\xb8\x00\x00", "mov ax, 0")       .Reg(.ax, 0x0000),
        TC.Init(@src()).Inst("\xa1\x00\xf0", "mov ax, [61440]") .Reg(.ax, 0x1234),
        TC.Init(@src()).Inst("\xa3\x64\x00", "mov [100], ax")   .Mem(100, "\x12\x34"),
        TC.Init(@src()).Inst("\xb8\x00\x00", "mov ax, 0")       .Reg(.ax, 0x0000),
        TC.Init(@src()).Inst("\xa1\x64\x00", "mov ax, [100]")   .Reg(.ax, 0x1234),
        // Direct address
        TC.Init(@src()).Inst("\x8b\x2e\x64\x00", "mov bp, [100]")   .Reg(.bp, 0x1234),
        TC.Init(@src()).Inst("\x8b\x1e\x00\xf0", "mov bx, [61440]") .Reg(.bx, 0x1234),
        // setup for next tests
        TC.Init(@src()).Inst("\xb8\x34\x12", "mov ax, 4660")    .Reg(.ax, 0x1234),
        TC.Init(@src()).Inst("\xa3\x00\xf0", "mov [61440], ax") .Mem (61440, "\x12\x34"),
        TC.Init(@src()).Inst("\xbb\xd8\xef", "mov bx, 61400")   .Reg(.bx, 0xefd8),
        TC.Init(@src()).Inst("\xbe\x28\x00", "mov si, 40")      .Reg(.si, 0x0028),
        TC.Init(@src()).Inst("\xbd\xd8\xef", "mov bp, 61400")   .Reg(.bx, 0xefd8),
        TC.Init(@src()).Inst("\xbf\x28\x00", "mov di, 40")      .Reg(.si, 0x0028),
        TC.Init(@src()).Inst("\xa3\xd8\xef", "mov [61400], ax") .Mem(61400, "\x12\x34"),
        // Source address calculation
        TC.Init(@src()).Inst("\x8a\x00",     "mov al, [bx + si]") .Reg(.al, 0x12),
        TC.Init(@src()).Inst("\x8b\x1b",     "mov bx, [bp + di]") .Reg(.bx, 0x1234),
        TC.Init(@src()).Inst("\x8b\x56\x00", "mov dx, [bp]")      .Reg(.dx, 0x1234),
        // test source address calculation plus 8-bit displacement
        TC.Init(@src()).Inst("\xb8\x34\x12", "mov ax, 4660")          .Reg(.ax, 0x1234),
        TC.Init(@src()).Inst("\xa3\x08\xf0", "mov [61448], ax")       .Mem(61448, "\x12\x34"),
        TC.Init(@src()).Inst("\xbb\xd8\xef", "mov bx, 61400")         .Reg(.bx, 0xefd8),
        TC.Init(@src()).Inst("\xbe\x28\x00", "mov si, 40")            .Reg(.si, 0x0028),
        TC.Init(@src()).Inst("\x8a\x60\x08", "mov ah, [bx + si + 8]") .Reg(.ah, 0x12),
        // Source address calculation plus 16-bit displacement
        TC.Init(@src()).Inst("\xbb\xfa\xaf",     "mov bx, 45050")             .Reg(.bx, 0xaffa),
        TC.Init(@src()).Inst("\xbe\x06\x00",     "mov si, 6")                 .Reg(.si, 0x0006),
        TC.Init(@src()).Inst("\x8a\x80\x00\x40", "mov al, [bx + si + 16384]") .Reg(.al, 0x12),
        // Dest address calculation setup and tests
        TC.Init(@src()).Inst("\xbd\xd8\xef", "mov bp, 61400") .Reg(.bp, 0xefd8),
        TC.Init(@src()).Inst("\xbb\xd8\xef", "mov bx, 61400") .Reg(.bx, 0xefd8),
        TC.Init(@src()).Inst("\xbe\x28\x00", "mov si, 40")    .Reg(.si, 0x0028),
        TC.Init(@src()).Inst("\xbf\x28\x00", "mov di, 40")    .Reg(.di, 0x0028),
        // first test
        TC.Init(@src()).Inst("\xb8\x00\x00", "mov ax, 0")         .Reg(.ax, 0x0000),
        TC.Init(@src()).Inst("\xb9\x34\x12", "mov cx, 0x1234")    .Reg(.cx, 0x1234),
        TC.Init(@src()).Inst("\x89\x09",     "mov [bx + di], cx") .Mem(61440, "\x12\x34"),
        // second test
        TC.Init(@src()).Inst("\xb8\x00\x00", "mov ax, 0")         .Reg(.ax, 0x0000),
        TC.Init(@src()).Inst("\xb1\x66",     "mov cl, 0x66")      .Reg(.cl, 0x66),
        TC.Init(@src()).Inst("\x88\x0a",     "mov [bp + si], cl") .Mem(61440, "\x66\x34"),
        // third test
        TC.Init(@src()).Inst("\xb8\x00\x00", "mov ax, 0")       .Reg(.ax, 0x0000),
        TC.Init(@src()).Inst("\xb5\x77",     "mov ch, 0x77")    .Reg(.ch, 0x77),
        TC.Init(@src()).Inst("\x88\x6e\x00", "mov [bp], ch")    .Mem(61400, "\x77\x34"),
        // Signed displacements setup and tests
        // first test
        TC.Init(@src()).Inst("\xb8\x34\x12", "mov ax, 4660")           .Reg(.ax, 0x1234),
        TC.Init(@src()).Inst("\xa3\x00\xf0", "mov [61440], ax")        .Mem(61440, "\x12\x34"),
        TC.Init(@src()).Inst("\xb8\x00\x00", "mov ax, 0")              .Reg(.ax, 0x0000),
        TC.Init(@src()).Inst("\xbb\xd8\xef", "mov bx, 61400")          .Reg(.bx, 0xefd8),
        TC.Init(@src()).Inst("\xbf\x50\x00", "mov di, 80")             .Reg(.di, 0x0050),
        TC.Init(@src()).Inst("\x8b\x41\xd8", "mov ax, [bx + di - 40]") .Reg(.ax, 0x1234),
        // second test
        TC.Init(@src()).Inst("\xb9\x34\x12",     "mov cx, 4660")      .Reg(.cx, 0x1234),
        TC.Init(@src()).Inst("\xbe\x28\xf0",     "mov si, 61480")     .Reg(.si, 0xf028),
        TC.Init(@src()).Inst("\x89\x4c\xd8",     "mov [si - 40], cx") .Mem(61440, "\x12\x34"),
        // third test
        TC.Init(@src()).Inst("\xb8\x34\x12", "mov ax, 4660")      .Reg(.ax, 0x1234),
        TC.Init(@src()).Inst("\xa3\x00\xf0", "mov [61440], ax")   .Mem(61440, "\x12\x34"),
        TC.Init(@src()).Inst("\xbb\x28\xf0", "mov bx, 61480")     .Reg(.bx, 0xf028),
        TC.Init(@src()).Inst("\x8b\x57\xd8", "mov dx, [bx - 40]") .Reg(.dx, 0x1234),
        // Explicit sizes setup and tests
        // first test
        TC.Init(@src()).Inst("\xbd\xd8\xef",     "mov bp, 61400")         .Reg(.bp, 0xefd8),
        TC.Init(@src()).Inst("\xbf\x28\x00",     "mov di, 40")            .Reg(.di, 0x0028),
        TC.Init(@src()).Inst("\xb0\x00",         "mov al, 0")             .Reg(.al, 0x00),
        TC.Init(@src()).Inst("\xc6\x03\x07",     "mov [bp + di], byte 7") .Mem(61440, "\x07"),
        TC.Init(@src()).Inst("\xa0\x00\xf0",     "mov al, [61440]")       .Reg(.al, 0x07),
        TC.Init(@src()).Inst("\x8a\x26\x00\xf0", "mov ah, [61440]")       .Reg(.ah, 0x07),
        // second test
        TC.Init(@src()).Inst("\xbf\xd8\xef",         "mov di, 61400")            .Reg(.di, 0xefd8),
        TC.Init(@src()).Inst("\xb8\x00\x00",         "mov ax, 0")                .Reg(.ax, 0x0000),
        TC.Init(@src()).Inst("\xc7\x45\x28\x34\x12", "mov [di + 40], word 4660") .Mem(61440, "\x12\x34"),
        // Accumulator-to-memory test
        TC.Init(@src()).Inst("\xb8\x34\x12",     "mov ax, 4660")   .Reg(.ax, 0x1234),
        TC.Init(@src()).Inst("\xa3\xfa\x09",     "mov [2554], ax") .Mem(2554, "\x12\x34"),
        TC.Init(@src()).Inst("\xbb\x00\x00",     "mov bx, 0")      .Reg(.bx, 0x0000),
        TC.Init(@src()).Inst("\x8b\x1e\xfa\x09", "mov bx, [2554]") .Reg(.bx, 0x1234),
        TC.Init(@src()).Inst("\xa3\x0f\x00",     "mov [15], ax")   .Mem(15, "\x12\x34"),
        // add tests
        // simple registers add
        // setup and test
        TC.Init(@src()).Inst("\xb8\x01\x00", "mov ax, 1")  .Reg(.ax, 0x0001),
        TC.Init(@src()).Inst("\xbb\x01\x00", "mov bx, 1")  .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\x01\xd8",     "add ax, bx") .Reg(.ax, 0x0002),
        // setup and test
        TC.Init(@src()).Inst("\xb8\x00\xf0", "mov ax, 61440") .Reg(.ax, 0xf000),
        TC.Init(@src()).Inst("\xbb\x00\x0f", "mov bx, 3840")  .Reg(.bx, 0x0f00),
        TC.Init(@src()).Inst("\x01\xd8",     "add ax, bx")    .Reg(.ax, 0xff00),
        // setup and test
        TC.Init(@src()).Inst("\xbe\x01\x00",     "mov si, 1") .Reg(.si, 0x0001),
        TC.Init(@src()).Inst("\x83\xc6\x01\x00", "add si, 1") .Reg(.si, 0x0002),
        TC.Init(@src()).Inst("\x83\xc6\x02\x00", "add si, 2") .Reg(.si, 0x0004),
        // setup and test
        TC.Init(@src()).Inst("\xbd\x01\x00",     "mov bp, 1") .Reg(.bp, 0x0001),
        TC.Init(@src()).Inst("\x83\xc5\x02\x00", "add bp, 2") .Reg(.bp, 0x0003),
        // setup and test
        TC.Init(@src()).Inst("\xb9\x01\x00",     "mov cx, 1")  .Reg(.cx, 0x0001),
        TC.Init(@src()).Inst("\x83\xc1\x08\x00", "add cx, 8")  .Reg(.cx, 0x0009),
        TC.Init(@src()).Inst("\x83\xc1\xfe\x00", "add cx, -2") .Reg(.cx, 0x0107),
        // half registers add
        TC.Init(@src()).Inst("\xb0\x01", "mov al, 1")  .Reg(.al, 0x01),
        TC.Init(@src()).Inst("\xb3\x01", "mov bl, 1")  .Reg(.bl, 0x01),
        TC.Init(@src()).Inst("\x00\xd8", "add al, bl") .Reg(.al, 0x02),
        // memory to register add
        TC.Init(@src()).Inst("\xb8\x34\x12", "mov ax, 4660")      .Reg(.ax, 0x1234),
        TC.Init(@src()).Inst("\xa3\x00\xf0", "mov [61440], ax")   .Mem(61440, "\x12\x34"),
        TC.Init(@src()).Inst("\xbb\x01\x00", "mov bx, 1")         .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\xbe\xff\xef", "mov si, 61439")     .Reg(.si, 0xefff),
        TC.Init(@src()).Inst("\x03\x18",     "add bx, [bx + si]") .Reg(.bx, 0x1235),
        // setup and test
        TC.Init(@src()).Inst("\xbd\x00\xf0",             "mov bp, 61440")       .Reg(.bp, 0xf000),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x01\x00", "mov [61440], word 1") .Mem(61440, "\x00\x01"),
        TC.Init(@src()).Inst("\xbb\x00\x00",             "mov bx, 0")           .Reg(.bx, 0x0000),
        TC.Init(@src()).Inst("\x03\x5e\x00",             "add bx, [bp]")        .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\x03\x5e\x00",             "add bx, [bp]")        .Reg(.bx, 0x0002),
        // memory with offset to register add
        TC.Init(@src()).Inst("\xbb\xfe\xef",             "mov bx, 61438")       .Reg(.bx, 0xeffe),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x01\x00", "mov [61440], word 1") .Mem(61440, "\x00\x01"),
        TC.Init(@src()).Inst("\xb9\x01\x00",             "mov cx, 1")           .Reg(.cx, 0x0001),
        TC.Init(@src()).Inst("\x03\x4f\x02",             "add cx, [bx + 2]")    .Reg(.cx, 0x0002),
        // memory with effective address calculation and offset to register add
        TC.Init(@src()).Inst("\xbd\xf6\xef",         "mov bp, 61430")         .Reg(.bp, 0xeff6),
        TC.Init(@src()).Inst("\xbe\x06\x00",         "mov si, 6")             .Reg(.si, 0x0006),
        TC.Init(@src()).Inst("\xc6\x06\x00\xf0\x01", "mov [61440], byte 1")   .Mem(61440, "\x01"),
        TC.Init(@src()).Inst("\xb7\x01",             "mov bh, 1")             .Reg(.bh, 0x01),
        TC.Init(@src()).Inst("\x02\x7a\x04",         "add bh, [bp + si + 4]") .Reg(.bh, 0x02),
        // setup and test
        TC.Init(@src()).Inst("\xbd\xf6\xef",             "mov bp, 61430")         .Reg(.bp, 0xeff6),
        TC.Init(@src()).Inst("\xbf\x04\x00",             "mov di, 4")             .Reg(.di, 0x04),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x01\x00", "mov [61440], word 1")   .Mem(61440, "\x00\x01"),
        TC.Init(@src()).Inst("\x03\x7b\x06",             "add di, [bp + di + 6]") .Reg(.di, 0x0005),
        // register to memory address add
        TC.Init(@src()).Inst("\xbb\xf6\xef",             "mov bx, 61430")       .Reg(.bx, 0xeff6),
        TC.Init(@src()).Inst("\xbe\x0a\x00",             "mov si, 10")          .Reg(.si, 0x000a),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x00\x00", "mov [61440], word 0") .Mem(61440, "\x00\x00"),
        TC.Init(@src()).Inst("\x01\x18",                 "add [bx + si], bx")   .Reg(.si, 0x000a),
        TC.Init(@src()).Inst("\xb8\x00\x00",             "mov ax, 0")           .Reg(.ax, 0x0000),
        TC.Init(@src()).Inst("\x03\x00",                 "add ax, [bx + si]")   .Reg(.ax, 0xeff6),
        // setup and test
        TC.Init(@src()).Inst("\xbb\x01\x00",         "mov bx, 1")        .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\xbd\xf6\xef",         "mov bp, 61430")    .Reg(.bp, 0xeff6),
        TC.Init(@src()).Inst("\xc7\x46\x00\x00\x00", "mov [bp], word 0") .Mem(61430, "\x00\x00"),
        TC.Init(@src()).Inst("\x01\x5e\x00",         "add [bp], bx")     .Mem(61430, "\x00\x01"),
        TC.Init(@src()).Inst("\x01\x5e\x00",         "add [bp], bx")     .Mem(61430, "\x00\x02"),
        TC.Init(@src()).Inst("\x01\x5e\x00",         "add [bp], bx")     .Mem(61430, "\x00\x03"),
        // setup and test
        TC.Init(@src()).Inst("\xbb\xfe\xef",             "mov bx, 61438")       .Reg(.bx, 0xeffe),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x07\x00", "mov [61440], word 7") .Mem(61440, "\x00\x07"),
        TC.Init(@src()).Inst("\xb9\x01\x00",             "mov cx, 1")           .Reg(.cx, 0x0001),
        TC.Init(@src()).Inst("\x01\x4f\x02",             "add [bx + 2], cx")    .Mem(61440, "\x00\x08"),
        // setup and test
        TC.Init(@src()).Inst("\xbd\xd8\xef",         "mov bp, 61400")         .Reg(.bp, 0xefd8),
        TC.Init(@src()).Inst("\xbe\x24\x00",         "mov si, 36")            .Reg(.si, 0x0024),
        TC.Init(@src()).Inst("\xc6\x06\x00\xf0\x08", "mov [61440], byte 8")   .Mem(61440, "\x08"),
        TC.Init(@src()).Inst("\xb7\x02",             "mov bh, 2")             .Reg(.bh, 0x02),
        TC.Init(@src()).Inst("\x00\x7a\x04",         "add [bp + si + 4], bh") .Mem(61440, "\x0a"),
        // setup and test
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x05\x00", "mov [61440], word 5")   .Mem(61440, "\x00\x05"),
        TC.Init(@src()).Inst("\xbd\xd8\xef",             "mov bp, 61400")         .Reg(.bp, 0xefd8),
        TC.Init(@src()).Inst("\xbf\x22\x00",             "mov di, 34")            .Reg(.di, 0x0022),
        TC.Init(@src()).Inst("\x01\x7b\x06",             "add [bp + di + 6], di") .Mem(61440, "\x00\x27"),
        // setup and test
        TC.Init(@src()).Inst("\xbb\x00\xf0",         "mov bx, 61440")       .Reg(.bx, 0xf000),
        TC.Init(@src()).Inst("\xc6\x06\x00\xf0\x06", "mov [61440], byte 6") .Mem(61440, "\x06"),
        TC.Init(@src()).Inst("\x80\x07\x22",         "add [bx], byte 34")   .Mem(61440, "\x28"),
        // setup and test
        TC.Init(@src()).Inst("\xbd\xf0\xeb",             "mov bp, 60400")                 .Reg(.bp, 0xebf0),
        TC.Init(@src()).Inst("\xbe\x28\x00",             "mov si, 40")                    .Reg(.si, 0x0028),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x06\x00", "mov [61440], word 6")           .Mem(61440, "\x00\x06"),
        TC.Init(@src()).Inst("\x83\x82\xe8\x03\x1d\x00", "add [bp + si + 1000], word 29") .Mem(61440, "\x00\x23"),
        // setup and test
        TC.Init(@src()).Inst("\xb8\x11\x00",             "mov ax, 17")          .Reg(.ax, 0x0011),
        TC.Init(@src()).Inst("\xbd\x00\xf0",             "mov bp, 61440")       .Reg(.bp, 0xf000),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x01\x00", "mov [61440], word 1") .Mem(61440, "\x00\x01"),
        TC.Init(@src()).Inst("\x03\x46\x00",             "add ax, [bp]")        .Reg(.ax, 0x0012),
        // sub tests
        // simple registers sub
        // setup and test
        TC.Init(@src()).Inst("\xb8\x01\x00", "mov ax, 1")  .Reg(.ax, 0x0001),
        TC.Init(@src()).Inst("\xbb\x01\x00", "mov bx, 1")  .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\x29\xd8",     "sub ax, bx") .Reg(.ax, 0x0000),
        // setup and test
        TC.Init(@src()).Inst("\xb8\x00\xf0", "mov ax, 61440") .Reg(.ax, 0xf000),
        TC.Init(@src()).Inst("\xbb\x00\x0f", "mov bx, 3840")  .Reg(.bx, 0x0f00),
        TC.Init(@src()).Inst("\x29\xd8",     "sub ax, bx")    .Reg(.ax, 0xe100),
        // setup and test
        TC.Init(@src()).Inst("\xbe\x04\x00",     "mov si, 4") .Reg(.si, 0x0004),
        TC.Init(@src()).Inst("\x83\xee\x01\x00", "sub si, 1") .Reg(.si, 0x0003),
        TC.Init(@src()).Inst("\x83\xee\x02\x00", "sub si, 2") .Reg(.si, 0x0001),
        // setup and test
        TC.Init(@src()).Inst("\xb9\xff\xff",     "mov cx, 65535") .Reg(.cx, 0xffff),
        TC.Init(@src()).Inst("\x83\xe9\x01\x00", "sub cx, 1")     .Reg(.cx, 0xfffe),
        TC.Init(@src()).Inst("\x83\xe9\xfe\x00", "sub cx, -2")    .Reg(.cx, 0xff00),
        // half registers sub
        TC.Init(@src()).Inst("\xb0\x01", "mov al, 1")  .Reg(.al, 0x01),
        TC.Init(@src()).Inst("\xb3\x01", "mov bl, 1")  .Reg(.bl, 0x01),
        TC.Init(@src()).Inst("\x28\xd8", "sub al, bl") .Reg(.al, 0x00),
        // memory to register sub
        TC.Init(@src()).Inst("\xbb\x01\x00",             "mov bx, 1")           .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x01\x00", "mov [61440], word 1") .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\xbe\xff\xef",             "mov si, 61439")       .Reg(.si, 0xefff),
        TC.Init(@src()).Inst("\x2b\x18",                 "sub bx, [bx + si]")   .Reg(.bx, 0x0000),
        // setup and test
        TC.Init(@src()).Inst("\xbd\x00\xf0",             "mov bp, 61440")       .Reg(.bp, 0xf000),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x01\x00", "mov [61440], word 1") .Reg(.bp, 0xf000),
        TC.Init(@src()).Inst("\xa1\x00\xf0",             "mov ax, [61440]")     .Reg(.ax, 0x0001),
        TC.Init(@src()).Inst("\xbb\x03\x00",             "mov bx, 3")           .Reg(.bx, 0x0003),
        TC.Init(@src()).Inst("\x2b\x5e\x00",             "sub bx, [bp]")        .Reg(.bx, 0x0002),
        TC.Init(@src()).Inst("\x2b\x5e\x00",             "sub bx, [bp]")        .Reg(.bx, 0x0001),
        // memory with offset to register sub
        TC.Init(@src()).Inst("\xbb\xfe\xef",             "mov bx, 61438")       .Reg(.bx, 0xeffe),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x01\x00", "mov [61440], word 1") .Reg(.bp, 0xf000),
        TC.Init(@src()).Inst("\xb9\x01\x00",             "mov cx, 1")           .Reg(.cx, 0x0001),
        TC.Init(@src()).Inst("\x2b\x4f\x02",             "sub cx, [bx + 2]")    .Reg(.cx, 0x0000),
        // memory with effective address calculation and offset to register sub
        TC.Init(@src()).Inst("\xbd\xf6\xef",         "mov bp, 61430")         .Reg(.bp, 0xeff6),
        TC.Init(@src()).Inst("\xbe\x06\x00",         "mov si, 6")             .Reg(.si, 0x0006),
        TC.Init(@src()).Inst("\xc6\x06\x00\xf0\x01", "mov [61440], byte 1")   .Reg(.bp, 0xeff6),
        TC.Init(@src()).Inst("\xb7\x01",             "mov bh, 1")             .Reg(.bh, 0x01),
        TC.Init(@src()).Inst("\x2a\x7a\x04",         "sub bh, [bp + si + 4]") .Reg(.bh, 0x00),
        // setup and test
        TC.Init(@src()).Inst("\xbd\xf6\xef",             "mov bp, 61430")         .Reg(.bp, 0xeff6),
        TC.Init(@src()).Inst("\xbf\x04\x00",             "mov di, 4")             .Reg(.di, 0x04),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x01\x00", "mov [61440], word 1")   .Reg(.bp, 0xeff6),
        TC.Init(@src()).Inst("\x2b\x7b\x06",             "sub di, [bp + di + 6]") .Reg(.di, 0x0003),
        // register to memory address sub
        TC.Init(@src()).Inst("\xbb\xf6\xef",             "mov bx, 61430")           .Reg(.bx, 0xeff6),
        TC.Init(@src()).Inst("\xbe\x0a\x00",             "mov si, 10")              .Reg(.si, 0x000a),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\xf7\xef", "mov [61440], word 61431") .Reg(.si, 0x000a),
        TC.Init(@src()).Inst("\x29\x18",                 "sub [bx + si], bx")       .Reg(.si, 0x000a),
        TC.Init(@src()).Inst("\xa1\x00\xf0",             "mov ax, [61440]")         .Reg(.ax, 0x0001),
        TC.Init(@src()).Inst("\xb8\x02\x00",             "mov ax, 2")               .Reg(.ax, 0x0002),
        TC.Init(@src()).Inst("\x2b\x00",                 "sub ax, [bx + si]")       .Reg(.ax, 0x0001),
        // setup and test
        TC.Init(@src()).Inst("\xbd\x00\xf0",         "mov bp, 61440")    .Reg(.bp, 0xf000),
        TC.Init(@src()).Inst("\xbb\x01\x00",         "mov bx, 1")        .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\xc7\x46\x00\x05\x00", "mov [bp], word 5") .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\x29\x5e\x00",         "sub [bp], bx")     .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\x29\x5e\x00",         "sub [bp], bx")     .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\x29\x5e\x00",         "sub [bp], bx")     .Reg(.bx, 0x0001),
        TC.Init(@src()).Inst("\x8b\x5e\x00",         "mov bx, [bp]")     .Reg(.bx, 0x0002),
        // setup and test
        TC.Init(@src()).Inst("\xbb\xfe\xef",             "mov bx, 61438")       .Reg(.bx, 0xeffe),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x07\x00", "mov [61440], word 7") .Reg(.bx, 0xeffe),
        TC.Init(@src()).Inst("\xb9\x01\x00",             "mov cx, 1")           .Reg(.cx, 0x0001),
        TC.Init(@src()).Inst("\x29\x4f\x02",             "sub [bx + 2], cx")    .Reg(.cx, 0x0001),
        TC.Init(@src()).Inst("\x8b\x4f\x02",             "mov cx, [bx + 2]")    .Reg(.cx, 0x0006),
        // setup and test
        TC.Init(@src()).Inst("\xbd\xd8\xef",         "mov bp, 61400")         .Reg(.bp, 0xefd8),
        TC.Init(@src()).Inst("\xbe\x24\x00",         "mov si, 36")            .Reg(.si, 0x0024),
        TC.Init(@src()).Inst("\xc6\x06\x00\xf0\x08", "mov [61440], byte 8")   .Reg(.si, 0x0024),
        TC.Init(@src()).Inst("\xb7\x02",             "mov bh, 2")             .Reg(.bh, 0x02),
        TC.Init(@src()).Inst("\x28\x7a\x04",         "sub [bp + si + 4], bh") .Reg(.bh, 0x02),
        TC.Init(@src()).Inst("\xb0\x00",             "mov al, 0")             .Reg(.al, 0x00),
        TC.Init(@src()).Inst("\xa0\x00\xf0",         "mov al, [61440]")       .Reg(.al, 0x06),
        // setup and test
        TC.Init(@src()).Inst("\xb8\x00\x00",             "mov ax, 0")              .Reg(.ax, 0x0000),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x05\x00", "mov [61440], word 5")    .Reg(.ax, 0x0000),
        TC.Init(@src()).Inst("\xbd\xd8\xef",             "mov bp, 61400")          .Reg(.bp, 0xefd8),
        TC.Init(@src()).Inst("\xbf\x02\x00",             "mov di, 2")              .Reg(.di, 0x0002),
        TC.Init(@src()).Inst("\x29\x7b\x26",             "sub [bp + di + 38], di") .Reg(.di, 0x0002),
        TC.Init(@src()).Inst("\xa1\x00\xf0",             "mov ax, [61440]")        .Reg(.ax, 0x0003),
        // setup and test
        TC.Init(@src()).Inst("\xbb\x00\xf0",         "mov bx, 61440")        .Reg(.bx, 0xf000),
        TC.Init(@src()).Inst("\xc6\x06\x00\xf0\x28", "mov [61440], byte 40") .Reg(.bx, 0xf000),
        TC.Init(@src()).Inst("\x80\x2f\x22",         "sub [bx], byte 34")    .Reg(.bx, 0xf000),
        TC.Init(@src()).Inst("\xa0\x00\xf0",         "mov al, [61440]")      .Reg(.al, 0x06),
        // setup and test
        TC.Init(@src()).Inst("\xbd\xf0\xeb",             "mov bp, 60400")                 .Reg(.bp, 0xebf0),
        TC.Init(@src()).Inst("\xbe\x28\x00",             "mov si, 40")                    .Reg(.si, 0x0028),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x1e\x00", "mov [61440], word 30")          .Reg(.si, 0x0028),
        TC.Init(@src()).Inst("\x83\xaa\xe8\x03\x1d\x00", "sub [bp + si + 1000], word 29") .Reg(.si, 0x0028),
        TC.Init(@src()).Inst("\xa1\x00\xf0",             "mov ax, [61440]")               .Reg(.ax, 0x0001),
        // setup and test
        TC.Init(@src()).Inst("\xb8\x11\x00",             "mov ax, 17")          .Reg(.ax, 0x0011),
        TC.Init(@src()).Inst("\xbd\x00\xf0",             "mov bp, 61440")       .Reg(.bp, 0xf000),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\x01\x00", "mov [61440], word 1") .Reg(.bp, 0xf000),
        TC.Init(@src()).Inst("\x2b\x46\x00",             "sub ax, [bp]")        .Reg(.ax, 0x0010),
        // cmp tests
        // setup and test
        TC.Init(@src()).Inst("\xb0\x09", "mov al, 9")  .Reg(.al, 0x09),
        TC.Init(@src()).Inst("\xb4\x09", "mov ah, 9")  .Reg(.ah, 0x09),
        TC.Init(@src()).Inst("\x38\xe0", "cmp al, ah") .Flags(true, false),
        // setup and test
        TC.Init(@src()).Inst("\x3c\x0a", "cmp al, 10")  .Flags(false, true),
        TC.Init(@src()).Inst("\x3c\xe2", "cmp al, -30") .Flags(false, true),
        // setup and test
        TC.Init(@src()).Inst("\xb8\x7b\x00", "mov ax, 123") .Reg(.ax, 0x007b),
        TC.Init(@src()).Inst("\xbb\x7c\x00", "mov bx, 124") .Reg(.bx, 0x007c),
        TC.Init(@src()).Inst("\x39\xd8",     "cmp ax, bx")  .Flags(false, true),
        TC.Init(@src()).Inst("\xb8\x7b\x00", "mov ax, 123") .Reg(.ax, 0x007b),
        TC.Init(@src()).Inst("\xbb\x7a\x00", "mov bx, 122") .Reg(.bx, 0x007a),
        TC.Init(@src()).Inst("\x39\xd8",     "cmp ax, bx")  .Flags(false, false),
        TC.Init(@src()).Inst("\xb8\x7b\x00", "mov ax, 123") .Reg(.ax, 0x007b),
        TC.Init(@src()).Inst("\xbb\x7b\x00", "mov bx, 123") .Reg(.bx, 0x007b),
        TC.Init(@src()).Inst("\x39\xd8",     "cmp ax, bx")  .Flags(true, false),
        // setup and test
        TC.Init(@src()).Inst("\xbe\x0c\x00",     "mov si, 12") .Reg(.si, 0x000c),
        TC.Init(@src()).Inst("\x83\xfe\x0c\x00", "cmp si, 12") .Flags(true, false),
        TC.Init(@src()).Inst("\x83\xfe\x0d\x00", "cmp si, 13") .Flags(false, true),
        TC.Init(@src()).Inst("\x83\xfe\x0b\x00", "cmp si, 11") .Flags(false, false),
        // setup and test
        TC.Init(@src()).Inst("\xbb\xd8\xef",             "mov bx, 61400")           .Reg(.bx, 0xefd8),
        TC.Init(@src()).Inst("\xbe\x28\x00",             "mov si, 40")              .Reg(.si, 0x0028),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\xd8\xef", "mov [61440], word 61400") .Mem(61440, "\xef\xd8"),
        TC.Init(@src()).Inst("\x3b\x18",                 "cmp bx, [bx + si]")       .Flags(true, false),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\xd9\xef", "mov [61440], word 61401") .Mem(61440, "\xef\xd9"),
        TC.Init(@src()).Inst("\x3b\x18",                 "cmp bx, [bx + si]")       .Flags(false, true),
        TC.Init(@src()).Inst("\xc7\x06\x00\xf0\xd7\xef", "mov [61440], word 61399") .Mem(61440, "\xef\xd7"),
        TC.Init(@src()).Inst("\x3b\x18",                 "cmp bx, [bx + si]")       .Flags(false, false),
    };
    var output_buffer: [1024*1024]u8 = undefined;
    var fbs = io.fixedBufferStream(&output_buffer);
    const logger = fbs.writer();

    for (test_cases, 0..) |tc, index| {
        // reset the buffer at the end of the loop
        defer fbs.reset();
        // print details on failure
        errdefer debug.print("failed on test case {d} (line {d}): {s}\n", .{index+1, tc.src.line,
            (if (tc.inst) |inst| inst.txt else "no instruction") });
        // NOTE: change to just defer to have complete run output for debugging
        errdefer debug.print("{s}\n", .{output_buffer[0..fbs.pos]});
        // execute instructions if any
        if (tc.inst) |inst| {
            // setup - we do not reset or override memory - only append to it
            std.mem.copyForwards(u8, simulator.memory[simulator.ip..], inst.mem);
            simulator.memory[simulator.ip + inst.mem.len] = 0xf4; // hlt at the end
            // execute
            try simulator.run(logger);
        }
        // validation
        if (tc.mem)   |mem|   { try testing.expectEqualSlices(u8, mem.val, simulator.memory[mem.addr..(mem.addr+mem.val.len)]); }
        if (tc.reg)   |reg|   { try testing.expectEqual(reg.val, simulator.getRegister(reg.reg)); }
        if (tc.flags) |flags| { errdefer debug.print("expected zf = {s} got {s}, expected sf = {s} got {s}\n",
                                    .{ if (flags.zf) "1" else "0", if (simulator.getFlag(.zf)) "1" else "0",
                                       if (flags.sf) "1" else "0", if (simulator.getFlag(.sf)) "1" else "0", });
                                try testing.expectEqual(flags.zf, simulator.getFlag(.zf));
                                try testing.expectEqual(flags.sf, simulator.getFlag(.sf)); }
    }
}
