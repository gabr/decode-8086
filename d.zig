/// 8086 CPU decoder
/// compile with: zig-linux-x86_64-0.11.0-dev.2368+f4b411314
const std     = @import("std");
const mem     = std.mem;
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
