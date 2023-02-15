//
// Copyright (c) 2023 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

// swiftlint:disable file_length identifier_name line_length number_separator trailing_comma

@testable import Histogram
import Numerics
import XCTest

// swiftlint:disable:next type_body_length
final class HistogramDataAccessTests: XCTestCase {
    private static let highestTrackableValue = UInt64(3600) * 1000 * 1000 // e.g. for 1 hr in usec units
    private static let numberOfSignificantValueDigits = SignificantDigits.three
    private static let value: UInt64 = 4

    private static var histogram = Histogram<UInt64>(highestTrackableValue: highestTrackableValue, numberOfSignificantValueDigits: numberOfSignificantValueDigits)

    private static var scaledHistogram = Histogram<UInt64>(
            lowestDiscernibleValue: 1000,
            highestTrackableValue: highestTrackableValue * 512,
            numberOfSignificantValueDigits: numberOfSignificantValueDigits)

    private static var rawHistogram = Histogram<UInt64>(highestTrackableValue: highestTrackableValue, numberOfSignificantValueDigits: numberOfSignificantValueDigits)

    private static var scaledRawHistogram = Histogram<UInt64>(
            lowestDiscernibleValue: 1000,
            highestTrackableValue: highestTrackableValue * 512,
            numberOfSignificantValueDigits: numberOfSignificantValueDigits)

    override class func setUp() {
        // Log hypothetical scenario: 100 seconds of "perfect" 1msec results, sampled
        // 100 times per second (10,000 results), followed by a 100 second pause with
        // a single (100 second) recorded result. Recording is done indicating an expected
        // interval between samples of 10 msec:
        for _ in 0..<10_000 {
            histogram.recordCorrectedValue(1000 /* 1 msec */, expectedInterval: 10_000 /* 10 msec expected interval */)
            scaledHistogram.recordCorrectedValue(1000 * 512 /* 1 msec */, expectedInterval: 10_000 * 512 /* 10 msec expected interval */)
            rawHistogram.record(1000 /* 1 msec */)
            scaledRawHistogram.record(1000 * 512/* 1 msec */)
        }
        histogram.recordCorrectedValue(100_000_000 /* 100 sec */, expectedInterval: 10_000 /* 10 msec expected interval */)
        scaledHistogram.recordCorrectedValue(100_000_000 * 512 /* 100 sec */, expectedInterval: 10_000 * 512 /* 10 msec expected interval */)
        rawHistogram.record(100_000_000 /* 100 sec */)
        scaledRawHistogram.record(100_000_000 * 512 /* 100 sec */)
    }

    func testScalingEquivalence() {
        XCTAssertEqual(Self.histogram.mean * 512, Self.scaledHistogram.mean, accuracy: Self.scaledHistogram.mean * 0.000001, "averages should be equivalent")
        XCTAssertEqual(Self.histogram.totalCount, Self.scaledHistogram.totalCount, "total count should be the same")
        XCTAssertEqual(Self.scaledHistogram.highestEquivalentForValue(Self.histogram.valueAtPercentile(99.0) * 512),
                       Self.scaledHistogram.highestEquivalentForValue(Self.scaledHistogram.valueAtPercentile(99.0)), "99%'iles should be equivalent")
        XCTAssertEqual(Self.scaledHistogram.highestEquivalentForValue(Self.histogram.max * 512), Self.scaledHistogram.max, "Max should be equivalent")
    }

    func testTotalCount() {
        // The overflow value should count in the total count:
        XCTAssertEqual(10_001, Self.rawHistogram.totalCount, "Raw total count is 10,001")
        XCTAssertEqual(20_000, Self.histogram.totalCount, "Total count is 20,000")
    }

    func testMax() {
        XCTAssertTrue(Self.histogram.valuesAreEquivalent(100 * 1000 * 1000, Self.histogram.max))
    }

    func testMin() {
        XCTAssertTrue(Self.histogram.valuesAreEquivalent(1000, Self.histogram.min))
    }

