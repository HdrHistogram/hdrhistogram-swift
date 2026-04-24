//
// Copyright (c) 2023 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

// swiftlint:disable identifier_name

@testable import Histogram
import XCTest

final class HistogramMergeTests: XCTestCase {
    private static let highestTrackableValue: UInt64 = 3_600_000_000
    private static let digits = SignificantDigits.three

    private static func makeHistogram() -> Histogram<UInt64> {
        Histogram<UInt64>(
            highestTrackableValue: highestTrackableValue,
            numberOfSignificantValueDigits: digits)
    }

    func testMergeRoundTrip() throws {
        let values: [UInt64] = [
            1, 7, 42, 199, 1_000, 5_555, 10_000, 99_999,
            1_000_000, 12_345_678, 500_000_000, 3_000_000_000
        ]

        var a = Self.makeHistogram()
        var b = Self.makeHistogram()
        var reference = Self.makeHistogram()

        for (i, v) in values.enumerated() {
            if i.isMultiple(of: 2) {
                a.record(v)
            } else {
                b.record(v)
            }
            reference.record(v)
        }

        let bCountBefore = b.totalCount
        let bMaxBefore = b.maxRecorded

        a.add(b)

        XCTAssertEqual(a.totalCount, UInt64(values.count))
        XCTAssertEqual(a.totalCount, reference.totalCount)
        XCTAssertEqual(a.maxRecorded, reference.maxRecorded)
        XCTAssertEqual(a.minNonZero, reference.minNonZero)

        for pct in [0.0, 25.0, 50.0, 75.0, 90.0, 99.0, 99.9, 100.0] {
            XCTAssertEqual(
                a.valueAtPercentile(pct),
                reference.valueAtPercentile(pct),
                "mismatch at percentile \(pct)")
        }

        for i in 0 ..< a.counts.count {
            XCTAssertEqual(a.counts[i], reference.counts[i], "mismatch at bucket \(i)")
        }

        // `other` should be unchanged by the merge.
        XCTAssertEqual(b.totalCount, bCountBefore)
        XCTAssertEqual(b.maxRecorded, bMaxBefore)
    }

    func testAddEmptyOtherLeavesSelfUnchanged() throws {
        var a = Self.makeHistogram()
        let empty = Self.makeHistogram()

        for v: UInt64 in [100, 1_000, 10_000, 100_000] {
            a.record(v)
        }

        let totalBefore = a.totalCount
        let maxBefore = a.maxRecorded
        let minBefore = a.minNonZero
        let snapshot = a

        a.add(empty)

        XCTAssertEqual(a.totalCount, totalBefore)
        XCTAssertEqual(a.maxRecorded, maxBefore)
        XCTAssertEqual(a.minNonZero, minBefore)
        XCTAssertEqual(a, snapshot)
    }

    func testAddSelfDoublesCounts() throws {
        var a = Self.makeHistogram()
        for v: UInt64 in [1, 10, 100, 1_000, 10_000] {
            a.record(v)
        }

        let snapshot = a
        a.add(snapshot)

        XCTAssertEqual(a.totalCount, snapshot.totalCount * 2)
        XCTAssertEqual(a.maxRecorded, snapshot.maxRecorded)
        XCTAssertEqual(a.minNonZero, snapshot.minNonZero)

        for iv in snapshot.recordedValues() {
            XCTAssertEqual(a.countForValue(iv.value), iv.count * 2)
        }
    }

    func testAddGrowsSelfWhenOtherIsLargerAndSelfAutoResizes() {
        // Fresh auto-resizing histograms start with a tiny backing array.
        // Growing `other` via record() then merging into a fresh `self` should
        // resize `self` transparently; no precondition failure, no data loss.
        var other = Histogram<UInt64>(numberOfSignificantValueDigits: .two)
        other.record(1_000)
        other.record(1_000_000_000)

        var selfH = Histogram<UInt64>(numberOfSignificantValueDigits: .two)
        XCTAssertLessThan(selfH.counts.count, other.counts.count,
                          "precondition of this test: other's backing array is larger")

        selfH.add(other)

        XCTAssertEqual(selfH.totalCount, 2)
        XCTAssertEqual(selfH, other)
        XCTAssertTrue(selfH.valuesAreEquivalent(selfH.maxRecorded, 1_000_000_000))
        XCTAssertEqual(selfH.counts.count, other.counts.count,
                       "self should have grown to other's size")
    }

