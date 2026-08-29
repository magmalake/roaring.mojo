"""Shared constants and little-endian byte helpers for the Roaring "portable"
serialization format (RoaringFormatSpec) — used by both the 32-bit container
layer and the `Bitmap32`/`Bitmap64` assemblers.

Format recap (see https://github.com/RoaringBitmap/RoaringFormatSpec):
  - No run containers: 4-byte LE cookie `SERIAL_COOKIE_NO_RUNCONTAINER`
    (12346), 4-byte LE container count N, N x (2-byte LE key, 2-byte LE
    cardinality-1), N x 4-byte LE offset (always present), then container
    bodies back to back.
  - Has run containers: 4-byte LE value combining cookie `SERIAL_COOKIE`
    (12347) in the low 16 bits and (N-1) in the high 16 bits, a
    ceil(N/8)-byte bitset marking which containers are run containers, N x
    (2-byte LE key, 2-byte LE cardinality-1), then N x 4-byte LE offset
    UNLESS N < `NO_OFFSET_THRESHOLD` (in which case offsets are omitted),
    then container bodies.

Container promotion: an array container holds up to `ARRAY_MAX_CARDINALITY`
(4096) sorted UInt16 values (2 bytes each); above that it becomes a bitset
container (fixed `BITSET_BYTES` = 8192 bytes = 65536 bits). A run container
stores a 2-byte run count followed by that many (2-byte LE start, 2-byte LE
length-1) pairs, and is used only when `run_optimize()` finds it smaller.
"""

comptime SERIAL_COOKIE_NO_RUNCONTAINER: UInt32 = 12346
comptime SERIAL_COOKIE: UInt32 = 12347
comptime NO_OFFSET_THRESHOLD: Int = 4

comptime ARRAY_MAX_CARDINALITY: Int = 4096
comptime BITSET_WORDS: Int = 1024  # 1024 x 64-bit words = 65536 bits
comptime BITSET_BYTES: Int = 8192


def write_u16_le(mut buf: List[UInt8], v: UInt16):
    buf.append(UInt8(v & 0xFF))
    buf.append(UInt8((v >> 8) & 0xFF))


def write_u32_le(mut buf: List[UInt8], v: UInt32):
    buf.append(UInt8(v & 0xFF))
    buf.append(UInt8((v >> 8) & 0xFF))
    buf.append(UInt8((v >> 16) & 0xFF))
    buf.append(UInt8((v >> 24) & 0xFF))


def write_u64_le(mut buf: List[UInt8], v: UInt64):
    for i in range(8):
        buf.append(UInt8((v >> UInt64(8 * i)) & 0xFF))


def _check_bounds[origin: Origin, //](data: Span[UInt8, origin], pos: Int, width: Int) raises:
    if pos < 0 or pos + width > len(data):
        raise Error("roaring: truncated portable payload")


def read_u16_le[origin: Origin, //](data: Span[UInt8, origin], pos: Int) raises -> UInt16:
    _check_bounds(data, pos, 2)
    return UInt16(data[pos]) | (UInt16(data[pos + 1]) << 8)


def read_u32_le[origin: Origin, //](data: Span[UInt8, origin], pos: Int) raises -> UInt32:
    _check_bounds(data, pos, 4)
    var r: UInt32 = 0
    for i in range(4):
        r |= UInt32(data[pos + i]) << UInt32(8 * i)
    return r


def read_u64_le[origin: Origin, //](data: Span[UInt8, origin], pos: Int) raises -> UInt64:
    _check_bounds(data, pos, 8)
    var r: UInt64 = 0
    for i in range(8):
        r |= UInt64(data[pos + i]) << UInt64(8 * i)
    return r
