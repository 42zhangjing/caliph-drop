import { HttpError, errorResponse, jsonResponse, slugifyCollection } from "./collections.js";

const ALLOWED_IMAGE_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/avif",
  "image/heic",
  "image/heif",
  "image/tiff",
]);
const DEFAULT_UPLOAD_LIMIT = 50 * 1024 * 1024;

function headerValue(request, name) {
  const value = request.headers.get(name) || "";
  try { return decodeURIComponent(value); } catch { return value; }
}

function safeFileName(value) {
  const decoded = String(value || "upload").normalize("NFKC");
  const name = decoded.replace(/[^\p{Letter}\p{Number}._-]+/gu, "-").slice(-100);
  return name || "upload";
}

function baseName(value) {
  return value.replace(/\.[^/.]+$/, "").slice(0, 160);
}

async function hashesEqual(left, right) {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  const aa = new Uint8Array(a);
  const bb = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < aa.length; i += 1) diff |= aa[i] ^ bb[i];
  return diff === 0;
}

async function requireDropToken(request, env) {
  const expected = String(env.CALIPH_DROP_TOKEN || "");
  if (!expected) throw new HttpError(503, "CALIPH_DROP_TOKEN 尚未配置");
  const authorization = request.headers.get("authorization") || "";
  const provided = authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
  if (!provided || !(await hashesEqual(provided, expected))) {
    throw new HttpError(401, "Caliph Drop Token 不正确");
  }
}

async function createImageRecord(request, env) {
  await requireDropToken(request, env);
  if (!env.COLLECTIONS_DB) throw new HttpError(503, "D1 尚未配置");
  if (!env.COLLECTION_MEDIA) throw new HttpError(503, "R2 媒体存储尚未配置");
  if (request.method !== "POST") throw new HttpError(405, "只支持 POST 上传");

  const contentType = (request.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
  if (!ALLOWED_IMAGE_TYPES.has(contentType)) throw new HttpError(415, "只接受常见图片格式");

  const body = await request.arrayBuffer();
  if (!body.byteLength) throw new HttpError(400, "上传内容为空");
  const maxBytes = Number.parseInt(env.UPLOAD_MAX_BYTES || "", 10) || DEFAULT_UPLOAD_LIMIT;
  if (body.byteLength > maxBytes) {
    throw new HttpError(413, `单个文件不能超过 ${Math.round(maxBytes / 1024 / 1024)} MB`);
  }

  const now = new Date().toISOString();
  const capturedAt = now.slice(0, 10);
  const requestedCollectionId = headerValue(request, "x-collection-id").trim();
  const mediaId = crypto.randomUUID();
  const fileName = safeFileName(headerValue(request, "x-file-name"));
  const requestedTitle = headerValue(request, "x-title").trim();
  const title = requestedTitle.slice(0, 180);
  const publish = request.headers.get("x-publish") !== "0";
  const status = publish ? "published" : "draft";

  let collectionId = requestedCollectionId;
  let isExistingCollection = false;
  let existingItem = null;

  if (requestedCollectionId) {
    try {
      existingItem = await env.COLLECTIONS_DB.prepare(
        "SELECT id, slug, type, title, status, captured_at FROM collections WHERE id = ? AND deleted_at IS NULL"
      ).bind(requestedCollectionId).first();
      if (existingItem?.id) {
        isExistingCollection = true;
        collectionId = existingItem.id;
      }
    } catch {}
  }

  if (!isExistingCollection) {
    collectionId = crypto.randomUUID();
  }

  const slugSeed = title || baseName(fileName) || `drop-${collectionId.slice(0, 8)}`;
  const slug = isExistingCollection ? (existingItem.slug || slugSeed) : `${slugifyCollection(slugSeed) || "drop"}-${collectionId.slice(0, 8)}`;
  const storageKey = `collections/${collectionId}/${mediaId}-${fileName}`;

  try {
    await env.COLLECTION_MEDIA.put(storageKey, body, {
      httpMetadata: { contentType },
      customMetadata: { originalName: fileName, collectionId, source: "caliph-drop" },
    });

    if (isExistingCollection) {
      const countRes = await env.COLLECTIONS_DB.prepare(
        "SELECT COUNT(*) AS total FROM collection_media WHERE collection_id = ?"
      ).bind(collectionId).first();
      const nextSortOrder = Number(countRes?.total || 0);

      await env.COLLECTIONS_DB.prepare(
        "INSERT INTO collection_media (id, collection_id, kind, storage_key, source_url, mime_type, alt_text, poster_url, caption, sort_order, created_at) VALUES (?, ?, 'image', ?, '', ?, ?, '', '', ?, ?)"
      )
        .bind(mediaId, collectionId, storageKey, contentType, title, nextSortOrder, now)
        .run();

      await env.COLLECTIONS_DB.prepare(
        "UPDATE collections SET updated_at = ? WHERE id = ?"
      ).bind(now, collectionId).run();
    } else {
      await env.COLLECTIONS_DB.prepare(
        `INSERT INTO collections (
          id, slug, type, title, summary, body, source_url, prompt_text,
          metadata_json, tags_json, status, featured, captured_at, published_at,
          created_at, updated_at, deleted_at
        ) VALUES (?, ?, 'image', ?, '', '', '', '', ?, '[]', ?, 0, ?, ?, ?, ?, NULL)`,
      )
        .bind(
          collectionId,
          slug,
          title,
          JSON.stringify({ source: "caliph-drop", originalName: fileName }),
          status,
          capturedAt,
          publish ? now : null,
          now,
          now,
        )
        .run();

      await env.COLLECTIONS_DB.prepare(
        "INSERT INTO collection_media (id, collection_id, kind, storage_key, source_url, mime_type, alt_text, poster_url, caption, sort_order, created_at) VALUES (?, ?, 'image', ?, '', ?, ?, '', '', 0, ?)",
      )
        .bind(mediaId, collectionId, storageKey, contentType, title, now)
        .run();
    }
  } catch (error) {
    try { await env.COLLECTION_MEDIA.delete(storageKey); } catch {}
    if (!isExistingCollection) {
      try { await env.COLLECTIONS_DB.prepare("DELETE FROM collections WHERE id = ?").bind(collectionId).run(); } catch {}
    }
    throw error;
  }

  const publicPath = `/media/${encodeURIComponent(mediaId)}`;
  const publicUrl = new URL(publicPath, request.url).href;
  return jsonResponse({
    ok: true,
    url: publicUrl,
    item: {
      id: collectionId,
      slug: isExistingCollection ? (existingItem.slug || slug) : slug,
      type: "image",
      title: isExistingCollection ? (existingItem.title || title) : title,
      status: isExistingCollection ? (existingItem.status || status) : status,
      capturedAt: isExistingCollection ? (existingItem.captured_at || capturedAt) : capturedAt,
    },
    media: {
      id: mediaId,
      publicUrl: publicPath,
      mimeType: contentType,
    },
  }, 201);
}

export async function handleDropUploadRequest(request, env) {
  try {
    return await createImageRecord(request, env);
  } catch (error) {
    return errorResponse(error);
  }
}
