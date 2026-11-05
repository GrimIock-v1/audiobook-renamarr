import SwiftUI

@main
struct AudiobookRenamerApp: App {
    @StateObject private var viewModel = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .accentColor(Color(red: 0.95, green: 0.55, blue: 0.15)) // Audible-ish orange
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .undoRedo) {
                Button("Undo Last Move") {
                    Task { await viewModel.undoLastMove() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!viewModel.canUndoLastMove)
            }
        }
    }
}
