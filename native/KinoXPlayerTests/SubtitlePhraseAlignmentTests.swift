import Foundation
import XCTest
@testable import KinoXPlayer

final class SubtitlePhraseAlignmentTests: XCTestCase {
    func testFragmenterSplitsSentencesAndMapsCorrectedVideoTime() throws {
        let fragments = SubtitlePhraseFragmenter().fragments(
            from: [SubtitleCue(
                start: 10,
                end: 20,
                text: "First line. Second line!"
            )],
            timingTransform: SubtitleTimingTransform(offset: 2, rate: 2),
            manualOffset: 1,
            languageCode: "en"
        )

        XCTAssertEqual(fragments.map(\.text), ["First line.", "Second line!"])
        XCTAssertEqual(try XCTUnwrap(fragments.first).videoStart, 5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fragments.last).videoEnd, 10, accuracy: 0.001)
        XCTAssertTrue(fragments.allSatisfy(\.endsSentence))
    }

    func testMixedCueKeepsNonDialogueAndNamedSpeakersInSeparateFragments() async throws {
        let announcement = "[Station announcement]"
        let music = "♪ MUSIC ♪"
        let translation = "Hallo zusammen."
        let namedSpeaker = "ANNA: Komm jetzt."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Hello there.": [1, 0, 0],
            announcement: [0, 1, 0],
            music: [0, 0, 1],
            translation: [1, 0, 0],
            namedSpeaker: [0, 1, 1],
        ])

        let secondaryFragments = SubtitlePhraseFragmenter().fragments(
            from: [SubtitleCue(
                start: 0,
                end: 6,
                text: "\(announcement)\n\(music)\n\(translation)\n\(namedSpeaker)"
            )],
            languageCode: "de"
        )

        XCTAssertEqual(
            secondaryFragments.map(\.text),
            [announcement, music, translation, namedSpeaker]
        )
        XCTAssertEqual(secondaryFragments.map(\.isNonDialogue), [true, true, false, false])
        XCTAssertEqual(secondaryFragments.map(\.startsNewSpeaker), [false, false, false, true])

        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 6, text: "Hello there.")],
            secondaryCues: [SubtitleCue(
                start: 0,
                end: 6,
                text: "\(announcement)\n\(music)\n\(translation)\n\(namedSpeaker)"
            )],
            primaryLanguageCode: "en",
            secondaryLanguageCode: "de"
        )

        let pair = try XCTUnwrap(result.alignedPhrases.first)
        XCTAssertEqual(pair.primaryText, "Hello there.")
        XCTAssertEqual(pair.secondaryText, translation)
        XCTAssertFalse(pair.secondaryText.contains(announcement))
        XCTAssertFalse(pair.secondaryText.contains(music))
        XCTAssertTrue(result.unmatchedSecondaryFragments.contains { $0.text == announcement })
        XCTAssertTrue(result.unmatchedSecondaryFragments.contains { $0.text == music })
    }

    func testAlignsOnePrimaryFragmentToTwoSecondaryFragments() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Open the door now.": [1, 1, 0],
            "Öffne die Tür": [1, 0, 0],
            "jetzt.": [0, 1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 4, text: "Open the door now.")],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Öffne die Tür"),
                SubtitleCue(start: 2, end: 4, text: "jetzt.")
            ],
            primaryLanguageCode: "en",
            secondaryLanguageCode: "de"
        )

        let pair = try XCTUnwrap(result.alignedPhrases.first)
        XCTAssertEqual(result.alignedPhrases.count, 1)
        XCTAssertEqual(pair.primaryFragmentIDs.count, 1)
        XCTAssertEqual(pair.secondaryFragmentIDs.count, 2)
        XCTAssertEqual(pair.secondaryText, "Öffne die Tür\njetzt.")
    }

    func testAlignsTwoPrimaryFragmentsToOneSecondaryFragment() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Open the door": [1, 0, 0],
            "right now.": [0, 1, 0],
            "Öffne jetzt die Tür.": [0.5, 0.866, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Open the door"),
                SubtitleCue(start: 2, end: 4, text: "right now.")
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 4, text: "Öffne jetzt die Tür.")
            ],
            primaryLanguageCode: "en",
            secondaryLanguageCode: "de"
        )

        let pair = try XCTUnwrap(result.alignedPhrases.first)
        XCTAssertEqual(result.alignedPhrases.count, 1)
        XCTAssertEqual(pair.primaryFragmentIDs.count, 2)
        XCTAssertEqual(pair.secondaryFragmentIDs.count, 1)
        XCTAssertEqual(pair.primaryText, "Open the door\nright now.")
    }

    func testAlignsTwoPrimaryFragmentsToTwoSecondaryFragmentsAsOnePhrase() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "First half,": [1, 0, 0],
            "second half.": [0, 1, 0],
            "Erste Hälfte,": [1, 0, 0],
            "zweite Hälfte.": [0, 1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: "First half,"),
                SubtitleCue(start: 2, end: 4, text: "second half.")
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Erste Hälfte,"),
                SubtitleCue(start: 2, end: 4, text: "zweite Hälfte.")
            ]
        )

        let pair = try XCTUnwrap(result.alignedPhrases.first)
        XCTAssertEqual(result.alignedPhrases.count, 1)
        XCTAssertEqual(pair.primaryFragmentIDs.count, 2)
        XCTAssertEqual(pair.secondaryFragmentIDs.count, 2)
    }

    func testSkipsAnnouncementInsertedBetweenTwoTranslatedSentences() async throws {
        let primaryA = "The red door opens."
        let primaryB = "The blue gate closes."
        let secondaryA = "Die rote Tür öffnet sich."
        let announcement = "Attention, platform changed."
        let secondaryB = "Das blaue Tor schließt sich."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primaryA: [1, 0, 0],
            primaryB: [0, 1, 0],
            secondaryA: [1, 0, 0],
            announcement: [0, 0, 1],
            secondaryB: [0, 1, 0]
        ])

        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(
                start: 0,
                end: 9,
                text: "\(primaryA) \(primaryB)"
            )],
            secondaryCues: [
                SubtitleCue(start: 0, end: 3, text: secondaryA),
                SubtitleCue(start: 3, end: 6, text: announcement),
                SubtitleCue(start: 6, end: 9, text: secondaryB)
            ],
            primaryLanguageCode: "en",
            secondaryLanguageCode: "de"
        )

        XCTAssertEqual(result.alignedPhrases.count, 2)
        XCTAssertEqual(result.alignedPhrases.map(\.primaryText), [primaryA, primaryB])
        XCTAssertEqual(result.alignedPhrases.map(\.secondaryText), [secondaryA, secondaryB])
        XCTAssertEqual(result.unmatchedSecondaryFragments.map(\.text), [announcement])
        XCTAssertFalse(result.alignedPhrases.contains {
            $0.secondaryText.contains(announcement)
        })
    }

    func testDoesNotReorderTranslationsOrHideThemInsideAGroupedPair() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Primary A sentence.": [1, 0],
            "Primary B sentence.": [0, 1],
            "Secondary A sentence.": [1, 0],
            "Secondary B sentence.": [0, 1]
        ])

        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Primary A sentence."),
                SubtitleCue(start: 2, end: 4, text: "Primary B sentence.")
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Secondary B sentence."),
                SubtitleCue(start: 2, end: 4, text: "Secondary A sentence.")
            ]
        )

        XCTAssertLessThanOrEqual(result.alignedPhrases.count, 1)
        XCTAssertFalse(result.alignedPhrases.contains {
            $0.primaryFragmentIDs.count == 2 && $0.secondaryFragmentIDs.count == 2
        })
    }

    func testContextSafeDisplayUsesPairThenPrimaryThenSecondary() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Hello there.": [1, 0, 0],
            "Hallo zusammen.": [1, 0, 0],
            "Primary only.": [0, 1, 0],
            "Unrelated secondary.": [0, 0, 1]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Hello there."),
                SubtitleCue(start: 3, end: 5, text: "Primary only.")
            ],
            secondaryCues: [
                SubtitleCue(start: 0.2, end: 2.2, text: "Hallo zusammen."),
                SubtitleCue(start: 4, end: 6, text: "Unrelated secondary.")
            ]
        )

        XCTAssertEqual(result.displayFrame(at: 1), SubtitleDisplayFrame(
            primaryText: "Hello there.",
            secondaryText: "Hallo zusammen.",
            isAlignedPair: true,
            confidence: result.alignedPhrases.first?.confidence
        ))
        XCTAssertTrue(result.displayFrame(at: 2).isEmpty)
        XCTAssertEqual(result.displayFrame(at: 4.5).primaryText, "Primary only.")
        XCTAssertEqual(result.displayFrame(at: 4.5).secondaryText, "")
        XCTAssertEqual(result.displayFrame(at: 5.5).primaryText, "")
        XCTAssertEqual(result.displayFrame(at: 5.5).secondaryText, "Unrelated secondary.")
    }

    func testStandaloneSecondaryMillisecondTailIsNotDisplayed() {
        let primary = makeFragment(
            cue: 0,
            text: "Primary context.",
            start: 0,
            end: 1.99
        )
        let secondary = makeFragment(
            cue: 0,
            text: "Unrelated secondary context.",
            start: 0,
            end: 2
        )
        let alignment = SubtitlePhraseAlignment(
            primaryFragments: [primary],
            secondaryFragments: [secondary],
            alignedPhrases: [],
            modelVersion: "test"
        )

        XCTAssertEqual(alignment.displayFrame(at: 1).primaryText, primary.text)
        XCTAssertTrue(alignment.displayFrame(at: 1.995).isEmpty)
    }

    func testStandaloneSecondaryKeepsReadableUncoveredInterval() {
        let primary = makeFragment(
            cue: 0,
            text: "Primary context.",
            start: 0,
            end: 1
        )
        let secondary = makeFragment(
            cue: 0,
            text: "Secondary continues alone.",
            start: 0.5,
            end: 2
        )
        let alignment = SubtitlePhraseAlignment(
            primaryFragments: [primary],
            secondaryFragments: [secondary],
            alignedPhrases: [],
            modelVersion: "test"
        )

        XCTAssertEqual(alignment.displayFrame(at: 0.75).primaryText, primary.text)
        XCTAssertEqual(
            alignment.displayFrame(at: 1.5).secondaryText,
            secondary.text
        )
    }

    func testShortCompleteStandaloneSecondaryRemainsVisible() {
        let secondary = makeFragment(
            cue: 0,
            text: "Hm.",
            start: 1,
            end: 1.5
        )
        let alignment = SubtitlePhraseAlignment(
            primaryFragments: [],
            secondaryFragments: [secondary],
            alignedPhrases: [],
            modelVersion: "test"
        )

        XCTAssertEqual(
            alignment.displayFrame(at: 1.25).secondaryText,
            secondary.text
        )
    }

    func testOverlappingUnmatchedPrimarySuppressesAlignedSecondary() throws {
        let pairedPrimary = SubtitlePhraseFragment(
            id: SubtitleFragmentID(cueIndex: 0, fragmentIndex: 0),
            text: "Verified primary.",
            videoStart: 1,
            videoEnd: 4,
            endsSentence: true,
            startsNewSpeaker: false,
            isNonDialogue: false,
            characterWeight: 17
        )
        let pairedSecondary = SubtitlePhraseFragment(
            id: SubtitleFragmentID(cueIndex: 0, fragmentIndex: 0),
            text: "Verified secondary.",
            videoStart: 1,
            videoEnd: 4,
            endsSentence: true,
            startsNewSpeaker: false,
            isNonDialogue: false,
            characterWeight: 19
        )
        let overlappingPrimary = SubtitlePhraseFragment(
            id: SubtitleFragmentID(cueIndex: 1, fragmentIndex: 0),
            text: "Unmatched primary.",
            videoStart: 2,
            videoEnd: 3,
            endsSentence: true,
            startsNewSpeaker: false,
            isNonDialogue: false,
            characterWeight: 18
        )
        let pair = AlignedSubtitlePhrase(
            primaryFragmentIDs: [pairedPrimary.id],
            secondaryFragmentIDs: [pairedSecondary.id],
            primaryText: pairedPrimary.text,
            secondaryText: pairedSecondary.text,
            videoStart: 1,
            videoEnd: 4,
            secondaryVideoStart: 1,
            secondaryVideoEnd: 4,
            semanticScore: 0.95,
            timingScore: 1,
            boundaryScore: 1,
            structureScore: 1,
            confidence: 0.96
        )
        let alignment = SubtitlePhraseAlignment(
            primaryFragments: [pairedPrimary, overlappingPrimary],
            secondaryFragments: [pairedSecondary],
            alignedPhrases: [pair],
            modelVersion: "test-v1"
        )

        XCTAssertEqual(alignment.displayFrame(at: 2.5), SubtitleDisplayFrame(
            primaryText: overlappingPrimary.text,
            secondaryText: "",
            isAlignedPair: false,
            confidence: nil
        ))
    }

    func testRejectsIsolatedShortAndNonDialoguePairs() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Yes": [1, 0],
            "Ja": [1, 0],
            "[Music]": [0, 1],
            "[Musik]": [0, 1]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 1, text: "Yes"),
                SubtitleCue(start: 2, end: 4, text: "[Music]")
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 1, text: "Ja"),
                SubtitleCue(start: 2, end: 4, text: "[Musik]")
            ]
        )

        XCTAssertTrue(result.alignedPhrases.isEmpty)
        XCTAssertEqual(result.unmatchedPrimaryFragments.count, 2)
        XCTAssertEqual(result.unmatchedSecondaryFragments.count, 2)
    }

    func testKeepsShortPairWhenBothNeighborsConfirmSequence() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Long first sentence.": [1, 0, 0],
            "Langer erster Satz.": [1, 0, 0],
            "Yes": [0, 1, 0],
            "Ja": [0, 1, 0],
            "Long final sentence.": [0, 0, 1],
            "Langer letzter Satz.": [0, 0, 1]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Long first sentence."),
                SubtitleCue(start: 2, end: 3, text: "Yes"),
                SubtitleCue(start: 3, end: 5, text: "Long final sentence.")
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Langer erster Satz."),
                SubtitleCue(start: 2, end: 3, text: "Ja"),
                SubtitleCue(start: 3, end: 5, text: "Langer letzter Satz.")
            ]
        )

        XCTAssertEqual(result.alignedPhrases.count, 3)
        XCTAssertTrue(result.alignedPhrases.contains { $0.primaryText == "Yes" })
    }

    func testRejectsSemanticallyWeakShortPairEvenWhenNeighborsConfirmSequence() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Long first sentence.": [1, 0, 0],
            "Langer erster Satz.": [1, 0, 0],
            "Да": [0, 1, 0],
            "Und": [0, 0.83, 0.558],
            "Long final sentence.": [0, 0, 1],
            "Langer letzter Satz.": [0, 0, 1]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Long first sentence."),
                SubtitleCue(start: 2, end: 3, text: "Да"),
                SubtitleCue(start: 3, end: 5, text: "Long final sentence.")
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Langer erster Satz."),
                SubtitleCue(start: 2, end: 3, text: "Und"),
                SubtitleCue(start: 3, end: 5, text: "Langer letzter Satz.")
            ]
        )

        XCTAssertEqual(result.alignedPhrases.count, 2)
        XCTAssertFalse(result.alignedPhrases.contains { $0.primaryText == "Да" })
        XCTAssertEqual(result.unmatchedPrimaryFragments.map(\.text), ["Да"])
        XCTAssertEqual(result.unmatchedSecondaryFragments.map(\.text), ["Und"])
    }

    func testGroupedCandidateCannotHideAnUnrelatedTrailingFragment() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Primary first sentence.": [1, 0, 0, 0],
            "Secondary first sentence.": [1, 0, 0, 0],
            "Primary second sentence.": [0, 1, 0, 0],
            "Secondary second sentence.": [0, 1, 0, 0],
            "Untranslated primary sentence.": [0, 0, 1, 0],
            "Foreign announcement here.": [0, 0, 0, 1]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Primary first sentence."),
                SubtitleCue(start: 2, end: 4, text: "Primary second sentence."),
                SubtitleCue(start: 4, end: 6, text: "Untranslated primary sentence.")
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Secondary first sentence."),
                SubtitleCue(start: 2, end: 4, text: "Secondary second sentence."),
                SubtitleCue(start: 4, end: 6, text: "Foreign announcement here.")
            ]
        )

        XCTAssertEqual(result.alignedPhrases.count, 2)
        XCTAssertTrue(result.alignedPhrases.allSatisfy {
            $0.primaryFragmentIDs.count == 1 && $0.secondaryFragmentIDs.count == 1
        })
        XCTAssertEqual(
            result.unmatchedPrimaryFragments.map(\.text),
            ["Untranslated primary sentence."]
        )
        XCTAssertEqual(
            result.unmatchedSecondaryFragments.map(\.text),
            ["Foreign announcement here."]
        )
    }

    func testRejectedShortTransitionDoesNotBlockValidLongPair() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Да": [1, 0, 0],
            "Ja": [1, 0, 0],
            "Important long sentence.": [0, 1, 0],
            "Wichtiger langer Satz.": [0, 0.9, 0.435]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Да"),
                SubtitleCue(start: 0, end: 2, text: "Important long sentence.")
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Wichtiger langer Satz."),
                SubtitleCue(start: 0, end: 2, text: "Ja")
            ]
        )

        XCTAssertEqual(result.alignedPhrases.count, 1)
        XCTAssertEqual(result.alignedPhrases.first?.primaryText, "Important long sentence.")
        XCTAssertEqual(result.alignedPhrases.first?.secondaryText, "Wichtiger langer Satz.")
        XCTAssertEqual(result.unmatchedPrimaryFragments.map(\.text), ["Да"])
        XCTAssertEqual(result.unmatchedSecondaryFragments.map(\.text), ["Ja"])
    }

    func testLowercaseCrossCueContinuationMustStayWithItsUnfinishedPrefix() async throws {
        let primary = "I could hardly wait to get to work."
        let secondaryPrefix = "Ich konnte es kaum erwarten,"
        let secondaryContinuation = "zur Arbeit zu kommen."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary: [1, 0],
            secondaryPrefix: [0.6, 0.8],
            secondaryContinuation: [1, 0]
        ])

        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 4, text: primary)],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: secondaryPrefix),
                SubtitleCue(start: 2, end: 4, text: secondaryContinuation)
            ],
            primaryLanguageCode: "en",
            secondaryLanguageCode: "de"
        )

        let pair = try XCTUnwrap(result.alignedPhrases.first)
        XCTAssertEqual(result.alignedPhrases.count, 1)
        XCTAssertEqual(pair.secondaryFragmentIDs.count, 2)
        XCTAssertEqual(
            pair.secondaryText,
            "\(secondaryPrefix)\n\(secondaryContinuation)"
        )
    }

    func testMergedEdgeCannotAbsorbPhraseWithStrongerOutsideTranslation() async throws {
        let primaryA = "Then he introduced himself."
        let primaryB = "As if it happened by accident."
        let primaryC = "And now you are dating."
        let primaryOutside = "Well, is that really true?"
        let secondaryA = "Dann hat er sich vorgestellt."
        let secondaryBC = "Und jetzt seid ihr zusammen."
        let secondaryEdge = "Wirklich, ist das tatsächlich wahr?"
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primaryA: [1, 0, 0, 0],
            primaryB: [0, 1, 0, 0],
            primaryC: [0, 0, 1, 0],
            primaryOutside: [0, 0, 0, 1],
            secondaryA: [1, 0, 0, 0],
            secondaryBC: [0, 0.707, 0.707, 0],
            secondaryEdge: [0, 0, 0.55, 0.835]
        ])

        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: primaryA),
                SubtitleCue(start: 2, end: 4, text: primaryB),
                SubtitleCue(start: 4, end: 6, text: primaryC),
                SubtitleCue(start: 6.5, end: 8.5, text: primaryOutside)
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: secondaryA),
                SubtitleCue(start: 2, end: 4, text: secondaryBC),
                SubtitleCue(start: 4, end: 6, text: secondaryEdge)
            ]
        )

        XCTAssertFalse(result.alignedPhrases.contains { phrase in
            phrase.secondaryText.contains(secondaryEdge)
                && !phrase.primaryText.contains(primaryOutside)
        }, "Unexpected edge pairing: \(result.alignedPhrases)")
    }

    func testOverflowBeyondSixFragmentsRemainsVisibleButCannotBePaired() async throws {
        let primarySentences = [
            "Primary one sentence.",
            "Primary two sentence.",
            "Primary three sentence.",
            "Primary four sentence.",
            "Primary five sentence.",
            "Primary six sentence.",
            "Primary seven sentence."
        ]
        let secondarySentences = [
            "Secondary one sentence.",
            "Secondary two sentence.",
            "Secondary three sentence.",
            "Secondary four sentence.",
            "Secondary five sentence.",
            "Secondary six sentence.",
            "Secondary seven sentence."
        ]
        let primaryOverflow = primarySentences.suffix(2).joined(separator: " ")
        let secondaryOverflow = secondarySentences.suffix(2).joined(separator: " ")
        var vectors: [String: [Float]] = [:]
        for index in 0..<5 {
            var vector = Array(repeating: Float(0), count: 6)
            vector[index] = 1
            vectors[primarySentences[index]] = vector
            vectors[secondarySentences[index]] = vector
        }
        vectors[primaryOverflow] = [0, 0, 0, 0, 0, 1]
        vectors[secondaryOverflow] = [0, 0, 0, 0, 0, 1]

        let fragmenter = SubtitlePhraseFragmenter()
        let primaryFragments = fragmenter.fragments(
            from: [SubtitleCue(
                start: 0,
                end: 14,
                text: primarySentences.joined(separator: " ")
            )],
            languageCode: "en"
        )
        let secondaryFragments = fragmenter.fragments(
            from: [SubtitleCue(
                start: 0,
                end: 14,
                text: secondarySentences.joined(separator: " ")
            )],
            languageCode: "en"
        )

        XCTAssertEqual(primaryFragments.count, 6)
        XCTAssertEqual(secondaryFragments.count, 6)
        XCTAssertTrue(try XCTUnwrap(primaryFragments.last).isNonDialogue)
        XCTAssertTrue(try XCTUnwrap(secondaryFragments.last).isNonDialogue)

        let result = try await SubtitlePhraseAligner(
            embeddingProvider: FakePhraseEmbeddingProvider(vectors: vectors)
        ).align(primary: primaryFragments, secondary: secondaryFragments)
        let primaryOverflowID = try XCTUnwrap(primaryFragments.last).id
        let secondaryOverflowID = try XCTUnwrap(secondaryFragments.last).id

        XCTAssertFalse(result.alignedPhrases.contains {
            $0.primaryFragmentIDs.contains(primaryOverflowID)
                || $0.secondaryFragmentIDs.contains(secondaryOverflowID)
        })
        XCTAssertTrue(result.unmatchedPrimaryFragments.contains { $0.id == primaryOverflowID })
        XCTAssertTrue(result.unmatchedSecondaryFragments.contains { $0.id == secondaryOverflowID })
    }

    func testFragmenterRejoinsHonorificBeforeSurname() throws {
        let fragments = SubtitlePhraseFragmenter().fragments(
            from: [SubtitleCue(
                start: 0,
                end: 4,
                text: "Good morning, Mrs. Barish. Please sit down."
            )],
            languageCode: "en"
        )

        XCTAssertEqual(
            fragments.map(\.text),
            ["Good morning, Mrs. Barish.", "Please sit down."]
        )
    }

    func testEllipsisLowercaseContinuationCannotBePairedAlone() async throws {
        let primary = "You are kind and very beautiful."
        let prefix = "Du bist freundlich..."
        let continuation = "bist wunderschön."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary: [1, 0],
            prefix: [0.8, 0.6],
            continuation: [1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 4, text: primary)],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: prefix),
                SubtitleCue(start: 2, end: 4, text: continuation)
            ]
        )

        let pair = try XCTUnwrap(result.alignedPhrases.first)
        XCTAssertEqual(pair.secondaryFragmentIDs.count, 2)
        XCTAssertEqual(pair.secondaryText, "\(prefix)\n\(continuation)")
    }

    func testMicroAlignmentDoesNotReuseOneStrongFragmentAcrossGroup() async throws {
        let primaryA = "Primary translated sentence."
        let primaryExtra = "Primary unrelated sentence."
        let secondaryA = "Secondary translated sentence."
        let secondaryExtra = "Secondary unrelated sentence."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primaryA: [1, 0],
            primaryExtra: [0.9, 0.435],
            secondaryA: [1, 0],
            secondaryExtra: [0.5, -0.866]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: primaryA),
                SubtitleCue(start: 2, end: 4, text: primaryExtra)
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: secondaryA),
                SubtitleCue(start: 2, end: 4, text: secondaryExtra)
            ]
        )

        XCTAssertEqual(result.alignedPhrases.count, 1)
        XCTAssertEqual(result.alignedPhrases.first?.primaryText, primaryA)
        XCTAssertEqual(result.alignedPhrases.first?.secondaryText, secondaryA)
        XCTAssertEqual(result.unmatchedPrimaryFragments.map(\.text), [primaryExtra])
        XCTAssertEqual(result.unmatchedSecondaryFragments.map(\.text), [secondaryExtra])
    }

    func testMicroAlignmentAcceptsSupportedTwoToOnePlusOneToOneSequence() async throws {
        let primaryPrefix = "Open the"
        let primaryContinuation = "door right now."
        let primaryNext = "Then sit down."
        let secondaryMerged = "Öffne jetzt sofort die Tür."
        let secondaryNext = "Dann setz dich hin."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primaryPrefix: [1, 0, 0],
            primaryContinuation: [0.8, 0.6, 0],
            primaryNext: [0, 0, 1],
            secondaryMerged: [0.9, 0.435, 0],
            secondaryNext: [0, 0, 1]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 1, text: primaryPrefix),
                SubtitleCue(start: 1, end: 3, text: primaryContinuation),
                SubtitleCue(start: 3, end: 5, text: primaryNext)
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 3, text: secondaryMerged),
                SubtitleCue(start: 3, end: 5, text: secondaryNext)
            ]
        )

        XCTAssertEqual(result.summary.alignedPrimaryFragmentCount, 3)
        XCTAssertEqual(result.summary.alignedSecondaryFragmentCount, 2)
        XCTAssertTrue(result.alignedPhrases.contains {
            $0.primaryFragmentIDs.count == 2 && $0.secondaryFragmentIDs.count == 1
        })
    }

    func testOppositeExplicitNegationRejectsOtherwiseIdenticalEmbedding() async throws {
        let primary = "I do not know how to stop this."
        let secondary = "Ich weiß, wie wir das stoppen können."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary: [1, 0],
            secondary: [1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 3, text: primary)],
            secondaryCues: [SubtitleCue(start: 0, end: 3, text: secondary)]
        )

        XCTAssertTrue(result.alignedPhrases.isEmpty)
    }

    func testRealWorldNegationMismatchRemainsUnpaired() async throws {
        let primary = "Клем, не отвлекайся, я их сам просил."
        let secondary = "Clem, bitte, es ist meine Schuld, ok?"
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary: [1, 0],
            secondary: [1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 3, text: primary)],
            secondaryCues: [SubtitleCue(start: 0, end: 3, text: secondary)]
        )

        XCTAssertTrue(result.alignedPhrases.isEmpty)
    }

    func testReduplicatedActionRequiresStrongSemanticEvidence() async throws {
        let primary = "Sniff this now."
        let secondary = "Kille-kille."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary: [1, 0],
            secondary: [0.8, 0.6]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 2, text: primary)],
            secondaryCues: [SubtitleCue(start: 0, end: 2, text: secondary)]
        )

        XCTAssertTrue(result.alignedPhrases.isEmpty)
    }

    func testLowSemanticSingletonMustBeMutualLocalBest() async throws {
        let primaryAnchor = "The earlier translated line."
        let primaryShifted = "What a surprise this is."
        let secondaryAnchor = "Die frühere übersetzte Zeile."
        let secondaryWrong = "Also, dann alles Gute."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primaryAnchor: [0.9, 0.435],
            primaryShifted: [1, 0],
            secondaryAnchor: [0.9, 0.435],
            secondaryWrong: [0.86, 0.51]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: primaryAnchor),
                SubtitleCue(start: 2, end: 4, text: primaryShifted)
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: secondaryAnchor),
                SubtitleCue(start: 2, end: 4, text: secondaryWrong)
            ]
        )

        XCTAssertFalse(result.alignedPhrases.contains {
            $0.primaryText == primaryShifted && $0.secondaryText == secondaryWrong
        })
    }

    func testShiftedThreeByThreeCannotReuseOutOfOrderMeaning() async throws {
        let primary = ["Я тоже.", "Серьёзно?", "Вот это да!"]
        let secondary = ["Ist nicht wahr?", "Ich auch.", "Wirklich?"]
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary[0]: [1, 0, 0],
            primary[1]: [0, 1, 0],
            primary[2]: [0, 0, 1],
            secondary[0]: [0, 1, 0],
            secondary[1]: [1, 0, 0],
            secondary[2]: [0, 1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: primary.enumerated().map {
                SubtitleCue(start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
            },
            secondaryCues: secondary.enumerated().map {
                SubtitleCue(start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
            }
        )

        XCTAssertFalse(result.alignedPhrases.contains {
            $0.primaryFragmentIDs.count == 3 || $0.secondaryFragmentIDs.count == 3
        })
        XCTAssertFalse(result.alignedPhrases.contains {
            $0.primaryText.contains(primary[0]) && $0.secondaryText.contains(secondary[0])
        })
    }

    func testEqualScoreTieKeepsSmallestTransitions() async throws {
        let provider = FakePhraseEmbeddingProvider(vectors: [
            "Primary A sentence.": [1, 0],
            "Primary B sentence.": [1, 0],
            "Secondary A sentence.": [1, 0],
            "Secondary B sentence.": [1, 0]
        ])
        let result = try await SubtitlePhraseAligner(
            embeddingProvider: provider,
            configuration: SubtitlePhraseAlignmentConfiguration(mergePenalty: 0)
        ).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Primary A sentence."),
                SubtitleCue(start: 2, end: 4, text: "Primary B sentence.")
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: "Secondary A sentence."),
                SubtitleCue(start: 2, end: 4, text: "Secondary B sentence.")
            ]
        )

        XCTAssertEqual(result.alignedPhrases.count, 2)
        XCTAssertTrue(result.alignedPhrases.allSatisfy {
            $0.primaryFragmentIDs.count == 1 && $0.secondaryFragmentIDs.count == 1
        })
    }

    func testCompleteSentencesInSameCueCannotBeMergedAsOneTranslation() async throws {
        let primaryFirst = "The voltage is fine."
        let primaryExtra = "What do we have here?"
        let secondary = "Die Spannung ist in Ordnung."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primaryFirst: [1, 0],
            primaryExtra: [0.6, 0.8],
            secondary: [1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(
                start: 0,
                end: 4,
                text: "\(primaryFirst) \(primaryExtra)"
            )],
            secondaryCues: [SubtitleCue(start: 0, end: 4, text: secondary)]
        )

        XCTAssertFalse(result.alignedPhrases.contains {
            $0.primaryFragmentIDs.count == 2 && $0.secondaryFragmentIDs.count == 1
        })
        XCTAssertTrue(result.unmatchedPrimaryFragments.contains { $0.text == primaryExtra })
    }

    func testRealVoltageGroupCannotAbsorbQuestionIntoWirklich() async throws {
        let primary = ["Напряжение в порядке.", "Что у нас здесь?", "Правда?"]
        let secondary = ["Spannung sieht ok aus.", "Wirklich?"]
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary[0]: [1, 0, 0],
            primary[1]: [0, 1, 0],
            primary[2]: [0, 0, 1],
            secondary[0]: [1, 0, 0],
            secondary[1]: [0, 0, 1]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 6, text: primary.joined(separator: " "))],
            secondaryCues: [SubtitleCue(start: 0, end: 6, text: secondary.joined(separator: " "))]
        )

        XCTAssertFalse(result.alignedPhrases.contains {
            $0.primaryText.contains(primary[1]) && $0.secondaryText.contains(secondary[1])
        })
    }

    func testEllipsisContinuationWithQuoteAndCapitalCannotStandAlone() async throws {
        let primary = "We start with your most recent memories."
        let prefix = "Wir fangen an...”"
        let continuation = "Mit Ihren jüngsten Erinnerungen."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary: [1, 0],
            prefix: [0.8, 0.6],
            continuation: [1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 4, text: primary)],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: prefix),
                SubtitleCue(start: 2, end: 4, text: continuation)
            ]
        )

        let pair = try XCTUnwrap(result.alignedPhrases.first)
        XCTAssertEqual(pair.secondaryFragmentIDs.count, 2)
        XCTAssertEqual(pair.secondaryText, "\(prefix)\n\(continuation)")
    }

    func testExplicitSpeakerChangeAfterEllipsisRemainsIndependentlyPairable() async throws {
        let unfinished = "I was about to say..."
        let primarySpeaker = "- New speaker sentence."
        let secondarySpeaker = "- Satz eines neuen Sprechers."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            unfinished: [0, 1],
            primarySpeaker: [1, 0],
            secondarySpeaker: [1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: unfinished),
                SubtitleCue(start: 2, end: 4, text: primarySpeaker)
            ],
            secondaryCues: [SubtitleCue(start: 2, end: 4, text: secondarySpeaker)]
        )

        XCTAssertTrue(result.alignedPhrases.contains {
            $0.primaryText == primarySpeaker && $0.secondaryText == secondarySpeaker
        })
        XCTAssertTrue(result.unmatchedPrimaryFragments.contains { $0.text == unfinished })
    }

    func testShortFragmentCannotHideInsideMergedCellWithoutPathNeighbors() async throws {
        let primary = "A complete meaningful sentence."
        let secondaryPrefix = "Ein vollständiger Satz"
        let secondaryShort = "Ja"
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary: [1, 0],
            secondaryPrefix: [1, 0],
            secondaryShort: [1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 4, text: primary)],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: secondaryPrefix),
                SubtitleCue(start: 2, end: 4, text: secondaryShort)
            ]
        )

        XCTAssertFalse(result.alignedPhrases.contains {
            $0.primaryFragmentIDs.count == 1 && $0.secondaryFragmentIDs.count == 2
        })
    }

    func testMutualLocalBestHasNoHighSemanticBypass() async throws {
        let primary = "You are beautiful."
        let secondaryWrong = "Du bist freundlich."
        let secondaryCorrect = "Du bist wunderschön."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary: [1, 0],
            secondaryWrong: [0.89, 0.45596],
            secondaryCorrect: [0.95, 0.31225]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 3, text: primary)],
            secondaryCues: [
                SubtitleCue(start: 0, end: 3, text: secondaryWrong),
                SubtitleCue(start: 0.4, end: 3.4, text: secondaryCorrect)
            ]
        )

        XCTAssertFalse(result.alignedPhrases.contains {
            $0.secondaryText == secondaryWrong
        })
        XCTAssertTrue(result.alignedPhrases.contains {
            $0.secondaryText == secondaryCorrect
        })
    }

    func testMicroSingletonUsesGlobalLocalBestForShiftedDejaVuContinuation() async throws {
        let primaryDejaVu = "Дежа вю."
        let primaryReaction = "- Это так..."
        let primaryProcedure = "- Так, чтобы провести процедуру сегодня ночью..."
        let secondaryDejaVu = "Ein Deja vu."
        let secondaryReaction = "Das ist ja total..."
        let secondaryWrong = "- Na, fein, lassen Sie uns anfangen."
        let secondaryCorrect = "Wenn wir heute mit der Arbeit beginnen..."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primaryDejaVu: [1, 0, 0, 0],
            secondaryDejaVu: [1, 0, 0, 0],
            primaryReaction: [0, 1, 0, 0],
            secondaryReaction: [0, 1, 0, 0],
            primaryProcedure: [0, 0, 1, 0],
            secondaryWrong: [0, 0, 0.58, 0.8146],
            secondaryCorrect: [0, 0, 0.95, 0.31225]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 1, text: primaryDejaVu),
                SubtitleCue(start: 1, end: 2, text: primaryReaction),
                SubtitleCue(start: 2, end: 3, text: primaryProcedure)
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 1, text: secondaryDejaVu),
                SubtitleCue(start: 1, end: 2, text: secondaryReaction),
                SubtitleCue(start: 2, end: 3, text: secondaryWrong),
                SubtitleCue(start: 2.5, end: 3.5, text: secondaryCorrect)
            ]
        )

        XCTAssertFalse(result.alignedPhrases.contains {
            $0.primaryText.contains(primaryProcedure)
                && $0.secondaryText.contains(secondaryWrong)
        })
        XCTAssertTrue(result.alignedPhrases.contains {
            $0.primaryText == primaryProcedure && $0.secondaryText == secondaryCorrect
        })
    }

    func testCurlyApostropheNegationRejectsPositiveCounterpart() async throws {
        let primary = "I don’t know how to stop it."
        let secondary = "Ich weiß, wie man es stoppt."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primary: [1, 0],
            secondary: [1, 0]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [SubtitleCue(start: 0, end: 3, text: primary)],
            secondaryCues: [SubtitleCue(start: 0, end: 3, text: secondary)]
        )

        XCTAssertTrue(result.alignedPhrases.isEmpty)
    }

    func testIsolatedLowSemanticSingletonIsRejectedWithoutBlockingStrongPair() async throws {
        let primaryWrong = "Well, then go."
        let primaryGood = "Please stay this time."
        let secondaryWrong = "Schon ok."
        let secondaryGood = "Bitte bleib diesmal."
        let provider = FakePhraseEmbeddingProvider(vectors: [
            primaryWrong: [1, 0, 0],
            secondaryWrong: [0.8, 0.6, 0],
            primaryGood: [0, 0, 1],
            secondaryGood: [0, 0, 1]
        ])
        let result = try await SubtitlePhraseAligner(embeddingProvider: provider).align(
            primaryCues: [
                SubtitleCue(start: 0, end: 2, text: primaryWrong),
                SubtitleCue(start: 2, end: 4, text: primaryGood)
            ],
            secondaryCues: [
                SubtitleCue(start: 0, end: 2, text: secondaryWrong),
                SubtitleCue(start: 2, end: 4, text: secondaryGood)
            ]
        )

        XCTAssertFalse(result.alignedPhrases.contains { $0.primaryText == primaryWrong })
        XCTAssertTrue(result.alignedPhrases.contains {
            $0.primaryText == primaryGood && $0.secondaryText == secondaryGood
        })
    }

    func testEmbeddingCountMismatchIsReported() async {
        let provider = WrongCountEmbeddingProvider()
        let aligner = SubtitlePhraseAligner(embeddingProvider: provider)

        do {
            _ = try await aligner.align(
                primaryCues: [SubtitleCue(start: 0, end: 1, text: "One sentence.")],
                secondaryCues: [SubtitleCue(start: 0, end: 1, text: "Ein Satz.")]
            )
            XCTFail("Expected count mismatch")
        } catch let error as PhraseEmbeddingError {
            XCTAssertEqual(error, .countMismatch(expected: 2, actual: 0))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeFragment(
        cue: Int,
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> SubtitlePhraseFragment {
        SubtitlePhraseFragment(
            id: SubtitleFragmentID(cueIndex: cue, fragmentIndex: 0),
            text: text,
            videoStart: start,
            videoEnd: end,
            endsSentence: true,
            startsNewSpeaker: false,
            isNonDialogue: false,
            characterWeight: max(text.count, 1)
        )
    }
}

private struct FakePhraseEmbeddingProvider: PhraseEmbeddingProviding {
    let modelVersion = "fake-v1"
    let vectors: [String: [Float]]

    func embeddings(for texts: [String]) async throws -> [[Float]] {
        try texts.map { text in
            guard let vector = vectors[text] else {
                throw FakeEmbeddingError.missingText(text)
            }
            return vector
        }
    }
}

private struct WrongCountEmbeddingProvider: PhraseEmbeddingProviding {
    let modelVersion = "wrong-count"

    func embeddings(for texts: [String]) async throws -> [[Float]] {
        []
    }
}

private enum FakeEmbeddingError: Error {
    case missingText(String)
}
