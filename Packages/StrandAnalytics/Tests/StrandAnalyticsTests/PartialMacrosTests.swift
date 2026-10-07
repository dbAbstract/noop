import XCTest
@testable import StrandAnalytics

/// Macros where absent is a real state.
///
/// The premise: restaurant data is partial by nature — one chain publishes no fibre, another no fat. With
/// non-optional fields those are indistinguishable from zero, and a model told "90 kcal, 6P" logs a
/// fat-free piece of fish.
final class PartialMacrosTests: XCTestCase {

    // MARK: - Absent is not zero

    func testAnAbsentFieldStaysAbsent() {
        let m = PartialMacros(kcal: 90, protein: 6)
        XCTAssertNil(m.fat)
        XCTAssertNil(m.fiber)
        XCTAssertFalse(m.isComplete)
    }

    /// A non-finite or negative figure becomes ABSENT, never zero — clamping would manufacture exactly the
    /// false certainty this type exists to prevent.
    func testNonsenseBecomesAbsentRatherThanZero() {
        let m = PartialMacros(kcal: .nan, protein: -5, carbs: .infinity)
        XCTAssertNil(m.kcal)
        XCTAssertNil(m.protein)
        XCTAssertNil(m.carbs)
    }

    // MARK: - Gaps that are not gaps

    /// THE USEFUL PART. Atwater is an identity, so one missing field among four is exact arithmetic — no
    /// model, no question. Kura publishing kcal/P/C but no fat needs no inference at all.
    func testAMissingFatIsComputedExactly() {
        // 90 kcal, 6P, 3C → 9F·x = 90 − 24 − 12 = 54 → 6 g fat.
        let filled = PartialMacroMath.derived(PartialMacros(kcal: 90, protein: 6, carbs: 3))
        XCTAssertEqual(filled.fat ?? .nan, 6, accuracy: 0.001)
    }

    func testAMissingKcalIsComputedFromTheMacros() {
        let filled = PartialMacroMath.derived(PartialMacros(protein: 6, carbs: 3, fat: 6))
        XCTAssertEqual(filled.kcal ?? .nan, 90, accuracy: 0.001)
    }

    func testAMissingCarbIsComputed() {
        let filled = PartialMacroMath.derived(PartialMacros(kcal: 90, protein: 6, fat: 6))
        XCTAssertEqual(filled.carbs ?? .nan, 3, accuracy: 0.001)
    }

    /// TWO unknowns leave one equation underdetermined. Filling either would be inference wearing
    /// arithmetic's clothes, so the row stays incomplete and goes to the ask-first path.
    func testTwoMissingFieldsAreNotGuessed() {
        let filled = PartialMacroMath.derived(PartialMacros(kcal: 90, protein: 6))
        XCTAssertNil(filled.carbs)
        XCTAssertNil(filled.fat)
    }

    /// Fibre carries no energy in this app's Atwater sum, so it is never derived.
    func testFibreIsNeverDerived() {
        let filled = PartialMacroMath.derived(PartialMacros(kcal: 90, protein: 6, carbs: 3, fat: 6))
        XCTAssertNil(filled.fiber)
    }

    /// A derived figure below zero means the published fields contradict each other. Left absent, so the
    /// contradiction surfaces in validation instead of being stored as a confident 0.
    func testAnImpossibleDerivationStaysAbsent() {
        // 20 kcal cannot contain 6P (24 kcal) plus 3C.
        let filled = PartialMacroMath.derived(PartialMacros(kcal: 20, protein: 6, carbs: 3))
        XCTAssertNil(filled.fat)
    }

    // MARK: - Validation: missing is fine, contradictory is not

    /// THE IMPORT POLICY IN ONE TEST. A chain not publishing fibre is normal and must not fail a row —
    /// the nullable columns exist for exactly this.
    func testMissingFieldsAreNotAProblem() {
        XCTAssertNil(PartialMacroMath.problem(in: PartialMacros(kcal: 90, protein: 6)))
        XCTAssertNil(PartialMacroMath.problem(in: PartialMacros(kcal: 90, protein: 6, carbs: 3)))
    }

    /// A row whose published kcal disagrees with its own published macros means the parser put a column in
    /// the wrong place — and a parser that misaligned this row has no claim to the others.
    func testAContradictoryRowIsCaught() {
        let m = PartialMacros(kcal: 900, protein: 6, carbs: 3, fat: 6)   // implies 90
        guard case .contradictory(let stated, let implied)? = PartialMacroMath.problem(in: m) else {
            return XCTFail("a self-contradicting row must be caught")
        }
        XCTAssertEqual(stated, 900)
        XCTAssertEqual(implied, 90, accuracy: 1)
    }

    /// A DERIVED field is exact by construction, so checking it against the identity it came from would
    /// always pass and prove nothing. The check must bite only on independently published fields.
    func testADerivedRowIsNotFlaggedAgainstItsOwnArithmetic() {
        XCTAssertNil(PartialMacroMath.problem(in: PartialMacros(kcal: 90, protein: 6, carbs: 3)))
    }

    func testImplausibleFiguresAreCaught() {
        guard case .implausible? = PartialMacroMath.problem(in: PartialMacros(kcal: 40_000)) else {
            return XCTFail("a 40,000 kcal item is a misplaced decimal")
        }
        guard case .implausible? = PartialMacroMath.problem(in: PartialMacros(protein: 900)) else {
            return XCTFail("900 g of protein in one item is a per-100g column misread")
        }
    }

    func testAnEmptyRowIsCaught() {
        XCTAssertEqual(PartialMacroMath.problem(in: PartialMacros()), .empty)
    }

    // MARK: - Completing for a log

    func testACompletableRowYieldsConcreteMacros() {
        let totals = PartialMacroMath.complete(PartialMacros(kcal: 90, protein: 6, carbs: 3))
        XCTAssertEqual(totals?.fat ?? .nan, 6, accuracy: 0.001)
        // Fibre is reported as 0 when unpublished: it changes no total here, and refusing a whole row over
        // it would block logging for a fact nobody uses.
        XCTAssertEqual(totals?.fiber ?? .nan, 0)
    }

    /// REFUSES rather than zero-filling. A caller needing a total must borrow or estimate, and both are
    /// decisions the user agrees to rather than defaults the app picks silently.
    func testAnIncompletableRowRefuses() {
        XCTAssertNil(PartialMacroMath.complete(PartialMacros(kcal: 90, protein: 6)))
    }

    // MARK: - What the model is told

    /// THE LINE THAT STOPS A FAT-FREE TEMPURA. Omitting a field reads as zero; naming it as unpublished is
    /// what lets the model know to borrow or ask.
    func testMissingFieldsAreNamedNotOmitted() {
        let line = PartialMacroMath.describe(PartialMacros(kcal: 90, protein: 6))
        XCTAssertTrue(line.contains("F not published"))
        XCTAssertTrue(line.contains("fibre not published"))
        XCTAssertTrue(line.contains("kcal 90"))
    }

    /// A computed figure is marked, so the model does not weigh it as published evidence when deciding
    /// whether another chain's value is worth borrowing.
    func testDerivedFieldsAreMarkedAsSuch() {
        let line = PartialMacroMath.describe(PartialMacros(kcal: 90, protein: 6, carbs: 3))
        XCTAssertTrue(line.contains("derived"))
    }
}
