import CoreWLAN
import XCTest

@testable import WifindKit

final class BandTests: XCTestCase {
    func testCoreWLANBandMapping() {
        XCTAssertEqual(Band.from(cwBand: .band2GHz), .ghz2)
        XCTAssertEqual(Band.from(cwBand: .band5GHz), .ghz5)
        XCTAssertEqual(Band.from(cwBand: .band6GHz), .ghz6)
        XCTAssertEqual(Band.from(cwBand: .bandUnknown), .unknown)
    }

    func testChannelNumberFallback() {
        XCTAssertEqual(Band.from(channelNumber: 1), .ghz2)
        XCTAssertEqual(Band.from(channelNumber: 14), .ghz2)
        XCTAssertEqual(Band.from(channelNumber: 36), .ghz5)
        XCTAssertEqual(Band.from(channelNumber: 177), .ghz5)
        // 6 GHz channel numbers overlap the 2.4 GHz range, so a bare number
        // must not be reported as 6 GHz.
        XCTAssertEqual(Band.from(channelNumber: 5), .ghz2)
        XCTAssertEqual(Band.from(channelNumber: 233), .unknown)
    }

    func testLongNames() {
        XCTAssertEqual(Band.ghz2.longName, "2.4 GHz")
        XCTAssertEqual(Band.ghz5.longName, "5 GHz")
        XCTAssertEqual(Band.ghz6.longName, "6 GHz")
    }
}

final class ModelTests: XCTestCase {
    func testIdentityPrefersBSSID() {
        let entry = NetworkEntry(ssid: "home", bssid: "AA:BB:CC:DD:EE:FF", channel: 44)
        XCTAssertEqual(entry.identityKey, "bssid:aa:bb:cc:dd:ee:ff")
    }

    func testIdentityFallsBackToSSIDAndChannel() {
        let entry = NetworkEntry(ssid: "home", bssid: nil, channel: 44)
        XCTAssertEqual(entry.identityKey, "ssid:home#44")
        let hidden = NetworkEntry(ssid: nil, bssid: nil, channel: 6)
        XCTAssertEqual(hidden.identityKey, "ssid:<hidden>#6")
    }

    func testDisplayFallbacks() {
        let entry = NetworkEntry(ssid: nil, bssid: nil, channel: 6)
        XCTAssertEqual(entry.displaySSID, "(hidden)")
        XCTAssertEqual(entry.displayBSSID, "--")
    }

    func testOfflineSavedFlag() {
        let offline = NetworkEntry(ssid: "home", security: "?", isSaved: true)
        XCTAssertTrue(offline.isOfflineSaved)
        let visible = NetworkEntry(ssid: "home", rssi: -50, isSaved: true)
        XCTAssertFalse(visible.isOfflineSaved)
        let current = NetworkEntry(ssid: "home", isCurrent: true, isSaved: true)
        XCTAssertFalse(current.isOfflineSaved)
    }

    func testChannelWidthMapping() {
        XCTAssertEqual(channelWidthMHz(.width20MHz), 20)
        XCTAssertEqual(channelWidthMHz(.width40MHz), 40)
        XCTAssertEqual(channelWidthMHz(.width80MHz), 80)
        XCTAssertEqual(channelWidthMHz(.width160MHz), 160)
        XCTAssertNil(channelWidthMHz(.widthUnknown))
    }

    func testSignalBars() {
        XCTAssertEqual(signalBars(nil), "    ")
        XCTAssertEqual(signalBars(-40), "\u{2582}\u{2582}\u{2582}\u{2582}")
        XCTAssertEqual(signalBars(-70), "\u{2582}\u{2582}__")
        XCTAssertEqual(signalBars(-95), "____")
    }
}

final class SelectionTests: XCTestCase {
    private func sample() -> [NetworkEntry] {
        [
            NetworkEntry(ssid: "weak", bssid: "00:00:00:00:00:01", channel: 6, band: .ghz2, rssi: -80, security: "WPA2"),
            NetworkEntry(ssid: "strong", bssid: "00:00:00:00:00:02", channel: 44, band: .ghz5, rssi: -45, security: "WPA3"),
            NetworkEntry(ssid: "hidden-ap", bssid: nil, channel: 149, band: .ghz5, rssi: nil, security: "?"),
        ]
    }

