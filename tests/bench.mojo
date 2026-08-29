"""Bench: add 10M random UInt32 values to a `Bitmap32`, serialize, and
deserialize — reports wall-clock times. Run via `pixi run bench`."""

from std.random import random_ui64, seed
from std.time import perf_counter_ns

from roaring import Bitmap32


def main() raises:
    seed(12345)
    comptime N = 10_000_000

    var bm = Bitmap32()
    var t0 = perf_counter_ns()
    for _ in range(N):
        var v = UInt32(random_ui64(0, 0xFFFFFFFF))
        bm.add(v)
    var t1 = perf_counter_ns()

    var data = bm.serialize_portable()
    var t2 = perf_counter_ns()

    var back = Bitmap32.deserialize_portable(Span(data))
    var t3 = perf_counter_ns()

    print("values added:               ", N)
    print("resulting cardinality:      ", bm.cardinality())
    print("containers:                 ", len(bm.containers))
    print("serialized size (bytes):    ", len(data))
    print("deserialized cardinality:   ", back.cardinality())
    print()
    print("add", N, "values:  ", Float64(t1 - t0) / 1e9, "s")
    print("serialize:            ", Float64(t2 - t1) / 1e9, "s")
    print("deserialize:          ", Float64(t3 - t2) / 1e9, "s")
