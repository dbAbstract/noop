import XCTest
import CoreText
import StrandAnalytics
import WhoopStore
@testable import Strand

final class NutritionDocumentTests: XCTestCase {
    private let text = "Burger 1 item 250 kcal 12 protein 30 carbs 9 fat"

    // A McDonald's Japan page the way PDFKit row reconstruction stores it.
    private let menu = """
    マクドナルド 栄養成分一覧
    商品名\tエネルギー(kcal)\tたんぱく質(g)\t脂質(g)\t炭水化物(g)\t食物繊維(g)
    ビッグマック\t525\t26.0\t28.3\t41.8\t2.6
    ダブルチーズバーガー\t457\t26.5\t24.7\t32.1\t1.9
    """

    @MainActor
    private func repoWithMenu(indexed: Bool = true) async throws -> (Repository, NutritionDocument) {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "nutrition-document-test")
        repo.setStoreForTesting(store)
        let document = NutritionDocument(title: "mcd-jp.pdf", sha256: String(repeating: "ab", count: 32),
                                         pages: [NutritionDocumentPage(number: 3, text: menu)])
        try await repo.storeNutritionDocument(document, brand: "McDonald's", market: "Japan",
            index: indexed ? [NutritionDocumentIndexItem(page: 3, line: 2, name: "ビッグマック", aliases: ["Big Mac"]),
                              NutritionDocumentIndexItem(page: 3, line: 3, name: "ダブルチーズバーガー",
                                                         aliases: ["Double Cheeseburger"])] : [])
        return (repo, document)
    }

    private func documentLog(_ key: String, kcal: Double = 525, protein: Double = 26, carbs: Double = 41.8,
                             fat: Double = 28.3, fiber: Double? = 2.6) -> FoodActionRequest {
        FoodActionRequest(action: .documentLog(rowKey: key, name: "Big Mac", servingLabel: "1 burger", kcal: kcal,
                                               protein: protein, carbs: carbs, fat: fat, fiber: fiber, portion: 1))
    }

    /// "Log a big mac" finds the Japanese row through its alias, with the header that names its columns.
    @MainActor
    func testAnEnglishRequestFindsTheJapaneseRowWithItsHeader() async throws {
        let (repo, _) = try await repoWithMenu()
        let rows = await repo.nutritionDocumentMatches(query: "can you log a big mac for lunch")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.text, "ビッグマック\t525\t26.0\t28.3\t41.8\t2.6")
        XCTAssertEqual(row.header, "商品名\tエネルギー(kcal)\tたんぱく質(g)\t脂質(g)\t炭水化物(g)\t食物繊維(g)")
        XCTAssertEqual(row.document.brand, "McDonald's")
        XCTAssertEqual(row.page, 3)
        XCTAssertEqual(row.aliases, ["Big Mac"])
    }

    /// Without an index the row is still found by the name as printed.
    @MainActor
    func testAnUnindexedDocumentAnswersTheNameAsPrinted() async throws {
        let (repo, _) = try await repoWithMenu(indexed: false)
        let english = await repo.nutritionDocumentMatches(query: "log a big mac")
        XCTAssertTrue(english.isEmpty)
        let japanese = await repo.nutritionDocumentMatches(query: "ダブルチーズバーガー")
        XCTAssertEqual(japanese.first?.line, 3)
    }

    /// The figures as printed resolve to a document card; logging it saves the food with its citation and
    /// logs the row's figures; a second log reuses the same library food.
    @MainActor
    func testAProposalWithPrintedFiguresLogsAndSavesTheDocumentFood() async throws {
        let (repo, document) = try await repoWithMenu()
        let found = await repo.nutritionDocumentMatches(query: "big mac")
        let key = try XCTUnwrap(found.first?.key)
        let rows = await repo.nutritionDocumentRows(keys: [key.uppercased()])
        let proposal = try XCTUnwrap(FoodProposal.resolve(documentLog(key.uppercased()), library: [], recipeIds: [],
            defaultServingLabel: "1 serving", lastKnownWeightKg: nil, documentRows: rows))
        guard case .documentLog(let name, let serving, let macros, _, let source, let row) = proposal.kind else {
            return XCTFail("expected a document card, got \(proposal.kind)")
        }
        XCTAssertEqual(name, "McDonald's [Japan] · Big Mac")
        XCTAssertEqual(serving, "1 burger")
        XCTAssertEqual(macros, MacroTotals(kcal: 525, protein: 26, carbs: 41.8, fat: 28.3, fiber: 2.6))
        XCTAssertEqual(source.page, 3)
        XCTAssertEqual(source.documentSHA256, document.sha256)
        XCTAssertTrue(source.evidence.contains("ビッグマック"))
        XCTAssertNotNil(row.header)

        let logged = await repo.applyFoodProposal(proposal)
        XCTAssertTrue(logged)
        let entries = await repo.foodEntries(day: proposal.dayKey)
        XCTAssertEqual(entries.first?.effectiveMacros.kcal, 525)
        XCTAssertEqual(NutritionDocumentSource.decode(entries.first?.macroSource)?.market, "Japan")
        let library = await repo.foodLibrary()
        XCTAssertEqual(library.map(\.name), ["McDonald's [Japan] · Big Mac"])

        let again = try XCTUnwrap(FoodProposal.resolve(documentLog(key), library: library, recipeIds: [],
            defaultServingLabel: "1 serving", lastKnownWeightKg: nil, documentRows: rows))
        _ = await repo.applyFoodProposal(again)
        let after = await repo.foodLibrary()
        XCTAssertEqual(after.count, 1, "the same row logged twice is one library food")
        XCTAssertEqual(after.first?.id, library.first?.id)
    }

    /// A figure not printed on the row, a key for no stored row, or a row the coach was not given: refused.
    @MainActor
    func testFiguresNotOnTheRowOrUnknownRowsAreRefused() async throws {
        let (repo, _) = try await repoWithMenu()
        let found = await repo.nutritionDocumentMatches(query: "big mac")
        let key = try XCTUnwrap(found.first?.key)
        let rows = await repo.nutritionDocumentRows(keys: [key, "dffffffffp3l2"])
        XCTAssertEqual(rows.count, 1)
        for request in [documentLog(key, kcal: 540), documentLog(key, fat: 30), documentLog(key, fiber: 3),
                        documentLog("dffffffffp3l2"), documentLog(key.replacingOccurrences(of: "l2", with: "l9"))] {
            let p = try XCTUnwrap(FoodProposal.resolve(request, library: [], recipeIds: [],
                defaultServingLabel: "1 serving", lastKnownWeightKg: nil, documentRows: rows))
            guard case .unresolved = p.kind else { return XCTFail("expected a refusal for \(request)") }
        }
    }

    /// The row reaches the coach: the stored document is named, and the matched row is listed with its key,
    /// header and printed line — matched on what the USER said, not on the coach's own replies.
    @MainActor
    func testCoachContextListsTheMatchedRowForWhatTheUserSaid() async throws {
        let oldEnabled = UserDefaults.standard.object(forKey: FoodLogStore.enabledKey)
        UserDefaults.standard.set(true, forKey: FoodLogStore.enabledKey)
        defer {
            if let oldEnabled { UserDefaults.standard.set(oldEnabled, forKey: FoodLogStore.enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: FoodLogStore.enabledKey) }
        }
        let (repo, _) = try await repoWithMenu()
        let coach = AICoachEngine(repo: repo)
        coach.messages = [ChatMessage(role: .assistant, text: "Double cheeseburgers are popular."),
                          ChatMessage(role: .user, text: "log a big mac for lunch")]
        let block = await coach.nutritionDocumentBlock()
        XCTAssertTrue(block.contains("Stored: McDonald's [Japan] (mcd-jp.pdf, 1 pages)"))
        XCTAssertTrue(block.contains("row: ビッグマック\t525\t26.0\t28.3\t41.8\t2.6"))
        XCTAssertTrue(block.contains("header: 商品名"))
        XCTAssertFalse(block.contains("ダブルチーズバーガー\t457"), "the coach's own mention does not pull a row in")
        let context = await coach.foodContextBlock()
        XCTAssertTrue(context.text.contains("NUTRITION DOCUMENTS"))

        coach.messages = [ChatMessage(role: .user, text: "log a filet-o-fish")]
        let miss = await coach.nutritionDocumentBlock()
        XCTAssertTrue(miss.contains("No row matched this conversation."))
    }

    @MainActor
    func testDeletingADocumentKeepsWhatWasLoggedFromIt() async throws {
        let (repo, _) = try await repoWithMenu()
        let found = await repo.nutritionDocumentMatches(query: "big mac")
        let key = try XCTUnwrap(found.first?.key)
        let rows = await repo.nutritionDocumentRows(keys: [key])
        let proposal = try XCTUnwrap(FoodProposal.resolve(documentLog(key), library: [], recipeIds: [],
            defaultServingLabel: "1 serving", lastKnownWeightKg: nil, documentRows: rows))
        _ = await repo.applyFoodProposal(proposal)
        let docs = await repo.nutritionDocuments()
        let docId = try XCTUnwrap(docs.first?.id)
        await repo.deleteNutritionDocument(id: docId)
        let gone = await repo.nutritionDocumentMatches(query: "big mac")
        XCTAssertTrue(gone.isEmpty)
        let library = await repo.foodLibrary()
        XCTAssertEqual(library.count, 1)
        let entries = await repo.foodEntries(day: proposal.dayKey)
        XCTAssertEqual(entries.count, 1)
    }

    @MainActor
    func testRoughPortionRetainsDocumentSourceAndFlagsIntakeUncertainty() async throws {
        let source = NutritionDocumentSource(title: "menu.pdf", brand: "Restaurant", market: "Japan",
                                             documentSHA256: "abc", page: 2, evidence: "Burger 250 12 30 9",
                                             fiberListed: false, userAdjusted: false)
        let food = FoodItem(macroSource: source.stored, name: "Restaurant [Japan] · Burger", servingLabel: "1 item",
                            macros: MacroTotals(kcal: 250, protein: 12, carbs: 30, fat: 9, fiber: 0))
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "document-rough-test")
        repo.setStoreForTesting(store)
        let day = Repository.localDayKey(Date())
        await repo.logFood(item: food, portion: 1.5, day: day, roughGuess: true)
        let entries = await repo.foodEntries(day: day)
        let decoded = try XCTUnwrap(NutritionDocumentSource.decode(entries.first?.macroSource))
        XCTAssertEqual(decoded.documentSHA256, "abc")
        XCTAssertEqual(decoded.roughGuess, true)
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
