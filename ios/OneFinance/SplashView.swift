import SwiftUI

/// The One Finance infinity mark: one path, one gradient across the whole shape (so the crossing
/// is seamless), glow added once to the whole mark. From mockups/logo/one-finance-mark.svg.
struct OneFinanceMark: View {
    var width: CGFloat = 207
    var glow = true

    private static let viewBox = CGRect(x: -248, y: -74.6, width: 496, height: 149.2)

    var body: some View {
        MarkShape()
            .fill(LinearGradient(stops: [.init(color: Color(hex: 0xC49BFF), location: 0),
                                         .init(color: Color(hex: 0xA45CFF), location: 0.35),
                                         .init(color: Color(hex: 0x8A2BE2), location: 1)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))  // = x1,y1 → x2,y2 of the viewBox
            .frame(width: width, height: width * Self.viewBox.height / Self.viewBox.width)
            .shadow(color: glow ? Theme.vib400.opacity(0.65) : .clear, radius: 10)
            .accessibilityLabel("One Finance")
    }

    struct MarkShape: Shape {
        private static let path: Path = {
            var p = Path()
            let scanner = Scanner(string: OneFinanceMarkData.d)
            scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\t")
            while !scanner.isAtEnd, let cmd = scanner.scanCharacter() {
                switch cmd {
                case "M", "L":
                    guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else { return p }
                    if cmd == "M" { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                case "Z", "z": p.closeSubpath()
                default: return p
                }
            }
            return p
        }()

        func path(in rect: CGRect) -> Path {
            let box = OneFinanceMark.viewBox
            let scale = min(rect.width / box.width, rect.height / box.height)
            return Self.path.applying(CGAffineTransform(translationX: -box.minX, y: -box.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        }
    }
}

/// Cold-launch animation (2.0 s): the wordmark from the static launch screen holds 0.3 s, "One" and
/// "Finance" slide apart and fade (0.6 s), the mark and "Welcome, <first name>" fade in from 0.96
/// scale (0.6 s), hold 0.2 s, then cross-fade to Home (0.3 s). Home loads underneath meanwhile.
/// Tap to skip. Reduce Motion: a plain cross-fade. Face ID lock: wordmark → Face ID → welcome → Home.
struct SplashView: View {
    let needsUnlock: Bool
    let onUnlocked: () -> Void
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var split = false
    @State private var welcome = false
    @State private var leaving = false
    @State private var firstName: String?
    @State private var waitingForFaceID = false
    @State private var faceIDNote: String?
    @State private var done = false

    var body: some View {
        ZStack {
            Color(hex: 0x050408).ignoresSafeArea()
            // Wordmark: the same two images the static launch screen joins, centred the same way.
            HStack(spacing: 0) {
                Image("WordOne").offset(x: split && !reduceMotion ? -130 : 0)
                Image("WordFinance").offset(x: split && !reduceMotion ? 130 : 0)
            }
            .opacity(split ? 0 : 1)
            // Welcome
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.vib400.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: 160))
                    .frame(width: 320, height: 320)
                VStack(spacing: 6) {
                    OneFinanceMark(width: 207).padding(.bottom, 20)
                    if let firstName {
                        Text("Welcome,").font(.system(size: 20)).foregroundStyle(Theme.muted)
                        Text(firstName).font(.system(size: 40, weight: .bold)).tracking(-0.8).foregroundStyle(Theme.text)
                    } else {
                        Text("Welcome").font(.system(size: 40, weight: .bold)).tracking(-0.8).foregroundStyle(Theme.text)
                    }
                }
            }
            .opacity(welcome ? 1 : 0)
            .scaleEffect(welcome || reduceMotion ? 1 : 0.96)
            if waitingForFaceID, let faceIDNote {
                VStack {
                    Spacer()
                    Text(faceIDNote).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Button("Unlock with Face ID") { Task { await unlock() } }
                        .buttonStyle(.borderedProminent).tint(Theme.vib500).padding(.top, 8).padding(.bottom, 80)
                }
            }
        }
        .ignoresSafeArea()
        .opacity(leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !waitingForFaceID { finish(animated: true) } }  // tap to skip
        .task { await run() }
        .task { firstName = await Self.loadFirstName() }
    }

    private func run() async {
        try? await Task.sleep(for: .seconds(0.3))
        if needsUnlock {
            waitingForFaceID = true
            await unlock()
            while waitingForFaceID { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard !done else { return }
        withAnimation(.easeIn(duration: 0.6)) { split = true }
        try? await Task.sleep(for: .seconds(0.6))
        guard !done else { return }
        withAnimation(.easeOut(duration: 0.6)) { welcome = true }
        try? await Task.sleep(for: .seconds(0.6 + 0.2))
        finish(animated: true)
    }

    private func unlock() async {
        let result = await AppLock.authenticate(reason: "Unlock One Finance")
        switch result {
        case .success, .unavailable:
            waitingForFaceID = false
            onUnlocked()
        case .cancelled: faceIDNote = "One Finance is locked."
        case .failed: faceIDNote = "Face ID didn't match. Try again."
        }
    }

    private func finish(animated: Bool) {
        guard !done else { return }
        done = true
        withAnimation(.easeInOut(duration: animated ? 0.3 : 0)) { leaving = true }
        Task {
            try? await Task.sleep(for: .seconds(animated ? 0.3 : 0))
            onFinished()
        }
    }

    /// "Welcome, William": the first word of the profile name, if the backend answers in time.
    private static func loadFirstName() async -> String? {
        guard let s: AppSettings = try? await APIClient().get("settings") else { return nil }
        let first = s.profileName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? nil : first
    }
}
