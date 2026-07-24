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

//Part 1: Structs & Helpers

typedef struct {
    gchar *candidate;
    guint mline_idx;
} PendingIceCandidate;

typedef struct {
    gchar *peer_id;
    GstElement *webrtc;
    GstElement *v_queue;        // outgoing to peer
    GstElement *a_queue;
    GstPad *comp_pad;
    GstPad *amix_pad;
    GstElement *v_decodebin;
    GstElement *a_decodebin;
    GstElement *v_convert;
    GstElement *v_jitter;
    GstElement *a_convert;
    GstElement *a_jitter;
    GstElement *a_resample;
    gint grid_idx;
    gboolean remote_desc_set;
    gboolean bundled;
    GArray *pending_ice_candidates;
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
    GHashTable *webrtcbins;
    GMainLoop *loop;
    gboolean grid_slots[16];
} RecorderState;

static RecorderState state;

typedef struct {
    gchar *pem_certificate;
    gchar *pem_key;
    GstWebRTCBundlePolicy bundle_policy;
    guint latency;
} WebRTCConfig;

static WebRTCConfig global_config = {
    .pem_certificate = NULL,
    .pem_key = NULL,
    .bundle_policy = GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE,
    .latency = 220
};

// WSL2 Helpers

static gboolean is_wsl(void) {
    static gint in_wsl = -1;
    if (in_wsl != -1) return (gboolean)in_wsl;
    if (getenv("WSL_DISTRO_NAME") || getenv("WSL_INTEROP")) {
        in_wsl = 1; return TRUE;
    }
    FILE *f = fopen("/proc/sys/kernel/osrelease", "r");
    if (f) {
        char buf[256] = {0};
        if (fgets(buf, sizeof(buf), f) && (strstr(buf, "WSL") || strstr(buf, "microsoft"))) {
            fclose(f); in_wsl = 1; return TRUE;
        }
        fclose(f);
    }
    in_wsl = 0; return FALSE;
}

static gchar *replace_wsl_ip(const gchar *candidate) {
    if (!candidate || !is_wsl()) return g_strdup(candidate);
    const gchar *p = strstr(candidate, " 172.");
    if (!p) return g_strdup(candidate);
    const gchar *p_end = strchr(p + 1, ' ');
    if (!p_end) return g_strdup(candidate);
    GString *res = g_string_new_len(candidate, p - candidate);
    g_string_append(res, " 127.0.0.1");
    g_string_append(res, p_end);
    return g_string_free(res, FALSE);
}

// Prototypes

static void cleanup_peer(const gchar *peer_id);
static void on_incoming_pad(GstElement *webrtc, GstPad *pad, gpointer user_data);
static void on_ice_candidate(GstElement *webrtc, guint mline_idx, gchar *candidate, gpointer user_data);
static void handle_signaling_message(const gchar *json_str);

static void add_remote_ice_candidate_impl(GstElement *webrtc, guint mline_idx, const gchar *candidate_str, gboolean bundled) {
    if (!webrtc || !candidate_str) return;
    g_signal_emit_by_name(webrtc, "add-ice-candidate", mline_idx, candidate_str);
    if (bundled)
        g_signal_emit_by_name(webrtc, "add-ice-candidate", (mline_idx == 0 ? 1 : 0), candidate_str);
    if (is_wsl()) {
        gchar *dup = replace_wsl_ip(candidate_str);
        if (dup && g_strcmp0(dup, candidate_str) != 0) {
            g_signal_emit_by_name(webrtc, "add-ice-candidate", mline_idx, dup);
            if (bundled)
                g_signal_emit_by_name(webrtc, "add-ice-candidate", (mline_idx == 0 ? 1 : 0), dup);
        }
        if (dup) g_free(dup);
    }
}

/* Remote description is set synchronously upon set-remote-description signal emit */

// Part 2: Signaling & Core Callbacks

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

static void send_to_erlang(JsonNode *root) {
    gchar *json_str = json_to_string(root, FALSE);
    printf("%s\n", json_str);
    fflush(stdout);
    g_free(json_str);
}

