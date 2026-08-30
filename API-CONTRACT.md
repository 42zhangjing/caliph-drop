# Caliph Drop 0.2 API Contract

## Endpoint

`POST /api/drop`

## Headers

```http
Authorization: Bearer <CALIPH_DROP_TOKEN>
Content-Type: image/webp
X-File-Name: IMG_1234.webp
X-Title: optional-title
X-Publish: 1
Accept: application/json
```

The request body is the raw image bytes, not multipart/form-data.

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
    "capturedAt": "2026-08-30"
  },
  "media": {
    "id": "...",
    "publicUrl": "/media/<media-id>",
    "mimeType": "image/webp"
  }
}
```
