import SwiftData
import SwiftUI

@main
struct AlbumFinderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: RecommendationFolder.self)
    }
}
