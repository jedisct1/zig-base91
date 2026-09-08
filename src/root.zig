//! Base91 encoding and decoding
//!
//! Base91 is a binary-to-text encoding scheme that uses 91 different ASCII characters.
//! It is similar to Base64 but more space-efficient.

const std = @import("std");

const default_alphabet_chars: [91]u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&()*+,./:;<=>?@[]^_`{|}~\"".*;
const filesystem_alphabet_chars: [91]u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&()*+,.':;<=>?@[]^_`{|}~\"".*;

/// Base91 encoding and decoding with the default alphabet
pub const standard = Base91(default_alphabet_chars);

/// Base91 encoding and decoding with a filesystem-safe alphabet
///
/// This variant of Base91 uses an alphabet that is safe for use in filesystem paths.
/// It is similar to Base64URL but more space-efficient.
pub const filesystem = Base91(filesystem_alphabet_chars);

pub const Error = error{
    /// The encoded data contains invalid characters
    InvalidCharacter,
    /// The encoded data contains invalid padding
    InvalidPadding,
    /// The destination buffer is too small
    NoSpaceLeft,
};

/// Base91 encoding and decoding
///
/// Base91 is a binary-to-text encoding scheme that uses 91 different ASCII characters.
/// It is similar to Base64 but more space-efficient.
///
/// The alphabet must be 91 distinct ASCII characters other than NUL.
pub fn Base91(comptime alphabet: [91]u8) type {
    var observed: [256]bool = @splat(false);
    for (alphabet) |c| {
        if (observed[c]) @compileError("duplicate character in alphabet");
        observed[c] = true;
        if (c == 0 or c > 127) @compileError("non-ASCII character in alphabet");
    }

    return struct {
        const none = 0xff;
        const inverse_map = inverseMap(alphabet);

        // The largest 13-bit value that leaves room for a 14th bit in a pair of characters.
        const threshold = 91 * 91 - 8192 - 1;

        /// Given a source length, compute the upper bound of the encoded length
        ///
        /// A source made of `0xff` bytes reaches the bound.
        pub fn calcSizeUpperBound(src_len: usize) usize {
            // Thirteen bytes hold 104 bits, which is exactly eight pairs of 13 bits.
            const bits = src_len % 13 * 8;
            const pairs = src_len / 13 * 8 + bits / 13;
            const tail: usize = if (bits % 13 == 0) 0 else if (bits % 13 <= 6) 1 else 2;
            return pairs * 2 + tail;
        }

        /// Given an encoded length, compute the upper bound of the decoded length
        pub fn calcDecodedSizeUpperBound(encoded_len: usize) usize {
            const pairs = encoded_len / 2;
            return pairs / 4 * 7 + pairs % 4 * 7 / 4 + encoded_len % 2;
        }

        /// Encode a byte slice into a base91 encoded byte slice
        ///
        /// The destination buffer needs up to `calcSizeUpperBound(src.len)` bytes.
        /// The function returns the encoded slice of the destination buffer, or `NoSpaceLeft` if the buffer is too small.
        pub fn encode(dst: []u8, src: []const u8) error{NoSpaceLeft}![]u8 {
            var writer = std.Io.Writer.fixed(dst);

            var acc: u32 = 0;
            var num_bits: u5 = 0;

            for (src) |x| {
                const byte: u32 = x;
                acc |= byte << num_bits;
                num_bits += 8;
                if (num_bits > 13) {
                    const bits = pairBits(acc);
                    const v = if (bits == 13) acc & 0x1fff else acc & 0x3fff;
                    acc >>= bits;
                    num_bits -= bits;
                    writer.writeByte(alphabet[v % 91]) catch return error.NoSpaceLeft;
                    writer.writeByte(alphabet[v / 91]) catch return error.NoSpaceLeft;
                }
            }
            if (num_bits > 0) {
                writer.writeByte(alphabet[acc % 91]) catch return error.NoSpaceLeft;
                if (!fitsOneChar(num_bits, acc)) {
                    writer.writeByte(alphabet[acc / 91]) catch return error.NoSpaceLeft;
                }
            }
            return writer.buffered();
        }

        /// Decode a base91 encoded byte slice into a byte slice
        ///
        /// The destination buffer needs up to `calcDecodedSizeUpperBound(src.len)` bytes.
        /// The function returns the decoded slice of the destination buffer, or `NoSpaceLeft` if the buffer is too small.
        /// It returns `InvalidCharacter` for a character outside the alphabet, and `InvalidPadding` for trailing bits that do not form a byte.
        pub fn decode(dst: []u8, src: []const u8) Error![]u8 {
            var writer = std.Io.Writer.fixed(dst);

            var acc: ?u32 = null;
            var b: u32 = 0;
            var num_bits: u5 = 0;

            for (src) |x| {
                const c: u16 = inverse_map[x];
                if (c == none) return error.InvalidCharacter;
                if (acc) |acc_| {
                    const a = acc_ + c * 91;
                    b |= a << num_bits;
                    num_bits += pairBits(a);
                    while (num_bits >= 8) {
                        writer.writeByte(@truncate(b)) catch return error.NoSpaceLeft;
                        b >>= 8;
                        num_bits -= 8;
                    }
                    acc = null;
                } else {
                    acc = c;
                }
            }
            if (acc) |a| {
                const last = b | a << num_bits;
                if (last > 0xff) return error.InvalidPadding;
                writer.writeByte(@truncate(last)) catch return error.NoSpaceLeft;
            } else if (b != 0) {
                return error.InvalidPadding;
            }
            return writer.buffered();
        }

        /// The number of input bits that a pair of characters holds for this value
        fn pairBits(v: u32) u5 {
            return if ((v & 0x1fff) > threshold) 13 else 14;
        }

        /// Whether the encoder writes a single character for this tail
        fn fitsOneChar(tail_bits: u5, tail: u32) bool {
            return tail_bits <= 7 and tail < 91;
        }

        fn inverseMap(forward_map: [91]u8) [256]u8 {
            var inverse: [256]u8 = @splat(none);
            for (forward_map, 0..) |c, i| {
                inverse[c] = i;
            }
            return inverse;
        }
    };
}

