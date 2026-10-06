import XCTest
@testable import Strand
import StrandAnalytics

/// The two decisions behind mirror mode and the coach dump that are worth pinning: which snapshot to
/// restore, and that a dump carries the proposals rather than only the prose.
final class DebugMirrorAndDumpTests: XCTestCase {

    /// Built by the REAL generator rather than hand-written. My first version invented the stamp format
    /// (`2026-10-03-093000` instead of `20261003-093000`), so `latestSnapshot` rejected every name and two
    /// of these tests passed by both sides being nil — green for the wrong reason.
    private func snapshot(_ epochMs: Int) -> String { BackupSync.snapshotName(epochMs) }

    private let oct1 = 1_759_305_600_000   // 2026-10-01 08:00 UTC
    private let oct2 = 1_759_399_200_000
    private let oct3 = 1_759_487_400_000
    private let oct4 = 1_759_562_100_000

    // MARK: - Which snapshot to restore

    /// Guards the fixture itself. Without this, a name the parser rejects makes every expectation nil and
    /// the suite goes green while testing nothing — which is exactly what happened first time.
    func testTheFixtureProducesNamesTheParserAccepts() {
        XCTAssertTrue(BackupSync.isSnapshot(snapshot(oct3)), "fixture is not a real snapshot name")
        XCTAssertLessThan(BackupSync.snapshotTimeMs(snapshot(oct1)) ?? 0,
                          BackupSync.snapshotTimeMs(snapshot(oct3)) ?? 0)
    }

    /// Nothing restored yet: take the newest there is.
    func testWithNoMarkerTheNewestIsChosen() {
        let names = [snapshot(oct1), snapshot(oct3), snapshot(oct2)]
        XCTAssertEqual(DebugMirror.snapshotToRestore(available: names, lastRestored: nil),
                       snapshot(oct3))
    }

    /// Already on the newest: nothing to do. This is the answer on almost every launch, and restoring
    /// anyway would replace the database for no reason.
    func testTheSameSnapshotIsNotRestoredTwice() {
        let names = [snapshot(oct3)]
        XCTAssertNil(DebugMirror.snapshotToRestore(available: names, lastRestored: snapshot(oct3)))
    }

    func testANewerSnapshotIsPickedUp() {
        let names = [snapshot(oct3), snapshot(oct4)]
        XCTAssertEqual(DebugMirror.snapshotToRestore(available: names, lastRestored: snapshot(oct3)),
                       snapshot(oct4))
    }

    /// THE ONE THAT MATTERS. If the folder has gone backwards — a snapshot deleted, a different folder
    /// picked — restoring an OLDER state over a newer one silently loses whatever came after it. Refused.
    func testAnOlderSnapshotIsRefusedRatherThanTreatedAsAnUpdate() {
        let names = [snapshot(oct1)]
        XCTAssertNil(DebugMirror.snapshotToRestore(available: names, lastRestored: snapshot(oct3)),
                     "going backwards would lose the data written since")
    }

    func testAnEmptyFolderRestoresNothing() {
        XCTAssertNil(DebugMirror.snapshotToRestore(available: [], lastRestored: nil))
        XCTAssertNil(DebugMirror.snapshotToRestore(available: [], lastRestored: snapshot(oct3)))
    }

    /// Files that are not snapshots must not be offered to the restore path at all.
    func testNonSnapshotFilesAreIgnored() {
        XCTAssertNil(DebugMirror.snapshotToRestore(available: ["notes.txt", ".DS_Store"],
                                                   lastRestored: nil))
    }

    /// Mirror mode cannot be on in a release build, so the strap can never be silenced by a stray
    /// preference — including one arriving through a restored `.noopbak`, which is how it could leak.
    func testReleaseBuildsCannotMirror() {
        #if NOOP_DEV_BUILD
        XCTAssertTrue(DebugMirror.isAvailable)
        #else
        XCTAssertFalse(DebugMirror.isAvailable)
        XCTAssertFalse(DebugMirror.isEnabled)
        XCTAssertFalse(DebugMirror.suppressesStrapWork)
        #endif
    }

