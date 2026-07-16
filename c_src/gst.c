#define GST_USE_UNSTABLE_API

#include <gst/gst.h>
#include <gst/webrtc/webrtc.h>
#include <gst/sdp/sdp.h>
#include <json-glib/json-glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <glib-unix.h>

#define WIDTH 1920
#define HEIGHT 1080

typedef struct {
    gchar *peer_id;
    GstElement *webrtc;
    GstElement *v_queue;
    GstElement *a_queue;
    GstPad *comp_pad;
    GstPad *amix_pad;
    GstElement *v_decodebin;
    GstElement *a_decodebin;
    GstElement *v_convert;
    GstElement *a_convert;
    GstElement *a_resample;
    gint grid_idx;
} PeerInfo;

static void free_peer_info(gpointer data) {
    PeerInfo *peer = (PeerInfo *)data;
    g_free(peer->peer_id);
    g_free(peer);
}

typedef struct {
    GstElement *pipeline;
    GstElement *compositor;
    GstElement *audiomixer;
    GstElement *video_tee;
    GstElement *audio_tee;
    GHashTable *webrtcbins; // Maps peer_id (gchar*) -> PeerInfo*
    GMainLoop *loop;
    gboolean grid_slots[16];
    gint pad_index;
} RecorderState;

static RecorderState state;

// Prototypes
static void cleanup_peer(const gchar *peer_id);
static void on_incoming_pad(GstElement *webrtc, GstPad *pad, gpointer user_data);
static void on_ice_candidate(GstElement *webrtc, guint mline_idx, gchar *candidate, gpointer user_data);
static void handle_signaling_message(const gchar *json_str);

// Write JSON message to stdout (read by Erlang port)
static void send_to_erlang(JsonNode *root) {
    gchar *json_str = json_to_string(root, FALSE);
    printf("%s\n", json_str);
    fflush(stdout);
    g_free(json_str);
}

// IO channel callback for stdin signaling
static gboolean on_stdin_message(GIOChannel *source, GIOCondition cond, gpointer data) {
    gchar *line = NULL;
    gsize length = 0;
    GError *error = NULL;

    GIOStatus status = g_io_channel_read_line(source, &line, &length, NULL, &error);
    if (status == G_IO_STATUS_NORMAL) {
        if (line) {
            handle_signaling_message(line);
            g_free(line);
        }
    } else if (status == G_IO_STATUS_EOF || status == G_IO_STATUS_ERROR) {
        g_printerr("DEBUG: stdin EOF or error, exiting main loop...\n");
        g_main_loop_quit(state.loop);
        if (error) {
            g_printerr("Error reading stdin: %s\n", error->message);
            g_clear_error(&error);
        }
        return FALSE;
    }
    return TRUE;
}

// Handle offer creation callback
static void on_offer_created(GstPromise *promise, gpointer user_data) {
    gchar *peer_id = (gchar *)user_data;
    g_printerr("DEBUG: on_offer_created promise callback triggered for peer: %s\n", peer_id);
    const GstStructure *reply = gst_promise_get_reply(promise);
    if (!reply) {
        g_printerr("DEBUG: promise reply is NULL!\n");
        return;
    }
    GstWebRTCSessionDescription *offer = NULL;
    gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, NULL);
    if (!offer) {
        g_printerr("DEBUG: offer structure is NULL!\n");
        return;
    }
    g_printerr("DEBUG: successfully generated SDP offer\n");

    PeerInfo *peer = g_hash_table_lookup(state.webrtcbins, peer_id);
    GstElement *webrtc = peer ? peer->webrtc : NULL;
    if (!webrtc) return;

    GstPromise *local_desc_promise = gst_promise_new();
    g_signal_emit_by_name(webrtc, "set-local-description", offer, local_desc_promise);
    gst_promise_interrupt(local_desc_promise);
    gst_promise_unref(local_desc_promise);

    // Format SDP offer JSON
    gchar *sdp_text = gst_sdp_message_as_text(offer->sdp);

    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "type");
    json_builder_add_string_value(builder, "sdp_offer");
    json_builder_set_member_name(builder, "peer_id");
    json_builder_add_string_value(builder, peer_id);
    json_builder_set_member_name(builder, "sdp");
    json_builder_add_string_value(builder, sdp_text);
    json_builder_end_object(builder);

    JsonNode *root = json_builder_get_root(builder);
    send_to_erlang(root);

    json_node_free(root);
    g_object_unref(builder);
    g_free(sdp_text);
    gst_webrtc_session_description_free(offer);
}

