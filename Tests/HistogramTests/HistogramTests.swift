//
// Copyright (c) 2023 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

import Numerics
import XCTest
@testable import Histogram


final class HistogramTests: XCTestCase {
    static let highestTrackableValue = UInt64(3_600) * 1_000 * 1_000 // e.g. for 1 hr in usec units
    static let numberOfSignificantValueDigits = SignificantDigits.three
    static let value: UInt64 = 4

    func testCreate() throws {
        let h = Histogram<UInt64>(lowestDiscernibleValue: 1, highestTrackableValue: 3_600_000_000, numberOfSignificantValueDigits: .three)
        XCTAssertEqual(h.counts.count, 23_552)
    }

    func testUnitMagnitude0IndexCalculations() throws {
        let h = Histogram<UInt64>(lowestDiscernibleValue: 1, highestTrackableValue: UInt64(1) << 32, numberOfSignificantValueDigits: .three)

        XCTAssertEqual(2048, h.subBucketCount)
        XCTAssertEqual(0, h.unitMagnitude)
        // subBucketCount = 2^11, so 2^11 << 22 is > the max of 2^32 for 23 buckets total
        XCTAssertEqual(23, h.bucketCount)

        // first half of first bucket
        XCTAssertEqual(0, h.bucketIndexForValue(3))
        XCTAssertEqual(3, h.subBucketIndexForValue(3, bucketIndex: 0))

        // second half of first bucket
        XCTAssertEqual(0, h.bucketIndexForValue(1024 + 3))
        XCTAssertEqual(1024 + 3, h.subBucketIndexForValue(1024 + 3, bucketIndex: 0))

        // second bucket (top half)
        XCTAssertEqual(1, h.bucketIndexForValue(2048 + 3 * 2))
        // counting by 2s, starting at halfway through the bucket
        XCTAssertEqual(1024 + 3, h.subBucketIndexForValue(2048 + 3 * 2, bucketIndex: 1))

        // third bucket (top half)
        XCTAssertEqual(2, h.bucketIndexForValue((2048 << 1) + 3 * 4))
        // counting by 4s, starting at halfway through the bucket
        XCTAssertEqual(1024 + 3, h.subBucketIndexForValue((2048 << 1) + 3 * 4, bucketIndex: 2))

        // past last bucket -- not near UInt64.max, so should still calculate ok.
        XCTAssertEqual(23, h.bucketIndexForValue((UInt64(2048) << 22) + 3 * (1 << 23)))
        XCTAssertEqual(1024 + 3, h.subBucketIndexForValue((UInt64(2048) << 22) + 3 * (1 << 23), bucketIndex: 23))
    }

    func testUnitMagnitude4IndexCalculations() throws {
        let h = Histogram<UInt64>(lowestDiscernibleValue: 1 << 12, highestTrackableValue: 1 << 32, numberOfSignificantValueDigits: .three)

        XCTAssertEqual(2048, h.subBucketCount)
        XCTAssertEqual(12, h.unitMagnitude)
        // subBucketCount = 2^11. With unit magnitude shift, it's 2^23. 2^23 << 10 is > the max of 2^32 for 11 buckets total
        XCTAssertEqual(11, h.bucketCount)

        let unit: UInt64 = 1 << 12

        // below lowest value
        XCTAssertEqual(0, h.bucketIndexForValue(3))
        XCTAssertEqual(0, h.subBucketIndexForValue(3, bucketIndex: 0))

        // first half of first bucket
        XCTAssertEqual(0, h.bucketIndexForValue(3 * unit))
        XCTAssertEqual(3, h.subBucketIndexForValue(3 * unit, bucketIndex: 0))

        // second half of first bucket
        // subBucketHalfCount's worth of units, plus 3 more
        XCTAssertEqual(0, h.bucketIndexForValue(unit * (1024 + 3)))
        XCTAssertEqual(1024 + 3, h.subBucketIndexForValue(unit * (1024 + 3), bucketIndex: 0))

        // second bucket (top half), bucket scale = unit << 1.
        // Middle of bucket is (subBucketHalfCount = 2^10) of bucket scale, = unit << 11.
        // Add on 3 of bucket scale.
        XCTAssertEqual(1, h.bucketIndexForValue((unit << 11) + 3 * (unit << 1)))
        XCTAssertEqual(1024 + 3, h.subBucketIndexForValue((unit << 11) + 3 * (unit << 1), bucketIndex: 1))

        // third bucket (top half), bucket scale = unit << 2.
        // Middle of bucket is (subBucketHalfCount = 2^10) of bucket scale, = unit << 12.
        // Add on 3 of bucket scale.
        XCTAssertEqual(2, h.bucketIndexForValue((unit << 12) + 3 * (unit << 2)))
        XCTAssertEqual(1024 + 3, h.subBucketIndexForValue((unit << 12) + 3 * (unit << 2), bucketIndex: 2))

        // past last bucket -- not near UInt64.max, so should still calculate ok.
        XCTAssertEqual(11, h.bucketIndexForValue((unit << 21) + 3 * (unit << 11)))
        XCTAssertEqual(1024 + 3, h.subBucketIndexForValue((unit << 21) + 3 * (unit << 11), bucketIndex: 11))
    }