    // MARK: - Publish cadence

    /// Default behaviour is UNCHANGED: daily, the cadence `catchUpIfDue` had before the option existed.
    /// Deliberately not the 3-day `staleThresholdMs`, which is the threshold for WARNING that a backup is
    /// old rather than for taking one — conflating them would have quietly tripled the interval.
    func testTheDefaultCadenceIsStillDaily() {
        FolderBackup.publishFrequently = false
        XCTAssertEqual(FolderBackup.activeThresholdMs, 24 * 60 * 60 * 1000)
        XCTAssertNotEqual(FolderBackup.activeThresholdMs, BackupSync.staleThresholdMs)
    }

    /// The mirror's whole problem: it can only be as fresh as the newest snapshot, so a daily cadence
    /// leaves it a day behind the work being reviewed.
    func testPublishingFrequentlyShortensTheIntervalToAnHour() {
        FolderBackup.publishFrequently = true
        XCTAssertEqual(FolderBackup.activeThresholdMs, BackupSync.frequentThresholdMs)
        XCTAssertEqual(FolderBackup.activeThresholdMs, 60 * 60 * 1000)
        FolderBackup.publishFrequently = false
    }

    // MARK: - The coach dump

    private func message(_ role: ChatMessage.Role, _ text: String,
                         proposals: [FoodProposal] = []) -> ChatMessage {
        ChatMessage(role: role, text: text, proposals: proposals)
    }

    private func dump(_ messages: [ChatMessage], error: String? = nil,
                      sending: Bool = false) -> String {
        CoachDump.json(messages: messages, provider: "openai", model: "gpt-x",
                       dataConsent: true, onDeviceSignals: false,
                       hasCustomPrompt: false, customPromptMissesFoodProtocol: false,
                       errorText: error, isSending: sending) ?? ""
    }

    /// THE OMISSION THAT MADE A REAL DUMP HARD TO READ. It showed five identical user turns and an empty
    /// assistant turn with no sign that anything had FAILED — a transcript of failures that does not say
    /// they failed reads as the app ignoring the user.
    func testTheDumpCarriesTheFailureAndTheReason() {
        var failed = message(.user, "log my breakfast")
        failed.failure = "The request timed out."
        let json = dump([failed], error: "The request timed out.", sending: true)
        XCTAssertTrue(json.contains("timed out"))
        XCTAssertTrue(json.contains("\"failure\""))
        XCTAssertTrue(json.contains("\"errorText\""))
        XCTAssertTrue(json.contains("\"failedMessageCount\""))
        // Explains a trailing empty assistant turn rather than leaving it to look like its own bug.
        XCTAssertTrue(json.contains("\"isSending\" : true"))
    }

    func testAHealthyConversationReportsNoFailures() {
        let json = dump([message(.user, "hello"), message(.assistant, "hi")])
        XCTAssertTrue(json.contains("\"failedMessageCount\" : 0"))
        XCTAssertFalse(json.contains("\"failure\""))
    }

    /// Bumped whenever the shape changes, or a reader guesses from the keys present and gets it wrong.
    func testTheFormatVersionWasBumpedForTheNewFields() {
        XCTAssertEqual(CoachDump.formatVersion, 2)
    }

    func testTheTranscriptIsCarried() {
        let json = dump([message(.user, "just had an Oikos"),
                         message(.assistant, "Which one?")])
        XCTAssertTrue(json.contains("just had an Oikos"))
        XCTAssertTrue(json.contains("Which one?"))
        XCTAssertTrue(json.contains("\"formatVersion\""))
    }

