const std = @import("std");
const stdx = @import("stdx");
const t = stdx.testing;
const fatal = stdx.fatal;

pub const NodeId = u32;
const NullId = std.math.maxInt(u32);
const log = stdx.log.scoped(.parser);
const IndexSlice = stdx.IndexSlice(u32);

const keywords = std.ComptimeStringMap(TokenType, .{
    .{ "return", .return_k },
    .{ "if", .if_k },
    .{ "else", .else_k },
    .{ "for", .for_k },
    .{ "fun", .func },
    .{ "break", .break_k },
    .{ "await", .await_k },
});

const BlockState = struct {
    indent_spaces: u32,
    vars: std.StringHashMapUnmanaged(void),

    fn deinit(self: *BlockState, alloc: std.mem.Allocator) void {
        self.vars.deinit(alloc);
    }
};

/// Parses source code into AST.
pub const Parser = struct {
    alloc: std.mem.Allocator,

    /// Context vars.
    src: std.ArrayListUnmanaged(u8),
    next_pos: u32,
    tokens: std.ArrayListUnmanaged(Token),
    nodes: std.ArrayListUnmanaged(Node),
    last_err: []const u8,
    block_stack: std.ArrayListUnmanaged(BlockState),
    cur_indent: u32,
    func_params: std.ArrayListUnmanaged(FunctionParam),
    func_decls: std.ArrayListUnmanaged(FunctionDeclaration),

    // TODO: This should be implemented by user callbacks.
    /// @name arg.
    name: []const u8,
    /// Variable dependencies.
    deps: std.StringHashMapUnmanaged(NodeId),

    pub fn init(alloc: std.mem.Allocator) Parser {
        return .{
            .alloc = alloc,
            .src = .{},
            .next_pos = undefined,
            .tokens = .{},
            .nodes = .{},
            .last_err = "",
            .block_stack = .{},
            .cur_indent = 0,
            .func_params = .{},
            .func_decls = .{},
            .name = "",
            .deps = .{},
        };
    }

    pub fn deinit(self: *Parser) void {
        self.tokens.deinit(self.alloc);
        self.nodes.deinit(self.alloc);
        self.src.deinit(self.alloc);
        self.alloc.free(self.last_err);
        self.block_stack.deinit(self.alloc);
        self.func_params.deinit(self.alloc);
        self.func_decls.deinit(self.alloc);
        self.deps.deinit(self.alloc);
    }

    pub fn parseNoErr(self: *Parser, src: []const u8) !ResultView {
        const res = try self.parse(src);
        if (res.has_error) {
            log.debug("{s}", .{res.err_msg});
            return error.ParseError;
        }
        return res;
    }

    pub fn parse(self: *Parser, src: []const u8) !ResultView {
        self.src.clearRetainingCapacity();
        try self.src.appendSlice(self.alloc, src);
        self.name = "";
        self.deps.clearRetainingCapacity();

        self.tokenize() catch |err| {
            log.debug("tokenize error: {}", .{err});
            return ResultView{
                .has_error = true,
                .err_msg = self.last_err,
                .root_id = NullId,
                .nodes = &self.nodes,
                .func_decls = &.{},
                .func_params = &.{},
                .tokens = &.{},
                .src = "",
                .name = self.name,
                .deps = &self.deps,
            };
        };
        const root_id = self.parseRoot() catch |err| {
            log.debug("parse error: {}", .{err});
            return ResultView{
                .has_error = true,
                .err_msg = self.last_err,
                .root_id = NullId,
                .nodes = &self.nodes,
                .func_decls = &.{},
                .func_params = &.{},
                .tokens = &.{},
                .src = "",
                .name = self.name,
                .deps = &self.deps,
            };
        };
        return ResultView{
            .has_error = false,
            .err_msg = "",
            .root_id = root_id,
            .nodes = &self.nodes,
            .tokens = self.tokens.items,
            .src = self.src.items,
            .func_decls = self.func_decls.items,
            .func_params = self.func_params.items,
            .name = self.name,
            .deps = &self.deps,
        };
    }

    fn parseRoot(self: *Parser) !NodeId {
        self.next_pos = 0;
        self.nodes.clearRetainingCapacity();
        self.block_stack.clearRetainingCapacity();
        self.func_decls.clearRetainingCapacity();
        self.func_params.clearRetainingCapacity();
        self.cur_indent = 0;

        const root_id = self.pushNode(.root, 0);
        const first_stmt = try self.parseBodyStatements(0);
        self.nodes.items[root_id].head = .{
            .child_head = first_stmt,
        };
        return 0;
    }

    /// Returns number of spaces that precedes a statement.
    /// If current line is consumed if there is no statement.
    fn consumeIndentBeforeStmt(self: *Parser) u32 {
        while (true) {
            var res: u32 = 0;
            var token = self.peekToken();
            while (token.token_t == .indent) {
                res += token.data.indent;
                self.advanceToken();
                token = self.peekToken();
            }
            if (token.token_t == .new_line) {
                self.advanceToken();
                continue;
            } else if (token.token_t == .none) {
                return res;
            } else {
                return res;
            }
        }
    }

    fn pushBlock(self: *Parser, indent: u32) !void {
        try self.block_stack.append(self.alloc, .{
            .indent_spaces = indent,
            .vars = .{},
        });
    }

    fn popBlock(self: *Parser) void {
        self.block_stack.items[self.block_stack.items.len-1].deinit(self.alloc);
        _ = self.block_stack.pop();
    }

    /// Like parseIndentedBodyStatements but the body indentation is already known.
    fn parseBodyStatements(self: *Parser, body_indent: u32) !NodeId {
        try self.pushBlock(body_indent);
        defer self.popBlock();

        var indent = self.consumeIndentBeforeStmt();
        if (indent != body_indent) {
            return self.reportTokenError(error.IndentError, "Unexpected indentation.", self.peekToken());
        }
        var first_stmt = (try self.parseStatement()) orelse return NullId;
        var last_stmt = first_stmt;

        while (true) {
            indent = self.consumeIndentBeforeStmt();
            if (indent == body_indent) {
                const id = (try self.parseStatement()) orelse break;
                self.nodes.items[last_stmt].next = id;
                last_stmt = id;
            } else {
                return self.reportTokenError(error.IndentError, "Unexpected indentation.", self.peekToken());
            }
        }
        return first_stmt;
    }

    /// Returns the first statement or NullId.
    fn parseIndentedBodyStatements(self: *Parser, start_indent: u32) !NodeId {
        // New block. Indent spaces is determines by the first body statement.
        try self.pushBlock(0);
        defer {
            self.popBlock();
            self.cur_indent = start_indent;
        }

        // Parse first statement and determine the body indentation.
        var body_indent: u32 = undefined;
        var start = self.next_pos;
        var indent = self.consumeIndentBeforeStmt();
        if (indent <= start_indent) {
            // End of body. Rewind and return.
            self.next_pos = start;
            return NullId;
        } else {
            body_indent = indent;
            self.cur_indent = body_indent;
        }
        var first_stmt = (try self.parseStatement()) orelse return NullId;
        var last_stmt = first_stmt;

        // Parse the rest of the body statements and enforce the body indentation.
        while (true) {
            start = self.next_pos;
            indent = self.consumeIndentBeforeStmt();
            if (indent == body_indent) {
                const id = (try self.parseStatement()) orelse break;
                self.nodes.items[last_stmt].next = id;
                last_stmt = id;
            } else if (indent <= start_indent) {
                self.next_pos = start;
                break;
            } else {
                return self.reportTokenError(error.IndentError, "Unexpected indent.", self.peekToken());
            }
        }
        return first_stmt;
    }

    fn parseLambdaFunction(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `func` keyword.
        self.advanceToken();

        var decl = FunctionDeclaration{
            .name = undefined,
            .params = undefined,
            .return_type = null,
        };

        decl.params = try self.parseFunctionParams();

        var token = self.peekToken();
        if (token.token_t != .equal_greater) {
            return self.reportTokenError(error.SyntaxError, "Expected =>.", token);
        }
        self.advanceToken();

        // Parse body expr.
        var dummy = false;
        const body_expr = (try self.parseExpression(false, &dummy)) orelse {
            return self.reportTokenError(error.SyntaxError, "Expected lambda body expression.", self.peekToken());
        };
        
        const decl_id = @intCast(u32, self.func_decls.items.len);
        try self.func_decls.append(self.alloc, decl);

        const id = self.pushNode(.lambda_single, start);
        self.nodes.items[id].head = .{
            .func = .{
                .decl_id = decl_id,
                .body_head = body_expr,
            },
        };
        return id;
    }

    fn parseFunctionParams(self: *Parser) !IndexSlice {
        var token = self.peekToken();
        if (token.token_t != .left_paren) {
            return self.reportTokenError(error.SyntaxError, "Expected open parenthesis.", token);
        }
        self.advanceToken();

        // Parse params.
        const param_start = @intCast(u32, self.func_params.items.len);
        outer: {
            token = self.peekToken();
            if (token.token_t == .ident) {
                self.advanceToken();
                const name = IndexSlice.init(token.start_pos, token.data.end_pos);
                try self.func_params.append(self.alloc, .{
                    .name = name,
                });
            } else if (token.token_t == .right_paren) {
                self.advanceToken();
                break :outer;
            } else return self.reportTokenError(error.SyntaxError, "Unexpected token in function param list.", token);
            while (true) {
                token = self.peekToken();
                switch (token.token_t) {
                    .comma => {
                        self.advanceToken();
                    },
                    .right_paren => {
                        self.advanceToken();
                        break;
                    },
                    else => return self.reportTokenError(error.SyntaxError, "Unexpected token in function param list.", token),
                }

                token = self.peekToken();
                if (token.token_t != .ident) {
                    return self.reportTokenError(error.SyntaxError, "Expected param identifier.", token);
                }
                self.advanceToken();
                const name = IndexSlice.init(token.start_pos, token.data.end_pos);
                try self.func_params.append(self.alloc, .{
                    .name = name,
                });
            }
        }
        return IndexSlice.init(param_start, @intCast(u32, self.func_params.items.len));
    }

    fn parseFunctionDeclaration(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `func` keyword.
        self.advanceToken();

        var decl = FunctionDeclaration{
            .name = undefined,
            .params = undefined,
            .return_type = null,
        };

        // Parse function name.
        var token = self.peekToken();
        if (token.token_t == .ident) {
            decl.name = IndexSlice.init(token.start_pos, token.data.end_pos);
        } else return self.reportTokenError(error.SyntaxError, "Expected function name identifier.", token);
        self.advanceToken();

        decl.params = try self.parseFunctionParams();

        token = self.peekToken();
        if (token.token_t == .colon) {
            self.advanceToken();
        } else if (token.token_t == .ident) {
            decl.return_type = IndexSlice.init(token.start_pos, token.data.end_pos);
            self.advanceToken();
            token = self.peekToken();
            if (token.token_t != .colon) {
                return self.reportTokenError(error.SyntaxError, "Expected colon.", token);
            }
            self.advanceToken();
        } else {
            return self.reportTokenError(error.SyntaxError, "Expected colon or type.", token);
        }

        // Parse body.
        const first_stmt = try self.parseIndentedBodyStatements(self.cur_indent);
        
        const decl_id = @intCast(u32, self.func_decls.items.len);
        try self.func_decls.append(self.alloc, decl);

        const id = self.pushNode(.func_decl, start);
        self.nodes.items[id].head = .{
            .func = .{
                .decl_id = decl_id,
                .body_head = first_stmt,
            },
        };

        const name = self.src.items[decl.name.start..decl.name.end];
        const block = &self.block_stack.items[self.block_stack.items.len-1];
        try block.vars.put(self.alloc, name, {});

        return id;
    }

    fn parseIfStatement(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `if` keyword.
        self.advanceToken();

        const if_stmt = self.pushNode(.if_stmt, start);

        var dummy = false;
        const if_cond = (try self.parseExpression(false, &dummy)) orelse {
            return self.reportTokenError(error.SyntaxError, "Expected if condition.", self.peekToken());
        };

        var token = self.peekToken();
        if (token.token_t != .colon) {
            return self.reportTokenError(error.SyntaxError, "Expected colon after if condition.", token);
        }
        self.advanceToken();

        // TODO: Parse statements on the same line.

        token = self.peekToken();
        if (token.token_t != .new_line) {
            return self.reportTokenError(error.SyntaxError, "Expected new line.", token);
        }
        self.advanceToken();

        var first_stmt = try self.parseIndentedBodyStatements(self.cur_indent);
        self.nodes.items[if_stmt].head = .{
            .left_right = .{
                .left = if_cond,
                .right = first_stmt,
            },
        };

        const save = self.next_pos;
        const indent = self.consumeIndentBeforeStmt();
        if (indent != self.cur_indent) {
            self.next_pos = save;
            return if_stmt;
        }

        if (self.peekToken().token_t == .else_k) {
            const else_clause = self.pushNode(.else_clause, self.next_pos);
            self.advanceToken();

            token = self.peekToken();
            if (token.token_t != .colon) {
                return self.reportTokenError(error.SyntaxError, "Expected colon after else.", token);
            }
            self.advanceToken();

            // TODO: Parse statements on the same line.

            token = self.peekToken();
            if (token.token_t != .new_line) {
                return self.reportTokenError(error.SyntaxError, "Expected new line.", token);
            }
            self.advanceToken();

            first_stmt = try self.parseIndentedBodyStatements(self.cur_indent);
            self.nodes.items[else_clause].head = .{
                .child_head = first_stmt,
            };
            self.nodes.items[if_stmt].head.left_right.extra = else_clause;
        }
        return if_stmt;
    }

    fn parseForStatement(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `for` keyword.
        self.advanceToken();

        var token = self.peekToken();
        if (token.token_t == .colon) {
            self.advanceToken();

            // Infinite loop.
            const first_stmt = try self.parseIndentedBodyStatements(self.cur_indent);
            const for_stmt = self.pushNode(.for_inf_stmt, start);
            self.nodes.items[for_stmt].head = .{
                .child_head = first_stmt,
            };
            return for_stmt;
        } else {
            // Parse next token as expression.
            var dummy: bool = undefined;
            const expr_id = (try self.parseExpression(false, &dummy)) orelse {
                return self.reportTokenError(error.SyntaxError, "Expected condition expression.", token);
            };
            token = self.peekToken();
            if (token.token_t == .colon) {
                self.advanceToken();
                const first_stmt = try self.parseIndentedBodyStatements(self.cur_indent);
                const for_stmt = self.pushNode(.for_cond_stmt, start);
                self.nodes.items[for_stmt].head = .{
                    .left_right = .{
                        .left = expr_id,
                        .right = first_stmt,
                    },
                };
                return for_stmt;
            } else {
                return self.reportTokenError(error.SyntaxError, "Expected :.", token);
            }
        }
    }

    fn parseBlock(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the ident.
        const name = self.pushNode(.ident, start);
        self.advanceToken();
        // Assumes second token is colon.
        self.advanceToken();

        // Parse body.
        const first_stmt = try self.parseIndentedBodyStatements(self.cur_indent);
        
        const id = self.pushNode(.label_decl, start);
        self.nodes.items[id].head = .{
            .left_right = .{
                .left = name,
                .right = first_stmt,
            },
        };
        return id;
    }

    fn parseStatement(self: *Parser) anyerror!?NodeId {
        var token = self.peekToken();
        if (token.token_t == .none) {
            return null;
        }
        switch (token.token_t) {
            .new_line => {
                // Skip newlines.
                while (true) {
                    self.advanceToken();
                    token = self.peekToken();
                    if (token.token_t == .none) {
                        return null;
                    }
                    if (token.token_t != .new_line) {
                        break;
                    }
                }
                return try self.parseStatement();
            },
            .ident => {
                const token2 = self.peekTokenAhead(1);
                if (token2.token_t == .colon) {
                    return try self.parseBlock();
                } else {
                    if (try self.parseExprOrAssignStatement()) |id| {
                        return id;
                    }
                }
            },
            .at => {
                const start = self.next_pos;
                self.advanceToken();
                token = self.peekToken();
                if (token.token_t == .ident) {
                    const name_token = self.tokens.items[self.next_pos];
                    const name = self.src.items[name_token.start_pos .. name_token.data.end_pos];
                    if (std.mem.eql(u8, "name", name)) {
                        var skip_compile = false;

                        const ident = self.pushNode(.ident, self.next_pos);
                        self.advanceToken();
                        const at_ident = self.pushNode(.at_ident, start);
                        self.nodes.items[at_ident].head = .{
                            .annotation = .{
                                .child = ident,
                            },
                        };

                        const child = b: {
                            // Annotation must begin the source.
                            if (self.nodes.items.len == 3) {
                                // Parse as call expr.
                                const call_id = try self.parseAnyCallExpr(at_ident);
                                const call_expr = self.nodes.items[call_id];
                                if (call_expr.head.func_call.arg_head == NullId) {
                                    return self.reportTokenError(error.SyntaxError, "Expected arg for @name.", token);
                                }
                                const arg = self.nodes.items[call_expr.head.func_call.arg_head];
                                if (arg.node_t == .ident) {
                                    const arg_token = self.tokens.items[arg.start_token];
                                    self.name = self.src.items[arg_token.start_pos .. arg_token.data.end_pos];
                                    skip_compile = true;
                                    break :b call_id;
                                } else {
                                    return self.reportTokenError(error.SyntaxError, "Expected ident arg for @name.", token);
                                }
                            } else {
                                return self.reportTokenError(error.SyntaxError, "Expected @name to be the first statement.", token);
                            }
                            break :b at_ident;
                        };

                        const id = self.pushNode(.at_stmt, start);
                        self.nodes.items[id].head = .{
                            .at_stmt = .{
                                .child = child,
                                .skip_compile = skip_compile,
                            },
                        };

                        token = self.peekToken();
                        if (token.token_t == .new_line) {
                            self.advanceToken();
                            return id;
                        } else if (token.token_t == .none) {
                            return id;
                        } else return self.reportTokenError(error.BadToken, "Expected end of line or file", token);
                    }
                }

                // Reparse as expression.
                self.next_pos = start;
                if (try self.parseExprOrAssignStatement()) |id| {
                    return id;
                }
            },
            .func => {
                return try self.parseFunctionDeclaration();
            },
            .if_k => {
                return try self.parseIfStatement();
            },
            .for_k => {
                return try self.parseForStatement();
            },
            .break_k => {
                const id = self.pushNode(.break_stmt, self.next_pos);
                self.advanceToken();
                token = self.peekToken();
                switch (token.token_t) {
                    .none => return id,
                    .new_line => {
                        self.advanceToken();
                        return id;
                    },
                    else => {
                        return self.reportTokenError(error.SyntaxError, "Expected end of statement.", token);
                    },
                }
            },
            .return_k => {
                const id = try self.parseReturnStatement();
                token = self.peekToken();
                switch (token.token_t) {
                    .none => return id,
                    .new_line => {
                        self.advanceToken();
                        return id;
                    },
                    else => {
                        return self.reportTokenError(error.SyntaxError, "Expected end of statement.", token);
                    },
                }
            },
            else => {
                if (try self.parseExprOrAssignStatement()) |id| {
                    return id;
                }
            },
        }
        self.last_err = std.fmt.allocPrint(self.alloc, "unknown token: {} at {}", .{token.token_t, token.start_pos}) catch fatal();
        return error.UnknownToken;
    }

    fn reportTokenError(self: *Parser, err: anyerror, msg: []const u8, token: Token) anyerror {
        self.alloc.free(self.last_err);
        self.last_err = std.fmt.allocPrint(self.alloc, "{s}: {} at {}", .{msg, token.token_t, token.start_pos}) catch fatal();
        return err;
    }

    fn parseDictEntry(self: *Parser, key_node_t: NodeType) !NodeId {
        const start = self.next_pos;
        self.advanceToken();
        var token = self.peekToken();
        if (token.token_t != .colon) {
            return self.reportTokenError(error.SyntaxError, "Expected colon.", token);
        }
        self.advanceToken();
        var dummy = false;
        const val_id = (try self.parseExpression(false, &dummy)) orelse {
            return self.reportTokenError(error.SyntaxError, "Expected dictionary value.", token);
        };
        const key_id = self.pushNode(key_node_t, start);
        const entry_id = self.pushNode(.dict_entry, start);
        self.nodes.items[entry_id].head = .{
            .left_right = .{
                .left = key_id,
                .right = val_id,
            }
        };
        return entry_id;
    }

    fn consumeWhitespaceTokens(self: *Parser) void {
        var token = self.peekToken();
        while (token.token_t != .none) {
            switch (token.token_t) {
                .new_line,
                .indent => {
                    self.advanceToken();
                    token = self.peekToken();
                    continue;
                },
                else => return,
            }
        }
    }

    fn parseArrayLiteral(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assume first token is left bracket.
        self.advanceToken();

        var last_entry: NodeId = undefined;
        var first_entry: NodeId = NullId;
        outer: {
            self.consumeWhitespaceTokens();
            var token = self.peekToken();

            if (token.token_t == .right_bracket) {
                // Empty array.
                break :outer;
            } else {
                var dummy = false;
                first_entry = (try self.parseExpression(false, &dummy)) orelse {
                    return self.reportTokenError(error.SyntaxError, "Expected array item.", token);
                };
                last_entry = first_entry;
            }

            while (true) {
                self.consumeWhitespaceTokens();
                token = self.peekToken();
                if (token.token_t == .comma) {
                    self.advanceToken();
                } else if (token.token_t == .right_bracket) {
                    break :outer;
                }

                token = self.peekToken();
                if (token.token_t == .right_bracket) {
                    break :outer;
                } else {
                    var dummy = false;
                    const expr_id = (try self.parseExpression(false, &dummy)) orelse {
                        return self.reportTokenError(error.SyntaxError, "Expected array item.", token);
                    };
                    self.nodes.items[last_entry].next = expr_id;
                    last_entry = expr_id;
                }
            }
        }

        const arr_id = self.pushNode(.arr_literal, start);
        self.nodes.items[arr_id].head = .{
            .child_head = first_entry,
        };

        // Parse closing bracket.
        const token = self.peekToken();
        if (token.token_t == .right_bracket) {
            self.advanceToken();
            return arr_id;
        } else return self.reportTokenError(error.SyntaxError, "Expected closing bracket.", token);
    }

    fn parseDictLiteral(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assume first token is left brace.
        self.advanceToken();

        var last_entry: NodeId = undefined;
        var first_entry: NodeId = NullId;
        outer: {
            self.consumeWhitespaceTokens();
            var token = self.peekToken();
            switch (token.token_t) {
                .ident => {
                    first_entry = try self.parseDictEntry(.ident);
                    last_entry = first_entry;
                },
                .string => {
                    first_entry = try self.parseDictEntry(.string);
                    last_entry = first_entry;
                },
                .number => {
                    first_entry = try self.parseDictEntry(.number);
                    last_entry = first_entry;
                },
                .right_brace => {
                    break :outer;
                },
                else => return self.reportTokenError(error.SyntaxError, "Expected dictionary key.", token),
            }

            while (true) {
                self.consumeWhitespaceTokens();
                token = self.peekToken();
                if (token.token_t == .comma) {
                    self.advanceToken();
                } else if (token.token_t == .right_brace) {
                    break :outer;
                }

                token = self.peekToken();
                switch (token.token_t) {
                    .ident => {
                        const entry_id = try self.parseDictEntry(.ident);
                        self.nodes.items[last_entry].next = entry_id;
                        last_entry = entry_id;
                    },
                    .string => {
                        const entry_id = try self.parseDictEntry(.string);
                        self.nodes.items[last_entry].next = entry_id;
                        last_entry = entry_id;
                    },
                    .number => {
                        const entry_id = try self.parseDictEntry(.number);
                        self.nodes.items[last_entry].next = entry_id;
                        last_entry = entry_id;
                    },
                    .right_brace => {
                        break :outer;
                    },
                    else => return self.reportTokenError(error.SyntaxError, "Expected dictionary key.", token),
                }
            }
        }

        const dict_id = self.pushNode(.dict_literal, start);
        self.nodes.items[dict_id].head = .{
            .child_head = first_entry,
        };

        // Parse closing brace.
        const token = self.peekToken();
        if (token.token_t == .right_brace) {
            self.advanceToken();
            return dict_id;
        } else return self.reportTokenError(error.SyntaxError, "Expected closing brace.", token);
    }

    fn parseCallArg(self: *Parser) !?NodeId {
        self.consumeWhitespaceTokens();
        const start = self.next_pos;
        const token = self.peekToken();
        if (token.token_t == .ident) {
            if (self.peekTokenAhead(1).token_t == .colon) {
                // Named arg.
                const name = self.pushNode(.ident, start);
                _ = self.consumeToken();
                _ = self.consumeToken();
                var dummy = false;
                var arg = (try self.parseExpression(false, &dummy)) orelse {
                    return self.reportTokenError(error.SyntaxError, "Expected arg expression.", self.peekToken());
                };
                const named_arg = self.pushNode(.named_arg, start);
                self.nodes.items[named_arg].head = .{
                    .left_right = .{
                        .left = name,
                        .right = arg,
                    },
                };
                return named_arg;
            } 
        }

        var dummy = false;
        return try self.parseExpression(false, &dummy);
    }

    fn parseAnyCallExpr(self: *Parser, callee: NodeId) !NodeId {
        const token = self.peekToken();
        if (token.token_t == .left_paren) {
            return try self.parseCallExpression(callee);
        } else {
            return try self.parseNoParenCallExpression(callee);
        }
    }

    fn parseCallExpression(self: *Parser, left_id: NodeId) !NodeId {
        // Assume first token is left paren.
        self.advanceToken();

        const expr_start = self.nodes.items[left_id].start_token;
        const expr_id = self.pushNode(.call_expr, expr_start);

        var has_named_arg = false;
        var first: NodeId = NullId;
        inner: {
            first = (try self.parseCallArg()) orelse {
                break :inner;
            };
            if (self.nodes.items[first].node_t == .named_arg) {
                has_named_arg = true;
            }
            var last_arg_id = first;
            while (true) {
                const token = self.peekToken();
                if (token.token_t != .comma and token.token_t != .new_line) {
                    break;
                }
                self.advanceToken();
                const arg_id = (try self.parseCallArg()) orelse {
                    break;
                };
                self.nodes.items[last_arg_id].next = arg_id;
                last_arg_id = arg_id;
                if (self.nodes.items[last_arg_id].node_t == .named_arg) {
                    has_named_arg = true;
                }
            }
        }
        // Parse closing paren.
        self.consumeWhitespaceTokens();
        const token = self.peekToken();
        if (token.token_t == .right_paren) {
            self.advanceToken();
            self.nodes.items[expr_id].head = .{
                .func_call = .{
                    .callee = left_id,
                    .arg_head = first,
                    .has_named_arg = has_named_arg,
                },
            };
            return expr_id;
        } else return self.reportTokenError(error.SyntaxError, "Expected closing parenthesis.", token);
    }

    /// Assumes first arg exists.
    fn parseNoParenCallExpression(self: *Parser, left_id: NodeId) !NodeId {
        const expr_start = self.nodes.items[left_id].start_token;
        const expr_id = self.pushNode(.call_expr, expr_start);

        const start = self.next_pos;
        var token = self.consumeToken();
        var last_arg_id = switch (token.token_t) {
            .ident => self.pushNode(.ident, start),
            .string => self.pushNode(.string, start),
            .number => self.pushNode(.number, start),
            else => return self.reportTokenError(error.BadToken, "Expected arg token", token),
        };
        self.nodes.items[expr_id].head = .{
            .func_call = .{
                .callee = left_id,
                .arg_head = last_arg_id,
                .has_named_arg = false,
            },
        };

        while (true) {
            token = self.peekToken();
            const arg_id = switch (token.token_t) {
                .ident => self.pushNode(.ident, self.next_pos),
                .string => self.pushNode(.string, self.next_pos),
                .number => self.pushNode(.number, self.next_pos),
                .new_line => break,
                .none => break,
                else => return self.reportTokenError(error.BadToken, "Expected arg token", token),
            };
            self.nodes.items[last_arg_id].next = arg_id;
            last_arg_id = arg_id;
            self.advanceToken();
        }
        return expr_id;
    }

    /// Parses the right expression of a BinaryExpression.
    fn parseRightExpression(self: *Parser, left_op: BinaryExprOp) anyerror!NodeId {
        var start = self.next_pos;
        const expr_id = try self.parseTermExpr();

        // Check if next token is an operator with higher precedence.
        const token = self.peekToken();
        if (token.token_t == .operator) {
            const op_prec = getBinOpPrecedence(left_op);
            const right_op = toBinExprOp(token.data.operator_t);
            const right_op_prec = getBinOpPrecedence(right_op);
            if (right_op_prec > op_prec) {
                // Continue parsing right.
                _ = self.consumeToken();
                start = self.next_pos;
                const right_id = try self.parseRightExpression(right_op);

                const bin_expr = self.pushNode(.bin_expr, start);
                self.nodes.items[bin_expr].head = .{
                    .left_right = .{
                        .left = expr_id,
                        .right = right_id,
                        .extra = @enumToInt(right_op),
                    },
                };
                return bin_expr;
            }
        }
        return expr_id;
    }

    fn isVarDeclaredFromScope(self: *Parser, name: []const u8) bool {
        var i = self.block_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.block_stack.items[i].vars.contains(name)) {
                return true;
            }
        }
        return false;
    }

    fn parseTermExpr(self: *Parser) anyerror!NodeId {
        var start = self.next_pos;
        var token = self.peekToken();

        var left_id = switch (token.token_t) {
            .ident => b: {
                self.advanceToken();
                const id = self.pushNode(.ident, start);

                const name_token = self.tokens.items[start];
                const name = self.src.items[name_token.start_pos..name_token.data.end_pos];
                if (!self.isVarDeclaredFromScope(name)) {
                    try self.deps.put(self.alloc, name, id);
                }

                break :b id;
            },
            .number => b: {
                self.advanceToken();
                break :b self.pushNode(.number, start);
            },
            .string => b: {
                self.advanceToken();
                break :b self.pushNode(.string, start);
            },
            .at => b: {
                self.advanceToken();
                token = self.peekToken();
                if (token.token_t == .ident) {
                    const ident = self.pushNode(.ident, self.next_pos);
                    self.advanceToken();
                    const at_ident = self.pushNode(.at_ident, start);
                    self.nodes.items[at_ident].head = .{
                        .annotation = .{
                            .child = ident,
                        },
                    };
                    break :b at_ident;
                } else {
                    return self.reportTokenError(error.SyntaxError, "Expected identifier.", token);
                }
            },
            .await_k => {
                // Await expression.
                const expr_id = self.pushNode(.await_expr, start);
                self.advanceToken();
                const term_id = try self.parseTermExpr();
                self.nodes.items[expr_id].head = .{
                    .child_head = term_id,
                };
                return expr_id;
            },
            .func => {
                // Lambda function.
                return self.parseLambdaFunction();
            },
            .if_k => {
                const if_expr = self.pushNode(.if_expr, start);
                self.advanceToken();
                var dummy = false;
                const if_cond = (try self.parseExpression(false, &dummy)) orelse {
                    return self.reportTokenError(error.SyntaxError, "Expected if condition.", self.peekToken());
                };

                var token2 = self.peekToken();
                if (token2.token_t != .colon) {
                    return self.reportTokenError(error.SyntaxError, "Expected colon after if condition.", token2);
                }
                self.advanceToken();

                const if_body = (try self.parseExpression(false, &dummy)) orelse {
                    return self.reportTokenError(error.SyntaxError, "Expected if body.", self.peekToken());
                };
                self.nodes.items[if_expr].head = .{
                    .left_right = .{
                        .left = if_cond,
                        .right = if_body,
                    },
                };

                if (self.peekToken().token_t == .else_k) {
                    const else_clause = self.pushNode(.else_clause, self.next_pos);
                    self.advanceToken();

                    const else_body = (try self.parseExpression(false, &dummy)) orelse {
                        return self.reportTokenError(error.SyntaxError, "Expected else body.", self.peekToken());
                    };
                    self.nodes.items[else_clause].head = .{
                        .child_head = else_body,
                    };

                    self.nodes.items[if_expr].head.left_right.extra = else_clause;
                }
                return if_expr;
            },
            .left_paren => b: {
                _ = self.consumeToken();
                token = self.peekToken();

                var dummy = false;
                const expr_id = (try self.parseExpression(false, &dummy)) orelse {
                    return self.reportTokenError(error.SyntaxError, "Expected expression.", token);
                };
                token = self.peekToken();
                if (token.token_t == .right_paren) {
                    _ = self.consumeToken();
                    break :b expr_id;
                } else {
                    return self.reportTokenError(error.SyntaxError, "Expected right parenthesis.", token);
                }
            },
            .left_brace => b: {
                // Dictionary literal.
                const dict_id = try self.parseDictLiteral();
                break :b dict_id;
            },
            .left_bracket => b: {
                // Array literal.
                const arr_id = try self.parseArrayLiteral();
                break :b arr_id;
            },
            .operator => {
                if (token.data.operator_t == .minus) {
                    self.advanceToken();
                    const expr_id = self.pushNode(.unary_expr, start);
                    const term_id = try self.parseTermExpr();
                    self.nodes.items[expr_id].head = .{
                        .unary = .{
                            .child = term_id,
                            .op = .minus,
                        },
                    };
                    return expr_id;
                } else return self.reportTokenError(error.SyntaxError, "Unexpected operator.", token);
            },
            .none => return self.reportTokenError(error.SyntaxError, "Expected term expr.", token),
            else => return self.reportTokenError(error.SyntaxError, "Expected term expr.", token),
        };

        while (true) {
            const next = self.peekToken();
            switch (next.token_t) {
                .dot => {
                    // AccessExpression.
                    self.advanceToken();
                    const next2 = self.peekToken();
                    if (next2.token_t == .ident) {
                        const right_id = self.pushNode(.ident, self.next_pos);
                        const expr_id = self.pushNode(.access_expr, start);
                        self.nodes.items[expr_id].head = .{
                            .left_right = .{
                                .left = left_id,
                                .right = right_id,
                            },
                        };
                        left_id = expr_id;
                        self.advanceToken();
                        start = self.next_pos;
                    } else return self.reportTokenError(error.BadToken, "Expected ident", next2);
                },
                .left_bracket => {
                    // If left is an accessor expression or identifier, parse as access expression.
                    const left_t = self.nodes.items[left_id].node_t;
                    if (left_t == .ident or left_t == .access_expr) {
                        // Consume left bracket.
                        self.advanceToken();

                        var dummy = false;
                        const expr_id = (try self.parseExpression(false, &dummy)) orelse {
                            return self.reportTokenError(error.SyntaxError, "Expected expression.", self.peekToken());
                        };

                        token = self.peekToken();
                        if (token.token_t == .right_bracket) {
                            self.advanceToken();
                            const access_id = self.pushNode(.access_expr, start);
                            self.nodes.items[access_id].head = .{
                                .left_right = .{
                                    .left = left_id,
                                    .right = expr_id,
                                },
                            };
                            left_id = access_id;
                            start = self.next_pos;
                        } else return self.reportTokenError(error.SyntaxError, "Expected right bracket.", token);
                    } else return self.reportTokenError(error.SyntaxError, "Expected variable to left of access expression.", next);
                },
                .left_paren => {
                    // If left is an accessor expression or identifier, parse as call expression.
                    const left_t = self.nodes.items[left_id].node_t;
                    if (left_t == .ident or left_t == .access_expr or left_t == .at_ident) {
                        const call_id = try self.parseCallExpression(left_id);
                        left_id = call_id;
                    } else return self.reportTokenError(error.SyntaxError, "Expected variable to left of call expression.", next);
                },
                .right_bracket => break,
                .right_paren => break,
                .right_brace => break,
                .else_k => break,
                .comma => break,
                .colon => break,
                .plus_equal,
                .equal => break,
                .operator => break,
                .logic_op => break,
                .ident,
                .number,
                .string => {
                    // CallExpression.
                    left_id = try self.parseNoParenCallExpression(left_id);
                    start = self.next_pos;
                },
                .new_line,
                .none => break,
                else => return self.reportTokenError(error.UnknownToken, "Unknown token", next),
            }
        }
        return left_id;
    }

    fn parseExpression(self: *Parser, consider_assignment_stmt: bool, out_is_assignment_stmt: *bool) anyerror!?NodeId {
        var start = self.next_pos;
        var token = self.peekToken();

        var left_id = switch (token.token_t) {
            .if_k => {
                return try self.parseTermExpr();
            },
            .none => return null,
            .right_paren => return null,
            .right_bracket => return null,
            else => self.parseTermExpr() catch {
                return self.reportTokenError(error.SyntaxError, "Unexpected left token in expression", token);
            },
        };

        while (true) {
            const next = self.peekToken();
            switch (next.token_t) {
                .right_bracket => break,
                .right_paren => break,
                .right_brace => break,
                .else_k => break,
                .comma => break,
                .colon => break,
                .plus_equal,
                .equal => {
                    // If left is an accessor expression or identifier, parse as assignment statement.
                    if (consider_assignment_stmt) {
                        if (self.nodes.items[left_id].node_t == .ident) {
                            out_is_assignment_stmt.* = true;
                            return left_id;
                        } else {
                            return self.reportTokenError(error.SyntaxError, "Expected variable to left of assignment operator.", next);
                        }
                    } else {
                        return self.reportTokenError(error.SyntaxError, "Assignment operator not allowed in expression.", next);
                    }
                },
                .operator => {
                    // BinaryExpression.
                    const op_t = next.data.operator_t;
                    const bin_op = toBinExprOp(op_t);
                    self.advanceToken();
                    const right_id = try self.parseRightExpression(bin_op);

                    const bin_expr = self.pushNode(.bin_expr, start);
                    self.nodes.items[bin_expr].head = .{
                        .left_right = .{
                            .left = left_id,
                            .right = right_id,
                            .extra = @enumToInt(bin_op),
                        },
                    };
                    left_id = bin_expr;
                },
                .logic_op => {
                    // BinaryExpression.
                    const op_t = next.data.logic_op_t;
                    const bin_op = try toBinExprOpFromLogicOp(op_t);
                    self.advanceToken();
                    const right_id = try self.parseRightExpression(bin_op);

                    const bin_expr = self.pushNode(.bin_expr, start);
                    self.nodes.items[bin_expr].head = .{
                        .left_right = .{
                            .left = left_id,
                            .right = right_id,
                            .extra = @enumToInt(bin_op),
                        },
                    };
                    left_id = bin_expr;
                },
                .new_line,
                .none => break,
                else => return self.reportTokenError(error.UnknownToken, "Unknown token", next),
            }
        }
        out_is_assignment_stmt.* = false;
        return left_id;
    }

    /// Assumes next token is the return token.
    fn parseReturnStatement(self: *Parser) !u32 {
        const start = self.next_pos;
        self.advanceToken();
        var dummy = false;
        if (try self.parseExpression(false, &dummy)) |expr_id| {
            const id = self.pushNode(.return_expr_stmt, start);
            self.nodes.items[id].head = .{
                .child_head = expr_id,
            };
            return id;
        } else {
            return self.pushNode(.return_stmt, start);
        }
    }

    fn parseExprOrAssignStatement(self: *Parser) !?u32 {
        var is_assign_stmt = false;
        const expr_id = (try self.parseExpression(true, &is_assign_stmt)) orelse return null;

        if (is_assign_stmt) {
            var token = self.peekToken();
            // Assumes next token is an assignment operator: =, +=.
            self.advanceToken();
            var dummy = false;
            const right_expr_id = (try self.parseExpression(false, &dummy)) orelse {
                return self.reportTokenError(error.SyntaxError, "Expected right expression for assignment statement.", self.peekToken());
            };
            const start = self.nodes.items[expr_id].start_token;
            const id = switch (token.token_t) {
                .equal => self.pushNode(.assign_stmt, start),
                .plus_equal => self.pushNode(.add_assign_stmt, start),
                else => return self.reportTokenError(error.Unsupported, "Unsupported assignment operator.", token),
            };
            self.nodes.items[id].head = .{
                .left_right = .{
                    .left = expr_id,
                    .right = right_expr_id,
                },
            };

            const left = self.nodes.items[expr_id];
            if (left.node_t == .ident) {
                const name_token = self.tokens.items[left.start_token];
                const name = self.src.items[name_token.start_pos..name_token.data.end_pos];
                const block = &self.block_stack.items[self.block_stack.items.len-1];
                if (self.deps.get(name)) |node_id| {
                    if (node_id == expr_id) {
                        // Remove dependency now that it's recognized as assign statement.
                        _ = self.deps.remove(name);
                    }
                }
                try block.vars.put(self.alloc, name, {});
            }

            token = self.peekToken();
            if (token.token_t == .new_line) {
                self.advanceToken();
                return id;
            } else if (token.token_t == .none) {
                return id;
            } else return self.reportTokenError(error.BadToken, "Expected end of line or file", token);
        } else {
            const start = self.nodes.items[expr_id].start_token;
            const id = self.pushNode(.expr_stmt, start);
            self.nodes.items[id].head = .{
                .child_head = expr_id,
            };

            const token = self.peekToken();
            if (token.token_t == .new_line) {
                self.advanceToken();
                return id;
            } else if (token.token_t == .none) {
                return id;
            } else return self.reportTokenError(error.BadToken, "Expected end of line or file", token);
        }
    }

    pub fn pushNode(self: *Parser, node_t: NodeType, start: u32) NodeId {
        const id = self.nodes.items.len;
        self.nodes.append(self.alloc, .{
            .node_t = node_t,
            .start_token = start,
            .next = NullId,
            .head = undefined,
        }) catch fatal();
        return @intCast(NodeId, id);
    }

    fn tokenize(self: *Parser) !void {
        self.tokens.clearRetainingCapacity();
        self.last_err = "";
        self.next_pos = 0;

        while (!self.isAtEndChar()) {
            // First parse indent spaces.
            while (!self.isAtEndChar()) {
                const ch = self.peekChar();
                switch (ch) {
                    ' ' => {
                        const start = self.next_pos;
                        self.advanceChar();
                        var count: u32 = 1;
                        while (true) {
                            const ch_ = self.peekChar();
                            if (ch_ == ' ') {
                                count += 1;
                                self.advanceChar();
                            } else break;
                        }
                        self.pushIndentToken(count, start);
                    },
                    '\n' => {
                        self.pushToken(.new_line, self.next_pos);
                        self.advanceChar();
                    },
                    else => break,
                }
            }
            while (!self.isAtEndChar()) {
                const start = self.next_pos;
                const ch = self.consumeChar();
                switch (ch) {
                    '(' => self.pushToken(.left_paren, start),
                    ')' => self.pushToken(.right_paren, start),
                    '{' => self.pushToken(.left_brace, start),
                    '}' => self.pushToken(.right_brace, start),
                    '[' => self.pushToken(.left_bracket, start),
                    ']' => self.pushToken(.right_bracket, start),
                    ',' => self.pushToken(.comma, start),
                    '.' => self.pushToken(.dot, start),
                    ':' => self.pushToken(.colon, start),
                    '@' => self.pushToken(.at, start),
                    '-' => self.pushOpToken(.minus, start),
                    '%' => self.pushOpToken(.percent, start),
                    '+' => {
                        if (self.peekChar() == '=') {
                            self.advanceChar();
                            self.pushToken(.plus_equal, start);
                        } else {
                            self.pushOpToken(.plus, start);
                        }
                    },
                    '*' => self.pushOpToken(.star, start),
                    '/' => {
                        if (self.peekChar() == '/') {
                            // Single line comment. Ignore chars until eol.
                            while (!self.isAtEndChar()) {
                                _ = self.consumeChar();
                                if (self.peekChar() == '\n') {
                                    // Don't consume new line or the current indentation could augment with the next line.
                                    break;
                                }
                            }
                        } else {
                            self.pushOpToken(.slash, start);
                        }
                    },
                    '!' => {
                        if (self.isNextChar('=')) {
                            self.pushLogicOpToken(.bang_equal, start);
                            self.advanceChar();
                        } else {
                            self.pushLogicOpToken(.bang, start);
                        }
                    },
                    '=' => {
                        if (!self.isAtEndChar()) {
                            switch (self.peekChar()) {
                                '=' => {
                                    self.advanceChar();
                                    self.pushLogicOpToken(.equal_equal, start);
                                },
                                '>' => {
                                    self.advanceChar();
                                    self.pushToken(.equal_greater, start);
                                },
                                else => {
                                    self.pushToken(.equal, start);
                                }
                            }
                        } else {
                            self.pushToken(.equal, start);
                        }
                    },
                    '<' => {
                        if (self.isNextChar('=')) {
                            self.pushLogicOpToken(.less_equal, start);
                            self.advanceChar();
                        } else {
                            self.pushLogicOpToken(.less, start);
                        }
                    },
                    '>' => {
                        if (self.isNextChar('=')) {
                            self.pushLogicOpToken(.greater_equal, start);
                            self.advanceChar();
                        } else {
                            self.pushLogicOpToken(.greater, start);
                        }
                    },
                    ' ',
                    '\r',
                    '\t' => continue,
                    '\n' => {
                        self.pushToken(.new_line, start);
                        break;
                    },
                    '`' => {
                        while (true) {
                            if (self.isAtEndChar()) {
                                return error.UnterminatedString;
                            }
                            const ch_ = self.consumeChar();
                            switch (ch_) {
                                '`' => {
                                    self.pushStringToken(start, self.next_pos);
                                    break;
                                },
                                '\\' => {
                                    // Escape the next character.
                                    if (self.isAtEndChar()) {
                                        return error.UnterminatedString;
                                    }
                                    _ = self.consumeChar();
                                    continue;
                                },
                                else => {},
                            }
                        }
                    },
                    '\'' => {
                        while (true) {
                            if (self.isAtEndChar()) {
                                return error.UnterminatedString;
                            }
                            const ch_ = self.consumeChar();
                            switch (ch_) {
                                '\'' => {
                                    self.pushStringToken(start, self.next_pos);
                                    break;
                                },
                                '\\' => {
                                    // Escape the next character.
                                    if (self.isAtEndChar()) {
                                        return error.UnterminatedString;
                                    }
                                    _ = self.consumeChar();
                                    continue;
                                },
                                '\n' => {
                                    return error.UnterminatedString;
                                },
                                else => {},
                            }
                        }
                    },
                    else => {
                        if (std.ascii.isAlpha(ch)) {
                            self.tokenizeKeywordOrIdent(start);
                            continue;
                        }
                        if (ch >= '0' and ch <= '9') {
                            self.tokenizeNumber(start);
                            continue;
                        }
                        self.last_err = std.fmt.allocPrint(self.alloc, "unknown character: {c} ({}) at {}", .{ch, ch, start}) catch fatal();
                        return error.UnknownChar;
                    },
                }
            }
        }
    }

    fn tokenizeKeywordOrIdent(self: *Parser, start: u32) void {
        // Consume alpha.
        while (true) {
            if (self.isAtEndChar()) {
                if (keywords.get(self.src.items[start..self.next_pos])) |token_t| {
                    self.pushToken(token_t, start);
                } else {
                    self.pushIdentToken(start, self.next_pos);
                }
                return;
            }
            const ch = self.peekChar();
            if (std.ascii.isAlpha(ch)) {
                self.advanceChar();
                continue;
            } else break;
        }

        // Consume alpha, numeric, underscore.
        while (true) {
            if (self.isAtEndChar()) {
                if (keywords.get(self.src.items[start..self.next_pos])) |token_t| {
                    self.pushToken(token_t, start);
                } else {
                    self.pushIdentToken(start, self.next_pos);
                }
                return;
            }
            const ch = self.peekChar();
            if (std.ascii.isAlNum(ch)) {
                self.advanceChar();
                continue;
            }
            if (ch == '_') {
                self.advanceChar();
                continue;
            }
            if (keywords.get(self.src.items[start..self.next_pos])) |token_t| {
                self.pushToken(token_t, start);
            } else {
                self.pushIdentToken(start, self.next_pos);
            }
            return;
        }
    }

    fn tokenizeNumber(self: *Parser, start: u32) void {
        while (true) {
            if (self.isAtEndChar()) {
                self.pushNumberToken(start, self.next_pos);
                return;
            }
            const ch = self.peekChar();
            if (ch >= '0' and ch <= '9') {
                self.advanceChar();
                continue;
            } else break;
        }
        // Check for decimal.
        if (self.next_pos < self.src.items.len - 1) {
            const ch = self.peekChar();
            const ch2 = self.src.items[self.next_pos + 1];
            if (ch == '.' and ch2 >= '0' and ch2 <= '9') {
                self.next_pos += 2;
                while (true) {
                    if (self.isAtEndChar()) {
                        break;
                    }
                    const ch_ = self.peekChar();
                    if (ch_ >= '0' and ch_ <= '9') {
                        self.advanceChar();
                        continue;
                    } else break;
                }
            }
        }
        self.pushNumberToken(start, self.next_pos);
    }

    inline fn pushIdentToken(self: *Parser, start_pos: u32, end_pos: u32) void {
        self.tokens.append(self.alloc, .{
            .token_t = .ident,
            .start_pos = start_pos,
            .data = .{
                .end_pos = end_pos,
            },
        }) catch fatal();
    }

    inline fn pushNumberToken(self: *Parser, start_pos: u32, end_pos: u32) void {
        self.tokens.append(self.alloc, .{
            .token_t = .number,
            .start_pos = start_pos,
            .data = .{
                .end_pos = end_pos,
            },
        }) catch fatal();
    }

    inline fn pushStringToken(self: *Parser, start_pos: u32, end_pos: u32) void {
        self.tokens.append(self.alloc, .{
            .token_t = .string,
            .start_pos = start_pos,
            .data = .{
                .end_pos = end_pos,
            },
        }) catch fatal();
    }

    inline fn pushLogicOpToken(self: *Parser, logic_op_t: LogicOpType, start_pos: u32) void {
        self.tokens.append(self.alloc, .{
            .token_t = .logic_op,
            .start_pos = start_pos,
            .data = .{
                .logic_op_t = logic_op_t,
            },
        }) catch fatal();
    }

    inline fn pushOpToken(self: *Parser, operator_t: OperatorType, start_pos: u32) void {
        self.tokens.append(self.alloc, .{
            .token_t = .operator,
            .start_pos = start_pos,
            .data = .{
                .operator_t = operator_t,
            },
        }) catch fatal();
    }

    inline fn pushIndentToken(self: *Parser, num_spaces: u32, start_pos: u32) void {
        self.tokens.append(self.alloc, .{
            .token_t = .indent,
            .start_pos = start_pos,
            .data = .{
                .indent = num_spaces,
            },
        }) catch fatal();
    }

    inline fn pushToken(self: *Parser, token_t: TokenType, start_pos: u32) void {
        self.tokens.append(self.alloc, .{
            .token_t = token_t,
            .start_pos = start_pos,
            .data = .{
                .nothing = {},
            },
        }) catch fatal();
    }

    inline fn isAtEndChar(self: Parser) bool {
        return self.src.items.len == self.next_pos;
    }

    inline fn isNextChar(self: Parser, ch: u8) bool {
        if (self.isAtEndChar()) {
            return false;
        }
        return self.src.items[self.next_pos] == ch;
    }

    inline fn consumeChar(self: *Parser) u8 {
        const ch = self.src.items[self.next_pos];
        self.next_pos += 1;
        return ch;
    }

    inline fn peekChar(self: Parser) u8 {
        return self.src.items[self.next_pos];
    }

    inline fn advanceChar(self: *Parser) void {
        self.next_pos += 1;
    }

    /// When n=0, this is equivalent to peekToken.
    inline fn peekTokenAhead(self: Parser, n: u32) Token {
        if (self.next_pos + n < self.tokens.items.len) {
            return self.tokens.items[self.next_pos + n];
        } else {
            return Token{
                .token_t = .none,
                .start_pos = self.next_pos,
                .data = .{
                    .nothing = {},
                },
            };
        }
    }

    inline fn peekToken(self: Parser) Token {
        if (!self.isAtEndToken()) {
            return self.tokens.items[self.next_pos];
        } else {
            return Token{
                .token_t = .none,
                .start_pos = self.next_pos,
                .data = .{
                    .nothing = {},
                },
            };
        }
    }

    inline fn advanceToken(self: *Parser) void {
        self.next_pos += 1;
    }

    inline fn isAtEndToken(self: Parser) bool {
        return self.tokens.items.len == self.next_pos;
    }

    inline fn consumeToken(self: *Parser) Token {
        const token = self.tokens.items[self.next_pos];
        self.next_pos += 1;
        return token;
    }
};

