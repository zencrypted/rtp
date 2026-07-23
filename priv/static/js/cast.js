
        const urlParams = new URLSearchParams(window.location.search);
        const roomName = urlParams.get('room') || 'lobby';
        document.getElementById('roomDisplay').textContent = 'Кімната: ' + roomName;

        const hlsVideo = document.getElementById('hlsVideo');
        const container = document.getElementById('container');
        const unmuteOverlay = document.getElementById('unmuteOverlay');
        const statusSlate = document.getElementById('statusSlate');
        const statusText = document.getElementById('statusText');
        const liveBadge = document.getElementById('liveBadge');
        const liveDot = document.getElementById('liveDot');
        const retroSlider = document.getElementById('retroSlider');

        // Control Buttons
        const playPauseBtn = document.getElementById('playPauseBtn');
        const iconPlay = document.getElementById('iconPlay');
        const iconPause = document.getElementById('iconPause');
        const muteBtn = document.getElementById('muteBtn');
        const iconVol = document.getElementById('iconVol');
        const iconMuted = document.getElementById('iconMuted');
        const volumeSlider = document.getElementById('volumeSlider');
        const fullscreenBtn = document.getElementById('fullscreenBtn');

        const infoToggleBtn = document.getElementById('infoToggleBtn');
        const sidebar = document.getElementById('sidebar');
        const sidebarClose = document.getElementById('sidebarClose');

        if (infoToggleBtn && sidebar) {
            infoToggleBtn.addEventListener('click', () => {
                sidebar.classList.add('open');
            });
        }
        if (sidebarClose && sidebar) {
            sidebarClose.addEventListener('click', () => {
                sidebar.classList.remove('open');
            });
        }

        let isLiveMode = true;
        let isUserSeeking = false;
        let isStreamEnded = false;

        let roomStartedAt = null;
        let roomEndedAt = null;
        let peerSet = new Set();
        let telemetryInterval = null;

        function updateTelemetry() {
            if (!roomStartedAt) return;
            const now = Date.now();

            if (isStreamEnded) {
                if (!roomEndedAt) roomEndedAt = now;
                document.getElementById('telemetryEndedStat').style.display = 'block';
                const endedDiff = now - roomEndedAt;
                document.getElementById('telemetryEndedTime').textContent = formatTime(endedDiff);
            } else {
                const liveDiff = now - roomStartedAt;
                document.getElementById('telemetryDuration').textContent = formatTime(liveDiff);
            }
        }

        function formatTime(ms) {
            const totalSec = Math.floor(ms / 1000);
            const h = Math.floor(totalSec / 3600).toString().padStart(2, '0');
            const m = Math.floor((totalSec % 3600) / 60).toString().padStart(2, '0');
            const s = (totalSec % 60).toString().padStart(2, '0');
            return `${h}:${m}:${s}`;
        }

        function renderPeers() {
            document.getElementById('peerCount').textContent = peerSet.size;
            const list = document.getElementById('peerList');
            list.innerHTML = '';
            peerSet.forEach(peer => {
                const li = document.createElement('li');
                // Remove the generated ID part just to show name if available, else show full ID
                const nameMatch = peer.match(/^peer_(\d+)/) ? "Глядач " + peer.split('_')[1] : peer;
                li.textContent = nameMatch;
                list.appendChild(li);
            });
        }

        // Connect Telemetry WebSocket (role=broadcast — not a WebRTC peer, no MCU registration)
        const signalingWs = new WebSocket('ws://' + window.location.hostname + ':8001/ws/signaling?room=' + encodeURIComponent(roomName) + '&user=broadcast&role=broadcast');
        let telemetryPingInterval = null;

        signalingWs.onopen = () => {
            console.log('Telemetry connected.');
            telemetryPingInterval = setInterval(() => {
                if (signalingWs && signalingWs.readyState === WebSocket.OPEN) {
                    signalingWs.send(JSON.stringify({ type: 'ping' }));
                }
            }, 5000);
        };

        signalingWs.onclose = () => {
            if (telemetryPingInterval) clearInterval(telemetryPingInterval);
        };

        signalingWs.onmessage = (e) => {
            try {
                const data = JSON.parse(e.data);
                if (data.type === 'init') {
                    // connected, fetch room info and peers
                    signalingWs.send(JSON.stringify({ type: 'get_room_info' }));
                    signalingWs.send(JSON.stringify({ type: 'get_peers' }));
                } else if (data.type === 'room_info') {
                    roomStartedAt = data.started_at;
                    if (telemetryInterval) clearInterval(telemetryInterval);
                    telemetryInterval = setInterval(updateTelemetry, 1000);
                } else if (data.type === 'peer_list') {
                    data.peers.forEach(p => peerSet.add(p));
                    renderPeers();
                } else if (data.type === 'peer_joined') {
                    peerSet.add(data.peer_id);
                    renderPeers();
                } else if (data.type === 'peer_left') {
                    peerSet.delete(data.peer_id);
                    renderPeers();
                }
            } catch(e) {}
        };

        // Chrome Auto-hide logic
        let idleTimeout;
        function resetIdle() {
            container.classList.remove('idle');
            clearTimeout(idleTimeout);
            idleTimeout = setTimeout(() => {
                container.classList.add('idle');
            }, 3000);
        }
        window.addEventListener('mousemove', resetIdle);
        window.addEventListener('click', resetIdle);
        window.addEventListener('touchstart', resetIdle);
        resetIdle();

        // Unmute logic (Overlay)
        unmuteOverlay.addEventListener('click', () => {
            hlsVideo.muted = false;
            unmuteOverlay.classList.add('hidden');
            iconMuted.style.display = 'none';
            iconVol.style.display = 'block';
            volumeSlider.value = hlsVideo.volume;
        });

        // Player Controls Logic
        playPauseBtn.addEventListener('click', () => {
            if (hlsVideo.paused) {
                hlsVideo.play();
            } else {
                hlsVideo.pause();
            }
        });

        hlsVideo.addEventListener('play', () => {
            iconPlay.style.display = 'none';
            iconPause.style.display = 'block';
        });

        hlsVideo.addEventListener('pause', () => {
            iconPause.style.display = 'none';
            iconPlay.style.display = 'block';
        });

        muteBtn.addEventListener('click', () => {
            hlsVideo.muted = !hlsVideo.muted;
            if (hlsVideo.muted) {
                iconMuted.style.display = 'block';
                iconVol.style.display = 'none';
                volumeSlider.value = 0;
            } else {
                iconMuted.style.display = 'none';
                iconVol.style.display = 'block';
                volumeSlider.value = hlsVideo.volume || 1;
            }
            unmuteOverlay.classList.add('hidden');
        });

        volumeSlider.addEventListener('input', (e) => {
            hlsVideo.volume = e.target.value;
            if (e.target.value > 0) {
                hlsVideo.muted = false;
                iconMuted.style.display = 'none';
                iconVol.style.display = 'block';
                unmuteOverlay.classList.add('hidden');
            } else {
                hlsVideo.muted = true;
                iconMuted.style.display = 'block';
                iconVol.style.display = 'none';
            }
        });

        fullscreenBtn.addEventListener('click', () => {
            if (!document.fullscreenElement) {
                container.requestFullscreen().catch(err => {
                    console.error(`Error attempting to enable full-screen mode: ${err.message}`);
                });
            } else {
                document.exitFullscreen();
            }
        });

        // Catch up logic
        function catchUpToLive(e) {
            console.log('Catchup clicked!', e.target);
            if (isStreamEnded) {
                console.log('Stream ended, jumping to end of buffer');
                if (hlsVideo.seekable && hlsVideo.seekable.length > 0) {
                    hlsVideo.currentTime = hlsVideo.seekable.end(0) - 1;
                }
                return;
            }
            if (!isLiveMode) {
                console.log('Catching up to live edge');
                if (window.hlsPlayer && window.hlsPlayer.liveSyncPosition) {
                    console.log('Using liveSyncPosition:', window.hlsPlayer.liveSyncPosition);
                    hlsVideo.currentTime = window.hlsPlayer.liveSyncPosition;
                } else if (hlsVideo.seekable && hlsVideo.seekable.length > 0) {
                    console.log('Using seekable.end:', hlsVideo.seekable.end(0));
                    hlsVideo.currentTime = hlsVideo.seekable.end(0) - 1;
                }
                setLiveMode(true);
            } else {
                console.log('Already in live mode, ignoring click');
            }
        }

        liveBadge.addEventListener('click', catchUpToLive);
        document.getElementById('catchUpBtn').addEventListener('click', catchUpToLive);

        retroSlider.addEventListener('input', () => {
            isUserSeeking = true;
            resetIdle();
        });

        retroSlider.addEventListener('change', () => {
            isUserSeeking = false;
            if (hlsVideo.seekable.length > 0) {
                const start = hlsVideo.seekable.start(0);
                const end = hlsVideo.seekable.end(0);
                const targetTime = start + (retroSlider.value / 100) * (end - start);
                hlsVideo.currentTime = targetTime;

                // If they scrubbed away from the edge, disable live mode
                if (end - targetTime > 3) {
                    setLiveMode(false);
                } else {
                    setLiveMode(true);
                }
            }
        });

        hlsVideo.addEventListener('timeupdate', () => {
            if (!isUserSeeking && hlsVideo.seekable.length > 0) {
                const start = hlsVideo.seekable.start(0);
                const end = hlsVideo.seekable.end(0);
                const current = hlsVideo.currentTime;

                if (end > start) {
                    const percent = ((current - start) / (end - start)) * 100;
                    retroSlider.value = Math.max(0, Math.min(100, percent));
                }
            }
        });

        function setLiveMode(isLive) {
            if (isStreamEnded) return;
            isLiveMode = isLive;
            const catchUpBtn = document.getElementById('catchUpBtn');
            if (isLive) {
                liveDot.style.background = '#ef4444';
                liveDot.style.animation = 'pulse-red 2s infinite';
                liveBadge.style.opacity = '1';
                liveBadge.style.background = 'rgba(0, 0, 0, 0.5)';
                document.getElementById('liveText').textContent = 'LIVE';
                if (catchUpBtn) {
                    catchUpBtn.style.opacity = '0.4';
                    catchUpBtn.style.pointerEvents = 'none';
                }
            } else {
                liveDot.style.background = '#888';
                liveDot.style.animation = 'none';
                liveBadge.style.opacity = '0.7';
                liveBadge.style.background = 'rgba(0, 0, 0, 0.8)';
                document.getElementById('liveText').textContent = 'РЕТРО';
                if (catchUpBtn) {
                    catchUpBtn.style.opacity = '1';
                    catchUpBtn.style.pointerEvents = 'auto';
                }
            }
        }

        // (Old unmute logic removed)

        function setStatus(text, showSpinner = true) {
            if (text) {
                statusText.textContent = text;
                statusSlate.classList.add('active');
                if (!showSpinner) statusSlate.querySelector('.spinner').style.display = 'none';
                else statusSlate.querySelector('.spinner').style.display = 'block';
                liveBadge.classList.add('offline');
            } else {
                statusSlate.classList.remove('active');
                liveBadge.classList.remove('offline');
            }
        }

        let catchUpInterval = null;

        function initHlsPlayer() {
            console.log(`Initializing HLS player for room: ${roomName}`);
            const playlistUrl = `/rooms/${encodeURIComponent(roomName)}/index.m3u8`;
            setStatus('Підключення до ефіру...');

            if (Hls.isSupported()) {
                if (window.hlsPlayer) {
                    window.hlsPlayer.destroy();
                }

                // Aggressive live settings
                // Aggressive live settings (removed maxLatency to fix jumping in retro)
                window.hlsPlayer = new Hls({
                    liveSyncDurationCount: 2,
                    backBufferLength: 30
                });

                // Bust cache on initial load
                window.hlsPlayer.loadSource(playlistUrl + '?t=' + Date.now());
                window.hlsPlayer.attachMedia(hlsVideo);

                window.hlsPlayer.on(Hls.Events.MANIFEST_PARSED, function() {
                    setStatus(null); // Clear loading
                    hlsVideo.play().catch(e => {
                        console.warn('HLS Autoplay prevented:', e);
                        unmuteOverlay.classList.remove('hidden');
                    });
                });

                window.hlsPlayer.on(Hls.Events.ERROR, function (event, data) {
                    if (data.fatal) {
                        switch (data.type) {
                            case Hls.ErrorTypes.NETWORK_ERROR:
                                setStatus('Втрачено з\'єднання. Відновлення...');
                                setTimeout(() => {
                                    if (window.hlsPlayer) {
                                        window.hlsPlayer.loadSource(playlistUrl + '?t=' + Date.now());
                                    }
                                }, 1000);
                                break;
                            case Hls.ErrorTypes.MEDIA_ERROR:
                                console.warn('HLS Media error, recovering...', data);
                                window.hlsPlayer.recoverMediaError();
                                break;
                            default:
                                console.error('Fatal HLS error, destroying and restarting...', data);
                                setStatus('Критична помилка. Перезапуск...');
                                window.hlsPlayer.destroy();
                                setTimeout(() => initHlsPlayer(), 2000);
                                break;
                        }
                    }
                });

                // Robust Manual Catch-Up Logic
                if (catchUpInterval) clearInterval(catchUpInterval);
                catchUpInterval = setInterval(() => {
                    if (!window.hlsPlayer || hlsVideo.paused) return;

                    const liveEdge = window.hlsPlayer.liveSyncPosition;
                    const currentPos = hlsVideo.currentTime;

                    if (isLiveMode && liveEdge && currentPos > 0) {
                        const drift = liveEdge - currentPos;

                        // If we are more than 10 seconds behind the live edge and user is not seeking
                        if (drift > 10 && !isUserSeeking) {
                            console.warn(`[Catch-up] Video is lagging by ${drift.toFixed(2)}s. Forcing jump to live edge.`);
                            hlsVideo.currentTime = liveEdge;
                        }
                    }
                }, 5000); // Check every 5 seconds

            } else if (hlsVideo.canPlayType('application/vnd.apple.mpegurl')) {
                hlsVideo.src = playlistUrl;
                hlsVideo.addEventListener('loadedmetadata', function() {
                    setStatus(null);
                    hlsVideo.play().catch(e => {
                        unmuteOverlay.classList.remove('hidden');
                    });
                });
            }
        }

        // Handle Stream End (turns into Archive/VOD mode)
        hlsVideo.addEventListener('ended', () => {
            console.log('Stream has reached the end of the recording.');
            isStreamEnded = true;
            isLiveMode = false;

            if (catchUpInterval) clearInterval(catchUpInterval);
            if (stalledTimeout) clearTimeout(stalledTimeout);

            liveDot.style.background = '#888';
            liveDot.style.animation = 'none';
            liveBadge.style.opacity = '0.9';
            liveBadge.style.background = 'rgba(0, 0, 0, 0.8)';
            liveBadge.style.cursor = 'default';
            document.getElementById('liveText').textContent = 'ЗАВЕРШЕНО';

            setStatus(null); // Clear loading slate
        });

        let stalledTimeout = null;
        hlsVideo.addEventListener('waiting', () => {
            if (isStreamEnded) return;
            setStatus('Буферизація...');
            stalledTimeout = setTimeout(() => {
                console.warn('Video stuck buffering for 5s. Re-initializing...');
                initHlsPlayer();
            }, 5000);
        });
        hlsVideo.addEventListener('playing', () => {
            setStatus(null);
            if (stalledTimeout) clearTimeout(stalledTimeout);
        });

        // Start playback attempt immediately
        initHlsPlayer();