    func testUnitMagnitude51SubBucketMagnitude11IndexCalculations() throws {
        // maximum unit magnitude for this precision
        let h = Histogram<UInt64>(lowestDiscernibleValue: UInt64(1) << 51, highestTrackableValue: UInt64(Int64.max), numberOfSignificantValueDigits: .three)

        XCTAssertEqual(2048, h.subBucketCount)
        XCTAssertEqual(51, h.unitMagnitude)
        // subBucketCount = 2^11. With unit magnitude shift, it's 2^62. 1 more bucket to (almost) reach 2^63.
        XCTAssertEqual(2, h.bucketCount)
        XCTAssertEqual(2, h.leadingZeroCountBase)

        let unit = UInt64(1) << 51

        // below lowest value
        XCTAssertEqual(0, h.bucketIndexForValue(3))
        XCTAssertEqual(0, h.subBucketIndexForValue(3, bucketIndex: 0))

        // first half of first bucket
        XCTAssertEqual(0, h.bucketIndexForValue(3 * unit))
        XCTAssertEqual(3, h.subBucketIndexForValue(3 * unit, bucketIndex: 0))

        // second half of first bucket
        // subBucketHalfCount's worth of units, plus 3 more
        XCTAssertEqual(0, h.bucketIndexForValue(unit * (1024 + 3)))
        XCTAssertEqual(1024 + 3, h.subBucketIndexForValue(unit * (1024 + 3), bucketIndex: 0))

        // end of second half
        XCTAssertEqual(0, h.bucketIndexForValue(unit * 1024 + 1023 * unit))
        XCTAssertEqual(1024 + 1023, h.subBucketIndexForValue(unit * 1024 + 1023 * unit, bucketIndex: 0))

        // second bucket (top half), bucket scale = unit << 1.
        // Middle of bucket is (subBucketHalfCount = 2^10) of bucket scale, = unit << 11.
        // Add on 3 of bucket scale.
        XCTAssertEqual(1, h.bucketIndexForValue((unit << 11) + 3 * (unit << 1)))
        XCTAssertEqual(1024 + 3, h.subBucketIndexForValue((unit << 11) + 3 * (unit << 1), bucketIndex: 1))

        // upper half of second bucket, last slot
        XCTAssertEqual(1, h.bucketIndexForValue(UInt64(Int64.max)))
        XCTAssertEqual(1024 + 1023, h.subBucketIndexForValue(UInt64(Int64.max), bucketIndex: 1))
    }

    func testUnitMagnitude52SubBucketMagnitude11Throws() throws {
        /* Cannot catch fatal errors.
        let h = Histogram<UInt64>(lowestDiscernibleValue: UInt64(1) << 52, highestTrackableValue: UInt64(1) << 62, numberOfSignificantValueDigits: .three)
        XCTAssertNil(h)
        */
    }

