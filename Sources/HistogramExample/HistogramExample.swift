//
// Copyright (c) 2023 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0

import Histogram

@main
struct HistogramExample {
    static func main() {
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

        print("\n", histogram)
    }
}
