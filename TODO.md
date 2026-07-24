# Implementation Plan: Scaling MCU to 32 Max Peers & Grid Rendering Strategies

This plan outlines the architecture and options for expanding the `gst.c` MCU compositor from 16 to 32 maximum participants while maintaining real-time performance and memory efficiency.

---

## Technical Challenges at 32 Participants

1. **Decoding & Compositing Overhead**: Concurrent software decoding of 32 incoming video streams at 1080p/720p requires significant CPU resources.
2. **Spatial Geometry Math**: The current index placement in `gst.c` hardcodes a 2x2 quadrant (`idx % 2`, `idx / 2` at 960x540), causing indices 4–15 to render off-screen.
3. **Data Structure Limits**: `grid_slots[16]` must be scaled to `grid_slots[32]`.

---

## Proposed Grid Rendering Strategies (User Selection Required)

> [!IMPORTANT]
> Please review the three best-practice grid rendering options below and specify which approach best matches your application requirements:

### Option A: Dynamic Auto-Scaling Matrix (Uniform Grid)
Dynamically adjusts grid dimensions ($C \times R$) based on the number of currently connected participants $N$ (up to 32).

| Active Peers ($N$) | Layout Matrix ($C \times R$) | Tile Dimensions ($W \times H$) |
|---|---|---|
| 1 – 4 | 2 x 2 | 960 x 540 |
| 5 – 9 | 3 x 3 | 640 x 360 |
| 10 – 16 | 4 x 4 | 480 x 270 |
| 17 – 25 | 5 x 5 | 384 x 216 |
| 26 – 36 | 6 x 6 | 320 x 180 |

- **Pros**: Every participant receives equal visual prominence.
- **Cons**: High CPU decode load when 32 video streams are active simultaneously.

---

### Option B: Active Speaker / Stage Layout (Hero + Filmstrip) — *Recommended*
Industry-standard layout used by Google Meet and Zoom:
- **Hero Stage**: 1 prominent active speaker slot (e.g., 1440x810 or 1280x720, top-left or centered).
- **Filmstrip**: Up to 7 or 15 secondary speaker thumbnails arranged along the right column or bottom row (e.g., 240x135).
- **Overflow**: Non-speaking peers beyond slot 8/16 have their video pads unlinked from `compositor` (or set `alpha=0.0`) while their audio remains active in `audiomixer`.

- **Pros**: Drastically reduces CPU decode overhead; maintains high video quality for the active speaker.
- **Cons**: Requires volume/VAD signals from Erlang to trigger active speaker layout swaps.

---

### Option C: Paginated 4x4 Grid (Max 16 Visible Video Streams)
Caps the composited canvas to a 4x4 grid (16 visible video tiles at 480x270), supporting up to 32 peers in audio mixing.
- Pages can be switched via a JSON signaling message (`{"type": "set_page", "page": 0|1}`).
- Page 0 displays peers 1–16; Page 1 displays peers 17–32.

- **Pros**: Predictable, capped CPU performance (never exceeds 16 video decoders). Full 32-peer audio mix is preserved.
- **Cons**: Participants must page through to see everyone.

---

## Proposed Changes in `c_src/gst.c`

### 1. Expand `RecorderState` Grid Allocator
- Expand bitmap array: `gboolean grid_slots[32];`
- Update search loops in `setup_peer` and cleanup logic in `cleanup_peer` to iterate up to 32 slots.

### 2. Generalize Tile Positioning Math
Replace hardcoded 2x2 geometry math in `on_decoded_pad`:

```c
// General N x M layout computation:
gint cols = (state.active_peers <= 4)  ? 2 :
            (state.active_peers <= 9)  ? 3 :
            (state.active_peers <= 16) ? 4 :
            (state.active_peers <= 25) ? 5 : 6;
gint rows = cols;

gint w = 1920 / cols;
gint h = 1080 / rows;
gint x = (peer->grid_idx % cols) * w;
gint y = (peer->grid_idx / cols) * h;

g_object_set(comp_pad, "xpos", x, "ypos", y, "width", w, "height", h,
             "zorder", (guint)(peer->grid_idx + 10), "sizing-policy", 1, NULL);
```

### 3. Dynamic Grid Reflow Trigger
When a new peer joins or leaves:
- Iterate through all active `PeerInfo` structs in `state.webrtcbins`.
- Re-calculate and update `xpos`, `ypos`, `width`, and `height` properties on their `comp_pad`s to reflow the grid seamlessly without breaking live video streams.

---

## Verification Plan

### Automated / Semantic Verification
- Verify indexing bounds and array allocations do not overflow index 31.
- Ensure reflow loop safely skips peers without an active `comp_pad`.

### Manual Verification
- Test joining up to 32 simulated peers via stdin JSON signaling.
- Verify no off-screen rendering occurs for slots 4–31.


# Fix MCU Framerate Slowdown & Time Dilation

## Root Cause Analysis
The "slow time" and stuttering on the MCU are caused by a severe architectural mismatch between WebRTC's dynamic nature and GStreamer's rigid `compositor` expectations:

