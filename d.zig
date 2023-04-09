/// 8086 CPU decoder
/// compile with: zig-linux-x86_64-0.11.0
const std     = @import("std");
const mem     = std.mem;
const fmt     = std.fmt;
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
    var args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    debug.print("args: {d}:\n  {s}\n", .{args.len, try mem.join(allocator, "\n  ", args)});

    const defs = CPU8086.getDefinitions();
    for (defs) |d| {
        debug.print(
            "type: {}\n" ++
            "fields({d}): [\n",
            .{ d.type, d.fields.len });

        for (d.fields) |f| {
            debug.print("{{ {}, {b}, {d} }}\n", .{f.type, f.value, f.bits_count});
        }

        debug.print("]\n", .{});
    }
}

const CPU8086 = struct {
    pub const InstructionType = enum(u8) {
        MOV,
    };

    pub const FieldType = enum {
        constant, d, w, mod, reg, rm,

        pub fn getFieldSize(self: FieldType) u8 {
            return switch(self) {
                .constant => 0,
                .d        => 1,
                .w        => 1,
                .mod      => 2,
                .reg      => 3,
                .rm       => 3,
            };
        }
    };

    const instruction_definitions_separators = " |";
    const instruction_definitions_strings = .{
        "MOV 100010 d w | mod reg rm",
        "MOV 1000101  w | mod 000 rm",
    };

    const Field = struct {
        type:       FieldType,
        value:      u8,
        bits_count: u8,
    };

    const InstructionDefinition = result: {
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
            if (fields > max_fields) {
                max_fields = fields;
            }
        }

        // now we know how git the fields should be
        break :result struct {
            type:   InstructionType,
            fields: [max_fields]Field,
        };
    };

    pub fn getDefinitions() []const InstructionDefinition {
        return &instruction_definitions;
    }

    const instruction_definitions = result: {
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
                            .bits_count = type_enum.getFieldSize(),
                        };
                    };

                // TODO(agabrys): YOU HAVE TO FLIP THE FIELDS ORDER, or do parsing in some special way?
                parsed_definition.fields[field_index] = field;
            }

            parsed_definitions[i] = parsed_definition;
        }

        break :result parsed_definitions;
    };

};
