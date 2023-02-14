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
import TextTable

/**
 * Number of significant digits for values recorded in histogram.
 */
public enum SignificantDigits: Int8 {
    case zero, one, two, three, four, five
}

/**
 * Histogram output format.
 */
public enum HistogramOutputFormat {
    case plainText
    case csv
}

/**
 * # A High Dynamic Range (HDR) Histogram.
 *
 * ``Histogram`` supports the recording and analyzing sampled data value counts across a configurable integer value
 * range with configurable value precision within the range. Value precision is expressed as the number of significant
 * digits in the value recording, and provides control over value quantization behavior across the value range and the
 * subsequent value resolution at any given level.
 *
 * For example, a ``Histogram`` could be configured to track the counts of observed integer values between 0 and
 * 3,600,000,000 while maintaining a value precision of 3 significant digits across that range. Value quantization
 * within the range will thus be no larger than 1/1,000th (or 0.1%) of any value. This example Histogram could
 * be used to track and analyze the counts of observed response times ranging between 1 microsecond and 1 hour
 * in magnitude, while maintaining a value resolution of 1 microsecond up to 1 millisecond, a resolution of
 * 1 millisecond (or better) up to one second, and a resolution of 1 second (or better) up to 1,000 seconds. At its
 * maximum tracked value (1 hour), it would still maintain a resolution of 3.6 seconds (or better).
 *
 * Histogram tracks value counts in fields of provided unsigned integer type.
 *
 * Auto-resizing: When constructed with no specified value range range (or when auto-resize is turned on with
 * ``autoResize``) a ``Histogram`` will auto-resize its dynamic range to include recorded values as
 * they are encountered. Note that recording calls that cause auto-resizing may take longer to execute, as resizing
 * incurs allocation and copying of internal data structures.
 */

public struct Histogram<Count: FixedWidthInteger> {
    /// The lowest value that can be discerned (distinguished from 0) by the histogram.
    public let lowestDiscernibleValue: UInt64

    /// The highest value to be tracked by the histogram.
    public private(set) var highestTrackableValue: UInt64

    var bucketCount: Int

    /**
     * Power-of-two length of linearly scaled array slots in the counts array. Long enough to hold the first sequence of
     * entries that must be distinguished by a single unit (determined by configured precision).
     */
    var subBucketCount: Int { 1 << (subBucketHalfCountMagnitude + 1) }
    var subBucketHalfCount: Int { 1 << subBucketHalfCountMagnitude }

    // Biggest value that can fit in bucket 0
    let subBucketMask: UInt64

    @usableFromInline
    var maxValue: UInt64 = 0

    @usableFromInline
    var minNonZeroValue: UInt64 = .max

    @usableFromInline
    var counts: [Count]

    @usableFromInline
    var _totalCount: UInt64 = 0

    /// Total count of all recorded values in the histogram
    public var totalCount: UInt64 { _totalCount }

    /// The number of significant decimal digits to which the histogram will maintain value resolution and separation.
    public let numberOfSignificantValueDigits: SignificantDigits

    /// Control whether or not the histogram can auto-resize and auto-adjust its ``highestTrackableValue``.
    public var autoResize: Bool = false

    let subBucketHalfCountMagnitude: UInt8

    // Number of leading zeros in the largest value that can fit in bucket 0.
    let leadingZeroCountBase: UInt8

    // Largest k such that 2^k <= lowestDiscernibleValue
    let unitMagnitude: UInt8

    // MARK: Construction

    /**
     * Construct an auto-resizing histogram with a lowest discernible value of 1 and an auto-adjusting
     * `highestTrackableValue`. Can auto-resize up to track values up to `(UInt64.max / 2)`.
     *
     * - Parameters:
     *    - numberOfSignificantValueDigits: Specifies the precision to use. This is the number of significant
     *                                      decimal digits to which the histogram will maintain value resolution
     *                                      and separation. Must be a non-negative integer between 0 and 5.
     *                                      Default is 3.
     */
    public init(numberOfSignificantValueDigits: SignificantDigits = .three) {
        self.init(lowestDiscernibleValue: 1, highestTrackableValue: 2, numberOfSignificantValueDigits: numberOfSignificantValueDigits)
        self.autoResize = true
    }

