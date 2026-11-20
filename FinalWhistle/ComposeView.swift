import SwiftUI

/// Compose a new cast, a reply, or a quoted repost. Farcaster casts are
/// at most 320 characters. @username tokens in the text are resolved to
/// FIDs and encoded per the mention rule when posting.
///
/// A top-level post goes into the /football channel (parent_url) and the
/// sheet closes itself on success, so the user lands back on the feed and
/// the feed refreshes. A quoted repost is a top-level cast into the same
/// channel carrying the quoted cast as an embed (Quilcast's post() with
/// quote) — there is no plain recast in this app.
struct ComposeView: View {
    @EnvironmentObject private var identity: IdentityStore
    @Environment(\.dismiss) private var dismiss
    let parent: Cast?
    let quoted: Cast?
    /// Called after a successful post/reply/quote, before dismissing, so
    /// the caller can refresh the feed and show the new cast at the top.
    var onPosted: (() -> Void)? = nil

    init(parent: Cast? = nil, quoted: Cast? = nil, onPosted: (() -> Void)? = nil) {
        self.parent = parent
        self.quoted = quoted
        self.onPosted = onPosted
    }

    @State private var text = ""
    @State private var isPosting = false
    @State private var error: String?

    private let maxLength = 320

    private var title: String {
        if parent != nil { return "Reply" }
        if quoted != nil { return "Quote repost" }
        return "New post"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let parent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replying to @\(parent.author.displayUsername)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(parent.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    // Top-level posts land in /football, not the global feed.
                    Label("Posting to /football", systemImage: "sportscourt")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.fwAccentSoft)
                }

                if let quoted {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("@\(quoted.author.displayUsername)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.fwText)
                        Text(quoted.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    .padding()
                    .background(Color.fwPanelSoft, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.fwLine, lineWidth: 1))
                }

                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 160)
                    .accessibilityLabel(title)

                HStack {
                    Text("\(text.count)/\(maxLength)")
                        .font(.footnote)
                        .foregroundStyle(text.count > maxLength ? .red : .secondary)
                    Spacer()
                    if isPosting { ProgressView() }
                }

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                // No Spacer: the footer sits directly under the editor, so
                // nothing is pushed off the bottom of the sheet.
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { Task { await post() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || text.count > maxLength || isPosting)
                }
            }
        }
    }

    private func post() async {
        isPosting = true
        error = nil
        defer { isPosting = false }
        do {
            if let parent {
                _ = try await identity.reply(to: parent, text: text)
            } else if let quoted {
                _ = try await identity.quote(cast: quoted, text: text)
            } else {
                _ = try await identity.post(text: text)
            }
            // Success: back to the feed at once. The feed refreshes via
            // onPosted, so the new cast is at the top when it lands.
            onPosted?()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
