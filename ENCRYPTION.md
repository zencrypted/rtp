Encryption Policy
=================

Here are the 4 best ways to verify that your WebRTC media traffic (SRTP) and TURN traffic are fully encrypted:

### 1. Browser Diagnostics (`chrome://webrtc-internals` or `about:webrtc`)

This is the easiest and most authoritative way to inspect the live connection stats:

1. Open Chrome and navigate to `chrome://webrtc-internals` (or `about:webrtc` in Firefox).
2. Expand your active `RTCPeerConnection`.
3. Look for the `transport` section and verify:
   - **`dtlsState`**: `connected`
   - **`srtpCipher`**: `AEAD_AES_128_GCM` or `SRTP_AES128_CM_HMAC_SHA1_80`
   - **`dtlsCipher`**: `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256`

If the DTLS state is `connected` and an SRTP cipher is selected, the browser guarantees that
all video and audio frames leaving the browser are encrypted before hitting the wire.

### 2. Network Packet Capture (`tcpdump` or Wireshark)

You can directly capture raw packets flowing between your browser and the MCU/TURN server:

Using `tcpdump` in your terminal:

```bash
sudo tcpdump -i any port 3478 or portrange 49152-65535 -X -c 20
```

- Look at the ASCII payload on the right side of the packet output.
- **Result:** You will see randomized garbage data (ciphertext).
  Standard unencrypted video/audio codecs (like VP8/H.264 NAL headers or raw audio) will not be visible.

Using Wireshark:

1. Start capturing on your network interface.
2. Filter by `dtls || srtp || turnchannel`.
3. You will see:
   - Initial **DTLS Handshake** packets (`Client Hello`, `Server Hello`, `Change Cipher Spec`).
   - Subsequent media packets categorized as **SRTP** (Secure Real-Time Transport Protocol).
   - If you try to analyze the audio/video payload in Wireshark, it will state
     that the payload is encrypted and cannot be decoded without secret keys.

### 3. GStreamer Debug Logs (`GST_DEBUG`)

You can observe `webrtcbin`'s internal DTLS state machine in your C binary logs:

Run your Erlang/MCU node with the GStreamer debug environment variable set:

```bash
GST_DEBUG=webrtcbin:4,dtlstransport:4 ./priv/gst /tmp/test ts
```

When a peer connects, you will see explicit log outputs showing the DTLS handshake completing:

```text
webrtcdtlstransport gstwebrtcdtlstransport.c:...:gst_webrtc_dtls_transport_change_state:<dtlstransport0> state changed to connected
webrtcbin gstwebrtcbin.c:...: _dtls_transport_connected:<webrtc_peer1> DTLS transport connected, negotiated SRTP cipher SRTP_AES128_CM_HMAC_SHA1_80
```

### 4. Inspect SDP Fingerprints (`a=fingerprint:`)

WebRTC browsers enforce encryption by default—they will immediately abort
the call if DTLS/SRTP is missing. You can verify this in the SDP offer/answer:

1. Check the JSON `sdp_offer` output by `gst.c`.

2. Ensure lines like the following are present:

   ```text
   a=fingerprint:sha-256 4A:AD:B9:8A:...
   a=setup:actpass
   ```

   The `a=fingerprint` attribute proves that DTLS key exchange is requested for SRTP media transport.

