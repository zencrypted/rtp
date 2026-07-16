import ws from 'k6/ws';
import { check } from 'k6';

export const options = {
  vus: 4,
  duration: '10s',
};

export default function () {
  const vuId = __VU;
  const roomId = `room_${vuId}`;
  const userId = `user_${vuId}`;
  
  const url = `ws://localhost:8001/ws/signaling?room=${roomId}&user=${userId}`;
  
  console.log(`[VU ${vuId}] Connecting to ${url}`);
  
  const res = ws.connect(url, null, function (socket) {
    let peerId = null;

    socket.on('open', () => {
      console.log(`[VU ${vuId}] Connected to WebSocket`);
    });

    socket.on('message', (message) => {
      console.log(`[VU ${vuId}] Message received: ${message}`);
      const data = JSON.parse(message);

      if (data.type === 'init') {
        peerId = data.peer_id;
        console.log(`[VU ${vuId}] Initialized with peerId: ${peerId}, sending ready`);
        socket.send(JSON.stringify({ type: 'ready' }));
      } else if (data.sdp && data.sdp.type === 'offer') {
        console.log(`[VU ${vuId}] Received SDP Offer, sending mock answer`);
        const answer = {
          sdp: {
            type: 'answer',
            sdp: 'v=0\no=- 123456 2 IN IP4 127.0.0.1\ns=mock\nt=0 0\na=group:BUNDLE 0 1\nm=video 9 UDP/TLS/RTP/SAVPF 96\nc=IN IP4 127.0.0.1\na=setup:active\na=mid:0\nm=audio 9 UDP/TLS/RTP/SAVPF 97\nc=IN IP4 127.0.0.1\na=setup:active\na=mid:1\n'
          }
        };
        socket.send(JSON.stringify(answer));
        
        const candidate = {
          candidate: {
            candidate: 'candidate:842163049 1 udp 16777215 127.0.0.1 9 typ host',
            sdpMLineIndex: 0,
            sdpMid: '0'
          }
        };
        socket.send(JSON.stringify(candidate));
      }
    });

    socket.on('close', () => {
      console.log(`[VU ${vuId}] Disconnected`);
    });

    socket.on('error', (err) => {
      console.error(`[VU ${vuId}] WebSocket error:`, err);
    });

    socket.setTimeout(() => {
      console.log(`[VU ${vuId}] Timeout reached, closing connection`);
      socket.close();
    }, 8000);
  });

  check(res, { 'status is 101': (r) => r && r.status === 101 });
}
