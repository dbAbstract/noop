import CoreGraphics
import Foundation

/// One row of the UIKit Coach transcript: a turn, or the "Coach is thinking…" line under the newest one.
enum CoachTranscriptItem: Hashable {
    case message(UUID)
    case typing
}

/// FORK-LOCAL. The decisions the UIKit Coach transcript (`CoachTranscriptCollection`) makes, kept free of UIKit so
/// `StrandTests` covers them on macOS: which rows to show in what order, which existing rows must be redrawn, and
/// where "the end" of the scroll is.
enum CoachTranscriptPlan {

    struct Update: Equatable {
        /// Every row, in order: the turns, then the typing line while a reply is on its way.
        let items: [CoachTranscriptItem]
        /// Rows already on screen whose content changed and must be reconfigured. New rows are not listed;
        /// they are inserted.
        let changed: Set<CoachTranscriptItem>
    }

    /// The rows for `rows`, and which of the rows drawn from `previous` need redrawing.
    ///
    /// A turn whose id repeats keeps its first occurrence only: a diffable snapshot traps on a duplicate id,
    /// and the SwiftUI transcript this replaces tolerated one.
    static func update(previous: [UUID: CoachTranscriptRow.Model], rows: [CoachTranscriptRow.Model],
                       typing: Bool) -> Update {
        var seen = Set<UUID>()
        var items: [CoachTranscriptItem] = []
        var changed = Set<CoachTranscriptItem>()
        for row in rows where seen.insert(row.message.id).inserted {
            let item = CoachTranscriptItem.message(row.message.id)
            items.append(item)
            if let old = previous[row.message.id], old != row { changed.insert(item) }
        }
        if typing { items.append(.typing) }
        return Update(items: items, changed: changed)
    }

    /// The row models by id, first occurrence winning, as `update(previous:…)` reads them back next time.
    static func byId(_ rows: [CoachTranscriptRow.Model]) -> [UUID: CoachTranscriptRow.Model] {
        Dictionary(rows.map { ($0.message.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether the newest content is within `tolerance` points of the bottom of the viewport. 120, the
    /// SwiftUI transcript's jump-button threshold, decides the ↓ button; a tighter one decides whether new
    /// content keeps the transcript pinned to the end.
    static func isAtEnd(offsetY: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat, bottomInset: CGFloat,
                        tolerance: CGFloat = 120) -> Bool {
        offsetY + viewportHeight >= contentHeight + bottomInset - tolerance
    }

    /// The content offset that shows the end of the transcript, or its top when it is shorter than the viewport.
    static func endOffset(contentHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat,
                          bottomInset: CGFloat) -> CGFloat {
        max(-topInset, contentHeight + bottomInset - viewportHeight)
    }
}
