#!/bin/bash
# gst-mixer.sh - Compile and run the GStreamer MCU Mixer

C_SRC="c_src/gst.c"
BIN="priv/gst_recorder"
OUT_FILE="${1:-output.mp4}"

mkdir -p priv

# Check if we need to compile
if [ ! -f "$BIN" ] || [ "$C_SRC" -nt "$BIN" ]; then
    echo "Compiling $C_SRC..." >&2
    cc -O3 "$C_SRC" -o "$BIN" $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-webrtc-1.0 gstreamer-sdp-1.0 json-glib-1.0)
    if [ $? -ne 0 ]; then
        echo "Compilation failed!" >&2
        exit 1
    fi
fi

# Run the mixer
exec "$BIN" "$OUT_FILE"
