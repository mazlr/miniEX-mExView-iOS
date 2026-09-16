import SwiftUI

@main struct miniEXViewApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene { WindowGroup { ContentView().environmentObject(model) } }
}