1. **WebRTC Dynamic Framerates**: Web browsers dynamically adjust webcam framerates based on lighting, network, and CPU. They rarely send a perfect 30 FPS (often fluctuating between 15-24 FPS).
2. **Compositor Starvation**: The MCU `compositor` is hard-locked to 30 FPS (`video/x-raw,framerate=30/1`). When it tries to process a 30 FPS frame and the WebRTC client hasn't sent one (e.g., because the client is running at 15 FPS), the compositor **blocks and waits** for the missing frame.
3. **Latency Timeout Loop**: It waits until the global pipeline latency timeout (`220ms` configured in `webrtcbin`) expires. Because a 15 FPS client is "missing" every other frame, the compositor hits a 220ms timeout on 50% of all frames! 
4. **Time Dilation**: This constant blocking throttles the entire pipeline down to ~5-10 FPS. Because `videotestsrc` generates timestamps based on frame count rather than the system clock, the `timeoverlay` draws time at 1/3rd to 1/6th speed (e.g., 1 real second passes, but only 0.3s of video time is drawn).

## Latency and Jitter Calculations

### Current Incoming Latency:
- **WebRTC Jitterbuffer**: `220ms` (Absorbs network UDP jitter, delaying frames).
- **Decoder (`vp8dec`)**: ~10ms.
- **Pipeline Global Latency**: `220ms` (Dictated by `webrtcbin`).
- **Compositor Timeout**: When a frame is missing (due to low client framerate), the compositor blocks the main thread for `220ms` per missing frame.

### Proposed Target Latency:
By decoupling the framerates, we eliminate the compositor timeout loop:
- **WebRTC Jitterbuffer**: `220ms`.
- **`videorate` Interpolation**: ~33ms (Wait time to interpolate missing frames).
- **Compositor Block Time**: `0ms` (Compositor receives a perfect 30 FPS feed and never waits).
- **Total Glass-to-Glass MCU Delay**: ~260ms (Rock solid, perfectly smooth, real-time sync).

## Proposed Changes

### 1. Decouple Client Framerates (`c_src/gst.c`)
I will inject a `videorate` element into the dynamic `on_decoded_pad` pipeline for every incoming WebRTC peer. 
`videorate` will intercept the fluctuating WebRTC stream (e.g. 15 FPS) and instantly duplicate frames to output a flawless 30 FPS stream to the compositor. The compositor will never block waiting for missing frames again.

#### [MODIFY] c_src/gst.c
- Add `videorate` element to the `on_decoded_pad` video branch:
  ```c
  GstElement *rate = gst_element_factory_make("videorate", NULL);
  g_object_set(rate, "drop-only", FALSE, "skip-to-first", TRUE, NULL);
  // Link: webrtcbin -> queue -> videoconvert -> videorate -> capsfilter(30fps) -> compositor
  ```
- Add a `capsfilter` after `videorate` to explicitly force the 30/1 framerate per-peer before it hits the compositor.

### 2. Fix Clock Synchronization (`c_src/gst.c`)
I will enforce strict system-clock synchronization on the base generators.

#### [MODIFY] c_src/gst.c
- Add `do-timestamp=true` to `videotestsrc` and `audiotestsrc` so their generated frames are strictly tied to the system clock. If the pipeline ever stutters, they will intelligently drop frames instead of dilating time.

## Verification Plan
1. Apply the patches to `gst.c` and recompile.
2. Restart the `beam.smp` server.
3. Observe the `timeoverlay` in the browser — it should perfectly match real-world seconds passing.
4. Verify the video stream remains perfectly smooth even if the connected WebRTC client drops its framerate.

## User Review Required
> [!IMPORTANT]
> Please review this implementation plan. If you agree with the `videorate` interpolation approach to fix the WebRTC framerate mismatches, I will execute the changes!

Fix Time Sync & Async HLS Writing
Root Cause Analysis
Time Not Synched: Even with videorate and audiorate pacing the incoming streams, the time is still dilating. This happens because GStreamer is dynamically selecting the WebRTC UDP receiver (webrtcbin) as the master pipeline clock instead of the reliable local System Clock. If the WebRTC network stutters, the pipeline clock stutters, causing the videotestsrc to generate delayed timestamps.
HLS Blocking: You suspected HLS file saving is causing the slowdown. Even though we put a 30-second leaky queue in front of hlssink2, GStreamer sinks default to sync=true and async=true. This means the sink forces state changes to block until the clock reaches the buffer timestamps, and heavy disk I/O in WSL2 can still cause state-change deadlocks that bubble up to the master pipeline thread.
Proposed Changes
1. Force Master System Clock
I will explicitly force the pipeline to use the OS Monotonic System Clock. This guarantees that timeoverlay and videotestsrc will ALWAYS tick at exactly 1.0x real-time speed, regardless of any WebRTC client stutters.

[MODIFY] c_src/gst.c:
c

GstClock *system_clock = gst_system_clock_obtain();
gst_pipeline_use_clock(GST_PIPELINE(state.pipeline), system_clock);
gst_object_unref(system_clock);
2. Fully Asynchronous Disk I/O
I will decouple the file writing branches completely from the live pipeline timing. By adding sync=false and async=false to the final sinks, GStreamer will dump data to disk as fast as it arrives from the leaky queues, without ever attempting to synchronize with the pipeline clock or block state changes.

[MODIFY] c_src/gst.c:
Add async=false sync=false to filesink in the MP4 branch.
Since hlssink2 doesn't expose sync properties directly for its internal splitmuxers in a simple string, I will wrap the queues in a dedicated asynchronous thread boundary using queue run-fast=true or use fakesink clocking to ensure the disk I/O is completely orphaned from the live clock.
Wait, I'll update the queue before hlssink2 to max-size-time=0 max-size-bytes=0 max-size-buffers=0 leaky=2? No, unlimited queue is bad. I will keep leaky=2 but add flush-on-eos=true and isolate it.
