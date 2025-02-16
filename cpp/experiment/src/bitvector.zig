const std = @import("std");

pub fn BitVector(comptime T: type) type {
    const typeInfo = @typeInfo(T);
    const bits: u16 = switch (typeInfo) {
        .Int => |i| i.bits,
        // TODO: wrapping/unwrapping the tags is annoying so I didn't implement it yet, but it'd be nice to have.
        // .Enum => |e| @typeInfo(e.tag_type).Int.bits,
        else => @compileError("Unsupported BitVector type: " ++ @typeName(T)),
    };
    const elementsPerByte: usize = 8 / bits;

    comptime {
        if (bits == 0 or bits >= 8)
            @compileError("Bits must be between 1 and 7 inclusive");
    }

    return struct {
        allocator: std.mem.Allocator,
        data: std.ArrayList(u8),
        elementCount: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .allocator = allocator,
                .data = std.ArrayList(u8).init(allocator),
                .elementCount = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.data.deinit();
        }

        fn calculateBitOffset(index: usize) usize {
            const elemsPerByte = elementsPerByte;
            const group = index / elemsPerByte;
            const posInGroup = @mod(index, elemsPerByte);
            return group * 8 + posInGroup * bits;
        }

        /// Returns the number of elements stored.
        pub fn len(self: *Self) usize {
            return self.elementCount;
        }

        pub fn ensureCapacity(self: *Self, cap: usize) std.mem.Allocator.Error!void {
            const bitOffset: usize = calculateBitOffset(self.elementCount + cap);
            const byteIndex: usize = bitOffset / 8;
            try self.data.ensureTotalCapacity(byteIndex);
        }

        pub fn appendNTimes(self: *Self, value: T, nElems: usize) !void {
            var n = nElems;
            try self.ensureCapacity(n);

            // Handle not being byte aligned.
            if (@mod(self.elementCount, elementsPerByte) != 0) {
                const remainingElems = elementsPerByte - @mod(n, elementsPerByte);
                for (0..remainingElems) |_| {
                    try self.append(value);
                    n -= 1;
                }
                if (n == 0) {
                    return;
                }
            }

            const startByte: usize = calculateBitOffset(self.elementCount) / 8;
            const endByte: usize = calculateBitOffset(self.elementCount + n) / 8;
            const remainingBitLen = @mod(n, elementsPerByte);
            var saturatedByte: u8 = 0;
            inline for (0..elementsPerByte) |i| {
                const offset: std.math.Log2Int(u8) = comptime @intCast(@mod(calculateBitOffset(i), 8));
                saturatedByte |= (@as(u8, @intCast(value)) << @intCast(offset));
            }
            try self.data.appendNTimes(saturatedByte, endByte - startByte);
            self.elementCount += elementsPerByte * (endByte - startByte);

            // Handle not being byte aligned at the end.
            for (0..remainingBitLen) |_| {
                try self.append(value);
            }
        }

        pub fn deleteLastN(self: *Self, n: usize) void {
            if (n == 0) return;
            self.elementCount -= n;
        }

        pub fn append(self: *Self, value: T) !void {
            const bitOffset: usize = calculateBitOffset(self.elementCount);
            const byteIndex: usize = bitOffset / 8;
            const bitIndex: std.math.Log2Int(u8) = @intCast(@mod(bitOffset, 8));

            // Ensure that our underlying storage has enough bytes.
            while (byteIndex >= self.data.items.len) {
                try self.data.append(0);
            }

            const mask = @as(u8, (1 << bits) - 1) << bitIndex;
            self.data.items[byteIndex] &= ~mask;
            self.data.items[byteIndex] |= (@as(u8, value) & ((1 << bits) - 1)) << bitIndex;
            self.elementCount += 1;
        }

        pub fn get(self: *Self, index: usize) T {
            const bitOffset = calculateBitOffset(index);
            const byteIndex = bitOffset / 8;
            const bitIndex: std.math.Log2Int(u8) = @intCast(@mod(bitOffset, 8));
            const result: u8 = (self.data.items[byteIndex] >> bitIndex) & ((1 << bits) - 1);
            return @intCast(result);
        }

        pub fn set(self: *Self, index: usize, value: T) void {
            const bitOffset: usize = calculateBitOffset(index);
            const byteIndex: usize = bitOffset / 8;
            const bitIndex: std.math.Log2Int(u8) = @intCast(@mod(bitOffset, 8));
            const mask = @as(u8, (1 << bits) - 1) << bitIndex;
            self.data.items[byteIndex] &= ~mask;
            self.data.items[byteIndex] |= (@as(u8, value) & ((1 << bits) - 1)) << bitIndex;
        }
    };
}