pub const OperatorType = enum(u3) {
    plus,
    minus,
    star,
    slash,
    percent,
};

const LogicOpType = enum(u3) {
    bang = 0,
    bang_equal = 1,
    less = 2,
    less_equal = 3,
    greater = 4,
    greater_equal = 5,
    equal_equal = 6,
};

const TokenType = enum(u5) {
    ident,
    number,
    string,
    operator,
    at,
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
    equal_greater,
    comma,
    colon,
    dot,
    logic_op,
    equal,
    plus_equal,
    new_line,
    indent,
    return_k,
    break_k,
    if_k,
    else_k,
    for_k,
    await_k,
    func,
    /// Used to indicate no token.
    none,
};

pub const Token = struct {
    token_t: TokenType,
    start_pos: u32,
    data: union {
        end_pos: u32,
        operator_t: OperatorType,
        logic_op_t: LogicOpType,
        // Num indent spaces.
        indent: u32,
        nothing: void,
    },
};

const NodeType = enum(u5) {
    root,
    expr_stmt,
    assign_stmt,
    add_assign_stmt,
    break_stmt,
    return_stmt,
    return_expr_stmt,
    at_stmt,
    ident,
    at_ident,
    string,
    await_expr,
    access_expr,
    call_expr,
    named_arg,
    bin_expr,
    unary_expr,
    number,
    if_expr,
    if_stmt,
    else_clause,
    for_inf_stmt,
    for_cond_stmt,
    label_decl,
    func_decl,
    lambda_single, // Single line.
    lambda_multi,  // Multi line.
    dict_literal,
    dict_entry,
    arr_literal,
};

