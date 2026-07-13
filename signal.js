// signal.js
const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');
const readline = require('readline');

// Start the GStreamer mixer process
console.log('Starting GStreamer mixer...');
const mixer = spawn('./gst-mixer.sh', ['output.mp4']);

mixer.stderr.pipe(process.stderr);

mixer.on('close', (code) => {
  console.log(`Mixer process exited with code ${code}`);
  process.exit(code);
});

process.on('SIGINT', () => {
  console.log('Received SIGINT in signal.js, propagating SIGINT to GStreamer...');
  mixer.kill('SIGINT');
});

process.on('SIGTERM', () => {
  console.log('Received SIGTERM in signal.js, propagating SIGTERM to GStreamer...');
  mixer.kill('SIGTERM');
});

// Map of peer_id -> WebSocket
const peers = new Map();

// Helper to write JSON to GStreamer's stdin
function sendToMixer(obj) {
  const json = JSON.stringify(obj);
  mixer.stdin.write(json + '\n');
}

// Read JSON messages from GStreamer stdout line by line
const rl = readline.createInterface({
  input: mixer.stdout,
  terminal: false
});

rl.on('line', (line) => {
  if (!line.trim()) return;
  try {
    const msg = JSON.parse(line);
    const peerId = msg.peer_id;
    const ws = peers.get(peerId);
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      console.warn(`Warning: Received message for inactive peer ${peerId}`);
      return;
    }

    if (msg.type === 'sdp_offer') {
      console.log(`Forwarding SDP Offer to client ${peerId}`);
      ws.send(JSON.stringify({
        sdp: {
          type: 'offer',
          sdp: msg.sdp
        }
      }));
    } else if (msg.type === 'ice_candidate') {
      console.log(`Forwarding ICE candidate to client ${peerId}`);
      ws.send(JSON.stringify({
        candidate: msg.candidate
      }));
    }
  } catch (err) {
    console.error('Failed to parse message from GStreamer:', line, err);
  }
});

// Create HTTP server to serve mcu.html
const server = http.createServer((req, res) => {
  if (req.url === '/' || req.url === '/mcu.html') {
    fs.readFile(path.join(__dirname, 'mcu.html'), (err, data) => {
      if (err) {
        res.writeHead(500);
        res.end('Error loading mcu.html');
      } else {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(data);
      }
    });
  } else {
    res.writeHead(404);
    res.end('Not Found');
  }
});

// Start the WebSocket signaling server sharing the HTTP server port
const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
  // Generate a unique peer ID for this connection
  const peerId = 'peer_' + Math.random().toString(36).substr(2, 9);
  peers.set(peerId, ws);
  console.log(`Client connected: ${peerId}`);

  // Send peer ID to client
  ws.send(JSON.stringify({ type: 'init', peer_id: peerId }));

  ws.on('message', (message) => {
    try {
      const msg = JSON.parse(message);
      
      if (msg.type === 'ready') {
        console.log(`Client ${peerId} is ready, notifying GStreamer`);
        sendToMixer({
          type: 'peer_joined',
          peer_id: peerId
        });
      } else if (msg.sdp && msg.sdp.type === 'answer') {
        console.log(`Received SDP Answer from client ${peerId}`);
        sendToMixer({
          type: 'sdp_answer',
          peer_id: peerId,
          sdp: msg.sdp.sdp
        });
      } else if (msg.candidate) {
        console.log(`Received ICE Candidate from client ${peerId}`);
        sendToMixer({
          type: 'ice_candidate',
          peer_id: peerId,
          candidate: msg.candidate
        });
      }
    } catch (err) {
      console.error(`Error handling message from client ${peerId}:`, err);
    }
  });

  ws.on('close', () => {
    console.log(`Client disconnected: ${peerId}`);
    peers.delete(peerId);
  });
});

server.listen(8888, '0.0.0.0', () => {
  console.log('Signaling & web server running at http://localhost:8888');
});