    /**
     * Construct a histogram given the lowest and highest values to be tracked and a number of significant
     * decimal digits. Providing a `lowestDiscernibleValue` is useful is situations where the units used
     * for the histogram's values are much smaller that the minimal accuracy required. E.g. when tracking
     * time values stated in nanosecond units, where the minimal accuracy required is a microsecond, the
     * proper value for `lowestDiscernibleValue` would be 1000.
     *
     * - Parameters:
     *   - lowestDiscernibleValue: The lowest value that can be discerned (distinguished from 0) by the histogram.
     *                             Must be a positive integer that is >= 1. May be internally rounded down to
     *                             nearest power of 2.
     *                             If not specified the histogram will be constructed to implicitly track values
     *                             as low as 1.
     *   - highestTrackableValue: The highest value to be tracked by the histogram. Must be a positive
     *                            integer that is `>= (2 * ``lowestDiscernibleValue``)`.
     *   - numberOfSignificantValueDigits The number of significant decimal digits to which the histogram will
     *                                    maintain value resolution and separation.
     *                                    Default is 3.
     */
    public init(lowestDiscernibleValue: UInt64 = 1, highestTrackableValue: UInt64, numberOfSignificantValueDigits: SignificantDigits = .three) {
        // Verify argument validity
        precondition(lowestDiscernibleValue >= 1, "Invalid arguments: lowestDiscernibleValue must be >= 1")
        // prevent subsequent multiplication by 2 for highestTrackableValue check from overflowing
        precondition(lowestDiscernibleValue <= UInt64.max / 2, "Invalid arguments: lowestDiscernibleValue must be <= UInt64.max / 2")
        precondition(lowestDiscernibleValue * 2 <= highestTrackableValue, "Invalid arguments: highestTrackableValue must be >= 2 * lowestDiscernibleValue")

        self.lowestDiscernibleValue = lowestDiscernibleValue
        self.highestTrackableValue = highestTrackableValue
        self.numberOfSignificantValueDigits = numberOfSignificantValueDigits

        // Given a 3 decimal point accuracy, the expectation is obviously for "+/- 1 unit at 1000". It also means that
        // it's "ok to be +/- 2 units at 2000". The "tricky" thing is that it is NOT ok to be +/- 2 units at 1999. Only
        // starting at 2000. So internally, we need to maintain single unit resolution to 2x 10^decimalPoints.
        let largestValueWithSingleUnitResolution = UInt64(2 * .pow(10.0, Int(numberOfSignificantValueDigits.rawValue)))

        unitMagnitude = UInt8(.log2(Double(lowestDiscernibleValue)))

        // We need to maintain power-of-two subBucketCount (for clean direct indexing) that is large enough to
        // provide unit resolution to at least largestValueWithSingleUnitResolution. So figure out
        // largestValueWithSingleUnitResolution's nearest power-of-two (rounded up), and use that:
        let subBucketCountMagnitude = UInt8((Double.log2(Double(largestValueWithSingleUnitResolution))).rounded(.up))
        subBucketHalfCountMagnitude = (subBucketCountMagnitude > 1 ? subBucketCountMagnitude : 1) - 1
        let subBucketCount = 1 << subBucketCountMagnitude
        let subBucketHalfCount = subBucketCount / 2
        subBucketMask = UInt64(subBucketCount - 1) << unitMagnitude

        // Check subBucketCount entries can be represented, with unitMagnitude applied, in a UInt64.
        // Technically it still sort of works if their sum is 63: you can represent all but the last number
        // in the shifted subBucketCount. However, the utility of such a histogram vs ones whose magnitude here
        // fits in 62 bits is debatable, and it makes it harder to work through the logic.
        // Sums larger than 64 are totally broken as leadingZeroCountBase would go negative.
        precondition(unitMagnitude + subBucketHalfCountMagnitude <= 61,
                "Invalid arguments: Cannot represent numberOfSignificantValueDigits worth of values beyond lowestDiscernibleValue")

        // Establish leadingZeroCountBase, used in bucketIndexForValue() fast path:
        // subtract the bits that would be used by the largest value in bucket 0.
        leadingZeroCountBase = 64 - unitMagnitude - subBucketCountMagnitude

        // The buckets (each of which has subBucketCount sub-buckets, here assumed to be 2048 as an example) overlap:
        //
        // ```
        // The 0'th bucket covers from 0...2047 in multiples of 1, using all 2048 sub-buckets
        // The 1'th bucket covers from 2048..4097 in multiples of 2, using only the top 1024 sub-buckets
        // The 2'th bucket covers from 4096..8191 in multiple of 4, using only the top 1024 sub-buckets
        // ...
        // ```
        //
        // Bucket 0 is "special" here. It is the only one that has 2048 entries. All the rest have 1024 entries (because
        // their bottom half overlaps with and is already covered by the all of the previous buckets put together). In other
        // words, the k'th bucket could represent 0 * 2^k to 2048 * 2^k in 2048 buckets with 2^k precision, but the midpoint
        // of 1024 * 2^k = 2048 * 2^(k-1) = the k-1'th bucket's end, so we would use the previous bucket for those lower
        // values as it has better precision.
        bucketCount = Self.bucketsNeededToCoverValue(highestTrackableValue, subBucketCount: subBucketCount, unitMagnitude: unitMagnitude)
        counts = [Count](repeating: 0, count: Self.countsArrayLengthFor(bucketCount: bucketCount, subBucketHalfCount: subBucketHalfCount))
    }

    // MARK: Value recording.

    /**
     * Record a value in the histogram.
     *
     * - Parameters:
     *  - value: The value to be recorded.
     *
     * - Returns:`false` if the value is larger than the `highestTrackableValue` and can't be recorded, `true` otherwise.
     */
    @discardableResult
    @inlinable
    @inline(__always)
    public mutating func record(_ value: UInt64) -> Bool {
        return record(value, count: 1)
    }

    /**
     * Record a value in the histogram (adding to the value's current count).
     *
     * - Parameters:
     *   - value: The value to be recorded.
     *   - count: The number of occurrences of this value to record.
     *
     * - Returns: `false` if the value is larger than the ``highestTrackableValue`` and can't be recorded, `true` otherwise.
     */
    @discardableResult
    @inlinable
    @inline(__always)
    public mutating func record(_ value: UInt64, count: Count) -> Bool {
        let index = countsIndexForValue(value)
        guard index >= 0 else {
            return false
        }

        if index >= counts.count {
            if autoResize {
                resize(newHighestTrackableValue: value)
            } else {
                return false
            }
        }

        incrementCountForIndex(index, by: count)
        updateMinMax(value: value)

        return true
    }

    /**
     * Record a value in the histogram and backfill based on an expected interval.
     *
     * Records a value in the histogram, will round this value of to a precision at or better
     * than the ``numberOfSignificantValueDigits`` specified at construction time.
     *
     * This is specifically used for recording latency.  If the value is larger than the `expectedInterval`
     * then the latency recording system has experienced co-ordinated omission.  This method fills in the
     * values that would have occurred had the client providing the load not been blocked.
     *
     * - Parameters:
     *   - value: Value to add to the histogram
     *   - expectedInterval: The delay between recording values.
     *
     * - Returns: `false` if the value is larger than the ``highestTrackableValue`` and can't be recorded, `true` otherwise.
     */
    @discardableResult
    @inlinable
    @inline(__always)
    public mutating func recordCorrectedValue(_ value: UInt64, expectedInterval: UInt64) -> Bool {
        return recordCorrectedValue(value, count: 1, expectedInterval: expectedInterval)
    }

    /**
     * Record a value in the histogram `count` times.  Applies the same correcting logic  as
     * `recordCorrected(value:expectedInterval:)`.
     *
     * - Parameters:
     *   - value: Value to add to the histogram
     *   - count: Number of `value`'s to add to the histogram
     *   - expectedInterval: The delay between recording values.
     *
     * - Returns: `false` if the value is larger than the ``highestTrackableValue`` and can't be recorded, `true` otherwise.
     */
    @discardableResult
    @inlinable
    @inline(__always)
    public mutating func recordCorrectedValue(_ value: UInt64, count: Count, expectedInterval: UInt64) -> Bool {
        if !record(value, count: count) {
            return false
        }

        if expectedInterval <= 0 || value <= expectedInterval {
            return true
        }

        var missingValue = value - expectedInterval
        while missingValue >= expectedInterval {
            if !record(missingValue, count: count) {
                return false
            }
            missingValue -= expectedInterval
        }

        return true
    }

    // MARK: Clearing.

    /**
     * Reset the contents and stats of this histogram
     */
    public mutating func reset() {
        for i in 0..<counts.count {
            counts[i] = 0
        }
        _totalCount = 0

        maxValue = 0
        minNonZeroValue = .max
    }

    // MARK: Data access.

