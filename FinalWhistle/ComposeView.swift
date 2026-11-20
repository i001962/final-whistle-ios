import SwiftUI

/// Compose a new cast, or reply to a parent cast. Farcaster casts are at
/// most 320 characters. @username tokens in the text are resolved to FIDs
/// and encoded per the mention rule when posting.
///
/// A top-level post goes into the /football channel (parent_url) and the
/// sheet closes itself on success, so the user lands back on the feed and
/// the feed refreshes. The old version stayed open showing the hash at
/// the bottom of the sheet, pushed off-screen by a Spacer, and forced a
/// second tap on Done. That is gone: success means dismiss, nothing else.
struct ComposeView: View {
    @EnvironmentObject private var identity: IdentityStore
    @Environment(\.dismiss) private var dismiss
    let parent: Cast?
    /// Called after a successful post/reply, before dismissing, so the
    /// caller can refresh the feed and show the new cast at the top.
    var onPosted: (() -> Void)? = nil

    @State private var text = ""
    @State private var isPosting = false
    @State private var error: String?

    private let maxLength = 320

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

                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 160)
                    .accessibilityLabel(parent == nil ? "New post" : "Reply")

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
            .navigationTitle(parent == nil ? "New post" : "Reply")
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