    func testMean() {
        let expectedRawMean = ((10_000.0 * 1000) + (1.0 * 100_000_000)) / 10_001 // direct avg. of raw results
        let expectedMean = (1000.0 + 50_000_000.0) / 2 // avg. 1 msec for half the time, and 50 sec for other half
        // We expect to see the mean to be accurate to ~3 decimal points (~0.1%):
        XCTAssertEqual(expectedRawMean, Self.rawHistogram.mean, accuracy: expectedRawMean * 0.001, "Raw mean is \(expectedRawMean) +/- 0.1%")
        XCTAssertEqual(expectedMean, Self.histogram.mean, accuracy: expectedMean * 0.001, "Mean is \(expectedMean) +/- 0.1%")
    }

    func testStdDeviation() {
        let expectedRawMean = ((10_000.0 * 1000) + (1.0 * 100_000_000)) / 10_001 // direct avg. of raw results
        let expectedRawStdDev = (((10_000.0 * .pow((1000.0 - expectedRawMean), 2)) + .pow((100_000_000.0 - expectedRawMean), 2)) / 10_001).squareRoot()

        let expectedMean = (1000.0 + 50_000_000.0) / 2 // avg. 1 msec for half the time, and 50 sec for other half
        var expectedSquareDeviationSum = 10_000 * .pow((1000.0 - expectedMean), 2)

        for value in stride(from: 10_000, through: 100_000_000, by: 10_000) {
            expectedSquareDeviationSum += .pow((Double(value) - expectedMean), 2)
        }

        let expectedStdDev = (expectedSquareDeviationSum / 20_000).squareRoot()

        // We expect to see the standard deviations to be accurate to ~3 decimal points (~0.1%):
        XCTAssertEqual(expectedRawStdDev, Self.rawHistogram.stdDeviation, accuracy: expectedRawStdDev * 0.001,
                       "Raw standard deviation is \(expectedRawStdDev) +/- 0.1%")
        XCTAssertEqual(expectedStdDev, Self.histogram.stdDeviation, accuracy: expectedStdDev * 0.001,
                       "Standard deviation is \(expectedStdDev) +/- 0.1%")
    }

    func testMedian() {
        var histogram = Histogram<UInt64>()

        XCTAssertEqual(histogram.median, 0)

        let cases: [(UInt64, UInt64)] = [
            (10, 10),
            (5, 5),
            (1, 5),
            (2, 2),
        ]

        for (add, expectedMedian) in cases {
            histogram.record(add)
            XCTAssertEqual(histogram.median, expectedMedian)
        }
    }

    func testValueAtPercentileExamples() {
        var hist = Histogram<UInt64>(highestTrackableValue: 3600_000_000, numberOfSignificantValueDigits: .three)

        hist.record(1)
        hist.record(2)

        XCTAssertEqual(1, hist.valueAtPercentile(50.0), "50.0%'ile is 1")
        XCTAssertEqual(1, hist.valueAtPercentile(50.00000000000001), "50.00000000000001%'ile is 1")
        XCTAssertEqual(2, hist.valueAtPercentile(50.0000000000001), "50.0000000000001%'ile is 2")

        hist.record(2)
        hist.record(2)
        hist.record(2)

        XCTAssertEqual(2, hist.valueAtPercentile(25.0), "25%'ile is 2")
        XCTAssertEqual(2, hist.valueAtPercentile(30.0), "30%'ile is 2")
    }

