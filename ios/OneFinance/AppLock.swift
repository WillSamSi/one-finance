import LocalAuthentication
import SwiftUI

/// Face ID lock (More → Privacy and security): the app asks for Face ID (or the passcode) when it
/// opens and whenever it comes back from the background.
enum AppLock {
    enum Result { case success, failed, cancelled, unavailable(String) }

    static func authenticate(reason: String) async -> Result {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable("Face ID isn't set up on this device. Set up Face ID or a passcode in Settings first.")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return .cancelled
        } catch {
            return .failed
        }
    }
}

/// Covers the app until Face ID succeeds.
struct LockScreen: View {
    let onUnlock: () -> Void
    @State private var note: String?
    @State private var asking = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "faceid").font(.system(size: 56, weight: .light)).foregroundStyle(Theme.vib300)
                Text("One Finance is locked").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                if let note { Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center) }
                Button { Task { await unlock() } } label: {
                    Text("Unlock with Face ID").font(.system(size: 16, weight: .semibold)).padding(.horizontal, 24).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent).tint(Theme.vib500)
            }
            .padding(32)
        }
        .task { if scenePhase == .active { await unlock() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await unlock() } } }  // ask once the app is back
    }

    private func unlock() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        switch await AppLock.authenticate(reason: "Unlock One Finance") {
        case .success: onUnlock()
        case .cancelled: break
        case .failed: note = "Face ID didn't match. Try again."
        case .unavailable:
            // Face ID and the passcode were removed from the phone after the lock was turned on:
            // there's nothing left to check against, so let the owner in.
            onUnlock()
        }
    }
}
