# Implementation Plan: Scaling MCU to 32 Max Peers & Grid Rendering Strategies

This plan outlines the architecture and options for expanding the `gst.c` MCU
compositor from 16 to 32 maximum participants while maintaining real-time performance and memory efficiency.

## Technical Challenges at 32 Participants

1. **Decoding & Compositing Overhead**: Concurrent software decoding of 32 incoming video streams at 1080p/720p requires significant CPU resources.
2. **Spatial Geometry Math**: The current index placement in `gst.c` hardcodes a 2x2 quadrant (`idx % 2`, `idx / 2` at 960x540), causing indices 4–15 to render off-screen.
3. **Data Structure Limits**: `grid_slots[16]` must be scaled to `grid_slots[32]`.

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

**Pros**: Every participant receives equal visual prominence.
**Cons**: High CPU decode load when 32 video streams are active simultaneously.

### Option B: Active Speaker / Stage Layout (Hero + Filmstrip) — *Recommended*

Industry-standard layout used by Google Meet and Zoom:

* **Hero Stage**: 1 prominent active speaker slot (e.g., 1440x810 or 1280x720, top-left or centered).
* **Filmstrip**: Up to 7 or 15 secondary speaker thumbnails arranged along the right column or bottom row (e.g., 240x135).
* **Overflow**: Non-speaking peers beyond slot 8/16 have their video pads unlinked from `compositor` (or set `alpha=0.0`) while their audio remains active in `audiomixer`.
* **Pros**: Drastically reduces CPU decode overhead; maintains high video quality for the active speaker.
* **Cons**: Requires volume/VAD signals from Erlang to trigger active speaker layout swaps.

### Option C: Paginated 4x4 Grid (Max 16 Visible Video Streams)

Caps the composited canvas to a 4x4 grid (16 visible video tiles at 480x270), supporting up to 32 peers in audio mixing.

* Pages can be switched via a JSON signaling message (`{"type": "set_page", "page": 0|1}`).
* Page 0 displays peers 1–16; Page 1 displays peers 17–32.
* **Pros**: Predictable, capped CPU performance (never exceeds 16 video decoders). Full 32-peer audio mix is preserved.
* **Cons**: Participants must page through to see everyone.

## Proposed Changes in `c_src/gst.c`

### 1. Expand `RecorderState` Grid Allocator

* Expand bitmap array: `gboolean grid_slots[32];`
* Update search loops in `setup_peer` and cleanup logic in `cleanup_peer` to iterate up to 32 slots.

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

* Iterate through all active `PeerInfo` structs in `state.webrtcbins`.
* Re-calculate and update `xpos`, `ypos`, `width`, and `height` properties on their `comp_pad`s to reflow the grid seamlessly without breaking live video streams.

