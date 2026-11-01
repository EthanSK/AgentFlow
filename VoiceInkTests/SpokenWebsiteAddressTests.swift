// Guards spoken URL conversion and its boundary with prose and user dictionary rules.
import Foundation
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

struct SpokenWebsiteAddressTests {
    @Test func ordinarySpeechDoesNotScanDictionaryProtection() {
        var reads = 0
        for text in ["Just an ordinary sentence.", "This dotted line is visible."] {
            #expect(SpokenWebsiteAddressFormatter.format(text, preserving: { reads += 1; return [] }) == text)
        }
        #expect(reads == 0)
        #expect(SpokenWebsiteAddressFormatter.format("speedtest dot net", preserving: { reads += 1; return [] }) == "speedtest.net")
        #expect(reads == 1)
    }

    @Test func spokenWebsiteAddressesBecomeDomainsInsideSentences() {
        #expect(SpokenWebsiteAddressFormatter.format("Please open speedtest dot net.")
            == "Please open speedtest.net.")
        #expect(SpokenWebsiteAddressFormatter.format("The website is example dot com, then visit docs dot python dot org.")
            == "The website is example.com, then visit docs.python.org.")
        #expect(SpokenWebsiteAddressFormatter.format("SPEEDTEST DOT NET") == "speedtest.net")
    }

    @Test func spokenSubdomainsDashesAndSimplePathsStayTogether() {
        #expect(SpokenWebsiteAddressFormatter.format("www dot example dot co dot uk") == "www.example.co.uk")
        #expect(SpokenWebsiteAddressFormatter.format("my dash site dot com slash MyProfile slash index")
            == "my-site.com/MyProfile/index")
        #expect(SpokenWebsiteAddressFormatter.format("docs.python dot org slash reference")
            == "docs.python.org/reference")
        #expect(SpokenWebsiteAddressFormatter.format("https://example.com slash MyProfile")
            == "https://example.com/MyProfile")
    }

    @Test func dotProductDotComProseAndDotNetFrameworkRemainLiteral() {
        for text in [
            "Calculate the dot product.", "A dot product is not a website.",
            "The dot com boom was different.", "I use dot net and the dot net SDK.",
            "Microsoft dot net framework and ASP dot net.", "Put a dot on it.",
            "Just say dot com.", "example dot notarealdomainending"
        ] {
            #expect(SpokenWebsiteAddressFormatter.format(text) == text)
        }
    }

    @Test func existingURLsCodeAndParagraphBoundariesStayLiteral() {
        for text in [
            "Visit https://Example.COM/MyPath?q=a%20b#Top, then speedtest.net.",
            "Run `echo dot com` and keep this command.",
            "```\nexample dot com\n```", "example\ndot com", "example dot\ncom",
            "name@example.com", "bücher dot de"
        ] {
            #expect(SpokenWebsiteAddressFormatter.format(text) == text)
        }
    }

    @Test func spokenAddressFormattingIsIdempotentAndKeepsOtherWords() {
        let input = "Before 🌊 speedtest dot net; after example dot com!"
        let expected = "Before 🌊 speedtest.net; after example.com!"
        let once = SpokenWebsiteAddressFormatter.format(input)
        #expect(once == expected)
        #expect(SpokenWebsiteAddressFormatter.format(once) == expected)
    }

    @Test @MainActor func addressFormattingRunsWithoutDictionaryAndCustomReplacementWins() throws {
        let schema = Schema([WordReplacement.self])
        let container = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let input = "Please open speedtest dot net."
        #expect(WordReplacementService.shared.applyReplacements(to: input, using: context)
            == "Please open speedtest.net.")
        context.insert(WordReplacement(originalText: "speedtest.net", replacementText: "my chosen website"))
        try context.save()
        #expect(WordReplacementService.shared.applyReplacements(to: input, using: context)
            == "Please open my chosen website.")
        context.insert(WordReplacement(originalText: "speedtest dot net", replacementText: "Preferred dot net wording"))
        try context.save()
        #expect(WordReplacementService.shared.applyReplacements(to: input, using: context)
            == "Please open Preferred dot net wording.")
    }

    @Test @MainActor func URLProtectionSharesWordBoundariesAndDoesNotRepeatDictionaryPasses() throws {
        let schema = Schema([WordReplacement.self])
        let container = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.insert(WordReplacement(originalText: "speed", replacementText: "velocity"))
        context.insert(WordReplacement(originalText: "codeword", replacementText: "example dot com"))
        context.insert(WordReplacement(originalText: "old", replacementText: "newer"))
        context.insert(WordReplacement(originalText: "newer", replacementText: "latest"))
        try context.save()
        #expect(WordReplacementService.shared.applyReplacements(to: "speedtest dot net and speed", using: context)
            == "speedtest.net and velocity")
        #expect(WordReplacementService.shared.applyReplacements(to: "codeword", using: context)
            == "example dot com")
        // Longest-first existing ordering replaces "old" last; a second pass
        // would incorrectly change its newly inserted "newer" to "latest".
        #expect(WordReplacementService.shared.applyReplacements(to: "old", using: context) == "newer")
    }
}
