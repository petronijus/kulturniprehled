#!/usr/bin/env python3
"""Resolve season-pool programme pieces to Spotify recordings.

Czech programme spellings against an English-language catalogue: the queries
are tried in the order the skill prescribes (verbatim, transliterated,
international title, catalogue number dropped) and each hit is scored before
anything is accepted. Everything the scorer is not sure about is written out
for a human to look at rather than guessed.
"""
from __future__ import annotations
import json, os, re, sys, time, unicodedata, urllib.parse, urllib.request

SD = os.environ.get("KP_SEASON_DIR") or sys.exit("set KP_SEASON_DIR to the season scratch dir")
NON = re.compile(r"[^a-z0-9]+")

def fold(t: str | None) -> str:
    d = unicodedata.normalize("NFKD", (t or "").lower())
    s = "".join(c for c in d if not unicodedata.combining(c))
    return NON.sub(" ", s).strip()

# Spotify has never heard of "Dmitrij Šostakovič"; the recordings sit under
# the English transliteration. This cost a whole earlier pass.
COMPOSER = {
    "dmitrij sostakovic": "Shostakovich", "sostakovic": "Shostakovich",
    "petr iljic cajkovskij": "Tchaikovsky", "cajkovskij": "Tchaikovsky",
    "modest musorgskij": "Mussorgsky", "musorgskij": "Mussorgsky",
    "sergej prokofjev": "Prokofiev", "prokofjev": "Prokofiev",
    "sergej rachmaninov": "Rachmaninoff", "rachmaninov": "Rachmaninoff",
    "frantisek kramar": "Krommer", "kramar": "Krommer",
    "igor stravinskij": "Stravinsky", "stravinskij": "Stravinsky",
    "nikolaj rimskij korsakov": "Rimsky-Korsakov", "rimskij korsakov": "Rimsky-Korsakov",
    "fryderyk chopin": "Chopin", "gioachino rossini": "Rossini",
    "felix mendelssohn bartholdy": "Mendelssohn", "antonin dvorak": "Dvořák",
    "leos janacek": "Janáček", "bedrich smetana": "Smetana",
    "bohuslav martinu": "Martinů", "josef suk": "Josef Suk",
    "jevgenij svetlanov": "Svetlanov", "alexandr borodin": "Borodin",
    "aram chacaturjan": "Khachaturian", "michail glinka": "Glinka",
    "arvo part": "Arvo Pärt", "gyorgy ligeti": "Ligeti",
}
# Czech concert-programme titles → the spelling the catalogue uses.
TITLE = [
    (r"\bsymfonie c (\d+)\b", r"Symphony No. \1"),
    (r"\bsymfonie\b", "Symphony"),
    (r"\bkoncert pro klavir a orchestr c (\d+)\b", r"Piano Concerto No. \1"),
    (r"\bkoncert pro klavir a orchestr\b", "Piano Concerto"),
    (r"\bklavirni koncert c (\d+)\b", r"Piano Concerto No. \1"),
    (r"\bklavirni koncert\b", "Piano Concerto"),
    (r"\bkoncert pro housle a orchestr c (\d+)\b", r"Violin Concerto No. \1"),
    (r"\bhouslovy koncert c (\d+)\b", r"Violin Concerto No. \1"),
    (r"\bhouslovy koncert\b", "Violin Concerto"),
    (r"\bkoncert pro violoncello\b", "Cello Concerto"),
    (r"\bvioloncellovy koncert\b", "Cello Concerto"),
    (r"\bkoncert pro\b", "Concerto for"),
    (r"\bsmyccovy kvartet c (\d+)\b", r"String Quartet No. \1"),
    (r"\bsmyccovy kvartet\b", "String Quartet"),
    (r"\bklavirni kvartet\b", "Piano Quartet"),
    (r"\bklavirni kvintet\b", "Piano Quintet"),
    (r"\bklavirni trio\b", "Piano Trio"),
    (r"\bklavirni sonata c (\d+)\b", r"Piano Sonata No. \1"),
    (r"\bklavirni sonata\b", "Piano Sonata"),
    (r"\bsonata pro housle\b", "Violin Sonata"),
    (r"\bpredehra k opere\b", "Overture"),
    (r"\bpredehra\b", "Overture"),
    (r"\bsuita z baletu\b", "Suite"),
    (r"\bbaletni suita\b", "Suite"),
    (r"\bserenada\b", "Serenade"),
    (r"\bmse\b", "Mass"),
    (r"\bkantata\b", "Cantata"),
    (r"\bslovanske tance\b", "Slavonic Dances"),
    (r"\bprodana nevesta\b", "The Bartered Bride"),
    (r"\bkouzelna fletna\b", "Die Zauberflöte"),
    (r"\bfigarova svatba\b", "Le nozze di Figaro"),
    (r"\blazebnik sevillsky\b", "Il barbiere di Siviglia"),
    (r"\bmoje vlast\b|\bma vlast\b", "Má vlast"),
    (r"\blasske tance\b", "Lachian Dances"),
    (r"\bpták ohnivak\b|\bptak ohnivak\b", "The Firebird"),
    (r"\bobrazky z vystavy\b", "Pictures at an Exhibition"),
    (r"\bsen noci svatojanske\b", "A Midsummer Night's Dream"),
    (r"\bromeo a julie\b", "Romeo and Juliet"),
    (r"\bzimni cesta\b", "Winterreise"),
    (r"\bctvero rocnich dob\b", "The Four Seasons"),
    (r"\bdafnis a chloe\b", "Daphnis et Chloé"),
    (r"\bsymfonicke tance\b", "Symphonic Dances"),
    (r"\bvarhanni\b", "Organ"),
    (r"\btrojkoncert\b", "Triple Concerto"),
]
# Noise the concert programme adds and the catalogue never carries.
STRIP = [
    r"\bvyber\b", r"\bvybrane casti\b", r"\bkoncertni provedeni\b", r"\bscenicka verze[^,]*",
    r"\bkomorni provedeni\b", r"\bupravа[^,]*", r"\buprava[^,]*", r"\barr[ .][^,]*",
    r"\bpro housle a klavir\b", r"\bpro klavir a orchestr\b", r"\bpro smycce a basso continuo\b",
    r"\bsvetova premiera[^,]*", r"\bceska premiera[^,]*", r"\bna objednavku[^,]*",
    r"\bz opery\b", r"\bz baletu\b", r"\bvyber z dila\b", r"\bpisne\b", r"\bzive\b", r"\blive set\b",
]
CATNUM = re.compile(r"\b(kv|k|op|bwv|hob|wq|fk|rv|d|h|b|wc|hwv|fp)[ .]*\d+[a-z]*\b", re.I)

