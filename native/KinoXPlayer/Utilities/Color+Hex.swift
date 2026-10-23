import AppKit
import SwiftUI

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        let expanded: String
        switch value.count {
        case 3, 4:
            expanded = value.map { "\($0)\($0)" }.joined()
        case 6, 8:
            expanded = value
        default:
            return nil
        }

        guard expanded.allSatisfy(\.isHexDigit),
              let rgba = UInt64(expanded, radix: 16) else {
            return nil
        }

        let hasAlpha = expanded.count == 8
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64

        if hasAlpha {
            red = (rgba >> 24) & 0xFF
            green = (rgba >> 16) & 0xFF
            blue = (rgba >> 8) & 0xFF
            alpha = rgba & 0xFF
        } else {
            red = (rgba >> 16) & 0xFF
            green = (rgba >> 8) & 0xFF
            blue = rgba & 0xFF
            alpha = 0xFF
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }

    func hexString(includeAlpha: Bool = false) -> String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }

        let red = Self.byte(from: color.redComponent)
        let green = Self.byte(from: color.greenComponent)
        let blue = Self.byte(from: color.blueComponent)
        let alpha = Self.byte(from: color.alphaComponent)

        if includeAlpha {
            return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
        }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func byte(from component: CGFloat) -> Int {
        Int((min(max(component, 0), 1) * 255).rounded())
    }
}
