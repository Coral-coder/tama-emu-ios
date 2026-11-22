import SwiftUI

/// Tama on the Apple Watch: the same native Paradise emulator as the phone, the Digital Crown as
/// the dial, ghost buttons over the screen. Games and their saves come from the phone and go back
/// to it, so the pet lives on whichever one is playing.
@main
struct TamaWatchApp: App {
  @StateObject private var library = WatchLibrary.shared
  @Environment(\.scenePhase) private var phase

  init() {
    PhoneLink.shared.start()
  }

  var body: some Scene {
    WindowGroup {
      GamesView()
        .environmentObject(library)
    }
    .onChange(of: phase) { p in
      Console.shared.scene(active: p == .active)
    }
  }
}
