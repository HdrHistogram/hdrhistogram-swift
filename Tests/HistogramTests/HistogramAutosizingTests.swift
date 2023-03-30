//
// Copyright (c) 2023 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

// swiftlint:disable todo

@testable import Histogram
import XCTest

final class HistogramAutosizingTests: XCTestCase {
    private static let highestTrackableValue = UInt64(3_600) * 1_000 * 1_000 // e.g. for 1 hr in usec units

    func testHistogramAutoSizingEdges() {
        var histogram = Histogram<UInt64>(numberOfSignificantValueDigits: .three)

        histogram.record((UInt64(1) << 62) - 1)

        XCTAssertEqual(52, histogram.bucketCount)
        XCTAssertEqual(54_272, histogram.counts.count)

        histogram.record(UInt64(Int64.max))

        XCTAssertEqual(53, histogram.bucketCount)
        XCTAssertEqual(55_296, histogram.counts.count)
    }

    func testHistogramEqualsAfterResizing() {
        var histogram = Histogram<UInt64>(numberOfSignificantValueDigits: .three)

        histogram.record((UInt64(1) << 62) - 1)

        XCTAssertEqual(52, histogram.bucketCount)
        XCTAssertEqual(54_272, histogram.counts.count)

        histogram.record(UInt64(Int64.max))

        XCTAssertEqual(53, histogram.bucketCount)
        XCTAssertEqual(55_296, histogram.counts.count)

        histogram.reset()
        histogram.record((UInt64(1) << 62) - 1)

        var histogram1 = Histogram<UInt64>(numberOfSignificantValueDigits: .three)
        histogram1.record((UInt64(1) << 62) - 1)

        XCTAssertEqual(histogram, histogram1)
    }

    func testHistogramAutoSizing() {
        var histogram = Histogram<UInt64>(numberOfSignificantValueDigits: .three)

        for i in 0 ..< 63 {
            histogram.record(UInt64(1) << i)
        }

        XCTAssertEqual(53, histogram.bucketCount)
        XCTAssertEqual(55_296, histogram.counts.count)
    }

    func testAutoSizingAdd() throws {
        var histogram1 = Histogram<UInt64>(numberOfSignificantValueDigits: .two)
        //    let histogram2 = Histogram<UInt64>(numberOfSignificantValueDigits: .two)

        histogram1.record(1_000)
        histogram1.record(1_000_000_000)

        // FIXME:
        throw XCTSkip("Histogram.add() is not implemented yet")
        // histogram2.add(histogram1)

        //     XCTAssert(histogram2.valuesAreEquivalent(histogram2.max, 1_000_000_000),
        //               "Max should be equivalent to 1_000_000_000")
    }

    func testAutoSizingAcrossContinuousRange() {
        var histogram = Histogram<UInt64>(numberOfSignificantValueDigits: .two)

        for i: UInt64 in 0 ..< 10_000_000 {
            histogram.record(i)
        }
    }
}
// swiftlint:enable todo
