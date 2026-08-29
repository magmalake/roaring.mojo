"""A single Roaring container, keyed externally by a 16-bit high key and
holding up to 65536 low-16-bit values in one of three representations:

  - **array**: a sorted `List[UInt16]`, used while cardinality <= 4096.
  - **bitset**: a fixed 1024-word (65536-bit) bitset, used above that.
  - **run**: sorted (start, length) runs, used only after `run_optimize()`
    finds it strictly smaller than the array/bitset encoding.

All three representations round-trip through the portable per-container byte
layout described in `portable.mojo`.
"""

from std.bit import pop_count

from .portable import (
    ARRAY_MAX_CARDINALITY,
    BITSET_BYTES,
    BITSET_WORDS,
    read_u16_le,
    read_u64_le,
    write_u16_le,
    write_u64_le,
)

comptime CONTAINER_ARRAY: UInt8 = 0
comptime CONTAINER_BITSET: UInt8 = 1
comptime CONTAINER_RUN: UInt8 = 2


def _bsearch(arr: List[UInt16], v: UInt16) -> Int:
    """Index of `v` in sorted `arr`, or -1."""
    var lo = 0
    var hi = len(arr) - 1
    while lo <= hi:
        var mid = (lo + hi) // 2
        if arr[mid] == v:
            return mid
        elif arr[mid] < v:
            lo = mid + 1
        else:
            hi = mid - 1
    return -1


def _bsearch_insert_pos(arr: List[UInt16], v: UInt16) -> Int:
    """Index at which `v` should be inserted to keep sorted `arr` sorted."""
    var lo = 0
    var hi = len(arr)
    while lo < hi:
        var mid = (lo + hi) // 2
        if arr[mid] < v:
            lo = mid + 1
        else:
            hi = mid
    return lo


