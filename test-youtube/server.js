const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');
const dns = require('dns');

const PORT = process.env.PORT || 3000;

// Force IPv4 resolution first to avoid IPv6 connection hangs on macOS
if (typeof dns.setDefaultResultOrder === 'function') {
  dns.setDefaultResultOrder('ipv4first');
}

// Robust Cookie Loader and Parser
function parseCookieString(content) {
  if (!content) return null;
  
  // If it's a Netscape format string (has tabs or starts with #)
  if (content.includes('\t') || content.includes('# Netscape')) {
    const cookieArray = [];
    const lines = content.split(/\r?\n/);
    for (let line of lines) {
      line = line.trim();
      if (!line || line.startsWith('#')) continue;
      const parts = line.split('\t');
      if (parts.length >= 7) {
        const name = parts[5];
        const value = parts[6];
        cookieArray.push(`${name}=${value}`);
      }
    }
    if (cookieArray.length > 0) {
      return cookieArray.join('; ');
    }
  }
  
  // Otherwise, assume it's already a raw semicolon-separated cookie header string
  const clean = content.replace(/\r?\n/g, ' ').trim();
  if (clean.includes('=')) {
    return clean;
  }
  
  return null;
}

function loadCookies() {
  // 1. Try environment variable first
  if (process.env.YT_COOKIE) {
    const parsed = parseCookieString(process.env.YT_COOKIE);
    if (parsed) {
      console.log(`[Cookies] Successfully loaded and parsed YT_COOKIE environment variable (length: ${parsed.length})`);
      return parsed;
    }
    console.warn(`[Cookies Warning] YT_COOKIE environment variable is set but could not be parsed.`);
  }

  // 2. Try looking for cookie files in the workspace
  const cookiePaths = [
    path.join(__dirname, 'youtube_cookies.txt'),
    path.join(__dirname, 'www.youtube.com_cookies.txt'),
    path.join(__dirname, '../youtube_cookies.txt'),
    path.join(__dirname, '../www.youtube.com_cookies.txt'),
  ];

  for (const p of cookiePaths) {
    if (fs.existsSync(p)) {
      try {
        const content = fs.readFileSync(p, 'utf8');
        const parsed = parseCookieString(content);
        if (parsed) {
          console.log(`[Cookies] Loaded cookies from file: ${path.basename(p)} (length: ${parsed.length})`);
          return parsed;
        }
      } catch (err) {
        console.error(`[Cookies Error] Failed reading cookie file ${path.basename(p)}: ${err.message}`);
      }
    }
  }

  console.warn(`[Cookies Warning] No valid cookies found in YT_COOKIE or cookie files.`);
  return null;
}

// Extraction helpers
function extractPlayerResponse(html) {
  const markers = [
    'ytInitialPlayerResponse = ',
    'ytInitialPlayerResponse={',
    'window["ytInitialPlayerResponse"] = '
  ];

  for (const marker of markers) {
    let index = -1;
    while ((index = html.indexOf(marker, index + 1)) !== -1) {
      let start = index + marker.length;
      if (html[start - 1] === '{') {
        start = start - 1;
      }
      
      const rest = html.substring(start);
      let depth = 0;
      let inString = false;
      let escape = false;
      let jsonStr = '';
      
      for (let i = 0; i < rest.length; i++) {
        const char = rest[i];
        jsonStr += char;
        
        if (escape) {
          escape = false;
        } else if (inString) {
          if (char === '\\') {
            escape = true;
          } else if (char === '"') {
            inString = false;
          }
        } else {
          if (char === '"') {
            inString = true;
          } else if (char === '{') {
            depth++;
          } else if (char === '}') {
            depth--;
            if (depth === 0) {
              break;
            }
          }
        }
      }
      
      try {
        const parsed = JSON.parse(jsonStr);
        if (parsed && typeof parsed === 'object') {
          return parsed;
        }
      } catch (e) {
        // Continue searching
      }
    }
  }
  return null;
}

function extractAPIKey(html) {
  const markers = [
    '"INNERTUBE_API_KEY":"',
    '"innertubeApiKey":"',
    '"INNERTUBE_API_KEY": "',
    '"innertubeApiKey": "'
  ];
  for (const m of markers) {
    const idx = html.indexOf(m);
    if (idx !== -1) {
      const rest = html.substring(idx + m.length);
      const endIdx = rest.indexOf('"');
      if (endIdx !== -1) {
        return rest.substring(0, endIdx).trim();
      }
    }
  }
  return null;
}

