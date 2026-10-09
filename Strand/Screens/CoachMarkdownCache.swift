import Foundation
import MarkdownUI

/// Retain parsed replies across lazy-row recreation and tab transitions, within a bounded cache.
final class CoachMarkdownCache {
    static let shared = CoachMarkdownCache()
    private let entries = NSCache<NSString, Entry>()

    final class Entry {
        let text: String
        let content: MarkdownContent
        init(_ text: String) {
            self.text = text
            content = MarkdownContent(text)
        }
    }

    init() {
        entries.countLimit = 48
        entries.totalCostLimit = 2 * 1_024 * 1_024
    }

    func entry(for text: String, messageId: UUID) -> Entry {
        let key = messageId.uuidString as NSString
        if let cached = entries.object(forKey: key), cached.text == text { return cached }
        let parsed = Entry(text)
        entries.setObject(parsed, forKey: key, cost: text.utf8.count)
        return parsed
    }

    func content(for text: String, messageId: UUID) -> MarkdownContent {
        entry(for: text, messageId: messageId).content
    }
}