static void on_offer_created(GstPromise *promise, gpointer user_data) {
    // (Same as your original - unchanged)
    gchar *peer_id = (gchar *)user_data;
    const GstStructure *reply = gst_promise_get_reply(promise);
    GstWebRTCSessionDescription *offer = NULL;
    gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, NULL);
    if (!offer) return;

    PeerInfo *peer = g_hash_table_lookup(state.webrtcbins, peer_id);
    if (!peer) return;

    GstPromise *local_desc_promise = gst_promise_new();
    g_signal_emit_by_name(peer->webrtc, "set-local-description", offer, local_desc_promise);
    gst_promise_unref(local_desc_promise);

    gchar *sdp_text = gst_sdp_message_as_text(offer->sdp);

    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "type"); json_builder_add_string_value(builder, "sdp_offer");
    json_builder_set_member_name(builder, "peer_id"); json_builder_add_string_value(builder, peer_id);
    json_builder_set_member_name(builder, "sdp"); json_builder_add_string_value(builder, sdp_text);
    json_builder_end_object(builder);

    JsonNode *root = json_builder_get_root(builder);
    send_to_erlang(root);

    json_node_free(root);
    g_object_unref(builder);
    g_free(sdp_text);
    gst_webrtc_session_description_free(offer);
}

static void on_ice_candidate(GstElement *webrtc, guint mline_idx, gchar *candidate, gpointer user_data) {
    PeerInfo *peer = (PeerInfo *)user_data;
    gchar *fixed = replace_wsl_ip(candidate);

    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "type"); json_builder_add_string_value(builder, "ice_candidate");
    json_builder_set_member_name(builder, "peer_id"); json_builder_add_string_value(builder, peer->peer_id);
    json_builder_set_member_name(builder, "candidate");
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "sdpMLineIndex"); json_builder_add_int_value(builder, mline_idx);
    json_builder_set_member_name(builder, "candidate"); json_builder_add_string_value(builder, fixed ? fixed : candidate);
    json_builder_end_object(builder);
    json_builder_end_object(builder);

    JsonNode *root = json_builder_get_root(builder);
    send_to_erlang(root);

    json_node_free(root);
    g_object_unref(builder);
    if (fixed) g_free(fixed);
}

// ==================== LOW LATENCY INGEST ====================

static void on_decoded_pad(GstElement *decodebin, GstPad *pad, gpointer user_data) {
    PeerInfo *peer = (PeerInfo *)user_data;
    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) return;
    const gchar *name = gst_structure_get_name(gst_caps_get_structure(caps, 0));

    if (g_str_has_prefix(name, "video")) {
        gst_caps_unref(caps);
        g_printerr("DEBUG: Linking video for peer: %s\n", peer->peer_id);

        GstPad *comp_pad = gst_element_request_pad_simple(state.compositor, "sink_%u");
        peer->comp_pad = comp_pad;

        gint idx = peer->grid_idx;
        gint w = WIDTH / 2, h = HEIGHT / 2;
        gint x = (idx % 2) * w, y = (idx / 2) * h;

        g_object_set(comp_pad, "xpos", x, "ypos", y, "width", w, "height", h,
                     "zorder", (guint)(idx + 10), "sizing-policy", 1, NULL);

        GstElement *jitter = gst_element_factory_make("queue", NULL);
        GstElement *converter = gst_element_factory_make("videoconvert", NULL);

        g_object_set(jitter,
            "max-size-buffers", 5,
            "max-size-bytes", 0,
            "max-size-time", (guint64)0,
            "leaky", 2,
            NULL);

        peer->v_jitter = jitter;
        peer->v_convert = converter;

        gst_bin_add_many(GST_BIN(state.pipeline), jitter, converter, NULL);

        GstPad *j_sink = gst_element_get_static_pad(jitter, "sink");
        GstPad *j_src  = gst_element_get_static_pad(jitter, "src");
        GstPad *c_sink = gst_element_get_static_pad(converter, "sink");
        GstPad *c_src  = gst_element_get_static_pad(converter, "src");

        gst_pad_link(pad, j_sink);
        gst_pad_link(j_src, c_sink);
        gst_pad_link(c_src, comp_pad);

        gst_element_sync_state_with_parent(jitter);
        gst_element_sync_state_with_parent(converter);

        gst_object_unref(j_sink); gst_object_unref(j_src);
        gst_object_unref(c_sink); gst_object_unref(c_src);

    } else if (g_str_has_prefix(name, "audio")) {
        gst_caps_unref(caps);
        g_printerr("DEBUG: Linking audio for peer: %s\n", peer->peer_id);

        GstPad *amix_pad = gst_element_request_pad_simple(state.audiomixer, "sink_%u");
        peer->amix_pad = amix_pad;

        GstElement *jitter = gst_element_factory_make("queue", NULL);
        GstElement *converter = gst_element_factory_make("audioconvert", NULL);
        GstElement *resampler = gst_element_factory_make("audioresample", NULL);

        g_object_set(jitter,
            "max-size-buffers", 5,
            "max-size-bytes", 0,
            "max-size-time", (guint64)0,
            "leaky", 2,
            NULL);

        peer->a_jitter = jitter;
        peer->a_convert = converter;
        peer->a_resample = resampler;

        gst_bin_add_many(GST_BIN(state.pipeline), jitter, converter, resampler, NULL);

        GstPad *j_sink    = gst_element_get_static_pad(jitter, "sink");
        GstPad *j_src     = gst_element_get_static_pad(jitter, "src");
        GstPad *conv_sink = gst_element_get_static_pad(converter, "sink");
        GstPad *conv_src  = gst_element_get_static_pad(converter, "src");
        GstPad *res_sink  = gst_element_get_static_pad(resampler, "sink");
        GstPad *res_src   = gst_element_get_static_pad(resampler, "src");

        gst_pad_link(pad, j_sink);
        gst_pad_link(j_src, conv_sink);
        gst_pad_link(conv_src, res_sink);
        gst_pad_link(res_src, amix_pad);

        gst_element_sync_state_with_parent(jitter);
        gst_element_sync_state_with_parent(converter);
        gst_element_sync_state_with_parent(resampler);

        gst_object_unref(j_sink);    gst_object_unref(j_src);
        gst_object_unref(conv_sink); gst_object_unref(conv_src);
        gst_object_unref(res_sink);  gst_object_unref(res_src);
    } else {
        gst_caps_unref(caps);
    }
}

