import os
import sys
import subprocess
import json
import urllib.request
import urllib.parse
from flask import Flask, request, send_file, abort, jsonify, url_for

app = Flask(__name__)

BASE_DIR    = os.path.dirname(os.path.abspath(__file__))
COOKIE_FILE = os.path.join(BASE_DIR, 'youtube_cookies.txt')

def setup_node():
    node_dir = os.path.join(BASE_DIR, 'node-v20.11.1-linux-x64')
    if not os.path.exists(node_dir):
        tar_path = os.path.join(BASE_DIR, 'node.tar.xz')
        if os.path.exists(tar_path):
            try:
                subprocess.check_output(f"tar -xf {tar_path} -C {BASE_DIR}", shell=True)
            except:
                pass
    
    os.environ['PATH'] = f"{node_dir}/bin:" + os.environ.get('PATH', '')

def update_yt_dlp():
    """Download the latest yt-dlp binary."""
    binary_path = os.path.join(BASE_DIR, 'yt-dlp')
    # Use proxy to download if needed, or directly download
    download_cmd = f"export http_proxy=http://proxy.server:3128; export https_proxy=http://proxy.server:3128; curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o {binary_path} && chmod a+rx {binary_path}"
    subprocess.check_output(['bash', '-c', download_cmd])
    return binary_path

@app.route("/check")
def check_version():
    try:
        binary_path = os.path.join(BASE_DIR, 'yt-dlp')
        out = subprocess.check_output([binary_path, '--version']).decode()
        return out
    except Exception as e:
        return str(e)

@app.route("/fix")
def fix_deps():
    setup_node()
    try:
        binary_path = update_yt_dlp()
        out = subprocess.check_output([binary_path, '--version']).decode()
        try:
            node_ver = subprocess.check_output(["node", "-v"]).decode()
        except Exception as e:
            node_ver = f"Failed to get node version: {e}"
        return f"<pre>yt-dlp binary updated to: {out}\nNode version: {node_ver}\nPATH: {os.environ.get('PATH')}</pre>"
    except subprocess.CalledProcessError as e:
        return f"<pre>EXIT CODE: {e.returncode}\nOUTPUT:\n{e.output.decode()}</pre>"
    except Exception as e:
        import traceback
        return f"<pre>{traceback.format_exc()}</pre>"


STORAGE_DIR = os.path.join(BASE_DIR, 'storage')
AUDIO_DIR   = os.path.join(STORAGE_DIR, 'audio')
INFO_DIR    = os.path.join(STORAGE_DIR, 'info')

for d in [AUDIO_DIR, INFO_DIR]:
    if not os.path.exists(d):
        os.makedirs(d, exist_ok=True)

def run_yt_dlp(args):
    setup_node()
    binary_path = os.path.join(BASE_DIR, 'yt-dlp')
    if not os.path.exists(binary_path):
        binary_path = update_yt_dlp()

    cmd = [binary_path, '--cookies', COOKIE_FILE, '--user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36', '--js-runtimes', 'node'] + args
    return subprocess.check_output(cmd, stderr=subprocess.STDOUT).decode()


@app.route("/download")
def download_audio():
    video_id = request.args.get("id")
    if not video_id:
        return jsonify({"error": "Missing `id` parameter"}), 400

    cached_file = os.path.join(AUDIO_DIR, f"{video_id}.mp3")
    if os.path.exists(cached_file):
        return send_file(cached_file, as_attachment=True)

    outtmpl = os.path.join(AUDIO_DIR, f"{video_id}.%(ext)s")
    
    try:
        run_yt_dlp([
            '-x', '--audio-format', 'mp3',
            '--ffmpeg-location', '/usr/bin',
            '-o', outtmpl,
            f"https://www.youtube.com/watch?v={video_id}"
        ])
    except subprocess.CalledProcessError as e:
        return jsonify({"error": f"Conversion failed: {e.output.decode()}"}), 500
    except Exception as e:
        return jsonify({"error": f"Conversion failed: {e}"}), 500

    if os.path.exists(cached_file):
        return send_file(cached_file, as_attachment=True)
    else:
        return jsonify({"error": "MP3 file not found after conversion"}), 500


# ── LRCLIB integration ──────────────────────────────────────────────

