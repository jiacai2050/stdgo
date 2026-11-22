//! Package text/scanner provides a lexical scanner and tokenizer for UTF-8-encoded text.
//!
//! Takes text input and splits it into tokens (ident, int, float, char, string, raw string,
//! comment),
//! accurately reporting the file, line, and column position of each token.

const std = @import("std");
const mem = std.mem;

/// Token represents lexical token types recognized by the scanner.
pub const Token = enum(i32) {
    eof = -1,
    ident = -2,
    int = -3,
    float = -4,
    char = -5,
    string = -6,
    raw_string = -7,
    comment = -8,
    other = 0,
};

/// Position represents a source position within scanned text.
pub const Position = struct {
    filename: []const u8 = "",
    offset: usize = 0,
    line: usize = 1,
    column: usize = 1,
};

pub const ScanIdents: u32 = 1 << 0;
pub const ScanInts: u32 = 1 << 1;
pub const ScanFloats: u32 = 1 << 2;
pub const ScanChars: u32 = 1 << 3;
pub const ScanStrings: u32 = 1 << 4;
pub const ScanRawStrings: u32 = 1 << 5;
pub const ScanComments: u32 = 1 << 6;
pub const SkipComments: u32 = 1 << 7;

/// GoTokens enables all standard Go lexical token types.
pub const GoTokens: u32 = ScanIdents | ScanInts | ScanFloats | ScanChars | ScanStrings |
    ScanRawStrings | ScanComments | SkipComments;