static void on_incoming_pad(GstElement *webrtc, GstPad *pad, gpointer user_data) {
    PeerInfo *peer = (PeerInfo *)user_data;
    if (GST_PAD_DIRECTION(pad) != GST_PAD_SRC) return;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    gboolean is_video = FALSE, is_audio = FALSE;

    if (caps) {
        const gchar *media = gst_structure_get_string(gst_caps_get_structure(caps, 0), "media");
        is_video = g_strcmp0(media, "video") == 0;
        is_audio = g_strcmp0(media, "audio") == 0;
        gst_caps_unref(caps);
    }

    if (!is_video && !is_audio) return;

    GstElement *decodebin = gst_element_factory_make("decodebin", NULL);
    gst_bin_add(GST_BIN(state.pipeline), decodebin);

    GstPad *sinkpad = gst_element_get_static_pad(decodebin, "sink");
    gst_pad_link(pad, sinkpad);
    gst_object_unref(sinkpad);

    gst_element_sync_state_with_parent(decodebin);

    if (is_video) peer->v_decodebin = decodebin;
    else peer->a_decodebin = decodebin;

    g_signal_connect(decodebin, "pad-added", G_CALLBACK(on_decoded_pad), peer);
}

// ==================== SETUP PEER (Simplified) ====================

static void setup_peer(const gchar *peer_id) {
    g_printerr("DEBUG: Setting up peer: %s\n", peer_id);

    gchar *bin_name = g_strdup_printf("webrtc_%s", peer_id);
    GstElement *webrtc = gst_element_factory_make("webrtcbin", bin_name);
    g_free(bin_name);

    if (!webrtc) {
        g_printerr("Error: Failed to create webrtcbin\n");
        return;
    }

    // WebRTC Latency Profile:
    // - 50ms: Aggressive low-latency. Requires excellent fiber/LAN connections.
    // - 120ms: Balanced default. Suitable for typical broadband and TURN relay.
    // - 200ms+: High latency. Recommended for 3G/Mobile networks with high packet jitter.
    // Note: This configures the internal rtpjitterbuffer which buffers compressed packets efficiently.

    g_object_set(webrtc,
        "latency", global_config.latency,
        "bundle-policy", global_config.bundle_policy,
        "stun-server", "stun://127.0.0.1:3478",
        "turn-server", "turn://rtpuser:rtppassword@127.0.0.1:3478",
        NULL);

    /* pem-certificate/pem-key removed (not supported in GStreamer 1.20.x on Ubuntu 22.04) */

    PeerInfo *peer = g_new0(PeerInfo, 1);
    peer->peer_id = g_strdup(peer_id);
    peer->webrtc = webrtc;
    peer->grid_idx = -1;
    peer->remote_desc_set = FALSE;
    peer->bundled = FALSE;
    peer->pending_ice_candidates = g_array_new(FALSE, FALSE, sizeof(PendingIceCandidate));

    // Grid slot
    for (int i = 0; i < 16; i++) {
        if (!state.grid_slots[i]) {
            state.grid_slots[i] = TRUE;
            peer->grid_idx = i;
            break;
        }
    }
    if (peer->grid_idx == -1) peer->grid_idx = 0;

    // Outgoing queues to peer
    peer->v_queue = gst_element_factory_make("queue", NULL);
    peer->a_queue = gst_element_factory_make("queue", NULL);
    g_object_set(peer->v_queue, "leaky", 2, "max-size-time", (guint64)1000000000, NULL);
    g_object_set(peer->a_queue, "leaky", 2, "max-size-time", (guint64)1000000000, NULL);

    gst_bin_add_many(GST_BIN(state.pipeline), webrtc, peer->v_queue, peer->a_queue, NULL);

    // Link broadcast (vtee/atee) → this peer
    GstPad *vtee_src = gst_element_request_pad_simple(state.video_tee, "src_%u");
    GstPad *vqueue_sink = gst_element_get_static_pad(peer->v_queue, "sink");
    GstPad *vqueue_src = gst_element_get_static_pad(peer->v_queue, "src");
    GstPad *webrtc_vsink = gst_element_request_pad_simple(webrtc, "sink_0");

    gst_pad_link(vtee_src, vqueue_sink);
    gst_pad_link(vqueue_src, webrtc_vsink);

    // Same for audio...
    GstPad *atee_src = gst_element_request_pad_simple(state.audio_tee, "src_%u");
    GstPad *aqueue_sink = gst_element_get_static_pad(peer->a_queue, "sink");
    GstPad *aqueue_src = gst_element_get_static_pad(peer->a_queue, "src");
    GstPad *webrtc_asink = gst_element_request_pad_simple(webrtc, "sink_1");

    gst_pad_link(atee_src, aqueue_sink);
    gst_pad_link(aqueue_src, webrtc_asink);

    // Cleanup pads
    gst_object_unref(vtee_src); gst_object_unref(vqueue_sink); gst_object_unref(vqueue_src); gst_object_unref(webrtc_vsink);
    gst_object_unref(atee_src); gst_object_unref(aqueue_sink); gst_object_unref(aqueue_src); gst_object_unref(webrtc_asink);

    gst_element_sync_state_with_parent(peer->v_queue);
    gst_element_sync_state_with_parent(peer->a_queue);
    gst_element_sync_state_with_parent(webrtc);

    g_hash_table_insert(state.webrtcbins, g_strdup(peer_id), peer);

    g_signal_connect(webrtc, "on-ice-candidate", G_CALLBACK(on_ice_candidate), peer);
    g_signal_connect(webrtc, "pad-added", G_CALLBACK(on_incoming_pad), peer);

    GstPromise *promise = gst_promise_new_with_change_func(on_offer_created, g_strdup(peer_id), g_free);
    g_signal_emit_by_name(webrtc, "create-offer", NULL, promise);
}