    func testAddResizedAndResetOtherIntoFreshIsNoOp() {
        // The case flagged in review: `other` auto-resized larger, then was reset.
        // It's equal (`==`) to a fresh histogram but has a larger backing array.
        // Merging it in should be a complete no-op — including leaving `fresh`'s
        // public range state (`highestTrackableValue`, `counts.count`) untouched.
        // (`==` ignores backing length and `highestTrackableValue`, so relying on
        // it alone would mask a regression that inflated the receiver's range.)
        var other = Histogram<UInt64>(numberOfSignificantValueDigits: .two)
        other.record(1_000_000_000)
        other.reset()

        var fresh = Histogram<UInt64>(numberOfSignificantValueDigits: .two)
        XCTAssertEqual(fresh, other, "resized-and-reset should compare equal to fresh")
        XCTAssertLessThan(fresh.counts.count, other.counts.count)

        let freshSnapshot = fresh
        let freshHTVBefore = fresh.highestTrackableValue
        let freshCountsCountBefore = fresh.counts.count

        fresh.add(other)

        XCTAssertEqual(fresh.totalCount, 0)
        XCTAssertEqual(fresh, freshSnapshot, "merging a reset histogram should not change contents")
        XCTAssertEqual(fresh.highestTrackableValue, freshHTVBefore,
                       "no-op merge must not inflate receiver's highestTrackableValue")
        XCTAssertEqual(fresh.counts.count, freshCountsCountBefore,
                       "no-op merge must not grow receiver's backing array")

        // And the reverse: `reset.add(fresh)` must also be a no-op, including
        // not shrinking `other`'s already-grown backing array.
        let otherSnapshot = other
        let otherHTVBefore = other.highestTrackableValue
        let otherCountsCountBefore = other.counts.count

        other.add(fresh)

        XCTAssertEqual(other.totalCount, 0)
        XCTAssertEqual(other, otherSnapshot)
        XCTAssertEqual(other.highestTrackableValue, otherHTVBefore)
        XCTAssertEqual(other.counts.count, otherCountsCountBefore)
    }

    func testAddLargerOtherWithOnlySmallValuesDoesNotResizeAutoResizingReceiver() {
        // Reviewer-supplied repro: `other` has a larger backing array but its
        // recorded value (1) already fits in a fresh auto-resizing receiver. A
        // replay of `other.recordedValues()` would call `self.record(1)`, which
        // does not resize, so `add()` must not resize either.
        var other = Histogram<UInt64>(highestTrackableValue: 1_000_000, numberOfSignificantValueDigits: .two)
        other.record(1)

        var receiver = Histogram<UInt64>(numberOfSignificantValueDigits: .two)
        XCTAssertTrue(receiver.autoResize)
        let htvBefore = receiver.highestTrackableValue
        let countsCountBefore = receiver.counts.count
        XCTAssertLessThan(countsCountBefore, other.counts.count,
                          "precondition of this test: other has the longer backing array")

        receiver.add(other)

        XCTAssertEqual(receiver.totalCount, 1)
        XCTAssertEqual(receiver.maxRecorded, 1)
        XCTAssertEqual(receiver.highestTrackableValue, htvBefore,
                       "receiver must not grow when other's values all fit in the existing backing array")
        XCTAssertEqual(receiver.counts.count, countsCountBefore,
                       "receiver must not grow backing array when unnecessary")
    }

    func testAddSmallerOtherLeavesSelfTailUntouched() {
        // When `self` is the larger one, merging `other` should only touch the
        // common prefix; self's tail counts survive.
        var selfH = Histogram<UInt64>(numberOfSignificantValueDigits: .two)
        selfH.record(1_000_000_000) // grows selfH
        let selfHighBucketIndex = selfH.counts.count - 1
        let selfBucketValueBefore = selfH.counts[selfHighBucketIndex]

        var other = Histogram<UInt64>(numberOfSignificantValueDigits: .two)
        other.record(1_000) // small; other stays small
        XCTAssertLessThan(other.counts.count, selfH.counts.count)

        selfH.add(other)

        XCTAssertEqual(selfH.totalCount, 2)
        XCTAssertEqual(selfH.counts[selfHighBucketIndex], selfBucketValueBefore,
                       "self's tail buckets must survive merging a shorter `other`")
    }