function extractSTS(html) {
  const match = html.match(/"STS"\s*:\s*(\d+)/i);
  return match ? parseInt(match[1], 10) : null;
}

async function fetchInnertubeMetadata(videoId, apiKey, sts) {
  const payload = {
    context: {
      client: {
        clientName: 'ANDROID_VR',
        clientVersion: '1.65.10',
        platform: 'MOBILE',
        hl: 'en',
        gl: 'US',
        userAgent: 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
        deviceMake: 'Oculus',
        deviceModel: 'Quest 3',
        androidSdkVersion: 32,
        osName: 'Android',
        osVersion: '12L',
        timeZone: 'UTC',
        utcOffsetMinutes: 0
      }
    },
    videoId: videoId,
    racyCheckOk: true,
    contentCheckOk: true
  };

  if (sts) {
    payload.playbackContext = {
      contentPlaybackContext: {
        html5Preference: 'HTML5_PREF_WANTS',
        signatureTimestamp: sts
      }
    };
  }

  const endpoint = `https://www.youtube.com/youtubei/v1/player?key=${apiKey}&prettyPrint=false`;
  
  const headers = {
    'Content-Type': 'application/json',
    'User-Agent': payload.context.client.userAgent,
    'Origin': 'https://www.youtube.com',
    'Referer': `https://www.youtube.com/watch?v=${videoId}`
  };

  const cookieString = loadCookies();
  if (cookieString) {
    headers['Cookie'] = cookieString;
  }

  const res = await fetch(endpoint, {
    method: 'POST',
    headers: headers,
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(15000)
  });

  if (!res.ok) {
    throw new Error(`Innertube fetch failed with status ${res.status}`);
  }

  return await res.json();
}

function getBestAudioFormat(playerResponse) {
  if (!playerResponse || !playerResponse.streamingData) return null;
  const streamingData = playerResponse.streamingData;
  const formats = (streamingData.adaptiveFormats || []).concat(streamingData.formats || []);
  const audioFormats = formats.filter(f => f.mimeType && f.mimeType.includes('audio/'));
  if (audioFormats.length === 0) return null;
  
  audioFormats.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0));
  return audioFormats[0];
}