// ==================== CLEANUP ====================

static void cleanup_peer(const gchar *peer_id) {
    g_printerr("DEBUG: Cleaning up peer: %s\n", peer_id);
    PeerInfo *peer = g_hash_table_lookup(state.webrtcbins, peer_id);
    if (!peer) return;

    // Release compositor and jitter queue
    if (peer->comp_pad) {
        GstPad *peer_pad = gst_pad_get_peer(peer->comp_pad);
        if (peer_pad) {
            gst_pad_unlink(peer_pad, peer->comp_pad);
            gst_object_unref(peer_pad);
        }
        gst_element_release_request_pad(state.compositor, peer->comp_pad);
        gst_object_unref(peer->comp_pad);
    }
    if (peer->v_jitter) {
        gst_element_set_state(peer->v_jitter, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->v_jitter);
    }
    if (peer->v_convert) {
        gst_element_set_state(peer->v_convert, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->v_convert);
    }
    if (peer->v_decodebin) {
        gst_element_set_state(peer->v_decodebin, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->v_decodebin);
    }

    // Disconnect and release audiomixer pad, remove dynamic audio resampler, converter and decodebin
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
    if (peer->a_jitter) {
        gst_element_set_state(peer->a_jitter, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->a_jitter);
    }
    if (peer->a_decodebin) {
        gst_element_set_state(peer->a_decodebin, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->a_decodebin);
    }

    // Disconnect and release video tee src pad, remove v_queue
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

    // Disconnect and release audio tee src pad, remove a_queue
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

    if (peer->webrtc) {
        gst_element_set_state(peer->webrtc, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->webrtc);
    }

    if (peer->grid_idx >= 0 && peer->grid_idx < 16)
        state.grid_slots[peer->grid_idx] = FALSE;

    g_hash_table_remove(state.webrtcbins, peer_id);
}

