import NoonmarkCore
import SwiftUI

@MainActor
enum IOSTheme {
    private static var activeTheme = AppTheme.coolGray

    static var background: Color {
        switch activeTheme {
        case .coolGray:
            Color(red: 0.965, green: 0.972, blue: 0.985)
        case .warmPaper:
            Color(red: 0.992, green: 0.985, blue: 0.970)
        }
    }

    static var panel: Color {
        switch activeTheme {
        case .coolGray:
            .white
        case .warmPaper:
            Color(red: 1.0, green: 0.997, blue: 0.990)
        }
    }

    static var text: Color {
        switch activeTheme {
        case .coolGray:
            Color(red: 0.08, green: 0.11, blue: 0.17)
        case .warmPaper:
            Color(red: 0.16, green: 0.12, blue: 0.09)
        }
    }

    static var secondaryText: Color {
        switch activeTheme {
        case .coolGray:
            Color(red: 0.35, green: 0.40, blue: 0.48)
        case .warmPaper:
            Color(red: 0.45, green: 0.39, blue: 0.32)
        }
    }

    static var accent: Color {
        switch activeTheme {
        case .coolGray:
            Color(red: 0.12, green: 0.36, blue: 0.86)
        case .warmPaper:
            Color(red: 0.15, green: 0.33, blue: 0.68)
        }
    }

    static var line: Color {
        switch activeTheme {
        case .coolGray:
            Color.black.opacity(0.08)
        case .warmPaper:
            Color(red: 0.34, green: 0.27, blue: 0.20).opacity(0.14)
        }
    }

    static func apply(_ theme: AppTheme) {
        activeTheme = theme
    }
}

struct IOSPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(IOSTheme.text)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.secondaryText)
                }
                Spacer()
                actions()
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct IOSComposer: View {
    @Binding var text: String
    let placeholder: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1 ... 5)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("ios.composer.\(placeholder)")
                .padding(12)
                .background(IOSTheme.background, in: RoundedRectangle(cornerRadius: 12))
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(IOSTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(IOSTheme.line)
        }
        .padding(.horizontal)
    }
}

struct IOSStatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(IOSTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(IOSTheme.background, in: Capsule())
    }
}
