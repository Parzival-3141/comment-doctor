//! Parse any Zig file and convert comments to doc-comments where possible.

const std = @import("std");
const Ast = std.zig.Ast;

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
    var ast = try Ast.parse(gpa, src, .zig);
    defer ast.deinit(gpa);

    try search_for_decls(gpa, ast);
    // recurse_for_decls(ast);

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
    for (comments.items) |comment| {
        std.debug.print(
            "Comment {{\nline_num: {d}\nmultiline: {}\nvalue: {s}\n}}\n\n",
            .{
                1 + std.mem.count(u8, src[0..comment.start], "\n"),
                comment.is_multiline,
                src[comment.start..comment.end],
            },
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

fn search_for_decls(ally: std.mem.Allocator, ast: Ast) !void {
    var nodes = try std.ArrayList(Ast.Node.Index).initCapacity(ally, ast.nodes.len + ast.extra_data.len);
    defer nodes.deinit();

    for (0..ast.nodes.len) |i| nodes.appendAssumeCapacity(@intCast(i));
    for (ast.extra_data) |node| nodes.appendAssumeCapacity(node);

    var buf = [_]Ast.Node.Index{ 0, 0 };
    for (nodes.items) |node| {
        const tag = ast.nodes.items(.tag)[node];

        if (ast.fullContainerDecl(&buf, node)) |_| {} else if (ast.fullContainerField(node)) |_| {} else if (ast.fullVarDecl(node)) |_| {} else continue;

        const token = ast.nodes.items(.main_token)[node];
        const token_start = ast.tokens.items(.start)[token];
        const token_loc = ast.tokenLocation(0, token);
        const token_slice = ast.tokenSlice(token);

        std.debug.print(
            "node: {d: ^4} \x1b[35m{s: <25}\x1b[39mtoken: {d: >3}:{d: <3} '{s}\x1b[32m{s}\x1b[39m{s}'\n",
            .{
                node,
                @tagName(tag),
                token_loc.line + 1,
                token_loc.column + 1,
                ast.source[token_loc.line_start..token_start],
                token_slice,
                ast.source[token_start + token_slice.len .. token_loc.line_end],
            },
        );
    }
}
fn recurse_for_decls(ast: Ast) void {
    const decls = ast.rootDecls();
    for (decls) |idx| {
        recurse_for_decls_inner(ast, idx, 0);
    }
}

fn indent(d: u8) []const u8 {
    return switch (d) {
        inline else => |n| " " ** n,
    };
}

fn recurse_for_decls_inner(ast: Ast, node: Ast.Node.Index, depth: u8) void {
    if (node == 0 or node >= ast.nodes.len) return;

    const token = ast.nodes.items(.main_token)[node];
    const token_start = ast.tokens.items(.start)[token];
    const token_loc = ast.tokenLocation(0, token);
    const token_slice = ast.tokenSlice(token);

    std.debug.print(
        "node: {s}\x1b[35m{s}\x1b[39m{s}token: {d: >3}:{d: <3} '{s}\x1b[32m{s}\x1b[39m{s}'\n",
        .{
            indent(depth * 2),
            @tagName(ast.nodes.items(.tag)[node]),
            indent(35 - depth * 2 - @as(u8, @truncate(@tagName(ast.nodes.items(.tag)[node]).len))),
            token_loc.line + 1,
            token_loc.column + 1,
            ast.source[token_loc.line_start..token_start],
            token_slice,
            ast.source[token_start + token_slice.len .. token_loc.line_end],
        },
    );

    const S = struct {
        //! saf
        //!
        //!
        //!
        //!

        bang: bool,
    };
    _ = S;

    var buf = [_]Ast.Node.Index{ 0, 0 };
    if (ast.fullContainerDecl(&buf, node)) |container_decl| {
        for (container_decl.ast.members) |member| {
            recurse_for_decls_inner(ast, member, depth + 1);
        }
        recurse_for_decls_inner(ast, container_decl.ast.arg, depth + 1);
    } else if (ast.fullContainerField(node)) |field| {
        recurse_for_decls_inner(ast, field.ast.type_expr, depth + 1);
        recurse_for_decls_inner(ast, field.ast.value_expr, depth + 1);
    } else if (ast.fullVarDecl(node)) |var_decl| {
        recurse_for_decls_inner(ast, var_decl.ast.init_node, depth + 1);
        recurse_for_decls_inner(ast, var_decl.ast.type_node, depth + 1);
    }
}