    /**
     * Get the value at a given percentile.
     *
     * Returns the largest value that `(100% - percentile) [+/- 1 ulp]` of the overall recorded value entries
     * in the histogram are either larger than or equivalent to. Returns 0 if no recorded values exist.

     * Note that two values are "equivalent" in this statement if ``valuesAreEquivalent(_:_:)`` would return true.
     *
     * - Parameters:
     *   - percentile: The percentile for which to return the associated value
     *
     * - Returns: The largest value that `(100% - percentile) [+/- 1 ulp]` of the overall recorded value entries
     *            in the histogram are either larger than or equivalent to. Returns 0 if no recorded values exist.
     */
    public func valueAtPercentile(_ percentile: Double) -> UInt64 {
        // Truncate to 0..100%, and remove 1 ulp to avoid roundoff overruns into next bucket when we
        // subsequently round up to the nearest integer:
        let requestedPercentile = Swift.min(Swift.max(percentile.nextDown, 0.0), 100.0)

        // derive the count at the requested percentile. We round up to nearest integer to ensure that the
        // largest value that the requested percentile of overall recorded values is <= is actually included.
        let fpCountAtPercentile = (requestedPercentile * Double(totalCount)) / 100.0

        // Round up and make sure we at least reach the first recorded entry
        let countAtPercentile = Swift.max(1, UInt64(fpCountAtPercentile.rounded(.up)))

        var totalToCurrentIndex: UInt64 = 0
        for i in 0..<counts.count {
            totalToCurrentIndex += UInt64(counts[i])
            if totalToCurrentIndex >= countAtPercentile {
                let valueAtIndex = valueFromIndex(i)
                return (percentile == 0.0) ?
                        lowestEquivalentForValue(valueAtIndex) :
                        highestEquivalentForValue(valueAtIndex)
            }
        }
        return 0
    }

    /**
     * Get the percentile at a given value.
     * The percentile returned is the percentile of values recorded in the histogram that are smaller
     * than or equivalent to the given value.
     *
     * Note that two values are "equivalent" in this statement if ``valuesAreEquivalent(_:_:)`` would return true.
     *
     * - Parameters:
     *   - value: The value for which to return the associated percentile
     *
     * - Returns: The percentile of values recorded in the histogram that are smaller than or equivalent
     *            to the given value.
     */
    public func percentileAtOrBelowValue(_ value: UInt64) -> Double {
        if totalCount == 0 {
            return 100.0
        }
        let targetIndex = Swift.min(countsIndexForValue(value), counts.count - 1)
        var totalToCurrentIndex: UInt64 = 0
        for i in 0...targetIndex {
            totalToCurrentIndex += UInt64(counts[i])
        }
        return (100.0 * Double(totalToCurrentIndex)) / Double(totalCount)
    }

    /**
     * Get the count of recorded values within a range of value levels (inclusive to within the histogram's resolution).
     *
     * - Parameters:
     *   - range: The closed range of value levels.
     *            The lower bound will be rounded down with ``lowestEquivalentForValue(_:)``
     *            The upper bound will be rounded up with ``highestEquivalentForValue(_:)``
     *
     * - Returns: The total count of values recorded in the histogram within the value range that is
     *            `>= lowestEquivalentForValue(range.lowerBound)` and `<= highestEquivalentForValue(range.upperBound)`
     */
    public func count(within range: ClosedRange<UInt64>) -> UInt64 {
        let lowIndex = Swift.max(0, countsIndexForValue(range.lowerBound))
        let highIndex = Swift.min(countsIndexForValue(range.upperBound), counts.count - 1)
        var count: UInt64 = 0
        for i in lowIndex...highIndex {
            count += UInt64(counts[i])
        }
        return count
    }

    /**
     * Determine if two values are equivalent with the histogram's resolution.
     * Where "equivalent" means that value samples recorded for any two
     * equivalent values are counted in a common total count.
     *
     * - Parameters:
     *   - value1: first value to compare
     *   - value2: second value to compare
     *
     * - Returns: `true` if values are equivalent with the histogram's resolution, `false` otherwise.
     */
    public func valuesAreEquivalent(_ value1: UInt64, _ value2: UInt64) -> Bool {
        return lowestEquivalentForValue(value1) == lowestEquivalentForValue(value2)
    }

    /**
     * Provide a (conservatively high) estimate of the histogram's total footprint in bytes.
     *
     * - Returns: a (conservatively high) estimate of the histogram's total footprint in bytes.
     */
    public var estimatedFootprintInBytes: Int {
        // Estimate overhead as 512 bytes
        return 512 + counts.capacity * MemoryLayout<Count>.stride
    }

    /**
     * Get the count of recorded values at a specific value (to within the histogram resolution at the value level).
     *
     * - Parameters:
     *   - value: The value for which to provide the recorded count.
     *
     * - Returns: The total count of values recorded in the histogram within the value range that is
     *            `>= lowestEquivalentForValue(value)` and `<= `highestEquivalentForValue(value)`.
     */
    public func countForValue(_ value: UInt64) -> Count {
        return counts[countsIndexForValue(value)]
    }

    /**
     * Get the lowest recorded value level in the histogram.
     *
     * If the histogram has no recorded values, the value returned is undefined.
     *
     * - Returns: The minimum value recorded in the histogram.
     */
    public var min: UInt64 {
        return (counts[0] > 0 || totalCount == 0) ? 0 : minNonZeroValue
    }

    /**
     * Get the highest recorded value level in the histogram.
     *
     * If the histogram has no recorded values, the value returned is undefined.
     *
     * - Returns: The maximum value recorded in the histogram.
     */
    public var max: UInt64 {
        return maxValue == 0 ? 0 : highestEquivalentForValue(maxValue)
    }

    /**
     * Get the lowest recorded non-zero value level in the histogram.
     *
     * If the histogram has no recorded values, the value returned is undefined.
     *
     * - Returns: The lowest recorded non-zero value level in the histogram.
     */
    public var minNonZero: UInt64 {
        return minNonZeroValue == UInt64.max ? UInt64.max : lowestEquivalentForValue(minNonZeroValue)
    }

    /**
     * Get the computed mean value of all recorded values in the histogram.
     *
     * - Returns: The mean value (in value units) of the histogram data.
     */
    public var mean: Double {
        if (totalCount == 0) {
            return 0.0
        }
        var totalValue: Double = 0
        for iv in recordedValues() {
            totalValue += Double(medianEquivalentForValue(iv.value)) * Double(iv.count)
        }
        return totalValue / Double(totalCount)
    }

    /**
     * Get the computed standard deviation of all recorded values in the histogram.
     *
     * - Returns: The standard deviation (in value units) of the histogram data.
     */
    public var stdDeviation: Double {
        if (totalCount == 0) {
            return 0.0
        }

        let mean = self.mean

        var geometricDeviationTotal = 0.0
        for iv in recordedValues() {
            let deviation = Double(medianEquivalentForValue(iv.value)) - mean
            geometricDeviationTotal += (deviation * deviation) * Double(iv.count)
        }

        return (geometricDeviationTotal / Double(totalCount)).squareRoot()
    }

