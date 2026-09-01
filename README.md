# roaring.mojo

[![mojoshelf](https://mojoshelf.org/badge/roaring-mojo.svg)](https://mojoshelf.org/tins/roaring-mojo) [![mojo nightly](https://mojoshelf.org/badge/roaring-mojo/nightly.svg)](https://mojoshelf.org/tins/roaring-mojo)

> Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

Pure-Mojo **Roaring bitmaps** — 32-bit and 64-bit — implementing the
[RoaringFormatSpec](https://github.com/RoaringBitmap/RoaringFormatSpec)
portable serialization (including the 64-bit extension) plus Apache
Iceberg's deletion-vector v1 blob framing. No dependencies: the CRC-32 used
by the Iceberg framing is a from-scratch implementation, not a wrapper
around a system zlib or another Mojo package.

## Install

```sh
pixi shelf add roaring-mojo
```

Working with a coding agent? `npx skills add mojoshelf/mojoshelf --skill mojoshelf-consume --yes` teaches it to find and install tins itself — it installs the `shelf` CLI too.

That resolves the tin from [mojoshelf](https://mojoshelf.org) and adds it — along with the tins it depends on — as **pixi git source dependencies**. magmalake tins are not published to a conda channel, so `pixi add roaring-mojo` will not find them.

## Why this exists

Apache Iceberg v3 [deletion
vectors](https://iceberg.apache.org/spec/#deletion-vectors) record which
rows of a data file are deleted as a Roaring bitmap of row positions, in the
**portable format, 64-bit extension**, wrapped in Iceberg's own blob framing
inside a Puffin file. Reading or writing Iceberg v3 tables from Mojo means
being able to produce and consume exactly those bytes — this tin does that,
independent of any particular table-format or storage library.

- `Bitmap32` / `Bitmap64` are general-purpose Roaring bitmaps, useful on
  their own for compressed sets of integers (row positions, IDs, bitmasks).
- `encode_iceberg_dv` / `decode_iceberg_dv` add just the Iceberg-specific
  framing on top of a `Bitmap64`.

## API

### `Bitmap32` (values are `UInt32`) and `Bitmap64` (values are `UInt64`)

Both types share the same shape of API; `Bitmap64` is a sorted map from a
32-bit high key to a `Bitmap32` over the low 32 bits (see "64-bit
extension" below).

| method | signature | notes |
|---|---|---|
| `add` | `add(mut self, v)` | idempotent |
| `add_range` | `add_range(mut self, start, stop)` | adds `[start, stop)` |
| `remove` | `remove(mut self, v)` | no-op if absent |
| `contains` | `contains(self, v) -> Bool` | |
| `cardinality` | `cardinality(self) -> Int` | |
| `is_empty` | `is_empty(self) -> Bool` | |
| `min` / `max` | `min(self) raises -> V` | raises on an empty bitmap |
| `to_list` | `to_list(self) -> List[V]` | ascending order |
| `run_optimize` | `run_optimize(mut self)` | converts containers to run-length encoding where that's smaller |
| `or_` / `and_` / `and_not` / `xor` | `Bitmap32.or_(a, b) -> Bitmap32` (static) | set union / intersection / difference / symmetric difference |
| `serialize_portable` | `serialize_portable(self) -> List[UInt8]` | |
| `deserialize_portable` | `Bitmap32.deserialize_portable(data: Span[UInt8]) raises -> Bitmap32` (static) | |
| `portable_size` | `portable_size(self) -> Int` | serialized size in bytes, without building the buffer |

All bitmap methods that look up a container internally use `Dict`
subscripting and are marked `raises`.

### Iceberg deletion vectors (`iceberg_dv.mojo`)

| function | signature |
|---|---|
| `encode_iceberg_dv` | `encode_iceberg_dv(bitmap: Bitmap64) raises -> List[UInt8]` |
| `decode_iceberg_dv` | `decode_iceberg_dv(data: Span[UInt8]) raises -> Bitmap64` |

`decode_iceberg_dv` raises on a length mismatch, a bad magic, or a CRC-32
mismatch — treat any raise as "this blob is corrupt," not as a decodable
edge case.

### `Container` (`container.mojo`)

The internal per-16-bit-key container (array / bitset / run), exposed for
introspection (`Bitmap32.containers: Dict[UInt16, Container]`,
`container.kind` is one of `CONTAINER_ARRAY` / `CONTAINER_BITSET` /
`CONTAINER_RUN`). Most users won't need this directly.

## Format notes

### Portable format (32-bit)

Each `Bitmap32` serializes as a cookie header, then a sorted list of
16-bit-keyed containers:

- **No run containers** — cookie `12346` (`SERIAL_COOKIE_NO_RUNCONTAINER`),
  a 4-byte container count, then per-container `(key, cardinality-1)` pairs,
  then a 4-byte offset per container (**always present**), then the
  container bodies.
- **Has run containers** — cookie `12347` (`SERIAL_COOKIE`) packed into the
  low 16 bits of the first 4-byte field with `(count - 1)` in the high 16
  bits, a `ceil(count/8)`-byte bitset marking which containers are run
  containers, the same `(key, cardinality-1)` pairs, then offsets **unless**
  `count < 4` (`NO_OFFSET_THRESHOLD`), then bodies.

Container promotion follows the spec/CRoaring exactly: an **array**
container holds up to 4096 sorted `UInt16`s (2 bytes each); above that it
becomes a fixed 8192-byte **bitset** (65536 bits). A **run** container
(2-byte run count, then `(start, length-1)` `UInt16` pairs) is used only
when `run_optimize()` finds it strictly smaller than the array/bitset
encoding it would otherwise use — nothing is run-encoded implicitly.

All integers in the portable format are **little-endian**.

### 64-bit extension

A `Bitmap64` serializes as an 8-byte LE count of 32-bit bitmaps, then per
bitmap: a 4-byte LE key (the high 32 bits) followed by a complete, portable
32-bit bitmap (the low 32 bits) — keys ascending. There's no length prefix
on the embedded 32-bit bitmap; a reader has to parse its container headers
to know where it ends, which is exactly what `Bitmap32._deserialize_at`
does when `Bitmap64.deserialize_portable` walks the stream.

### Iceberg deletion-vector v1 blob

```
4 bytes   length of (magic + vector), BIG-ENDIAN
4 bytes   magic: D1 D3 39 64
N bytes   the 64-bit portable Roaring vector (LITTLE-ENDIAN internally)
4 bytes   CRC-32 (standard, as in gzip/zlib) over (magic + vector), BIG-ENDIAN
```

The big-endian length/CRC wrapping a little-endian payload is deliberate —
it's exactly what the [Iceberg Puffin
spec](https://iceberg.apache.org/puffin-spec/#deletion-vector-v1-blob-type)
specifies, not an inconsistency in this implementation. Row positions are
`UInt64`, hence `Bitmap64`.

## Tests

```sh
pixi run test
```

26 tests covering: array/bitset/run container behavior and the 4096-element
promotion boundary in both directions, `add_range`, multi-container
ordering, all four binary set operations (including across mixed
array/bitset representations), `run_optimize` (both the shrink case and the
no-op case), portable round trips at several sizes and shapes, and the
Iceberg DV framing (round trip, corrupted CRC in two places, corrupted
magic).

A dozen of those tests cross-check against
[`pyroaring`](https://github.com/RoaringBitmap/CRoaringUnityBuild)'s
`BitMap`/`BitMap64` (`BitMap.serialize()` implements the same portable
format), installed in a throwaway venv while developing this tin. Several
exact byte payloads pyroaring produced are baked in as constants; the tests
assert both directions — that Mojo deserializes pyroaring's bytes correctly,
and that Mojo's own serialization of the same value set is byte-for-byte
identical. (pyroaring auto-run-optimizes contiguous ranges; the equivalent
Mojo tests call `run_optimize()` explicitly before comparing bytes, since
this library never run-encodes implicitly.)

## Bench

```sh
pixi run -e bench bench                 # the table below
pixi run -e bench bench -- --json       # every repetition, for tracking
pixi run -e bench bench -- --only bench_add
```

Adding 10,000,000 random `UInt32` values (all 65536 possible containers get
touched; most stay array containers at ~150 elements each), then serializing
and deserializing the result, on an Apple Silicon Mac. Measured with
[bench.mojo](https://github.com/magmalake/bench.mojo) — mean of three timed
repetitions:

| operation | time | rate |
|---|---|---|
| add 10M values | 1.30 s | 7.7 Melem/s |
| serialize (~20.5 MB output) | 24.0 ms | 0.854 GB/s |
| deserialize | 66.8 ms | 0.307 GB/s |

**These are much faster than the figures published before 2026-09-01
(~5–11 s / ~50–130 ms / ~110–230 ms), and the add row is a measurement fix
rather than a speedup.** The old bench generated each random value *inside*
the timed loop, so roughly three quarters of that 5–11 s was `random_ui64`,
not `add`. Values are now generated during setup, which the harness does not
time. The serialize and deserialize rows were single cold passes and are
simply steadier now.

The container lookup is still a `Dict[UInt16, Container]` subscript per
value — amortized O(1), but with real per-call overhead at 10M calls, and it
is what the 1.30 s is mostly made of. Serialize and deserialize walk a `Dict`
of at most 65536 containers doing bulk byte work per container, which is far
cheaper per element.

## Layout

```
src/roaring/
  __init__.mojo    re-exports
  container.mojo   array/bitset/run container + binary ops + per-container bytes
  bitmap32.mojo     Bitmap32
  bitmap64.mojo     Bitmap64 (64-bit extension)
  portable.mojo     format constants + little-endian byte helpers
  iceberg_dv.mojo   Iceberg deletion-vector v1 blob framing
  crc32.mojo        standalone CRC-32 (gzip/zlib variant)
tests/
  roaring_test.mojo unit tests + pyroaring cross-checks
bench/
  bench_roaring.mojo 10M-value add/serialize/deserialize bench
```

Consume it like the other magmalake Mojo libs — `-I ../roaring.mojo/src`
(no FFI, no link flags).

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
