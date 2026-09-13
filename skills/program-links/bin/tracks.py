#!/usr/bin/env python3
"""Turn each picked album into the track list of the piece.

The planner plays a programme in place, so a symphony has to arrive as its
own movements — an album URL alone would run on into whatever else the record
holds. Where the movements cannot be told apart (compilations, an opera with
no work prefix), the album is pushed without a track list and the planner
says so, which is honest and re-resolvable.
"""
from __future__ import annotations
import json, os, re, sys, time, unicodedata, urllib.request

SD = os.environ.get("KP_SEASON_DIR") or sys.exit("set KP_SEASON_DIR to the season scratch dir")
NON = re.compile(r"[^a-z0-9]+")
def fold(t):
    d = unicodedata.normalize("NFKD", (t or "").lower())
    s = "".join(c for c in d if not unicodedata.combining(c))
    return NON.sub(" ", s).strip()

MOVEMENT = re.compile(r"^\s*(?:[IVXLC]+\.|\d+\.)\s|:\s*[IVXLC]+[.:]| - [IVXLC]+[.:]", re.I)
TEMPO = re.compile(r"\b(allegro|andante|adagio|largo|presto|scherzo|menuetto|minuet|finale|"
                   r"vivace|moderato|lento|grave|rondo|trauermarsch|nicht zu schnell|"
                   r"aria|recitativ|ouverture|overture|prelude|preludio|act |akt )\b", re.I)

def api(url, token):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    for _ in range(4):
        try:
            return json.loads(urllib.request.urlopen(req, timeout=30).read())
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(int(e.headers.get("Retry-After", "2")) + 1); continue
            if e.code >= 500:
                time.sleep(2); continue
            return {}
        except Exception:
            time.sleep(2)
    return {}

def work_tokens(work):
    stop = {"pro","and","the","for","orchestr","orchestra","koncert","concerto","a","v","z","op","no"}
    return [t for t in fold(work).split() if len(t) > 3 and t not in stop][:5]

def main():
    token = os.environ["SP_TOKEN"]
    picks = json.load(open(f"{SD}/resolved.json"))
    out = []
    for n, p in enumerate(picks, 1):
        tracks = api(f"https://api.spotify.com/v1/albums/{p['_album_id']}/tracks?limit=50&market=CZ",
                     token).get("items", [])
        toks = work_tokens(p["work"])
        named = [t for t in tracks if any(tok in fold(t["name"]) for tok in toks)]
        item = {"author": p["author"], "work": p["work"], "spotify_url": p["spotify_url"],
                "match_label": p["match_label"]}
        if named:
            # Keep the contiguous run: a work's movements sit together on a disc.
            idx = [tracks.index(t) for t in named]
            lo, hi = min(idx), max(idx)
            run = tracks[lo:hi + 1]
            if len(run) <= 30:
                item["spotify_track_uris"] = [t["uri"] for t in run]
        elif tracks and len(tracks) <= 12 and all(
                MOVEMENT.search(t["name"]) or TEMPO.search(t["name"]) for t in tracks):
            # One work per disc, movements titled only by their tempo marking.
            item["spotify_track_uris"] = [t["uri"] for t in tracks]
        elif len(tracks) == 1:
            item["spotify_track_uris"] = [tracks[0]["uri"]]
        out.append(item)
        if n % 25 == 0:
            print(f"  … {n}/{len(picks)}", file=sys.stderr)
        time.sleep(0.05)
    json.dump(out, open(f"{SD}/links-push.json", "w"), ensure_ascii=False)
    with_tracks = sum(1 for i in out if i.get("spotify_track_uris"))
    print(f"{len(out)} links ready, {with_tracks} with a movement list, "
          f"{len(out) - with_tracks} album-only")
    return 0

if __name__ == "__main__":
    sys.exit(main())
