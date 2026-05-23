const urlInput = document.getElementById('url-input');
const downloadBtn = document.getElementById('download-btn');
// Use absolute URL if the page is opened from the local filesystem (file://)
const proxyBase = window.location.origin.startsWith('file') ? 'http://localhost:3000' : '';

const metadataCard = document.getElementById('metadata-card');
const metadataThumbnail = document.getElementById('metadata-thumbnail');
const metadataTitle = document.getElementById('metadata-title');
const metadataArtist = document.getElementById('metadata-artist');

const formatSelectorContainer = document.getElementById('format-selector-container');
const formatSelect = document.getElementById('format-select');
const startDownloadBtn = document.getElementById('start-download-btn');

const progressContainer = document.getElementById('progress-container');
const progressBar = document.getElementById('progress-bar');
const statusLabel = document.getElementById('status-label');
const percentLabel = document.getElementById('percent-label');
const consoleDiv = document.getElementById('console');

function log(message, type = 'info') {
  const line = document.createElement('div');
  line.className = `console-line ${type}`;
  line.textContent = `[${new Date().toLocaleTimeString()}] ${message}`;
  consoleDiv.appendChild(line);
  consoleDiv.scrollTop = consoleDiv.scrollHeight;
}

function extractVideoId(input) {
  const trimmed = input.trim();
  if (trimmed.length === 11 && !trimmed.includes('/') && !trimmed.includes('?')) {
    return trimmed;
  }
  const patterns = [
    /(?:v=|\/v\/|embed\/|shorts\/|youtu\.be\/)([\w-]{11})/,
    /^[a-zA-Z0-9_-]{11}$/
  ];
  for (const pattern of patterns) {
    const match = trimmed.match(pattern);
    if (match && match[1]) {
      return match[1];
    }
  }
  return null;
}

function resolveCipher(cipherValue) {
  const params = new URLSearchParams(cipherValue);
  const baseUrl = params.get('url');
  const signature = params.get('s');
  const sigKey = params.get('sp') || 'signature';
  if (baseUrl && signature) {
    return `${baseUrl}&${sigKey}=${encodeURIComponent(signature)}`;
  }
  return baseUrl || '';
}

// 1. Fetch metadata & populate format dropdown
downloadBtn.addEventListener('click', async () => {
  const input = urlInput.value;
  const videoId = extractVideoId(input);
  
  if (!videoId) {
    log("Error: Invalid Video ID or YouTube link format", 'error');
    alert("Please enter a valid YouTube Video ID or URL.");
    return;
  }
  
  downloadBtn.disabled = true;
  urlInput.disabled = true;
  metadataCard.style.display = 'block';
  formatSelectorContainer.style.display = 'none';
  progressContainer.style.display = 'none';
  metadataThumbnail.style.display = 'none';
  
  metadataTitle.textContent = "Fetching video details...";
  metadataArtist.textContent = "";
  
  log(`Fetching metadata for Video ID: ${videoId}...`);
  
  try {
    const response = await fetch(`${proxyBase}/info?videoId=${videoId}`);
    if (!response.ok) {
      throw new Error(`Failed to fetch metadata: status ${response.status}`);
    }
    
    const playerResponse = await response.json();
    log("Metadata successfully fetched from server.");
    
    const videoDetails = playerResponse.videoDetails || {};
    const title = videoDetails.title || "Unknown Video";
    const author = videoDetails.author || "Unknown Artist";
    
    metadataTitle.textContent = title;
    metadataArtist.textContent = author;
    
    // Display highest resolution thumbnail
    const thumbnails = videoDetails.thumbnail?.thumbnails || [];
    if (thumbnails.length > 0) {
      const bestThumbnail = thumbnails[thumbnails.length - 1];
      metadataThumbnail.src = bestThumbnail.url;
      metadataThumbnail.style.display = 'block';
    }
    
    // Filter and populate formats
    const streamingData = playerResponse.streamingData || {};
    const formats = (streamingData.adaptiveFormats || []).concat(streamingData.formats || []);
    const audioFormats = formats.filter(f => f.mimeType && f.mimeType.includes('audio/'));
    
    if (audioFormats.length === 0) {
      throw new Error("No audio formats available for this video.");
    }
    
    // Sort by bitrate descending
    audioFormats.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0));
    
    formatSelect.innerHTML = '';
    audioFormats.forEach((f) => {
      const isOpus = f.mimeType.includes('opus');
      const codecLabel = isOpus ? 'OPUS (WebM)' : 'AAC (M4A)';
      const kbps = Math.round(f.bitrate / 1000);
      
      const lenSecs = parseInt(playerResponse.videoDetails?.lengthSeconds || '0', 10);
      const estBytes = parseInt(f.contentLength || '0', 10) || Math.round((f.bitrate * lenSecs) / 8);
      const sizeMB = (estBytes / 1024 / 1024).toFixed(2);
      
      const streamUrl = f.url || (f.signatureCipher || f.cipher ? resolveCipher(f.signatureCipher || f.cipher) : '');
      
      if (!streamUrl) return;
      
      const option = document.createElement('option');
      option.value = JSON.stringify({
        url: streamUrl,
        mimeType: f.mimeType,
        totalLength: estBytes
      });
      option.textContent = `${codecLabel} | ${kbps} kbps | Est. Size: ${sizeMB} MB`;
      formatSelect.appendChild(option);
    });
    
    log(`Populated ${formatSelect.options.length} audio formats. Please choose a quality to download.`, 'success');
    formatSelectorContainer.style.display = 'block';
    
  } catch (error) {
    log(`Error resolving metadata: ${error.message}`, 'error');
    metadataTitle.textContent = "Failed to load video details";
    console.error(error);
  } finally {
    downloadBtn.disabled = false;
    urlInput.disabled = false;
  }
});

