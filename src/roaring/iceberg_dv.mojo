"""Apache Iceberg "deletion vector v1" blob framing
(https://iceberg.apache.org/puffin-spec/#deletion-vector-v1-blob-type):

    4 bytes            length of (magic + vector), big-endian
    4 bytes            magic: D1 D3 39 64
    <length - 4> bytes the 64-bit portable Roaring vector
    4 bytes            CRC-32 (standard, as in gzip) over (magic + vector),
                       big-endian

Row positions in a data file are `UInt64`, so the vector is a `Bitmap64`."""

from .bitmap64 import Bitmap64
from .crc32 import crc32

comptime _DV_MAGIC_0: UInt8 = 0xD1
comptime _DV_MAGIC_1: UInt8 = 0xD3
comptime _DV_MAGIC_2: UInt8 = 0x39
comptime _DV_MAGIC_3: UInt8 = 0x64


def encode_iceberg_dv(bitmap: Bitmap64) raises -> List[UInt8]:
    """Encode `bitmap` as a framed Iceberg deletion-vector v1 blob."""
    var vector = bitmap.serialize_portable()

    var body = List[UInt8]()
    body.append(_DV_MAGIC_0)
    body.append(_DV_MAGIC_1)
    body.append(_DV_MAGIC_2)
    body.append(_DV_MAGIC_3)
    body.extend(vector^)

    var crc = crc32(Span(body))
    var length = UInt32(len(body))

    var out = List[UInt8]()
    out.append(UInt8((length >> 24) & 0xFF))
    out.append(UInt8((length >> 16) & 0xFF))
    out.append(UInt8((length >> 8) & 0xFF))
    out.append(UInt8(length & 0xFF))
    out.extend(body^)
    out.append(UInt8((crc >> 24) & 0xFF))
    out.append(UInt8((crc >> 16) & 0xFF))
    out.append(UInt8((crc >> 8) & 0xFF))
    out.append(UInt8(crc & 0xFF))
    return out^


def decode_iceberg_dv[origin: Origin, //](data: Span[UInt8, origin]) raises -> Bitmap64:
    """Decode and verify a framed Iceberg deletion-vector v1 blob, raising on
    a length, magic, or CRC-32 mismatch."""
    if len(data) < 12:
        raise Error("iceberg_dv: blob too short")

    var length = (
        (UInt32(data[0]) << 24)
        | (UInt32(data[1]) << 16)
        | (UInt32(data[2]) << 8)
        | UInt32(data[3])
    )
    var body_end = 4 + Int(length)
    if body_end + 4 != len(data):
        raise Error("iceberg_dv: length field does not match blob size")

    if (
        data[4] != _DV_MAGIC_0
        or data[5] != _DV_MAGIC_1
        or data[6] != _DV_MAGIC_2
        or data[7] != _DV_MAGIC_3
    ):
        raise Error("iceberg_dv: bad magic bytes")

    var body = List[UInt8]()
    for i in range(4, body_end):
        body.append(data[i])

    var expected_crc = crc32(Span(body))
    var actual_crc = (
        (UInt32(data[body_end]) << 24)
        | (UInt32(data[body_end + 1]) << 16)
        | (UInt32(data[body_end + 2]) << 8)
        | UInt32(data[body_end + 3])
    )
    if expected_crc != actual_crc:
        raise Error("iceberg_dv: CRC-32 mismatch")

    var vector = List[UInt8]()
    for i in range(8, body_end):
        vector.append(data[i])
    return Bitmap64.deserialize_portable(Span(vector))
