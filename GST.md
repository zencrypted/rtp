# GST.md

## Overview

The GStreamer MCU implementation lives in **`c_src/gst.c`**. Its purpose is to receive WebRTC streams from multiple peers, decode them, and compose them into a single video recording (MP4). The code arranges the video streams in a **2 × 2 grid** (four quadrants) and mixes all audio into a single track.

---

## Where the list of streams is stored

### 1. Peer‑to‑WebRTC element map (`state.webrtcbins`)

```c
static RecorderState state;
...
state.webrtcbins = g_hash_table_new_full(g_str_hash,
                                          g_str_equal,
                                          g_free,
                                          g_object_unref);
```

- **Key** – `peer_id` (a `gchar*` supplied by the Erlang side).
- **Value** – the `GstElement*` created for that peer (`webrtcbin`).
- This hash table lives in the global `RecorderState` struct and is populated in **`setup_peer()`**:
  ```c
  g_hash_table_insert(state.webrtcbins, g_strdup(peer_id), webrtc);
  ```
- It is the authoritative list of *active* peers. When a peer leaves you would remove the entry (the current file does not contain explicit removal code).

### 2. Pad index counter (`state.pad_index`)

```c
state.pad_index = 0;   // initialised in main()
```

Every time a **video pad** is decoded (`on_decoded_pad`), the function increments `state.pad_index` and uses the value to calculate the grid cell:

```c
gint idx = state.pad_index++;   // 0‑based index for the incoming video stream
```

- The counter provides a **stable ordering** of the streams as they appear on the compositor.
- It is not a container of the streams themselves; it merely supplies a sequential number used for positioning.

### 3. Grid placement logic (inside `on_decoded_pad`)

```c
gint w = WIDTH  / 2;          // cell width  – half of full width
gint h = HEIGHT / 2;          // cell height – half of full height
gint x = (idx % 2) * w;       // column → X offset
gint y = (idx / 2) * h;       // row    → Y offset

g_object_set(comp_pad,
             "xpos",   x,
             "ypos",   y,
             "width",  w,
             "height", h,
             NULL);
```

- `comp_pad` is a sink pad on the **`compositor`** element (`state.compositor`).
- The geometry values tell the compositor where to draw the incoming video frame.
- Because `idx` comes from `state.pad_index`, the placement order directly reflects the order in which streams were first seen.

---

## Summary of data structures

| Structure | Purpose | Key fields used for stream handling |
|-----------|---------|-------------------------------------|
| `RecorderState` (global) | Holds the entire MCU state. | `webrtcbins` (hash table), `pad_index` (counter), `pipeline`, `compositor`, `audiomixer`, `video_tee`, `audio_tee`, `loop` |
| `state.webrtcbins` | Maps *peer id* → *webrtcbin element*. | `peer_id` strings are the unique identifiers provided by Erlang. |
| `state.pad_index` | Simple integer counter used to assign grid cells. | Incremented for each decoded **video** pad. |
| `state.compositor` | GStreamer compositor element (`compositor name=mix`). | Receives sink pads (`sink_%u`) whose geometry is set per stream. |

---

## How the flow works

1. **Signalling** – Erlang sends a JSON message (`peer_joined`) → `handle_signaling_message` → `setup_peer(peer_id)`.
2. `setup_peer` creates a `webrtcbin` for the peer, stores it in `state.webrtcbins`, and fires an SDP offer.
3. When the remote peer sends media, the `pad-added` signal on the webrtcbin triggers `on_incoming_pad`.
4. `on_incoming_pad` creates a `decodebin`, links the incoming pad to it, and connects the `pad-added` signal of the decodebin to `on_decoded_pad`.
5. **Video** – `on_decoded_pad` receives the decoded video pad, requests a compositor sink pad, calculates `x`, `y`, `w`, `h` using `state.pad_index`, and links the pipeline.
6. **Audio** – a similar path sends the audio pads to the `audiomixer` (no grid logic required).
7. The compositor (with its positioned pads) and the audio mixer feed into the MP4 muxer for recording.

---

## Extending the grid

If you need more than four video streams, you can:
- Increase the grid dimensions (e.g., `cols = 3`, `rows = 2`).
- Compute `w = WIDTH / cols; h = HEIGHT / rows;` and adjust the `x`/`y` formulas accordingly.
- Optionally clamp `idx` so that streams beyond the grid are either discarded or placed in an overflow area.

---

## References in the source code

- **Peer map creation** – `setup_peer()` (lines ~96‑111).
- **Grid layout** – `on_decoded_pad()` (lines ~226‑247).
- **Global state definition** – top of `gst.c` (lines ~14‑25).

---

*This document is intended to be added to the repository as documentation for developers working on the GStreamer MCU component.*
