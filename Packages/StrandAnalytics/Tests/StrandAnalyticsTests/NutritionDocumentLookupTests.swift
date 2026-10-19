import XCTest
@testable import StrandAnalytics

/// Finding a requested food in a stored nutrition document, and refusing figures the row does not print.
final class NutritionDocumentLookupTests: XCTestCase {

    // A page the way PDFKit row reconstruction stores it: tab-separated cells, one row per line.
    private let page = """
    マクドナルド 栄養成分一覧
    商品名\tエネルギー(kcal)\tたんぱく質(g)\t脂質(g)\t炭水化物(g)\t食物繊維(g)
    ビッグマック\t525\t26.0\t28.3\t41.8\t2.6
    ダブルチーズバーガー\t457\t26.5\t24.7\t32.1\t1.9
    てりやきマックバーガー\t477\t14.8\t30.2\t36.7\t2.1
    """

    private var entries: [NutritionDocumentLookup.Entry] {
        [.init(documentId: "a1b2c3d4-0000", page: 3, line: 2, name: "ビッグマック", aliases: ["Big Mac", "biggu makku"]),
         .init(documentId: "a1b2c3d4-0000", page: 3, line: 3, name: "ダブルチーズバーガー", aliases: ["Double Cheeseburger"]),
         .init(documentId: "a1b2c3d4-0000", page: 3, line: 4, name: "てりやきマックバーガー",
               aliases: ["Teriyaki McBurger", "Teriyaki Mac Burger"])]
    }

    // MARK: - Matching

    /// An English request finds the Japanese row through its alias; the Japanese name finds it directly.
    func testEnglishAndJapaneseRequestsFindTheSameRow() {
        let english = NutritionDocumentLookup.match(query: "log a big mac for lunch", entries: entries)
        XCTAssertEqual(english.first?.line, 2)
        XCTAssertEqual(english.count, 1, "'mac' alone does not drag in the Teriyaki McBurger")
        let japanese = NutritionDocumentLookup.match(query: "ビッグマック食べた", entries: entries)
        XCTAssertEqual(japanese.first?.line, 2)
        let fullWidth = NutritionDocumentLookup.match(query: "ＢＩＧ ＭＡＣ", entries: entries)
        XCTAssertEqual(fullWidth.first?.line, 2, "full-width Latin folds to what the user typed")
    }

    func testEveryMeaningfulWordMustAppearForAWordMatch() {
        XCTAssertEqual(NutritionDocumentLookup.match(query: "teriyaki burger please", entries: entries).first?.line, nil,
                       "'mac' is missing, so not a match on word overlap")
        XCTAssertEqual(NutritionDocumentLookup.match(query: "a teriyaki mac burger", entries: entries).first?.line, 4)
        XCTAssertTrue(NutritionDocumentLookup.match(query: "had lunch today", entries: entries).isEmpty)
    }

    /// A document stored without an index still answers a request in its own words.
    func testUnindexedPagesMatchOnRawLines() {
        let m = NutritionDocumentLookup.match(query: "ダブルチーズバーガー", entries: [],
                                              unindexedPages: [("doc", 3, page)])
        XCTAssertEqual(m.map(\.line), [3], "the exact Japanese name finds its row with no index at all")
        let english = "Menu\nItem\tkcal\tProtein\tFat\tCarbs\nCheeseburger Deluxe\t480\t25\t22\t40\nSalad\t120\t3\t5\t12"
        let hit = NutritionDocumentLookup.match(query: "log a cheeseburger deluxe", entries: [],
                                                unindexedPages: [("doc", 1, english)])
        XCTAssertEqual(hit.map(\.line), [2])
        XCTAssertNil(hit.first?.name)
    }

    // MARK: - Header and figures

    func testHeaderIsTheNearestOneAbove() {
        XCTAssertEqual(NutritionDocumentLookup.header(forLine: 2, inPage: page),
                       "商品名\tエネルギー(kcal)\tたんぱく質(g)\t脂質(g)\t炭水化物(g)\t食物繊維(g)")
        XCTAssertFalse(NutritionDocumentLookup.isHeader("ビッグマック\t525\t26.0\t28.3\t41.8\t2.6"))
        XCTAssertNil(NutritionDocumentLookup.header(forLine: 99, inPage: page))
    }

    func testFiguresMustAllBePrintedOnTheRow() {
        let row = "ビッグマック\t525\t26.0\t28.3\t41.8\t2.6"
        XCTAssertTrue(NutritionDocumentLookup.figuresArePrinted(kcal: 525, protein: 26, carbs: 41.8, fat: 28.3,
                                                                fiber: 2.6, in: row))
        XCTAssertTrue(NutritionDocumentLookup.figuresArePrinted(kcal: 525, protein: 26, carbs: 41.8, fat: 28.3,
                                                                fiber: nil, in: row))
        XCTAssertFalse(NutritionDocumentLookup.figuresArePrinted(kcal: 530, protein: 26, carbs: 41.8, fat: 28.3,
                                                                 fiber: nil, in: row), "a remembered kcal")
        // The known limit: swapped columns pass, because both numbers ARE printed. The check stops invented
        // figures, not misassigned ones — which is why the card shows the row beside its header.
        XCTAssertTrue(NutritionDocumentLookup.figuresArePrinted(kcal: 525, protein: 26, carbs: 28.3, fat: 41.8,
                                                                fiber: nil, in: row))
    }

