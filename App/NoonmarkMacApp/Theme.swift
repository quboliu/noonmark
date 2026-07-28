import AppKit
import Combine
import CryptoKit
import Darwin
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    struct Palette {
        let desk: Color
        let background: Color
        let panel: Color
        let panel2: Color
        let line: Color
        let line2: Color
        let text1: Color
        let text2: Color
        let text3: Color
        let chip: Color
        let sidebar: Color
        let controlFill: Color
        let listRowHover: Color
    }

    private nonisolated(unsafe) static var activeTheme: AppTheme = .coolGray

    static func apply(_ theme: AppTheme) {
        activeTheme = theme
    }

    static func hex(_ value: Int) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private static func color(_ components: MacUISRGBColor) -> Color {
        Color(
            red: components.red,
            green: components.green,
            blue: components.blue
        )
    }

    private static var accessibilityPolicy: AccessibilityPresentationPolicy {
        let workspace = NSWorkspace.shared
        return AccessibilityPresentationPolicy(
            options: AccessibilityDisplayOptions(
                increasesContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                differentiatesWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
                reducesMotion: workspace.accessibilityDisplayShouldReduceMotion,
                reducesTransparency: workspace.accessibilityDisplayShouldReduceTransparency
            )
        )
    }

    static var palette: Palette {
        let increasedContrast = accessibilityPolicy.usesEnhancedBoundaries
        switch activeTheme {
        case .coolGray:
            return Palette(
                desk: Color(red: 0.925, green: 0.928, blue: 0.936),
                background: Color(red: 0.994, green: 0.993, blue: 0.991),
                panel: .white,
                panel2: Color(red: 0.984, green: 0.984, blue: 0.987),
                line: increasedContrast
                    ? Color(red: 0.72, green: 0.725, blue: 0.75)
                    : Color(red: 0.90, green: 0.902, blue: 0.914),
                line2: increasedContrast
                    ? Color(red: 0.58, green: 0.59, blue: 0.63)
                    : Color(red: 0.80, green: 0.805, blue: 0.835),
                text1: Color(red: 0.11, green: 0.11, blue: 0.12),
                text2: increasedContrast
                    ? Color(red: 0.30, green: 0.30, blue: 0.34)
                    : Color(red: 0.42, green: 0.42, blue: 0.46),
                text3: increasedContrast
                    ? Color(red: 0.34, green: 0.34, blue: 0.38)
                    : color(MacUIAccessibleColorMetrics.coolGrayTertiaryText),
                chip: Color(red: 0.951, green: 0.951, blue: 0.958),
                sidebar: Color(red: 0.982, green: 0.981, blue: 0.978),
                controlFill: Color(red: 0.996, green: 0.996, blue: 0.997),
                listRowHover: Color(red: 0.977, green: 0.979, blue: 0.984)
            )
        case .warmPaper:
            return Palette(
                desk: Color(red: 0.93, green: 0.914, blue: 0.882),
                background: Color(red: 0.997, green: 0.992, blue: 0.982),
                panel: Color(red: 1.0, green: 0.998, blue: 0.992),
                panel2: Color(red: 0.990, green: 0.982, blue: 0.964),
                line: increasedContrast
                    ? Color(red: 0.70, green: 0.65, blue: 0.57)
                    : Color(red: 0.90, green: 0.872, blue: 0.824),
                line2: increasedContrast
                    ? Color(red: 0.56, green: 0.49, blue: 0.40)
                    : Color(red: 0.78, green: 0.724, blue: 0.646),
                text1: Color(red: 0.13, green: 0.105, blue: 0.085),
                text2: increasedContrast
                    ? Color(red: 0.31, green: 0.255, blue: 0.205)
                    : Color(red: 0.44, green: 0.385, blue: 0.32),
                text3: increasedContrast
                    ? Color(red: 0.35, green: 0.29, blue: 0.23)
                    : color(MacUIAccessibleColorMetrics.warmPaperTertiaryText),
                chip: Color(red: 0.957, green: 0.946, blue: 0.925),
                sidebar: Color(red: 0.989, green: 0.979, blue: 0.957),
                controlFill: Color(red: 1.0, green: 0.997, blue: 0.989),
                listRowHover: Color(red: 0.989, green: 0.981, blue: 0.966)
            )
        }
    }

    static var desk: Color { palette.desk }
    static var background: Color { palette.background }
    static var panel: Color { palette.panel }
    static var panel2: Color { palette.panel2 }
    static var line: Color { palette.line }
    static var line2: Color { palette.line2 }
    static var text1: Color { palette.text1 }
    static var text2: Color { palette.text2 }
    static var text3: Color { palette.text3 }
    static var placeholderText: Color {
        if accessibilityPolicy.usesEnhancedBoundaries {
            return palette.text3
        }
        return switch activeTheme {
        case .coolGray:
            color(MacUIAccessibleColorMetrics.coolGrayPlaceholderText)
        case .warmPaper:
            color(MacUIAccessibleColorMetrics.warmPaperPlaceholderText)
        }
    }

    static var chip: Color { palette.chip }
    static var sidebar: Color { palette.sidebar }
    static var controlFill: Color { palette.controlFill }
    static var listRowHover: Color { palette.listRowHover }
    static var shouldReduceMotion: Bool {
        accessibilityPolicy.animatesTransitions == false
    }

    static var shouldReduceTransparency: Bool {
        accessibilityPolicy.options.reducesTransparency
    }

    static var shouldDifferentiateWithoutColor: Bool {
        accessibilityPolicy.usesTextualCountMarkers
    }

    static var layeredSurfaceOpacity: Double {
        accessibilityPolicy.layeredSurfaceOpacity
    }

    static let accent = Color(red: 0.16, green: 0.38, blue: 0.78)
    static let accentSoft = Color(red: 0.93, green: 0.955, blue: 1.0)
    static let ok = color(MacUIAccessibleColorMetrics.success)
    static let okSoft = Color(red: 0.91, green: 0.98, blue: 0.95)
    static let warn = Color(red: 0.706, green: 0.302, blue: 0.204)
    static let warnSoft = Color(red: 1.0, green: 0.937, blue: 0.922)
    static let noteBackground = Color(red: 1.0, green: 0.984, blue: 0.937)
    static let navDay = hex(0x2A6FDB)
    static let navPool = hex(0x0E9488)
    static let navFuture = hex(0x7C5CFF)
    static let navRecurring = hex(0xB86A16)
    static let navUnfinished = hex(0xE0851B)
    static let navCompleted = hex(0x1F8A5B)
    static let navCalendar = hex(0xD1477A)
    static let navZhulong = hex(0x7C5CFF)
    static let navSettings = hex(0x64748B)
    static let recurringActiveIcon = color(
        MacUIRecurringLifecycleColorMetrics.activeIcon
    )
    static let recurringUpcomingIcon = color(
        MacUIRecurringLifecycleColorMetrics.upcomingIcon
    )
    static let recurringEndedIcon = color(
        MacUIRecurringLifecycleColorMetrics.endedIcon
    )
    static let recurringStoppedIcon = color(
        MacUIRecurringLifecycleColorMetrics.stoppedIcon
    )
    static let recurringActiveText = color(
        MacUIRecurringLifecycleColorMetrics.activeText
    )
    static let recurringUpcomingText = color(
        MacUIRecurringLifecycleColorMetrics.upcomingText
    )
}