pub const BinaryExprOp = enum(u4) {
    plus,
    minus,
    star,
    slash,
    percent,
    bang_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    equal_equal,
    dummy,
};

const UnaryOp = enum {
    minus,
};

pub const Node = struct {
    node_t: NodeType,
    start_token: u32,
    next: NodeId,
    /// Fixed size.
    head: union {
        left_right: struct {
            left: NodeId,
            right: NodeId,
            extra: u32 = NullId,
        },
        func_call: struct {
            callee: NodeId,
            arg_head: NodeId,
            has_named_arg: bool,
        },
        unary: struct {
            child: NodeId,
            op: UnaryOp,
        },
        child_head: NodeId,
        annotation: struct {
            child: NodeId,
        },
        at_stmt: struct {
            child: NodeId,
            skip_compile: bool,
        },
        func: struct {
            decl_id: FuncDeclId,
            body_head: NodeId,
        },
    },
};

pub const Result = struct {
    inner: ResultView,
    
    pub fn init(alloc: std.mem.Allocator, view: ResultView) !Result {
        const arr = try view.nodes.clone(alloc);
        const nodes = try alloc.create(std.ArrayListUnmanaged(Node));
        nodes.* = arr;

        const deps_map = try view.deps.clone(alloc);
        const deps = try alloc.create(std.StringHashMapUnmanaged(NodeId));
        deps.* = deps_map;

        return Result{
            .inner = .{
                .has_error = view.has_error,
                .err_msg = try alloc.dupe(u8, view.err_msg),
                .root_id = view.root_id,
                .nodes = nodes,
                .src = try alloc.dupe(u8, view.src),
                .tokens = try alloc.dupe(Token, view.tokens),
                .func_decls = try alloc.dupe(FunctionDeclaration, view.func_decls),
                .func_params = try alloc.dupe(FunctionParam, view.func_params),
                .name = try alloc.dupe(u8, view.name),
                .deps = deps,
            },
        };
    }

    pub fn deinit(self: Result, alloc: std.mem.Allocator) void {
        alloc.free(self.inner.err_msg);
        self.inner.nodes.deinit(alloc);
        alloc.destroy(self.inner.nodes);
        alloc.free(self.inner.tokens);
        alloc.free(self.inner.src);
        alloc.free(self.inner.func_decls);
        alloc.free(self.inner.func_params);
        alloc.free(self.inner.name);
        self.inner.deps.deinit(alloc);
        alloc.destroy(self.inner.deps);
    }
};

