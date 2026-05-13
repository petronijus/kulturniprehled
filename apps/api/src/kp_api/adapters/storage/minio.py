"""MinIO storage adapter.

Two clients are intentional:

- The **internal** client uses `MINIO_ENDPOINT` for server-to-server traffic
  (bucket bootstrap, deletes, integrity probes). On Proxmox this points at
  the in-cluster service name; in dev/tests it resolves to the docker
  network.

- The **public** client uses `MINIO_PUBLIC_ENDPOINT` and is used **only** for
  generating presigned URLs that mobile clients and the desktop skill will
  hit directly. SigV4 binds the URL to the host header that signed it — if
  we baked an internal hostname into a presigned URL, a mobile client
  visiting `tickets.kp.example.com` would fail the signature check.

When `MINIO_PUBLIC_ENDPOINT` is unset both clients share the internal
endpoint, which is fine for tests and local development.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from datetime import timedelta
from functools import lru_cache
from uuid import UUID

from minio import Minio

from kp_api.config import Settings, get_settings


@dataclass(frozen=True)
class PresignedUpload:
    object_key: str
    url: str
    expires_in_seconds: int


@dataclass(frozen=True)
class PresignedDownload:
    url: str
    expires_in_seconds: int


def _build_client(endpoint: str, secure: bool, settings: Settings) -> Minio:
    return Minio(
        endpoint,
        access_key=settings.minio_access_key,
        secret_key=settings.minio_secret_key,
        secure=secure,
        region=settings.minio_region,
    )


@lru_cache(maxsize=1)
def _internal_client_cached() -> Minio:
    settings = get_settings()
    return _build_client(settings.minio_endpoint, settings.minio_use_ssl, settings)


@lru_cache(maxsize=1)
def _public_client_cached() -> Minio:
    settings = get_settings()
    endpoint = settings.minio_public_endpoint or settings.minio_endpoint
    secure = (
        settings.minio_public_use_ssl
        if settings.minio_public_use_ssl is not None
        else settings.minio_use_ssl
    )
    return _build_client(endpoint, secure, settings)


def reset_cached_clients() -> None:
    """Drop both cached clients. Tests call this after rebinding settings."""

    _internal_client_cached.cache_clear()
    _public_client_cached.cache_clear()


def _internal_client() -> Minio:
    return _internal_client_cached()


def _public_client() -> Minio:
    return _public_client_cached()


def ensure_bucket(bucket: str | None = None) -> None:
    """Best-effort bucket creation. Safe to call at startup."""

    settings = get_settings()
    bucket = bucket or settings.minio_bucket_tickets
    client = _internal_client()
    if not client.bucket_exists(bucket):
        client.make_bucket(bucket, location=settings.minio_region)


def _object_key_for_ticket(event_id: UUID) -> str:
    # Random suffix avoids predictability and collisions; event prefix keeps
    # the bucket listings browseable when debugging.
    suffix = secrets.token_hex(16)
    return f"events/{event_id}/{suffix}"


def make_upload_url(event_id: UUID, mime_type: str) -> PresignedUpload:
    settings = get_settings()
    ttl = settings.minio_presigned_url_ttl_seconds
    key = _object_key_for_ticket(event_id)
    url = _public_client().presigned_put_object(
        settings.minio_bucket_tickets,
        key,
        expires=timedelta(seconds=ttl),
    )
    _ = mime_type  # Reserved for future Content-Type binding via headers.
    return PresignedUpload(object_key=key, url=url, expires_in_seconds=ttl)


def make_download_url(object_key: str) -> PresignedDownload:
    settings = get_settings()
    ttl = settings.minio_presigned_url_ttl_seconds
    url = _public_client().presigned_get_object(
        settings.minio_bucket_tickets,
        object_key,
        expires=timedelta(seconds=ttl),
    )
    return PresignedDownload(url=url, expires_in_seconds=ttl)


def object_exists(object_key: str) -> bool:
    from minio.error import S3Error

    settings = get_settings()
    try:
        _internal_client().stat_object(settings.minio_bucket_tickets, object_key)
        return True
    except S3Error as exc:
        if exc.code == "NoSuchKey":
            return False
        raise


def remove_object(object_key: str) -> None:
    settings = get_settings()
    _internal_client().remove_object(settings.minio_bucket_tickets, object_key)
