const wsUrl = `ws://${window.location.hostname}:8081/ws/signaling`;
let ws = null;
let localStream = null;

window.addEventListener('load', async () => {
    setupWebsocket();
    await initMediaDevices();
    setupUIHandlers();
});

function setupWebsocket() {
    ws = new WebSocket(wsUrl);

    ws.onopen = () => {
        console.log("Connected to main signaling websocket");
    };

    ws.onmessage = (event) => {
        const data = JSON.parse(event.data);
        handleSignalingEvent(data);
    };

    ws.onclose = () => {
        console.warn("Disconnected from signaling websocket. Retrying...");
        setTimeout(setupWebsocket, 3000);
    };
}

async function initMediaDevices() {
    try {
        localStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
        const localVideo = document.getElementById('localVideo');
        if (localVideo) {
            localVideo.srcObject = localStream;
        }
        if (window.TelemetryProbe) {
            window.TelemetryProbe.init(localStream);
        }
    } catch (err) {
        console.error("Error accessing video/audio devices", err);
    }
}

function setupUIHandlers() {
    const chatInput = document.getElementById('chatInput');
    const sendBtn = document.getElementById('sendBtn');
    const micBtn = document.getElementById('micBtn');
    const camBtn = document.getElementById('camBtn');

    sendBtn.addEventListener('click', () => {
        sendChatMessage();
    });

    chatInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            sendChatMessage();
        }
    });

    micBtn.addEventListener('click', () => {
        const audioTracks = localStream.getAudioTracks();
        if (audioTracks.length > 0) {
            const enabled = !audioTracks[0].enabled;
            audioTracks[0].enabled = enabled;
            micBtn.classList.toggle('active', enabled);
            micBtn.innerText = enabled ? '🎙️' : '🔇';
        }
    });

    camBtn.addEventListener('click', () => {
        const videoTracks = localStream.getVideoTracks();
        if (videoTracks.length > 0) {
            const enabled = !videoTracks[0].enabled;
            videoTracks[0].enabled = enabled;
            camBtn.classList.toggle('active', enabled);
            camBtn.innerText = enabled ? '📹' : '🚫';
        }
    });
}

function sendChatMessage() {
    const input = document.getElementById('chatInput');
    const text = input.value.trim();
    if (!text || !ws || ws.readyState !== WebSocket.OPEN) return;

    const payload = {
        type: 'chat_message',
        text: text
    };
    ws.send(JSON.stringify(payload));
    input.value = '';
}

function handleSignalingEvent(data) {
    switch (data.type) {
        case 'chat':
            appendMessageBubble(data.from, data.text);
            break;
        case 'presence':
            console.log(`Presence update: user ${data.user_id || data.user.id} did ${data.action}`);
            break;
        case 'signal':
            console.log("WebRTC signal payload received:", data.signal);
            break;
        default:
            console.log("Unhandled signaling event type:", data.type);
    }
}

function appendMessageBubble(sender, text) {
    const container = document.getElementById('messagesList');
    const bubble = document.createElement('div');
    bubble.className = 'message-bubble';
    
    const header = document.createElement('div');
    header.className = 'message-header';
    
    const senderSpan = document.createElement('span');
    senderSpan.innerText = sender;
    const timeSpan = document.createElement('span');
    const now = new Date();
    timeSpan.innerText = `${now.getHours()}:${String(now.getMinutes()).padStart(2, '0')}`;
    
    header.appendChild(senderSpan);
    header.appendChild(timeSpan);
    
    const body = document.createElement('div');
    body.className = 'message-text';
    body.innerText = text;
    
    bubble.appendChild(header);
    bubble.appendChild(body);
    container.appendChild(bubble);
    
    container.scrollTop = container.scrollHeight;
}
