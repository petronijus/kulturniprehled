"""Static serving for the season-planner SPA.

The SPA is a client-side-routed single page app served same-origin at
`/app`, so no CORS is needed and the existing bearer-token auth flow works
unchanged. `SPAStaticFiles` adds the standard history-API fallback: any
path that does not resolve to a real file returns `index.html` and the
client router takes over.
"""

from __future__ import annotations

from starlette.exceptions import HTTPException
from starlette.responses import Response
from starlette.staticfiles import StaticFiles
from starlette.types import Scope


class SPAStaticFiles(StaticFiles):
    """StaticFiles with an index.html fallback for client-side routes.

    `html=True` alone only maps directory roots to index.html; a deep link
    like `/app/scenare` would 404 on refresh without this override.
    Starlette signals "no such file" either as a raised HTTPException or a
    404 response depending on version — handle both.
    """

    async def get_response(self, path: str, scope: Scope) -> Response:
        try:
            response = await super().get_response(path, scope)
        except HTTPException as exc:
            if exc.status_code != 404:
                raise
            return await super().get_response("index.html", scope)
        if response.status_code == 404:
            response = await super().get_response("index.html", scope)
        return response