def fetch_lrclib_lyrics(title, artist, album="", duration=0):
    """Query LRCLIB for synced lyrics. Returns (synced_lrc, plain_lyrics) or (None, None)."""
    import urllib.request, urllib.parse, json as _json

    # Clean up auto-generated YouTube artist names
    artist_clean = artist.replace(" - Topic", "").strip()

    # 1. Try exact match
    params = urllib.parse.urlencode({
        "track_name": title,
        "artist_name": artist_clean,
        **({"album_name": album} if album else {}),
        **({"duration": int(duration)} if duration else {}),
    })
    try:
        req = urllib.request.Request(
            f"https://lrclib.net/api/get?{params}",
            headers={"User-Agent": "OwenisasMusic/1.0 github.com/owenisas/Owenisas-Music"}
        )
        with urllib.request.urlopen(req, timeout=8) as res:
            data = _json.loads(res.read())
            synced = data.get("syncedLyrics")
            plain  = data.get("plainLyrics")
            if synced or plain:
                return synced, plain
    except Exception:
        pass

    # 2. Fallback: search
    try:
        q = urllib.parse.urlencode({"q": f"{artist_clean} {title}"})
        req = urllib.request.Request(
            f"https://lrclib.net/api/search?{q}",
            headers={"User-Agent": "OwenisasMusic/1.0 github.com/owenisas/Owenisas-Music"}
        )
        with urllib.request.urlopen(req, timeout=8) as res:
            results = _json.loads(res.read())
            for r in results:
                synced = r.get("syncedLyrics")
                plain  = r.get("plainLyrics")
                if synced:
                    return synced, plain
            # If no synced, return first plain
            if results:
                return results[0].get("syncedLyrics"), results[0].get("plainLyrics")
    except Exception:
        pass

    return None, None