test {
    _ = standard;
    _ = filesystem;
}

fn testRoundTrip(comptime codec: type, input: []const u8) !void {
    var buf_encoded: [codec.calcSizeUpperBound(256)]u8 = undefined;
    var buf_decoded: [codec.calcDecodedSizeUpperBound(buf_encoded.len)]u8 = undefined;

    const encoded = try codec.encode(buf_encoded[0..codec.calcSizeUpperBound(input.len)], input);
    const decoded = try codec.decode(buf_decoded[0..codec.calcDecodedSizeUpperBound(encoded.len)], encoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "random round trips" {
    var buf: [256]u8 = undefined;

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    for (0..50000) |_| {
        random.bytes(&buf);
        const len = random.int(u8);
        try testRoundTrip(standard, buf[0..len]);
        try testRoundTrip(filesystem, buf[0..len]);
    }
}

test "round trips of all inputs of up to two bytes" {
    const all_bytes: [256]u8 = std.simd.iota(u8, 256);
    try testRoundTrip(standard, "");
    for (all_bytes) |a| {
        try testRoundTrip(standard, &.{a});
        for (all_bytes) |b| {
            try testRoundTrip(standard, &.{ a, b });
        }
    }
}

fn testVector(comptime codec: type, decoded: []const u8, encoded: []const u8) !void {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(encoded, try codec.encode(&buf, decoded));
    try std.testing.expectEqualSlices(u8, decoded, try codec.decode(&buf, encoded));
    try std.testing.expect(codec.calcSizeUpperBound(decoded.len) >= encoded.len);
    try std.testing.expect(codec.calcDecodedSizeUpperBound(encoded.len) >= decoded.len);
}

test "vectors" {
    // The expected strings come from the Python `base91` package.
    try testVector(standard, "", "");
    try testVector(standard, "M", "=A");
    try testVector(standard, "Ma", "8DD");
    try testVector(standard, "Man", "8D$J");
    try testVector(standard, "Man ", "8D$JI");
    try testVector(standard, "Hello, World!", ">OwJh>}AQ;r@@Y?F");
    try testVector(standard, "\x00", "AA");
    try testVector(standard, "\xff", "/C");
    try testVector(standard, "\xff\xff\xff\xff", "B\"B\"#");
    try testVector(standard, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f", ":C#(:C?hVB$MSiVEwndB");
    try testVector(
        standard,
        "The quick brown fox jumps over the lazy dog.",
        "nX^Iz?T1s!2t:aRn#o>vf>6C9#`##mlLK#_1:Wzv;RG!,a%q3Lc=5gA",
    );
}

test "errors" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidCharacter, standard.decode(&buf, "8D-J"));
    try std.testing.expectError(error.InvalidCharacter, standard.decode(&buf, "8D J"));
    try std.testing.expectError(error.InvalidCharacter, standard.decode(&buf, "8D\x00J"));
    try std.testing.expectError(error.InvalidPadding, standard.decode(&buf, "AAI"));
    try std.testing.expectError(error.InvalidPadding, standard.decode(&buf, "A#"));
    try std.testing.expectError(error.NoSpaceLeft, standard.decode(buf[0..3], "8D$JI"));
    try std.testing.expectError(error.NoSpaceLeft, standard.decode(buf[0..0], "AA"));
    try std.testing.expectError(error.NoSpaceLeft, standard.encode(buf[0..4], "Man "));
    try std.testing.expectError(error.NoSpaceLeft, standard.encode(buf[0..0], "M"));
}

test "size computations" {
    try std.testing.expectEqual(0, standard.calcSizeUpperBound(0));
    try std.testing.expectEqual(2, standard.calcSizeUpperBound(1));
    try std.testing.expectEqual(3, standard.calcSizeUpperBound(2));
    try std.testing.expectEqual(4, standard.calcSizeUpperBound(3));
    try std.testing.expectEqual(5, standard.calcSizeUpperBound(4));
    try std.testing.expectEqual(16, standard.calcSizeUpperBound(13));
    try std.testing.expectEqual(0, standard.calcDecodedSizeUpperBound(0));
    try std.testing.expectEqual(1, standard.calcDecodedSizeUpperBound(2));
    try std.testing.expectEqual(2, standard.calcDecodedSizeUpperBound(3));
    try std.testing.expectEqual(3, standard.calcDecodedSizeUpperBound(4));
    try std.testing.expectEqual(5, standard.calcDecodedSizeUpperBound(6));

    // A source of 0xff bytes reaches the bound.
    const buf: [64]u8 = @splat(0xff);
    var encoded_buf: [standard.calcSizeUpperBound(buf.len)]u8 = undefined;
    for (0..buf.len + 1) |len| {
        const encoded = try standard.encode(&encoded_buf, buf[0..len]);
        try std.testing.expectEqual(standard.calcSizeUpperBound(len), encoded.len);
    }

    // The bounds must not overflow as long as the result fits in a `usize`.
    const max = std.math.maxInt(usize);
    try std.testing.expectEqual(max - 15, standard.calcSizeUpperBound(max / 16 * 13));
    try std.testing.expect(standard.calcDecodedSizeUpperBound(max) >= max / 2);
}
