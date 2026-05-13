"""
GCS → chunks → embeddings → Qdrant ingestion.

Idempotent: each point ID is hash(source_path + chunk_index), so re-runs
upsert. Skips files whose md5 hash matches a record in the ingestion_state
collection (so unchanged files aren't re-embedded).

Supported file types: .txt, .md, .pdf (pdf via pypdf, optional dep)
"""
from __future__ import annotations

import hashlib
import logging
import os
import sys
import uuid
from typing import Iterator

import httpx
from google.cloud import storage

DOCS_BUCKET = os.environ["DOCS_BUCKET"]
EMBEDDINGS_URL = os.environ["EMBEDDINGS_URL"]
QDRANT_URL = os.environ["QDRANT_URL"]
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "documents")
QDRANT_API_KEY = os.environ["QDRANT_API_KEY"]
CHUNK_SIZE = int(os.environ.get("CHUNK_SIZE", "1000"))
CHUNK_OVERLAP = int(os.environ.get("CHUNK_OVERLAP", "200"))
EMBED_DIM = int(os.environ.get("EMBED_DIM", "384"))
STATE_COLLECTION = "ingestion_state"
EMBED_BATCH = 32

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ingestion")


def _qheaders() -> dict[str, str]:
    return {"api-key": QDRANT_API_KEY, "Content-Type": "application/json"}


def ensure_collections(client: httpx.Client) -> None:
    """Create documents + ingestion_state collections if missing."""
    for name, dim in [(QDRANT_COLLECTION, EMBED_DIM), (STATE_COLLECTION, 1)]:
        r = client.get(f"{QDRANT_URL}/collections/{name}", headers=_qheaders())
        if r.status_code == 200:
            continue
        log.info("creating collection: %s", name)
        body = {
            "vectors": {"size": dim, "distance": "Cosine"},
            "optimizers_config": {"default_segment_number": 2},
        }
        r = client.put(f"{QDRANT_URL}/collections/{name}", headers=_qheaders(), json=body)
        r.raise_for_status()


def list_objects() -> Iterator[storage.Blob]:
    sc = storage.Client()
    bucket = sc.bucket(DOCS_BUCKET)
    for blob in bucket.list_blobs():
        if blob.size == 0:
            continue
        if not blob.name.lower().endswith((".txt", ".md", ".pdf")):
            continue
        yield blob


def already_ingested(client: httpx.Client, blob_path: str, md5: str) -> bool:
    point_id = str(uuid.UUID(hashlib.md5(blob_path.encode()).hexdigest()))
    r = client.post(
        f"{QDRANT_URL}/collections/{STATE_COLLECTION}/points",
        headers=_qheaders(),
        json={"ids": [point_id], "with_payload": True},
    )
    if r.status_code != 200:
        return False
    points = r.json().get("result", [])
    if not points:
        return False
    return (points[0].get("payload") or {}).get("md5") == md5


def mark_ingested(client: httpx.Client, blob_path: str, md5: str) -> None:
    point_id = str(uuid.UUID(hashlib.md5(blob_path.encode()).hexdigest()))
    body = {
        "points": [{
            "id": point_id,
            "vector": [0.0],
            "payload": {"source": blob_path, "md5": md5},
        }]
    }
    r = client.put(
        f"{QDRANT_URL}/collections/{STATE_COLLECTION}/points?wait=true",
        headers=_qheaders(), json=body,
    )
    r.raise_for_status()


def extract_text(blob: storage.Blob) -> str:
    data = blob.download_as_bytes()
    name = blob.name.lower()
    if name.endswith(".pdf"):
        try:
            from pypdf import PdfReader  # type: ignore
            import io
            reader = PdfReader(io.BytesIO(data))
            return "\n".join((page.extract_text() or "") for page in reader.pages)
        except ImportError:
            log.warning("pypdf not installed; skipping %s", blob.name)
            return ""
    return data.decode("utf-8", errors="replace")


def chunk_text(text: str, size: int, overlap: int) -> list[str]:
    if not text.strip():
        return []
    chunks: list[str] = []
    start = 0
    while start < len(text):
        end = min(start + size, len(text))
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end == len(text):
            break
        start = end - overlap
    return chunks


def embed(client: httpx.Client, texts: list[str]) -> list[list[float]]:
    r = client.post(f"{EMBEDDINGS_URL}/embed", json={"texts": texts}, timeout=60.0)
    r.raise_for_status()
    return r.json()["embeddings"]


def upsert_chunks(
    client: httpx.Client,
    source: str,
    chunks: list[str],
    vectors: list[list[float]],
    start_index: int,
) -> None:
    points = []
    for i, (text, vec) in enumerate(zip(chunks, vectors)):
        chunk_index = start_index + i
        id_seed = f"{source}::{chunk_index}".encode()
        point_id = str(uuid.UUID(hashlib.md5(id_seed).hexdigest()))
        points.append({
            "id": point_id,
            "vector": vec,
            "payload": {
                "source": source,
                "chunk_index": chunk_index,
                "text": text,
            },
        })
    r = client.put(
        f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points?wait=true",
        headers=_qheaders(), json={"points": points},
    )
    r.raise_for_status()


def process_blob(client: httpx.Client, blob: storage.Blob) -> int:
    blob.reload()
    md5 = blob.md5_hash or ""
    if already_ingested(client, blob.name, md5):
        log.info("skip (unchanged): %s", blob.name)
        return 0

    log.info("processing: %s (%d bytes)", blob.name, blob.size or 0)
    text = extract_text(blob)
    chunks = chunk_text(text, CHUNK_SIZE, CHUNK_OVERLAP)
    if not chunks:
        log.info("no extractable text: %s", blob.name)
        mark_ingested(client, blob.name, md5)
        return 0

    total = 0
    for i in range(0, len(chunks), EMBED_BATCH):
        batch = chunks[i:i + EMBED_BATCH]
        vectors = embed(client, batch)
        upsert_chunks(client, blob.name, batch, vectors, start_index=i)
        total += len(batch)
    mark_ingested(client, blob.name, md5)
    log.info("ingested %d chunks for %s", total, blob.name)
    return total


def main() -> int:
    with httpx.Client(timeout=120.0) as client:
        ensure_collections(client)
        grand_total = 0
        files_processed = 0
        for blob in list_objects():
            try:
                n = process_blob(client, blob)
                if n > 0:
                    files_processed += 1
                grand_total += n
            except Exception:
                log.exception("failed to process %s", blob.name)
        log.info("done: %d new chunks across %d files", grand_total, files_processed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