def lrc_to_vtt(lrc_text):
    """Convert LRC format to VTT format.
    LRC:  [MM:SS.xx]Line text
    VTT:  MM:SS.xxx --> MM:SS.xxx\\nLine text
    """
    import re
    lines = lrc_text.strip().split('\n')
    entries = []

    for line in lines:
        m = re.match(r'\[(\d+):(\d+)\.(\d+)\](.*)', line)
        if m:
            mins, secs, ms_part, text = m.groups()
            text = text.strip()
            if not text:
                continue
            # Normalize milliseconds to 3 digits
            ms_part = ms_part.ljust(3, '0')[:3]
            total_secs = int(mins) * 60 + int(secs) + int(ms_part) / 1000.0
            entries.append((total_secs, text))

    if not entries:
        return None

    vtt_lines = ["WEBVTT", ""]
    for i, (start, text) in enumerate(entries):
        if i + 1 < len(entries):
            end = entries[i + 1][0]
        else:
            end = start + 5.0  # last line: 5s duration

        def fmt(t):
            m = int(t // 60)
            s = t - m * 60
            return f"{m:02d}:{s:06.3f}"

        vtt_lines.append(f"{fmt(start)} --> {fmt(end)}")
        vtt_lines.append(text)
        vtt_lines.append("")

    return "\n".join(vtt_lines)


@app.route("/lyrics")
def lyrics_endpoint():
    """Serve LRCLIB lyrics as VTT. Query: ?title=...&artist=...&album=...&duration=..."""
    title  = request.args.get("title", "")
    artist = request.args.get("artist", "")
    album  = request.args.get("album", "")
    dur    = request.args.get("duration", "0")

    if not title:
        return jsonify({"error": "Missing `title` parameter"}), 400

    synced, plain = fetch_lrclib_lyrics(title, artist, album, float(dur) if dur else 0)

    if synced:
        vtt = lrc_to_vtt(synced)
        if vtt:
            import tempfile
            tmp = tempfile.NamedTemporaryFile(suffix=".vtt", delete=False, mode='w', encoding='utf-8')
            tmp.write(vtt)
            tmp.close()
            return send_file(tmp.name, mimetype='text/vtt', as_attachment=True, download_name='lyrics.vtt')

    if plain:
        # Convert plain lyrics to a simple VTT (no timestamps, just display all)
        vtt = "WEBVTT\n\n00:00.000 --> 99:59.999\n" + plain.replace("\n", "\n")
        import tempfile
        tmp = tempfile.NamedTemporaryFile(suffix=".vtt", delete=False, mode='w', encoding='utf-8')
        tmp.write(vtt)
        tmp.close()
        return send_file(tmp.name, mimetype='text/vtt', as_attachment=True, download_name='lyrics.vtt')

    return jsonify({"error": "No lyrics found"}), 404


@app.route("/info")
def video_info():
    import json
    video_id = request.args.get("id")
    if not video_id:
        return jsonify({"error": "Missing `id` parameter"}), 400

    cached_info = os.path.join(INFO_DIR, f"{video_id}.json")
    if os.path.exists(cached_info):
        try:
            with open(cached_info, 'r') as f:
                return jsonify(json.load(f))
        except:
            pass

    yt_args = ['--dump-json', f"https://www.youtube.com/watch?v={video_id}"]

    try:
        out = run_yt_dlp(yt_args)
        info = json.loads(out)

        title     = info.get("title", video_id)
        artist    = info.get("artist") or info.get("uploader") or info.get("channel") or "Unknown Artist"
        album     = info.get("album") or ""
        thumb     = info.get("thumbnail", "")
        duration  = info.get("duration", 0)
        audio_url = url_for('download_audio', id=video_id, _external=True)

        language  = info.get("language") or ""
        subs_data = {}

        for sub_type in ["subtitles", "automatic_captions"]:
            s_dict = info.get(sub_type, {})
            for lang, versions in s_dict.items():
                if not versions:
                    continue
                vtt_url = next((v['url'] for v in versions if v.get('ext') == 'vtt'), None)
                if not vtt_url:
                    vtt_url = next((v['url'] for v in versions if v.get('ext') == 'srv1'), None)
                if not vtt_url:
                    vtt_url = versions[0].get('url')

                if vtt_url and lang not in subs_data:
                    subs_data[lang] = vtt_url

        resp_data = {
            "id":       video_id,
            "title":    title,
            "artist":   artist,
            "album":    album,
            "duration": duration,
            "language": language,
            "coverUrl": thumb,
            "audioUrl": audio_url,
            "subtitleUrls": subs_data
        }

        with open(cached_info, 'w') as f:
            json.dump(resp_data, f)

        return jsonify(resp_data)
    except subprocess.CalledProcessError as e:
        return jsonify({"error": f"Metadata fetch failed: {e.output.decode()}"}), 500
    except Exception as e:
        return jsonify({"error": f"Metadata fetch failed: {e}"}), 500


@app.route("/playlist-info")
def playlist_info():
    """Return metadata for every video in a YouTube playlist."""
    playlist_url = request.args.get("url")
    playlist_id = request.args.get("id")
    
    if not playlist_url and not playlist_id:
        return jsonify({"error": "Missing `url` or `id` parameter"}), 400
        
    if not playlist_url:
        playlist_url = f"https://www.youtube.com/playlist?list={playlist_id}"

    import hashlib
    cache_id = playlist_id if playlist_id else hashlib.md5(playlist_url.encode()).hexdigest()
    cached_playlist = os.path.join(INFO_DIR, f"playlist_{cache_id}.json")
    if os.path.exists(cached_playlist):
        try:
            with open(cached_playlist, 'r') as f:
                return jsonify(json.load(f))
        except:
            pass

    try:
        out = run_yt_dlp([
            '--dump-single-json', '--flat-playlist',
            playlist_url
        ])
        result = json.loads(out)

    except subprocess.CalledProcessError as e:
        return jsonify({"error": f"Playlist fetch failed: {e.output.decode()}"}), 500
    except Exception as e:
        return jsonify({"error": f"Playlist fetch failed: {e}"}), 500

    playlist_title  = result.get("title", "Unknown Playlist")
    playlist_artist = result.get("uploader") or result.get("channel") or "Unknown Artist"
    
    thumbs = result.get("thumbnails", [])
    playlist_cover = ""
    for t in reversed(thumbs):
        url = t.get("url")
        if url:
            try:
                req = urllib.request.Request(url, method='HEAD')
                with urllib.request.urlopen(req, timeout=3) as res:
                    if res.status == 200:
                        playlist_cover = url
                        break
            except Exception:
                pass

    entries         = result.get("entries", [])

    videos = []
    for entry in entries:
        if entry is None:
            continue
        vid_id   = entry.get("id", "")
        title    = entry.get("title", vid_id)
        artist   = entry.get("artist") or entry.get("uploader") or entry.get("channel") or playlist_artist
        album    = entry.get("album") or playlist_title
        thumb    = entry.get("thumbnail", "")
        duration = entry.get("duration", 0)
        audio    = url_for('download_audio', id=vid_id, _external=True)
        videos.append({
            "id":       vid_id,
            "title":    title,
            "artist":   artist,
            "album":    album,
            "duration": duration,
            "coverUrl": thumb,
            "audioUrl": audio,
        })

    resp_data = {
        "title":    playlist_title,
        "artist":   playlist_artist,
        "coverUrl": playlist_cover,
        "videos":   videos,
    }

    with open(cached_playlist, 'w') as f:
        json.dump(resp_data, f)

    return jsonify(resp_data)
