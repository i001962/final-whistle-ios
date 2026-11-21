# FIP: Inline Stickers (Draft)

Status: Draft — for discussion with Hypersnap client authors.

## Summary

Stickers today are picture embeds: they render as a block under the text,
never inside it. This FIP lets a sticker sit inside a line of text, like a
custom emoji, using only pieces the protocol already has plus one small
optional field. A client that does not implement it still shows a readable
message.

## Mechanism

Three parts, all of them optional and backward compatible.

1. **The shortcode (the anchor).** The text contains `:label:` at the inline
   position, e.g. `lfg :check:`. The label is `[a-z0-9_][a-z0-9_-]{0,31}`
   (max 32 chars). A shortcode is only a sticker anchor when an embed in
   the same cast carries that label; otherwise it is literal text.
2. **The embed (where it is hosted).** The sticker image is an ordinary
   picture embed: CastAddBody field 6, Embed field 1 = the image URL (a
   direct link to a WebP or GIF, not a page). The client does not need to
   know the host; it fetches the URL exactly as it does for a photo embed.
3. **The label (which embed).** Embed gains an optional field:

   ```proto
   message Embed {
     string url = 1;
     CastId cast_id = 2;
     // Present when this embed is a sticker. The value is the shortcode
     // label (without colons). Absent means "photo", as today.
     string sticker_label = 3;
   }
   ```

   Field 3 is the next unassigned field in Embed. A renderer matches
   `:label:` in the text to the embed whose `sticker_label` equals `label`,
   in order. Labels must be unique within one cast; if two embeds share a
   label, the first match wins.

No new message type. No new CastAddBody field. A hub that does not know
field 3 stores and serves the bytes unchanged (protobuf forward
compatibility — to be verified against the Hypersnap hub before finalizing).

## Rendering (supporting clients)

1. Replace each matched `:label:` with the image, inline, at the text line
   height (height = 1.2em, width by aspect ratio, capped at 4em),
   baseline-aligned with the surrounding text. It is an emoji, not a
   picture: it sits inside the line.
2. Animated images MUST animate. Use an animated-image renderer. Do not
   downscale, thumbnail, or re-encode to a static frame; a pipeline that
   strips animation breaks the sticker.
3. Do not also render a matched embed as a block. A matched embed is
   consumed inline.
4. An embed with a `sticker_label` but no matching shortcode in the text
   renders as a block picture (today's sticker behavior). A shortcode with
   no matching embed renders as literal text `:label:`.
5. If the image fails to load, render the shortcode as text. The shortcode
   is the alt text.
6. A sticker sent on its own (empty text, bare embed, no shortcode) is a
   block sticker, as today. Inline only happens through a shortcode.

## Composer (Markdown mode)

1. The picker inserts `:label:` at the cursor (replacing any selection),
   followed by a space, with the cursor after the space. It attaches the
   sticker as an embed with `sticker_label` set.
2. When the composer is empty, the picker sends the sticker as a bare embed
   with no text (a block sticker), not a shortcode. A lone `:label:` would
   render tiny.
3. The composer must not attach two embeds with the same `sticker_label` to
   one cast. The shortcode text counts toward the 1024-byte cast limit; the
   embed URL does not.
4. When Markdown is off, the picker behaves as today (sticker as a
   standalone embed). Inline placement is a Markdown-mode behavior.

## Compatibility (clients that do not implement this)

- They show the text with the shortcode, e.g. `lfg :check:`, which reads
  fine — it is the same convention as Slack and Discord custom emoji.
- They render the embed as a picture block below the text, so the sticker
  is still visible, just not inline.
- They ignore the unknown Embed field 3 and treat the embed as a photo,
  which is exactly the current behavior.
- Nothing in the text depends on the reader supporting the FIP. No raw URLs
  and no markup appear in the text.

## Worked example

Text: `that tackle was :dirty: and the ref saw :eyes:`

Embeds (in order):

1. `url: https://final-whistle.app/st/match/abc123.webp, sticker_label: "dirty"`
2. `url: https://example.com/photo.jpg` (a photo, no label)
3. `url: https://final-whistle.app/st/match/def456.webp, sticker_label: "eyes"`

- Supporting client: "that tackle was [dirty inline] and the ref saw [eyes
  inline]", then the photo as a block below. The two sticker embeds are not
  also shown as blocks.
- Non-supporting client: "that tackle was :dirty: and the ref saw :eyes:",
  then three pictures as blocks below.

## Why not offsets (the mention pattern)?

Mentions store byte offsets separately from the text. That works for
mentions because the anchor (`@username`) is removed and the offset is the
only record. For stickers it is worse: the anchor would be an invisible
space, and any client or pipeline that trims or normalizes whitespace
(notably a trailing space, the common case for a sticker at the end of a
message) silently destroys the position. A shortcode cannot be trimmed away,
it is visible and meaningful in every client, and it needs no new
CastAddBody field. Offsets are the right tool when the anchor must be
invisible; here the anchor being visible is the graceful degradation.

## Why not a new embed type?

A whole new Embed variant would say "this is a sticker" but would not say
where in the text it goes — it still needs an anchor. The `sticker_label`
field on the existing Embed says both "this is a sticker" and "this is
which one", and it reuses the picture-embed transport every client already
implements.

## Non-goals

- Sticker packs, pack discovery, and hosting. This FIP is only about inline
  placement. A pack is a list of (label, URL) pairs; how a client obtains
  one is out of scope.
- Changing block-sticker rendering. That stays a client UI choice.

## Open questions

1. Confirm the Hypersnap hub preserves unknown Embed field 3 bytes on write
   and read (expected: yes, protobuf forward compatibility; verify on a dev
   hub before calling this final).
2. Confirm field 3 is unassigned in the canonical Embed message.