// Setup webrtcbin for a newly joined peer (Both receiving upstream & broadcasting downstream)
static void setup_peer(const gchar *peer_id) {
    g_printerr("DEBUG: Setting up webrtcbin for peer: %s\n", peer_id);
    gchar *bin_name = g_strdup_printf("webrtc_%s", peer_id);
    GstElement *webrtc = gst_element_factory_make("webrtcbin", bin_name);
    g_free(bin_name);

    if (!webrtc) {
        g_printerr("Error: Failed to create webrtcbin\n");
        return;
    }

    PeerInfo *peer = g_new0(PeerInfo, 1);
    peer->peer_id = g_strdup(peer_id);
    peer->webrtc = webrtc;
    peer->grid_idx = -1;

    for (int i = 0; i < 16; i++) {
        if (!state.grid_slots[i]) {
            state.grid_slots[i] = TRUE;
            peer->grid_idx = i;
            break;
        }
    }
    if (peer->grid_idx == -1) peer->grid_idx = 0;

    gchar *vqueue_name = g_strdup_printf("vqueue_%s", peer_id);
    GstElement *v_queue = gst_element_factory_make("queue", vqueue_name);
    g_free(vqueue_name);

    gchar *aqueue_name = g_strdup_printf("aqueue_%s", peer_id);
    GstElement *a_queue = gst_element_factory_make("queue", aqueue_name);
    g_free(aqueue_name);

    peer->v_queue = v_queue;
    peer->a_queue = a_queue;

    // Set queues as leaky to prevent deadlocking the tee when a client lags or leaves
    g_object_set(v_queue, "leaky", 2, "max-size-buffers", 60, NULL);
    g_object_set(a_queue, "leaky", 2, "max-size-buffers", 60, NULL);

    gst_bin_add_many(GST_BIN(state.pipeline), webrtc, v_queue, a_queue, NULL);

    // Link downstream mixed video broadcast (vtee) to this peer's webrtcbin
    GstPad *vtee_src = gst_element_request_pad_simple(state.video_tee, "src_%u");
    GstPad *vqueue_sink = gst_element_get_static_pad(v_queue, "sink");
    GstPad *vqueue_src = gst_element_get_static_pad(v_queue, "src");
    GstPad *webrtc_vsink = gst_element_request_pad_simple(webrtc, "sink_0");

    gst_pad_link(vtee_src, vqueue_sink);
    gst_pad_link(vqueue_src, webrtc_vsink);

    gst_object_unref(vtee_src);
    gst_object_unref(vqueue_sink);
    gst_object_unref(vqueue_src);
    gst_object_unref(webrtc_vsink);

    // Link downstream mixed audio broadcast (atee) to this peer's webrtcbin
    GstPad *atee_src = gst_element_request_pad_simple(state.audio_tee, "src_%u");
    GstPad *aqueue_sink = gst_element_get_static_pad(a_queue, "sink");
    GstPad *aqueue_src = gst_element_get_static_pad(a_queue, "src");
    GstPad *webrtc_asink = gst_element_request_pad_simple(webrtc, "sink_1");

    gst_pad_link(atee_src, aqueue_sink);
    gst_pad_link(aqueue_src, webrtc_asink);

    gst_object_unref(atee_src);
    gst_object_unref(aqueue_sink);
    gst_object_unref(aqueue_src);
    gst_object_unref(webrtc_asink);

    // Sync state after elements are added and linked
    gst_element_sync_state_with_parent(v_queue);
    gst_element_sync_state_with_parent(a_queue);
    gst_element_sync_state_with_parent(webrtc);

    g_hash_table_insert(state.webrtcbins, g_strdup(peer_id), peer);

    // Connect GObject signaling handlers
    g_signal_connect(webrtc, "on-ice-candidate", G_CALLBACK(on_ice_candidate), peer);
    g_signal_connect(webrtc, "pad-added", G_CALLBACK(on_incoming_pad), peer);

    // Create SDP Offer
    GstPromise *promise = gst_promise_new_with_change_func(on_offer_created, g_strdup(peer_id), NULL);
    g_signal_emit_by_name(webrtc, "create-offer", NULL, promise);
}