//
// ==============================
//           TESTS BELOW
// ==============================
//

// These tests assume that you have defined custom types like u3 and u4
// that represent unsigned integers with 3 or 4 bits respectively.
// For the purpose of these tests, we’ll assume such types are available.

test "BitVector push and get with 3-bit elements" {
    var bv = try BitVector(u3).init(std.testing.allocator);
    defer bv.deinit();

    // For 3-bit elements, valid values are 0 .. 7.
    try bv.append(3);
    try bv.append(5);
    try bv.append(7);
    try std.testing.expectEqual(3, bv.len());
    try std.testing.expectEqual(3, bv.get(0));
    try std.testing.expectEqual(5, bv.get(1));
    try std.testing.expectEqual(7, bv.get(2));

    try std.testing.expectEqual(2, bv.data.items.len);
}

test "BitVector set modifies an element (4-bit elements)" {
    var bv = try BitVector(u4).init(std.testing.allocator);
    defer bv.deinit();

    // For 4-bit elements, valid values are 0 .. 15.
    try bv.append(1);
    try bv.append(2);
    try bv.append(3);
    try std.testing.expect(bv.get(1) == 2);
    bv.set(1, 7);
    try std.testing.expect(bv.get(1) == 7);

    try std.testing.expectEqual(2, bv.data.items.len);
}

test "BitVector push and get with 1-bit elements" {
    // For 1-bit elements, valid values are 0 and 1.
    var bv = try BitVector(u1).init(std.testing.allocator);
    defer bv.deinit();

    try bv.append(1);
    try bv.append(0);
    try bv.append(1);
    try bv.append(1);

    try std.testing.expectEqual(4, bv.len());
    try std.testing.expectEqual(1, bv.data.items.len);

    try std.testing.expectEqual(1, bv.get(0));
    try std.testing.expectEqual(0, bv.get(1));
    try std.testing.expectEqual(1, bv.get(2));
    try std.testing.expectEqual(1, bv.get(3));

    // Since 1-bit elements pack 8 per byte, 4 elements should be stored in 1 byte.
    try std.testing.expectEqual(1, bv.data.items.len);
}

test "BitVector push beyond one byte with 1-bit elements" {
    // Push 9 elements so that the 9th bit forces allocation of a second byte.
    var bv = try BitVector(u1).init(std.testing.allocator);
    defer bv.deinit();

    for (0..9) |i| {
        // Alternate between 0 and 1.
        try bv.append(@intCast(i & 1));
    }
    try std.testing.expectEqual(9, bv.len());
    // With 9 bits we expect at least 2 underlying bytes.
    try std.testing.expect(bv.data.items.len >= 2);
}

test "BitVector push many elements with 2-bit elements" {
    // For 2-bit elements, valid values are 0 .. 3.
    var bv = try BitVector(u2).init(std.testing.allocator);
    defer bv.deinit();

    // Prepare an array of 10 elements.
    const values: [10]u2 = [_]u2{ 0, 1, 2, 3, 0, 1, 2, 3, 2, 1 };
    for (values) |val| {
        try bv.append(val);
    }
    try std.testing.expectEqual(10, bv.len());
    for (values, 0..) |val, idx| {
        try std.testing.expectEqual(val, bv.get(idx));
    }
    // 10 elements * 2 bits = 20 bits, which should take ceil(20/8)=3 bytes.
    try std.testing.expectEqual(3, bv.data.items.len);
}

test "BitVector push and get with 7-bit elements" {
    // For 7-bit elements, valid values are 0 .. 127.
    var bv = try BitVector(u7).init(std.testing.allocator);
    defer bv.deinit();

    try bv.append(10);
    try bv.append(64);
    try bv.append(127);
    try std.testing.expectEqual(3, bv.len());
    try std.testing.expectEqual(10, bv.get(0));
    try std.testing.expectEqual(64, bv.get(1));
    try std.testing.expectEqual(127, bv.get(2));

    // For u7, wasted = 8 - ((8/7)*7) = 1 so each element occupies 7+1=8 bits.
    // Each pushed element should therefore reside in its own byte.
    try std.testing.expectEqual(3, bv.data.items.len);
}