static void handle_signaling_message(const gchar *json_str) {
    // Same as your original (unchanged)
    JsonParser *parser = json_parser_new();
    if (!json_parser_load_from_data(parser, json_str, -1, NULL)) {
        g_object_unref(parser); return;
    }

    JsonObject *root = json_node_get_object(json_parser_get_root(parser));
    const gchar *type = json_object_get_string_member(root, "type");

    if (g_strcmp0(type, "config") == 0 || g_strcmp0(type, "init") == 0) {
        if (json_object_has_member(root, "pem_certificate") || json_object_has_member(root, "pem-certificate")) {
            const gchar *cert = json_object_has_member(root, "pem_certificate") ?
                json_object_get_string_member(root, "pem_certificate") :
                json_object_get_string_member(root, "pem-certificate");
            g_free(global_config.pem_certificate);
            global_config.pem_certificate = g_strdup(cert);
            g_printerr("DEBUG: Loaded custom WebRTC DTLS certificate into global config\n");
        }
        if (json_object_has_member(root, "pem_key") || json_object_has_member(root, "pem-key")) {
            const gchar *key = json_object_has_member(root, "pem_key") ?
                json_object_get_string_member(root, "pem_key") :
                json_object_get_string_member(root, "pem-key");
            g_free(global_config.pem_key);
            global_config.pem_key = g_strdup(key);
        }
        if (json_object_has_member(root, "latency")) {
            global_config.latency = (guint)json_object_get_int_member(root, "latency");
        }
        if (json_object_has_member(root, "bundle_policy") || json_object_has_member(root, "bundle-policy")) {
            const gchar *bp = json_object_has_member(root, "bundle_policy") ?
                json_object_get_string_member(root, "bundle_policy") :
                json_object_get_string_member(root, "bundle-policy");
            if (g_strcmp0(bp, "none") == 0) global_config.bundle_policy = GST_WEBRTC_BUNDLE_POLICY_NONE;
            else if (g_strcmp0(bp, "max-compat") == 0) global_config.bundle_policy = GST_WEBRTC_BUNDLE_POLICY_MAX_COMPAT;
            else global_config.bundle_policy = GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE;
        }
    } else if (g_strcmp0(type, "peer_joined") == 0) {
        const gchar *peer_id = json_object_get_string_member(root, "peer_id");
        setup_peer(peer_id);
    } else if (g_strcmp0(type, "sdp_answer") == 0) {
        const gchar *peer_id = json_object_get_string_member(root, "peer_id");
        const gchar *sdp_text = json_object_get_string_member(root, "sdp");

        PeerInfo *peer = g_hash_table_lookup(state.webrtcbins, peer_id);
        GstElement *webrtc = peer ? peer->webrtc : NULL;
        if (webrtc) {
            g_printerr("DEBUG: Received SDP answer for peer: %s\n", peer_id);
            GstSDPMessage *sdp = NULL;
            gst_sdp_message_new(&sdp);
            gst_sdp_message_parse_buffer((const guint8 *)sdp_text, strlen(sdp_text), sdp);
            gboolean is_bundled = FALSE;
            guint nmedia = gst_sdp_message_medias_len(sdp);
            if (nmedia >= 2) {
                const GstSDPMedia *m0 = gst_sdp_message_get_media(sdp, 0);
                const GstSDPMedia *m1 = gst_sdp_message_get_media(sdp, 1);
                const gchar *uf0 = gst_sdp_media_get_attribute_val(m0, "ice-ufrag");
                const gchar *uf1 = gst_sdp_media_get_attribute_val(m1, "ice-ufrag");
                if (uf0 && uf1 && g_strcmp0(uf0, uf1) == 0 && gst_sdp_media_get_port(m1) != 0)
                    is_bundled = TRUE;
            }
            if (peer) peer->bundled = is_bundled;

            GstWebRTCSessionDescription *answer = gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, sdp);
            GstPromise *promise = gst_promise_new();
            g_signal_emit_by_name(webrtc, "set-remote-description", answer, promise);
            gst_promise_interrupt(promise);
            gst_promise_unref(promise);
            gst_webrtc_session_description_free(answer);

            if (peer) {
                peer->remote_desc_set = TRUE;
                g_printerr("DEBUG: Remote description set for peer: %s (flushing queued candidates)\n", peer_id);
                if (peer->pending_ice_candidates) {
                    for (guint i = 0; i < peer->pending_ice_candidates->len; i++) {
                        PendingIceCandidate *cand = &g_array_index(peer->pending_ice_candidates, PendingIceCandidate, i);
                        add_remote_ice_candidate_impl(peer->webrtc, cand->mline_idx, cand->candidate, peer->bundled);
                        g_free(cand->candidate);
                    }
                    g_array_set_size(peer->pending_ice_candidates, 0);
                }
            }
        }
    } else if (g_strcmp0(type, "ice_candidate") == 0) {
        const gchar *peer_id = json_object_get_string_member(root, "peer_id");
        JsonObject *candidate_obj = json_object_get_object_member(root, "candidate");
        gint mline_idx = json_object_get_int_member(candidate_obj, "sdpMLineIndex");
        const gchar *candidate_str = json_object_get_string_member(candidate_obj, "candidate");

        PeerInfo *peer = g_hash_table_lookup(state.webrtcbins, peer_id);
        GstElement *webrtc = peer ? peer->webrtc : NULL;
        if (peer && peer->webrtc) {
            if (peer->remote_desc_set) {
                add_remote_ice_candidate_impl(peer->webrtc, (guint)mline_idx, candidate_str, peer->bundled);
            } else {
                PendingIceCandidate pending = { g_strdup(candidate_str), (guint)mline_idx };
                g_array_append_val(peer->pending_ice_candidates, pending);
            }
        }
    } else if (g_strcmp0(type, "peer_left") == 0) {
        const gchar *peer_id = json_object_get_string_member(root, "peer_id");
        cleanup_peer(peer_id);
    }
    g_object_unref(parser);
}