/// Result data is owned by the Parser instance.
pub const ResultView = struct {
    has_error: bool,
    err_msg: []const u8,
    root_id: NodeId,

    /// ArrayList is returned so resulting ast can be modified.
    nodes: *std.ArrayListUnmanaged(Node),
    tokens: []const Token,
    src: []const u8,
    func_decls: []const FunctionDeclaration,
    func_params: []const FunctionParam,

    name: []const u8,
    deps: *std.StringHashMapUnmanaged(NodeId),

    pub fn getTokenString(self: ResultView, token_id: u32) []const u8 {
        // Assumes token with end_pos.
        const token = self.tokens[token_id];
        return self.src[token.start_pos..token.data.end_pos];
    }

    pub fn dupe(self: ResultView, alloc: std.mem.Allocator) !Result {
        return try Result.init(alloc, self);
    }
};

const FuncDeclId = u32;

pub const FunctionDeclaration = struct {
    name: IndexSlice,
    params: IndexSlice,
    return_type: ?IndexSlice,
};

pub const FunctionParam = struct {
    name: IndexSlice,
};

fn toBinExprOp(op: OperatorType) BinaryExprOp {
    return switch (op) {
        .plus => .plus,
        .minus => .minus,
        .star => .star,
        .slash => .slash,
        .percent => .percent,
    };
}