    func testValueAtPercentile() {
        XCTAssertEqual(1000.0, Double(Self.rawHistogram.valueAtPercentile(30.0)),
                       accuracy: 1000.0 * 0.001, "raw 30%'ile is 1 msec +/- 0.1%")
        XCTAssertEqual(1000.0, Double(Self.rawHistogram.valueAtPercentile(99.0)),
                       accuracy: 1000.0 * 0.001, "raw 99%'ile is 1 msec +/- 0.1%")
        XCTAssertEqual(1000.0, Double(Self.rawHistogram.valueAtPercentile(99.99)),
                       accuracy: 1000.0 * 0.001, "raw 99.99%'ile is 1 msec +/- 0.1%")

        XCTAssertEqual(100_000_000.0, Double(Self.rawHistogram.valueAtPercentile(99.999)),
                       accuracy: 100_000_000.0 * 0.001, "raw 99.999%'ile is 100 sec +/- 0.1%")
        XCTAssertEqual(100_000_000.0, Double(Self.rawHistogram.valueAtPercentile(100.0)),
                       accuracy: 100_000_000.0 * 0.001, "raw 100%'ile is 100 sec +/- 0.1%")

        XCTAssertEqual(1000.0, Double(Self.histogram.valueAtPercentile(30.0)),
                       accuracy: 1000.0 * 0.001, "30%'ile is 1 msec +/- 0.1%")
        XCTAssertEqual(1000.0, Double(Self.histogram.valueAtPercentile(50.0)),
                       accuracy: 1000.0 * 0.001, "50%'ile is 1 msec +/- 0.1%")

        XCTAssertEqual(50_000_000.0, Double(Self.histogram.valueAtPercentile(75.0)),
                       accuracy: 50_000_000.0 * 0.001, "75%'ile is 50 sec +/- 0.1%")

        XCTAssertEqual(80_000_000.0, Double(Self.histogram.valueAtPercentile(90.0)),
                       accuracy: 80_000_000.0 * 0.001, "90%'ile is 80 sec +/- 0.1%")
        XCTAssertEqual(98_000_000.0, Double(Self.histogram.valueAtPercentile(99.0)),
                       accuracy: 98_000_000.0 * 0.001, "99%'ile is 98 sec +/- 0.1%")
        XCTAssertEqual(100_000_000.0, Double(Self.histogram.valueAtPercentile(99.999)),
                       accuracy: 100_000_000.0 * 0.001, "99.999%'ile is 100 sec +/- 0.1%")
        XCTAssertEqual(100_000_000.0, Double(Self.histogram.valueAtPercentile(100.0)),
                       accuracy: 100_000_000.0 * 0.001, "100%'ile is 100 sec +/- 0.1%")
    }

    func testValueAtPercentileForLargeHistogram() {
        let largestValue: UInt64 = 1_000_000_000_000

        var h = Histogram<UInt64>(highestTrackableValue: largestValue, numberOfSignificantValueDigits: .five)

        h.record(largestValue)

        XCTAssertGreaterThan(h.valueAtPercentile(100.0), 0)
    }

    func testPercentileAtOrBelowValue() {
        XCTAssertEqual(99.99, Self.rawHistogram.percentileAtOrBelowValue(5000),
                       accuracy: 0.0001, "Raw percentile at or below 5 msec is 99.99% +/- 0.0001")
        XCTAssertEqual(50.0, Self.histogram.percentileAtOrBelowValue(5000),
                       accuracy: 0.0001, "Percentile at or below 5 msec is 50% +/- 0.0001%")
        XCTAssertEqual(100.0, Self.histogram.percentileAtOrBelowValue(100_000_000),
                       accuracy: 0.0001, "Percentile at or below 100 sec is 100% +/- 0.0001%")
    }

    func testCountWithinRange() {
        XCTAssertEqual(10_000, Self.rawHistogram.count(within: 1000...1000),
                       "Count of raw values between 1 msec and 1 msec is 1")
        XCTAssertEqual(1, Self.rawHistogram.count(within: 5000...150_000_000),
                       "Count of raw values between 5 msec and 150 sec is 1")
        XCTAssertEqual(10_000, Self.histogram.count(within: 5000...150_000_000),
                       "Count of values between 5 msec and 150 sec is 10,000")
    }

    func testCountForValue() {
        XCTAssertEqual(0, Self.rawHistogram.count(within: 10_000...10_010),
                       "Count of raw values at 10 msec is 0")
        XCTAssertEqual(1, Self.histogram.count(within: 10_000...10_010),
                       "Count of values at 10 msec is 0")
        XCTAssertEqual(10_000, Self.rawHistogram.countForValue(1000),
                       "Count of raw values at 1 msec is 10,000")
        XCTAssertEqual(10_000, Self.histogram.countForValue(1000),
                       "Count of values at 1 msec is 10,000")
    }