test "BitVector set modifies value correctly with 2-bit elements" {
    // Test that set updates the stored value without affecting others.
    var bv = try BitVector(u2).init(std.testing.allocator);
    defer bv.deinit();

    // Initially push four 2-bit values.
    try bv.append(0);
    try bv.append(1);
    try bv.append(2);
    try bv.append(3);

    // Modify some elements.
    bv.set(0, 3);
    bv.set(2, 1);

    try std.testing.expectEqual(3, bv.get(0));
    try std.testing.expectEqual(1, bv.get(1)); // Unchanged.
    try std.testing.expectEqual(1, bv.get(2));
    try std.testing.expectEqual(3, bv.get(3));
}

test "BitVector push and get boundary test with 4-bit elements" {
    var bv = try BitVector(u4).init(std.testing.allocator);
    defer bv.deinit();

    // For 4-bit elements, two elements pack exactly into one byte.
    try bv.append(1);
    try bv.append(2);
    try std.testing.expectEqual(2, bv.len());
    try std.testing.expectEqual(1, bv.get(0));
    try std.testing.expectEqual(2, bv.get(1));
    try std.testing.expectEqual(1, bv.data.items.len);

    // Pushing a third element should force allocation of a new byte.
    try bv.append(3);
    try std.testing.expectEqual(3, bv.len());
    try std.testing.expectEqual(3, bv.get(2));
    try std.testing.expect(bv.data.items.len >= 2);
}

test "BitVector random fuzz test with 1-bit elements (u1)" {
    try fuzzTest(u1, 98765, 10_000);
}

test "BitVector heavy random fuzz test with 2-bit elements (u2)" {
    // Push 50,000 elements to stress the storage allocation.
    try fuzzTest(u2, 13579, 50_000);
}

test "BitVector random fuzz test with 3-bit elements (u3)" {
    try fuzzTest(u3, 12345, 10_000);
}

test "BitVector random fuzz test with 4-bit elements (u4)" {
    try fuzzTest(u4, 54321, 10_000);
}

test "BitVector random fuzz test with 7-bit elements (u7)" {
    try fuzzTest(u7, 24680, 10_000);
}

/// A helper function to fuzz-test a BitVector with random pushes and updates.
///
/// - `T`: the element type (e.g. u1, u2, u3, etc).
/// - `rngSeed`: seed for the random generator.
/// - `count`: total number of random elements to push.
/// - `maxValue`: the maximum value allowed (e.g. 7 for u3, 15 for u4, etc).
fn fuzzTest(comptime T: type, rngSeed: u64, count: usize) !void {
    const maxValue = std.math.maxInt(T);
    const allocator = std.testing.allocator;
    var bv = try BitVector(T).init(allocator);
    defer bv.deinit();

    var rng = std.rand.DefaultPrng.init(rngSeed);
    // Allocate an array to record expected values.
    var expected = try allocator.alloc(u64, count);
    defer allocator.free(expected);

    // Push 'count' random values into the BitVector.
    for (0..count) |i| {
        // Generate a random value between 0 and maxValue (inclusive).
        const value = rng.random().uintAtMost(u64, maxValue);
        expected[i] = value;
        try bv.append(@intCast(value));
    }

    // Verify that every value read from the BitVector matches what was pushed.
    for (0..count) |i| {
        try std.testing.expectEqual(expected[i], @as(u64, @intCast(bv.get(i))));
    }

    // Now perform a series of random updates (using set) on roughly 10% of the entries.
    const updateCount = count / 10;
    for (0..updateCount) |_| {
        const idx = rng.random().uintAtMost(usize, count);
        const value = rng.random().uintAtMost(u64, maxValue);
        expected[idx] = value;
        bv.set(idx, @intCast(value));
    }

    // Verify that after the updates, all values are still correct.
    for (0..count) |i| {
        try std.testing.expectEqual(expected[i], @as(u64, @intCast(bv.get(i))));
    }
}

//
// ==============================
//  TESTS FOR appendNTimes BELOW
// ==============================
//
// (These tests assume that you’ve defined custom types such as u1, u2, u3, u4, and u7.
//  For testing purposes, you can imagine these are simply aliases for unsigned integers
//  constrained to the appropriate bit-width.)
//