    func testDedupeKeepsStrongestReport() {
        let weaker = NetworkEntry(ssid: "home", bssid: "aa:bb:cc:dd:ee:ff", channel: 44, band: .ghz5, rssi: -70)
        let stronger = NetworkEntry(ssid: "home", bssid: "aa:bb:cc:dd:ee:ff", channel: 44, band: .ghz5, rssi: -50)
        let deduped = Scanner.dedupe([weaker, stronger])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.rssi, -50)
    }

    func testDedupeKeepsSeparateBSSIDs() {
        let a = NetworkEntry(ssid: "mesh", bssid: "aa:bb:cc:dd:ee:01", channel: 1, band: .ghz2, rssi: -60)
        let b = NetworkEntry(ssid: "mesh", bssid: "aa:bb:cc:dd:ee:02", channel: 44, band: .ghz5, rssi: -55)
        XCTAssertEqual(Scanner.dedupe([a, b]).count, 2)
    }

    func testDedupeWithoutBSSIDSeparatesChannels() {
        let a = NetworkEntry(ssid: "home", channel: 6)
        let b = NetworkEntry(ssid: "home", channel: 11)
        XCTAssertEqual(Scanner.dedupe([a, b]).count, 2)
    }

    func testSortByRSSIPutsUnknownLast() {
        let sorted = sortEntries(sample(), by: .rssi)
        XCTAssertEqual(sorted.map { $0.ssid }, ["strong", "weak", "hidden-ap"])
    }

    func testSortByChannel() {
        let sorted = sortEntries(sample(), by: .channel)
        XCTAssertEqual(sorted.map { $0.channel }, [6, 44, 149])
    }

    func testSortByBandGroups() {
        let sorted = sortEntries(sample(), by: .band)
        XCTAssertEqual(sorted.first?.band, .ghz2)
        XCTAssertEqual(sorted.last?.band, .ghz5)
    }

    func testSortIsStableForEqualRSSI() {
        let a = NetworkEntry(ssid: "beta", rssi: -50)
        let b = NetworkEntry(ssid: "alpha", rssi: -50)
        XCTAssertEqual(sortEntries([a, b], by: .rssi).map { $0.ssid }, ["alpha", "beta"])
    }

    func testFilterMatchesSSIDAndBSSID() {
        let entries = sample()
        XCTAssertEqual(filterEntries(entries, query: "stron").count, 1)
        XCTAssertEqual(filterEntries(entries, query: "00:00:00:00:00:01").count, 1)
        XCTAssertEqual(filterEntries(entries, query: "00:00:00:00:00:01").first?.ssid, "weak")
        XCTAssertEqual(filterEntries(entries, query: "").count, 3)
        XCTAssertEqual(filterEntries(entries, query: "nothing").count, 0)
    }

    func testBandFilter() {
        let entries = sample()
        XCTAssertEqual(entries.filter { BandFilter.ghz2.matches($0) }.count, 1)
        XCTAssertEqual(entries.filter { BandFilter.ghz5.matches($0) }.count, 2)
        XCTAssertEqual(entries.filter { BandFilter.all.matches($0) }.count, 3)
        XCTAssertEqual(BandFilter.all.next, .ghz2)
        XCTAssertEqual(BandFilter.ghz6.next, .all)
    }
}

final class DisplayTests: XCTestCase {
    func testASCIIWidth() {
        XCTAssertEqual(Display.width("home-5g"), 7)
    }

    func testCJKWidth() {
        XCTAssertEqual(Display.width("\u{5BB6}"), 2)
        XCTAssertEqual(Display.width("\u{5BB6}\u{5EAD}WiFi"), 8)
    }

    func testCombiningMarkIsZeroWidth() {
        XCTAssertEqual(Display.width("e\u{0301}"), 1)
    }

    func testTruncateAddsEllipsis() {
        XCTAssertEqual(Display.truncate("abcdefgh", width: 5), "abcd\u{2026}")
        XCTAssertEqual(Display.truncate("abc", width: 5), "abc")
        XCTAssertEqual(Display.truncate("\u{5BB6}\u{5EAD}\u{5BB6}\u{5EAD}", width: 5), "\u{5BB6}\u{5EAD}\u{2026}")
    }

    func testPadAlignsByDisplayWidth() {
        XCTAssertEqual(Display.width(Display.pad("\u{5BB6}", width: 6)), 6)
        XCTAssertEqual(Display.width(Display.pad("home", width: 6, alignRight: true)), 6)
        XCTAssertTrue(Display.pad("home", width: 6, alignRight: true).hasPrefix("  "))
    }

    func testPadTruncatesOverlongText() {
        XCTAssertEqual(Display.pad("abcdefgh", width: 4), "abc\u{2026}")
    }
}

/// The helper hands rows across a process boundary as JSON, so the round trip
/// has to preserve everything the UI and the connect path depend on.
final class HelperWireTests: XCTestCase {
    private func roundTrip(_ entry: NetworkEntry) throws -> NetworkEntry {
        let data = try JSONEncoder().encode(HelperAccessPoint(entry: entry))
        let decoded = try JSONDecoder().decode(HelperAccessPoint.self, from: data)
        return decoded.entry()
    }

