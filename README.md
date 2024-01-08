[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FHdrHistogram%2Fhdrhistogram-swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/HdrHistogram/hdrhistogram-swift)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FHdrHistogram%2Fhdrhistogram-swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/HdrHistogram/hdrhistogram-swift)
[![codecov](https://codecov.io/gh/HdrHistogram/hdrhistogram-swift/graph/badge.svg?token=3k47sRmxXn)](https://codecov.io/gh/HdrHistogram/hdrhistogram-swift)
[![Address sanitizer](https://github.com/HdrHistogram/hdrhistogram-swift/actions/workflows/swift-sanitizer-address.yml/badge.svg)](https://github.com/HdrHistogram/hdrhistogram-swift/actions/workflows/swift-sanitizer-address.yml)
[![Thread sanitizer](https://github.com/HdrHistogram/hdrhistogram-swift/actions/workflows/swift-sanitizer-thread.yml/badge.svg)](https://github.com/HdrHistogram/hdrhistogram-swift/actions/workflows/swift-sanitizer-thread.yml)

# Histogram

Histogram is a port of Gil Tene's [High Dynamic Range (HDR) Histogram](http://hdrhistogram.org) to native Swift. It provides recording and analyzing of sampled data value counts across a large, configurable value range with configurable precision within the range. The resulting "HDR" histogram allows for fast and accurate analysis of the extreme ranges of data with non-normal distributions, like latency.

Histogram supports the recording and analyzing of sampled data value counts across a configurable integer value range with configurable value precision within the range. Value precision is expressed as the number of significant digits in the value recording, and provides control over value quantization behavior across the value range and the subsequent value resolution at any given level.

For example, a Histogram could be configured to track the counts of observed integer values between 0 and 3,600,000,000 while maintaining a value precision of 3 significant digits across that range. Value quantization within the range will thus be no larger than 1/1,000th (or 0.1%) of any value. 

This example Histogram could be used to track and analyze the counts of observed response times ranging between 1 microsecond and 1 hour in magnitude, while maintaining a value resolution of 1 microsecond up to 1 millisecond, a resolution of 1 millisecond (or better) up to one second, and a resolution of 1 second (or better) up to 1,000 seconds. At it's maximum tracked value (1 hour), it would still maintain a resolution of 3.6 seconds (or better).

Histogram is designed for recording histograms of value measurements in latency and performance sensitive applications. 

**Measurements show value recording times as low as 3-4 nanoseconds on Apple Silicon CPUs (M1).** 

The Histogram maintains a fixed cost in both space and time. A Histogram's memory footprint is constant, with no allocation operations involved in recording data values or in iterating through them. 

The memory footprint is fixed regardless of the number of data value samples recorded, and depends solely on the dynamic range and precision chosen. The amount of work involved in recording a sample is constant, and directly computes storage index locations such that no iteration or searching is ever involved in recording data values.

This port contains a subset of the functionality supported by the Java implementation.  

The current supported features are:

* Generic histogram class parametrized by type used for bucket count
* All iterator types (all values, recorded, percentiles, linear, logarithmic)

Users are encouraged to read the documentation from the original [Java implementation](https://github.com/HdrHistogram/HdrHistogram), 
as most of the concepts translate directly to the Swift port. Additional Thanks to the maintainers of the Rust port for a nice introduction to the package that we've largely borrowed.

# Adding dependencies
To add to your project:
```
dependencies: [
    .package(url: "https://github.com/HdrHistogram/hdrhistogram-swift", .upToNextMajor(from: "0.1.0"))
]
```

and then add the dependency to your target, e.g.:

```
.executableTarget(
  name: "MyExecutableTarget",
  dependencies: [
  .product(name: "Histogram", package: "hdrhistogram-swift")
]),
```
## Usage

The Histogram API follows that of the original HdrHistogram Java implementation, with some modifications to make its use more idiomatic in Swift. 

[Documentation for the classes and API](https://swiftpackageindex.com/ordo-one/package-histogram/main/documentation/Histogram) are hosted by the [SwiftPackageIndex](http://www.swiftpackageindex.com)

# Simple example 

(see implementation in Sources/HistogramExample)

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

print("\(histogram)")
```