    /**
     * Get the median value of all recorded values in the histogram.
     *
     * - Returns: The median value of the histogram data.
     */
    public var median: UInt64 { valueAtPercentile(50.0) }

    // MARK: Iteration support.

    /**
     * Represents a value point iterated through in a Histogram, with associated stats.
     */
    public struct IterationValue: Equatable {
        /**
         * The actual value level that was iterated to by the iterator.
         */
        public let value: UInt64

        /**
         * The actual value level that was iterated from by the iterator.
         */
        public let prevValue: UInt64

        /**
         * The count of recorded values in the histogram that exactly match this
         * [`lowestEquivalentForValue(value)`...`highestEquivalentForValue(value)`] value range.
         */
        public let count: Count

        /**
         * The percentile of recorded values in the histogram at values equal or smaller than value.
         */
        public let percentile: Double

        /**
         * The percentile level that the iterator returning this ``IterationValue`` had iterated to.
         * Generally, `percentileLevelIteratedTo` will be equal to or smaller than `percentile`,
         * but the same value point can contain multiple iteration levels for some iterators. E.g. a
         * percentile iterator can stop multiple times in the exact same value point (if the count at
         * that value covers a range of multiple percentiles in the requested percentile iteration points).
         */
        public let percentileLevelIteratedTo: Double

        /**
         * The count of recorded values in the histogram that were added to the ``totalCountToThisValue`` as a result
         * on this iteration step. Since multiple iteration steps may occur with overlapping equivalent value ranges,
         * the count may be lower than the count found at the value (e.g. multiple linear steps or percentile levels
         * can occur within a single equivalent value range).
         */
        public let countAddedInThisIterationStep: UInt64

        /**
         * The total count of all recorded values in the histogram at values equal or smaller than value.
         */
        public let totalCountToThisValue: UInt64

        /**
         * The sum of all recorded values in the histogram at values equal or smaller than value.
         */
        public let totalValueToThisValue: UInt64
    }

    /**
     * Common part of all iterators.
     */
    struct IteratorImpl {
        let histogram: Histogram

        let arrayTotalCount: UInt64

        var currentIndex: Int = 0
        var currentValueAtIndex: UInt64 = 0

        var nextValueAtIndex: UInt64

        var prevValueIteratedTo: UInt64 = 0
        var totalCountToPrevIndex: UInt64 = 0

        var totalCountToCurrentIndex: UInt64 = 0
        var totalValueToCurrentIndex: UInt64 = 0

        var countAtThisValue: Count = 0

        private var freshSubBucket: Bool = true

        init(histogram: Histogram) {
            self.histogram = histogram
            arrayTotalCount = histogram.totalCount
            nextValueAtIndex = 1 << histogram.unitMagnitude
        }

        var hasNext: Bool {
            return totalCountToCurrentIndex < arrayTotalCount
        }

        mutating func moveNext() {
            assert(!exhaustedSubBuckets)

            countAtThisValue = histogram.counts[currentIndex]
            if freshSubBucket { // Don't add unless we've incremented since last bucket...
                totalCountToCurrentIndex += UInt64(countAtThisValue)
                totalValueToCurrentIndex += UInt64(countAtThisValue) * histogram.highestEquivalentForValue(currentValueAtIndex)
                freshSubBucket = false
            }
        }

        mutating func makeIterationValueAndUpdatePrev(value: UInt64? = nil, percentileIteratedTo: Double? = nil) -> IterationValue {
            let valueIteratedTo = value ?? self.valueIteratedTo

            defer {
                prevValueIteratedTo = valueIteratedTo
                totalCountToPrevIndex = totalCountToCurrentIndex
            }

            let percentile = (100.0 * Double(totalCountToCurrentIndex)) / Double(arrayTotalCount)

            return IterationValue(value: valueIteratedTo, prevValue: prevValueIteratedTo, count: countAtThisValue,
                    percentile: percentile, percentileLevelIteratedTo: percentileIteratedTo ?? percentile,
                    countAddedInThisIterationStep: totalCountToCurrentIndex - totalCountToPrevIndex,
                    totalCountToThisValue: totalCountToCurrentIndex, totalValueToThisValue: totalValueToCurrentIndex)
        }

        var exhaustedSubBuckets: Bool { currentIndex >= histogram.counts.count }

        private var valueIteratedTo: UInt64 { histogram.highestEquivalentForValue(currentValueAtIndex) }

        mutating func incrementSubBucket() {
            freshSubBucket = true
            currentIndex += 1
            currentValueAtIndex = histogram.valueFromIndex(currentIndex)
            // Figure out the value at the next index (used by some iterators):
            nextValueAtIndex = histogram.valueFromIndex(currentIndex + 1)
        }
    }

    /**
     * Used for iterating through histogram values according to percentile levels. The iteration is
     * performed in steps that start at 0% and reduce their distance to 100% according to the
     * `percentileTicksPerHalfDistance` parameter, ultimately reaching 100% when all recorded histogram
     * values are exhausted.
     */
    public struct Percentiles: Sequence, IteratorProtocol {
        var impl: IteratorImpl
        let percentileTicksPerHalfDistance: Int
        var percentileLevelToIterateTo: Double
        var percentileLevelToIterateFrom: Double
        var reachedLastRecordedValue: Bool

        init(histogram: Histogram, percentileTicksPerHalfDistance: Int) {
            impl = IteratorImpl(histogram: histogram)
            self.percentileTicksPerHalfDistance = percentileTicksPerHalfDistance
            percentileLevelToIterateTo = 0.0
            percentileLevelToIterateFrom = 0.0
            reachedLastRecordedValue = false
        }

        public mutating func next() -> IterationValue? {
            if !impl.hasNext {
                // We want one additional last step to 100%
                if reachedLastRecordedValue || impl.arrayTotalCount <= 0 {
                    return nil
                }

                percentileLevelToIterateTo = 100.0
                reachedLastRecordedValue = true
            }

            while !impl.exhaustedSubBuckets {
                impl.moveNext()
                if reachedIterationLevel {
                    defer {
                        incrementIterationLevel()
                    }
                    return impl.makeIterationValueAndUpdatePrev(percentileIteratedTo: percentileLevelToIterateTo)
                }
                impl.incrementSubBucket()
            }

            return nil
        }

        private var reachedIterationLevel: Bool {
            if impl.countAtThisValue == 0 {
                return false
            }
            let currentPercentile = (100.0 * Double(impl.totalCountToCurrentIndex)) / Double(impl.arrayTotalCount)
            return currentPercentile >= percentileLevelToIterateTo
        }