static void cleanup_peer(const gchar *peer_id) {
    g_printerr("DEBUG: Starting cleanup for peer: %s\n", peer_id);
    PeerInfo *peer = g_hash_table_lookup(state.webrtcbins, peer_id);
    if (!peer) {
        g_printerr("DEBUG: Peer %s not found for cleanup\n", peer_id);
        return;
    }

    // 1. Disconnect and release video tee src pad, remove v_queue
    if (peer->v_queue) {
        GstPad *sink = gst_element_get_static_pad(peer->v_queue, "sink");
        if (sink) {
            GstPad *vtee_src = gst_pad_get_peer(sink);
            if (vtee_src) {
                gst_pad_unlink(vtee_src, sink);
                gst_element_release_request_pad(state.video_tee, vtee_src);
                gst_object_unref(vtee_src);
            }
            gst_object_unref(sink);
        }
        gst_element_set_state(peer->v_queue, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->v_queue);
    }

    // 2. Disconnect and release audio tee src pad, remove a_queue
    if (peer->a_queue) {
        GstPad *sink = gst_element_get_static_pad(peer->a_queue, "sink");
        if (sink) {
            GstPad *atee_src = gst_pad_get_peer(sink);
            if (atee_src) {
                gst_pad_unlink(atee_src, sink);
                gst_element_release_request_pad(state.audio_tee, atee_src);
                gst_object_unref(atee_src);
            }
            gst_object_unref(sink);
        }
        gst_element_set_state(peer->a_queue, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->a_queue);
    }

    // 3. Disconnect and release compositor pad, remove dynamic video converter and decodebin
    if (peer->comp_pad) {
        GstPad *peer_pad = gst_pad_get_peer(peer->comp_pad);
        if (peer_pad) {
            gst_pad_unlink(peer_pad, peer->comp_pad);
            gst_object_unref(peer_pad);
        }
        gst_element_release_request_pad(state.compositor, peer->comp_pad);
        gst_object_unref(peer->comp_pad);
    }
    if (peer->v_convert) {
        gst_element_set_state(peer->v_convert, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->v_convert);
    }
    if (peer->v_decodebin) {
        gst_element_set_state(peer->v_decodebin, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->v_decodebin);
    }

    // 4. Disconnect and release audiomixer pad, remove dynamic audio resampler, converter and decodebin
    if (peer->amix_pad) {
        GstPad *peer_pad = gst_pad_get_peer(peer->amix_pad);
        if (peer_pad) {
            gst_pad_unlink(peer_pad, peer->amix_pad);
            gst_object_unref(peer_pad);
        }
        gst_element_release_request_pad(state.audiomixer, peer->amix_pad);
        gst_object_unref(peer->amix_pad);
    }
    if (peer->a_resample) {
        gst_element_set_state(peer->a_resample, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->a_resample);
    }
    if (peer->a_convert) {
        gst_element_set_state(peer->a_convert, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->a_convert);
    }
    if (peer->a_decodebin) {
        gst_element_set_state(peer->a_decodebin, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->a_decodebin);
    }

    // 5. Remove webrtcbin
    if (peer->webrtc) {
        gst_element_set_state(peer->webrtc, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->webrtc);
    }

    // Free up grid slot
    if (peer->grid_idx >= 0 && peer->grid_idx < 16) {
        state.grid_slots[peer->grid_idx] = FALSE;
    }

    // Free up grid slot
    if (peer->grid_idx >= 0 && peer->grid_idx < 16) {
        state.grid_slots[peer->grid_idx] = FALSE;
    }

    // 6. Remove peer from hashtable (triggers free_peer_info)
    g_hash_table_remove(state.webrtcbins, peer_id);
    g_printerr("DEBUG: Cleaned up peer: %s\n", peer_id);
}