const server = http.createServer(async (req, res) => {
  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Expose-Headers', '*');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  const parsedUrl = url.parse(req.url, true);
  const pathname = parsedUrl.pathname;

  if (pathname === '/info') {
    const videoId = parsedUrl.query.videoId;
    if (!videoId) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('Missing videoId parameter');
      return;
    }

    console.log(`[Info] Resolving metadata for Video ID: ${videoId}`);

    try {
      const watchUrl = `https://www.youtube.com/watch?v=${videoId}&bpctr=9999999999&has_verified=1&hl=en&gl=US`;
      
      const headers = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      };

      const cookieString = loadCookies();
      if (cookieString) {
        headers['Cookie'] = cookieString;
      }

      const watchRes = await fetch(watchUrl, {
        headers: headers,
        signal: AbortSignal.timeout(15000)
      });

      if (!watchRes.ok) {
        throw new Error(`Failed to fetch watch page: ${watchRes.status}`);
      }

      const html = await watchRes.text();
      let playerResponse = extractPlayerResponse(html);

      if (!playerResponse) {
        console.error(`[Info Error] extractPlayerResponse failed. HTML length: ${html.length}. First 600 chars:`);
        console.error(html.substring(0, 600));
        const titleMatch = html.match(/<title>(.*?)<\/title>/i);
        console.error(`[Info Error] Page Title: ${titleMatch ? titleMatch[1] : 'No Title Tag'}`);
        throw new Error('Could not parse playerResponse from watch page');
      }

      // Check if the best audio format has encrypted signatureCipher
      const bestAudio = getBestAudioFormat(playerResponse);
      if (bestAudio && !bestAudio.url && (bestAudio.signatureCipher || bestAudio.cipher)) {
        console.log('[Info] Encrypted signature cipher detected. Fetching clean URLs via Innertube fallback...');
        const apiKey = extractAPIKey(html);
        const sts = extractSTS(html);

        if (apiKey) {
          try {
            const innertubeData = await fetchInnertubeMetadata(videoId, apiKey, sts);
            const innertubeBest = getBestAudioFormat(innertubeData);
            if (innertubeBest && innertubeBest.url) {
              console.log('[Info] Successfully resolved direct URLs from Innertube!');
              playerResponse = innertubeData;
            } else {
              console.log('[Info] Innertube format also missing direct URL, keeping watch page response');
            }
          } catch (innertubeErr) {
            console.error('[Info] Innertube fallback failed:', innertubeErr.message);
          }
        } else {
          console.log('[Info] No API Key found, skipping Innertube fallback');
        }
      } else {
        console.log('[Info] Watch page response returned direct unencrypted URLs.');
      }

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(playerResponse));

    } catch (err) {
      console.error(`[Info Error] ${err.message}`);
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end(`Error: ${err.message}`);
    }
  } else if (pathname === '/proxy') {
    const targetUrl = parsedUrl.query.url;
    if (!targetUrl) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('Missing url parameter');
      return;
    }

    let target;
    try {
      target = new URL(targetUrl);
    } catch {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('Invalid url parameter');
      return;
    }

    const hostname = target.hostname.toLowerCase();
    const isYouTubeHost = hostname === 'youtube.com' || hostname.endsWith('.youtube.com');
    const isGoogleVideoHost = hostname === 'googlevideo.com' || hostname.endsWith('.googlevideo.com');
    if (target.protocol !== 'https:' || (!isYouTubeHost && !isGoogleVideoHost)) {
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('Proxy target is not an approved YouTube media host');
      return;
    }

    console.log(`[Proxy] Fetching: ${target.toString().substring(0, 80)}...`);

    try {
      const requestHeaders = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
      };

      if (req.headers.range) {
        requestHeaders['Range'] = req.headers.range;
      }

      const cookieString = loadCookies();
      if (cookieString && isYouTubeHost) {
        requestHeaders['Cookie'] = cookieString;
      }

      // NO AbortSignal.timeout here to allow long stream downloads to finish
      const response = await fetch(targetUrl, {
        method: req.method,
        headers: requestHeaders,
        redirect: 'follow'
      });

      console.log(`[Proxy] Response: ${response.status} ${response.statusText}`);

      const resHeaders = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': '*',
        'Access-Control-Expose-Headers': '*',
      };

      const copyHeaders = ['content-type', 'content-range', 'accept-ranges'];
      for (const h of copyHeaders) {
        if (response.headers.has(h)) {
          resHeaders[h] = response.headers.get(h);
        }
      }

      if (response.headers.has('content-length') && !response.headers.has('content-encoding')) {
        resHeaders['content-length'] = response.headers.get('content-length');
      }

      res.writeHead(response.status, resHeaders);

      if (response.body) {
        const { Readable, pipeline } = require('stream');
        // pipeline automatically cleans up streams and handles errors, preventing server crashes
        pipeline(
          Readable.fromWeb(response.body),
          res,
          (err) => {
            if (err) {
              console.error(`[Proxy Stream Error] ${err.message}`);
            }
          }
        );
      } else {
        res.end();
      }
    } catch (err) {
      console.error(`[Proxy Error] ${err.message}`);
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end(`Proxy error: ${err.message}`);
    }
  } else {
    // Serve static files from 'public' directory
    const publicRoot = path.resolve(__dirname, 'public');
    const filePath = path.resolve(publicRoot, pathname === '/' ? 'index.html' : `.${pathname}`);
    if (filePath !== publicRoot && !filePath.startsWith(`${publicRoot}${path.sep}`)) {
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('Forbidden');
      return;
    }
    const ext = path.extname(filePath);
    
    const contentTypeMap = {
      '.html': 'text/html',
      '.js': 'text/javascript',
      '.css': 'text/css',
      '.json': 'application/json',
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.gif': 'image/gif'
    };
    
    const contentType = contentTypeMap[ext] || 'text/plain';

    fs.readFile(filePath, (err, content) => {
      if (err) {
        if (err.code === 'ENOENT') {
          res.writeHead(404, { 'Content-Type': 'text/plain' });
          res.end('File not found');
        } else {
          res.writeHead(500, { 'Content-Type': 'text/plain' });
          res.end(`Server error: ${err.code}`);
        }
      } else {
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(content, 'utf-8');
      }
    });
  }
});

server.listen(PORT, () => {
  console.log(`Server running at http://localhost:${PORT}`);
});