# "Program bude upřesněn" is not a piece. Resolving one of these produces a ▶
# that plays something nobody asked for, which is worse than no ▶ at all.
PLACEHOLDER = re.compile(
    r"^(vyber|vyber z dila|vybrane casti|pisne|arie|various works|program[^|]*upresn|"
    r"live|live set|autorsky program|spolecny set|spolecny program|dj set|koncert|"
    r"vystoupeni|recital|krest[^|]*|not specified.*|)$")

# What KIND of piece it is. A number surviving is not enough — "Klavírní koncert
# č. 5" matched "Symphony No. 5" on the digit alone until this gate existed.
KIND = [
    ("concerto", r"\bkoncert\b|\bconcerto\b|\bkonzert\b"),
    ("symphony", r"\bsymfoni|\bsymphon|\bsinfoni"),
    ("quartet",  r"\bkvartet\b|\bquartet\b|\bquatuor\b"),
    ("quintet",  r"\bkvintet\b|\bquintet\b"),
    ("trio",     r"\btrio\b"),
    ("sextet",   r"\bsextet\b"),
    ("sonata",   r"\bsonat|\bsonata\b"),
    ("overture", r"\bpredehra\b|\bouvertur|\boverture\b"),
    ("mass",     r"\bmse\b|\bmass\b|\brequiem\b"),
    ("cantata",  r"\bkantata\b|\bcantata\b|\boratori"),
    ("suite",    r"\bsuita\b|\bsuite\b"),
    ("serenade", r"\bserenad"),
    ("fantasia", r"\bfantazie\b|\bfantas"),
    ("variations", r"\bvariace\b|\bvariation"),
]
def kind_of(text):
    t = fold(text)
    return {name for name, pat in KIND if re.search(pat, t)}
NUMBER = re.compile(r"\bno\s*(\d+)\b|\bc\s*(\d+)\b")
BAD_ALBUM = re.compile(
    r"\b(relaxation|relaxing|chill|sleep|study|best of classical|100 best|greatest hits|"
    r"famous|favourite|favorite|classical music for|essential classics|wedding|"
    r"meditation|spa|karaoke|ringtone)\b", re.I)

