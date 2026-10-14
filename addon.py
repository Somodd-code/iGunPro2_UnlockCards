"""
Card capture addon for mitmproxy / mitmweb.

Watches every server response. If it is JSON containing card entries
(objects with a "card" field), it:
  - saves a copy in the "captures" folder, and
  - writes captures/latest.js, which reader.html reloads every 2 seconds.
"""
import json
import os
import time

from mitmproxy import http

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "captures")
LATEST_JS = os.path.join(OUT_DIR, "latest.js")

# Optional: only look at URLs containing one of these. Empty = check every response.
URL_KEYWORDS = []

os.makedirs(OUT_DIR, exist_ok=True)


def has_cards(x) -> bool:
    if isinstance(x, list):
        return any(has_cards(v) for v in x)
    if isinstance(x, dict):
        if isinstance(x.get("card"), str):
            return True
        return any(has_cards(v) for v in x.values())
    return False


def parse_json(body: bytes):
    text = body.decode("utf-8", errors="replace")
    try:
        return json.loads(text)
    except Exception:
        a, b = text.find("{"), text.rfind("}")
        if a != -1 and b > a:
            try:
                return json.loads(text[a : b + 1])
            except Exception:
                return None
    return None


def response(flow: http.HTTPFlow) -> None:
    if flow.response is None:
        return
    if URL_KEYWORDS and not any(k in flow.request.pretty_url for k in URL_KEYWORDS):
        return

    body = flow.response.get_content()  # already decompressed
    if not body or len(body) > 50_000_000:
        return

    data = parse_json(body)
    if data is None or not has_cards(data):
        return

    stamp = time.strftime("%Y%m%d_%H%M%S")
    with open(os.path.join(OUT_DIR, f"{stamp}.json"), "wb") as f:
        f.write(body)

    # write to a temp file first so the reader never sees a half-written file
    tmp = LATEST_JS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("window.LATEST_CAPTURE = " + json.dumps(data) + ";")
    os.replace(tmp, LATEST_JS)

    print(f"[captured] card data saved ({len(body)} bytes) - reader will update")
