//
//  bigcsvApp.swift
//  bigcsv
//

import SwiftUI
import AppKit

/// AppKit delegate that catches Finder "Open With" / double-click / drag-onto-Dock
/// opens. These arrive already security-scope-granted by LaunchServices.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // Single-window app: the last URL wins (open replaces the current file).
        if let url = urls.last {
            AppModel.shared.open(url: url)
        }
    }
}

@main
struct bigcsvApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel.shared
    @StateObject private var purchase = PurchaseManager.shared

    var body: some Scene {
        // `Window` (not `WindowGroup`) enforces the single-window free model.
        Window("BigCSV", id: "main") {
            AppShellView()
                .environmentObject(appModel)
                .environmentObject(purchase)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                if purchase.isUnlocked {
                    Text("BigCSV Pro — Unlocked")
                } else {
                    Button("Unlock BigCSV Pro…") { purchase.presentPaywall(.filter) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { appModel.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(appModel.recentFiles) { file in
                        Button(file.name) { appModel.openRecent(file) }
                    }
                    if !appModel.recentFiles.isEmpty {
                        Divider()
                        Button("Clear Menu") { appModel.clearRecents() }
                    }
                }
                .disabled(appModel.recentFiles.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button("Go to Row…") { appModel.showGoToRow = true }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(appModel.document == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { appModel.document?.findBarVisible = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(appModel.document == nil)
                Button("Find Next") { appModel.document?.nextMatch() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(appModel.document?.matchRows.isEmpty ?? true)
                Button("Find Previous") { appModel.document?.previousMatch() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(appModel.document?.matchRows.isEmpty ?? true)
            }
        }
    }
}
