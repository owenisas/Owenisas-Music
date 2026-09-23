#!/usr/bin/env python3
"""
owen_yt_proxy.py — minimal LAN proxy for Owenisas Music.
Wraps yt-dlp (which already solves Google's attestation via web_safari +
Deno, signature decipher, and HLS fragment download).

Routes:
  GET  /info?videoId=<id>            -> JSON: {title, artist, thumbnail, duration, audioUrl, videoId}
  GET  /audio?videoId=<id>           -> 302 redirect to the stream URL
  GET  /health                       -> 200 "ok"  (iOS pings this on launch)

Environment:
  OWEN_YT_PORT   (default 8732)
  OWEN_YT_BIND   (default 0.0.0.0)

Why this exists: the iOS app cannot solve botguard + signatureCipher
on-device without bundling ~100 MB of node + JS player code, which
the App Store will not accept. yt-dlp running on the Mac handles all
of that, and the iOS app just gets a clean audio URL.
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("OWEN_YT_PORT", "8732"))
BIND = os.environ.get("OWEN_YT_BIND", "0.0.0.0")
YT_DLP = os.environ.get("OWEN_YT_DLP", "python3.13")
DLP_ARGS = ["-m", "yt_dlp", "--no-warnings", "--no-update",
            "--extractor-args", "youtube:player_client=tv,ios,web_safari",
            "--extractor-args", "youtubepot:pot_request_timeout=15"]

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


def run_yt_dlp_meta(video_id: str) -> dict:
    cmd = [YT_DLP, *DLP_ARGS,
           "-J",  # dump single JSON
           "--no-download",
           f"https://www.youtube.com/watch?v={video_id}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
    if proc.returncode != 0:
        raise RuntimeError(f"yt-dlp failed: {proc.stderr.strip()[-300:]}")
    return json.loads(proc.stdout)


def pick_audio_format(meta: dict) -> tuple[str, str]:
    """Return (direct_audio_url, ext) for the best available m4a or webm opus."""
    formats = (meta.get("formats") or []) + (meta.get("adaptive_formats") or [])
    audio = [f for f in formats if (f.get("acodec") not in (None, "none"))
             and (f.get("vcodec") in (None, "none"))
             and f.get("url")]
    if not audio:
        # Sometimes sig-deciphered formats come back with a url — try any audio
        audio = [f for f in formats if (f.get("acodec") not in (None, "none"))
                 and f.get("url")]
    # Prefer m4a/aac for iOS compatibility
    m4a = [f for f in audio if "mp4" in (f.get("ext") or "")]
    chosen = (m4a or audio)
    if not chosen:
        raise RuntimeError("no audio format with direct url")
    chosen.sort(key=lambda f: -(f.get("abr") or f.get("tbr") or 0))
    f = chosen[0]
    return f["url"], f.get("ext") or "m4a"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        sys.stderr.write("[owen_yt_proxy] " + (format % args) + "\n")

    def _send_json(self, code: int, payload: dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, code: int, body: str):
        b = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(url.query)
        if url.path == "/health":
            self._send_text(200, "ok")
            return
        if url.path == "/info":
            video_id = (qs.get("videoId") or [""])[0]
            if not VIDEO_ID_RE.match(video_id):
                self._send_json(400, {"error": "invalid videoId"})
                return
            try:
                meta = run_yt_dlp_meta(video_id)
            except Exception as e:
                self._send_json(502, {"error": str(e), "videoId": video_id})
                return
            try:
                audio_url, ext = pick_audio_format(meta)
            except Exception as e:
                self._send_json(502, {"error": str(e), "videoId": video_id})
                return
            self._send_json(200, {
                "videoId": video_id,
                "title": meta.get("title"),
                "artist": meta.get("uploader") or meta.get("channel"),
                "duration": meta.get("duration"),
                "thumbnail": (meta.get("thumbnail") or "").split("?")[0],
                "audioUrl": audio_url,
                "ext": ext,
            })
            return
        if url.path == "/audio":
            video_id = (qs.get("videoId") or [""])[0]
            if not VIDEO_ID_RE.match(video_id):
                self._send_json(400, {"error": "invalid videoId"})
                return
            try:
                meta = run_yt_dlp_meta(video_id)
                audio_url, _ = pick_audio_format(meta)
            except Exception as e:
                self._send_json(502, {"error": str(e), "videoId": video_id})
                return
            self.send_response(302)
            self.send_header("Location", audio_url)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            return
        self._send_json(404, {"error": "not found"})


def main():
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    sys.stderr.write(f"[owen_yt_proxy] listening on {BIND}:{PORT}\n")
    sys.stderr.write(f"[owen_yt_proxy] test: curl http://127.0.0.1:{PORT}/health\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("[owen_yt_proxy] shutting down\n")
        server.shutdown()


if __name__ == "__main__":
    main()