        private mutating func incrementIterationLevel() {
            percentileLevelToIterateFrom = percentileLevelToIterateTo

            // The choice to maintain fixed-sized "ticks" in each half-distance to 100% [starting
            // from 0%], as opposed to a "tick" size that varies with each interval, was made to
            // make the steps easily comprehensible and readable to humans. The resulting percentile
            // steps are much easier to browse through in a percentile distribution output, for example.
            //
            // We calculate the number of equal-sized "ticks" that the 0-100 range will be divided
            // by at the current scale. The scale is determined by the percentile level we are
            // iterating to. The following math determines the tick size for the current scale,
            // and maintain a fixed tick size for the remaining "half the distance to 100%"
            // [from either 0% or from the previous half-distance]. When that half-distance is
            // crossed, the scale changes and the tick size is effectively cut in half.

            if percentileLevelToIterateTo == 100.0 { // to avoid division by zero in calculation below
                return
            }

            let percentileReportingTicks = UInt64(percentileTicksPerHalfDistance) *
                            UInt64(.pow(2.0, Int(.log2(100.0 / (100.0 - percentileLevelToIterateTo))) + 1))
            percentileLevelToIterateTo += 100.0 / Double(percentileReportingTicks)
        }
    }

    /**
     * Used for iterating through histogram values in linear steps. The iteration is
     * performed in steps of `valueUnitsPerBucket` in size, terminating when all recorded histogram
     * values are exhausted. Note that each iteration "bucket" includes values up to and including
     * the next bucket boundary value.
     */
    public struct LinearBucketValues: Sequence, IteratorProtocol {
        var impl: IteratorImpl
        let valueUnitsPerBucket: UInt64

        var currentStepHighestValueReportingLevel: UInt64
        var currentStepLowestValueReportingLevel: UInt64

        init(histogram: Histogram, valueUnitsPerBucket: UInt64) {
            impl = IteratorImpl(histogram: histogram)
            self.valueUnitsPerBucket = valueUnitsPerBucket
            currentStepHighestValueReportingLevel = valueUnitsPerBucket - 1
            currentStepLowestValueReportingLevel = histogram.lowestEquivalentForValue(currentStepHighestValueReportingLevel)
        }

        public mutating func next() -> IterationValue? {
            if !hasNext {
                return nil
            }

            while !impl.exhaustedSubBuckets {
                impl.moveNext()
                if reachedIterationLevel {
                    defer {
                        incrementIterationLevel()
                    }
                    return impl.makeIterationValueAndUpdatePrev(value: currentStepHighestValueReportingLevel)
                }
                impl.incrementSubBucket()
            }

            return nil
        }

        private var hasNext: Bool {
            if impl.hasNext {
                return true
            }
            // If the next iteration will not move to the next sub bucket index (which is empty if
            // if we reached this point), then we are not yet done iterating (we want to iterate
            // until we are no longer on a value that has a count, rather than util we first reach
            // the last value that has a count. The difference is subtle but important)...
            // When this is called, we're about to begin the "next" iteration, so
            // currentStepHighestValueReportingLevel has already been incremented, and we use it
            // without incrementing its value.
            return currentStepHighestValueReportingLevel < impl.nextValueAtIndex
        }

        private var reachedIterationLevel: Bool {
            return impl.currentValueAtIndex >= currentStepLowestValueReportingLevel ||
                   impl.currentIndex >= impl.histogram.counts.count - 1
        }

        private mutating func incrementIterationLevel() {
            currentStepHighestValueReportingLevel += valueUnitsPerBucket
            currentStepLowestValueReportingLevel = impl.histogram.lowestEquivalentForValue(currentStepHighestValueReportingLevel)
        }
    }

    /**
     * Used for iterating through histogram values at logarithmically increasing levels. The iteration is
     * performed in steps that start at `valueUnitsInFirstBucket` and increase exponentially according to
     * `logBase`, terminating when all recorded histogram values are exhausted.
     */
    public struct LogarithmicBucketValues: Sequence, IteratorProtocol {
        var impl: IteratorImpl
        let valueUnitsInFirstBucket: UInt64
        let logBase: Double
        var nextValueReportingLevel: Double
        var currentStepHighestValueReportingLevel: UInt64
        var currentStepLowestValueReportingLevel: UInt64

        init(histogram: Histogram, valueUnitsInFirstBucket: UInt64, logBase: Double) {
            impl = IteratorImpl(histogram: histogram)
            self.valueUnitsInFirstBucket = valueUnitsInFirstBucket
            self.logBase = logBase
            nextValueReportingLevel = Double(valueUnitsInFirstBucket - 1)
            currentStepHighestValueReportingLevel = UInt64(nextValueReportingLevel) - 1
            currentStepLowestValueReportingLevel = histogram.lowestEquivalentForValue(currentStepHighestValueReportingLevel)
        }

        public mutating func next() -> IterationValue? {
            if !hasNext {
                return nil
            }

            while !impl.exhaustedSubBuckets {
                impl.moveNext()
                if reachedIterationLevel {
                    defer {
                        incrementIterationLevel()
                    }
                    return impl.makeIterationValueAndUpdatePrev(value: currentStepHighestValueReportingLevel)
                }
                impl.incrementSubBucket()
            }

            return nil
        }

        private var hasNext: Bool {
            if impl.hasNext {
                return true
            }
            // If the next iterate will not move to the next sub bucket index (which is empty if
            // if we reached this point), then we are not yet done iterating (we want to iterate
            // until we are no longer on a value that has a count, rather than util we first reach
            // the last value that has a count. The difference is subtle but important)...
            return impl.histogram.lowestEquivalentForValue(UInt64(nextValueReportingLevel)) < impl.nextValueAtIndex
        }

        private var reachedIterationLevel: Bool {
            return impl.currentValueAtIndex >= currentStepLowestValueReportingLevel ||
                   impl.currentIndex >= impl.histogram.counts.count - 1
        }

        private mutating func incrementIterationLevel() {
            nextValueReportingLevel *= logBase
            currentStepHighestValueReportingLevel = UInt64(nextValueReportingLevel) - 1
            currentStepLowestValueReportingLevel = impl.histogram.lowestEquivalentForValue(currentStepHighestValueReportingLevel)
        }
    }

    /**
     * Used for iterating through all recorded histogram values using the finest granularity steps supported by the
     * underlying representation. The iteration steps through all non-zero recorded value counts, and terminates when
     * all recorded histogram values are exhausted.
     */
    public struct RecordedValues: Sequence, IteratorProtocol {
        var impl: IteratorImpl
        var visitedIndex = -1

        init(histogram: Histogram) {
            impl = IteratorImpl(histogram: histogram)
        }

        public mutating func next() -> IterationValue? {
            if !impl.hasNext {
                return nil
            }

            while !impl.exhaustedSubBuckets {
                impl.moveNext()
                if reachedIterationLevel {
                    defer {
                        incrementIterationLevel()
                    }
                    return impl.makeIterationValueAndUpdatePrev()
                }
                impl.incrementSubBucket()
            }

            return nil
        }

