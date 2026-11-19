# Final Whistle for iPhone

A football-first Hypersnap client for iPhone. Classic X/Twitter-style feed, Hypersnap native identity, posting, replies, likes, and recasts. No follows in v1.

- App name: Final Whistle
- Bundle ID: `app.final-whistle`
- Site: https://final-whistle.app/
- Apple team: FREE. Mobile only, the user's own phone. No push notifications, no iCloud, no Sign in with Apple. Free builds stop opening after 7 days, and only 3 free-team apps fit on a phone at once.
- iPhone: iOS 27.2.1. `IPHONEOS_DEPLOYMENT_TARGET` is 26.0, lower than the phone, so it installs.
- Xcode: 26.6 or later, classic project format `project.pbxproj` (works on Xcode 26 and 27). One app target, SwiftUI, Swift 6.0. The earlier `project.xcproj` (Xcode 27.2 JSON) format was removed: Xcode 26 cannot open it.

## What is built in v1

- Feed, read-only, works without an account. Two tabs: Trending (`GET /v2/farcaster/feed/trending`) and Football (`GET /v2/farcaster/cast/search?q=football`). The Football tab is a keyword search, not a live channel feed, so older casts that mention football can appear. Dedup by cast hash, pull to refresh, empty / loading / error states, cached feed shown on launch.
- Bring your FID: enter a FID number and the 32-byte Ed25519 signer seed (hex) from an earlier onboarding. The seed goes only into the Keychain. Verification is real: the user is fetched over HTTP and the signer must appear in `GetSignersByFid` for that FID. If that check cannot run, nothing is stored and no verification is claimed.
- Create a new Hypersnap native FID: fresh secp256k1 custody key + fresh Ed25519 signer generated on the device, PoW mined on device, EIP-712 `HyperNativeOnboard` signed by custody, then a gasless `KeyAdd` authorising the signer. Native FIDs are free, Hypersnap only, start at 4294967296, need no ETH and no rented storage, and do not appear on Warpcast. One custody address gets one FID, custody is immutable in this release, and losing the custody key loses the FID.
- Post, reply, like, recast. All writes are built as Farcaster protobuf messages, hashed with BLAKE3 (first 20 bytes), signed with the Ed25519 signer from the Keychain, and submitted via gRPC `SubmitMessage` to `grpc.castrater.xyz:3383` (plaintext). Reply uses the parent author's FID in `parent_cast_id`, not the caller's own FID. Mentions are encoded per the Farcaster rule: the `@username` token is removed from the stored text, with the FID and byte position in the mentions fields.
- Data: Codable structs as JSON in Application Support, written with `.atomic`, with a version field and a backup of the previous good file. Keys live only in the Keychain, never in UserDefaults, files, logs, or this repo.
- No API keys in the app. `ITSAppUsesNonExemptEncryption` is `NO` (HTTPS + hashing + Keychain only).

## What is NOT built

- Follows, profile editing, threads, notifications, search beyond the Football tab, TestFlight, App Store Connect. Do not upload anything to Apple from this repo.

## Build on the Mac

The Linux machine this was written on has no Xcode and no Swift, so nothing here has been built, run in a simulator, or installed on a phone yet. See "Unverified" below.