// ==================== SIGNAL & BUS HANDLERS ====================

static gboolean on_unix_signal(gpointer user_data) {
    gint sig = GPOINTER_TO_INT(user_data);
    g_printerr("DEBUG: Caught signal %d, sending EOS...\n", sig);
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
            g_printerr("DEBUG: Received EOS, exiting...\n");
            g_main_loop_quit(state.loop);
            break;
        case GST_MESSAGE_ERROR: {
            GError *err = NULL;
            gchar *debug = NULL;
            gst_message_parse_error(message, &err, &debug);
            g_printerr("Error: %s (%s)\n", err->message, debug ? debug : "");
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
    for (int i = 0; i < 16; i++) state.grid_slots[i] = FALSE;
    state.loop = g_main_loop_new(NULL, FALSE);

    gint64 ts = g_get_real_time() / G_USEC_PER_SEC;

    gchar *pipeline_str = NULL;
    if (g_strcmp0(format, "fmp4") == 0 || g_strcmp0(format, "mp4") == 0) {
        g_printerr("Using MP4 Fragmented single file recording format.\n");
        pipeline_str = g_strdup_printf(
            "videotestsrc pattern=black is-live=true ! timeoverlay valignment=bottom halignment=right font-desc=\"Sans, 48\" ! video/x-raw,width=1920,height=1080,framerate=30/1 ! mix.sink_0 "
            "audiotestsrc is-live=true volume=0 ! amix.sink_0 "
            "compositor name=mix ignore-inactive-pads=true ! videoconvert ! video/x-raw,format=I420,width=1920,height=1080,framerate=30/1 ! x264enc bitrate=4000 "
            "speed-preset=ultrafast key-int-max=30 tune=zerolatency ! video/x-h264,profile=baseline ! h264parse ! tee name=h264_tee "
            "h264_tee. ! queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 leaky=2 ! rtph264pay config-interval=1 pt=96 ! tee name=vtee "
            "audiomixer name=amix ignore-inactive-pads=true ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=2 ! tee name=raw_atee "
            "raw_atee. ! queue max-size-buffers=5 max-size-bytes=0 max-size-time=0 leaky=2 ! opusenc ! rtpopuspay pt=111 ! tee name=atee "
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
            "compositor name=mix ignore-inactive-pads=true ! videoconvert ! video/x-raw,format=I420,width=1920,height=1080,framerate=30/1 ! tee name=raw_vtee "
            "raw_vtee. ! queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 leaky=2 ! x264enc bitrate=4000 speed-preset=ultrafast key-int-max=30 tune=zerolatency ! video/x-h264,profile=baseline ! h264parse ! rtph264pay config-interval=1 pt=96 ! tee name=vtee "
            "audiomixer name=amix ignore-inactive-pads=true ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=2 ! tee name=raw_atee "
            "raw_atee. ! queue max-size-buffers=5 max-size-bytes=0 max-size-time=0 leaky=2 ! opusenc ! rtpopuspay pt=111 ! tee name=atee "
            "raw_vtee. ! queue max-size-time=30000000000 max-size-bytes=0 max-size-buffers=0 leaky=2 ! x265enc bitrate=4000 speed-preset=ultrafast tune=zerolatency key-int-max=60 ! h265parse ! hlssink2.video "
            "raw_atee. ! queue max-size-time=30000000000 max-size-bytes=0 max-size-buffers=0 leaky=2 ! audioconvert ! audioresample ! audio/x-raw,rate=44100,channels=2 ! avenc_aac ! aacparse ! hlssink2.audio "
            "hlssink2 name=hlssink2 location=%s/segment_%" G_GINT64_FORMAT "_%%05d.ts playlist-location=%s/index.m3u8 target-duration=2 max-files=0 playlist-length=10",
            out_dir, ts, out_dir
        );
    } else {
        g_printerr("Using HLS segment generation format (H.264).\n");
        pipeline_str = g_strdup_printf(
            "videotestsrc pattern=black is-live=true ! timeoverlay valignment=bottom halignment=right font-desc=\"Sans, 48\" ! video/x-raw,width=1920,height=1080,framerate=30/1 ! mix.sink_0 "
            "audiotestsrc is-live=true volume=0 ! amix.sink_0 "
            "compositor name=mix ignore-inactive-pads=true ! videoconvert ! video/x-raw,format=I420,width=1920,height=1080,framerate=30/1 ! x264enc bitrate=4000 "
            "speed-preset=ultrafast key-int-max=60 tune=zerolatency ! video/x-h264,profile=baseline ! h264parse ! tee name=h264_tee "
            "h264_tee. ! queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 leaky=2 ! rtph264pay config-interval=1 pt=96 ! tee name=vtee "
            "audiomixer name=amix ignore-inactive-pads=true ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=2 ! tee name=raw_atee "
            "raw_atee. ! queue max-size-buffers=5 max-size-bytes=0 max-size-time=0 leaky=2 ! opusenc ! rtpopuspay pt=111 ! tee name=atee "
            "h264_tee. ! queue max-size-time=30000000000 max-size-bytes=0 max-size-buffers=0 leaky=2 ! hlssink2.video "
            "raw_atee. ! queue max-size-time=30000000000 max-size-bytes=0 max-size-buffers=0 leaky=2 ! audioconvert ! audioresample ! audio/x-raw,rate=44100,channels=2 ! avenc_aac ! aacparse ! hlssink2.audio "
            "hlssink2 name=hlssink2 location=%s/segment_%" G_GINT64_FORMAT "_%%05d.ts playlist-location=%s/index.m3u8 target-duration=2 max-files=0 playlist-length=10",
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

    g_printerr("DEBUG: GStreamer MCU C process started (low-latency mode)\n");
    g_main_loop_run(state.loop);

    // Cleanup
    gst_element_set_state(state.pipeline, GST_STATE_NULL);
    gst_object_unref(state.pipeline);
    if (state.compositor) gst_object_unref(state.compositor);
    if (state.audiomixer) gst_object_unref(state.audiomixer);
    if (state.video_tee) gst_object_unref(state.video_tee);
    if (state.audio_tee) gst_object_unref(state.audio_tee);
    g_hash_table_destroy(state.webrtcbins);
    g_main_loop_unref(state.loop);

    if (global_config.pem_certificate) g_free(global_config.pem_certificate);
    if (global_config.pem_key) g_free(global_config.pem_key);

    return 0;
}

