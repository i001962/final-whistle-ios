# Final Whistle pfp upload API

Contract between the Final Whistle iOS app and the Castrater Storage
pfp endpoint. The other side of this contract is being built in
`i001962/quilibrium-storage-provider` (storage.castrater.xyz).
This file is the app side's statement of what it sends and expects;
if the server changes shape, this file and `ProfilePhotoService`
change together.

## Goal

A Final Whistle user sets their Farcaster profile picture from the
Account panel. The app uploads the photo once per FID, the server
stores it in QStorage and returns a public URL, and the app saves
that URL as the FID's pfp with a `UserDataAdd` (type 11, field 1).
**No money changes hands**: this is not the $0.03 x402 rental flow.
The operator (who runs the storage site) covers the storage.

## Endpoint

```
POST https://storage.castrater.xyz/v1/files/pfp
Authorization: Bearer <FINAL_WHISTLE_API_KEY>
Content-Type: multipart/form-data; boundary=...
```

The API key identifies the Final Whistle app. It is not the
authorization for a given FID — the FID's signer signature is.
The key ships in the app build (see `Secrets.swift`); it must not
be committed to the repo.

## Request (multipart)

| Field | Value |
| --- | --- |
| `fid` | Decimal FID, e.g. `4294967327` |
| `signer_public_key` | Lowercase hex of the 32-byte Ed25519 signer public key |
| `sha256` | Lowercase hex SHA-256 of the exact JPEG bytes |
| `signature` | Lowercase hex Ed25519 signature over the UTF-8 bytes of `final-whistle-pfp:{fid}:{sha256}` |
| `file` | The JPEG bytes, filename `pfp.jpg`, content-type `image/jpeg` |

The app resizes the photo to a 512px square JPEG before uploading,
so bodies are small (tens of KB). Accept `image/jpeg` at minimum;
`image/png` and `image/webp` are a bonus. Reject anything over 2 MB.

## Response

```
201 {"fid": 4294967327, "url": "https://storage.castrater.xyz/..."}
```

`url` is the public URL the app saves as the pfp. It must be
**stable per FID**: re-uploading a new photo for the same FID
returns the same URL (store keyed by FID, e.g. `pfp/{fid}.jpg`),
so an updated photo needs no new `UserDataAdd` to take effect.

## Server rules

1. Verify `signer_public_key` is an active signer for `fid` on
   Hypersnap (same check as `GetSignersByFid` — the key must be
   registered for that FID, or the request is rejected).
2. Verify `signature` over `final-whistle-pfp:{fid}:{sha256}` with
   that public key, and verify `sha256` matches the uploaded bytes.
3. One active pfp per FID. A re-upload replaces the previous object.
4. **No expiry.** Pfp files are exempt from the rental expiry sweep
   (the 30-day rental term does not apply here — a profile picture
   that dies after a month breaks the profile everywhere).
5. Serve the object as a plain public image URL (correct
   `Content-Type`, no auth required to fetch it) — every Farcaster
   client fetches it directly.

## App flow

1. Pick a photo → square-crop to 512px JPEG (`preparedJPEG`).
2. SHA-256 the JPEG, sign `final-whistle-pfp:{fid}:{sha256}` with
   the FID's Ed25519 signer key (`IdentityStore.uploadPFP`).
3. POST the multipart body with the app's API key
   (`ProfilePhotoService.uploadPFP`).
4. Save the returned URL with `IdentityStore.setPFP`
   (`UserDataAdd` type 11, field 1).
5. Refresh the profile; the new photo shows as nodes pick it up.

## Errors

- `401` — bad or missing API key.
- `403` — signature invalid, signer not registered for the FID,
  or `sha256` does not match the bytes.
- `413` — file too large.
- Anything else non-2xx — the app shows the server's message if
  any, else "The photo upload did not return a link."