    func testAddSmallerFixedSizeOtherIntoLargerFixedSizeSelf() {
        // Non-auto-resizing analogue of testAddSmallerOtherLeavesSelfTailUntouched:
        // both histograms have `autoResize == false`, `self` has the larger backing
        // array, and `other` has recorded values entirely within the common prefix.
        // self's public range state must be unchanged, its tail buckets untouched,
        // and the overlapping counts correctly summed.
        var selfH = Histogram<UInt64>(highestTrackableValue: 10_000_000, numberOfSignificantValueDigits: .three)
        var other = Histogram<UInt64>(highestTrackableValue: 10_000, numberOfSignificantValueDigits: .three)
        XCTAssertFalse(selfH.autoResize)
        XCTAssertFalse(other.autoResize)
        XCTAssertGreaterThan(selfH.counts.count, other.counts.count,
                             "precondition of this test: self has the larger backing array")

        // Record a value in self that lives past other's backing range, so the
        // "tail untouched" invariant has something observable to protect.
        selfH.record(5_000_000)
        other.record(500)

        let selfHTVBefore = selfH.highestTrackableValue
        let selfSizeBefore = selfH.counts.count
        let selfMaxBefore = selfH.maxRecorded

        selfH.add(other)

        XCTAssertEqual(selfH.totalCount, 2)
        XCTAssertEqual(selfH.counts.count, selfSizeBefore,
                       "self's backing length must not change when other is smaller")
        XCTAssertEqual(selfH.highestTrackableValue, selfHTVBefore,
                       "self's highestTrackableValue must not change when other is smaller")
        XCTAssertEqual(selfH.maxRecorded, selfMaxBefore,
                       "self.max must survive merging a smaller other")
        XCTAssertTrue(selfH.valuesAreEquivalent(selfH.minNonZero, 500),
                      "self.minNonZero must come from other's smaller value")
    }

    func testAddIntoFixedSizeSelfWhenOtherLongerButInRange() {
        // Non-auto-resizing `self`: merging a longer `other` is OK as long as
        // `other` never recorded anything beyond what fits in `self`'s backing
        // array. This covers the case where `other` was constructed with more
        // headroom but only ever saw values that `self` can also represent.
        var selfH = Histogram<UInt64>(highestTrackableValue: 1_000_000, numberOfSignificantValueDigits: .three)
        XCTAssertFalse(selfH.autoResize)

        var other = Histogram<UInt64>(highestTrackableValue: 1_000_000_000, numberOfSignificantValueDigits: .three)
        XCTAssertFalse(other.autoResize)
        other.record(42)
        other.record(9_999)

        XCTAssertGreaterThan(other.counts.count, selfH.counts.count)
        XCTAssertLessThanOrEqual(other.maxRecorded, selfH.highestTrackableValue)

        selfH.add(other)

        XCTAssertEqual(selfH.totalCount, 2)
        XCTAssertTrue(selfH.valuesAreEquivalent(selfH.maxRecorded, 9_999))
        XCTAssertTrue(selfH.valuesAreEquivalent(selfH.minNonZero, 42))
    }