    func testUnitMagnitude54SubBucketMagnitude8Ok() throws {
        let h = Histogram<UInt64>(lowestDiscernibleValue: UInt64(1) << 54, highestTrackableValue: UInt64(1) << 62, numberOfSignificantValueDigits: .two)

        XCTAssertEqual(256, h.subBucketCount)
        XCTAssertEqual(54, h.unitMagnitude)
        // subBucketCount = 2^8. With unit magnitude shift, it's 2^62.
        XCTAssertEqual(2, h.bucketCount)

        // below lowest value
        XCTAssertEqual(0, h.bucketIndexForValue(3))
        XCTAssertEqual(0, h.subBucketIndexForValue(3, bucketIndex: 0))

        // upper half of second bucket, last slot
        XCTAssertEqual(1, h.bucketIndexForValue(UInt64(Int64.max)))
        XCTAssertEqual(128 + 127, h.subBucketIndexForValue(UInt64(Int64.max), bucketIndex: 1))
    }

    func testUnitMagnitude61SubBucketMagnitude0Ok() throws {
        let h = Histogram<UInt64>(lowestDiscernibleValue: UInt64(1) << 61, highestTrackableValue: UInt64(1) << 62, numberOfSignificantValueDigits: .zero)

        XCTAssertEqual(2, h.subBucketCount)
        XCTAssertEqual(61, h.unitMagnitude)
        // subBucketCount = 2^1. With unit magnitude shift, it's 2^62. 1 more bucket to be > the max of 2^62.
        XCTAssertEqual(2, h.bucketCount)

        // below lowest value
        XCTAssertEqual(0, h.bucketIndexForValue(3))
        XCTAssertEqual(0, h.subBucketIndexForValue(3, bucketIndex: 0))

        // upper half of second bucket, last slot
        XCTAssertEqual(1, h.bucketIndexForValue(UInt64(Int64.max)))
        XCTAssertEqual(1, h.subBucketIndexForValue(UInt64(Int64.max), bucketIndex: 1))
    }