static void handle_signaling_message(const gchar *json_str) {
    JsonParser *parser = json_parser_new();
    if (!json_parser_load_from_data(parser, json_str, -1, NULL)) {
        g_object_unref(parser);
        return;
    }

    JsonObject *root = json_node_get_object(json_parser_get_root(parser));
    const gchar *type = json_object_get_string_member(root, "type");

    if (g_strcmp0(type, "peer_joined") == 0) {
        const gchar *peer_id = json_object_get_string_member(root, "peer_id");
        setup_peer(peer_id);
    } else if (g_strcmp0(type, "sdp_answer") == 0) {
        const gchar *peer_id = json_object_get_string_member(root, "peer_id");
        const gchar *sdp_text = json_object_get_string_member(root, "sdp");

        PeerInfo *peer = g_hash_table_lookup(state.webrtcbins, peer_id);
        GstElement *webrtc = peer ? peer->webrtc : NULL;
        if (webrtc) {
            GstSDPMessage *sdp = NULL;
            gst_sdp_message_new(&sdp);
            gst_sdp_message_parse_buffer((const guint8 *)sdp_text, strlen(sdp_text), sdp);
            GstWebRTCSessionDescription *answer = gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, sdp);

            GstPromise *promise = gst_promise_new();
            g_signal_emit_by_name(webrtc, "set-remote-description", answer, promise);
            gst_promise_interrupt(promise);
            gst_promise_unref(promise);
            gst_webrtc_session_description_free(answer);
        }
    } else if (g_strcmp0(type, "ice_candidate") == 0) {
        const gchar *peer_id = json_object_get_string_member(root, "peer_id");
        JsonObject *candidate_obj = json_object_get_object_member(root, "candidate");
        gint mline_idx = json_object_get_int_member(candidate_obj, "sdpMLineIndex");
        const gchar *candidate_str = json_object_get_string_member(candidate_obj, "candidate");

        PeerInfo *peer = g_hash_table_lookup(state.webrtcbins, peer_id);
        GstElement *webrtc = peer ? peer->webrtc : NULL;
        if (webrtc) {
            g_signal_emit_by_name(webrtc, "add-ice-candidate", mline_idx, candidate_str);
        }
    } else if (g_strcmp0(type, "peer_left") == 0) {
        const gchar *peer_id = json_object_get_string_member(root, "peer_id");
        cleanup_peer(peer_id);
    }
    g_object_unref(parser);
}

static void on_ice_candidate(GstElement *webrtc, guint mline_idx, gchar *candidate, gpointer user_data) {
    PeerInfo *peer = (PeerInfo *)user_data;
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "type");
    json_builder_add_string_value(builder, "ice_candidate");
    json_builder_set_member_name(builder, "peer_id");
    json_builder_add_string_value(builder, peer->peer_id);

    json_builder_set_member_name(builder, "candidate");
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "sdpMLineIndex");
    json_builder_add_int_value(builder, mline_idx);
    json_builder_set_member_name(builder, "candidate");
    json_builder_add_string_value(builder, candidate);
    json_builder_end_object(builder);

    json_builder_end_object(builder);

    JsonNode *root = json_builder_get_root(builder);
    send_to_erlang(root);

    json_node_free(root);
    g_object_unref(builder);
}

