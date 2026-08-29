"""Test suite for `roaring` — run via `pixi run test`.

Cross-check payloads (the `*_32`/`BM64_*` byte constants below) were produced
by CPython's `pyroaring` (`BitMap.serialize()` / `BitMap64.serialize()`,
which implement the portable RoaringFormatSpec format) in a throwaway venv:

    from pyroaring import BitMap, BitMap64
    BitMap([...]).serialize().hex()
    BitMap64([...]).serialize().hex()

Some of these (`tiny_run_opt32()`, `run_contig32()`, `run_dense32()`) are run
containers — pyroaring auto-run-optimizes contiguous ranges, so a plain
`BitMap(range(a, b))` already serializes with the "has run containers"
cookie. Mojo's `Bitmap32` never auto-optimizes; the matching test calls
`run_optimize()` explicitly before comparing bytes.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from roaring import Bitmap32, Bitmap64, decode_iceberg_dv, encode_iceberg_dv
from roaring.container import CONTAINER_ARRAY, CONTAINER_BITSET, CONTAINER_RUN, Container

# ── pyroaring cross-check payloads ──────────────────────────────────────

def empty32() -> List[UInt8]:
    return [0x3a, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

def single32() -> List[UInt8]:
    return [
        0x3a, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x10, 0x00, 0x00, 0x00, 0x2a, 0x00,
    ]

def small_array32() -> List[UInt8]:
    return [
        0x3a, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00,
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x06, 0x00, 0x09, 0x00,
        0x0c, 0x00, 0x0f, 0x00, 0x12, 0x00, 0x15, 0x00, 0x18, 0x00, 0x1b, 0x00,
        0x1e, 0x00, 0x21, 0x00, 0x24, 0x00, 0x27, 0x00, 0x2a, 0x00, 0x2d, 0x00,
        0x30, 0x00, 0x33, 0x00, 0x36, 0x00, 0x39, 0x00, 0x3c, 0x00, 0x3f, 0x00,
        0x42, 0x00, 0x45, 0x00, 0x48, 0x00, 0x4b, 0x00, 0x4e, 0x00, 0x51, 0x00,
        0x54, 0x00, 0x57, 0x00, 0x5a, 0x00, 0x5d, 0x00, 0x60, 0x00, 0x63, 0x00,
    ]

# BitMap([5, 70000, 705032709])
def multi_key32() -> List[UInt8]:
    return [
        0x3a, 0x30, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x05, 0x2a, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
        0x22, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x05, 0x00, 0x70, 0x11,
        0x05, 0xf2,
    ]

# BitMap([5, 70000, 200000, 4294967295])
def multi_key2_32() -> List[UInt8]:
    return [
        0x3a, 0x30, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00,
        0x28, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00,
        0x2e, 0x00, 0x00, 0x00, 0x05, 0x00, 0x70, 0x11, 0x40, 0x0d, 0xff, 0xff,
    ]

# BitMap(range(0, 10)).run_optimize()
def tiny_run_opt32() -> List[UInt8]:
    return [
        0x3b, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x09, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x09, 0x00,
    ]

# BitMap(range(1000, 3000)) — pyroaring auto-run-optimizes contiguous ranges
def run_contig32() -> List[UInt8]:
    return [
        0x3b, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0xcf, 0x07, 0x01, 0x00, 0xe8,
        0x03, 0xcf, 0x07,
    ]

# BitMap(range(0, 5001)) — also auto-run-optimized by pyroaring
def run_dense32() -> List[UInt8]:
    return [
        0x3b, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x88, 0x13, 0x01, 0x00, 0x00,
        0x00, 0x88, 0x13,
    ]

# BitMap64([1, 2, 3, 2**40 + 5])
def bm64_small() -> List[UInt8]:
    return [
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x3a, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00,
        0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x3a, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x05, 0x00,
    ]

# BitMap64([0, 1, 2**32, 2**32+1, 2**63-1, 2**64-1])
def bm64_spanning() -> List[UInt8]:
    return [
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x3a, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x3a, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0xff, 0xff, 0xff, 0x7f,
        0x3a, 0x30, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00,
        0x10, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x3a, 0x30,
        0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x10, 0x00,
        0x00, 0x00, 0xff, 0xff,
    ]


def _list_eq(a: List[UInt32], b: List[UInt32]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _list_eq64(a: List[UInt64], b: List[UInt64]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# ── array container basics ──────────────────────────────────────────────


def test_array_add_contains_remove() raises:
    var bm = Bitmap32()
    assert_true(bm.is_empty())
    bm.add(5)
    bm.add(3)
    bm.add(3)  # duplicate, no-op
    bm.add(9)
    assert_equal(bm.cardinality(), 3)
    assert_true(bm.contains(3))
    assert_true(bm.contains(5))
    assert_true(bm.contains(9))
    assert_false(bm.contains(4))
    assert_equal(bm.min(), UInt32(3))
    assert_equal(bm.max(), UInt32(9))

    bm.remove(5)
    assert_equal(bm.cardinality(), 2)
    assert_false(bm.contains(5))
    bm.remove(999)  # no-op, not present
    assert_equal(bm.cardinality(), 2)

    var vals = bm.to_list()
    assert_equal(len(vals), 2)
    assert_equal(vals[0], UInt32(3))
    assert_equal(vals[1], UInt32(9))


def test_add_range() raises:
    var bm = Bitmap32()
    bm.add_range(1000, 3000)
    assert_equal(bm.cardinality(), 2000)
    assert_true(bm.contains(1000))
    assert_true(bm.contains(2999))
    assert_false(bm.contains(3000))
    assert_false(bm.contains(999))


def test_multi_container_ordering() raises:
    var bm = Bitmap32()
    bm.add(70000)
    bm.add(5)
    bm.add(4294967295)
    bm.add(200000)
    assert_equal(bm.cardinality(), 4)
    assert_equal(bm.min(), UInt32(5))
    assert_equal(bm.max(), UInt32(4294967295))
    var expected: List[UInt32] = [5, 70000, 200000, 4294967295]
    assert_true(_list_eq(bm.to_list(), expected))


# ── container promotion (array <-> bitset at 4096) ──────────────────────


def test_array_bitset_promotion() raises:
    var bm = Bitmap32()
    for i in range(4096):
        bm.add(UInt32(2 * i))  # 4096 values, non-contiguous -> stays array
    assert_equal(bm.cardinality(), 4096)
    assert_equal(bm.containers[UInt16(0)].kind, CONTAINER_ARRAY)

    bm.add(UInt32(2 * 4096))  # 4097th value -> promotes to bitset
    assert_equal(bm.cardinality(), 4097)
    assert_equal(bm.containers[UInt16(0)].kind, CONTAINER_BITSET)
    assert_true(bm.contains(UInt32(2 * 4096)))
    assert_true(bm.contains(0))
    assert_false(bm.contains(1))

    bm.remove(UInt32(2 * 4096))  # back down to 4096 -> demotes to array
    assert_equal(bm.cardinality(), 4096)
    assert_equal(bm.containers[UInt16(0)].kind, CONTAINER_ARRAY)
    for i in range(4096):
        assert_true(bm.contains(UInt32(2 * i)))


def test_bitset_serialized_size() raises:
    var bm_array = Bitmap32()
    for i in range(4096):
        bm_array.add(UInt32(2 * i))
    assert_equal(bm_array.portable_size(), 8208)
    assert_equal(len(bm_array.serialize_portable()), 8208)

    var bm_bitset = bm_array.copy()
    bm_bitset.add(UInt32(2 * 4096))
    assert_equal(bm_bitset.containers[UInt16(0)].kind, CONTAINER_BITSET)
    assert_equal(bm_bitset.portable_size(), 8208)
    assert_equal(len(bm_bitset.serialize_portable()), 8208)

    var back = Bitmap32.deserialize_portable(Span(bm_bitset.serialize_portable()))
    assert_equal(back.cardinality(), 4097)
    assert_true(back.contains(UInt32(2 * 4096)))
    assert_false(back.contains(1))


# ── run_optimize ─────────────────────────────────────────────────────────


def test_run_optimize_shrinks_and_preserves() raises:
    var bm = Bitmap32()
    bm.add_range(1000, 3000)
    var before = bm.portable_size()
    bm.run_optimize()
    var after = bm.portable_size()
    assert_true(after < before)
    assert_equal(bm.containers[UInt16(0)].kind, CONTAINER_RUN)
    assert_equal(bm.cardinality(), 2000)
    assert_true(bm.contains(1000))
    assert_true(bm.contains(2999))
    assert_false(bm.contains(3000))

    var vals = bm.to_list()
    assert_equal(len(vals), 2000)
    for i in range(2000):
        assert_equal(vals[i], UInt32(1000 + i))


def test_run_optimize_noop_when_not_smaller() raises:
    # A sparse, non-contiguous array has more runs than values -> stays array.
    var bm = Bitmap32()
    bm.add(1)
    bm.add(100)
    bm.add(50000)
    bm.run_optimize()
    assert_equal(bm.containers[UInt16(0)].kind, CONTAINER_ARRAY)


# ── binary set operations ───────────────────────────────────────────────


def test_or_and_andnot_xor() raises:
    var a = Bitmap32()
    for v in [1, 2, 3, 100, 70000]:
        a.add(UInt32(v))
    var b = Bitmap32()
    for v in [2, 3, 4, 70000, 70001]:
        b.add(UInt32(v))

    var u = Bitmap32.or_(a, b)
    var expected_or: List[UInt32] = [1, 2, 3, 4, 100, 70000, 70001]
    assert_true(_list_eq(u.to_list(), expected_or))

    var i = Bitmap32.and_(a, b)
    var expected_and: List[UInt32] = [2, 3, 70000]
    assert_true(_list_eq(i.to_list(), expected_and))

    var d = Bitmap32.and_not(a, b)
    var expected_andnot: List[UInt32] = [1, 100]
    assert_true(_list_eq(d.to_list(), expected_andnot))

    var x = Bitmap32.xor(a, b)
    var expected_xor: List[UInt32] = [1, 4, 100, 70001]
    assert_true(_list_eq(x.to_list(), expected_xor))


def test_binops_across_representations() raises:
    # a: dense bitset container; b: sparse array container, partial overlap.
    var a = Bitmap32()
    for i in range(5000):
        a.add(UInt32(i))
    assert_equal(a.containers[UInt16(0)].kind, CONTAINER_BITSET)

    var b = Bitmap32()
    b.add(10)
    b.add(4999)
    b.add(5000)

    var inter = Bitmap32.and_(a, b)
    assert_equal(inter.cardinality(), 2)
    assert_true(inter.contains(10))
    assert_true(inter.contains(4999))
    assert_false(inter.contains(5000))

    var union = Bitmap32.or_(a, b)
    assert_equal(union.cardinality(), 5001)
    assert_true(union.contains(5000))


# ── portable round trips ─────────────────────────────────────────────────


def test_portable_roundtrip_empty() raises:
    var bm = Bitmap32()
    var data = bm.serialize_portable()
    assert_true(_bytes_eq(data, empty32()))
    var back = Bitmap32.deserialize_portable(Span(data))
    assert_true(back.is_empty())


def test_portable_roundtrip_sparse_and_multi_key() raises:
    var bm = Bitmap32()
    bm.add(5)
    bm.add(70000)
    bm.add(200000)
    bm.add(4294967295)
    var data = bm.serialize_portable()
    var back = Bitmap32.deserialize_portable(Span(data))
    assert_true(_list_eq(back.to_list(), bm.to_list()))
    assert_equal(back.cardinality(), 4)


def test_portable_roundtrip_dense_and_run() raises:
    var bm = Bitmap32()
    bm.add_range(0, 6000)  # spills into bitset before run_optimize
    bm.run_optimize()
    var data = bm.serialize_portable()
    var back = Bitmap32.deserialize_portable(Span(data))
    assert_equal(back.cardinality(), 6000)
    assert_true(_list_eq(back.to_list(), bm.to_list()))


# ── cross-checks against pyroaring's portable bytes ─────────────────────


def test_cross_check_empty() raises:
    var back = Bitmap32.deserialize_portable(Span(empty32()))
    assert_true(back.is_empty())
    var bm = Bitmap32()
    assert_true(_bytes_eq(bm.serialize_portable(), empty32()))


def test_cross_check_single() raises:
    var back = Bitmap32.deserialize_portable(Span(single32()))
    assert_equal(back.cardinality(), 1)
    assert_true(back.contains(42))
    var bm = Bitmap32()
    bm.add(42)
    assert_true(_bytes_eq(bm.serialize_portable(), single32()))


def test_cross_check_small_array() raises:
    var back = Bitmap32.deserialize_portable(Span(small_array32()))
    assert_equal(back.cardinality(), 34)
    var bm = Bitmap32()
    var v: UInt32 = 0
    while v < 100:
        bm.add(v)
        v += 3
    assert_equal(bm.cardinality(), back.cardinality())
    assert_true(_list_eq(bm.to_list(), back.to_list()))
    assert_true(_bytes_eq(bm.serialize_portable(), small_array32()))


def test_cross_check_multi_key() raises:
    var back = Bitmap32.deserialize_portable(Span(multi_key32()))
    var expected: List[UInt32] = [5, 70000, 705032709]
    assert_true(_list_eq(back.to_list(), expected))
    var bm = Bitmap32()
    for x in expected:
        bm.add(x)
    assert_true(_bytes_eq(bm.serialize_portable(), multi_key32()))


def test_cross_check_multi_key2() raises:
    var back = Bitmap32.deserialize_portable(Span(multi_key2_32()))
    var expected: List[UInt32] = [5, 70000, 200000, 4294967295]
    assert_true(_list_eq(back.to_list(), expected))
    var bm = Bitmap32()
    for x in expected:
        bm.add(x)
    assert_true(_bytes_eq(bm.serialize_portable(), multi_key2_32()))


def test_cross_check_tiny_run() raises:
    var back = Bitmap32.deserialize_portable(Span(tiny_run_opt32()))
    assert_equal(back.cardinality(), 10)
    for i in range(10):
        assert_true(back.contains(UInt32(i)))
    var bm = Bitmap32()
    bm.add_range(0, 10)
    bm.run_optimize()
    assert_true(_bytes_eq(bm.serialize_portable(), tiny_run_opt32()))


def test_cross_check_run_contig() raises:
    var back = Bitmap32.deserialize_portable(Span(run_contig32()))
    assert_equal(back.cardinality(), 2000)
    assert_true(back.contains(1000))
    assert_true(back.contains(2999))
    var bm = Bitmap32()
    bm.add_range(1000, 3000)
    bm.run_optimize()
    assert_true(_bytes_eq(bm.serialize_portable(), run_contig32()))


def test_cross_check_run_dense() raises:
    var back = Bitmap32.deserialize_portable(Span(run_dense32()))
    assert_equal(back.cardinality(), 5001)
    var bm = Bitmap32()
    bm.add_range(0, 5001)
    bm.run_optimize()
    assert_true(_bytes_eq(bm.serialize_portable(), run_dense32()))


def test_cross_check_bitmap64_small() raises:
    var back = Bitmap64.deserialize_portable(Span(bm64_small()))
    var expected: List[UInt64] = [1, 2, 3, UInt64(2) ** 40 + 5]
    assert_equal(back.cardinality(), 4)
    for x in expected:
        assert_true(back.contains(x))
    var bm = Bitmap64()
    for x in expected:
        bm.add(x)
    assert_true(_bytes_eq(bm.serialize_portable(), bm64_small()))


def test_cross_check_bitmap64_spanning() raises:
    var back = Bitmap64.deserialize_portable(Span(bm64_spanning()))
    var expected: List[UInt64] = [
        0,
        1,
        UInt64(2) ** 32,
        UInt64(2) ** 32 + 1,
        UInt64(2) ** 63 - 1,
        UInt64(2) ** 64 - 1,
    ]
    assert_equal(back.cardinality(), 6)
    for x in expected:
        assert_true(back.contains(x))
    assert_equal(back.min(), UInt64(0))
    assert_equal(back.max(), UInt64(2) ** 64 - 1)
    var bm = Bitmap64()
    for x in expected:
        bm.add(x)
    assert_true(_bytes_eq(bm.serialize_portable(), bm64_spanning()))


# ── Iceberg deletion-vector v1 framing ──────────────────────────────────


def test_iceberg_dv_roundtrip() raises:
    var bm = Bitmap64()
    bm.add(0)
    bm.add(1)
    bm.add(1000000)
    bm.add(UInt64(2) ** 40 + 7)
    var blob = encode_iceberg_dv(bm)

    # 4-byte BE length + 4-byte magic + vector + 4-byte BE CRC.
    assert_equal(blob[0], UInt8(0x00))
    assert_equal(blob[4], UInt8(0xD1))
    assert_equal(blob[5], UInt8(0xD3))
    assert_equal(blob[6], UInt8(0x39))
    assert_equal(blob[7], UInt8(0x64))

    var back = decode_iceberg_dv(Span(blob))
    assert_equal(back.cardinality(), 4)
    assert_true(_list_eq64(back.to_list(), bm.to_list()))


def test_iceberg_dv_bad_crc() raises:
    var bm = Bitmap64()
    bm.add(42)
    var blob = encode_iceberg_dv(bm)
    blob[len(blob) - 1] ^= UInt8(0xFF)  # flip a byte in the CRC itself
    with assert_raises():
        _ = decode_iceberg_dv(Span(blob))


def test_iceberg_dv_bad_crc_body_flip() raises:
    var bm = Bitmap64()
    bm.add_range(0, 500)
    var blob = encode_iceberg_dv(bm)
    blob[20] ^= UInt8(0x01)  # flip a byte inside the vector body
    with assert_raises():
        _ = decode_iceberg_dv(Span(blob))


def test_iceberg_dv_bad_magic() raises:
    var bm = Bitmap64()
    bm.add(1)
    var blob = encode_iceberg_dv(bm)
    blob[4] = UInt8(0x00)
    with assert_raises():
        _ = decode_iceberg_dv(Span(blob))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