# socr.rozhlas.cz prints the playing time after each title ("Římské pinie
# (23‘)"). It has to go before fold(), because fold() drops the brackets and
# leaves a bare number that is indistinguishable from an opus number — strip
# it afterwards and "op. 26" loses its 26. Left in, it competes with the
# work's own number: Bernstein's Symphony No. 2 came back as Bach's
# Orchestral Suite No. 2. The scrapers strip it at the source now; this
# catches rows stored before that and any venue that takes up the habit.
DURATION = re.compile(r"\s*[(\[]\s*\d{1,3}\s*['\u2018\u2019\u00b4\u02b9\u2032]?\s*[)\]]\s*$")


def variants(author: str, work: str) -> list[str]:
    work = DURATION.sub("", work)
    a_f, w_f = fold(author), fold(work)
    a_en = COMPOSER.get(a_f) or COMPOSER.get(a_f.split()[-1] if a_f else "") or author
    w_clean = w_f
    for pat in STRIP:
        w_clean = re.sub(pat, " ", w_clean)
    w_clean = re.sub(r"\s+", " ", w_clean).strip(" ,-")
    w_en = w_clean
    for pat, rep in TITLE:
        w_en = re.sub(pat, rep, w_en)
    w_nocat = CATNUM.sub("", w_en).strip(" ,-")
    out, seen = [], set()
    for q in (f"{author} {work}", f"{a_en} {w_en}", f"{a_en} {w_nocat}", f"{a_en} {w_clean}"):
        q = re.sub(r"\s+", " ", q).strip()
        if q and q.lower() not in seen:
            seen.add(q.lower()); out.append(q)
    return out

def api(url: str, token: str) -> dict:
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    for attempt in range(4):
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

def score(album: dict, author: str, work: str, hint: str = "") -> int:
    name = fold(album.get("name"))
    artists = fold(" ".join(a["name"] for a in album.get("artists", [])))
    hay = name + " " + artists
    a_f = fold(author); sur = a_f.split()[-1] if a_f else ""
    a_en = fold(COMPOSER.get(a_f) or COMPOSER.get(sur) or author)
    en_sur = a_en.split()[-1] if a_en else ""
    s = 0
    if BAD_ALBUM.search(album.get("name") or ""): return -100
    if sur and (sur in hay): s += 3
    elif en_sur and (en_sur in hay): s += 3
    else: return -100                      # not about this composer at all
    # The kind of piece has to agree. A concerto is not a symphony, however
    # well the opus number lines up.
    want, got = kind_of(work), kind_of(album.get("name"))
    if want and got and not (want & got): return -100
    if want and want & got: s += 2
    # A number in the piece must survive into the recording, or it is another work.
    nums = {m.group(1) or m.group(2) for m in NUMBER.finditer(fold(work))}
    if nums:
        if nums & {m.group(1) or m.group(2) for m in NUMBER.finditer(name)}: s += 3
        else: return -100
    w_tokens = [t for t in fold(work).split() if len(t) > 3][:6]
    s += sum(1 for t in w_tokens if t in name)
    # A retry carries the catalogue title someone supplied by hand. Its words
    # landing on the record is the evidence that the title was right, and a
    # Czech title contributes almost nothing to the line above — without this
    # Górecki's "Three Pieces in the Old Style" scored exactly at the cutoff.
    if hint:
        s += min(sum(1 for t in [t for t in fold(hint).split() if len(t) > 3][:6] if t in name), 4)
    for pat, rep in TITLE:
        if re.search(pat, fold(work)) and fold(rep).split()[0] in name: s += 2; break
    if album.get("album_type") == "album": s += 1
    if (album.get("total_tracks") or 0) > 40: s -= 1     # box sets drown the work
    return s

