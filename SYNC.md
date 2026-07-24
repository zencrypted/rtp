# Smooth Streaming & Recording: Jitter, Latency, and Clock Sync

This document outlines the architectural patterns and nuances required to achieve real-time,
ultra-low latency WebRTC streaming mixed with stable disk recording on a centralized
MCU (Multipoint Control Unit). It pays special attention to resource-constrained
environments like Raspberry Pis or aging x86 hardware.

## The Core Challenge

When designing an MCU with GStreamer, you face conflicting goals:

1. **Live WebRTC Streaming** requires absolute real-time delivery. It cannot afford to block or wait. If a frame is late, it must be dropped.
2. **Disk Recording (MP4/HLS)** is inherently prone to unpredictable I/O blocking.
3. **Compositing** requires a constant, unyielding framerate (e.g., exactly 30 FPS) to mix multiple variable-framerate WebRTC clients into a single canvas.

If these subsystems are naively linked, a slow disk write will block the recording sink, which blocks the compositor, which blocks the master clock, ultimately freezing the live WebRTC stream for all participants and causing severe time dilation.

## What We Have Achieved (Current Architecture)

To solve the challenges above, we implemented the following robust architectural patterns:

### 1. Decoupling WebRTC Framerates (`videorate`)

Browsers dynamically adjust webcam framerates (e.g., 15–24 FPS) based on network and CPU load. The MCU `compositor`, however, is locked to `30/1` FPS. If a client sends 15 FPS, the compositor previously starved and blocked waiting for the missing frames, hitting latency timeouts and causing a 50% slowdown in real-world time passing.

* **The Fix:** We injected a `videorate` element and a strict `capsfilter` (`video/x-raw,framerate=30/1`) immediately after decoding incoming WebRTC streams. `videorate` duplicates missing frames instantly, ensuring the compositor is constantly fed at a perfect 30 FPS.

### 2. Overriding the Master Pipeline Clock

By default, GStreamer dynamically selects the clock of the most active receiver (in this case, `webrtcbin`). If the WebRTC client connection jittered, the entire pipeline clock slowed down, causing the `timeoverlay` and base generators to draw time slower than reality (Time Dilation).

* **The Fix:** We force the pipeline to use the **OS Monotonic System Clock** (`gst_system_clock_obtain()`). The MCU now ticks at exactly 1.0x real-time speed, regardless of what the network or WebRTC clients are doing.

### 3. Strict Base Generation Timestamps

`videotestsrc` and `audiotestsrc` provide the baseline black background and silent audio for the compositor.

* **The Fix:** We enabled `do-timestamp=true` on these generators. This forces their generated frames to bind directly to the OS System Clock rather than relying on sequential frame counts, ensuring absolute A/V sync.

### 4. Asynchronous Disk I/O & Thread Boundaries

Saving to MP4 or HLS involves heavy I/O that can deadlock GStreamer's main thread.

* **The Fix (Thread Isolation):** Every branch is isolated by `queue` elements (which spawn new OS threads).

* **The Fix (Async Sinks):** We disabled synchronous state-change blocking on the disk writers. `filesink` uses `sync=false async=false`, and `hlssink2` uses `async-handling=true`.

* **The Fix (Leaky Queues):** We deployed `leaky=downstream` queues. If the encoder or disk stalls, the queue fills up and silently deletes the oldest buffers. **This trades perfect recordings for a flawless live stream.** 

### 5. Nuanced Queue Sizing

We strategically tuned queue sizes:

* **Disk Queues:** `max-size-time=30000000000 max-size-buffers=0` (30 seconds). If disk I/O stalls, we can buffer a massive 30 seconds of video in RAM before we start losing recording frames.

* **Encoder Queues:** `max-size-time=1000000000 max-size-buffers=0` (1 second). This allows the CPU to absorb micro-stutters during heavy H.264/H.265 encoding without unnecessarily dropping recorded frames.

## Future Research & Optimizations (Raspberry Pi / Old Hardware)

To scale this system on older hardware (or SBCs like the Raspberry Pi), software encoding and 1080p compositing will quickly bottleneck. Here are areas for future research:

### 1. Hardware-Accelerated Encoding / Decoding

Software encoders (`x264enc`, `x265enc`) and decoders (`vp8dec`, `h264parse`) will melt older CPUs. 

* **Raspberry Pi:** Investigate migrating to `v4l2h264enc` (hardware H.264 encoder) or `omxh264enc`.

* **Intel Hardware:** Utilize QuickSync (`mmsvh264enc` or `vaapih264enc`).

* **Nvidia:** Utilize NVENC (`nvh264enc`).

### 2. Resolution Downscaling

Compositing 16 participants onto a `1920x1080` canvas is incredibly taxing. Processing 1080p requires dealing with ~2 million pixels per frame.

* **Research:** Change the MCU hardcoded resolution to `1280x720` (720p). This reduces pixel calculations by >50%. The CPU savings across `compositor`, `videoconvert`, and `x264enc` will be immense, drastically reducing jitter and latency.

### 3. CPU Affinity & Thread Pinning

On systems like the Raspberry Pi, OS context switching between threads can induce jitter.

* **Research:** Investigate pinning GStreamer threads to specific CPU cores. For instance, pinning `x264enc` to Core 3, and the `compositor` to Core 2. Also, `x264enc` allows explicit thread allocation (`threads=4`).

### 4. Tuning `webrtcbin` Latency and Jitterbuffers

Currently, `webrtcbin` is using a default `latency` (e.g., 200ms) on its internal RTP Jitterbuffer.

* **Research:** Expose the `latency` property dynamically based on connection quality. A LAN connection can run at `latency=20` (20ms) for ultra-real-time comms, while a poor 4G connection might need `latency=400` to prevent macro-blocking.

### 5. Multi-Bitrate (Simulcast) HLS

Currently, the MCU burns a single high-quality HLS stream.

* **Research:** If CPU overhead is reduced via hardware encoding, add a secondary `tee` branch that encodes a lower bitrate stream (e.g., 480p at 1000kbps). This allows `hlssink2` to generate a master playlist supporting adaptive bitrate streaming (ABR) for end-users on poor connections.