1. Install Xcode from the Mac App Store (about 30 GB). The project opens in Xcode 26.6 or later. Open it once and add the iOS platform. Sign in under Xcode, Settings, Apple Accounts.
2. **iOS version warning:** the phone was reported as iOS 27.2.1. Xcode 26.6 ships an iOS 26.x SDK, so it can open this project but it will NOT install onto a 27.2.1 phone. Confirm the phone's real version (Settings, General, About, iOS Version). If it really is 27.2.1, update Xcode to 27.2.1 or newer from the Mac App Store first. Do not raise the deployment target: it stays at 26.0.
3. Clone this repo, open `FinalWhistle.xcodeproj` in Xcode.
4. Select the FinalWhistle target, Signing and Capabilities, pick your free personal team. Do not change the bundle ID (`app.final-whistle`).
5. Resolve packages: Xcode fetches the pinned packages below on first build. Check they resolve before trusting the build.
6. Connect the iPhone by cable, unlock it, tap Trust. Turn on Settings, Privacy and Security, Developer Mode on the phone (it restarts the phone).
7. Run from the repo root, with the phone unlocked:
   ```sh
   ./scripts/phone.sh
   ```
   It builds, installs over the old copy (keeping the app's data), launches, and confirms the app is still running after 5 seconds. Never uninstall to fix a problem: that erases the app's data, including the Keychain keys.
8. After the first install, if iOS asks, trust the developer under Settings, General, VPN and Device Management.

Simulator check (from the repo root, NAME from `xcrun simctl list devices`):

```sh
xcodebuild -scheme FinalWhistle -destination 'platform=iOS Simulator,name=NAME' -derivedDataPath DerivedData.noindex build
xcrun simctl boot "NAME"
xcrun simctl install "NAME" DerivedData.noindex/Build/Products/Debug-iphonesimulator/FinalWhistle.app
xcrun simctl launch "NAME" app.final-whistle
xcrun simctl io "NAME" screenshot shot.png
```

Tests:

```sh
xcodebuild test -scheme FinalWhistle -destination 'platform=iOS Simulator,name=NAME' -derivedDataPath DerivedData.noindex
```

## Swift packages (all pinned exact, verified 19 Nov 2026)

| Package | Version | Use |
| --- | --- | --- |
| grpc/grpc-swift-2 | 2.4.4 | gRPC core, generic unary calls |
| grpc/grpc-swift-nio-transport | 2.11.0 | HTTP/2 transport, `.http2NIOTS`, plaintext |
| 21-DOT-DEV/swift-secp256k1 (P256K) | 0.25.1 | secp256k1 custody keys, recoverable EIP-712 signing |
| krzyzanowskim/CryptoSwift | 1.10.0 | Keccak-256 (`SHA3(variant: .keccak256)`, NOT `.sha3_256`) |
| joshbashed/blake3-swift | 0.2.2 | BLAKE3 message hashes |

SwiftProtobuf is deliberately NOT used: the app hand-encodes the few protobuf messages it needs (`FinalWhistle/Protobuf.swift`, `FinalWhistle/FarcasterMessages.swift`) and calls grpc-swift 2's generic unary API with an identity `Data` serializer. The `.proto` files are vendored in `Protos/` (farcasterorg/hypersnap, `proto/definitions/`). The hand encoding was verified byte-for-byte against the Python protobuf library for CastAdd, Reply, Reaction, KeyAdd, and NativeOnboard; the unit tests pin those vectors.

EIP-712 is hand-encoded on top of P256K + CryptoSwift (no maintained standalone Swift EIP-712 library was found). The signing path is: `P256K.Recovery.PrivateKey.signature(for: Digest)` with a `P256K.HashDigest` built from the 32-byte Keccak digest (its public `init(_ output: [UInt8])` accepts any 32 bytes). Do NOT use the `signature(for: Data)` overload: it SHA-256-hashes the input first, which is wrong for an EIP-712 digest. Signatures are low-S normalised (flipping the recovery id when s is flipped), v is 27 or 28.

BLAKE3 0.2.2 is the weakest pin: a small single-maintainer wrapper over the official C code. The unit test asserts the official BLAKE3 test vector for the empty input on first build. If the wrapper fails to fetch or the vector fails, vendor the official C sources (BLAKE3-team/BLAKE3) as a local SPM C target instead.

## How the Hypersnap pieces fit

- Reads: `https://hypersnap.castrater.xyz` (HTTPS, public, no auth).
- Writes: gRPC `grpc.castrater.xyz:3383`, plaintext, `HubService` (the protos declare no package, so the service is just `HubService`). HTTP write endpoints return 501 by design.
- Farcaster epoch: Unix time minus 1609459200.
- KeyAdd: EIP-712 `Farcaster KeyAdd` v1 chain 1, scopes 1, 2, 3, 4, 5, 6, 11, 12, TTL 30 days, nonce 1 for a first signer, deadline now + 86400 (Farcaster epoch seconds). `SignedKeyRequest` metadata is a single ABI tuple `(uint256,address,bytes,uint256)`, 288 bytes with a leading 0x20 offset word. Four flat fields (256 bytes) are rejected by the node.
- PoW: SHA256 over `hyper.onboard.pow:` + custody (20 bytes) + anchor hash (32 bytes) + nonce (8 bytes big-endian), 22 bits (hash bytes 0 and 1 zero, byte 2 below 4). Gate commitment: SHA256 over `hyper.onboard.pow.commitment:` + nonce + difficulty (4 bytes big-endian).
- Signer TTL is 30 days. After it expires, the app must authorise a new signer from custody (not built in v1: sign out and create a new signer flow is a follow-up).

## Unverified (needs the Mac)

- The Xcode project file (`project.pbxproj`, classic format) has not been opened by Xcode. It was generated from the earlier `project.xcproj` and validated on Linux with the `pbxproj` parser (3 targets, 16 + 1 + 1 sources, 5 + 4 + 0 package products, all settings read back), but `xcodebuild -list` has not run on it. If Xcode reports an error on open, note the exact message; do not guess.
- The test targets (`unit-test` / `ui-test` product types, `TEST_HOST` / `BUNDLE_LOADER` settings) are the least-verified part of the project file. If Xcode rejects them, delete the two test targets in Xcode and re-add them from the template; the app target builds without them.
- Package resolution, Swift compilation, simulator launch, phone install, and every gRPC call from the phone are unverified. The unit-test vectors are verified against Python, but the tests themselves have not run.
- The Football tab uses cast search, which returns older keyword matches as well as recent ones. That is a Hypersnap search behaviour, not a bug in the app, but it means the tab is not a live football feed.
- `GetSignersByFid` verification for a brought FID depends on the node answering gRPC from the phone. If the phone cannot reach `grpc.castrater.xyz:3383`, bringing a FID will fail with a transport error rather than a false verification.

## Repo layout

- `FinalWhistle/` - SwiftUI app, one target, synchronized folder (new files build automatically)
- `FinalWhistleTests/` - unit tests, including byte-exact protobuf / EIP-712 / BLAKE3 vectors
- `FinalWhistleUITests/` - one UI test of the main loop (launch, browse without an account)
- `FinalWhistle.xcodeproj/project.pbxproj` - classic Xcode project file (Xcode 26 and 27)
- `Protos/` - Hypersnap `.proto` files (reference only, not compiled)
- `scripts/phone.sh` - build, install over the old copy, launch, confirm still running
