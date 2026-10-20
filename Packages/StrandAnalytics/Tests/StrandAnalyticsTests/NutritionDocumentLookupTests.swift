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

    // A conveyor-belt sushi page: one row per plate, the piece count printed after the name.
    private let sushi = """
    商品名\tエネルギー(kcal)\tたんぱく質(g)\t脂質(g)\t炭水化物(g)
    ノルウェーサーモン 1貫\t52\t2.6\t1.9\t6.1
    炙りサーモン 1貫\t55\t2.7\t2.2\t6.0
    とろサーモン 1貫\t61\t2.4\t3.0\t6.0
    うなぎ 1貫\t68\t2.9\t2.8\t7.5
    えび天 2貫\t140\t4.1\t5.2\t18.9
    大とろ 1貫\t70\t2.5\t4.1\t6.0
    宮崎牛 2貫\t150\t5.0\t7.1\t15.2
    """

    private var sushiEntries: [NutritionDocumentLookup.Entry] {
        [("ノルウェーサーモン", ["Norwegian salmon"]), ("炙りサーモン", ["Seared salmon"]), ("とろサーモン", ["Fatty salmon"]),
         ("うなぎ", ["Eel", "unagi"]), ("えび天", ["Shrimp tempura"]), ("大とろ", ["Fatty tuna", "otoro"]),
         ("宮崎牛", ["Miyazaki beef"])].enumerated().map {
            .init(documentId: "kura", page: 1, line: $0.offset + 1, name: $0.element.0, aliases: $0.element.1)
        }
    }

    private func names(_ m: [NutritionDocumentLookup.Match]) -> [String] {
        m.compactMap { match in sushiEntries.first { $0.line == match.line }?.name }
    }

    /// A short word finds every row it is part of — "サーモン" is a request to pick among the salmon plates.
    func testAShortJapaneseWordFindsEveryRowItIsPartOf() {
        let m = NutritionDocumentLookup.match(query: "check for サーモン", entries: sushiEntries)
        XCTAssertEqual(Set(names(m)), ["ノルウェーサーモン", "炙りサーモン", "とろサーモン"])
    }

    /// Katakana and hiragana are one spelling, and a near transliteration still lands on the right row.
    func testKanaAndNearSpellingsMatch() {
        XCTAssertEqual(names(NutritionDocumentLookup.match(query: "ウナギ", entries: sushiEntries)), ["うなぎ"])
        XCTAssertEqual(names(NutritionDocumentLookup.match(query: "ノールウェイサーモン", entries: sushiEntries)),
                       ["ノルウェーサーモン"], "a typo finds its row, not the other salmon plates")
        XCTAssertEqual(NutritionDocumentLookup.searchFold("ノルウェーサーモン"), "のるうぇさもん")
        XCTAssertEqual(NutritionDocumentLookup.similarity("炙りさもん", "のるうぇいさもん"), 4.0 / 11.0, accuracy: 1e-9)
    }

    /// The meal as one user typed it, from an exported conversation where nothing was found: every item
    /// whose name is recognisable now finds its row, with or without an index. 天ぷら for えび天 is left to
    /// Coach's own search, which can guess the printed name.
    func testAMultiItemMessageFindsEachItem() {
        let said = "finished eating\n\nhad 8 ノールウェイサーモン\n1 ウナギ\n1 天ぷら2貫\n2大トロマグロ\n1宮崎牛"
        let indexed = NutritionDocumentLookup.match(query: said, entries: sushiEntries)
        XCTAssertEqual(Set(names(indexed)), ["ノルウェーサーモン", "うなぎ", "大とろ", "宮崎牛"])
        let raw = NutritionDocumentLookup.match(query: said, entries: [], unindexedPages: [("kura", 1, sushi)])
        XCTAssertEqual(Set(raw.map(\.line)), [1, 4, 6, 7])
    }

    /// A term Coach chose is the food alone, so an English word inside a longer alias is a match there,
    /// and only there.
    func testSearchTermsMatchWordsInsideLongerNames() {
        let searched = NutritionDocumentLookup.match(query: "salmon", entries: sushiEntries, search: true)
        XCTAssertEqual(Set(names(searched)), ["ノルウェーサーモン", "炙りサーモン", "とろサーモン"])
        XCTAssertTrue(NutritionDocumentLookup.match(query: "salmon", entries: sushiEntries).isEmpty)
        XCTAssertEqual(NutritionDocumentLookup.match(query: "teriyaki", entries: entries, search: true).map(\.line), [4])
    }

    func testFillerWordsAloneMatchNothing() {
        XCTAssertTrue(NutritionDocumentLookup.match(query: "今日食べた", entries: sushiEntries).isEmpty)
        XCTAssertTrue(NutritionDocumentLookup.match(query: "do it then", entries: sushiEntries,
                                                    unindexedPages: [("kura", 1, sushi)]).isEmpty)
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

    func testSearchDocumentTermsAreReadAndCapped() {
        let reply = """
        {"noop_food_action": {"actions": [{"action": "search_document", "queries": ["サーモン一貫", "サーモン", " サーモン ", "x", 7]}, \
        {"action": "search_document", "query": "えび天"}]}}
        """
        XCTAssertEqual(FoodActionParse.documentSearchQueries(fromReply: reply), ["サーモン一貫", "サーモン", "えび天"])
        XCTAssertTrue(FoodActionParse.documentSearchQueries(fromReply: "Salmon is popular.").isEmpty)
        let many = (0..<20).map { "\"q\($0)\"" }.joined(separator: ",")
        let capped = "{\"noop_food_action\": {\"action\": \"search_document\", \"queries\": [\(many)]}}"
        XCTAssertEqual(FoodActionParse.documentSearchQueries(fromReply: capped).count, FoodActionParse.maxSearchQueries)
        guard case .failure = FoodActionParse.actions(fromReply: reply) else {
            return XCTFail("a search proposes nothing to log")
        }
    }

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