/// Scanner holds the state for tokenizing UTF-8 text.
pub const Scanner = struct {
    src: []const u8,
    pos_idx: usize = 0,
    tok_start: usize = 0,
    tok_end: usize = 0,
    cur_tok: Token = .eof,
    tok_char: u8 = 0,
    mode: u32 = GoTokens,
    position: Position = .{},

    pub fn init(src: []const u8) Scanner {
        return .{
            .src = src,
        };
    }

    pub fn pos(self: Scanner) Position {
        return self.position;
    }

    pub fn tokenText(self: Scanner) []const u8 {
        return self.src[self.tok_start..self.tok_end];
    }

    pub fn character(self: Scanner) u8 {
        return self.tok_char;
    }

    pub fn scan(self: *Scanner) Token {
        while (true) {
            self.skipWhitespace();

            if (self.pos_idx >= self.src.len) {
                self.cur_tok = .eof;
                self.tok_start = self.pos_idx;
                self.tok_end = self.pos_idx;
                return .eof;
            }

            self.tok_start = self.pos_idx;
            const c = self.src[self.pos_idx];

            // Comments: // or /*
            if (c == '/' and self.pos_idx + 1 < self.src.len) {
                const next = self.src[self.pos_idx + 1];
                if (next == '/') {
                    self.consumeSingleComment();
                    if ((self.mode & SkipComments) != 0) continue;
                    self.tok_end = self.pos_idx;
                    self.cur_tok = .comment;
                    return .comment;
                } else if (next == '*') {
                    self.consumeMultiComment();
                    if ((self.mode & SkipComments) != 0) continue;
                    self.tok_end = self.pos_idx;
                    self.cur_tok = .comment;
                    return .comment;
                }
            }

            // Identifiers: [a-zA-Z_]
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
                self.consumeIdent();
                self.tok_end = self.pos_idx;
                self.cur_tok = .ident;
                return .ident;
            }

            // Numbers: [0-9]
            if (c >= '0' and c <= '9') {
                const is_float = self.consumeNumber();
                self.tok_end = self.pos_idx;
                self.cur_tok = if (is_float) .float else .int;
                return self.cur_tok;
            }

            // Strings: "..."
            if (c == '"') {
                self.consumeString();
                self.tok_end = self.pos_idx;
                self.cur_tok = .string;
                return .string;
            }

            // Raw strings: `...`
            if (c == '`') {
                self.consumeRawString();
                self.tok_end = self.pos_idx;
                self.cur_tok = .raw_string;
                return .raw_string;
            }

            // Chars: '...'
            if (c == '\'') {
                self.consumeChar();
                self.tok_end = self.pos_idx;
                self.cur_tok = .char;
                return .char;
            }

            // Single punctuation / operator char
            self.advance();
            self.tok_end = self.pos_idx;
            self.tok_char = c;
            self.cur_tok = .other;
            return .other;
        }
    }

    fn advance(self: *Scanner) void {
        if (self.pos_idx < self.src.len) {
            const c = self.src[self.pos_idx];
            self.pos_idx += 1;
            self.position.offset += 1;
            if (c == '\n') {
                self.position.line += 1;
                self.position.column = 1;
            } else {
                self.position.column += 1;
            }
        }
    }

    fn skipWhitespace(self: *Scanner) void {
        while (self.pos_idx < self.src.len) {
            const c = self.src[self.pos_idx];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn consumeIdent(self: *Scanner) void {
        while (self.pos_idx < self.src.len) {
            const c = self.src[self.pos_idx];
            const is_ident = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_';
            if (is_ident) {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn consumeNumber(self: *Scanner) bool {
        var is_float = false;

        // Base prefix: 0x, 0b, 0o
        if (self.src[self.pos_idx] == '0' and self.pos_idx + 1 < self.src.len) {
            const next = self.src[self.pos_idx + 1];
            if (next == 'x' or next == 'X' or next == 'b' or
                next == 'B' or next == 'o' or next == 'O')
            {
                self.advance();
                self.advance();
                while (self.pos_idx < self.src.len) {
                    const c = self.src[self.pos_idx];
                    const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or
                        (c >= 'A' and c <= 'F') or c == '_';
                    if (is_hex) {
                        self.advance();
                    } else {
                        break;
                    }
                }
                return false;
            }
        }

        while (self.pos_idx < self.src.len) {
            const c = self.src[self.pos_idx];
            if (c >= '0' and c <= '9') {
                self.advance();
            } else if (c == '.') {
                if (self.pos_idx + 1 < self.src.len and
                    self.src[self.pos_idx + 1] >= '0' and
                    self.src[self.pos_idx + 1] <= '9')
                {
                    is_float = true;
                    self.advance();
                } else {
                    break;
                }
            } else if (c == 'e' or c == 'E') {
                is_float = true;
                self.advance();
                if (self.pos_idx < self.src.len and
                    (self.src[self.pos_idx] == '+' or self.src[self.pos_idx] == '-'))
                {
                    self.advance();
                }
            } else if (c == '_') {
                self.advance();
            } else {
                break;
            }
        }
        return is_float;
    }

    fn consumeString(self: *Scanner) void {
        self.advance(); // skip opening "
        while (self.pos_idx < self.src.len) {
            const c = self.src[self.pos_idx];
            if (c == '"') {
                self.advance();
                break;
            } else if (c == '\\') {
                self.advance(); // skip backslash
                if (self.pos_idx < self.src.len) self.advance(); // skip escaped char
            } else {
                self.advance();
            }
        }
    }

    fn consumeRawString(self: *Scanner) void {
        self.advance(); // skip opening `
        while (self.pos_idx < self.src.len) {
            const c = self.src[self.pos_idx];
            if (c == '`') {
                self.advance();
                break;
            } else {
                self.advance();
            }
        }
    }

    fn consumeChar(self: *Scanner) void {
        self.advance(); // skip opening '
        while (self.pos_idx < self.src.len) {
            const c = self.src[self.pos_idx];
            if (c == '\'') {
                self.advance();
                break;
            } else if (c == '\\') {
                self.advance();
                if (self.pos_idx < self.src.len) self.advance();
            } else {
                self.advance();
            }
        }
    }

    fn consumeSingleComment(self: *Scanner) void {
        while (self.pos_idx < self.src.len and self.src[self.pos_idx] != '\n') {
            self.advance();
        }
    }

    fn consumeMultiComment(self: *Scanner) void {
        self.advance(); // /
        self.advance(); // *
        while (self.pos_idx + 1 < self.src.len) {
            if (self.src[self.pos_idx] == '*' and self.src[self.pos_idx + 1] == '/') {
                self.advance();
                self.advance();
                break;
            }
            self.advance();
        }
    }
};

test "text/scanner tokenizes Go source code" {
    const testing = std.testing;

    const src =
        \\// package declaration
        \\package main
        \\
        \\import "fmt"
        \\
        \\func main() {
        \\    const pi = 3.14159
        \\    var count = 42
        \\    var hex = 0xff
        \\    var ch = 'Z'
        \\    var msg = `hello
        \\world`
        \\}
    ;

    var s = Scanner.init(src);

    // 1. package
    try testing.expectEqual(Token.ident, s.scan());
    try testing.expectEqualStrings("package", s.tokenText());

    // 2. main
    try testing.expectEqual(Token.ident, s.scan());
    try testing.expectEqualStrings("main", s.tokenText());

    // 3. import
    try testing.expectEqual(Token.ident, s.scan());
    try testing.expectEqualStrings("import", s.tokenText());

    // 4. "fmt"
    try testing.expectEqual(Token.string, s.scan());
    try testing.expectEqualStrings("\"fmt\"", s.tokenText());

    // 5. func
    try testing.expectEqual(Token.ident, s.scan());
    try testing.expectEqualStrings("func", s.tokenText());

    // 6. main
    try testing.expectEqual(Token.ident, s.scan());
    try testing.expectEqualStrings("main", s.tokenText());

    // 7. (
    try testing.expectEqual(Token.other, s.scan());
    try testing.expectEqual(@as(u8, '('), s.character());

    // 8. )
    try testing.expectEqual(Token.other, s.scan());
    try testing.expectEqual(@as(u8, ')'), s.character());

    // 9. {
    try testing.expectEqual(Token.other, s.scan());
    try testing.expectEqual(@as(u8, '{'), s.character());

    // 10. const
    try testing.expectEqual(Token.ident, s.scan());
    try testing.expectEqualStrings("const", s.tokenText());

    // 11. pi
    try testing.expectEqual(Token.ident, s.scan());
    try testing.expectEqualStrings("pi", s.tokenText());

    // 12. =
    try testing.expectEqual(Token.other, s.scan());
    try testing.expectEqual(@as(u8, '='), s.character());

    // 13. 3.14159 (float)
    try testing.expectEqual(Token.float, s.scan());
    try testing.expectEqualStrings("3.14159", s.tokenText());

    // 14. var
    try testing.expectEqual(Token.ident, s.scan());
    // 15. count
    try testing.expectEqual(Token.ident, s.scan());
    // 16. =
    try testing.expectEqual(Token.other, s.scan());
    // 17. 42 (int)
    try testing.expectEqual(Token.int, s.scan());
    try testing.expectEqualStrings("42", s.tokenText());

    // 18. var
    try testing.expectEqual(Token.ident, s.scan());
    // 19. hex
    try testing.expectEqual(Token.ident, s.scan());
    // 20. =
    try testing.expectEqual(Token.other, s.scan());
    // 21. 0xff (int)
    try testing.expectEqual(Token.int, s.scan());
    try testing.expectEqualStrings("0xff", s.tokenText());

    // 22. var
    try testing.expectEqual(Token.ident, s.scan());
    // 23. ch
    try testing.expectEqual(Token.ident, s.scan());
    // 24. =
    try testing.expectEqual(Token.other, s.scan());
    // 25. 'Z' (char)
    try testing.expectEqual(Token.char, s.scan());
    try testing.expectEqualStrings("'Z'", s.tokenText());

    // 26. var
    try testing.expectEqual(Token.ident, s.scan());
    // 27. msg
    try testing.expectEqual(Token.ident, s.scan());
    // 28. =
    try testing.expectEqual(Token.other, s.scan());
    // 29. `hello\nworld` (raw string)
    try testing.expectEqual(Token.raw_string, s.scan());

    // 30. }
    try testing.expectEqual(Token.other, s.scan());
    try testing.expectEqual(@as(u8, '}'), s.character());

    // 31. EOF
    try testing.expectEqual(Token.eof, s.scan());
}
