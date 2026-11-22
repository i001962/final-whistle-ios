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
///
/// Native feel: the editor is focused the moment the sheet appears, so
/// the keyboard is already up and the user types straight away — no
/// second tap into a panel. The quoted/replied-to cast is a compact
/// preview above the editor, never a panel the editor hides behind.
struct ComposeView: View {
    @EnvironmentObject private var identity: IdentityStore
    @Environment(\.dismiss) private var dismiss
    let parent: Cast?
    let quoted: Cast?
    /// Called after a successful post/reply/quote, before dismissing, so
    /// the caller can refresh the feed and show the new cast at the top.
    /// It receives the new cast's hash: the node can take a few seconds
    /// to index a fresh cast, so the caller polls until that hash shows
    /// up instead of refreshing once and missing it.
    var onPosted: ((String) -> Void)? = nil

    init(parent: Cast? = nil, quoted: Cast? = nil, onPosted: ((String) -> Void)? = nil) {
        self.parent = parent
        self.quoted = quoted
        self.onPosted = onPosted
    }

    @State private var text = ""
    @State private var linkField = ""
    @State private var isPosting = false
    @State private var error: String?
    @FocusState private var editorFocused: Bool

    private let maxLength = 320

    /// The link field is optional; when it holds a URL it is attached
    /// as a link embed, so the feed renders it as a preview card. The
    /// link does not count toward the 320 characters — it travels as
    /// an embed, not as text.
    private var trimmedLink: String {
        linkField.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var linkError: String? {
        guard !trimmedLink.isEmpty else { return nil }
        guard let url = URL(string: trimmedLink), url.scheme == "https", url.host != nil else {
            return "That link needs to be a full https:// address."
        }
        return nil
    }

    /// Every https URL in the text, in order, deduped. A pasted link
    /// becomes an embed on its own — the user does not have to use the
    /// link field or know what an embed is.
    private func linkURLs(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var urls: [String] = []
        for match in detector.matches(in: text, options: [], range: range) {
            guard let urlRange = Range(match.range, in: text) else { continue }
            let urlString = String(text[urlRange])
            guard let url = URL(string: urlString), url.scheme == "https", url.host != nil,
                  !urls.contains(urlString) else { continue }
            urls.append(urlString)
        }
        return urls
    }

    private var title: String {
        if parent != nil { return "Reply" }
        if quoted != nil { return "Quote repost" }
        return "New post"
    }

    private var placeholder: String {
        if parent != nil { return "Post your reply" }
        if quoted != nil { return "Add your take…" }
        return "What's happening in football?"
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
                            .lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    // Top-level posts land in /football, not the global feed.
                    Label("Posting to /football", systemImage: "sportscourt")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.fwAccentSoft)
                }

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.body)
                        .focused($editorFocused)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(title)
                }
                .contentShape(Rectangle())
                .onTapGesture { editorFocused = true }

                if let quoted {
                    // The quoted cast sits BELOW your words, as an
                    // attachment, not above them: above reads as a reply
                    // to it, below reads as a quote of it. That is the
                    // visual language every other client uses, and the
                    // "Quoting" label makes it unmistakable.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Quoting @\(quoted.author.displayUsername)", systemImage: "arrow.2.squarepath")
                            .font(.footnote)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.fwAccentSoft)
                        Text(quoted.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.fwPanelSoft, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.fwLine, lineWidth: 1))
                }

                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(Color.fwMuted)
                    TextField("Add a link (optional)", text: $linkField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 12))
                if let linkError {
                    Text(linkError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

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
                                  || text.count > maxLength || isPosting || linkError != nil)
                }
                // No keyboard Done button: it only hid the keyboard, so
                // the sheet stayed open and Cancel was the only real exit
                // — two dismiss-looking controls for one empty editor.
                // Cancel (top left) is now the single way out; swiping
                // the sheet down also dismisses it.
            }
            .onAppear {
                // The sheet animation has to finish before the keyboard
                // will take focus; a short delay is the standard way.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    editorFocused = true
                }
            }
        }
    }

    private func post() async {
        if linkError != nil { return }
        isPosting = true
        error = nil
        defer { isPosting = false }
        do {
            // Gather link candidates: the explicit link field first,
            // then every URL in the text, in order. The embed budget
            // is 2 total; a quote already takes 1, so a quote leaves
            // room for 1 link and a plain post or reply leaves room
            // for 2. When the budget is tight the explicit link wins
            // and the text URLs past the budget stay as text. Every
            // link that is attached is removed from the text, so the
            // post does not show the URL as text above the picture
            // or card.
            var candidates: [String] = []
            if !trimmedLink.isEmpty {
                candidates.append(trimmedLink)
            }
            for url in linkURLs(in: text) where !candidates.contains(url) {
                candidates.append(url)
            }
            let linkBudget = quoted != nil ? 1 : 2
            let links = Array(candidates.prefix(linkBudget))
            var sendText = text
            for link in links {
                sendText = sendText.replacingOccurrences(of: link, with: "")
            }
            sendText = sendText.trimmingCharacters(in: .whitespacesAndNewlines)
            sendText = sendText.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            let hash: String
            if let parent {
                hash = try await identity.reply(to: parent, text: sendText, linkURLs: links)
            } else if let quoted {
                hash = try await identity.quote(cast: quoted, text: sendText, linkURLs: links)
            } else {
                hash = try await identity.post(text: sendText, linkURLs: links)
            }
            // Success: back to the feed at once. The feed refreshes via
            // onPosted, so the new cast is at the top when it lands.
            onPosted?(hash)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
