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
    /// Whether the editor has the keyboard. A plain Bool state, not
    /// a FocusState: the WYSIWYG editor is a UITextView, and it
    /// drives focus through this binding.
    @State private var editorFocused = false
    /// Sticker images attached to this post. Picking an emoji from
    /// the tray inserts its shortcode (`:packid:emojiconid:`) into
    /// the text; it does NOT post, and it shows inline in the editor
    /// as its picture, nowhere else. The user writes around it and
    /// hits Post, and the images travel as embeds, derived from the
    /// shortcodes in the text at post time — backspacing an emoji
    /// out of the editor un-attaches it. The embed budget is 2 total
    /// (1 when quoting), shared with links. The shortcode is the
    /// emoji (inline, looked up by pack and emoji id); the image is
    /// the sticker (the embed the shortcode resolves to). The two
    /// are kept separate: the text carries the emoji reference, the
    /// embeds carry the art.
    /// The emoji tray above the editor. Same tray as the room: tap
    /// an emoji to add it to the post being written.
    @State private var showStickerTray = false

    /// The @mention being typed, if any, and the users that match
    /// it. When the text ends with @ + word characters, the composer
    /// searches for matching usernames and offers them below the
    /// editor; tapping one completes the @username in the text. The
    /// mention itself is plain text — it is resolved to an FID and
    /// encoded per the mention rule when posting, the same as a name
    /// typed out in full.
    @State private var mentionQuery: String?
    @State private var mentionResults: [UserResponse.User] = []
    @State private var mentionSearchTask: Task<Void, Never>?

    /// The @mention being typed, if the text ends with @ + word
    /// characters. The @ must start a word (start of text or after
    /// whitespace), so an email address never triggers the lookup.
    /// Returns the query after the @, or nil when the user is not
    /// typing a mention.
    private func mentionQuery(in text: String) -> String? {
        let pattern = "(?:^|\\s)@([A-Za-z0-9_.-]+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Search for users matching the mention being typed, debounced
    /// so a fast typist fires one search, not one per keystroke.
    /// Each new keystroke cancels the previous search, so only the
    /// latest query's results are ever shown. A failed search just
    /// hides the list; the user can still type the name out in full
    /// and it resolves at post time.
    private func updateMentionSearch(for query: String?) {
        mentionSearchTask?.cancel()
        guard let query, !query.isEmpty else {
            mentionQuery = nil
            mentionResults = []
            return
        }
        mentionQuery = query
        mentionSearchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let users = (try? await FeedService.searchUsers(query: query)) ?? []
            guard !Task.isCancelled else { return }
            mentionResults = Array(users.prefix(5))
        }
    }

    /// Replace the @query being typed with the picked user's
    /// @username, plus a trailing space so the user can keep typing.
    /// The editor rebuilds from the binding and the cursor lands at
    /// the end, which is where the mention was.
    private func pickMention(_ user: UserResponse.User) {
        guard let username = user.username, let query = mentionQuery else { return }
        let token = "@" + query
        guard text.hasSuffix(token) else { return }
        text = String(text.dropLast(token.count)) + "@" + username + " "
        mentionSearchTask?.cancel()
        mentionQuery = nil
        mentionResults = []
    }

    /// Attach an emoji to this post: its shortcode goes into the
    /// text at the end (so it renders inline on the reader side),
    /// and the editor shows it as its picture. A sticker already in
    /// the text is not added twice, and the embed budget caps how
    /// many fit. To remove one, the user backspaces it out of the
    /// editor; the embeds are derived from the text at post time, so
    /// a deleted emoji is not sent.
    private func attachSticker(url: String) {
        let budget = quoted != nil ? 1 : 2
        guard let shortcode = StickerStore.shared.shortcode(for: url),
              !text.contains(shortcode),
              StickerStore.shared.stickerURLs(forShortcodesIn: text).count < budget
        else { return }
        StickerStore.shared.recordUse(url: url)
        // Insert the shortcode at the end, with a space after it so
        // the user can keep typing. If the text is empty the
        // shortcode is the whole post and renders large.
        if text.isEmpty {
            text = shortcode + " "
        } else if text.hasSuffix(" ") || text.hasSuffix("\n") {
            text += shortcode + " "
        } else {
            text += " " + shortcode + " "
        }
    }

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

    /// Remove a URL from the text, but only where it is a bare
    /// link. A URL that is the destination of a Markdown link
    /// `[label](url)` is left alone: the Markdown is the labeled
    /// link, and stripping the URL would leave a broken
    /// `[label]()`. The reader renders the Markdown as the label,
    /// so the URL never shows as text.
    private static func stripBareLink(_ link: String, from text: String) -> String {
        let pattern = #"\[([^\]]+)\]\(([^)\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text.replacingOccurrences(of: link, with: "")
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        // The URL parts of Markdown links: a bare occurrence of the
        // link inside one of these is protected.
        let protected = matches.compactMap { match -> NSRange? in
            guard match.numberOfRanges == 3 else { return nil }
            return match.range(at: 2)
        }
        var result = ""
        var cursor = text.startIndex
        var searchStart = text.startIndex
        while let found = text.range(of: link, range: searchStart..<text.endIndex) {
            let foundNS = NSRange(found, in: text)
            let isProtected = protected.contains { NSIntersectionRange($0, foundNS).length == foundNS.length }
            if !isProtected {
                result += text[cursor..<found.lowerBound]
                cursor = found.upperBound
            }
            searchStart = found.upperBound
        }
        result += text[cursor..<text.endIndex]
        return result
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

                if showStickerTray {
                    StickerTrayView { url in attachSticker(url: url) }
                }

                // The editor shows the emoji itself, not the
                // delimiter: while you write, a tapped emoji sits in
                // the sentence as its picture (WYSIWYG). The text
                // underneath is still the plain text with shortcodes,
                // which is what gets posted.
                WYSIWYGEditor(
                    text: $text,
                    placeholder: placeholder,
                    font: .preferredFont(forTextStyle: .body),
                    textColor: .label,
                    isFocused: $editorFocused
                )
                .frame(minHeight: 140)
                .accessibilityLabel(title)
                .onChange(of: text) { _, newValue in
                    updateMentionSearch(for: mentionQuery(in: newValue))
                }

                if !mentionResults.isEmpty {
                    // The @mention matches, right under the editor:
                    // tap one to complete the name in the text. The
                    // list only shows while a mention is being typed
                    // at the end of the text; picking one, or typing
                    // a space, hides it.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(mentionResults, id: \.fid.value) { user in
                            Button {
                                pickMention(user)
                            } label: {
                                HStack(spacing: 10) {
                                    if let pfpURL = user.pfpURL {
                                        AsyncImage(url: pfpURL) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image.resizable().scaledToFill()
                                            case .failure, .empty:
                                                Image(systemName: "person.circle.fill")
                                                    .resizable()
                                                    .foregroundStyle(Color.fwMuted)
                                            @unknown default:
                                                EmptyView()
                                            }
                                        }
                                        .frame(width: 32, height: 32)
                                        .clipShape(Circle())
                                    } else {
                                        Image(systemName: "person.circle.fill")
                                            .resizable()
                                            .foregroundStyle(Color.fwMuted)
                                            .frame(width: 32, height: 32)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(user.displayName ?? user.username ?? "fid:\(user.fid.value)")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(Color.fwText)
                                            .lineLimit(1)
                                        Text("@\(user.username ?? "")")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if let followers = user.followerCount {
                                        Text("\(followers) followers")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.fwLine, lineWidth: 1))
                }

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
                    Button {
                        showStickerTray.toggle()
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.title2)
                            .foregroundStyle(showStickerTray ? Color.fwAccent : Color.fwAccentSoft)
                    }
                    .accessibilityLabel("Add an emoji")
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
            // Gather embeds: stickers first (explicit), then links.
            // The stickers are derived from the shortcodes in the
            // text, so an emoji the user backspaced out of the
            // editor is not sent. The embed budget is 2 total; a
            // quote already takes 1, so a quote leaves room for 1
            // link and a plain post or reply leaves room for 2. When
            // the budget is tight the stickers win and the links
            // past the budget stay as text. Every bare link that is
            // attached is removed from the text, so the post does
            // not show the URL as text above the picture or card.
            // A Markdown link `[label](url)` is the exception: its
            // URL is attached as the embed, but the Markdown stays
            // in the text, and the reader renders it as the label.
            // Sticker URLs are not in the text (only their shortcode
            // is), so they are never stripped.
            var candidates: [String] = []
            if !trimmedLink.isEmpty {
                candidates.append(trimmedLink)
            }
            for url in linkURLs(in: text) where !candidates.contains(url) {
                candidates.append(url)
            }
            let embedBudget = quoted != nil ? 1 : 2
            let stickerEmbeds = Array(StickerStore.shared.stickerURLs(forShortcodesIn: text).prefix(embedBudget))
            let links = Array(candidates.prefix(max(0, embedBudget - stickerEmbeds.count)))
            let embeds = stickerEmbeds + links
            var sendText = text
            for link in links {
                sendText = Self.stripBareLink(link, from: sendText)
            }
            sendText = sendText.trimmingCharacters(in: .whitespacesAndNewlines)
            sendText = sendText.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            let hash: String
            if let parent {
                hash = try await identity.reply(to: parent, text: sendText, linkURLs: embeds)
            } else if let quoted {
                hash = try await identity.quote(cast: quoted, text: sendText, linkURLs: embeds)
            } else {
                hash = try await identity.post(text: sendText, linkURLs: embeds)
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