    func testPercentiles() {
        for iv in Self.histogram.percentiles(ticksPerHalfDistance: 5) {
            XCTAssertEqual(
                    iv.value, Self.histogram.highestEquivalentForValue(Self.histogram.valueAtPercentile(iv.percentile)),
                    "Iterator value: \(iv.value), count: \(iv.count), percentile: \(iv.percentile)\n" +
                    "histogram valueAtPercentile(\(iv.percentile)): \(Self.histogram.valueAtPercentile(iv.percentile)), " +
                    "highest equivalent value: \(Self.histogram.highestEquivalentForValue(Self.histogram.valueAtPercentile(iv.percentile)))")
        }
    }

    func testPercentileIterator() {
        typealias H = Histogram<UInt64> // swiftlint:disable:this type_name

        var histogram = H(highestTrackableValue: 10_000, numberOfSignificantValueDigits: .three)

        for i in 1...10 {
            histogram.record(UInt64(i))
        }

        let expected = [
            H.IterationValue(value: 1, prevValue: 0, count: 1, percentile: 10.0, percentileLevelIteratedTo: 0.0, countAddedInThisIterationStep: 1, totalCountToThisValue: 1, totalValueToThisValue: 1),
            H.IterationValue(value: 3, prevValue: 1, count: 1, percentile: 30.0, percentileLevelIteratedTo: 25.0, countAddedInThisIterationStep: 2, totalCountToThisValue: 3, totalValueToThisValue: 6),
            H.IterationValue(value: 5, prevValue: 3, count: 1, percentile: 50.0, percentileLevelIteratedTo: 50.0, countAddedInThisIterationStep: 2, totalCountToThisValue: 5, totalValueToThisValue: 15),
            H.IterationValue(value: 7, prevValue: 5, count: 1, percentile: 70.0, percentileLevelIteratedTo: 62.5, countAddedInThisIterationStep: 2, totalCountToThisValue: 7, totalValueToThisValue: 28),
            H.IterationValue(value: 8, prevValue: 7, count: 1, percentile: 80.0, percentileLevelIteratedTo: 75.0, countAddedInThisIterationStep: 1, totalCountToThisValue: 8, totalValueToThisValue: 36),
            H.IterationValue(value: 9, prevValue: 8, count: 1, percentile: 90.0, percentileLevelIteratedTo: 81.25, countAddedInThisIterationStep: 1, totalCountToThisValue: 9, totalValueToThisValue: 45),
            H.IterationValue(value: 9, prevValue: 9, count: 1, percentile: 90.0, percentileLevelIteratedTo: 87.5, countAddedInThisIterationStep: 0, totalCountToThisValue: 9, totalValueToThisValue: 45),
            H.IterationValue(value: 10, prevValue: 9, count: 1, percentile: 100.0, percentileLevelIteratedTo: 90.625, countAddedInThisIterationStep: 1, totalCountToThisValue: 10, totalValueToThisValue: 55),
            H.IterationValue(value: 10, prevValue: 10, count: 1, percentile: 100.0, percentileLevelIteratedTo: 100.0, countAddedInThisIterationStep: 0, totalCountToThisValue: 10, totalValueToThisValue: 55),
        ]

        let output = [H.IterationValue](histogram.percentiles(ticksPerHalfDistance: 2))

        XCTAssertEqual(output, expected)
    }

