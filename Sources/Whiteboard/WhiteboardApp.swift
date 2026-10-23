import SwiftUI

@main
struct WhiteboardApp: App {
    @State private var store: BoardStore = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "WBSamples") { return BoardStore.preview() }   // -WBSamples YES: sample boards
        if Screenshots.active { return Screenshots.makeStore() }                                 // -WBShots: see Screenshots
        #endif
        return BoardStore()
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
