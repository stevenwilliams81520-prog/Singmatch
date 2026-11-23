import SwiftUI

@main
struct SingMatchApp: App {
    @StateObject private var store = SongStore()
    @StateObject private var processor = SongProcessor()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(processor)
        }
    }
}