        private var reachedIterationLevel: Bool {
            let currentCount = impl.histogram.counts[impl.currentIndex]
            return currentCount != 0 && visitedIndex != impl.currentIndex
        }

        private mutating func incrementIterationLevel() {
            visitedIndex = impl.currentIndex
        }
    }

    /**
     * Provide a means of iterating through all histogram values using the finest granularity steps supported by
     * the underlying representation. The iteration steps through all possible unit value levels, regardless of
     * whether or not there were recorded values for that value level, and terminates when all recorded histogram
     * values are exhausted.
     */
    public struct AllValues: Sequence, IteratorProtocol {
        var impl: IteratorImpl
        var visitedIndex = -1

        init(histogram: Histogram) {
            impl = IteratorImpl(histogram: histogram)
        }

        public mutating func next() -> IterationValue? {
            if !hasNext {
                return nil
            }

            while !impl.exhaustedSubBuckets {
                impl.moveNext()
                if reachedIterationLevel {
                    defer {
                        incrementIterationLevel()
                    }
                    return impl.makeIterationValueAndUpdatePrev()
                }
                impl.incrementSubBucket()
            }

            return nil
        }

        private var hasNext: Bool {
            // Unlike other iterators AllValuesIterator is only done when we've exhausted the indices:
            return impl.currentIndex < impl.histogram.counts.count - 1
        }

        private var reachedIterationLevel: Bool {
            return visitedIndex != impl.currentIndex
        }

        private mutating func incrementIterationLevel() {
            visitedIndex = impl.currentIndex
        }
    }

    /**
     * Provide a means of iterating through histogram values according to percentile levels.
     *
     * The iteration is performed in steps that start at 0% and reduce their distance to 100% according
     * to the `ticksPerHalfDistance` parameter, ultimately reaching 100% when all recorded histogram
     * values are exhausted.
     *
     * - Parameters:
     *   - ticksPerHalfDistance: The number of iteration steps per half-distance to 100%.
     *
     * - Returns: An object implementing `Sequence` protocol over ``IterationValue``.
     */
    public func percentiles(ticksPerHalfDistance: Int) -> Percentiles {
        return Percentiles(histogram: self, percentileTicksPerHalfDistance: ticksPerHalfDistance)
    }

    /**
     * Provide a means of iterating through histogram values using linear steps.
     *
     * The iteration is performed in steps of `valueUnitsPerBucket` in size, terminating when all
     * recorded histogram values are exhausted.
     *
     * - Parameters:
     *   - valueUnitsPerBucket: The size (in value units) of the linear buckets to use.
     *
     * - Returns: An object implementing `Sequence` protocol over ``IterationValue``.
     */
    public func linearBucketValues(valueUnitsPerBucket: UInt64) -> LinearBucketValues {
        return LinearBucketValues(histogram: self, valueUnitsPerBucket: valueUnitsPerBucket)
    }

    /**
     * Provide a means of iterating through histogram values at logarithmically increasing levels.
     *
     * The iteration is performed in steps that start at `valueUnitsInFirstBucket` and increase
     * exponentially according to `logBase`, terminating when all recorded histogram values are exhausted.
     *
     * - Parameters:
     *   - valueUnitsInFirstBucket: The size (in value units) of the first bucket in the iteration.
     *   - logBase: The multiplier by which bucket sizes will grow in each iteration step.
     *
     * - Returns: An object implementing `Sequence` protocol over ``IterationValue``.
     */
    public func logarithmicBucketValues(valueUnitsInFirstBucket: UInt64, logBase: Double) -> LogarithmicBucketValues {
        return LogarithmicBucketValues(histogram: self, valueUnitsInFirstBucket: valueUnitsInFirstBucket, logBase: logBase)
    }

    /**
     * Provide a means of iterating through all recorded histogram values using the finest granularity steps
     * supported by the underlying representation. The iteration steps through all non-zero recorded value counts,
     * and terminates when all recorded histogram values are exhausted.
     *
     * - Returns: An object implementing `Sequence` protocol over ``IterationValue``.
     */
    public func recordedValues() -> RecordedValues {
        return RecordedValues(histogram: self)
    }

    /**
     * Provide a means of iterating through all histogram values using the finest granularity steps supported by
     * the underlying representation. The iteration steps through all possible unit value levels, regardless of
     * whether or not there were recorded values for that value level, and terminates when all recorded histogram
     * values are exhausted.
     *
     * - Returns: An object implementing `Sequence` protocol over ``IterationValue``.
     */
    public func allValues() -> AllValues {
        return AllValues(histogram: self)
    }

    // MARK: Textual percentile output support.

    /**
     * Produce textual representation of the value distribution of histogram data by percentile.
     *
     * The distribution is output with exponentially increasing resolution, with each exponentially decreasing
     * half-distance containing `percentileTicksPerHalfDistance` percentile reporting tick points.
     *
     * - Parameters:
     *   - to: The object into which the distribution will be written.
     *   - percentileTicksPerHalfDistance: The number of reporting points per exponentially decreasing half-distance.
     *   - outputValueUnitScalingRatio: The scaling factor by which to divide histogram recorded values units in output.
     *   - format: The output format.
     */
    public func outputPercentileDistribution<Stream: TextOutputStream>(
            to stream: inout Stream,
            outputValueUnitScalingRatio: Double,
            percentileTicksPerHalfDistance ticks: Int = 5,
            format: HistogramOutputFormat = .plainText) {

        if format == .csv {
            return outputPercentileDistributionCsv(to: &stream, outputValueUnitScalingRatio: outputValueUnitScalingRatio, percentileTicksPerHalfDistance: ticks)
        }

        let table = TextTable<IterationValue> {
            let lastLine = ($0.percentile == 100.0)

            return [
                Column("Value" <- "%.\(self.numberOfSignificantValueDigits.rawValue)f".format(Double($0.value) / outputValueUnitScalingRatio), width: 12, align: .right),
                Column("Percentile" <- "%.12f".format($0.percentile / 100.0), width: 14, align: .right),
                Column("TotalCount" <- $0.totalCountToThisValue, width: 10, align: .right),
                Column("1/(1-Percentile)" <- (lastLine ? "" : "%.2f".format(1.0 / (1.0 - ($0.percentile / 100.0)))), align: .right)
            ]
        }

        let data = [IterationValue](percentiles(ticksPerHalfDistance: ticks))
        stream.write(table.string(for: data) ?? "unable to render percentile table")

        // Calculate and output mean and std. deviation.
        // Note: mean/std. deviation numbers are very often completely irrelevant when
        // data is extremely non-normal in distribution (e.g. in cases of strong multi-modal
        // response time distribution associated with GC pauses). However, reporting these numbers
        // can be very useful for contrasting with the detailed percentile distribution
        // reported by outputPercentileDistribution(). It is not at all surprising to find
        // percentile distributions where results fall many tens or even hundreds of standard
        // deviations away from the mean - such results simply indicate that the data sampled
        // exhibits a very non-normal distribution, highlighting situations for which the std.
        // deviation metric is a useless indicator.

        let mean =  self.mean / outputValueUnitScalingRatio
        let stdDeviation = self.stdDeviation / outputValueUnitScalingRatio

        stream.write(("#[Mean    = %12.\(numberOfSignificantValueDigits.rawValue)f," +
                    " StdDeviation   = %12.\(numberOfSignificantValueDigits.rawValue)f]\n").format(mean, stdDeviation))
        stream.write(("#[Max     = %12.\(numberOfSignificantValueDigits.rawValue)f," +
                    " Total count    = %12d]\n").format(Double(max) / outputValueUnitScalingRatio, totalCount))
        stream.write("#[Buckets = %12d, SubBuckets     = %12d]\n".format(bucketCount, subBucketCount))
    }

