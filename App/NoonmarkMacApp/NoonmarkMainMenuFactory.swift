import AppKit

@MainActor
@objc protocol NoonmarkMenuCommandTarget: AnyObject {
    func showAboutAction(_ sender: Any?)
    func showSettingsAction(_ sender: Any?)
    func showQuickEntryAction(_ sender: Any?)
    func showSearchAction(_ sender: Any?)
    func exportDataAction(_ sender: Any?)
    func importDataAction(_ sender: Any?)
    func undoAction(_ sender: Any?)
    func redoAction(_ sender: Any?)
    func selectAllAction(_ sender: Any?)
    func toggleSidebarAction(_ sender: Any?)
    func toggleDetailRailAction(_ sender: Any?)
    func showMainWindowAction(_ sender: Any?)
    func showHelpAction(_ sender: Any?)
}

enum NoonmarkMenuAction {
    static let showAbout = #selector(NoonmarkMenuCommandTarget.showAboutAction(_:))
    static let showSettings = #selector(NoonmarkMenuCommandTarget.showSettingsAction(_:))
    static let showQuickEntry = #selector(NoonmarkMenuCommandTarget.showQuickEntryAction(_:))
    static let showSearch = #selector(NoonmarkMenuCommandTarget.showSearchAction(_:))
    static let exportData = #selector(NoonmarkMenuCommandTarget.exportDataAction(_:))
    static let importData = #selector(NoonmarkMenuCommandTarget.importDataAction(_:))
    static let undo = #selector(NoonmarkMenuCommandTarget.undoAction(_:))
    static let redo = #selector(NoonmarkMenuCommandTarget.redoAction(_:))
    static let selectAll = #selector(NoonmarkMenuCommandTarget.selectAllAction(_:))
    static let toggleSidebar = #selector(NoonmarkMenuCommandTarget.toggleSidebarAction(_:))
    static let toggleDetailRail = #selector(NoonmarkMenuCommandTarget.toggleDetailRailAction(_:))
    static let showMainWindow = #selector(NoonmarkMenuCommandTarget.showMainWindowAction(_:))
    static let showHelp = #selector(NoonmarkMenuCommandTarget.showHelpAction(_:))
}

