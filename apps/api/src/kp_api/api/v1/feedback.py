"""Recommendation feedback endpoint.

Clickable from the weekly digest email — no login required. The link
carries an HMAC-signed token that encodes the event + rating; the
endpoint validates the signature, records the vote, and returns a
simple HTML "thanks" page.
"""

from __future__ import annotations

import hashlib
import hmac
import json
from base64 import urlsafe_b64decode, urlsafe_b64encode
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api.adapters.db import get_session
from kp_api.api.deps import CurrentUser
from kp_api.config import Settings, get_settings
from kp_api.domain.enums import FeedbackRating
from kp_api.domain.ids import uuid7
from kp_api.domain.models import RecommendationFeedback

router = APIRouter(prefix="/v1/feedback", tags=["feedback"])

_HTML_OK = """\
<!DOCTYPE html>
<html lang="cs">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Díky!</title>
<style>
body{{font-family:-apple-system,Segoe UI,sans-serif;display:flex;align-items:center;
justify-content:center;min-height:100vh;margin:0;background:#fafafa;color:#111;}}
.card{{text-align:center;padding:48px;border-radius:12px;background:#fff;
box-shadow:0 2px 12px rgba(0,0,0,.06);max-width:400px;}}
h1{{font-size:48px;margin:0 0 16px;}}
p{{font-size:16px;color:#444;margin:0;}}
</style></head>
<body><div class="card">
<h1>{emoji}</h1>
<p>{message}</p>
</div></body></html>
"""

_HTML_ERR = """\
<!DOCTYPE html>
<html lang="cs">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Chyba</title>
<style>
body{{font-family:-apple-system,Segoe UI,sans-serif;display:flex;align-items:center;
justify-content:center;min-height:100vh;margin:0;background:#fafafa;color:#111;}}
.card{{text-align:center;padding:48px;border-radius:12px;background:#fff;
box-shadow:0 2px 12px rgba(0,0,0,.06);max-width:400px;}}
p{{font-size:16px;color:#666;margin:0;}}
</style></head>
<body><div class="card">
<p>Neplatný nebo expirovaný odkaz.</p>
</div></body></html>
"""


def create_feedback_token(
    event_title: str,
    event_lane: str,
    digest_week: str,
    rating: str,
    secret: str,
) -> str:
    """Build a URL-safe HMAC-signed token encoding the feedback payload."""
    payload = json.dumps(
        {"t": event_title, "l": event_lane, "w": digest_week, "r": rating},
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode()
    sig = hmac.new(secret.encode(), payload, hashlib.sha256).digest()[:16]
    return urlsafe_b64encode(payload + sig).rstrip(b"=").decode()


def _decode_token(token: str, secret: str) -> dict[str, str] | None:
    try:
        padding = 4 - len(token) % 4
        raw = urlsafe_b64decode(token + "=" * padding)
    except Exception:
        return None
    if len(raw) < 17:
        return None
    payload_bytes, sig = raw[:-16], raw[-16:]
    expected = hmac.new(secret.encode(), payload_bytes, hashlib.sha256).digest()[:16]
    if not hmac.compare_digest(sig, expected):
        return None
    try:
        data = json.loads(payload_bytes)
    except Exception:
        return None
    if not all(k in data for k in ("t", "l", "w", "r")):
        return None
    if data["r"] not in (FeedbackRating.UP, FeedbackRating.DOWN):
        return None
    return dict(data)


@router.get("/rate")
async def rate_recommendation(
    t: Annotated[str, Query(description="HMAC-signed feedback token")],
    session: Annotated[AsyncSession, Depends(get_session)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> Response:
    data = _decode_token(t, settings.api_jwt_secret)
    if data is None:
        return Response(
            content=_HTML_ERR,
            media_type="text/html",
            status_code=400,
        )

    row = RecommendationFeedback(
        id=uuid7(),
        event_title=data["t"],
        event_lane=data["l"],
        digest_week=data["w"],
        rating=FeedbackRating(data["r"]),
    )
    session.add(row)
    await session.commit()

    emoji = "\U0001f44d" if data["r"] == "up" else "\U0001f44e"
    message = (
        f"Zaznamenáno {'líbí se' if data['r'] == 'up' else 'nelíbí se'} "
        f"pro <strong>{data['t']}</strong>. Díky!"
    )
    return Response(
        content=_HTML_OK.format(emoji=emoji, message=message),
        media_type="text/html",
    )


@router.get("/history")
async def feedback_history(
    session: Annotated[AsyncSession, Depends(get_session)],
    _user: CurrentUser,
) -> list[dict[str, str]]:
    """Return all feedback rows — used by the aggregator skill to learn
    preferences. Protected by bearer token (same as other API endpoints)."""
    result = await session.execute(
        select(RecommendationFeedback).order_by(RecommendationFeedback.created_at.desc())
    )
    rows = result.scalars().all()
    return [
        {
            "event_title": r.event_title,
            "event_lane": r.event_lane,
            "digest_week": r.digest_week,
            "rating": r.rating,
            "created_at": r.created_at.isoformat() if r.created_at else "",
        }
        for r in rows
    ]
