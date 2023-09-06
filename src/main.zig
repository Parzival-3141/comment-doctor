//! Parse any Zig file and convert comments to doc-comments where possible.

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // skip executable name

    // TODO: assuming each arg is a file path for now. Figure out UX later.
    while (args.next()) |arg| {
        if (!std.mem.endsWith(u8, arg, ".zig")) {
            std.log.warn("Skipping non-zig file: {s}", .{arg});
            continue;
        }

        _ = search_file(allocator, std.fs.cwd(), arg) catch |err| {
            std.log.err("{s} Skipping file: {s}", .{ @errorName(err), arg });
            continue;
        };
    }
}

const Comment = struct {
    start: usize,
    end: usize,
    is_multiline: bool,
};

fn search_file(gpa: std.mem.Allocator, dir: std.fs.Dir, sub_path: []const u8) !u32 {
    const src = try dir.readFileAllocOptions(
        gpa,
        sub_path,
        std.math.maxInt(u32),
        null,
        @alignOf(u8),
        0,
    );
    defer gpa.free(src);

    // TODO: figure out how to determine if a comment directly proceeds a declaration
    // var ast = try std.zig.Ast.parse(gpa, src, .zig);
    // defer ast.deinit(gpa);

    // Run through source file
    // When it hits a comment, parse it into the Comment struct and push that onto a stack.
    // (maybe only push ones that can be doc-comments? Or resolve those later?)
    // After the whole file has been copied, iterate the stack, popping a Comment and converting to doc-comment.
    // By iterating in reverse we avoid invalidating file offsets after making changes.

    var comments = std.ArrayList(Comment).init(gpa);
    defer comments.deinit();

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, src, cursor, "//")) |index| {
        if (!is_line_comment_start(src, index)) {
            cursor = index + 2;
            continue;
        }

        var comment = Comment{
            .start = index,
            .end = undefined,
            .is_multiline = false,
        };

        // If there is no newline, the comment ends with EOF
        const newline = if (std.mem.indexOfScalar(
            u8,
            src[comment.start..],
            '\n',
        )) |i| comment.start + i else null;

        comment.end = if (newline) |n| blk: {
            // Look for more comments
            // As long as we find whitespace (excluding newlines) before the next "//",
            // it's a multi-line comment. Skip to the next newline and repeat until this isn't true

            var end: usize = n;
            while (find_multiline_comment_end(src, end)) |new_end| {
                end = new_end;
            }
            if (end != n) comment.is_multiline = true;

            break :blk end;
        } else src.len;

        try comments.append(comment);
        cursor = comment.end;
    }

    // TODO: actually copy data to the atomic file.
    // Not sure if it's better than editing in place, but we'll see I guess.
    // var dest_atomic = try dir.atomicFile(
    //     sub_path,
    //     // .{ .mode = .read_write, .lock = .exclusive },
    //     .{},
    // );
    // defer dest_atomic.deinit();

    // try dest_atomic.file.writeAll(src);

    // change eligible comments into doc-comments
    while (comments.popOrNull()) |comment| {
        std.debug.print(
            "Comment {{\nmultiline: {}\nvalue: {s}\n}}\n\n",
            .{ comment.is_multiline, src[comment.start..comment.end] },
        );

        // TODO: check if this comment can be made into a doc comment
    }

    // try dest_atomic.finish();
    return 0;
}

/// Returns the index of the trailing `\n` of the next line-comment or EOF, or else `null`.
/// Assume's start to be the trailing `\n` of the current line-comment.
fn find_multiline_comment_end(src: []const u8, start: usize) ?usize {
    // TODO: This doesn't seem like the cleanest way... Maybe try using std.mem again?

    // search up until we find a "//", '\n', or any other non-whitespace
    if (start >= src.len or start == src.len - 1) return null;
    var i = start + 1; // Assuming we're already at a newline, so start at the next char.

    var state: enum { in_between, in_comment, start_comment } = .in_between;
    while (i < src.len) : (i += 1) {
        switch (state) {
            .in_between => switch (src[i]) {
                ' ',
                '\t',
                '\r',
                std.ascii.control_code.vt,
                std.ascii.control_code.ff,
                => {},

                '/' => state = .start_comment,

                '\n' => return null,
                else => return null,
            },
            .start_comment => {
                if (src[i] != '/' or value_at_index(src, i + 1, '/'))
                    return null
                else
                    state = .in_comment;
            },
            .in_comment => if (src[i] == '\n') return i,
        }
    }

    return if (state == .in_comment) i else null;
}

fn value_at_index(src: []const u8, index: usize, value: u8) bool {
    if (index >= src.len) return false;
    return src[index] == value;
}

/// Assumes idx is at the first of two slashes "//".
/// Searches back for a newline or start of file, returning false if non-whitespace is found.
/// Also returns false if actually a doc-comment.
fn is_line_comment_start(src: []const u8, idx: usize) bool {
    // ignore doc-comments
    if (value_at_index(src, idx + 2, '/') or value_at_index(src, idx + 2, '!')) return false;
    if (idx == 0) return true;

    var j: usize = idx - 1;
    return while (j > 0) : (j -= 1) {
        if (!std.ascii.isWhitespace(src[j])) break false;
        if (src[j] == '\n') break true;
    } else true;
}