fn toBinExprOpFromLogicOp(op: LogicOpType) !BinaryExprOp {
    return switch (op) {
        .bang_equal => .bang_equal,
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .equal_equal => .equal_equal,
        else => {
            log.debug("unsupported logic op: {}", .{op});
            return error.Unsupported;
        },
    };
}

pub fn getBinOpPrecedence(op: BinaryExprOp) u8 {
    switch (op) {
        .star => {
            return 2;
        },
        .minus,
        .plus => {
            return 1;
        },
        .greater,
        .greater_equal,
        .less,
        .less_equal,
        .bang_equal,
        .equal_equal => {
            return 0;
        },
        else => return 0,
    }
}

pub fn getLastStmt(nodes: []const Node, head: NodeId, out_prev: *NodeId) NodeId {
    var prev: NodeId = NullId;
    var cur_id = head;
    while (cur_id != NullId) {
        const node = nodes[cur_id];
        if (node.next == NullId) {
            out_prev.* = prev;
            return cur_id;
        }
        prev = cur_id;
        cur_id = node.next;
    }
    out_prev.* = NullId;
    return NullId;
}

pub fn pushNodeToList(alloc: std.mem.Allocator, nodes: *std.ArrayListUnmanaged(Node), node_t: NodeType, start: u32) NodeId {
    const id = nodes.items.len;
    nodes.append(alloc, .{
        .node_t = node_t,
        .start_token = start,
        .next = NullId,
        .head = undefined,
    }) catch fatal();
    return @intCast(NodeId, id);
}

test "Parse dependency variables" {
    var parser = Parser.init(t.alloc);
    defer parser.deinit();

    var res = try parser.parseNoErr(
        \\foo
    );
    try t.eq(res.deps.size, 1);
    try t.eq(res.deps.contains("foo"), true);

    // Assign statement.
    res = try parser.parseNoErr(
        \\foo = 123
        \\foo
    );
    try t.eq(res.deps.size, 0);

    // Function call.
    res = try parser.parseNoErr(
        \\foo()
    );
    try t.eq(res.deps.size, 1);
    try t.eq(res.deps.contains("foo"), true);

    // Function call after declaration.
    t.setLogLevel(.debug);
    res = try parser.parseNoErr(
        \\fun foo():
        \\  // nop
        \\foo()
    );
    try t.eq(res.deps.size, 0);
}