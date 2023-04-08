/// 8086 CPU decoder
/// compile with: zig-linux-x86_64-0.11.0
const std     = @import("std");
const mem     = std.mem;
const fmt     = std.fmt;
const meta    = std.meat;
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

    debug.print("args: {d}:\n  {s}", .{args.len, try mem.join(allocator, "\n  ", args)});
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

    const instruction_definitions = .{
        "MOV 100010 d w | mod reg rm",
        "MOV 1000101  w | mod 000 rm",
    };

    const Field = struct {
        type:       FieldType,
        value:      u8,
        bits_count: u8,
    };

    const FieldIterator = struct {
        buffer: []const u8,
        index: usize,

        const Self = @This();

        /// Returns next field in the instruction definition buffer or null if
        /// tokenization is  complete, and advances to the next token.
        pub fn next(self: *Self) ?Field {
            const result = self.peek() orelse return null;
            self.index += result.len;
            return result;
        }

        /// Returns a field of the nstruction definition buffer, or null if
        /// tokenization is complete. Does not advance to the next token.
        pub fn peek(self: *Self) ?Field {
            // move to beginning of token
            while (self.index < self.buffer.len and isSplitByte(self.buffer[self.index])) : (self.index += 1) {}

            const start = self.index;
            if (start == self.buffer.len) {
                return null;
            }

            // move to end of token
            var end = start;
            while (end < self.buffer.len and !isSplitByte(self.buffer[end])) : (end += 1) {}

            // we have a field string, now parse it
            const field_string = self.buffer[start..end];

            // if field starts with 1 or 0 its a constant and we need to do some extra parsing
            if (field_string[0] == '1' or field_string[0] == '0') {
                return .{
                    .type       = .Constant,
                    .value      = fmt.parseInt(u8, field_string, 2) catch unreachable,
                    .bits_count = field_string.len,
                };
            }
            // otherwise it's just a named field so convert it to enum
            else {
                const type_enum = meta.stringToEnum(FieldType, field_string)
                    orelse @compileError(field_string ++ " is not a valid FieldType enum");

                return .{
                    .type       = type_enum,
                    .value      = 0,
                    .bits_count = type_enum.getFieldSize(),
                };
            }
        }

        /// Resets the iterator to the initial token.
        pub fn reset(self: *Self) void {
            self.index = 0;
        }

        fn isSplitByte(byte: u8) bool {
            return switch (byte) {
                ' '  => true,
                '|'  => true,
                else => false,
            };
        }
    };
};