    func testAddAcceptsValuesAboveHighestTrackableWhenTheyFitInBackingArray() {
        // A 3-digit histogram rounds `subBucketCount` up to the next power of two,
        // so `record(_:)` accepts values that exceed the nominal
        // `highestTrackableValue` as long as the computed index is still within
        // `counts`. The merge API must match that acceptance rule; rejecting this
        // class of merge would make `add(_:)` stricter than `record(_:)`.
        //
        // Concrete repro from review: highestTrackableValue=1_000 / .three digits
        // yields a 2048-entry backing array, so `record(1_500)` succeeds. The
        // matching `add(_:)` of another histogram that recorded 1_500 must also
        // succeed, even though 1_500 > nominal highestTrackableValue.
        var probe = Histogram<UInt64>(highestTrackableValue: 1_000, numberOfSignificantValueDigits: .three)
        XCTAssertTrue(probe.record(1_500),
                      "precondition of this test: record(1_500) fits in the backing array")
        XCTAssertGreaterThan(probe.maxRecorded, probe.highestTrackableValue,
                             "precondition: 1_500 is above the nominal highestTrackableValue")

        // Case A: same-layout same-size. No counts.count mismatch; guard doesn't fire.
        var selfA = Histogram<UInt64>(highestTrackableValue: 1_000, numberOfSignificantValueDigits: .three)
        var otherA = Histogram<UInt64>(highestTrackableValue: 1_000, numberOfSignificantValueDigits: .three)
        otherA.record(1_500)
        selfA.add(otherA)
        XCTAssertEqual(selfA.totalCount, 1)
        XCTAssertTrue(selfA.valuesAreEquivalent(selfA.maxRecorded, 1_500))

        // Case B: other has a longer backing array, self.autoResize=false, other's
        // `maxValue` exceeds `self.highestTrackableValue` but still fits in `self`'s
        // backing array. Previously this trapped on the too-strict guard; now it
        // should succeed losslessly.
        var selfB = Histogram<UInt64>(highestTrackableValue: 1_000, numberOfSignificantValueDigits: .three)
        XCTAssertFalse(selfB.autoResize)
        var otherB = Histogram<UInt64>(highestTrackableValue: 1_000_000, numberOfSignificantValueDigits: .three)
        otherB.record(1_500)
        XCTAssertGreaterThan(otherB.counts.count, selfB.counts.count,
                             "precondition: other has the longer backing array")
        XCTAssertGreaterThan(otherB.maxRecorded, selfB.highestTrackableValue,
                             "precondition: other.maxValue > self.highestTrackableValue")

        selfB.add(otherB)

        XCTAssertEqual(selfB.totalCount, 1)
        XCTAssertTrue(selfB.valuesAreEquivalent(selfB.maxRecorded, 1_500))
    }

    // NOTE on the precondition traps:
    //
    // `Histogram.add(_:)` calls `precondition(...)` in two cases:
    //   1. `numberOfSignificantValueDigits` or `lowestDiscernibleValue` differ
    //      between the two histograms (the bucket layout would not line up).
    //   2. `other.counts.count > self.counts.count`, `self.autoResize == false`,
    //      and `other` has recorded a value that would not fit in `self`'s
    //      current backing array (merging would drop counts in the overflow
    //      region). This is the same acceptance rule `record(_:count:)` uses —
    //      a value above `highestTrackableValue` is still fine as long as its
    //      computed index stays within `counts`.
    //
    // Hard traps can't be caught in XCTest without signal-handling infra (e.g.
    // CwlPreconditionTesting) that this package does not depend on. This test
    // documents the trap inputs by asserting the guarded conditions really do
    // produce the distinguishing state — a drop-in set of inputs for anyone who
    // later adds CwlPreconditionTesting.
    func testLayoutMismatchInputsThatWouldTrap() {
        // Case (1a) — different numberOfSignificantValueDigits.
        let twoDigits = Histogram<UInt64>(highestTrackableValue: 1_000_000, numberOfSignificantValueDigits: .two)
        let fourDigits = Histogram<UInt64>(highestTrackableValue: 1_000_000, numberOfSignificantValueDigits: .four)
        XCTAssertNotEqual(twoDigits.numberOfSignificantValueDigits, fourDigits.numberOfSignificantValueDigits)

        // Case (1b) — different lowestDiscernibleValue.
        let lowOne = Histogram<UInt64>(lowestDiscernibleValue: 1, highestTrackableValue: 1_000_000_000)
        let lowThousand = Histogram<UInt64>(lowestDiscernibleValue: 1_000, highestTrackableValue: 1_000_000_000)
        XCTAssertNotEqual(lowOne.lowestDiscernibleValue, lowThousand.lowestDiscernibleValue)

        // Case (2) — fixed-size self, other has recorded a value that does not
        // fit in self's backing array. Cross-check via record() on a self-shaped
        // probe: if the same value can't be record()ed into self, it definitely
        // can't be merged in either.
        let selfH = Histogram<UInt64>(highestTrackableValue: 1_000, numberOfSignificantValueDigits: .three)
        var otherH = Histogram<UInt64>(highestTrackableValue: 100_000_000, numberOfSignificantValueDigits: .three)
        otherH.record(50_000_000)
        XCTAssertFalse(selfH.autoResize)
        XCTAssertGreaterThan(otherH.counts.count, selfH.counts.count)
        var probe = selfH
        XCTAssertFalse(probe.record(otherH.maxRecorded),
                       "precondition of this case: other.maxRecorded does not fit in self's backing array")
    }
}

// swiftlint:enable identifier_name