    /// THE POINT OF THE FILE. Proposals are not persisted, so a dump is the only place the full picture
    /// exists — and a screenshot of the prose loses exactly this.
    func testProposalsAreCarriedWithTheirStateAndDay() {
        let proposal = FoodProposal(
            kind: .create(name: "Oikos 180 g tub", servingLabel: "1 tub",
                          macros: MacroTotals(kcal: 150, protein: 15, carbs: 20, fat: 0, fiber: 0),
                          portion: 1),
            state: .applied,
            dayKey: "2026-10-04", dayLabel: "Yesterday")
        let json = dump([message(.assistant, "Got it.", proposals: [proposal])])

        XCTAssertTrue(json.contains("Oikos 180 g tub"))
        XCTAssertTrue(json.contains("\"create\""))
        // Whether the user ACTED on it — the difference between a model proposing something odd and
        // something odd being logged.
        XCTAssertTrue(json.contains("applied"))
        XCTAssertTrue(json.contains("2026-10-04"))
        XCTAssertTrue(json.contains("logsMacros"))
    }

    /// An unresolved proposal carries the handle the model quoted, which says whether it invented an id or
    /// merely hit an ambiguous prefix. Without it the case is undiagnosable.
    func testAnUnresolvedProposalCarriesTheQuotedHandle() {
        let proposal = FoodProposal(kind: .unresolved(handle: "deadbeef"),
                                    dayKey: "2026-10-05", dayLabel: "Today")
        XCTAssertTrue(dump([message(.assistant, "Hmm.", proposals: [proposal])]).contains("deadbeef"))
    }

    /// An edit must carry BOTH figures. With only the proposed one there is nothing to judge it against.
    func testAnEditCarriesBeforeAndAfter() {
        let item = FoodItem(name: "Yogurt", servingLabel: "1 pot",
                            macros: MacroTotals(kcal: 95, protein: 10, carbs: 5, fat: 3, fiber: 0))
        let proposal = FoodProposal(
            kind: .edit(item: item, name: nil,
                        macros: MacroTotals(kcal: 150, protein: 15, carbs: 20, fat: 0, fiber: 0)),
            dayKey: "2026-10-05", dayLabel: "Today")
        let json = dump([message(.assistant, "Correcting that.", proposals: [proposal])])
        XCTAssertTrue(json.contains("macrosBefore"))
        XCTAssertTrue(json.contains("macrosProposed"))
    }

    /// No credential, ever. A key would make the file unshareable, which is the opposite of its purpose.
    func testTheDumpCarriesNoCredential() {
        let json = dump([message(.user, "hello")])
        for forbidden in ["apiKey", "api_key", "Authorization", "Bearer", "baseURL"] {
            XCTAssertFalse(json.contains(forbidden), "\(forbidden) must never reach the dump")
        }
        // The provider and model DO belong — a reply is unexplainable without knowing what produced it.
        XCTAssertTrue(json.contains("openai"))
        XCTAssertTrue(json.contains("gpt-x"))
    }

    /// A non-finite macro would make `JSONSerialization` throw and lose the whole file — at exactly the
    /// moment it is most wanted, since such a figure is itself the bug being reported.
    func testANonFiniteMacroDoesNotLoseTheWholeDump() {
        let proposal = FoodProposal(
            kind: .create(name: "Broken", servingLabel: "1",
                          macros: MacroTotals(kcal: .nan, protein: 15, carbs: 20, fat: 0, fiber: 0),
                          portion: 1),
            dayKey: "2026-10-05", dayLabel: "Today")
        let json = dump([message(.assistant, "Odd.", proposals: [proposal])])
        XCTAssertFalse(json.isEmpty, "the dump must survive a bad figure")
        XCTAssertTrue(json.contains("Broken"))
    }

    func testAnEmptyConversationStillProducesValidJSON() {
        let json = dump([])
        XCTAssertTrue(json.contains("\"messageCount\""))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    /// The filename is second-resolution so two dumps in one minute do not collide.
    func testFilenamesAreDistinctWithinAMinute() {
        let a = CoachDump.filename(Date(timeIntervalSince1970: 1_760_000_000))
        let b = CoachDump.filename(Date(timeIntervalSince1970: 1_760_000_030))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix(".json"))
    }
}