    func testLinearBucketValues() {
        // Note that using linear buckets should work "as expected" as long as the number of linear buckets
        // is lower than the resolution level determined by largestValueWithSingleUnitResolution
        // (2000 in this case). Above that count, some of the linear buckets can end up rounded up in size
        // (to the nearest local resolution unit level), which can result in a smaller number of buckets that
        // expected covering the range.

        // Iterate data using linear buckets of 100 msec each.
        var index = 0
        for iv in Self.rawHistogram.linearBucketValues(valueUnitsPerBucket: 100_000 /* 100 msec */) {
            let countAddedInThisBucket = iv.countAddedInThisIterationStep
            if index == 0 {
                XCTAssertEqual(10_000, countAddedInThisBucket, "Raw Linear 100 msec bucket # 0 added a count of 10000")
            } else if index == 999 {
                XCTAssertEqual(1, countAddedInThisBucket, "Raw Linear 100 msec bucket # 999 added a count of 1") } else {
                XCTAssertEqual(0, countAddedInThisBucket, "Raw Linear 100 msec bucket # \(index) added a count of 0")
            }
            index += 1
        }

        XCTAssertEqual(1000, index)

        // Iterate data using linear buckets of 10 msec each.
        index = 0
        var totalAddedCounts: UInt64 = 0
        for iv in Self.histogram.linearBucketValues(valueUnitsPerBucket: 10_000 /* 10 msec */) {
            let countAddedInThisBucket = iv.countAddedInThisIterationStep
            if index == 0 {
                XCTAssertEqual(10_000, countAddedInThisBucket, "Linear 1 sec bucket # 0 [\(iv.prevValue)..\(iv.value)] added a count of 10000")
            }
            // Because value resolution is low enough (3 digits) that multiple linear buckets will end up
            // residing in a single value-equivalent range, some linear buckets will have counts of 2 or
            // more, and some will have 0 (when the first bucket in the equivalent range was the one that
            // got the total count bump).
            // However, we can still verify the sum of counts added in all the buckets...
            totalAddedCounts += countAddedInThisBucket
            index += 1
        }

        XCTAssertEqual(10_000, index, "There should be 10000 linear buckets of size 10000 usec between 0 and 100 sec.")
        XCTAssertEqual(20_000, totalAddedCounts, "Total added counts should be 20000")

        // Iterate data using linear buckets of 1 msec each.
        index = 0
        totalAddedCounts = 0
        for iv in Self.histogram.linearBucketValues(valueUnitsPerBucket: 1000 /* 1 msec */) {
            let countAddedInThisBucket = iv.countAddedInThisIterationStep
            if index == 1 {
                XCTAssertEqual(10_000, countAddedInThisBucket, "Linear 1 sec bucket # 0 [\(iv.prevValue)..\(iv.value)] added a count of 10000")
            }
            // Because value resolution is low enough (3 digits) that multiple linear buckets will end up
            // residing in a single value-equivalent range, some linear buckets will have counts of 2 or
            // more, and some will have 0 (when the first bucket in the equivalent range was the one that
            // got the total count bump).
            // However, we can still verify the sum of counts added in all the buckets...
            totalAddedCounts += countAddedInThisBucket
            index += 1
        }
        // You may ask "why 100007 and not 100000?" for the value below? The answer is that at this fine
        // a linear stepping resolution, the final populated sub-bucket (at 100 seconds with 3 decimal
        // point resolution) is larger than our liner stepping, and holds more than one linear 1 msec
        // step in it.
        // Since we only know we're done with linear iteration when the next iteration step will step
        // out of the last populated bucket, there is not way to tell if the iteration should stop at
        // 100000 or 100007 steps. The proper thing to do is to run to the end of the sub-bucket quanta...
        XCTAssertEqual(100_007, index, "There should be 100007 linear buckets of size 1000 usec between 0 and 100 sec.")
        XCTAssertEqual(20_000, totalAddedCounts, "Total added counts should be 20000")
    }

