import SwiftUI

/// Final Whistle: a football-first Hypersnap client for iPhone.
///
/// Free Apple Developer team, mobile only. No push notifications, no iCloud,
/// no Sign in with Apple. Identity is one or more Hypersnap FIDs on this
/// phone: the user either brings an existing FID plus its Ed25519 signer
/// seed, or creates a fresh native FID in the app. Each FID has its own
/// custody key, kept in the iOS Keychain and gated by Face ID / passcode.
/// Keys live only in the Keychain, never in files, and signing out never
/// deletes them.
@main
struct FinalWhistleApp: App {
    @StateObject private var identity = IdentityStore()
    @StateObject private var feed = FeedStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(identity)
                .environmentObject(feed)
                // final-whistle.app is dark-only: near-black navy, lime
                // highlights, magenta primary buttons (see Theme.swift).
                .preferredColorScheme(.dark)
                .tint(Color.fwAccent)
        }
    }
}
