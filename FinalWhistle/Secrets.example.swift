// Template for Secrets.swift. Copy this file to Secrets.swift and
// fill in the real values. Secrets.swift is gitignored and never
// committed — sim.sh creates an empty one if it is missing, so a
// fresh clone still builds. With an empty key, pfp upload reports
// "not configured" instead of failing the build.
enum Secrets {
    /// API key for the Final Whistle pfp endpoint on Castrater
    /// Storage (see docs/pfp-upload-api.md). Identifies the app;
    /// the FID's signer signature is what authorizes an upload for
    /// a given FID.
    static let pfpAPIKey = ""
}