// 2. Perform parallel chunked download on selected format
startDownloadBtn.addEventListener('click', async () => {
  const selectedFormatStr = formatSelect.value;
  if (!selectedFormatStr) return;
  
  const formatInfo = JSON.parse(selectedFormatStr);
  const audioDownloadUrl = formatInfo.url;
  const mimeType = formatInfo.mimeType;
  
  if (!audioDownloadUrl) {
    alert("Could not resolve streaming URL for this format.");
    return;
  }
  
  startDownloadBtn.disabled = true;
  downloadBtn.disabled = true;
  urlInput.disabled = true;
  formatSelect.disabled = true;
  
  progressContainer.style.display = 'block';
  progressBar.style.width = '0%';
  percentLabel.textContent = '0%';
  statusLabel.textContent = 'Preparing chunked download...';
  
  log(`Initiating concurrent chunked download...`);
  
  try {
    // Query stream size via bytes=0-0 range request
    const headResponse = await fetch(`${proxyBase}/proxy?url=${encodeURIComponent(audioDownloadUrl)}`, {
      headers: { 'Range': 'bytes=0-0' }
    });
    
    let totalLength = formatInfo.totalLength || 0;
    
    if (headResponse.ok) {
      const contentRange = headResponse.headers.get('content-range');
      if (contentRange) {
        totalLength = parseInt(contentRange.split('/')[1], 10);
      }
    }
    
    if (!totalLength) {
      throw new Error("Could not resolve audio stream content length.");
    }
    
    log(`Stream content size: ${(totalLength / 1024 / 1024).toFixed(2)} MB`);
    statusLabel.textContent = 'Downloading audio stream...';
    
    const chunkSize = 512 * 1024; // 512 KB chunks
    const concurrency = 4; // Number of parallel requests
    
    const chunkRanges = [];
    let start = 0;
    while (start < totalLength) {
      const end = Math.min(start + chunkSize - 1, totalLength - 1);
      chunkRanges.push({ start, end, index: chunkRanges.length });
      start += chunkSize;
    }
    
    log(`Downloading ${chunkRanges.length} stream fragments in parallel...`);
    
    const chunks = new Array(chunkRanges.length);
    let receivedLength = 0;
    let nextChunkIndex = 0;
    
    const downloadWorker = async () => {
      while (true) {
        if (nextChunkIndex >= chunkRanges.length) {
          break;
        }
        
        const taskIndex = nextChunkIndex++;
        const { start: cStart, end: cEnd, index } = chunkRanges[taskIndex];
        
        const chunkResponse = await fetch(`${proxyBase}/proxy?url=${encodeURIComponent(audioDownloadUrl)}`, {
          headers: { 'Range': `bytes=${cStart}-${cEnd}` }
        });
        
        if (!chunkResponse.ok) {
          throw new Error(`Audio download failed at chunk ${cStart}-${cEnd}: status ${chunkResponse.status}`);
        }
        
        const arrayBuffer = await chunkResponse.arrayBuffer();
        const chunkData = new Uint8Array(arrayBuffer);
        chunks[index] = chunkData;
        
        receivedLength += chunkData.length;
        
        // Update UI progress
        const percent = Math.round((receivedLength / totalLength) * 100);
        const mappedPercent = Math.round(10 + (percent * 0.85));
        progressBar.style.width = `${mappedPercent}%`;
        percentLabel.textContent = `${percent}%`;
        statusLabel.textContent = `Downloading: ${(receivedLength / 1024 / 1024).toFixed(2)}MB / ${(totalLength / 1024 / 1024).toFixed(2)}MB`;
      }
    };
    
    const workers = [];
    for (let i = 0; i < Math.min(concurrency, chunkRanges.length); i++) {
      workers.push(downloadWorker());
    }
    
    await Promise.all(workers);
    
    statusLabel.textContent = 'Compiling file...';
    progressBar.style.width = '98%';
    percentLabel.textContent = '98%';
    log(`Download complete. Assembling fragments...`);
    
    const mime = mimeType.split(';')[0] || 'audio/mp4';
    const audioBlob = new Blob(chunks, { type: mime });
    
    let fileExtension = 'm4a';
    if (mime.includes('webm')) {
      fileExtension = 'webm';
    } else if (mime.includes('ogg')) {
      fileExtension = 'ogg';
    }
    
    const title = metadataTitle.textContent;
    const author = metadataArtist.textContent;
    const safeFilename = `${author} - ${title}`.replace(/[\\/:*?"<>|]/g, "") + `.${fileExtension}`;
    const blobUrl = URL.createObjectURL(audioBlob);
    
    const downloadLink = document.createElement('a');
    downloadLink.href = blobUrl;
    downloadLink.download = safeFilename;
    document.body.appendChild(downloadLink);
    downloadLink.click();
    document.body.removeChild(downloadLink);
    
    setTimeout(() => URL.revokeObjectURL(blobUrl), 100);
    
    progressBar.style.width = '100%';
    percentLabel.textContent = '100%';
    statusLabel.textContent = 'Done!';
    log(`File saved: ${safeFilename}`, 'success');
    
  } catch (error) {
    log(`Download failed: ${error.message}`, 'error');
    statusLabel.textContent = 'Download failed';
    progressBar.style.width = '0%';
    percentLabel.textContent = 'Error';
    console.error(error);
  } finally {
    startDownloadBtn.disabled = false;
    downloadBtn.disabled = false;
    urlInput.disabled = false;
    formatSelect.disabled = false;
  }
});
