import XCTest
import CoreText
import StrandAnalytics
import WhoopStore
@testable import Strand

final class NutritionDocumentTests: XCTestCase {
    private let text = "Burger 1 item 250 kcal 12 protein 30 carbs 9 fat"

    private func fixture() -> (NutritionDocument, NutritionDocumentPage, String) {
        let page = NutritionDocumentPage(number: 2, text: text)
        let document = NutritionDocument(title: "menu.pdf", sha256: "abc", pages: [page])
        let reply = """
        {"items":[{"name":"Burger","serving":"1 item","kcal":250,"protein":12,"carbs":30,"fat":9,
        "fiber":null,"evidence":"Burger 1 item 250 kcal 12 protein 30 carbs 9 fat"}]}
        """
        return (document, page, reply)
    }

    func testExtractedValuesKeepTheirServingAndDocumentProvenance() throws {
        let (document, page, reply) = fixture()
        let row = try XCTUnwrap(NutritionDocumentRow.parse(reply, page: page, document: document,
            brand: "Restaurant", market: "Japan").first)
        XCTAssertEqual(row.food.name, "Restaurant [Japan] · Burger")
        XCTAssertEqual(row.food.servingLabel, "1 item")
        XCTAssertEqual(row.food.macros, MacroTotals(kcal: 250, protein: 12, carbs: 30, fat: 9, fiber: 0))
        let provenance = try XCTUnwrap(NutritionDocumentSource.decode(row.food.macroSource))
        XCTAssertEqual(provenance.documentSHA256, "abc")
        XCTAssertEqual(provenance.page, 2)
        XCTAssertEqual(provenance.evidence, text)
        XCTAssertFalse(provenance.fiberListed)
        XCTAssertFalse(provenance.userAdjusted)
        var adjusted = row
        adjusted.macros.kcal = 260
        XCTAssertTrue(try XCTUnwrap(NutritionDocumentSource.decode(adjusted.food.macroSource)).userAdjusted)
    }

    func testInventedEvidenceMissingMacrosAndUnsupportedNumbersCannotBecomeFoods() throws {
        let (document, page, reply) = fixture()
        for invalid in [reply.replacingOccurrences(of: "\"kcal\":250", with: "\"kcal\":999"),
                        reply.replacingOccurrences(of: "\"protein\":12,", with: ""),
                        reply.replacingOccurrences(of: "\"name\":\"Burger\"", with: "\"name\":\"Invented\""),
                        reply.replacingOccurrences(of: "\"serving\":\"1 item\"", with: "\"serving\":\"500 g\""),
                        reply.replacingOccurrences(of: "9 fat\"", with: "9 fat invented\"")] {
            XCTAssertTrue(try NutritionDocumentRow.parse(invalid, page: page, document: document,
                brand: "Restaurant", market: "Japan").isEmpty)
        }
    }

    @MainActor
    func testReviewSaveIsIdempotentAndCoachLogsStoredValuesWithoutEstimating() async throws {
        let (document, page, reply) = fixture()
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "nutrition-document-test")
        repo.setStoreForTesting(store)
        let rows = try NutritionDocumentRow.parse(reply, page: page, document: document,
            brand: "Restaurant", market: "Japan")
        let firstCount = try await repo.saveNutritionDocumentRows(rows)
        XCTAssertEqual(firstCount, 1)
        let first = await repo.foodLibrary()
        _ = try await repo.saveNutritionDocumentRows(rows)
        let library = await repo.foodLibrary()
        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library.first?.id, first.first?.id)
        let item = try XCTUnwrap(library.first)
        let proposal = try XCTUnwrap(FoodProposal.resolve(
            FoodActionRequest(action: .log(itemId: item.id.uuidString, portion: 2)),
            library: library, recipeIds: [], defaultServingLabel: "1 serving", lastKnownWeightKg: nil))
        let logged = await repo.applyFoodProposal(proposal)
        XCTAssertTrue(logged)
        let entries = await repo.foodEntries(day: proposal.dayKey)
        XCTAssertEqual(entries.first?.effectiveMacros.kcal, 500)
        XCTAssertEqual(entries.first?.macroSource, item.macroSource)
        XCTAssertEqual(NutritionDocumentSource.decode(entries.first?.macroSource)?.market, "Japan")
    }

    @MainActor
    func testRoughPortionRetainsDocumentSourceAndFlagsIntakeUncertainty() async throws {
        let (document, page, reply) = fixture()
        let row = try XCTUnwrap(NutritionDocumentRow.parse(reply, page: page, document: document,
            brand: "Restaurant", market: "Japan").first)
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "document-rough-test")
        repo.setStoreForTesting(store)
        let day = Repository.localDayKey(Date())
        await repo.logFood(item: row.food, portion: 1.5, day: day, roughGuess: true)
        let entries = await repo.foodEntries(day: day)
        let source = try XCTUnwrap(NutritionDocumentSource.decode(entries.first?.macroSource))
        XCTAssertEqual(source.documentSHA256, document.sha256)
        XCTAssertEqual(source.roughGuess, true)
        let roughDays = await repo.roughIntakeDays(days: 2)
        XCTAssertTrue(roughDays.contains(day))
        let restored = FoodMacroSource.forEntry(entries.first?.macroSource, rough: false)
        XCTAssertFalse(FoodMacroSource.isRough(restored))
        XCTAssertEqual(NutritionDocumentSource.decode(restored)?.page, 2)
    }

    func testPDFTextIsReadLocallyAndPagesKeepTheirSourceNumber() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 20, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let document = try await NutritionDocument.read(url: url)
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertEqual(document.pages.first?.number, 1)
        XCTAssertTrue(document.pages.first?.text.contains("Burger") == true)
        XCTAssertEqual(document.sha256.count, 64)
    }

    func testRelevantDocumentItemIsNotLostBehindSixtyRecentFoods() {
        let ordinary = (0..<80).map { FoodItem(name: "Food \($0)", servingLabel: "1 item", macros: .zero) }
        let burger = FoodItem(name: "McDonald's [Japan] · Burger", servingLabel: "1 item", macros: .zero)
        let ranked = NutritionDocumentCatalog.ranked(ordinary + [burger], query: "log mcds burger")
        XCTAssertEqual(ranked.first?.id, burger.id)
    }
}
