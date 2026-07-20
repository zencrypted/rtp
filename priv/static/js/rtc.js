
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
        const btnMuteAudio = document.getElementById('btnMuteAudio');

        let signalingWs = null;
        let pc          = null;
        let localStream = null;
        let peerId      = null;
        let pingInterval= null;
        // Persisted join state: true if user was joined before F5, false if they explicitly disconnected
        let autoJoin    = localStorage.getItem('rtp_joined') === 'true';

        function connectSignaling() {
            // Connect to signaling websocket using fallback auth query params
            signalingWs = new WebSocket('ws://' + window.location.hostname + ':8001/ws/signaling?room=' + encodeURIComponent(roomName) + '&user=' + encodeURIComponent(userName) + '&token=' + encodeURIComponent(sessionToken));

            signalingWs.onopen = () => {
                if (autoJoin) {
                    console.log('Signaling connected — auto-joining conference');
                    startConference();
                } else {
                    console.log('Signaling connected — standing by (Disconnect was pressed)');
                }

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
                } else if (msg.type === 'room_info') {
                    const startedAt = msg.started_at;
                    const now = Date.now();
                    const deltaMs = now - startedAt;
                    console.log(`Room started at: ${startedAt}. Delta from now: ${deltaMs}ms`);
                    document.getElementById('streamLabel').style.display = 'none';
                } else if (msg.sdp) {
                    await pc.setRemoteDescription(new RTCSessionDescription(msg.sdp));
                    if (msg.sdp.type === 'offer') {
                        const answer = await pc.createAnswer();
                        await pc.setLocalDescription(answer);
                        signalingWs.send(JSON.stringify({ sdp: pc.localDescription }));
                    }
                } else if (msg.candidate) {
                    try {
                        await pc.addIceCandidate(new RTCIceCandidate(msg.candidate));
                    } catch (err) {
                        console.error('Error adding ICE candidate:', err);
                    }
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
                    console.warn('Webcam acquisition failed, falling back to audio only:', e);
                    localStream = await navigator.mediaDevices.getUserMedia({ 
                        audio: true 
                    });
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

                pc = new RTCPeerConnection({
                   // iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] // Fallback STUN
                });

                pc.ontrack = (event) => {
                    console.log('Received remote track', event.track);
                    let stream = event.streams[0];
                    if (!stream) {
                        let currentStream = remoteVideo.srcObject || new MediaStream();
                        currentStream.addTrack(event.track);
                        remoteVideo.srcObject = null;
                        remoteVideo.srcObject = currentStream;
                    } else {
                        if (remoteVideo.srcObject !== stream) remoteVideo.srcObject = stream;
                    }

                    remoteVideo.style.display = 'block';
                    remoteVideo.play().catch(e => {
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

                pc.onicecandidate = (event) => {
                    if (event.candidate) signalingWs.send(JSON.stringify({ candidate: event.candidate }));
                };

                localStream.getTracks().forEach((track) => pc.addTrack(track, localStream));

                signalingWs.send(JSON.stringify({ type: 'ready' }));

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
