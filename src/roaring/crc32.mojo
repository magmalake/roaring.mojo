"""A plain, from-scratch CRC-32 (the IEEE 802.3 / zlib / gzip variant: poly
0xEDB88320 reflected, init 0xFFFFFFFF, final XOR 0xFFFFFFFF) — no
dependencies, used to checksum Iceberg deletion-vector blobs."""

comptime _CRC32_POLY: UInt32 = 0xEDB88320


def _crc32_table() -> List[UInt32]:
    var table = List[UInt32](length=256, fill=UInt32(0))
    for i in range(256):
        var c: UInt32 = UInt32(i)
        for _ in range(8):
            if (c & 1) != 0:
                c = (c >> 1) ^ _CRC32_POLY
            else:
                c = c >> 1
        table[i] = c
    return table^


def crc32[origin: Origin, //](data: Span[UInt8, origin]) -> UInt32:
    """Standard CRC-32 checksum of `data` (same algorithm as gzip/zlib)."""
    var table = _crc32_table()
    var crc: UInt32 = 0xFFFFFFFF
    for i in range(len(data)):
        var idx = Int((crc ^ UInt32(data[i])) & 0xFF)
        crc = table[idx] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF
