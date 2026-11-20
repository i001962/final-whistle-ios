import SwiftUI

/// Final Whistle: a football-first Hypersnap client for iPhone.
///
/// Free Apple Developer team, mobile only. No push notifications, no iCloud,
/// no Sign in with Apple. Identity is a Hypersnap native FID: the user either
/// brings an existing FID plus its Ed25519 signer seed, or creates a fresh
/// native FID in the app. Keys live only in the iOS Keychain, never in files.
@main
struct FinalWhistleApp: App {
    @StateObject private var identity = IdentityStore()
    @StateObject private var feed = FeedStore()
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(identity)
                .environmentObject(feed)
                .environmentObject(router)
                // final-whistle.app is dark-only: near-black navy, lime
                // highlights, magenta primary buttons (see Theme.swift).
                .preferredColorScheme(.dark)
                .tint(Color.fwAccent)
        }
    }
}
