
        // Room/user survive F5: URL params take priority, localStorage as fallback.
        const urlParams = new URLSearchParams(window.location.search);
        const roomName = urlParams.get('room')
                      || localStorage.getItem('rtp_room')
                      || 'lobby';
        const userName = urlParams.get('user')
                      || localStorage.getItem('rtp_user')
                      || 'guest';
        const sessionToken = urlParams.get('token')
                      || localStorage.getItem('rtp_token')
                      || '';

        // Persist so F5 without URL params still knows who/where we are
        localStorage.setItem('rtp_room', roomName);
        localStorage.setItem('rtp_user', userName);
        if (sessionToken) {
            localStorage.setItem('rtp_token', sessionToken);
        }

        // Keep URL in sync (makes sharing/bookmarking work)
        if (!urlParams.get('room') || !urlParams.get('user') || (sessionToken && !urlParams.get('token'))) {
            const next = new URL(window.location.href);
            next.searchParams.set('room', roomName);
            next.searchParams.set('user', userName);
            if (sessionToken) next.searchParams.set('token', sessionToken);
            history.replaceState(null, '', next.toString());
        }

        document.getElementById('currentUserSpan').textContent = userName + ' (You)';
        document.getElementById('currentUserSpanSidebar').textContent = userName + ' (You)';

        // Sidebar tab selector buttons
        const tabChat = document.getElementById('tabChat');
        const tabMembers = document.getElementById('tabMembers');
        const chatSection = document.getElementById('chatSection');
        const membersSection = document.getElementById('membersSection');

        tabChat.onclick = () => {
            tabChat.classList.add('active');
            tabMembers.classList.remove('active');
            chatSection.style.display = 'flex';
            membersSection.style.display = 'none';
        };

        tabMembers.onclick = () => {
            tabMembers.classList.add('active');
            tabChat.classList.remove('active');
            chatSection.style.display = 'none';
            membersSection.style.display = 'flex';
        };

        // WebRTC Signaling elements
        const remoteVideo = document.getElementById('remoteVideo');
        const localVideo  = document.getElementById('localVideo');
        const btnJoin      = document.getElementById('btnJoin');
        const btnMuteVideo = document.getElementById('btnMuteVideo');
        let signalingWs = null;
        let pc          = null;
        let localStream = null;
        let peerId      = null;
        let pingInterval= null;
        let autoJoin    = localStorage.getItem('rtp_joined') === 'true';
        let pendingRemoteSdp = null;
        let pendingRemoteCandidates = [];

        async function handleRemoteSdp(sdpMsg) {
            if (!pc) {
                console.warn('Queued remote SDP until RTCPeerConnection is created:', sdpMsg);
                pendingRemoteSdp = sdpMsg;
                return;
            }
            try {
                let sdpObj = Object.assign({}, sdpMsg);
                if (sdpObj.sdp && !sdpObj.sdp.includes('a=group:BUNDLE')) {
                    const mids = [...sdpObj.sdp.matchAll(/a=mid:(\w+)/g)].map(m => m[1]);
                    if (mids.length > 0) {
                        const bundleLine = `a=group:BUNDLE ${mids.join(' ')}\r\n`;
                        const firstMLine = sdpObj.sdp.indexOf('m=');
                        if (firstMLine !== -1) {
                            sdpObj.sdp = sdpObj.sdp.slice(0, firstMLine) + bundleLine + sdpObj.sdp.slice(firstMLine);
                            console.log('Auto-injected BUNDLE group line into SDP offer:', bundleLine.trim());
                        }
                    }
                }
                console.log('Applying remote SDP:', sdpObj);
                await pc.setRemoteDescription(new RTCSessionDescription(sdpObj));
                if (sdpObj.type === 'offer') {
                    const answer = await pc.createAnswer();
                    await pc.setLocalDescription(answer);
                    console.log('Sending SDP answer to server:', pc.localDescription);
                    signalingWs.send(JSON.stringify({ sdp: pc.localDescription }));
                }
                if (pendingRemoteCandidates.length > 0) {
                    console.log(`Flushing ${pendingRemoteCandidates.length} queued ICE candidates...`);
                    for (const cand of pendingRemoteCandidates) {
                        try {
                            if (cand.candidate === '') {
                                await pc.addIceCandidate(null);
                            } else {
                                await pc.addIceCandidate(new RTCIceCandidate(cand));
                            }
                        } catch(e) { console.error('Error applying queued ICE candidate:', e); }
                    }
                    pendingRemoteCandidates = [];
                }
            } catch(err) {
                console.error('Error applying remote SDP:', err);
            }
        }

        async function handleRemoteCandidate(candMsg) {
            if (!pc || !pc.remoteDescription) {
                console.log('Queued remote ICE candidate until remote SDP is set:', candMsg);
                pendingRemoteCandidates.push(candMsg);
                return;
            }
            try {
                if (candMsg.candidate === '') {
                    console.log('ICE gathering complete (end-of-candidates from server)');
                    await pc.addIceCandidate(null);
                } else {
                    await pc.addIceCandidate(new RTCIceCandidate(candMsg));
                }
            } catch (err) {
                console.error('Error adding ICE candidate:', err);
            }
        }

        function connectSignaling() {
            // Connect to signaling websocket using fallback auth query params
            signalingWs = new WebSocket('ws://' + window.location.hostname + ':8001/ws/signaling?room=' + encodeURIComponent(roomName) + '&user=' + encodeURIComponent(userName) + '&token=' + encodeURIComponent(sessionToken));

            signalingWs.onopen = () => {
                console.log('Signaling connected — standing by for init');

                pingInterval = setInterval(() => {
                    if (signalingWs && signalingWs.readyState === WebSocket.OPEN) {
                        signalingWs.send(JSON.stringify({ type: 'ping' }));
                    }
                }, 5000);
            };

            signalingWs.onclose = () => {
                console.log('WebRTC Signaling disconnected');
                if (pingInterval) clearInterval(pingInterval);
                resetWebRTC();
            };

            signalingWs.onmessage = async (e) => {
                const msg = JSON.parse(e.data);
                console.log('WebRTC signaling msg:', msg);

                if (msg.type === 'init') {
                    peerId = msg.peer_id;
                    console.log('My Peer ID:', peerId);
                    if (autoJoin && !pc) {
                        console.log('Init received — starting conference');
                        startConference();
                    }
                } else if (msg.type === 'room_info') {
                    const startedAt = msg.started_at;
                    const now = Date.now();
                    const deltaMs = now - startedAt;
                    console.log(`Room started at: ${startedAt}. Delta from now: ${deltaMs}ms`);
                    document.getElementById('streamLabel').style.display = 'none';
                } else if (msg.type === 'reset_webrtc') {
                    console.warn('Server media process restarted — resetting WebRTC connection');
                    if (pc) {
                        pc.close();
                        pc = null;
                    }
                    if (autoJoin) {
                        console.log('Re-starting conference following media server reset...');
                        startConference();
                    }
                } else if (msg.sdp) {
                    await handleRemoteSdp(msg.sdp);
                } else if (msg.candidate) {
                    await handleRemoteCandidate(msg.candidate);
                }
            };
        }

        btnJoin.addEventListener('click', () => {
            autoJoin = true;
            localStorage.setItem('rtp_joined', 'true');
            if (!signalingWs) {
                connectSignaling();
            } else {
                startConference();
            }
        });


        async function startConference() {
            if (pc) return;
            try {
                autoJoin = true;
                localStorage.setItem('rtp_joined', 'true');  // remember: user is joined
                btnJoin.disabled = true;
                btnJoin.textContent = '⌛';

                try {
                    localStream = await navigator.mediaDevices.getUserMedia({ 
                        video: { width: 640, height: 360, frameRate: 30 }, 
                        audio: true 
                    });
                } catch (e) {
                    console.warn('Webcam acquisition failed (webcam in use by another tab or unavailable). Using synthetic canvas video fallback:', e);
                    try {
                        localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
                    } catch (ae) {
                        localStream = new MediaStream();
                    }
                    const canvas = document.createElement('canvas');
                    canvas.width = 640;
                    canvas.height = 360;
                    const ctx = canvas.getContext('2d');
                    let frame = 0;
                    let hash = 0;
                    for (let i = 0; i < userName.length; i++) { hash = (hash << 5) - hash + userName.charCodeAt(i); hash |= 0; }
                    const hue = Math.abs(hash) % 360;
                    setInterval(() => {
                        frame++;
                        ctx.fillStyle = `hsl(${hue}, 65%, 28%)`;
                        ctx.fillRect(0, 0, canvas.width, canvas.height);
                        ctx.fillStyle = '#ffffff';
                        ctx.font = 'bold 36px sans-serif';
                        ctx.textAlign = 'center';
                        ctx.fillText(userName, canvas.width / 2, canvas.height / 2 - 10);
                        ctx.font = '20px sans-serif';
                        ctx.fillText('⚡ Synthetic Feed (Webcam Shared)', canvas.width / 2, canvas.height / 2 + 30);
                    }, 1000 / 30);
                    const synthTrack = canvas.captureStream(30).getVideoTracks()[0];
                    localStream.addTrack(synthTrack);
                }

                const hasVideo = localStream.getVideoTracks().length > 0;
                if (hasVideo) {
                    localVideo.srcObject = localStream;
                    localVideo.style.display = 'block';
                    btnMuteVideo.disabled = false;
                    btnMuteVideo.classList.add('active');
                } else {
                    localVideo.style.display = 'none';
                    btnMuteVideo.disabled = true;
                    btnMuteVideo.classList.remove('active');
                }

                btnMuteAudio.disabled = false;
                btnMuteAudio.classList.add('active');

                let rtcConfig = {
                    bundlePolicy: 'balanced',
                    iceServers: [
                        { urls: 'stun:' + window.location.hostname + ':3478' },
                        {
                            urls: 'turn:' + window.location.hostname + ':3478?transport=udp',
                            username: 'rtpuser',
                            credential: 'rtppassword'
                        },
                        {
                            urls: 'turn:' + window.location.hostname + ':3478?transport=tcp',
                            username: 'rtpuser',
                            credential: 'rtppassword'
                        }
                    ]
                };
                pc = new RTCPeerConnection(rtcConfig);

                pc.ontrack = (event) => {
                    console.log('Received remote track:', event.track.kind, event.track.id);
                    let stream = event.streams[0];
                    if (stream) {
                        if (remoteVideo.srcObject !== stream) {
                            remoteVideo.srcObject = stream;
                        }
                    } else {
                        if (!remoteVideo.srcObject) {
                            remoteVideo.srcObject = new MediaStream();
                        }
                        if (!remoteVideo.srcObject.getTracks().some(t => t.id === event.track.id)) {
                            remoteVideo.srcObject.addTrack(event.track);
                        }
                    }

                    remoteVideo.style.display = 'block';
                    if (remoteVideo.paused) {
                        remoteVideo.play().catch(e => {
                            if (e.name === 'AbortError') return; // ignore benign play race
                            console.error("WebRTC play error:", e);
                            if (e.name === 'NotAllowedError') {
                            const overlay = document.createElement('button');
                            overlay.textContent = '🔊 Натисніть для відтворення (Autoplay заблоковано)';
                            overlay.style.position = 'absolute';
                            overlay.style.top = '50%';
                            overlay.style.left = '50%';
                            overlay.style.transform = 'translate(-50%, -50%)';
                            overlay.style.zIndex = '9999';
                            overlay.style.padding = '15px 25px';
                            overlay.style.fontSize = '16px';
                            overlay.style.cursor = 'pointer';
                            overlay.style.borderRadius = '8px';
                            overlay.style.backgroundColor = '#1e88e5';
                            overlay.style.color = '#fff';
                            overlay.style.border = 'none';
                            overlay.onclick = () => {
                                remoteVideo.play();
                                overlay.remove();
                            };
                            // Add position relative to the container if not already
                            remoteVideo.parentElement.style.position = 'relative';
                            remoteVideo.parentElement.appendChild(overlay);
                        }
                    });
                    document.getElementById('streamLabel').textContent = '🔴 Ефір — GStreamer MCU Потік';
                    document.getElementById('streamLabel').style.display = 'block';
                };

                pc.oniceconnectionstatechange = () => console.log('ICE Connection State changed:', pc.iceConnectionState);
                pc.onconnectionstatechange = () => console.log('Peer Connection State changed:', pc.connectionState);
                pc.onicegatheringstatechange = () => console.log('ICE Gathering State changed:', pc.iceGatheringState);

                pc.onicecandidate = (event) => {
                    if (event.candidate) {
                        console.log('Gathered client ICE Candidate:', event.candidate.candidate);
                        signalingWs.send(JSON.stringify({ candidate: event.candidate }));
                    }
                };

                const videoTrack = localStream.getVideoTracks()[0];
                const audioTrack = localStream.getAudioTracks()[0];
                if (videoTrack) {
                    console.log('Adding local video track (m-line 0):', videoTrack);
                    pc.addTrack(videoTrack, localStream);
                }
                if (audioTrack) {
                    console.log('Adding local audio track (m-line 1):', audioTrack);
                    pc.addTrack(audioTrack, localStream);
                }

                signalingWs.send(JSON.stringify({ type: 'ready' }));

                if (pendingRemoteSdp) {
                    console.log('Applying pending remote SDP that arrived during startConference...');
                    const sdpToApply = pendingRemoteSdp;
                    pendingRemoteSdp = null;
                    await handleRemoteSdp(sdpToApply);
                }

                btnJoin.textContent = '❌';
                btnJoin.classList.remove('join-btn');
                btnJoin.classList.add('decline');
                btnJoin.onclick = leaveConference;
                btnJoin.disabled = false;

            } catch (err) {
                console.error('Join failed:', err);
                alert('Microphone/Webcam access denied or connection issue: ' + err.message);
                resetWebRTC();
            }
        }

        function leaveConference() {
            autoJoin = false;
            localStorage.removeItem('rtp_joined');  // F5 after Disconnect → stays disconnected
            if (signalingWs) {
                signalingWs.onclose = null;  // prevent double-reset
                signalingWs.close();
                signalingWs = null;
            }
            resetWebRTC();
            connectSignaling();
        }

        function resetWebRTC() {
            pendingRemoteSdp = null;
            pendingRemoteCandidates = [];
            if (localStream) { localStream.getTracks().forEach(t => t.stop()); localStream = null; }
            if (pc) { pc.close(); pc = null; }
            remoteVideo.srcObject = null;
            localVideo.srcObject = null;
            localVideo.style.display = 'none';
            document.getElementById('streamLabel').textContent = '⬛ Очікування трансляції MCU...';

            btnJoin.disabled = false;
            btnJoin.textContent = '📞';
            btnJoin.classList.remove('decline');
            btnJoin.classList.add('join-btn');
            btnJoin.onclick = startConference;

            btnMuteVideo.disabled = true;
            btnMuteVideo.classList.remove('active');
            btnMuteAudio.disabled = true;
            btnMuteAudio.classList.remove('active');
        }

        btnMuteVideo.onclick = () => {
            const videoTrack = localStream.getVideoTracks()[0];
            if (videoTrack) {
                videoTrack.enabled = !videoTrack.enabled;
                btnMuteVideo.classList.toggle('active', videoTrack.enabled);
                localVideo.style.display = videoTrack.enabled ? 'block' : 'none';
            }
        };

        btnMuteAudio.onclick = () => {
            const audioTrack = localStream.getAudioTracks()[0];
            if (audioTrack) {
                audioTrack.enabled = !audioTrack.enabled;
                btnMuteAudio.classList.toggle('active', audioTrack.enabled);
            }
        };

        btnJoin.onclick = startConference;

        // WebRTC real-time telemetry stats
        setInterval(async () => {
            if (pc && pc.signalingState !== 'closed') {
                try {
                    const stats = await pc.getStats();
                    stats.forEach(report => {
                        if (report.type === 'remote-inbound-rtp') {
                            if (report.roundTripTime !== undefined) {
                                document.getElementById('rttVal').textContent = Math.round(report.roundTripTime * 1000) + ' ms';
                            }
                            if (report.packetsLost !== undefined && report.packetsReceived !== undefined) {
                                const total = report.packetsLost + report.packetsReceived;
                                const lossRate = total > 0 ? (report.packetsLost / total) * 100 : 0;
                                document.getElementById('lossVal').textContent = lossRate.toFixed(2) + '%';
                            }
                        }
                        if (report.type === 'candidate-pair' && report.state === 'succeeded') {
                            if (report.currentRoundTripTime !== undefined) {
                                document.getElementById('rttVal').textContent = Math.round(report.currentRoundTripTime * 1000) + ' ms';
                            }
                        }
                    });
                } catch (e) {
                    console.warn('Telemetry check failed:', e);
                }
            } else {
                document.getElementById('rttVal').textContent = '0 ms';
                document.getElementById('lossVal').textContent = '0.00%';
            }
        }, 2000);

        connectSignaling();
