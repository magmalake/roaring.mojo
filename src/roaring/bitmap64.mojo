"""`Bitmap64` — a Roaring bitmap over `UInt64` values, per the "extension for
64-bit implementations": a sorted map from a 32-bit high key to a full
`Bitmap32` over the low 32 bits. This is the shape Apache Iceberg uses for
deletion vectors (row positions are `UInt64`)."""

from .bitmap32 import Bitmap32
from .portable import read_u32_le, read_u64_le, write_u32_le, write_u64_le


struct Bitmap64(Copyable, Movable):
    var maps: Dict[UInt32, Bitmap32]

    def __init__(out self):
        self.maps = Dict[UInt32, Bitmap32]()

    def _sorted_keys(self) -> List[UInt32]:
        var keys = List[UInt32]()
        for k in self.maps.keys():
            keys.append(k)
        sort(keys)
        return keys^

    # ── mutation ─────────────────────────────────────────────────────────

    def add(mut self, v: UInt64) raises:
        var key = UInt32((v >> 32) & 0xFFFFFFFF)
        var low = UInt32(v & 0xFFFFFFFF)
        if key not in self.maps:
            self.maps[key] = Bitmap32()
        self.maps[key].add(low)

    def add_range(mut self, start: UInt64, stop: UInt64) raises:
        """Add every value in `[start, stop)`."""
        var v = start
        while v < stop:
            self.add(v)
            v += 1

    def remove(mut self, v: UInt64) raises:
        var key = UInt32((v >> 32) & 0xFFFFFFFF)
        if key in self.maps:
            var low = UInt32(v & 0xFFFFFFFF)
            self.maps[key].remove(low)
            if self.maps[key].is_empty():
                _ = self.maps.pop(key)

    def run_optimize(mut self) raises:
        for k in self.maps.keys():
            self.maps[k].run_optimize()

    # ── queries ──────────────────────────────────────────────────────────

    def contains(self, v: UInt64) raises -> Bool:
        var key = UInt32((v >> 32) & 0xFFFFFFFF)
        if key not in self.maps:
            return False
        return self.maps[key].contains(UInt32(v & 0xFFFFFFFF))

    def cardinality(self) raises -> Int:
        var total = 0
        for k in self.maps.keys():
            total += self.maps[k].cardinality()
        return total

    def is_empty(self) -> Bool:
        return len(self.maps) == 0

    def min(self) raises -> UInt64:
        if self.is_empty():
            raise Error("Bitmap64.min() on an empty bitmap")
        var keys = self._sorted_keys()
        var k = keys[0]
        return (UInt64(k) << 32) | UInt64(self.maps[k].min())

    def max(self) raises -> UInt64:
        if self.is_empty():
            raise Error("Bitmap64.max() on an empty bitmap")
        var keys = self._sorted_keys()
        var k = keys[len(keys) - 1]
        return (UInt64(k) << 32) | UInt64(self.maps[k].max())

    def to_list(self) raises -> List[UInt64]:
        var out = List[UInt64]()
        var keys = self._sorted_keys()
        for i in range(len(keys)):
            var k = keys[i]
            var vals = self.maps[k].to_list()
            for j in range(len(vals)):
                out.append((UInt64(k) << 32) | UInt64(vals[j]))
        return out^

    # ── binary set operations ───────────────────────────────────────────

    @staticmethod
    def or_(a: Bitmap64, b: Bitmap64) raises -> Bitmap64:
        return _binop64(a, b, 0)

    @staticmethod
    def and_(a: Bitmap64, b: Bitmap64) raises -> Bitmap64:
        return _binop64(a, b, 1)

    @staticmethod
    def and_not(a: Bitmap64, b: Bitmap64) raises -> Bitmap64:
        return _binop64(a, b, 2)

    @staticmethod
    def xor(a: Bitmap64, b: Bitmap64) raises -> Bitmap64:
        return _binop64(a, b, 3)

    # ── portable serialization (64-bit extension) ───────────────────────

    def serialize_portable(self) raises -> List[UInt8]:
        var keys = self._sorted_keys()
        var buf = List[UInt8]()
        write_u64_le(buf, UInt64(len(keys)))
        for i in range(len(keys)):
            var k = keys[i]
            write_u32_le(buf, k)
            var sub = self.maps[k].serialize_portable()
            buf.extend(sub^)
        return buf^

    def portable_size(self) raises -> Int:
        var keys = self._sorted_keys()
        var size = 8
        for i in range(len(keys)):
            size += 4 + self.maps[keys[i]].portable_size()
        return size

    @staticmethod
    def deserialize_portable[
        origin: Origin, //
    ](data: Span[UInt8, origin]) raises -> Bitmap64:
        var result = Bitmap64()
        if len(data) < 8:
            raise Error("Bitmap64.deserialize_portable: truncated header")
        var count = Int(read_u64_le(data, 0))
        var p = 8
        for _ in range(count):
            var key = read_u32_le(data, p)
            p += 4
            var consumed = 0
            var bm = Bitmap32._deserialize_at(data, p, consumed)
            result.maps[key] = bm^
            p = consumed
        if p != len(data):
            raise Error("Bitmap64.deserialize_portable: trailing bytes")
        return result^


def _binop64(a: Bitmap64, b: Bitmap64, op: Int) raises -> Bitmap64:
    var result = Bitmap64()
    var keys = List[UInt32]()
    for k in a.maps.keys():
        keys.append(k)
    for k in b.maps.keys():
        if k not in a.maps:
            keys.append(k)
    sort(keys)

    for i in range(len(keys)):
        var k = keys[i]
        var has_a = k in a.maps
        var has_b = k in b.maps
        var merged = Bitmap32()
        var keep = False
        if op == 0:  # or
            if has_a and has_b:
                merged = Bitmap32.or_(a.maps[k], b.maps[k])
            elif has_a:
                merged = a.maps[k].copy()
            else:
                merged = b.maps[k].copy()
            keep = True
        elif op == 1:  # and
            if has_a and has_b:
                merged = Bitmap32.and_(a.maps[k], b.maps[k])
                keep = True
        elif op == 2:  # and_not
            if has_a and has_b:
                merged = Bitmap32.and_not(a.maps[k], b.maps[k])
                keep = True
            elif has_a:
                merged = a.maps[k].copy()
                keep = True
        else:  # xor
            if has_a and has_b:
                merged = Bitmap32.xor(a.maps[k], b.maps[k])
                keep = True
            elif has_a:
                merged = a.maps[k].copy()
                keep = True
            else:
                merged = b.maps[k].copy()
                keep = True
        if keep:
            var card = merged.cardinality()
            if card > 0:
                result.maps[k] = merged^

    return result^
