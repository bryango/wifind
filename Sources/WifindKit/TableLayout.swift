import Foundation

/// Column widths for the scan table.
///
/// Pure arithmetic, deliberately kept out of the renderer: the first version
/// computed rows two columns wider than the terminal, which made every row wrap
/// and the whole screen jump while rescanning. `totalWidth` is now the
/// invariant a test can hold on to.
public struct TableLayout {
    public struct Column: Equatable {
        public let title: String
        public let width: Int
        public let rightAligned: Bool
    }

    public let columns: [Column]
    /// What one rendered row actually occupies: a one-column marker, a space,
    /// then every column followed by a separating space.
    public let totalWidth: Int
    public let showsBSSID: Bool
    public let showsWidth: Bool
    public let showsSecurity: Bool

    /// Below this the SSID column stops shrinking and the row is allowed to
    /// overflow; the renderer clamps it. A terminal this narrow cannot show the
    /// table anyway.
    public static let minimumSSIDWidth = 8

    public init(width: Int) {
        let showsBSSID = width >= 84
        let showsWidth = width >= 96
        let showsSecurity = width >= 70

        var trailing: [Column] = []
        if showsBSSID { trailing.append(Column(title: "BSSID", width: 17, rightAligned: false)) }
        trailing.append(Column(title: "CH", width: 4, rightAligned: true))
        if showsWidth { trailing.append(Column(title: "W", width: 4, rightAligned: true)) }
        trailing.append(Column(title: "RSSI", width: 9, rightAligned: true))
        if showsSecurity { trailing.append(Column(title: "SEC", width: 10, rightAligned: false)) }
        trailing.append(Column(title: "", width: 3, rightAligned: false))

        let fixedWidth = 4 + trailing.reduce(0) { $0 + $1.width }
        // marker + space, then one separating space after every column; the
        // trailing +1 is the space that follows the SSID column itself.
        let reserved = 2 + (1 + trailing.count) + fixedWidth + 1
        let ssidWidth = max(TableLayout.minimumSSIDWidth, width - reserved)

        var columns: [Column] = [Column(title: "BAND", width: 4, rightAligned: false)]
        columns.append(Column(title: "SSID", width: ssidWidth, rightAligned: false))
        columns.append(contentsOf: trailing)

        self.columns = columns
        self.totalWidth = 2 + columns.reduce(0) { $0 + $1.width + 1 }
        self.showsBSSID = showsBSSID
        self.showsWidth = showsWidth
        self.showsSecurity = showsSecurity
    }
}