@MainActor
enum NoonmarkMainMenuFactory {
    static func make(copy: AppCopy, target: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: copy.appName)
        addTopLevelMenu(appMenu, title: copy.appName, to: mainMenu)
        addItem(copy.aboutApp, action: NoonmarkMenuAction.showAbout, target: target, to: appMenu)
        appMenu.addItem(.separator())
        addItem(
            copy.settingsCommand,
            action: NoonmarkMenuAction.showSettings,
            key: ",",
            target: target,
            to: appMenu
        )
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: copy.services, action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: copy.services)
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        addItem(
            copy.hideApp,
            action: #selector(NSApplication.hide(_:)),
            key: "h",
            target: NSApp,
            to: appMenu
        )
        addItem(
            copy.hideOthers,
            action: #selector(NSApplication.hideOtherApplications(_:)),
            key: "h",
            modifiers: [.command, .option],
            target: NSApp,
            to: appMenu
        )
        addItem(
            copy.showAll,
            action: #selector(NSApplication.unhideAllApplications(_:)),
            target: NSApp,
            to: appMenu
        )
        appMenu.addItem(.separator())
        addItem(
            copy.quitApp,
            action: #selector(NSApplication.terminate(_:)),
            key: "q",
            target: NSApp,
            to: appMenu
        )

        let fileMenu = NSMenu(title: copy.fileMenu)
        addTopLevelMenu(fileMenu, title: copy.fileMenu, to: mainMenu)
        addItem(
            copy.quickEntryCommand,
            action: NoonmarkMenuAction.showQuickEntry,
            key: "n",
            target: target,
            to: fileMenu
        )
        fileMenu.addItem(.separator())
        addItem(copy.exportJSON, action: NoonmarkMenuAction.exportData, target: target, to: fileMenu)
        addItem(
            copy.importData,
            action: NoonmarkMenuAction.importData,
            key: "i",
            modifiers: [.command, .shift],
            target: target,
            to: fileMenu
        )
        fileMenu.addItem(.separator())
        addItem(
            copy.closeWindow,
            action: #selector(NSWindow.performClose(_:)),
            key: "w",
            target: nil,
            to: fileMenu
        )

        let editMenu = NSMenu(title: copy.editMenu)
        addTopLevelMenu(editMenu, title: copy.editMenu, to: mainMenu)
        addItem(
            copy.undo,
            action: NoonmarkMenuAction.undo,
            key: "z",
            target: target,
            to: editMenu
        )
        addItem(
            copy.redo,
            action: NoonmarkMenuAction.redo,
            key: "Z",
            target: target,
            to: editMenu
        )
        editMenu.addItem(.separator())
        addItem(copy.cut, action: #selector(NSText.cut(_:)), key: "x", target: nil, to: editMenu)
        addItem(copy.copy, action: #selector(NSText.copy(_:)), key: "c", target: nil, to: editMenu)
        addItem(copy.paste, action: #selector(NSText.paste(_:)), key: "v", target: nil, to: editMenu)
        addItem(copy.delete, action: #selector(NSText.delete(_:)), target: nil, to: editMenu)
        addItem(
            copy.selectAll,
            action: NoonmarkMenuAction.selectAll,
            key: "a",
            target: target,
            to: editMenu
        )
        editMenu.addItem(.separator())
        let findMenu = NSMenu(title: copy.findMenu)
        addSubmenu(findMenu, title: copy.findMenu, to: editMenu)
        addTextFinderItem(
            copy.find,
            finderAction: .showFindInterface,
            key: "f",
            to: findMenu
        )
        addTextFinderItem(
            copy.findNext,
            finderAction: .nextMatch,
            key: "g",
            to: findMenu
        )
        addTextFinderItem(
            copy.findPrevious,
            finderAction: .previousMatch,
            key: "g",
            modifiers: [.command, .shift],
            to: findMenu
        )

        let spellingMenu = NSMenu(title: copy.spellingAndGrammar)
        addSubmenu(spellingMenu, title: copy.spellingAndGrammar, to: editMenu)
        addItem(
            copy.showSpellingAndGrammar,
            action: #selector(NSTextView.showGuessPanel(_:)),
            key: ":",
            target: nil,
            to: spellingMenu
        )
        addItem(
            copy.checkSpelling,
            action: #selector(NSTextView.checkSpelling(_:)),
            key: ";",
            target: nil,
            to: spellingMenu
        )
        spellingMenu.addItem(.separator())
        addItem(
            copy.checkSpellingWhileTyping,
            action: #selector(NSTextView.toggleContinuousSpellChecking(_:)),
            target: nil,
            to: spellingMenu
        )
        addItem(
            copy.checkGrammarWithSpelling,
            action: #selector(NSTextView.toggleGrammarChecking(_:)),
            target: nil,
            to: spellingMenu
        )
        addItem(
            copy.correctSpellingAutomatically,
            action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)),
            target: nil,
            to: spellingMenu
        )

        editMenu.addItem(.separator())
        addItem(
            copy.searchCommand,
            action: NoonmarkMenuAction.showSearch,
            key: "f",
            modifiers: [.command, .shift],
            target: target,
            to: editMenu
        )

        let viewMenu = NSMenu(title: copy.viewMenu)
        addTopLevelMenu(viewMenu, title: copy.viewMenu, to: mainMenu)
        addItem(
            copy.collapseSidebar,
            action: NoonmarkMenuAction.toggleSidebar,
            key: "s",
            modifiers: [.command, .control],
            target: target,
            to: viewMenu
        )
        addItem(
            copy.collapseDetailRail,
            action: NoonmarkMenuAction.toggleDetailRail,
            key: "i",
            modifiers: [.command, .option],
            target: target,
            to: viewMenu
        )

        let windowMenu = NSMenu(title: copy.windowMenu)
        addTopLevelMenu(windowMenu, title: copy.windowMenu, to: mainMenu)
        addItem(
            copy.minimize,
            action: #selector(NSWindow.performMiniaturize(_:)),
            key: "m",
            target: nil,
            to: windowMenu
        )
        addItem(copy.zoom, action: #selector(NSWindow.performZoom(_:)), target: nil, to: windowMenu)
        addItem(
            copy.enterFullScreen,
            action: #selector(NSWindow.toggleFullScreen(_:)),
            key: "f",
            modifiers: [.command, .control],
            target: nil,
            to: windowMenu
        )
        windowMenu.addItem(.separator())
        addItem(
            copy.mainWindowCommand,
            action: NoonmarkMenuAction.showMainWindow,
            target: target,
            to: windowMenu
        )
        addItem(
            copy.bringAllToFront,
            action: #selector(NSApplication.arrangeInFront(_:)),
            target: NSApp,
            to: windowMenu
        )
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: copy.helpMenu)
        addTopLevelMenu(helpMenu, title: copy.helpMenu, to: mainMenu)
        addItem(
            copy.noonmarkHelp,
            action: NoonmarkMenuAction.showHelp,
            target: target,
            to: helpMenu
        )
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    private static func addTopLevelMenu(
        _ menu: NSMenu,
        title: String,
        to mainMenu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        mainMenu.addItem(item)
    }

    private static func addSubmenu(
        _ submenu: NSMenu,
        title: String,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private static func addTextFinderItem(
        _ title: String,
        finderAction: NSTextFinder.Action,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        to menu: NSMenu
    ) {
        let item = addItem(
            title,
            action: #selector(NSTextView.performTextFinderAction(_:)),
            key: key,
            modifiers: modifiers,
            target: nil,
            to: menu
        )
        item.tag = finderAction.rawValue
    }

    @discardableResult
    private static func addItem(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject?,
        to menu: NSMenu
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        menu.addItem(item)
        return item
    }
}