// Link decoded raw pads into audio and video mixers
static void on_decoded_pad(GstElement *decodebin, GstPad *pad, gpointer user_data) {
    PeerInfo *peer = (PeerInfo *)user_data;
    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) return;
    const GstStructure *str = gst_caps_get_structure(caps, 0);
    const gchar *name = gst_structure_get_name(str);

    if (g_str_has_prefix(name, "video")) {
        gst_caps_unref(caps);
        g_printerr("DEBUG: Linking video pad to compositor for peer: %s\n", peer->peer_id);

        // Request compositor sink pad and lay it out in the grid
        GstPad *comp_pad = gst_element_request_pad_simple(state.compositor, "sink_%u");
        peer->comp_pad = comp_pad; // Keep ownership reference for cleanup

        gint idx = peer->grid_idx;
        gint w = WIDTH / 2;
        gint h = HEIGHT / 2;
        gint x = (idx % 2) * w;
        gint y = (idx / 2) * h;

        g_object_set(comp_pad, "xpos", x, "ypos", y, "width", w, "height", h, "zorder", (guint) (idx + 10), "sizing-policy", 1, NULL);
        g_printerr("DEBUG: Linked video pad to compositor quadrant position (%d, %d) with zorder %u\n", x, y, idx + 10);

        GstElement *converter = gst_element_factory_make("videoconvert", NULL);
        peer->v_convert = converter;
        gst_bin_add(GST_BIN(state.pipeline), converter);

        GstPad *conv_sink = gst_element_get_static_pad(converter, "sink");
        GstPad *conv_src = gst_element_get_static_pad(converter, "src");

        GstPadLinkReturn ret1 = gst_pad_link(pad, conv_sink);
        GstPadLinkReturn ret2 = gst_pad_link(conv_src, comp_pad);
        g_printerr("DEBUG: video gst_pad_link results: pad->conv_sink=%d, conv_src->comp_pad=%d\n", ret1, ret2);

        gst_element_sync_state_with_parent(converter);

        gst_object_unref(conv_sink);
        gst_object_unref(conv_src);

    } else if (g_str_has_prefix(name, "audio")) {
        gst_caps_unref(caps);
        g_printerr("DEBUG: Linking audio pad to audiomixer for peer: %s\n", peer->peer_id);

        GstPad *amix_pad = gst_element_request_pad_simple(state.audiomixer, "sink_%u");
        peer->amix_pad = amix_pad; // Keep ownership reference for cleanup

        GstElement *converter = gst_element_factory_make("audioconvert", NULL);
        GstElement *resampler = gst_element_factory_make("audioresample", NULL);
        peer->a_convert = converter;
        peer->a_resample = resampler;

        gst_bin_add_many(GST_BIN(state.pipeline), converter, resampler, NULL);

        GstPad *conv_sink = gst_element_get_static_pad(converter, "sink");
        GstPad *conv_src = gst_element_get_static_pad(converter, "src");
        GstPad *res_sink = gst_element_get_static_pad(resampler, "sink");
        GstPad *res_src = gst_element_get_static_pad(resampler, "src");

        gst_pad_link(pad, conv_sink);
        gst_pad_link(conv_src, res_sink);
        gst_pad_link(res_src, amix_pad);

        gst_element_sync_state_with_parent(converter);
        gst_element_sync_state_with_parent(resampler);

        gst_object_unref(conv_sink);
        gst_object_unref(conv_src);
        gst_object_unref(res_sink);
        gst_object_unref(res_src);
    } else {
        gst_caps_unref(caps);
    }
}

static void on_incoming_pad(GstElement *webrtc, GstPad *pad, gpointer user_data) {
    PeerInfo *peer = (PeerInfo *)user_data;
    if (GST_PAD_DIRECTION(pad) != GST_PAD_SRC) return;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) return;
    const GstStructure *str = gst_caps_get_structure(caps, 0);
    const gchar *media = gst_structure_get_string(str, "media");
    gboolean is_video = (g_strcmp0(media, "video") == 0);
    gboolean is_audio = (g_strcmp0(media, "audio") == 0);
    gst_caps_unref(caps);

    if (!is_video && !is_audio) return;

    g_printerr("DEBUG: New incoming track (%s) from peer: %s\n", is_video ? "video" : "audio", peer->peer_id);

    // Create decodebin for track decoding
    GstElement *decodebin = gst_element_factory_make("decodebin", NULL);
    gst_bin_add(GST_BIN(state.pipeline), decodebin);

    GstPad *sinkpad = gst_element_get_static_pad(decodebin, "sink");
    gst_pad_link(pad, sinkpad);
    gst_object_unref(sinkpad);

    gst_element_sync_state_with_parent(decodebin);

    if (is_video) {
        peer->v_decodebin = decodebin;
    } else {
        peer->a_decodebin = decodebin;
    }

    g_signal_connect(decodebin, "pad-added", G_CALLBACK(on_decoded_pad), peer);
}

static gboolean on_unix_signal(gpointer user_data) {
    gint sig = GPOINTER_TO_INT(user_data);
    g_printerr("DEBUG: Caught signal %d via GLib, sending EOS to mux...\n", sig);
    GstElement *mux = gst_bin_get_by_name(GST_BIN(state.pipeline), "mux");
    if (mux) {
        gst_element_send_event(mux, gst_event_new_eos());
        gst_object_unref(mux);
    }
    return FALSE;
}