    func testLogarithmicBucketValues() {
        // Iterate raw data using logarithmic buckets starting at 10 msec.
        var index = 0
        for iv in Self.rawHistogram.logarithmicBucketValues(valueUnitsInFirstBucket: 10_000 /* 10 msec */, logBase: 2) {
            let countAddedInThisBucket = iv.countAddedInThisIterationStep
            if index == 0 {
                XCTAssertEqual(10_000, countAddedInThisBucket, "Raw Logarithmic 10 msec bucket # 0 added a count of 10000")
            } else if index == 14 {
                XCTAssertEqual(1, countAddedInThisBucket, "Raw Logarithmic 10 msec bucket # 14 added a count of 1")
            } else {
                XCTAssertEqual(0, countAddedInThisBucket, "Raw Logarithmic 100 msec bucket # \(index) added a count of 0")
            }
            index += 1
        }
        XCTAssertEqual(14, index - 1)

        index = 0
        var totalAddedCounts: UInt64 = 0
        for iv in Self.histogram.logarithmicBucketValues(valueUnitsInFirstBucket: 10_000 /* 10 msec */, logBase: 2) {
            let countAddedInThisBucket = iv.countAddedInThisIterationStep
            if index == 0 {
                XCTAssertEqual(10_000, countAddedInThisBucket,
                               "Logarithmic 10 msec bucket # 0 [\(iv.prevValue)..\(iv.value)] added a count of 10000")
            }
            totalAddedCounts += countAddedInThisBucket
            index += 1
        }
        XCTAssertEqual(14, index - 1, "There should be 14 Logarithmic buckets of size 10000 usec between 0 and 100 sec.")
        XCTAssertEqual(20_000, totalAddedCounts, "Total added counts should be 20000")
    }

    func testRecordedValues() {
        // Iterate raw data by stepping through every value that has a count recorded:
        var index = 0
        for iv in Self.rawHistogram.recordedValues() {
            let countAddedInThisBucket = iv.countAddedInThisIterationStep
            if index == 0 {
                XCTAssertEqual(10_000, countAddedInThisBucket, "Raw recorded value bucket # 0 added a count of 10000")
            } else {
                XCTAssertEqual(1, countAddedInThisBucket, "Raw recorded value bucket # \(index) added a count of 1")
            }
            index += 1
        }
        XCTAssertEqual(2, index)

        index = 0
        var totalAddedCounts: UInt64 = 0
        for iv in Self.histogram.recordedValues() {
            let countAddedInThisBucket = iv.countAddedInThisIterationStep
            if index == 0 {
                XCTAssertEqual(10_000, countAddedInThisBucket,
                               "Recorded bucket # 0 [\(iv.prevValue)..\(iv.value)] added a count of 10000")
            }
            XCTAssertNotEqual(iv.count, 0, "The count in recorded bucket #\(index) is not 0")
            XCTAssertEqual(iv.count, countAddedInThisBucket,
                           "The count in recorded bucket # \(index)" +
                           " is exactly the amount added since the last iteration")
            totalAddedCounts += countAddedInThisBucket
            index += 1
        }
        XCTAssertEqual(20_000, totalAddedCounts, "Total added counts should be 20000")
    }

    func testAllValues() {
        var index = 0
        var totalCountToThisPoint: UInt64 = 0
        var totalValueToThisPoint: UInt64 = 0

        // Iterate raw data by stepping through every value that has a count recorded:
        for v in Self.rawHistogram.allValues() {
            let countAddedInThisBucket = v.countAddedInThisIterationStep
            if index == 1000 {
                XCTAssertEqual(10_000, countAddedInThisBucket, "Raw allValues bucket # 0 added a count of 10000")
            } else if Self.histogram.valuesAreEquivalent(v.value, 100_000_000) {
                XCTAssertEqual(1, countAddedInThisBucket, "Raw allValues value bucket # \(index) added a count of 1")
            } else {
                XCTAssertEqual(0, countAddedInThisBucket, "Raw allValues value bucket # \(index) added a count of 0")
            }
            totalCountToThisPoint += v.count
            XCTAssertEqual(totalCountToThisPoint, v.totalCountToThisValue, "total Count should match")
            totalValueToThisPoint += UInt64(v.count) * v.value
            XCTAssertEqual(totalValueToThisPoint, v.totalValueToThisValue, "total Value should match")
            index += 1
        }
        XCTAssertEqual(Self.histogram.counts.count, index, "index should be equal to counts array length")

        index = 0
        var totalAddedCounts: UInt64 = 0

        for v in Self.histogram.allValues() {
            let countAddedInThisBucket = v.countAddedInThisIterationStep
            if index == 1000 {
                XCTAssertEqual(10_000, countAddedInThisBucket,
                               "AllValues bucket # 0 [\(v.prevValue)..\(v.value)] added a count of 10000")
            }
            XCTAssertEqual(v.count, countAddedInThisBucket,
                           "The count in AllValues bucket # \(index)" +
                           " is exactly the amount added since the last iteration")
            totalAddedCounts += countAddedInThisBucket
            XCTAssertTrue(Self.histogram.valuesAreEquivalent(Self.histogram.valueFromIndex(index), v.value), "valueFromIndex() should be equal to value")
            index += 1
        }
        XCTAssertEqual(Self.histogram.counts.count, index, "index should be equal to counts array length")
        XCTAssertEqual(20_000, totalAddedCounts, "Total added counts should be 20000")
    }