struct Container(Copyable, Movable):
    var kind: UInt8
    var arr: List[UInt16]  # sorted ascending; valid when kind == CONTAINER_ARRAY
    var bits: List[UInt64]  # BITSET_WORDS words; valid when kind == CONTAINER_BITSET
    var run_start: List[UInt16]  # valid when kind == CONTAINER_RUN
    var run_len: List[UInt16]  # actual run length (not length-1); parallel to run_start

    def __init__(out self):
        self.kind = CONTAINER_ARRAY
        self.arr = List[UInt16]()
        self.bits = List[UInt64]()
        self.run_start = List[UInt16]()
        self.run_len = List[UInt16]()

    # ── queries ──────────────────────────────────────────────────────────

    def cardinality(self) -> Int:
        if self.kind == CONTAINER_ARRAY:
            return len(self.arr)
        elif self.kind == CONTAINER_BITSET:
            var total = 0
            for i in range(len(self.bits)):
                total += Int(pop_count(self.bits[i]))
            return total
        else:
            var total = 0
            for i in range(len(self.run_len)):
                total += Int(self.run_len[i])
            return total

    def contains(self, v: UInt16) -> Bool:
        if self.kind == CONTAINER_ARRAY:
            return _bsearch(self.arr, v) >= 0
        elif self.kind == CONTAINER_BITSET:
            var word = Int(v) >> 6
            var bit = UInt64(Int(v) & 63)
            return ((self.bits[word] >> bit) & 1) != 0
        else:
            var lo = 0
            var hi = len(self.run_start) - 1
            while lo <= hi:
                var mid = (lo + hi) // 2
                var s = self.run_start[mid]
                if v < s:
                    hi = mid - 1
                elif Int(v) >= Int(s) + Int(self.run_len[mid]):
                    lo = mid + 1
                else:
                    return True
            return False

    def min_value(self) -> UInt16:
        if self.kind == CONTAINER_ARRAY:
            return self.arr[0]
        elif self.kind == CONTAINER_BITSET:
            for i in range(len(self.bits)):
                if self.bits[i] != 0:
                    for bit in range(64):
                        if ((self.bits[i] >> UInt64(bit)) & 1) != 0:
                            return UInt16(i * 64 + bit)
            return 0
        else:
            return self.run_start[0]

    def max_value(self) -> UInt16:
        if self.kind == CONTAINER_ARRAY:
            return self.arr[len(self.arr) - 1]
        elif self.kind == CONTAINER_BITSET:
            for ridx in range(len(self.bits)):
                var i = len(self.bits) - 1 - ridx
                if self.bits[i] != 0:
                    for rbit in range(64):
                        var bit = 63 - rbit
                        if ((self.bits[i] >> UInt64(bit)) & 1) != 0:
                            return UInt16(i * 64 + bit)
            return 0
        else:
            var last = len(self.run_start) - 1
            return UInt16(Int(self.run_start[last]) + Int(self.run_len[last]) - 1)

    def to_sorted_list(self) -> List[UInt16]:
        if self.kind == CONTAINER_ARRAY:
            return self.arr.copy()
        elif self.kind == CONTAINER_BITSET:
            return self._bitset_to_sorted_list()
        else:
            var out = List[UInt16]()
            for i in range(len(self.run_start)):
                var s = Int(self.run_start[i])
                var l = Int(self.run_len[i])
                for j in range(l):
                    out.append(UInt16(s + j))
            return out^

    def _bitset_to_sorted_list(self) -> List[UInt16]:
        var out = List[UInt16]()
        for word_idx in range(len(self.bits)):
            var w = self.bits[word_idx]
            if w == 0:
                continue
            for bit in range(64):
                if ((w >> UInt64(bit)) & 1) != 0:
                    out.append(UInt16(word_idx * 64 + bit))
        return out^

    def to_bitset_words(self) -> List[UInt64]:
        if self.kind == CONTAINER_BITSET:
            return self.bits.copy()
        var words = List[UInt64](length=BITSET_WORDS, fill=UInt64(0))
        var vals = self.to_sorted_list()
        for i in range(len(vals)):
            var v = vals[i]
            var word = Int(v) >> 6
            var bit = UInt64(Int(v) & 63)
            words[word] |= UInt64(1) << bit
        return words^

    # ── mutation ─────────────────────────────────────────────────────────

    def add(mut self, v: UInt16):
        if self.kind == CONTAINER_ARRAY:
            var idx = _bsearch(self.arr, v)
            if idx >= 0:
                return
            var ins = _bsearch_insert_pos(self.arr, v)
            self.arr.insert(ins, v)
            if len(self.arr) > ARRAY_MAX_CARDINALITY:
                self._promote_to_bitset()
        elif self.kind == CONTAINER_BITSET:
            var word = Int(v) >> 6
            var bit = UInt64(Int(v) & 63)
            self.bits[word] |= UInt64(1) << bit
        else:
            self._run_to_array_or_bitset()
            self.add(v)

    def remove(mut self, v: UInt16):
        if self.kind == CONTAINER_ARRAY:
            var idx = _bsearch(self.arr, v)
            if idx >= 0:
                _ = self.arr.pop(idx)
        elif self.kind == CONTAINER_BITSET:
            var word = Int(v) >> 6
            var bit = UInt64(Int(v) & 63)
            self.bits[word] &= ~(UInt64(1) << bit)
            if self.cardinality() <= ARRAY_MAX_CARDINALITY:
                self._demote_to_array()
        else:
            self._run_to_array_or_bitset()
            self.remove(v)

    def _promote_to_bitset(mut self):
        var bits = List[UInt64](length=BITSET_WORDS, fill=UInt64(0))
        for i in range(len(self.arr)):
            var v = self.arr[i]
            var word = Int(v) >> 6
            var bit = UInt64(Int(v) & 63)
            bits[word] |= UInt64(1) << bit
        self.bits = bits^
        self.arr = List[UInt16]()
        self.kind = CONTAINER_BITSET

    def _demote_to_array(mut self):
        var arr = self._bitset_to_sorted_list()
        self.arr = arr^
        self.bits = List[UInt64]()
        self.kind = CONTAINER_ARRAY

    def _run_to_array_or_bitset(mut self):
        var vals = self.to_sorted_list()
        self.run_start = List[UInt16]()
        self.run_len = List[UInt16]()
        self._load_sorted(vals^)

    def _load_sorted(mut self, var values: List[UInt16]):
        if len(values) > ARRAY_MAX_CARDINALITY:
            var bits = List[UInt64](length=BITSET_WORDS, fill=UInt64(0))
            for i in range(len(values)):
                var v = values[i]
                var word = Int(v) >> 6
                var bit = UInt64(Int(v) & 63)
                bits[word] |= UInt64(1) << bit
            self.bits = bits^
            self.arr = List[UInt16]()
            self.kind = CONTAINER_BITSET
        else:
            self.bits = List[UInt64]()
            self.arr = values^
            self.kind = CONTAINER_ARRAY

    def run_optimize(mut self):
        if self.kind == CONTAINER_RUN:
            return
        var vals = self.to_sorted_list()
        if len(vals) == 0:
            return
        var starts = List[UInt16]()
        var lens = List[UInt16]()
        var run_start = vals[0]
        var run_len = 1
        for i in range(1, len(vals)):
            if Int(vals[i]) == Int(vals[i - 1]) + 1:
                run_len += 1
            else:
                starts.append(run_start)
                lens.append(UInt16(run_len))
                run_start = vals[i]
                run_len = 1
        starts.append(run_start)
        lens.append(UInt16(run_len))

        var num_runs = len(starts)
        var run_size = 2 + 4 * num_runs
        var current_size: Int
        if self.kind == CONTAINER_ARRAY:
            current_size = 2 * len(self.arr)
        else:
            current_size = BITSET_BYTES
        if run_size < current_size:
            self.run_start = starts^
            self.run_len = lens^
            self.arr = List[UInt16]()
            self.bits = List[UInt64]()
            self.kind = CONTAINER_RUN

    # ── binary set operations (via a full bitset intermediate) ─────────────

    @staticmethod
    def from_bitset_words(var words: List[UInt64]) -> Container:
        var c = Container()
        var total = 0
        for i in range(len(words)):
            total += Int(pop_count(words[i]))
        c._load_sorted_words(words^, total)
        return c^

    def _load_sorted_words(mut self, var words: List[UInt64], total: Int):
        if total <= ARRAY_MAX_CARDINALITY:
            var vals = List[UInt16]()
            for word_idx in range(len(words)):
                var w = words[word_idx]
                if w == 0:
                    continue
                for bit in range(64):
                    if ((w >> UInt64(bit)) & 1) != 0:
                        vals.append(UInt16(word_idx * 64 + bit))
            self.arr = vals^
            self.bits = List[UInt64]()
            self.kind = CONTAINER_ARRAY
        else:
            self.bits = words^
            self.arr = List[UInt16]()
            self.kind = CONTAINER_BITSET
        self.run_start = List[UInt16]()
        self.run_len = List[UInt16]()

    @staticmethod
    def or_(a: Container, b: Container) -> Container:
        var wa = a.to_bitset_words()
        var wb = b.to_bitset_words()
        var wr = List[UInt64](length=BITSET_WORDS, fill=UInt64(0))
        for i in range(BITSET_WORDS):
            wr[i] = wa[i] | wb[i]
        return Container.from_bitset_words(wr^)

    @staticmethod
    def and_(a: Container, b: Container) -> Container:
        var wa = a.to_bitset_words()
        var wb = b.to_bitset_words()
        var wr = List[UInt64](length=BITSET_WORDS, fill=UInt64(0))
        for i in range(BITSET_WORDS):
            wr[i] = wa[i] & wb[i]
        return Container.from_bitset_words(wr^)

    @staticmethod
    def and_not(a: Container, b: Container) -> Container:
        var wa = a.to_bitset_words()
        var wb = b.to_bitset_words()
        var wr = List[UInt64](length=BITSET_WORDS, fill=UInt64(0))
        for i in range(BITSET_WORDS):
            wr[i] = wa[i] & ~wb[i]
        return Container.from_bitset_words(wr^)

    @staticmethod
    def xor(a: Container, b: Container) -> Container:
        var wa = a.to_bitset_words()
        var wb = b.to_bitset_words()
        var wr = List[UInt64](length=BITSET_WORDS, fill=UInt64(0))
        for i in range(BITSET_WORDS):
            wr[i] = wa[i] ^ wb[i]
        return Container.from_bitset_words(wr^)

    # ── portable per-container byte layout ──────────────────────────────

    def serialized_body_size(self) -> Int:
        if self.kind == CONTAINER_ARRAY:
            return 2 * len(self.arr)
        elif self.kind == CONTAINER_BITSET:
            return BITSET_BYTES
        else:
            return 2 + 4 * len(self.run_start)

    def serialize_body(self, mut buf: List[UInt8]):
        if self.kind == CONTAINER_ARRAY:
            for i in range(len(self.arr)):
                write_u16_le(buf, self.arr[i])
        elif self.kind == CONTAINER_BITSET:
            for i in range(len(self.bits)):
                write_u64_le(buf, self.bits[i])
        else:
            write_u16_le(buf, UInt16(len(self.run_start)))
            for i in range(len(self.run_start)):
                write_u16_le(buf, self.run_start[i])
                write_u16_le(buf, UInt16(Int(self.run_len[i]) - 1))

    @staticmethod
    def deserialize_body[
        origin: Origin, //
    ](
        kind: UInt8, cardinality: Int, data: Span[UInt8, origin], pos: Int
    ) raises -> Container:
        var c = Container()
        c.kind = kind
        if kind == CONTAINER_ARRAY:
            var arr = List[UInt16]()
            for i in range(cardinality):
                arr.append(read_u16_le(data, pos + 2 * i))
            c.arr = arr^
        elif kind == CONTAINER_BITSET:
            var bits = List[UInt64](length=BITSET_WORDS, fill=UInt64(0))
            for i in range(BITSET_WORDS):
                bits[i] = read_u64_le(data, pos + 8 * i)
            c.bits = bits^
        else:
            var num_runs = Int(read_u16_le(data, pos))
            var starts = List[UInt16]()
            var lens = List[UInt16]()
            var p = pos + 2
            for _ in range(num_runs):
                var s = read_u16_le(data, p)
                var lm1 = read_u16_le(data, p + 2)
                starts.append(s)
                lens.append(UInt16(Int(lm1) + 1))
                p += 4
            c.run_start = starts^
            c.run_len = lens^
        return c^
