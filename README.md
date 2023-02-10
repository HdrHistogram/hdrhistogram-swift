# Histogram: Swift port of [High Dynamic Range (HDR) Histogram](http://hdrhistogram.org)

HdrHistogram
----------------------------------------------

This port contains a subset of the functionality supported by the Java
implementation.  The current supported features are:

* Generic histogram class parametrized by type used for bucket count
* All iterator types (all values, recorded, percentiles, linear, logarithmic)

# Performance

On Apple M1 hardware recording a value is on the order of 4ns.

# Simple example (see Sources/HistogramExample/main.swift)

```Swift
import Histogram

let maxValue: UInt64 = 3_600_000_000 // e.g. for 1 hr in usec units

var histogram = Histogram<UInt64>(highestTrackableValue: maxValue, numberOfSignificantValueDigits: .three)

// record some random values
for _ in 1...100 {
    histogram.record(UInt64.random(in: 10...1000))
}

// record value n times
histogram.record(UInt64.random(in: 50...200), count: 10)

// record value with correction for co-ordinated omission
histogram.recordCorrectedValue(1_000, expectedInterval: 100)

// iterate using percentile iterator
for pv in histogram.percentiles(ticksPerHalfDistance: 1) {
    print("Percentile: \(pv.percentile), Value: \(pv.value)")
}

print(String(repeating: "-", count: 80))

// print values for interesting percentiles
let percentiles = [ 0.0, 50.0, 80.0, 95.0, 99.0, 99.9, 99.99, 99.999, 100.0 ]
for p in percentiles {
    print("Percentile: \(p), Value: \(histogram.valueAtPercentile(p))")
}

print(String(repeating: "-", count: 80))

// general stats
print("min: \(histogram.min)")
print("max: \(histogram.max)")
print("mean: \(histogram.mean)")
print("stddev: \(histogram.stdDeviation)")
```
