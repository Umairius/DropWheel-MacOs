import AppKit

/// DropWheel has no menu bar of its own (it's a menu-bar agent), but keyboard shortcuts in its windows
/// (⌘V in a text field, ⌘Z in the sign window, ⌘W, zoom) are routed through the main menu.
/// This installs a minimal one. It never shows up on screen.
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit DropWheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: "View")
        viewItem.submenu = view
        view.addItem(withTitle: "Zoom In", action: Selector(("zoomIn:")), keyEquivalent: "=")
        view.addItem(withTitle: "Zoom Out", action: Selector(("zoomOut:")), keyEquivalent: "-")
        view.addItem(withTitle: "Fit Width", action: Selector(("zoomFit:")), keyEquivalent: "0")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let win = NSMenu(title: "Window")
        windowItem.submenu = win
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = main
    }
}
