"""`Bitmap32` — a Roaring bitmap over `UInt32` values: a sorted set of
16-bit-keyed `Container`s, one per distinct high-16-bits key present."""

from .container import CONTAINER_ARRAY, CONTAINER_BITSET, CONTAINER_RUN, Container
from .portable import (
    ARRAY_MAX_CARDINALITY,
    NO_OFFSET_THRESHOLD,
    SERIAL_COOKIE,
    SERIAL_COOKIE_NO_RUNCONTAINER,
    read_u16_le,
    read_u32_le,
    write_u16_le,
    write_u32_le,
)


struct Bitmap32(Copyable, Movable):
    var containers: Dict[UInt16, Container]

    def __init__(out self):
        self.containers = Dict[UInt16, Container]()

    def _sorted_keys(self) -> List[UInt16]:
        var keys = List[UInt16]()
        for k in self.containers.keys():
            keys.append(k)
        sort(keys)
        return keys^

    # ── mutation ─────────────────────────────────────────────────────────

    def add(mut self, v: UInt32) raises:
        var key = UInt16((v >> 16) & 0xFFFF)
        var low = UInt16(v & 0xFFFF)
        if key not in self.containers:
            self.containers[key] = Container()
        self.containers[key].add(low)

    def add_range(mut self, start: UInt32, stop: UInt32) raises:
        """Add every value in `[start, stop)`."""
        var v = start
        while v < stop:
            self.add(v)
            v += 1

    def remove(mut self, v: UInt32) raises:
        var key = UInt16((v >> 16) & 0xFFFF)
        if key in self.containers:
            var low = UInt16(v & 0xFFFF)
            self.containers[key].remove(low)
            if self.containers[key].cardinality() == 0:
                _ = self.containers.pop(key)

    def run_optimize(mut self) raises:
        for k in self.containers.keys():
            self.containers[k].run_optimize()

    # ── queries ──────────────────────────────────────────────────────────

    def contains(self, v: UInt32) raises -> Bool:
        var key = UInt16((v >> 16) & 0xFFFF)
        if key not in self.containers:
            return False
        return self.containers[key].contains(UInt16(v & 0xFFFF))

    def cardinality(self) raises -> Int:
        var total = 0
        for k in self.containers.keys():
            total += self.containers[k].cardinality()
        return total

    def is_empty(self) -> Bool:
        return len(self.containers) == 0

    def min(self) raises -> UInt32:
        if self.is_empty():
            raise Error("Bitmap32.min() on an empty bitmap")
        var keys = self._sorted_keys()
        var k = keys[0]
        return (UInt32(k) << 16) | UInt32(self.containers[k].min_value())

    def max(self) raises -> UInt32:
        if self.is_empty():
            raise Error("Bitmap32.max() on an empty bitmap")
        var keys = self._sorted_keys()
        var k = keys[len(keys) - 1]
        return (UInt32(k) << 16) | UInt32(self.containers[k].max_value())

    def to_list(self) raises -> List[UInt32]:
        var out = List[UInt32]()
        var keys = self._sorted_keys()
        for i in range(len(keys)):
            var k = keys[i]
            var vals = self.containers[k].to_sorted_list()
            for j in range(len(vals)):
                out.append((UInt32(k) << 16) | UInt32(vals[j]))
        return out^

    # ── binary set operations ───────────────────────────────────────────

    @staticmethod
    def or_(a: Bitmap32, b: Bitmap32) raises -> Bitmap32:
        return _binop(a, b, 0)

    @staticmethod
    def and_(a: Bitmap32, b: Bitmap32) raises -> Bitmap32:
        return _binop(a, b, 1)

    @staticmethod
    def and_not(a: Bitmap32, b: Bitmap32) raises -> Bitmap32:
        return _binop(a, b, 2)

    @staticmethod
    def xor(a: Bitmap32, b: Bitmap32) raises -> Bitmap32:
        return _binop(a, b, 3)

    # ── portable serialization ──────────────────────────────────────────

    def serialize_portable(self) raises -> List[UInt8]:
        var buf = List[UInt8]()
        _serialize_portable_into(self, buf)
        return buf^

    def portable_size(self) raises -> Int:
        var keys = self._sorted_keys()
        var n = len(keys)
        var has_run = False
        for i in range(n):
            if self.containers[keys[i]].kind == CONTAINER_RUN:
                has_run = True
                break
        var size: Int
        if has_run:
            size = 4 + (n + 7) // 8
        else:
            size = 8
        size += 4 * n
        var include_offsets = (not has_run) or (n >= NO_OFFSET_THRESHOLD)
        if include_offsets:
            size += 4 * n
        for i in range(n):
            size += self.containers[keys[i]].serialized_body_size()
        return size

    @staticmethod
    def deserialize_portable[
        origin: Origin, //
    ](data: Span[UInt8, origin]) raises -> Bitmap32:
        var consumed = 0
        var bm = Bitmap32._deserialize_at(data, 0, consumed)
        if consumed != len(data):
            raise Error("Bitmap32.deserialize_portable: trailing bytes")
        return bm^

    @staticmethod
    def _deserialize_at[
        origin: Origin, //
    ](data: Span[UInt8, origin], pos: Int, mut consumed: Int) raises -> Bitmap32:
        var result = Bitmap32()
        var cookie32 = read_u32_le(data, pos)
        var low16 = cookie32 & 0xFFFF
        var p = pos + 4
        var n: Int
        var has_run = False
        var run_flags = List[Bool]()
        if low16 == SERIAL_COOKIE_NO_RUNCONTAINER:
            n = Int(read_u32_le(data, p))
            p += 4
        elif low16 == SERIAL_COOKIE:
            has_run = True
            n = Int(cookie32 >> 16) + 1
            var nbytes = (n + 7) // 8
            for i in range(n):
                var byte = data[p + i // 8]
                run_flags.append(((byte >> UInt8(i % 8)) & 1) != 0)
            p += nbytes
        else:
            raise Error("roaring: bad portable cookie")

        var keys = List[UInt16]()
        var cards = List[Int]()
        for _ in range(n):
            var k = read_u16_le(data, p)
            var cm1 = read_u16_le(data, p + 2)
            keys.append(k)
            cards.append(Int(cm1) + 1)
            p += 4

        var include_offsets = (not has_run) or (n >= NO_OFFSET_THRESHOLD)
        if include_offsets:
            p += 4 * n

        for i in range(n):
            var kind: UInt8
            if has_run and run_flags[i]:
                kind = CONTAINER_RUN
            elif cards[i] > ARRAY_MAX_CARDINALITY:
                kind = CONTAINER_BITSET
            else:
                kind = CONTAINER_ARRAY
            var c = Container.deserialize_body(kind, cards[i], data, p)
            var body_size = c.serialized_body_size()
            result.containers[keys[i]] = c^
            p += body_size

        consumed = p
        return result^


def _serialize_portable_into(bm: Bitmap32, mut buf: List[UInt8]) raises:
    var keys = bm._sorted_keys()
    var n = len(keys)
    var has_run = False
    for i in range(n):
        if bm.containers[keys[i]].kind == CONTAINER_RUN:
            has_run = True
            break

    if has_run:
        var header32 = SERIAL_COOKIE | (UInt32(n - 1) << 16)
        write_u32_le(buf, header32)
        var nbytes = (n + 7) // 8
        var runbits = List[UInt8](length=nbytes, fill=UInt8(0))
        for i in range(n):
            if bm.containers[keys[i]].kind == CONTAINER_RUN:
                runbits[i // 8] |= UInt8(1) << UInt8(i % 8)
        buf.extend(runbits^)
    else:
        write_u32_le(buf, SERIAL_COOKIE_NO_RUNCONTAINER)
        write_u32_le(buf, UInt32(n))

    for i in range(n):
        var k = keys[i]
        var card = bm.containers[k].cardinality()
        write_u16_le(buf, k)
        write_u16_le(buf, UInt16(card - 1))

    var include_offsets = (not has_run) or (n >= NO_OFFSET_THRESHOLD)
    var body_sizes = List[Int]()
    for i in range(n):
        body_sizes.append(bm.containers[keys[i]].serialized_body_size())

    if include_offsets:
        var running = len(buf) + 4 * n
        for i in range(n):
            write_u32_le(buf, UInt32(running))
            running += body_sizes[i]

    for i in range(n):
        bm.containers[keys[i]].serialize_body(buf)


def _binop(a: Bitmap32, b: Bitmap32, op: Int) raises -> Bitmap32:
    var result = Bitmap32()
    var keys = List[UInt16]()
    for k in a.containers.keys():
        keys.append(k)
    for k in b.containers.keys():
        if k not in a.containers:
            keys.append(k)
    sort(keys)

    for i in range(len(keys)):
        var k = keys[i]
        var has_a = k in a.containers
        var has_b = k in b.containers
        var merged = Container()
        var keep = False
        if op == 0:  # or
            if has_a and has_b:
                merged = Container.or_(a.containers[k], b.containers[k])
            elif has_a:
                merged = a.containers[k].copy()
            else:
                merged = b.containers[k].copy()
            keep = True
        elif op == 1:  # and
            if has_a and has_b:
                merged = Container.and_(a.containers[k], b.containers[k])
                keep = True
        elif op == 2:  # and_not
            if has_a and has_b:
                merged = Container.and_not(a.containers[k], b.containers[k])
                keep = True
            elif has_a:
                merged = a.containers[k].copy()
                keep = True
        else:  # xor
            if has_a and has_b:
                merged = Container.xor(a.containers[k], b.containers[k])
                keep = True
            elif has_a:
                merged = a.containers[k].copy()
                keep = True
            else:
                merged = b.containers[k].copy()
                keep = True
        if keep and merged.cardinality() > 0:
            result.containers[k] = merged^

    return result^