    func testRoundTripKeepsEveryField() throws {
        let entry = NetworkEntry(
            ssid: "Iceland",
            bssid: "18:f2:2c:04:a7:12",
            channel: 36,
            band: .ghz5,
            widthMHz: 80,
            rssi: -48,
            noise: -92,
            security: "WPA2/WPA3",
            isOpen: false,
            phyMode: "802.11ax",
            isCurrent: true,
            isSaved: true,
            ref: nil
        )
        let restored = try roundTrip(entry)
        XCTAssertEqual(restored.ssid, "Iceland")
        XCTAssertEqual(restored.bssid, "18:f2:2c:04:a7:12")
        XCTAssertEqual(restored.channel, 36)
        XCTAssertEqual(restored.band, .ghz5)
        XCTAssertEqual(restored.widthMHz, 80)
        XCTAssertEqual(restored.rssi, -48)
        XCTAssertEqual(restored.noise, -92)
        XCTAssertEqual(restored.security, "WPA2/WPA3")
        XCTAssertEqual(restored.phyMode, "802.11ax")
        XCTAssertTrue(restored.isCurrent)
        XCTAssertTrue(restored.isSaved)
        XCTAssertNil(restored.ref)
    }

    func testRoundTripKeepsRedactedAndOpenFlags() throws {
        let hidden = NetworkEntry(ssid: nil, bssid: nil, channel: 6, band: .ghz2, rssi: -70, security: "OWE", isOpen: true)
        let restored = try roundTrip(hidden)
        XCTAssertNil(restored.ssid)
        XCTAssertNil(restored.bssid)
        XCTAssertTrue(restored.isOpen)
        XCTAssertEqual(restored.band, .ghz2)
        XCTAssertEqual(restored.identityKey, "ssid:<hidden>#6")
    }

    func testRoundTripKeepsOfflineSavedRow() throws {
        let offline = NetworkEntry(ssid: "home", channel: nil, band: .unknown, security: "?", isSaved: true)
        let restored = try roundTrip(offline)
        XCTAssertTrue(restored.isOfflineSaved)
    }

    func testUnknownBandStringDoesNotInventABand() throws {
        let wire = HelperAccessPoint(ssid: "x", band: "nonsense")
        XCTAssertEqual(wire.entry().band, .unknown)
    }

    func testHelperRequestEncodesActionAndOmitsNothingNeeded() throws {
        let request = HelperRequest(
            action: .connect,
            iface: "en0",
            ssid: "Iceland",
            bssid: nil,
            channel: 36,
            password: "secret",
            timeout: 20
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: data)
        XCTAssertEqual(decoded.action, .connect)
        XCTAssertEqual(decoded.iface, "en0")
        XCTAssertEqual(decoded.ssid, "Iceland")
        XCTAssertEqual(decoded.channel, 36)
        XCTAssertEqual(decoded.password, "secret")
        XCTAssertEqual(decoded.timeout, 20)
    }
}

/// The table used to be two columns wider than the terminal, which made every
/// row wrap and the whole screen jump while rescanning. These hold the
/// arithmetic to the promise that a row fits.
final class TableLayoutTests: XCTestCase {
    func testRowNeverExceedsTheTerminal() {
        for width in 60...200 {
            let layout = TableLayout(width: width)
            XCTAssertLessThanOrEqual(layout.totalWidth, width, "row overflows at \(width) columns")
        }
    }

    func testExactFitAtEightyColumns() {
        let layout = TableLayout(width: 80)
        XCTAssertEqual(layout.totalWidth, 80)
        XCTAssertTrue(layout.showsSecurity)
        XCTAssertFalse(layout.showsBSSID)
        XCTAssertFalse(layout.showsWidth)
    }

    func testWideTerminalShowsEveryColumn() {
        let layout = TableLayout(width: 120)
        XCTAssertEqual(layout.columns.map { $0.title }, ["BAND", "SSID", "BSSID", "CH", "W", "RSSI", "SEC", ""])
        XCTAssertTrue(layout.showsBSSID)
        XCTAssertTrue(layout.showsWidth)
        XCTAssertLessThanOrEqual(layout.totalWidth, 120)
    }

    func testMediumTerminalDropsTheOptionalColumns() {
        let layout = TableLayout(width: 90)
        XCTAssertEqual(layout.columns.map { $0.title }, ["BAND", "SSID", "BSSID", "CH", "RSSI", "SEC", ""])
        XCTAssertTrue(layout.showsBSSID)
        XCTAssertFalse(layout.showsWidth)
    }

    func testNarrowTerminalKeepsTheEssentialColumns() {
        let layout = TableLayout(width: 60)
        XCTAssertEqual(layout.columns.map { $0.title }, ["BAND", "SSID", "CH", "RSSI", ""])
    }

    func testSSIDColumnStopsShrinkingAtTheMinimum() {
        let layout = TableLayout(width: 20)
        XCTAssertGreaterThanOrEqual(layout.columns[1].width, TableLayout.minimumSSIDWidth)
    }
}

