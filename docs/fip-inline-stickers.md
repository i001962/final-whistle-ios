# FIP: Inline custom emoji (Draft)

Status: Draft — for discussion with Hypersnap client authors.

Previously titled "Inline Stickers". Renamed, because the mechanism below is
custom emoji, not stickers — see Emoji vs sticker.

## Summary

Images in casts today are picture embeds: they render as a block under the
text, never inside it. This FIP lets an image sit inside a line of text,
like a custom emoji, using only pieces the protocol already has plus two
small optional fields. A client that does not implement it still shows a
readable message.

## Emoji vs sticker

Discord's distinction is the right model, and this FIP adopts it.

- An **emoji** is small, tight, and inline. It sits inside a line of text
  at line height, like `:check:` in `lfg :check:`. It can be animated.
- A **sticker** is large and standalone. It is sent on its own, with no
  text, and renders as a big block — the behaviour this app already has
  (a bare picture embed, rendered at the client's sticker size).

The same image asset can be either, depending on how it is placed. A pack
is a set of images; the picker offers two actions on each one: insert it
inline as an emoji, or send it on its own as a sticker. This FIP specifies
only the emoji (inline) mechanism. The sticker (standalone) behaviour is
unchanged: a bare picture embed with no shortcode, rendered large at the
client's choice of size.

## Mechanism

Three parts, all of them optional and backward compatible.

1. **The shortcode (the anchor).** The text contains `:label:` at the inline
   position, e.g. `lfg :check:`. The label is `[a-z0-9_][a-z0-9_-]{0,31}`
   (max 32 chars). A shortcode is only an emoji anchor when an embed in
   the same cast carries that label; otherwise it is literal text.
2. **The embed (where it is hosted).** The emoji image is an ordinary
   picture embed: CastAddBody field 6, Embed field 1 = the image URL (a
   direct link to a WebP or GIF, not a page). The client does not need to
   know the host; it fetches the URL exactly as it does for a photo embed.
3. **The label (which embed).** Embed gains an optional field:

   ```proto
   message Embed {
     string url = 1;
     CastId cast_id = 2;
     // Present when this embed is an emoji. The value is the shortcode
     // label (without colons). Absent means "photo", as today.
     string emoji_label = 3;
   }
   ```

   Field 3 is the next unassigned field in Embed. A renderer matches
   `:label:` in the text to the embed whose `emoji_label` equals `label`,
   in order. Labels must be unique within one cast; if two embeds share a
   label, the first match wins.

No new message type. No new CastAddBody field. A hub that does not know
field 3 stores and serves the bytes unchanged (protobuf forward
compatibility — to be verified against the Hypersnap hub before finalizing).

## Sprite sheets (one embed, many emoji)

One embed per emoji does not scale, and not just for efficiency: a cast
may carry at most 2 embeds (Farcaster hub validation; a quote counts as one
slot), so a message could hold at most two inline emoji and no photo.
A sprite sheet fixes that. It is the icon-font pattern: one image file
holding a whole pack, with offsets picking out each icon.

1. **The sheet.** One static image (WebP or PNG) holding a grid of square
   cells. The grid is described by a manifest, not by a fixed layout, so
   packs can differ.
2. **The marker.** Embed gains a second optional field:

   ```proto
   message Embed {
     string url = 1;
     CastId cast_id = 2;
     string emoji_label = 3;
     // Present when this embed is a sprite sheet. The value is the pack
     // id (used for caching). A sheet embed is never a single emoji.
     string emoji_sheet = 4;
   }
   ```

   Field 4 is the next unassigned field in Embed. An embed carries either
   `emoji_label` (one emoji) or `emoji_sheet` (a pack), never both.
3. **The manifest (label to offset).** The manifest is JSON, fetched from a
   URL derived from the sheet URL: drop any query or fragment, then replace
   the extension of the last path segment with `.json` (append `.json` if
   there is none). E.g. `https://final-whistle.app/st/packs/matchday.webp`
   becomes `https://final-whistle.app/st/packs/matchday.json`.

   ```json
   {
     "version": 1,
     "columns": 8,
     "cell": 128,
     "stickers": { "check": [0, 0], "eyes": [0, 1], "dirty": [1, 3] }
   }
   ```

   `columns` is cells per row, `cell` is the cell size in pixels, and each
   label maps to `[row, column]` (row-major). The sheet image must be
   `columns * cell` wide and a whole number of rows tall; a manifest that
   disagrees with the image is invalid and the shortcodes stay literal
   text. The client fetches the manifest once per sheet URL and caches it
   keyed by URL. If the fetch fails, the shortcodes render as text.
4. **Resolution order.** For a shortcode `:label:` a supporting client
   looks first for a single-emoji embed with `emoji_label` equal to the
   label, then for a sheet embed whose manifest contains the label (sheets
   in embed order, first match wins). Otherwise the shortcode is literal
   text.
5. **Sheets are static.** A sheet is one still image, so its cells cannot
   animate independently. Animated emoji stay single embeds, exactly as in
   the Mechanism section. A cast can mix one sheet and one animated emoji:
   two embeds, inside the limit.
6. **A sheet embed is never block-rendered** by a supporting client. If its
   manifest cannot be fetched, the shortcodes just stay as text. (A client
   that does not implement this FIP will show the sheet as a picture block,
   the same degradation as a single emoji.)

## Rendering (supporting clients)

1. Replace each matched `:label:` with the image, inline, at the text line
   height (height = 1.2em, width by aspect ratio, capped at 4em),
   baseline-aligned with the surrounding text. It is an emoji, not a
   picture: it sits inside the line.
2. Animated images MUST animate. Use an animated-image renderer. Do not
   downscale, thumbnail, or re-encode to a static frame; a pipeline that
   strips animation breaks the emoji.
3. Do not also render a matched embed as a block. A matched embed is
   consumed inline. A sheet cell renders by cropping the cell rectangle
   out of the sheet and scaling it to line height, exactly as a single
   emoji renders.
4. An embed with an `emoji_label` but no matching shortcode in the text
   renders as a block picture (today's sticker behavior). A shortcode with
   no matching embed renders as literal text `:label:`.
5. If the image fails to load, render the shortcode as text. The shortcode
   is the alt text.
6. A message whose text is only shortcodes (and whitespace), up to three of
   them, renders each one large — at the client's sticker size — instead of
   at line height. Discord does this, and it is the reason a lone emoji
   reads as a reaction rather than a speck. Four or more shortcodes render
   inline. A sticker sent on its own (empty text, bare embed, no shortcode)
   is a block sticker, as today. Inline only happens through a shortcode.

## Composer (Markdown mode)

1. The picker inserts `:label:` at the cursor (replacing any selection),
   followed by a space, with the cursor after the space. It attaches the
   emoji as an embed with `emoji_label` set.
2. When the composer is empty, the picker sends the emoji as a bare embed
   with no text (a block sticker), not a shortcode. A lone `:label:` would
   render tiny (but see rendering rule 6 — a lone shortcode still renders
   large if one is typed).
3. The composer must not attach two embeds with the same `emoji_label` to
   one cast. The shortcode text counts toward the 1024-byte cast limit; the
   embed URL does not.
4. When the user picks from a pack, the picker attaches the pack's sheet
   embed once per cast (deduplicated — picking three emoji from one pack
   still attaches one embed) with `emoji_sheet` set. A cast should carry
   at most one sheet, so the second embed slot stays free for a photo or an
   animated emoji.
5. When Markdown is off, the picker behaves as today (image as a
   standalone embed). Inline placement is a Markdown-mode behavior.

## Compatibility (clients that do not implement this)

- They show the text with the shortcode, e.g. `lfg :check:`, which reads
  fine — it is the same convention as Slack and Discord custom emoji.
- They render the embed as a picture block below the text, so the image is
  still visible, just not inline.
- They ignore the unknown Embed fields 3 and 4 and treat the embed as a
  photo, which is exactly the current behavior.
- Nothing in the text depends on the reader supporting the FIP. No raw URLs
  and no markup appear in the text.

## Worked example

Text: `that tackle was :dirty: and the ref saw :eyes:`

Embeds (in order):

1. `url: https://final-whistle.app/st/match/abc123.webp, emoji_label: "dirty"`
2. `url: https://example.com/photo.jpg` (a photo, no label)
3. `url: https://final-whistle.app/st/match/def456.webp, emoji_label: "eyes"`

- Supporting client: "that tackle was [dirty inline] and the ref saw [eyes
  inline]", then the photo as a block below. The two emoji embeds are not
  also shown as blocks.
- Non-supporting client: "that tackle was :dirty: and the ref saw :eyes:",
  then three pictures as blocks below.

Sheet example. Text: `lfg :check: :eyes: :dirty:` with one embed:
`url: https://final-whistle.app/st/packs/matchday.webp,
emoji_sheet: "matchday"`. The client fetches
`.../matchday.json`, finds all three labels, and renders three inline cells
from the one sheet. One embed covers all three codes, and the second embed
slot is still free. A non-supporting client shows `lfg :check: :eyes:
:dirty:` plus the sheet as a picture block.

## Why not offsets (the mention pattern)?

Mentions store byte offsets separately from the text. That works for
mentions because the anchor (`@username`) is removed and the offset is the
only record. For emoji it is worse: the anchor would be an invisible
space, and any client or pipeline that trims or normalizes whitespace
(notably a trailing space, the common case for an emoji at the end of a
message) silently destroys the position. A shortcode cannot be trimmed away,
it is visible and meaningful in every client, and it needs no new
CastAddBody field. Offsets are the right tool when the anchor must be
invisible; here the anchor being visible is the graceful degradation.

## Why not a new embed type?

A whole new Embed variant would say "this is an emoji" but would not say
where in the text it goes — it still needs an anchor. The `emoji_label`
field on the existing Embed says both "this is an emoji" and "this is
which one", and it reuses the picture-embed transport every client already
implements.

## Non-goals

- Sticker packs, pack discovery, and hosting. This FIP is only about inline
  placement. A pack is a list of (label, URL) pairs, or a sheet plus a
  manifest; how a client obtains one is out of scope.
- Changing block-sticker rendering. That stays a client UI choice.

## Open questions

1. Confirm the Hypersnap hub preserves unknown Embed fields 3 and 4 on
   write and read (expected: yes, protobuf forward compatibility; verify on
   a dev hub before calling this final).
2. Confirm fields 3 and 4 are unassigned in the canonical Embed message.
3. Confirm Hypersnap enforces the 2-embed cast limit the same way Farcaster
   does (hub validation: at most 2 embeds, a quote counting as one slot).
   If it does not, the sheet is still worth having for fetch and cache
   efficiency, but it stops being the thing that makes multi-emoji
   messages possible at all.