    func testRecordValue() throws {
        var h = Histogram<UInt64>(highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        h.record(Self.value)

        XCTAssertEqual(1, h.countForValue(Self.value))
        XCTAssertEqual(1, h.totalCount)

        // try to record value above highest
        XCTAssertFalse(h.record(Self.highestTrackableValue * 2))

        XCTAssertEqual(1, h.countForValue(Self.value))
        XCTAssertEqual(1, h.totalCount)

        self.verifyMaxValue(histogram: h)
    }

    func testConstructionWithLargeNumbers() throws {
        var h = Histogram<UInt64>(lowestDiscernibleValue: 20_000_000, highestTrackableValue: 100_000_000, numberOfSignificantValueDigits: .five)

        h.record(100_000_000)
        h.record(20_000_000)
        h.record(30_000_000)

        XCTAssertTrue(h.valuesAreEquivalent(h.valueAtPercentile(50.0), 20_000_000))
        XCTAssertTrue(h.valuesAreEquivalent(h.valueAtPercentile(50.0), 30_000_000))
        XCTAssertTrue(h.valuesAreEquivalent(h.valueAtPercentile(83.33), 100_000_000))
        XCTAssertTrue(h.valuesAreEquivalent(h.valueAtPercentile(83.34), 100_000_000))
        XCTAssertTrue(h.valuesAreEquivalent(h.valueAtPercentile(99.0), 100_000_000))
    }

    func testValueAtPercentileMatchesPercentile() throws {
        let lengths: [UInt64] = [ 1, 5, 10, 50, 100, 500, 1000, 5000, 10_000, 50_000, 100_000 ]

        for length in lengths {
            var h = Histogram<UInt64>(lowestDiscernibleValue: 1, highestTrackableValue: UInt64.max, numberOfSignificantValueDigits: .two)

            for value in 1...length {
                h.record(value)
            }

            var value: UInt64 = 1
            while value <= length {
                let calculatedPercentile = 100.0 * (Double(value) / Double(length))
                let lookupValue = h.valueAtPercentile(calculatedPercentile)
                XCTAssertTrue(h.valuesAreEquivalent(value, lookupValue))

                value = h.nextNonEquivalentForValue(value)
            }
        }
    }

    func testValueAtPercentileMatchesPercentileIter() throws {
        let lengths: [UInt64] = [ 1, 5, 10, 50, 100, 500, 1000, 5000, 10_000, 50_000, 100_000 ]

        for length in lengths {
            var h = Histogram<UInt64>(lowestDiscernibleValue: 1, highestTrackableValue: UInt64.max, numberOfSignificantValueDigits: .two)

            for value in 1...length {
                h.record(value)
            }

            for v in h.percentiles(ticksPerHalfDistance: 1000) {
                let calculatedValue = h.valueAtPercentile(v.percentile)
                let iterValue = v.value

                XCTAssertTrue(h.valuesAreEquivalent(calculatedValue, iterValue),
                              "length: \(length) percentile: \(v.percentile) calculatedValue: \(calculatedValue) iterValue: \(iterValue) [should be \(calculatedValue)]")
            }
        }
    }

    func testRecordValueWithExpectedInterval() throws {
        var histogram = Histogram<UInt64>(highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        let value = Self.value

        histogram.recordCorrectedValue(value, expectedInterval: value / 4)

        var rawHistogram = Histogram<UInt64>(highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)
        rawHistogram.record(value)

        // The data will include corrected samples:
        XCTAssertEqual(1, histogram.countForValue((value * 1) / 4))
        XCTAssertEqual(1, histogram.countForValue((value * 2) / 4))
        XCTAssertEqual(1, histogram.countForValue((value * 3) / 4))
        XCTAssertEqual(1, histogram.countForValue((value * 4) / 4))
        XCTAssertEqual(4, histogram.totalCount)

        // But the raw data will not:
        XCTAssertEqual(0, rawHistogram.countForValue((value * 1) / 4))
        XCTAssertEqual(0, rawHistogram.countForValue((value * 2) / 4))
        XCTAssertEqual(0, rawHistogram.countForValue((value * 3) / 4))
        XCTAssertEqual(1, rawHistogram.countForValue((value * 4) / 4))
        XCTAssertEqual(1, rawHistogram.totalCount)

        self.verifyMaxValue(histogram: histogram)
    }

    func testReset() {
        var histogram = Histogram<UInt64>(highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        let testValueLevel: UInt64 = 4

        histogram.record(testValueLevel)
        histogram.record(10)
        histogram.record(100)

        XCTAssertEqual(histogram.min, min(10, testValueLevel))
        XCTAssertEqual(histogram.max, max(100, testValueLevel))

        histogram.reset()
        XCTAssertEqual(0, histogram.countForValue(testValueLevel))
        XCTAssertEqual(0, histogram.totalCount)

        verifyMaxValue(histogram: histogram)

        histogram.record(20)
        histogram.record(80)

        XCTAssertEqual(histogram.min, 20)
        XCTAssertEqual(histogram.max, 80)
    }

    func testScaledSizeOfEquivalentValueRange() throws {
        let histogram = Histogram<UInt64>(lowestDiscernibleValue: 1024, highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        XCTAssertEqual(1 * 1024, histogram.sizeOfEquivalentRangeForValue(1 * 1024))
        XCTAssertEqual(2 * 1024, histogram.sizeOfEquivalentRangeForValue(2500 * 1024))
        XCTAssertEqual(4 * 1024, histogram.sizeOfEquivalentRangeForValue(8191 * 1024))
        XCTAssertEqual(8 * 1024, histogram.sizeOfEquivalentRangeForValue(8192 * 1024))
        XCTAssertEqual(8 * 1024, histogram.sizeOfEquivalentRangeForValue(10_000 * 1024))

        self.verifyMaxValue(histogram: histogram)
    }

    func testLowestEquivalentValue() throws {
        let histogram = Histogram<UInt64>(highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        XCTAssertEqual(10_000, histogram.lowestEquivalentForValue(10_007))
        XCTAssertEqual(10_008, histogram.lowestEquivalentForValue(10_009))

        self.verifyMaxValue(histogram: histogram)
    }

    func testScaledLowestEquivalentValue() throws {
        let histogram = Histogram<UInt64>(lowestDiscernibleValue: 1024, highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        XCTAssertEqual(10_000 * 1024, histogram.lowestEquivalentForValue(10_007 * 1024))
        XCTAssertEqual(10_008 * 1024, histogram.lowestEquivalentForValue(10_009 * 1024))

        self.verifyMaxValue(histogram: histogram)
    }

    func testHighestEquivalentValue() throws {
        let histogram = Histogram<UInt64>(highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        XCTAssertEqual(8183, histogram.highestEquivalentForValue(8180))
        XCTAssertEqual(8191, histogram.highestEquivalentForValue(8191))
        XCTAssertEqual(8199, histogram.highestEquivalentForValue(8193))
        XCTAssertEqual(9999, histogram.highestEquivalentForValue(9995))
        XCTAssertEqual(10_007, histogram.highestEquivalentForValue(10_007))
        XCTAssertEqual(10_015, histogram.highestEquivalentForValue(10_008))

        self.verifyMaxValue(histogram: histogram)
    }

    func testScaledHighestEquivalentValue() throws {
        let histogram = Histogram<UInt64>(lowestDiscernibleValue: 1024, highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        XCTAssertEqual(8183 * 1024 + 1023, histogram.highestEquivalentForValue(8180 * 1024))
        XCTAssertEqual(8191 * 1024 + 1023, histogram.highestEquivalentForValue(8191 * 1024))
        XCTAssertEqual(8199 * 1024 + 1023, histogram.highestEquivalentForValue(8193 * 1024))
        XCTAssertEqual(9999 * 1024 + 1023, histogram.highestEquivalentForValue(9995 * 1024))
        XCTAssertEqual(10_007 * 1024 + 1023, histogram.highestEquivalentForValue(10_007 * 1024))
        XCTAssertEqual(10_015 * 1024 + 1023, histogram.highestEquivalentForValue(10_008 * 1024))

        self.verifyMaxValue(histogram: histogram)
    }

    func testEquivalentRangeForValue() {
        let histogram = Histogram<UInt64>(highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        XCTAssertEqual(histogram.equivalentRangeForValue(10_004), 10_000 ... 10_007)
        XCTAssertEqual(histogram.equivalentRangeForValue(10_009), 10_008 ... 10_015)
    }

    func testMedianEquivalentValue() throws {
        let histogram = Histogram<UInt64>(highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        XCTAssertEqual(4, histogram.medianEquivalentForValue(4))
        XCTAssertEqual(5, histogram.medianEquivalentForValue(5))
        XCTAssertEqual(4001, histogram.medianEquivalentForValue(4000))
        XCTAssertEqual(8002, histogram.medianEquivalentForValue(8000))
        XCTAssertEqual(10_004, histogram.medianEquivalentForValue(10_007))

        self.verifyMaxValue(histogram: histogram)
    }

    func testEstimatedFootprintInBytes() {
        let histogram = Histogram<UInt64>(highestTrackableValue: Self.highestTrackableValue, numberOfSignificantValueDigits: Self.numberOfSignificantValueDigits)

        /*
         *     largestValueWithSingleUnitResolution = 2 * (10 ^ numberOfSignificantValueDigits)
         *     subBucketSize = roundedUpToNearestPowerOf2(largestValueWithSingleUnitResolution)
         *
         *     expectedHistogramFootprintInBytes = {histogram object size} +
         *          ({primitive type size} / 2) *
         *          (log2RoundedUp((trackableValueRangeSize) / subBucketSize) + 2) *
         *          subBucketSize
         */
        let largestValueWithSingleUnitResolution = 2 * Int(.pow(10.0, Int(histogram.numberOfSignificantValueDigits.rawValue)))
        let subBucketCountMagnitude = Int((Double.log2(Double(largestValueWithSingleUnitResolution))).rounded(.up))
        let subBucketSize = 1 << subBucketCountMagnitude

        let a = Int((Double.log2(Double(histogram.highestTrackableValue / UInt64(subBucketSize)))).rounded(.up)) + 2
        let b = 1 << (64 - largestValueWithSingleUnitResolution.leadingZeroBitCount)
        let bucketsCount = a * b / 2

        XCTAssertEqual(bucketsCount, histogram.counts.count)

        let expectedSize = 512 + // histogram object size
                           histogram.counts.capacity * MemoryLayout<UInt64>.stride

        XCTAssertEqual(expectedSize, histogram.estimatedFootprintInBytes)

        verifyMaxValue(histogram: histogram)
    }

    func testOutputPercentileDistributionPlainText() {
        var histogram = Histogram<UInt64>(highestTrackableValue: 10_000, numberOfSignificantValueDigits: .three)

        for i in 1...10 {
            histogram.record(UInt64(i))
        }

        var output = ""
        histogram.outputPercentileDistribution(to: &output, outputValueUnitScalingRatio: 1.0, percentileTicksPerHalfDistance: 5, format: .plainText)

        let expectedOutput = """
       Value     Percentile TotalCount 1/(1-Percentile)

       1.000 0.000000000000          1           1.00
       1.000 0.100000000000          1           1.11
       2.000 0.200000000000          2           1.25
       3.000 0.300000000000          3           1.43
       4.000 0.400000000000          4           1.67
       5.000 0.500000000000          5           2.00
       6.000 0.550000000000          6           2.22
       6.000 0.600000000000          6           2.50
       7.000 0.650000000000          7           2.86
       7.000 0.700000000000          7           3.33
       8.000 0.750000000000          8           4.00
       8.000 0.775000000000          8           4.44
       8.000 0.800000000000          8           5.00
       9.000 0.825000000000          9           5.71
       9.000 0.850000000000          9           6.67
       9.000 0.875000000000          9           8.00
       9.000 0.887500000000          9           8.89
       9.000 0.900000000000          9          10.00
      10.000 0.912500000000         10          11.43
      10.000 1.000000000000         10
#[Mean    =        5.500, StdDeviation   =        2.872]
#[Max     =       10.000, Total count    =           10]
#[Buckets =            4, SubBuckets     =         2048]

"""

        XCTAssertEqual(output, expectedOutput)
    }

    func testOutputPercentileDistributionCsv() {
        var histogram = Histogram<UInt64>(highestTrackableValue: 10_000, numberOfSignificantValueDigits: .three)

        for i in 1...10 {
            histogram.record(UInt64(i))
        }

        var output = ""
        histogram.outputPercentileDistribution(to: &output, outputValueUnitScalingRatio: 1.0, percentileTicksPerHalfDistance: 5, format: .csv)

        let expectedOutput = """
"Value","Percentile","TotalCount","1/(1-Percentile)"
1.000,0.000000000000,1,1.00
1.000,0.100000000000,1,1.11
2.000,0.200000000000,2,1.25
3.000,0.300000000000,3,1.43
4.000,0.400000000000,4,1.67
5.000,0.500000000000,5,2.00
6.000,0.550000000000,6,2.22
6.000,0.600000000000,6,2.50
7.000,0.650000000000,7,2.86
7.000,0.700000000000,7,3.33
8.000,0.750000000000,8,4.00
8.000,0.775000000000,8,4.44
8.000,0.800000000000,8,5.00
9.000,0.825000000000,9,5.71
9.000,0.850000000000,9,6.67
9.000,0.875000000000,9,8.00
9.000,0.887500000000,9,8.89
9.000,0.900000000000,9,10.00
10.000,0.912500000000,10,11.43
10.000,1.000000000000,10,Infinity

"""

        XCTAssertEqual(output, expectedOutput)
    }

    func verifyMaxValue(histogram h: Histogram<UInt64>) {
        var computedMaxValue: UInt64 = 0
        for i in 0..<h.counts.count {
            if h.counts[i] > 0 {
                computedMaxValue = h.valueFromIndex(i)
            }
        }
        computedMaxValue = (computedMaxValue == 0) ? 0 : h.highestEquivalentForValue(computedMaxValue)
        XCTAssertEqual(computedMaxValue, h.maxValue)
    }
}
