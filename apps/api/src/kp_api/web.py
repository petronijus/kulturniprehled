"""Static serving for the season-planner SPA.

The SPA is a client-side-routed single page app served same-origin at
`/app`, so no CORS is needed and the existing bearer-token auth flow works
unchanged. `SPAStaticFiles` adds the standard history-API fallback: any
path that does not resolve to a real file returns `index.html` and the
client router takes over.

Network exposure: the API is public (Cloudflare Tunnel — the mobile apps
and the cloud routine need it), but the planner is a home tool. With
`WEB_PUBLIC=false` (default), requests that arrived through Cloudflare are
refused with 404 and only direct access works — LAN
(`http://192.168.20.101:18000/app`) and Tailscale
(`https://<vm>.<tailnet>.ts.net/app` via `tailscale serve`). Detection
keys on the `CF-Connecting-IP` header, which cloudflared injects into
every proxied request and which cannot be stripped by an outside caller —
the tunnel is the only public path to the origin.
"""

from __future__ import annotations

import os

from starlette.exceptions import HTTPException
from starlette.responses import PlainTextResponse, Response
from starlette.staticfiles import StaticFiles
from starlette.types import Scope


def _came_through_cloudflare(scope: Scope) -> bool:
    headers = scope.get("headers") or []
    return any(name == b"cf-connecting-ip" for name, _ in headers)


class SPAStaticFiles(StaticFiles):
    """StaticFiles with an index.html fallback for client-side routes.

    `html=True` alone only maps directory roots to index.html; a deep link
    like `/app/scenare` would 404 on refresh without this override.
    Starlette signals "no such file" either as a raised HTTPException or a
    404 response depending on version — handle both.

    With `public=False`, Cloudflare-proxied requests get a bare 404 (the
    planner does not exist as far as the public origin is concerned).
    """

    def __init__(
        self,
        *,
        directory: str | os.PathLike[str],
        html: bool = True,
        public: bool = False,
    ) -> None:
        super().__init__(directory=directory, html=html)
        self._public = public

    async def get_response(self, path: str, scope: Scope) -> Response:
        if not self._public and _came_through_cloudflare(scope):
            return PlainTextResponse("Not Found", status_code=404)
        try:
            response = await super().get_response(path, scope)
        except HTTPException as exc:
            if exc.status_code != 404:
                raise
            return await super().get_response("index.html", scope)
        if response.status_code == 404:
            response = await super().get_response("index.html", scope)
        return response
