import os
import sys
import subprocess
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

    outtmpl = f'/tmp/{video_id}.%(ext)s'
    
    try:
        run_yt_dlp([
            '-x', '--audio-format', 'mp3',
            '--ffmpeg-location', '/usr/bin',
            '-o', outtmpl,
            '--sleep-requests', '1',
            f"https://www.youtube.com/watch?v={video_id}"
        ])
        filename = f"/tmp/{video_id}.mp3"
    except subprocess.CalledProcessError as e:
        return jsonify({"error": f"Conversion failed: {e.output.decode()}"}), 500
    except Exception as e:
        return jsonify({"error": f"Conversion failed: {e}"}), 500

    if os.path.exists(filename):
        return send_file(filename, as_attachment=True)
    else:
        return jsonify({"error": "MP3 file not found after conversion"}), 500


@app.route("/info")
def video_info():
    import json
    video_id = request.args.get("id")
    if not video_id:
        return jsonify({"error": "Missing `id` parameter"}), 400

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

        subs_data = {}
        # preferred formats for vtt or srv1 or ttml
        for sub_type in ["subtitles", "automatic_captions"]:
            s_dict = info.get(sub_type, {})
            for lang, versions in s_dict.items():
                if not versions:
                    continue
                # Pick preferable format
                vtt_url = next((v['url'] for v in versions if v.get('ext') == 'vtt'), None)
                if not vtt_url:
                    vtt_url = next((v['url'] for v in versions if v.get('ext') == 'srv1'), None)
                if not vtt_url:
                    vtt_url = versions[0].get('url')
                
                if vtt_url and lang not in subs_data:
                    subs_data[lang] = vtt_url

        return jsonify({
            "id":       video_id,
            "title":    title,
            "artist":   artist,
            "album":    album,
            "duration": duration,
            "coverUrl": thumb,
            "audioUrl": audio_url,
            "subtitleUrls": subs_data
        })
    except subprocess.CalledProcessError as e:
        return jsonify({"error": f"Metadata fetch failed: {e.output.decode()}"}), 500
    except Exception as e:
        return jsonify({"error": f"Metadata fetch failed: {e}"}), 500


@app.route("/playlist-info")
def playlist_info():
    import json
    """Return metadata for every video in a YouTube playlist."""
    playlist_id = request.args.get("id")
    if not playlist_id:
        return jsonify({"error": "Missing `id` parameter"}), 400

    try:
        out = run_yt_dlp([
            '--dump-single-json', '--flat-playlist',
            '--sleep-requests', '1',
            f"https://www.youtube.com/playlist?list={playlist_id}"
        ])
        result = json.loads(out)

        playlist_title  = result.get("title", "Unknown Playlist")
        playlist_artist = result.get("uploader") or result.get("channel") or "Unknown Artist"
        
        # Try finding a high-res thumbnail for the entire playlist
        thumbs = result.get("thumbnails", [])
        playlist_cover = thumbs[-1].get("url") if thumbs else ""

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

        return jsonify({
            "title":    playlist_title,
            "artist":   playlist_artist,
            "coverUrl": playlist_cover,
            "videos":   videos,
        })
    except subprocess.CalledProcessError as e:
        return jsonify({"error": f"Playlist fetch failed: {e.output.decode()}"}), 500
    except Exception as e:
        return jsonify({"error": f"Playlist fetch failed: {e}"}), 500