    func testLinearIteratorSteps() {
        var histogram = Histogram<UInt64>(highestTrackableValue: 10_000, numberOfSignificantValueDigits: .two)

        for v: UInt64 in [193, 0, 1, 64, 128] {
            histogram.record(v)
        }

        var stepCount = 0
        for _ in histogram.linearBucketValues(valueUnitsPerBucket: 64) {
            stepCount += 1
        }

        XCTAssertEqual(4, stepCount, "should see 4 steps")
    }

    func testLinearIteratorVisitsBucketsWiderThanStepSizeMultipleTimes() {
        var h = Histogram<UInt64>(lowestDiscernibleValue: 1, highestTrackableValue: UInt64.max, numberOfSignificantValueDigits: .three)

        h.record(1)
        h.record(2047)
        // bucket size 2
        h.record(2048)
        h.record(2049)
        h.record(4095)
        // bucket size 4
        h.record(4096)
        h.record(4097)
        h.record(4098)
        h.record(4099)
        // 2nd bucket in size 4
        h.record(4100)

        struct IteratorValueSnapshot: Equatable {
            let value: UInt64
            let count: UInt64
        }

        var snapshots: [IteratorValueSnapshot] = []

        for iv in h.linearBucketValues(valueUnitsPerBucket: 1) {
            snapshots.append(IteratorValueSnapshot(value: iv.value, count: iv.countAddedInThisIterationStep))
        }

        // bucket size 1
        XCTAssertEqual(IteratorValueSnapshot(value: 0, count: 0), snapshots[0])
        XCTAssertEqual(IteratorValueSnapshot(value: 1, count: 1), snapshots[1])
        XCTAssertEqual(IteratorValueSnapshot(value: 2046, count: 0), snapshots[2046])
        XCTAssertEqual(IteratorValueSnapshot(value: 2047, count: 1), snapshots[2047])
        // bucket size 2
        XCTAssertEqual(IteratorValueSnapshot(value: 2048, count: 2), snapshots[2048])
        XCTAssertEqual(IteratorValueSnapshot(value: 2049, count: 0), snapshots[2049])
        XCTAssertEqual(IteratorValueSnapshot(value: 2050, count: 0), snapshots[2050])
        XCTAssertEqual(IteratorValueSnapshot(value: 2051, count: 0), snapshots[2051])
        XCTAssertEqual(IteratorValueSnapshot(value: 4094, count: 1), snapshots[4094])
        XCTAssertEqual(IteratorValueSnapshot(value: 4095, count: 0), snapshots[4095])
        // bucket size 4
        XCTAssertEqual(IteratorValueSnapshot(value: 4096, count: 4), snapshots[4096])
        XCTAssertEqual(IteratorValueSnapshot(value: 4097, count: 0), snapshots[4097])
        XCTAssertEqual(IteratorValueSnapshot(value: 4098, count: 0), snapshots[4098])
        XCTAssertEqual(IteratorValueSnapshot(value: 4099, count: 0), snapshots[4099])
        // also size 4, count: last bucket
        XCTAssertEqual(IteratorValueSnapshot(value: 4100, count: 1), snapshots[4100])
        XCTAssertEqual(IteratorValueSnapshot(value: 4101, count: 0), snapshots[4101])
        XCTAssertEqual(IteratorValueSnapshot(value: 4102, count: 0), snapshots[4102])
        XCTAssertEqual(IteratorValueSnapshot(value: 4103, count: 0), snapshots[4103])

        XCTAssertEqual(4104, snapshots.count)
    }
}
