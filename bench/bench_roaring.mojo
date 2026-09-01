"""Build, serialize and deserialize a 10M-value `Bitmap32`, through the
shared harness (magmalake/bench.mojo).

    pixi run -e bench bench
    pixi run -e bench bench -- --json
    pixi run -e bench bench -- --only bench_deserialize_portable

Moved from `tests/bench.mojo`, which timed one pass of each with
`perf_counter_ns` and reported seconds.
"""

from std.random import random_ui64, seed

from bench import Benchmark, BenchSuite, Metric, keep

from roaring import Bitmap32

comptime N = 10_000_000


def _values(n: Int) -> List[UInt32]:
    """Seeded, so the bitmap is identical run to run and the numbers compare
    across commits."""
    seed(12345)
    var out = List[UInt32](capacity=n)
    for _ in range(n):
        out.append(UInt32(random_ui64(0, 0xFFFFFFFF)))
    return out^


def _filled(n: Int) raises -> Bitmap32:
    var bm = Bitmap32()
    var vals = _values(n)
    for i in range(len(vals)):
        bm.add(vals[i])
    return bm^


def bench_add(mut b: Benchmark) raises:
    # Values are generated in setup: this measures `add`, not the RNG.
    var vals = _values(N)
    b.throughput(Metric.elements(), N)

    @parameter
    def call() raises:
        var bm = Bitmap32()
        for i in range(len(vals)):
            bm.add(vals[i])
        keep(bm.cardinality())

    b.iter[call]()
    keep(vals)


def bench_serialize_portable(mut b: Benchmark) raises:
    var bm = _filled(N)
    b.throughput(Metric.bytes(), len(bm.serialize_portable()))

    @parameter
    def call() raises:
        var data = bm.serialize_portable()
        keep(data)

    b.iter[call]()
    keep(bm.cardinality())


def bench_deserialize_portable(mut b: Benchmark) raises:
    var bm = _filled(N)
    var data = bm.serialize_portable()
    b.throughput(Metric.bytes(), len(data))

    @parameter
    def call() raises:
        var back = Bitmap32.deserialize_portable(Span(data))
        keep(back.cardinality())

    b.iter[call]()
    keep(data)


def _print_shape() raises:
    """Cardinality, container count and serialized size, printed once — they
    describe the bitmap, not its speed."""
    var bm = _filled(N)
    var data = bm.serialize_portable()
    var back = Bitmap32.deserialize_portable(Span(data))
    if back.cardinality() != bm.cardinality():
        raise Error("round trip cardinality mismatch")
    print(
        "values added", N,
        "| cardinality", bm.cardinality(),
        "| containers", len(bm.containers),
        "| serialized", len(data) // 1024, "KiB",
    )


def main() raises:
    _print_shape()
    BenchSuite.run[__functions_in_module()](num_repetitions=3)
