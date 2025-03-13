//! Base91 encoding and decoding
//!
//! Base91 is a binary-to-text encoding scheme that uses 91 different ASCII characters.
//! It is similar to Base64 but more space-efficient.

const std = @import("std");
const math = std.math;

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
/// The alphabet must be a slice of 91 characters.
/// The alphabet must not contain any duplicate characters.
/// The alphabet must not contain any characters that are NUL or not ASCII.
pub fn Base91(comptime alphabet: [91]u8) type {
    var observed = [_]bool{false} ** 256;
    for (alphabet) |c| {
        if (observed[c]) @compileError("duplicate character in alphabet");
        observed[c] = true;
        if (c == 0 or c > 127) @compileError("non-ASCII character in alphabet");
    }

    return struct {
        const none = 0xff;
        const inverse_map = inverseMap(alphabet);

        /// Given a source length, compute the upper bound of the encoded length
        pub fn calcSizeUpperBound(src_len: usize) usize {
            const input_bits = src_len * 8;
            const full_blocks = input_bits / 13;
            const remaining_bits = input_bits % 13;
            var out = full_blocks * 2;
            if (remaining_bits > 0) out += 2;
            return out;
        }

        /// Given an encoded length, compute the upper bound of the decoded length
        pub fn calcDecodedSizeUpperBound(encoded_len: usize) usize {
            const max_bits_per_pair = 14;
            const num_pairs = encoded_len / 2;
            var total_bits = num_pairs * max_bits_per_pair;
            if (encoded_len % 2 != 0) {
                total_bits += 7;
            }
            return math.divCeil(usize, total_bits, 8) catch unreachable;
        }

        /// Encode a byte slice into a base91 encoded byte slice
        ///
        /// The destination buffer must be large enough to hold the encoded data.
        /// The size of the destination buffer can be calculated using `calcSizeUpperBound`.
        /// The function returns the slice of the destination buffer that contains the encoded data.
        /// If the destination buffer is too small, the function returns `NoSpaceLeft`.
        pub fn encode(dst: []u8, src: []const u8) error{NoSpaceLeft}![]u8 {
            var al = std.io.fixedBufferStream(dst);
            var writer = al.writer();

            var acc: u32 = 0;
            var num_bits: u5 = 0;

            for (src) |x| {
                acc |= @as(@TypeOf(acc), x) << num_bits;
                num_bits += 8;
                if (num_bits > 13) {
                    var v = acc & 0x1fff;
                    if (v > 88) {
                        acc >>= 13;
                        num_bits -= 13;
                    } else {
                        v = acc & 0x3fff;
                        acc >>= 14;
                        num_bits -= 14;
                    }
                    writer.writeByte(alphabet[v % 91]) catch return error.NoSpaceLeft;
                    writer.writeByte(alphabet[v / 91]) catch return error.NoSpaceLeft;
                }
            }
            if (num_bits > 0) {
                writer.writeByte(alphabet[acc % 91]) catch return error.NoSpaceLeft;
                if (num_bits > 7 or acc > 90) {
                    writer.writeByte(alphabet[acc / 91]) catch return error.NoSpaceLeft;
                }
            }
            return al.buffer[0..al.pos];
        }

        /// Decode a base91 encoded byte slice into a byte slice
        /// The destination buffer must be large enough to hold the decoded data.
        /// The size of the destination buffer can be calculated using `calcDecodedSizeUpperBound`.
        /// The function returns the slice of the destination buffer that contains the decoded data.
        /// If the encoded data contains invalid characters, the function returns `InvalidCharacter`.
        /// If the encoded data contains invalid padding, the function returns `InvalidPadding`.
        /// If the destination buffer is too small, the function returns `NoSpaceLeft`.
        pub fn decode(dst: []u8, src: []const u8) Error![]u8 {
            var al = std.io.fixedBufferStream(dst);
            var writer = al.writer();

            var acc: ?u32 = null;
            var b: u32 = 0;
            var num_bits: u5 = 0;

            for (src) |x| {
                const c: u16 = @intCast(std.mem.indexOfScalar(u8, &alphabet, x) orelse return error.InvalidCharacter);
                if (acc) |acc_| {
                    const a = acc_ + c * 91;
                    b |= a << num_bits;
                    num_bits += if ((a & 0x1fff) > 88) 13 else 14;
                    while (true) {
                        writer.writeByte(@truncate(b)) catch return error.NoSpaceLeft;
                        b >>= 8;
                        num_bits -= 8;
                        if (num_bits <= 7) break;
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
            return al.buffer[0..al.pos];
        }

        fn inverseMap(forward_map: [91]u8) [256]u8 {
            var inverse = [_]u8{none} ** 256;
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

test {
    const codec = standard;

    var buf1: [256]u8 = undefined;
    var buf_encoded: [codec.calcSizeUpperBound(buf1.len)]u8 = undefined;
    var buf2: [codec.calcDecodedSizeUpperBound(buf_encoded.len)]u8 = undefined;

    std.crypto.random.bytes(&buf1);

    for (0..50000) |_| {
        const random_length = std.crypto.random.int(u8);
        const input_slice = buf1[0..random_length];

        const buf_encoded_slice = buf_encoded[0..codec.calcSizeUpperBound(random_length)];
        const encoded_slice = try codec.encode(buf_encoded_slice, input_slice);

        const buf_decoded_slice = buf2[0..codec.calcDecodedSizeUpperBound(encoded_slice.len)];
        const decoded_slice = try codec.decode(buf_decoded_slice, encoded_slice);
        std.debug.assert(std.mem.eql(u8, input_slice, decoded_slice));
    }
}
