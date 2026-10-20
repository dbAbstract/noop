import Foundation
import StrandAnalytics

/// The coach guides shipped in the app bundle (`Strand/Resources/CoachGuide/*.md`), read once.
///
/// FORK-LOCAL (Apple). The format and the matching are `CoachGuide`'s; this only finds the files. Bundle
/// resources are flattened, so every markdown file in the bundle is tried and only those with a guide header
/// are kept. Listed in topic order so the index Coach sees is stable from build to build.
enum CoachGuideLibrary {
    static let guides: [CoachGuide] = load(from: .main)

    static func load(from bundle: Bundle) -> [CoachGuide] {
        (bundle.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? [])
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .compactMap(CoachGuide.parse)
            .sorted { $0.topic < $1.topic }
    }

    static func guide(_ topic: String) -> CoachGuide? {
        guides.first { $0.topic == topic.lowercased() }
    }

    /// The protocol and topic index appended to the interactive system prompt. Static text, so it does not
    /// vary between turns, and it carries no user data, so it is sent with or without data consent.
    static var promptSection: String {
        guard !guides.isEmpty else { return "" }
        return """
        HOW NOOP WORKS. NOOP ships guides explaining how each of its numbers is computed and what it can and \
        cannot tell. When the user asks how or why a number is what it is, what a metric means, or why the app \
        did something, answer from the guide. If the topic's text is not already in HOW NOOP WORKS in the \
        context, reply with ONLY {"\(FoodActionParse.sentinel)": {"action": "read_guide", "topics": ["topic"]}} \
        (up to \(FoodActionParse.maxGuideTopics) topics) and no prose; the app sends the text back before the \
        user sees anything. Explain in plain words using the user's own numbers. Never invent a formula, \
        constant or behaviour the guide does not state; if the guide does not cover the question, say so.
        GUIDE TOPICS:
        """ + "\n" + guides.map(\.indexLine).joined(separator: "\n")
    }

    /// The guides a message asks about, for the context, or "" when it asks about none.
    static func contextBlock(for message: String) -> String {
        guard CoachGuide.asksForExplanation(message) else { return "" }
        return block(CoachGuide.matching(message, in: guides))
    }

    /// Guides as the context and the `read_guide` reply list them.
    static func block(_ list: [CoachGuide]) -> String {
        guard !list.isEmpty else { return "" }
        return "HOW NOOP WORKS (the app's own guide; describes the method, the user's numbers are elsewhere):\n\n"
            + list.map(\.contextText).joined(separator: "\n\n")
    }
}
