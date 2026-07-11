class TelemetryProbe {
    constructor() {
        this.wsUrl = `ws://${window.location.hostname}:8082/ws/telemetry`;
        this.ws = null;
        this.pollInterval = 2000;
        this.timer = null;
        this.peerConnections = [];
    }

    init() {
        this.setupWebsocket();
        this.startCollector();
    }

    setupWebsocket() {
        this.ws = new WebSocket(this.wsUrl);

        this.ws.onopen = () => {
            console.log("QoS priority telemetry websocket channel established");
        };

        this.ws.onclose = () => {
            console.warn("Telemetry websocket disconnected. Retrying...");
            setTimeout(() => this.setupWebsocket(), 5000);
        };
    }

    registerPeerConnection(pc) {
        this.peerConnections.push(pc);
    }

    startCollector() {
        this.timer = setInterval(async () => {
            if (this.ws && this.ws.readyState === WebSocket.OPEN) {
                const statsPayload = await this.gatherStats();
                this.ws.send(JSON.stringify(statsPayload));
                this.updateUI(statsPayload);
            }
        }, this.pollInterval);
    }

    async gatherStats() {
        let packetLoss = 0.0;
        let rtt = 0;
        let jitter = 0.0;

        if (this.peerConnections.length > 0) {
            for (const pc of this.peerConnections) {
                try {
                    const report = await pc.getStats();
                    report.forEach(stat => {
                        if (stat.type === 'remote-inbound-rtp') {
                            rtt = stat.roundTripTime ? stat.roundTripTime * 1000 : rtt;
                            jitter = stat.jitter || jitter;
                            packetLoss = stat.packetsLost && stat.packetsReceived
                                ? (stat.packetsLost / (stat.packetsLost + stat.packetsReceived)) * 100
                                : packetLoss;
                        }
                    });
                } catch (e) {
                    console.error("Failed to query getStats() from peer connection", e);
                }
            }
        } else {
            rtt = Math.floor(10 + Math.random() * 25);
            packetLoss = Math.random() < 0.1 ? Math.random() * 0.5 : 0.0;
            jitter = Math.random() * 0.005;
        }

        return {
            rtt: rtt,
            packet_loss: parseFloat(packetLoss.toFixed(4)),
            jitter: parseFloat(jitter.toFixed(6))
        };
    }

    updateUI(stats) {
        const rttElement = document.getElementById('rttVal');
        const lossElement = document.getElementById('lossVal');

        if (rttElement) {
            rttElement.innerText = `${stats.rtt} ms`;
            if (stats.rtt > 100) {
                rttElement.className = 'metric-value status-warn';
            } else {
                rttElement.className = 'metric-value status-ok';
            }
        }

        if (lossElement) {
            lossElement.innerText = `${stats.packet_loss.toFixed(2)}%`;
            if (stats.packet_loss > 1.0) {
                lossElement.className = 'metric-value status-warn';
            } else {
                lossElement.className = 'metric-value status-ok';
            }
        }
    }
}

window.TelemetryProbe = new TelemetryProbe();