    private func outputPercentileDistributionCsv<Stream: TextOutputStream>(
            to stream: inout Stream,
            outputValueUnitScalingRatio: Double,
            percentileTicksPerHalfDistance ticks: Int = 5) {
        stream.write("\"Value\",\"Percentile\",\"TotalCount\",\"1/(1-Percentile)\"\n")

        let percentileFormatString = "%.\(numberOfSignificantValueDigits)f,%.12f,%d,%.2f\n"
        let lastLinePercentileFormatString = "%.\(numberOfSignificantValueDigits)f,%.12f,%d,Infinity\n"

        for iv in percentiles(ticksPerHalfDistance: ticks) {
            if iv.percentile != 100.0 {
                stream.write(percentileFormatString.format(
                        Double(iv.value) / outputValueUnitScalingRatio,
                        iv.percentile / 100.0,
                        iv.totalCountToThisValue,
                        1.0 / (1.0 - (iv.percentile / 100.0))))
            } else {
                stream.write(lastLinePercentileFormatString.format(
                        Double(iv.value) / outputValueUnitScalingRatio,
                        iv.percentile / 100.0,
                        iv.totalCountToThisValue))
            }
        }
    }

    // MARK: Structure querying support.

    /**
     * Get the size (in value units) of the range of values that are equivalent to the given value within the
     * histogram's resolution. Where "equivalent" means that value samples recorded for any two
     * equivalent values are counted in a common total count.
     *
     * - Parameter value: The given value.
     * - Returns: The size of the range of values equivalent to the given value.
     */
    public func sizeOfEquivalentRangeForValue(_ value: UInt64) -> UInt64 {
        let bucketIndex = bucketIndexForValue(value)
        let subBucketIndex = subBucketIndexForValue(value, bucketIndex: bucketIndex)
        return sizeOfEquivalentRangeFor(bucketIndex: bucketIndex, subBucketIndex: subBucketIndex)
    }

    func sizeOfEquivalentRangeFor(bucketIndex: Int, subBucketIndex: Int) -> UInt64 {
        let adjustedBucket = (subBucketIndex >= subBucketCount) ? (bucketIndex + 1) : bucketIndex
        return UInt64(1) << (Int(unitMagnitude) + adjustedBucket)
    }

    /**
     * Get the lowest value that is equivalent to the given value within the histogram's resolution.
     * Where "equivalent" means that value samples recorded for any two
     * equivalent values are counted in a common total count.
     *
     * - Parameter value: The given value.
     * - Returns: The lowest value that is equivalent to the given value within the histogram's resolution.
     */
    public func lowestEquivalentForValue(_ value: UInt64) -> UInt64 {
        let bucketIndex = bucketIndexForValue(value)
        let subBucketIndex = subBucketIndexForValue(value, bucketIndex: bucketIndex)
        return valueFrom(bucketIndex: bucketIndex, subBucketIndex: subBucketIndex)
    }

    /**
     * Get the highest value that is equivalent to the given value within the histogram's resolution.
     * Where "equivalent" means that value samples recorded for any two
     * equivalent values are counted in a common total count.
     *
     * - Parameter value: The given value.
     * - Returns: The highest value that is equivalent to the given value within the histogram's resolution.
     */
    public func highestEquivalentForValue(_ value: UInt64) -> UInt64 {
        return nextNonEquivalentForValue(value) - 1
    }

    /**
     * Get the (closed) range of values that are equivalent to the given value within the
     * histogram's resolution. Where "equivalent" means that value samples recorded for any two
     * equivalent values are counted in a common total count.
     *
     * - Parameter value: The given value.
     * - Returns: The the range of values equivalent to the given value.
     */
    public func equivalentRangeForValue(_ value: UInt64) -> ClosedRange<UInt64> {
        let bucketIndex = bucketIndexForValue(value)
        let subBucketIndex = subBucketIndexForValue(value, bucketIndex: bucketIndex)

        let lowerBound = valueFrom(bucketIndex: bucketIndex, subBucketIndex: subBucketIndex)
        let upperBound = lowerBound + sizeOfEquivalentRangeFor(bucketIndex: bucketIndex, subBucketIndex: subBucketIndex) - 1

        return lowerBound ... upperBound
    }

    /**
     * Get a value that lies in the middle (rounded up) of the range of values equivalent the given value.
     * Where "equivalent" means that value samples recorded for any two
     * equivalent values are counted in a common total count.
     *
     * - Parameter value: The given value.
     * - Returns: The value lies in the middle (rounded up) of the range of values equivalent the given value.
     */
    public func medianEquivalentForValue(_ value: UInt64) -> UInt64 {
        return lowestEquivalentForValue(value) + (sizeOfEquivalentRangeForValue(value) >> 1)
    }

    /**
     * Get the next value that is not equivalent to the given value within the histogram's resolution.
     * Where "equivalent" means that value samples recorded for any two
     * equivalent values are counted in a common total count.
     *
     * - Parameter value: The given value.
     * - Returns: The next value that is not equivalent to the given value within the histogram's resolution.
     */
    public func nextNonEquivalentForValue(_ value: UInt64) -> UInt64 {
        return lowestEquivalentForValue(value) + sizeOfEquivalentRangeForValue(value)
    }

    func valueFromIndex(_ index: Int) -> UInt64 {
        var bucketIndex = (index >> subBucketHalfCountMagnitude) - 1
        var subBucketIndex = (index & (subBucketHalfCount - 1)) + subBucketHalfCount

        if bucketIndex < 0 {
            subBucketIndex -= subBucketHalfCount
            bucketIndex = 0
        }

        return valueFrom(bucketIndex: bucketIndex, subBucketIndex: subBucketIndex)
    }