    /// Thousands separators, decimal commas and full-width digits all read as the menu meant them.
    func testNumbersReadEveryWayAMenuPrintsThem() {
        XCTAssertTrue(NutritionDocumentLookup.numbers(in: "Mega set 1,050 kcal").contains(1_050))
        XCTAssertTrue(NutritionDocumentLookup.numbers(in: "Salade 2,5 g").contains(2.5))
        XCTAssertTrue(NutritionDocumentLookup.numbers(in: "ビッグマック　５２５　２６．０").contains(525))
        XCTAssertTrue(NutritionDocumentLookup.numbers(in: "ビッグマック　５２５　２６．０").contains(26))
        XCTAssertTrue(NutritionDocumentLookup.numbers(in: "no figures here").isEmpty)
    }

    // MARK: - Row keys

    func testRowKeysRoundTripAndRefuseOtherShapes() throws {
        let key = NutritionDocumentLookup.rowKey(documentId: "A1B2C3D4-E5F6-0000-0000-000000000000", page: 3, line: 12)
        XCTAssertEqual(key, "da1b2c3d4p3l12")
        let parsed = try XCTUnwrap(NutritionDocumentLookup.parseRowKey(" DA1B2C3D4P3L12 "))
        XCTAssertEqual(parsed.page, 3)
        XCTAssertEqual(parsed.line, 12)
        XCTAssertTrue(NutritionDocumentLookup.key(parsed, names: "a1b2c3d4-e5f6-0000-0000-000000000000"))
        XCTAssertFalse(NutritionDocumentLookup.key(parsed, names: "ffffffff-0000"))
        for bad in ["", "w1792058357", "da1b2p3l1", "da1b2c3d4p0l1", "da1b2c3d4pxl1", "a1b2c3d4p3l12"] {
            XCTAssertNil(NutritionDocumentLookup.parseRowKey(bad), bad)
        }
    }

    // MARK: - Building the index

    func testIndexReplyKeepsOnlyRealRowsWithTheirPrintedName() {
        let reply = """
        ```json
        {"items":[
          {"line":2,"name":"ビッグマック","aliases":["Big Mac","biggu makku","ビッグマック"]},
          {"line":1,"name":"商品名","aliases":["Item"]},
          {"line":0,"name":"マクドナルド","aliases":["McDonald's"]},
          {"line":3,"name":"Double Cheeseburger","aliases":[]},
          {"line":4,"name":"てりやきマックバーガー","aliases":["Teriyaki McBurger","a","\(String(repeating: "x", count: 90))"]},
          {"line":2,"name":"ビッグマック","aliases":["dup"]},
          {"line":99,"name":"Ghost","aliases":[]}
        ]}
        ```
        """
        let index = NutritionDocumentLookup.parseIndexReply(reply, pageText: page)
        XCTAssertEqual(index.map(\.line), [2, 4], "header, title, translated name, duplicate and ghost lines all refused")
        XCTAssertEqual(index.first?.aliases, ["Big Mac", "biggu makku"], "the printed name is not repeated as an alias")
        XCTAssertEqual(index.last?.aliases, ["Teriyaki McBurger"])
        XCTAssertTrue(NutritionDocumentLookup.parseIndexReply("not json", pageText: page).isEmpty)
    }

    func testNumberedLinesMatchTheLinesTheIndexPointsAt() {
        let numbered = NutritionDocumentLookup.numberedLines(page).components(separatedBy: "\n")
        XCTAssertEqual(numbered[2], "L2\tビッグマック\t525\t26.0\t28.3\t41.8\t2.6")
        XCTAssertEqual(NutritionDocumentLookup.line(2, inPage: page), "ビッグマック\t525\t26.0\t28.3\t41.8\t2.6")
    }

    // MARK: - The action

    func testLogDocumentActionParsesAndRefusesMissingFigures() throws {
        let ok = """
        Logged. {"noop_food_action": {"actions": [{"action": "log_document", "row": "da1b2c3d4p3l2", \
        "name": "Big Mac", "servingLabel": "1 burger", "kcal": 525, "protein": 26.0, "carbs": 41.8, "fat": 28.3, \
        "fiber": null, "portion": 1}]}}
        """
        guard case .success(let list) = FoodActionParse.actions(fromReply: ok),
              case .documentLog(let key, let name, let serving, let kcal, let p, let c, let f, let fiber, let portion) = list.first?.action
        else { return XCTFail("expected a document log") }
        XCTAssertEqual(key, "da1b2c3d4p3l2")
        XCTAssertEqual(name, "Big Mac")
        XCTAssertEqual(serving, "1 burger")
        XCTAssertEqual([kcal, p, c, f, portion], [525, 26, 41.8, 28.3, 1])
        XCTAssertNil(fiber)

        let noFat = ok.replacingOccurrences(of: ", \"fat\": 28.3", with: "")
        guard case .failure(let failure) = FoodActionParse.actions(fromReply: noFat) else { return XCTFail() }
        XCTAssertEqual(failure, .inconsistent, "a missing fat is refused, not read as 0 g")
        let noRow = ok.replacingOccurrences(of: "\"row\": \"da1b2c3d4p3l2\", ", with: "")
        guard case .failure(let f2) = FoodActionParse.actions(fromReply: noRow) else { return XCTFail() }
        XCTAssertEqual(f2, .missingItemId)
    }
}
