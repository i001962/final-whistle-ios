import SwiftUI

/// Compose a new cast, or reply to a parent cast. Farcaster casts are at
/// most 320 characters. @username tokens in the text are resolved to FIDs
/// and encoded per the mention rule when posting.
struct ComposeView: View {
    @EnvironmentObject private var identity: IdentityStore
    @Environment(\.dismiss) private var dismiss
    let parent: Cast?

    @State private var text = ""
    @State private var isPosting = false
    @State private var error: String?
    @State private var postedHash: String?

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
                if let postedHash {
                    Text("Posted: \(postedHash)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding()
            .navigationTitle(parent == nil ? "New post" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(postedHash == nil ? "Post" : "Done") {
                        if postedHash != nil { dismiss() } else { Task { await post() } }
                    }
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
                postedHash = try await identity.reply(to: parent, text: text)
            } else {
                postedHash = try await identity.post(text: text)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
