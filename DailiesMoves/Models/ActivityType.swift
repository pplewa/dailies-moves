import Foundation
import SwiftUI

/// User-customizable Move activity type (e.g. Walking, Car, Biking, etc.).
struct ActivityType: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var name: String
    var sfSymbol: String
    var colorHex: String
    var sortOrder: Int

    var gpxType: String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    var swiftUIColor: Color {
        Color(hex: colorHex) ?? .blue
    }

    static let defaults: [ActivityType] = [
        ActivityType(id: "walking", name: "Walking", sfSymbol: "figure.walk", colorHex: "#34C759", sortOrder: 0),
        ActivityType(id: "car", name: "Car", sfSymbol: "car.fill", colorHex: "#007AFF", sortOrder: 1),
        ActivityType(id: "biking", name: "Biking", sfSymbol: "bicycle", colorHex: "#FF9500", sortOrder: 2),
        ActivityType(id: "running", name: "Running", sfSymbol: "figure.run", colorHex: "#FF3B30", sortOrder: 3),
        ActivityType(id: "transit", name: "Transit", sfSymbol: "tram.fill", colorHex: "#AF52DE", sortOrder: 4),
        ActivityType(id: "other", name: "Move", sfSymbol: "arrow.triangle.turn.up.right.diamond.fill", colorHex: "#8E8E93", sortOrder: 5)
    ]

    static let paletteHexes: [String] = [
        "#34C759", "#007AFF", "#FF9500", "#FF3B30",
        "#AF52DE", "#5AC8FA", "#FF2D55", "#5856D6",
        "#A2845E", "#30B0C7", "#8E8E93"
    ]

    static let suggestedSymbols: [String] = [
        "figure.walk", "car.fill", "bicycle", "figure.run",
        "tram.fill", "bus.fill", "ferry.fill", "airplane",
        "scooter", "motorcycle.fill", "figure.hiking", "sailboat.fill",
        "arrow.triangle.turn.up.right.diamond.fill"
    ]
}

extension Color {
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard trimmed.count == 6, let value = UInt64(trimmed, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
