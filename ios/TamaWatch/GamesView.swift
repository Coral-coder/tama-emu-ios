import SwiftUI

/// The games the phone sent; tap one to play it.
struct GamesView: View {
  @EnvironmentObject var library: WatchLibrary
  @ObservedObject var console = Console.shared

  var body: some View {
    NavigationStack {
      List {
        if library.games.isEmpty {
          Text("Open a game on your iPhone, then ⋯ → Play on Apple Watch.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        ForEach(library.games) { g in
          NavigationLink(value: g.id) {
            Text(g.name.replacingOccurrences(of: "Tamagotchi Paradise · ", with: ""))
          }
        }
        if !library.status.isEmpty {
          Text(library.status).font(.caption2).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Tama")
      .navigationDestination(for: String.self) { id in
        if let g = library.games.first(where: { $0.id == id }) {
          GameView(game: g)
        }
      }
    }
  }
}

/// The game, full screen: the picture, ghost A / B / C and push buttons over it, the crown as the dial.
struct GameView: View {
  let game: WatchGame
  @ObservedObject var console = Console.shared
  @State private var crown: Double = 0
  @State private var lastCrown: Double = 0
  @State private var showKeys = true
  @State private var showMenu = false
  @State private var note = ""

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .bottom) {
        Color.black
        if let im = console.image {
          Image(decorative: im, scale: 1)
            .resizable()
            .interpolation(.none)
            .aspectRatio(1, contentMode: .fit)
            .frame(width: geo.size.width, height: geo.size.height)
        } else if let e = console.error {
          Text(e).font(.footnote).multilineTextAlignment(.center)
        } else {
          ProgressView()
        }
        VStack {
          HStack {
            Spacer()
            Button { Console.shared.releaseAll(); showMenu = true } label: {
              Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 22)
                .background(Capsule().fill(Color.white.opacity(0.22)))
            }
            .buttonStyle(.plain)
            .padding(.top, 4).padding(.trailing, 6)
          }
          Spacer()
        }
        if showMenu {
          ScrollView {
            VStack(spacing: 6) {
              MenuRow(title: "Feed") { note = console.care(1) ? "Fed" : "No pet yet" }
              MenuRow(title: "Play") { note = console.care(2) ? "Happy" : "No pet yet" }
              MenuRow(title: "Cure") { note = console.care(4) ? "Cured" : "No pet yet" }
              MenuRow(title: "Reset button") { console.reset(); showMenu = false }
              MenuRow(title: showKeys ? "Hide buttons" : "Show buttons") { showKeys.toggle(); showMenu = false }
              MenuRow(title: "Back to the game") { showMenu = false }
              if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(8)
          }
          .background(Color.black.opacity(0.85))
          .zIndex(2)
        }
        if showKeys && !showMenu {
          HStack(spacing: 6) {
            GhostKey(label: "A", pin: Console.pinA)
            GhostKey(label: "B", pin: Console.pinB)
            GhostKey(label: "C", pin: Console.pinC)
            GhostKey(label: "●", pin: Console.pinWheel)
          }
          .padding(.bottom, 2)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture(count: 2) { showKeys.toggle() }
    }
    .ignoresSafeArea()
    .focusable()
    .digitalCrownRotation($crown, from: -1_000_000, through: 1_000_000, by: 1, sensitivity: .medium, isContinuous: true, isHapticFeedbackEnabled: true)
    .onChange(of: crown) { v in
      // one wheel step per crown detent
      var d = (v - lastCrown).rounded()
      lastCrown += d
      while d >= 1 { console.turn(true); d -= 1 }
      while d <= -1 { console.turn(false); d += 1 }
    }
    .onAppear { console.play(game) }
    .onDisappear { console.stop() }
    .navigationBarBackButtonHidden(false)
  }
}

/// A see-through button over the screen; held while the finger is down.
struct GhostKey: View {
  let label: String
  let pin: UInt32
  @State private var down = false

  var body: some View {
    Text(label)
      .font(.system(size: 15, weight: .bold, design: .rounded))
      .frame(width: 36, height: 36)
      .background(Circle().fill(Color.white.opacity(down ? 0.55 : 0.22)))
      .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
      .foregroundStyle(.white)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if !down {
              down = true
              Console.shared.press(pin)
            }
          }
          .onEnded { _ in
            down = false
            Console.shared.release(pin)
          }
      )
      .onDisappear {
        if down { Console.shared.release(pin); down = false }
      }
  }
}

/// A row of the in-game menu.
struct MenuRow: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.18)))
    }
    .buttonStyle(.plain)
  }
}