static gboolean on_bus_message(GstBus *bus, GstMessage *message, gpointer data) {
    switch (GST_MESSAGE_TYPE(message)) {
        case GST_MESSAGE_EOS:
            g_printerr("DEBUG: Received EOS on bus, exiting main loop\n");
            g_main_loop_quit(state.loop);
            break;
        case GST_MESSAGE_ERROR: {
            GError *err = NULL;
            gchar *debug = NULL;
            gst_message_parse_error(message, &err, &debug);
            g_printerr("Error on bus: %s (%s)\n", err->message, debug ? debug : "");
            g_clear_error(&err);
            g_free(debug);
            g_main_loop_quit(state.loop);
            break;
        }
        default:
            break;
    }
    return TRUE;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        g_printerr("Usage: %s <output_directory>\n", argv[0]);
        return 1;
    }
    const gchar *out_dir = argv[1];
    const gchar *format = (argc >= 3) ? argv[2] : "ts";

    gst_init(&argc, &argv);

    state.webrtcbins = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, free_peer_info);
    state.pad_index = 1;
    for (int i = 0; i < 16; i++) state.grid_slots[i] = FALSE;
    state.loop = g_main_loop_new(NULL, FALSE);

    gint64 ts = g_get_real_time() / G_USEC_PER_SEC;

    gchar *pipeline_str = NULL;
    if (g_strcmp0(format, "fmp4") == 0 || g_strcmp0(format, "mp4") == 0) {
        g_printerr("Using fMP4 fragmented single file recording format.\n");
        pipeline_str = g_strdup_printf(
            "videotestsrc pattern=black is-live=true ! timeoverlay valignment=bottom halignment=right font-desc=\"Sans, 48\" ! video/x-raw,width=1920,height=1080,framerate=30/1 ! mix.sink_0 "
            "audiotestsrc is-live=true volume=0 ! amix.sink_0 "
            "compositor name=mix ignore-inactive-pads=true ! videoconvert ! video/x-raw,format=I420 ! x264enc bitrate=4000 "
            "speed-preset=ultrafast key-int-max=30 tune=zerolatency ! video/x-h264,profile=baseline ! h264parse ! tee name=h264_tee "
            "h264_tee. ! queue ! rtph264pay config-interval=1 pt=96 ! tee name=vtee "
            "audiomixer name=amix ignore-inactive-pads=true ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=2 ! tee name=raw_atee "
            "raw_atee. ! queue ! opusenc ! rtpopuspay pt=111 ! tee name=atee "
            "mp4mux name=mux fragment-duration=1000 streamable=true ! filesink location=%s/recording.mp4 "
            "h264_tee. ! queue max-size-time=30000000000 max-size-bytes=0 max-size-buffers=0 leaky=2 ! mux.video_0 "
            "raw_atee. ! queue max-size-time=30000000000 max-size-bytes=0 max-size-buffers=0 leaky=2 ! audioconvert ! audioresample ! audio/x-raw,rate=44100,channels=2 ! avenc_aac ! aacparse ! mux.audio_0",
            out_dir
        );
    } else if (g_strcmp0(format, "hevc") == 0 || g_strcmp0(format, "h265") == 0) {
        g_printerr("Using HLS segment generation format with HEVC (H.265).\n");
        pipeline_str = g_strdup_printf(
            "videotestsrc pattern=black is-live=true ! timeoverlay valignment=bottom halignment=right font-desc=\"Sans, 48\" ! video/x-raw,width=1920,height=1080,framerate=30/1 ! mix.sink_0 "
            "audiotestsrc is-live=true volume=0 ! amix.sink_0 "
            "compositor name=mix ignore-inactive-pads=true ! videoconvert ! video/x-raw,format=I420 ! tee name=raw_vtee "
            "raw_vtee. ! queue ! x264enc bitrate=4000 speed-preset=ultrafast key-int-max=30 tune=zerolatency ! video/x-h264,profile=baseline ! h264parse ! rtph264pay config-interval=1 pt=96 ! tee name=vtee "
            "audiomixer name=amix ignore-inactive-pads=true ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=2 ! tee name=raw_atee "
            "raw_atee. ! queue ! opusenc ! rtpopuspay pt=111 ! tee name=atee "
            "raw_vtee. ! queue max-size-time=30000000000 max-size-bytes=0 max-size-buffers=0 leaky=2 ! x265enc bitrate=4000 speed-preset=ultrafast tune=zerolatency key-int-max=60 ! h265parse ! hlssink2.video "
            "raw_atee. ! queue max-size-time=30000000000 max-size-bytes=0 max-size-buffers=0 leaky=2 ! audioconvert ! audioresample ! audio/x-raw,rate=44100,channels=2 ! avenc_aac ! aacparse ! hlssink2.audio "
            "hlssink2 name=hlssink2 location=%s/segment_%ld_%%05d.ts playlist-location=%s/index.m3u8 target-duration=2 max-files=0 playlist-length=10",
            out_dir, ts, out_dir
        );
    } else {
        g_printerr("Using HLS segment generation format (H.264).\n");
        pipeline_str = g_strdup_printf(
            "videotestsrc pattern=black is-live=true ! timeoverlay valignment=bottom halignment=right font-desc=\"Sans, 48\" ! video/x-raw,width=1920,height=1080,framerate=30/1 ! mix.sink_0 "
            "audiotestsrc is-live=true volume=0 ! amix.sink_0 "
            "compositor name=mix ignore-inactive-pads=true ! videoconvert ! video/x-raw,format=I420 ! x264enc bitrate=4000 "
            "speed-preset=ultrafast key-int-max=150 tune=zerolatency ! video/x-h264,profile=baseline ! h264parse ! tee name=h264_tee "
            "h264_tee. ! queue ! rtph264pay config-interval=1 pt=96 ! tee name=vtee "
            "audiomixer name=amix ignore-inactive-pads=true ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=2 ! tee name=raw_atee "
            "raw_atee. ! queue ! opusenc ! rtpopuspay pt=111 ! tee name=atee "
            "h264_tee. ! queue max-size-time=30000000000 max-size-bytes=0 max-size-buffers=0 leaky=2 ! hlssink2.video "
            "raw_atee. ! queue max-size-time=30000000000 max-size-bytes=0 max-size-buffers=0 leaky=2 ! audioconvert ! audioresample ! audio/x-raw,rate=44100,channels=2 ! avenc_aac ! aacparse ! hlssink2.audio "
            "hlssink2 name=hlssink2 location=%s/segment_%ld_%%05d.ts playlist-location=%s/index.m3u8 target-duration=5 max-files=0 playlist-length=10",
            out_dir, ts, out_dir
        );
    }
    state.pipeline = gst_parse_launch(pipeline_str, NULL);
    g_free(pipeline_str);

    if (!state.pipeline) {
        g_printerr("Error: Failed to parse GStreamer MCU pipeline\n");
        return 1;
    }

    GstBus *bus = gst_element_get_bus(state.pipeline);
    gst_bus_add_watch(bus, on_bus_message, NULL);
    gst_object_unref(bus);

    g_unix_signal_add(SIGINT, on_unix_signal, GINT_TO_POINTER(SIGINT));
    g_unix_signal_add(SIGTERM, on_unix_signal, GINT_TO_POINTER(SIGTERM));

    state.compositor = gst_bin_get_by_name(GST_BIN(state.pipeline), "mix");
    if (state.compositor) {
        GstPad *bg_pad = gst_element_get_static_pad(state.compositor, "sink_0");
        if (bg_pad) {
            g_object_set(bg_pad, "zorder", (guint) 1, NULL);
            gst_object_unref(bg_pad);
        }
    }
    state.audiomixer = gst_bin_get_by_name(GST_BIN(state.pipeline), "amix");
    state.video_tee = gst_bin_get_by_name(GST_BIN(state.pipeline), "vtee");
    state.audio_tee = gst_bin_get_by_name(GST_BIN(state.pipeline), "atee");

    gst_element_set_state(state.pipeline, GST_STATE_PLAYING);

    // Send a message to Erlang that the recording pipeline is playing
    g_printerr("{\"type\": \"recording_started\"}\n");
    
    // Setup stdin signaling channel reader via GLib IO channels
    GIOChannel *stdin_chan = g_io_channel_unix_new(0); // 0 = stdin
    g_io_add_watch(stdin_chan, G_IO_IN | G_IO_PRI, on_stdin_message, NULL);
    g_io_channel_unref(stdin_chan);

    g_printerr("DEBUG: GStreamer MCU C process started\n");
    fflush(stdout);

    // Enters GLib loop (runs main thread)
    g_main_loop_run(state.loop);

    // Cleanup
    gst_element_set_state(state.pipeline, GST_STATE_NULL);
    gst_object_unref(state.pipeline);
    gst_object_unref(state.compositor);
    gst_object_unref(state.audiomixer);
    gst_object_unref(state.video_tee);
    gst_object_unref(state.audio_tee);
    g_hash_table_destroy(state.webrtcbins);
    g_main_loop_unref(state.loop);

    return 0;
}