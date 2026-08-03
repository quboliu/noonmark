import AppKit
import NoonmarkMacUIContract
import SwiftUI

enum NoonmarkVisualMetrics {
    static let launchSize = NSSize(
        width: MacUIWindowLayout.defaultWidth,
        height: MacUIWindowLayout.defaultHeight
    )
    static let minimumSize = NSSize(
        width: MacUIWindowLayout.minimumWidth,
        height: MacUIWindowLayout.minimumHeight
    )

    static let sidebarWidth = CGFloat(MacUIShellLayout.sidebarWidth)
    static let compactSidebarWidth = CGFloat(MacUIShellLayout.compactSidebarWidth)
    static let detailRailWidth = CGFloat(MacUIShellLayout.detailRailWidth)
    static let calendarRailWidth = CGFloat(MacUIShellLayout.calendarRailWidth)
    static let paneToggleButtonSize = CGFloat(MacUIShellLayout.paneToggleButtonSize)
    static let pageHorizontalPadding = CGFloat(MacUIShellLayout.pageHorizontalPadding)
    static let taskRowVerticalPadding = CGFloat(MacUIShellLayout.taskRowVerticalPadding)
    static let detailPadding = CGFloat(MacUIShellLayout.detailPadding)
    static let navigationRowHeight = CGFloat(MacUIShellLayout.navigationRowHeight)
    static let taskRowCompletionControlSize = CGFloat(
        MacUITaskRowLayout.completionControlSize
    )
    static let taskRowAccessorySpacing = CGFloat(MacUITaskRowLayout.accessorySpacing)
    static let calendarDetailTitlePointSize = CGFloat(
        MacUICalendarDetailRowLayout.titlePointSize
    )
    static let calendarDetailMetadataPointSize = CGFloat(
        MacUICalendarDetailRowLayout.metadataPointSize
    )
    static let calendarDetailHorizontalPadding = CGFloat(
        MacUICalendarDetailRowLayout.horizontalPadding
    )
    static let calendarDetailVerticalPadding = CGFloat(
        MacUICalendarDetailRowLayout.verticalPadding
    )
    static let futurePlanMetadataSpacing = CGFloat(
        MacUIFuturePlanDetailLayout.metadataSpacing
    )
    static let ideasComposerCornerRadius = CGFloat(
        MacUIIdeasPageLayout.composerCornerRadius
    )
    static let ideasComposerFilterSpacing = CGFloat(
        MacUIIdeasPageLayout.composerFilterSpacing
    )
    static let ideasTimelineSectionSpacing = CGFloat(
        MacUIIdeasPageLayout.timelineSectionSpacing
    )
    static let ideasSectionHeaderBottomPadding = CGFloat(
        MacUIIdeasPageLayout.sectionHeaderBottomPadding
    )
    static let ideasCardHorizontalPadding = CGFloat(
        MacUIIdeasPageLayout.cardHorizontalPadding
    )
    static let ideasCardVerticalPadding = CGFloat(
        MacUIIdeasPageLayout.cardVerticalPadding
    )
    static let ideasCardMetadataSpacing = CGFloat(
        MacUIIdeasPageLayout.cardMetadataSpacing
    )

    static let detailTitleDescriptionSpacing = CGFloat(
        MacUIDetailEditorLayout.titleDescriptionSpacing
    )
    static let detailTitleMinimumHeight = CGFloat(
        MacUIDetailEditorLayout.titleHeight.lowerBound
    )
    static let detailTitleMaximumHeight = CGFloat(
        MacUIDetailEditorLayout.titleHeight.upperBound
    )
    static let detailDescriptionMinimumHeight = CGFloat(
        MacUIDetailEditorLayout.descriptionHeight.lowerBound
    )
    static let detailDescriptionMaximumHeight = CGFloat(
        MacUIDetailEditorLayout.descriptionHeight.upperBound
    )
    static let detailHorizontalTextInset = CGFloat(
        MacUIDetailEditorLayout.horizontalTextInset
    )
    static let detailVerticalTextInset = CGFloat(
        MacUIDetailEditorLayout.verticalTextInset
    )
    static let detailLineFragmentPadding = CGFloat(
        MacUIDetailEditorLayout.lineFragmentPadding
    )

    static let paneToggleChevronSize = CGFloat(MacUIIconMetrics.paneToggleChevronSize)
    static let navigationIconSize = CGFloat(MacUIIconMetrics.navigationSize)
    private static let dayHeaderDateBasePointSize = CGFloat(20)

    static var dayHeaderDateFont: Font {
        .system(
            size: compactPointSize(dayHeaderDateBasePointSize),
            weight: .semibold
        )
    }

    static var dayHeaderDateMeasurementFont: NSFont {
        .monospacedDigitSystemFont(
            ofSize: compactPointSize(dayHeaderDateBasePointSize),
            weight: .semibold
        )
    }

    static let compactEditorPointSize = CGFloat(MacUITypographyMetrics.compactEditorPointSize)
    static let compactEditorVerticalInset = CGFloat(
        MacUITypographyMetrics.compactEditorVerticalInset
    )
    static let zhulongConversationContentMaxWidth = CGFloat(
        MacUIZhulongConversationLayout.contentMaxWidth
    )
    static let zhulongConversationMessageSpacing = CGFloat(
        MacUIZhulongConversationLayout.messageSpacing
    )
    static let zhulongConversationAssistantBodyPointSize = CGFloat(
        MacUIZhulongConversationLayout.assistantBodyPointSize
    )
    static let zhulongConversationUserBodyPointSize = CGFloat(
        MacUIZhulongConversationLayout.userBodyPointSize
    )
    static let zhulongConversationUserBubbleMaxWidth = CGFloat(
        MacUIZhulongConversationLayout.userBubbleMaxWidth
    )
    static let zhulongConversationUserBubbleCornerRadius = CGFloat(
        MacUIZhulongConversationLayout.userBubbleCornerRadius
    )
    static let zhulongConversationComposerMinimumHeight = CGFloat(
        MacUIZhulongConversationLayout.composerMinimumHeight
    )
    static let zhulongConversationComposerEditorHeight = CGFloat(
        MacUIZhulongConversationLayout.composerEditorHeight
    )
    static let zhulongConversationComposerCornerRadius = CGFloat(
        MacUIZhulongConversationLayout.composerCornerRadius
    )
    static let zhulongConversationComposerBodyPointSize = CGFloat(
        MacUIZhulongConversationLayout.composerBodyPointSize
    )
    static let zhulongConversationComposerHorizontalInset = CGFloat(
        MacUIZhulongConversationLayout.composerHorizontalInset
    )
    static let zhulongConversationComposerVerticalInset = CGFloat(
        MacUIZhulongConversationLayout.composerVerticalInset
    )

    static func compactPointSize(_ baseSize: CGFloat) -> CGFloat {
        CGFloat(MacUITypographyMetrics.compactPointSize(Double(baseSize)))
    }
}

extension Font {
    static func noonmarkSystem(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(
            size: NoonmarkVisualMetrics.compactPointSize(size),
            weight: weight,
            design: design
        )
    }

    static func noonmarkCustom(_ name: String, size: CGFloat) -> Font {
        .custom(name, size: NoonmarkVisualMetrics.compactPointSize(size))
    }

    static func noonmarkRenderedSystem(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: size, weight: weight, design: design)
    }
}

extension NSFont {
    static func noonmarkSystemFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        .systemFont(
            ofSize: NoonmarkVisualMetrics.compactPointSize(size),
            weight: weight
        )
    }
}