    private func valueFrom(bucketIndex: Int, subBucketIndex: Int) -> UInt64 {
        return UInt64(subBucketIndex) << (bucketIndex + Int(unitMagnitude))
    }

    @usableFromInline
    func countsIndexForValue(_ value: UInt64) -> Int {
        let bucketIndex = bucketIndexForValue(value)
        let subBucketIndex = subBucketIndexForValue(value, bucketIndex: bucketIndex)
        return countsIndexFor(bucketIndex: bucketIndex, subBucketIndex: subBucketIndex)
    }

    /**
     * - Returns: The lowest (and therefore highest precision) bucket index that can represent the value.
     */
    func bucketIndexForValue(_ value: UInt64) -> Int {
        // Calculates the number of powers of two by which the value is greater than the biggest value that fits in
        // bucket 0. This is the bucket index since each successive bucket can hold a value 2x greater.
        // The mask maps small values to bucket 0
        return Int(leadingZeroCountBase) - (value | subBucketMask).leadingZeroBitCount
    }

   func subBucketIndexForValue(_ value: UInt64, bucketIndex: Int) -> Int {
        // For ``bucketIndex`` 0, this is just value, so it may be anywhere in 0 to ``subBucketCount``.
        // For other bucketIndex, this will always end up in the top half of subBucketCount: assume that for some bucket
        // `k` > 0, this calculation will yield a value in the bottom half of 0 to ``subBucketCount``. Then, because of how
        // buckets overlap, it would have also been in the top half of bucket `k-1`, and therefore would have
        // returned `k-1` in ``bucketIndexForValue()``. Since we would then shift it one fewer bits here, it would be twice as big,
        // and therefore in the top half of ``subBucketCount``.
        return Int(value >> (bucketIndex + Int(unitMagnitude)))
    }

    private func countsIndexFor(bucketIndex: Int, subBucketIndex: Int) -> Int {
        // Calculate the index for the first entry that will be used in the bucket (halfway through ``subBucketCount``).
        // For bucketIndex 0, all ``subBucketCount`` entries may be used, but bucketBaseIndex is still set in the middle.
        let bucketBaseIndex = (bucketIndex + 1) << subBucketHalfCountMagnitude
        // Calculate the offset in the bucket. This subtraction will result in a positive value in all buckets except
        // the 0th bucket (since a value in that bucket may be less than half the bucket's 0 to ``subBucketCount`` range).
        // However, this works out since we give bucket 0 twice as much space.
        let offsetInBucket = subBucketIndex - subBucketHalfCount
        // The following is the equivalent of `((subBucketIndex - subBucketHalfCount) + bucketBaseIndex)`
        return bucketBaseIndex + offsetInBucket
    }

    @inlinable
    @inline(__always)
    mutating func incrementCountForIndex(_ index: Int, by value: Count) {
        // Use unsafe access for performance.
        counts.withUnsafeMutableBufferPointer { buffer in
            buffer[index] &+= value
        }
        _totalCount &+= UInt64(value)
    }

    @inlinable
    @inline(__always)
    mutating func updateMinMax(value: UInt64) {
        if value > maxValue {
            maxValue = value
        }
        if value < minNonZeroValue && value != 0 {
            minNonZeroValue = value
        }
    }

    @usableFromInline
    mutating func resize(newHighestTrackableValue: UInt64) {
        let newBucketCount = Self.bucketsNeededToCoverValue(newHighestTrackableValue, subBucketCount: subBucketCount, unitMagnitude: unitMagnitude)
        let newCountsLength = Self.countsArrayLengthFor(bucketCount: newBucketCount, subBucketHalfCount: subBucketHalfCount)

        if newCountsLength > counts.count { // only handle increase
            counts.append(contentsOf: repeatElement(Count.zero, count: newCountsLength - counts.count))
            bucketCount = newBucketCount
            highestTrackableValue = highestEquivalentForValue(newHighestTrackableValue)
        }
    }

    private static func bucketsNeededToCoverValue(_ value: UInt64, subBucketCount: Int, unitMagnitude: UInt8) -> Int {
        var smallestUntrackableValue = UInt64(subBucketCount) << unitMagnitude
        var bucketsNeeded = 1
        while (smallestUntrackableValue <= value) {
            if (smallestUntrackableValue > UInt64.max / 2) {
                return bucketsNeeded + 1
            }
            smallestUntrackableValue <<= 1
            bucketsNeeded += 1
        }

        return bucketsNeeded
    }

    /**
     * If we have `N` such that ``subBucketCount`` `* 2^N` > max value, we need storage for `N+1` buckets, each with enough
     * slots to hold the top half of the ``subBucketCount`` (the lower half is covered by previous buckets), and the `+1`
     * being used for the lower half of the 0'th bucket. Or, equivalently, we need 1 more bucket to capture the max
     * value if we consider the sub-bucket length to be halved.
     */
    static func countsArrayLengthFor(bucketCount: Int, subBucketHalfCount: Int) -> Int {
        return (bucketCount + 1) * subBucketHalfCount
    }
}

// MARK: Histogram equality.

extension Histogram: Equatable {
    /**
     * Determine if this histogram is equivalent to another.
     *
     * - Parameter other: The other histogram to compare to.
     * - Returns: `true` if this histogram is equivalent to `other`, `false` othrewise.
     */
    public static func == (lhs: Histogram, rhs: Histogram) -> Bool {
        if lhs.lowestDiscernibleValue != rhs.lowestDiscernibleValue ||
           lhs.numberOfSignificantValueDigits != rhs.numberOfSignificantValueDigits ||
           lhs.totalCount != rhs.totalCount ||
           lhs.max != rhs.max ||
           lhs.minNonZero != rhs.minNonZero {
            return false
        }

        // 2 histograms may be equal but have different underlying array sizes. This can happen for instance due to
        // resizing.
        if lhs.counts.count == rhs.counts.count {
            for i in 0..<lhs.counts.count {
                if lhs.counts[i] != rhs.counts[i] {
                    return false
                }
            }
        } else {
            // Comparing the values is valid here because we have already confirmed the histograms have the same total
            // count. It would not be correct otherwise.
            for iv in lhs.recordedValues() {
                if rhs.countForValue(iv.value) != iv.count {
                    return false
                }
            }
        }

        return true
    }
}

// MARK: Histogram output.

extension Histogram: TextOutputStreamable {
    /**
     * Writes a textual representation of this histogram into the given output stream.
     *
     * - Parameter to: The target stream.
     */
    public func write<Target: TextOutputStream>(to: inout Target) {
        outputPercentileDistribution(to: &to, outputValueUnitScalingRatio: 1.0)
    }
}