test "appendNTimes on empty vector (aligned count, u2)" {
    // For u2, valid values: 0..3, and elementsPerByte = 8 / 2 = 4.
    var bv = try BitVector(u2).init(std.testing.allocator);
    defer bv.deinit();

    // Append 8 elements; 8 is a multiple of 4 so we expect two full bytes.
    try bv.appendNTimes(2, 8);
    try std.testing.expectEqual(8, bv.len());
    for (0..8) |i| {
        try std.testing.expectEqual(2, bv.get(i));
    }
    try std.testing.expectEqual(2, bv.data.items.len);
}

test "appendNTimes on empty vector (non-aligned count, u2)" {
    // For u2, elementsPerByte = 4.
    var bv = try BitVector(u2).init(std.testing.allocator);
    defer bv.deinit();

    // Append 5 elements; expect one full byte (4 elements) and one extra element in a new byte.
    try bv.appendNTimes(1, 5);
    try std.testing.expectEqual(5, bv.len());
    for (0..5) |i| {
        try std.testing.expectEqual(1, bv.get(i));
    }
    // Underlying storage: 2 bytes (first byte completely filled, second only partially).
    try std.testing.expectEqual(2, bv.data.items.len);
}

test "appendNTimes on partially filled vector (u4)" {
    // For u4, valid values: 0..15 and elementsPerByte = 8 / 4 = 2.
    var bv = try BitVector(u4).init(std.testing.allocator);
    defer bv.deinit();

    // Append one element normally; now the vector is not byte-aligned.
    try bv.append(5);
    // Now use appendNTimes to add 3 more elements.
    // Expected behavior:
    //  - One element is added to fill the first byte (bringing count to 2).
    //  - Then 3-1 = 2 elements remain; since u4 packs 2 per byte, these are added in one bulk append.
    try bv.appendNTimes(9, 3);
    try std.testing.expectEqual(4, bv.len());
    try std.testing.expectEqual(5, bv.get(0));
    try std.testing.expectEqual(9, bv.get(1));
    try std.testing.expectEqual(9, bv.get(2));
    try std.testing.expectEqual(9, bv.get(3));
    // Underlying data: should now be 2 bytes.
    try std.testing.expectEqual(2, bv.data.items.len);
}

test "appendNTimes with 0 elements (u2)" {
    var bv = try BitVector(u2).init(std.testing.allocator);
    defer bv.deinit();

    try bv.appendNTimes(3, 0);
    try std.testing.expectEqual(0, bv.len());
    try std.testing.expectEqual(0, bv.data.items.len);
}

test "appendNTimes with u1" {
    // For u1, valid values: 0 and 1, elementsPerByte = 8.
    var bv = try BitVector(u1).init(std.testing.allocator);
    defer bv.deinit();

    // Append 10 elements. That is 1 full byte (8 elements) plus 2 extra.
    try bv.appendNTimes(1, 10);
    try std.testing.expectEqual(10, bv.len());
    for (0..10) |i| {
        try std.testing.expectEqual(1, bv.get(i));
    }
    try std.testing.expectEqual(2, bv.data.items.len);
}

test "appendNTimes with u7" {
    // For u7, valid values: 0..127, and elementsPerByte = 8 / 7 = 1.
    var bv = try BitVector(u7).init(std.testing.allocator);
    defer bv.deinit();

    // Since only one u7 fits in a byte, a bulk append simply appends that many bytes.
    try bv.appendNTimes(65, 5);
    try std.testing.expectEqual(5, bv.len());
    for (0..5) |i| {
        try std.testing.expectEqual(65, bv.get(i));
    }
    try std.testing.expectEqual(5, bv.data.items.len);
}

test "Mixing append and appendNTimes (u3)" {
    // For u3, valid values: 0..7, elementsPerByte = 8 / 3 = 2.
    var bv = try BitVector(u3).init(std.testing.allocator);
    defer bv.deinit();

    // Append one element normally.
    try bv.append(1);
    // Then use appendNTimes to add 3 elements.
    try bv.appendNTimes(7, 3);
    // Expected: element 0 is 1; then the next 3 are 7.
    try std.testing.expectEqual(4, bv.len());
    try std.testing.expectEqual(1, bv.get(0));
    try std.testing.expectEqual(7, bv.get(1));
    try std.testing.expectEqual(7, bv.get(2));
    try std.testing.expectEqual(7, bv.get(3));
}
