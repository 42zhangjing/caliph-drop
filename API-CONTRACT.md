# Caliph Drop 0.5 API Contract

## Endpoint

`POST /api/drop`

## Headers

```http
Authorization: Bearer <CALIPH_DROP_TOKEN>
Content-Type: image/webp
X-File-Name: IMG_1234.webp
X-Title: optional-title
X-Publish: 1
X-Collection-Id: optional-existing-collection-id
X-Upload-Id: optional-client-generated-uuid
Accept: application/json
```

The request body is the raw image bytes, not multipart/form-data.
If `X-Collection-Id` is provided and exists in D1, subsequent images will be appended to the same collection item as additional media items.
`X-Upload-Id` is a stable UUID for one client task. The Worker uses it with the
request fingerprint to make retries idempotent; a replay returns the original
record, while a different payload with the same ID is rejected.

## Response

```json
{
  "ok": true,
  "url": "https://caliph.chengyu.dev/media/<media-id>",
  "item": {
    "id": "...",
    "slug": "...",
    "type": "image",
    "title": "",
      "status": "published",
      "capturedAt": "2026-08-30",
      "needsReview": false
  },
  "media": {
    "id": "...",
    "publicUrl": "/media/<media-id>",
    "mimeType": "image/webp"
  }
}
```