/// Styled text is what the renderer actually paints, so width has to be
/// measured the way the terminal measures it: escapes are invisible.
final class StyledWidthTests: XCTestCase {
    func testVisibleWidthIgnoresEscapes() {
        XCTAssertEqual(Display.visibleWidth("\u{1B}[1mhello\u{1B}[0m"), 5)
        XCTAssertEqual(Display.visibleWidth("plain"), 5)
        XCTAssertEqual(Display.visibleWidth(""), 0)
    }

    func testVisibleWidthCountsWideCharacters() {
        XCTAssertEqual(Display.visibleWidth("\u{1B}[33m\u{5BB6}\u{5EAD}\u{1B}[0m"), 4)
    }

    func testTruncateVisibleFitsTheLimitAndKeepsEscapesBalanced() {
        let line = "\u{1B}[32m" + String(repeating: "x", count: 200) + "\u{1B}[0m"
        let cut = Display.truncateVisible(line, width: 20)
        XCTAssertLessThanOrEqual(Display.visibleWidth(cut), 20)
        XCTAssertTrue(cut.hasPrefix("\u{1B}[32m"))
        XCTAssertTrue(cut.hasSuffix("\u{1B}[0m"))
        XCTAssertTrue(cut.contains("\u{2026}"))
    }

    func testTruncateVisibleLeavesShortStyledLinesAlone() {
        let line = "\u{1B}[1mshort\u{1B}[0m"
        XCTAssertEqual(Display.truncateVisible(line, width: 20), line)
    }

    func testTruncateVisibleHandlesCJKWithoutSplittingCells() {
        let line = String(repeating: "\u{5BB6}", count: 20)
        let cut = Display.truncateVisible(line, width: 5)
        XCTAssertLessThanOrEqual(Display.visibleWidth(cut), 5)
    }

    func testRenderedRowShapeFitsTheTerminal() {
        for width in [60, 80, 90, 120, 160] {
            let layout = TableLayout(width: width)
            var row = " "
            for column in layout.columns {
                let cell = Display.pad(String(repeating: "x", count: column.width), width: column.width)
                row += "\u{1B}[36m" + cell + "\u{1B}[0m "
            }
            XCTAssertLessThanOrEqual(Display.visibleWidth(row), width, "styled row overflows at \(width)")
        }
    }
}

/// The note under the header is the only explanation the user gets when macOS
/// hides the names, so its wrapping is worth holding down.
final class WrapTests: XCTestCase {
    func testShortTextStaysOnOneLine() {
        XCTAssertEqual(Display.wrap("hello", columns: 20, maxLines: 2), ["hello"])
    }

    func testEmptyTextProducesNoLines() {
        XCTAssertEqual(Display.wrap("", columns: 20, maxLines: 2), [])
    }

    func testLongTextWrapsAtAWordBoundary() {
        let lines = Display.wrap("the quick brown fox jumps over the lazy dog", columns: 20, maxLines: 3)
        XCTAssertGreaterThan(lines.count, 1)
        for line in lines {
            XCTAssertLessThanOrEqual(Display.width(line), 20, "line too wide: \(line)")
        }
        // Wrapping at spaces means no line ends mid-word.
        for line in lines.dropLast() {
            XCTAssertFalse(line.hasSuffix(" "), "trailing space in \"\(line)\"")
        }
    }

    func testEveryLineFitsTheColumnBudget() {
        let note = "macOS redacted every SSID. Grant Location Services access to the app running wifind (or use the bundled Wifind.app) and scan again."
        for columns in [30, 46, 60, 76, 100] {
            for line in Display.wrap(note, columns: columns, maxLines: 2) {
                XCTAssertLessThanOrEqual(Display.width(line), columns, "at \(columns) columns")
            }
        }
    }

    func testMaxLinesIsRespectedAndOverflowIsMarked() {
        let note = String(repeating: "word ", count: 40)
        let lines = Display.wrap(note, columns: 20, maxLines: 2)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix("\u{2026}"), "overflow should be marked on the last line")
    }

    func testWideCharactersAreMeasuredAsTwoColumns() {
        let lines = Display.wrap("\u{5BB6}\u{5EAD}\u{5BB6}\u{5EAD}\u{5BB6}\u{5EAD}\u{5BB6}\u{5EAD}", columns: 6, maxLines: 3)
        for line in lines {
            XCTAssertLessThanOrEqual(Display.width(line), 6)
        }
        XCTAssertEqual(lines[0], "\u{5BB6}\u{5EAD}\u{5BB6}")
    }

    func testWrappingNeverExceedsTheRequestedLines() {
        for maxLines in 1...4 {
            let lines = Display.wrap(String(repeating: "ab ", count: 50), columns: 10, maxLines: maxLines)
            XCTAssertLessThanOrEqual(lines.count, maxLines)
        }
    }
}