def retry() -> int:
    """Second pass: search again with catalogue titles supplied by hand.

    The first pass can only translate what the TITLE table happens to hold —
    two dozen entries against a whole season's repertoire — so everything
    else lands in unsure.json. Until 2026-09 nothing ever read that file, and
    "Tři kusy ve starém stylu" stayed unresolved although "Three Pieces in
    the Old Style" is the first hit. This turns that file into a work queue.

    Reads retry_titles.json: [{"author", "work", "title"}, …] where `title`
    is what the catalogue calls the piece. The scoring gates are unchanged —
    a supplied title still has to survive the composer, kind and number
    checks, because a confident guess is not a recording.
    """

    token = os.environ["SP_TOKEN"]
    unsure = json.load(open(f"{SD}/unsure.json"))
    supplied = json.load(open(f"{SD}/retry_titles.json"))
    if isinstance(supplied, dict):
        supplied = [{"author": k.split("|")[0], "work": k.split("|")[-1], "title": v}
                    for k, v in supplied.items()]
    by_key = {(fold(t["author"]), fold(t["work"])): t["title"] for t in supplied}

    resolved = json.load(open(f"{SD}/resolved.json"))
    still, added = [], 0
    for p in unsure:
        title = by_key.get((fold(p["author"]), fold(p["work"])))
        if not title:
            still.append(p)
            continue
        a_f = fold(p["author"])
        a_en = COMPOSER.get(a_f) or COMPOSER.get(a_f.split()[-1] if a_f else "") or p["author"]
        best = None
        for q in (f"{a_en} {title}", title):
            url = ("https://api.spotify.com/v1/search?"
                   + urllib.parse.urlencode({"q": q, "type": "album", "limit": 5, "market": "CZ"}))
            for alb in api(url, token).get("albums", {}).get("items", []):
                sc = score(alb, p["author"], p["work"], hint=title)
                if best is None or sc > best[0]:
                    best = (sc, alb, q)
            if best and best[0] >= 6:
                break
            time.sleep(0.08)
        if best is None or best[0] < 4:
            still.append({**p, "why": f"retry with '{title}' still found nothing"})
            continue
        sc, alb, q = best
        resolved.append({"author": p["author"], "work": p["work"],
                         "spotify_url": alb["external_urls"]["spotify"],
                         "match_label": f"{alb['artists'][0]['name']} — {alb['name']}",
                         "_score": sc, "_query": q, "_album_id": alb["id"],
                         "_total_tracks": alb.get("total_tracks"), "_retry_title": title})
        added += 1
    json.dump(resolved, open(f"{SD}/resolved.json", "w"), ensure_ascii=False)
    json.dump(still, open(f"{SD}/unsure.json", "w"), ensure_ascii=False)
    print(f"retry resolved: {added}   still unresolved: {len(still)}")
    return 0


def main() -> int:
    token = os.environ["SP_TOKEN"]
    pieces = json.load(open(f"{SD}/pieces.json"))
    resolved, unsure = [], []
    for n, p in enumerate(pieces, 1):
        if "klasika" not in p["lanes"] and "elektronika" not in p["lanes"]:
            continue
        stripped = fold(p["work"])
        for pat in STRIP:
            stripped = re.sub(pat, " ", stripped)
        if PLACEHOLDER.match(re.sub(r"\s+", " ", stripped).strip()):
            unsure.append({**p, "why": "placeholder, not a work", "best": None})
            continue
        best = None
        for q in variants(p["author"], p["work"]):
            url = ("https://api.spotify.com/v1/search?"
                   + urllib.parse.urlencode({"q": q, "type": "album", "limit": 5, "market": "CZ"}))
            for alb in api(url, token).get("albums", {}).get("items", []):
                sc = score(alb, p["author"], p["work"])
                if best is None or sc > best[0]:
                    best = (sc, alb, q)
            if best and best[0] >= 6:
                break
            time.sleep(0.08)
        if best is None or best[0] < 4:
            unsure.append({**p, "why": "no plausible album", "best": (best[1]["name"] if best else None)})
            continue
        sc, alb, q = best
        entry = {"author": p["author"], "work": p["work"],
                 "spotify_url": alb["external_urls"]["spotify"],
                 "match_label": f"{alb['artists'][0]['name']} — {alb['name']}",
                 "_score": sc, "_query": q, "_album_id": alb["id"],
                 "_total_tracks": alb.get("total_tracks")}
        resolved.append(entry)
        if n % 25 == 0:
            print(f"  … {n}/{len(pieces)}", file=sys.stderr)
    json.dump(resolved, open(f"{SD}/resolved.json", "w"), ensure_ascii=False)
    json.dump(unsure, open(f"{SD}/unsure.json", "w"), ensure_ascii=False)
    print(f"albums picked: {len(resolved)}   left unresolved: {len(unsure)}")
    return 0

if __name__ == "__main__":
    sys.exit(retry() if "--retry" in sys.argv else main())
