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
    gchar *candidate;
    guint mline_idx;
} PendingIceCandidate;

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
    GstElement *v_scale;
    GstElement *v_in_queue;
    GstElement *a_convert;
    GstElement *a_resample;
    GstElement *a_in_queue;
    gint grid_idx;
    gboolean remote_desc_set;
    gboolean bundled;           /* TRUE when remote SDP uses same ICE ufrag for all mlines (BUNDLE) */
    GArray *pending_ice_candidates;
} PeerInfo;

static void free_peer_info(gpointer data) {
    PeerInfo *peer = (PeerInfo *)data;
    if (peer->pending_ice_candidates) {
        for (guint i = 0; i < peer->pending_ice_candidates->len; i++) {
            PendingIceCandidate *cand = &g_array_index(peer->pending_ice_candidates, PendingIceCandidate, i);
            g_free(cand->candidate);
        }
        g_array_free(peer->pending_ice_candidates, TRUE);
    }
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
static void add_remote_ice_candidate_impl(GstElement *webrtc, guint mline_idx, const gchar *candidate_str, gboolean bundled);

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

static void on_ice_state_change(GstElement *webrtc, GParamSpec *pspec, gpointer user_data) {
    PeerInfo *peer = (PeerInfo *)user_data;
    GstWebRTCICEConnectionState ice_state;
    g_object_get(webrtc, "ice-connection-state", &ice_state, NULL);
    g_printerr("DEBUG: GStreamer ICE connection state for %s: %d\n", peer->peer_id, ice_state);
}

static gboolean is_wsl(void);
static void add_remote_ice_candidate(GstElement *webrtc, guint mline_idx, const gchar *candidate_str);

static void on_remote_description_set(GstPromise *promise, gpointer user_data) {
    gchar *peer_id = (gchar *)user_data;
    PeerInfo *peer = g_hash_table_lookup(state.webrtcbins, peer_id);
    if (!peer || !peer->webrtc) {
        g_free(peer_id);
        return;
    }

    g_printerr("DEBUG: set-remote-description completed for peer: %s\n", peer_id);
    peer->remote_desc_set = TRUE;

    if (peer->pending_ice_candidates) {
        for (guint i = 0; i < peer->pending_ice_candidates->len; i++) {
            PendingIceCandidate *cand = &g_array_index(peer->pending_ice_candidates, PendingIceCandidate, i);
            g_printerr("DEBUG: Flushing queued remote ICE candidate for peer %s (mline %u): %s\n", peer_id, cand->mline_idx, cand->candidate);
            add_remote_ice_candidate_impl(peer->webrtc, cand->mline_idx, cand->candidate, peer->bundled);
            g_free(cand->candidate);
        }
        g_array_set_size(peer->pending_ice_candidates, 0);
    }

    g_free(peer_id);
}

// Setup webrtcbin for a newly joined peer (Both receiving upstream & broadcasting downstream)
static void setup_peer(const gchar *peer_id) {
    g_printerr("DEBUG: Setting up peer: %s\n", peer_id);

    if (g_hash_table_contains(state.webrtcbins, peer_id)) {
        g_printerr("DEBUG: Peer %s already exists, running cleanup before re-setup\n", peer_id);
        cleanup_peer(peer_id);
    }

    GstElement *webrtc = gst_element_factory_make("webrtcbin", NULL);
    if (!webrtc) {
        g_printerr("Error: Failed to create webrtcbin\n");
        return;
    }

    g_object_set(webrtc, "latency", 50,
                 "bundle-policy", GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE,
                 "stun-server", "stun://127.0.0.1:3478",
                 "turn-server", "turn://rtpuser:rtppassword@127.0.0.1:3478",
                 NULL);

    PeerInfo *peer = g_new0(PeerInfo, 1);
    peer->peer_id = g_strdup(peer_id);
    peer->webrtc = webrtc;
    peer->grid_idx = -1;
    peer->remote_desc_set = FALSE;
    peer->pending_ice_candidates = g_array_new(FALSE, FALSE, sizeof(PendingIceCandidate));

    for (int i = 0; i < 16; i++) {
        if (!state.grid_slots[i]) {
            state.grid_slots[i] = TRUE;
            peer->grid_idx = i;
            break;
        }
    }
    
    if (peer->grid_idx < 0) {
        g_printerr("Error: MCU grid is full (16 participants max)\n");
        g_free(peer->peer_id);
        g_free(peer);
        gst_object_unref(webrtc);
        return;
    }

    // Create queue and capsfilter for video branch
    GstElement *v_queue = gst_element_factory_make("queue", NULL);
    g_object_set(v_queue, "leaky", 2, "max-size-time", (guint64) 1000000000, "max-size-buffers", 0, "max-size-bytes", 0, NULL);

    GstElement *v_cf = gst_element_factory_make("capsfilter", NULL);
    GstCaps *v_caps = gst_caps_from_string("application/x-rtp, media=(string)video, clock-rate=(int)90000, encoding-name=(string)H264, payload=(int)96");
    g_object_set(v_cf, "caps", v_caps, NULL);
    gst_caps_unref(v_caps);

    // Create queue and capsfilter for audio branch
    GstElement *a_queue = gst_element_factory_make("queue", NULL);
    g_object_set(a_queue, "leaky", 2, "max-size-time", (guint64) 1000000000, "max-size-buffers", 0, "max-size-bytes", 0, NULL);

    GstElement *a_cf = gst_element_factory_make("capsfilter", NULL);
    GstCaps *a_caps = gst_caps_from_string("application/x-rtp, media=(string)audio, clock-rate=(int)48000, encoding-name=(string)OPUS, payload=(int)111");
    g_object_set(a_cf, "caps", a_caps, NULL);
    gst_caps_unref(a_caps);

    peer->v_queue = v_queue;
    peer->a_queue = a_queue;

    gst_bin_add_many(GST_BIN(state.pipeline), webrtc, v_queue, v_cf, a_queue, a_cf, NULL);

    // Link downstream mixed video broadcast (vtee) -> v_queue -> v_cf -> webrtcbin sink_0
    GstPad *vtee_src = gst_element_request_pad_simple(state.video_tee, "src_%u");
    GstPad *vqueue_sink = gst_element_get_static_pad(v_queue, "sink");
    GstPad *vqueue_src = gst_element_get_static_pad(v_queue, "src");
    GstPad *vcf_sink = gst_element_get_static_pad(v_cf, "sink");
    GstPad *vcf_src = gst_element_get_static_pad(v_cf, "src");
    GstPad *webrtc_vsink = gst_element_request_pad_simple(webrtc, "sink_0");

    gst_pad_link(vtee_src, vqueue_sink);
    gst_pad_link(vqueue_src, vcf_sink);
    gst_pad_link(vcf_src, webrtc_vsink);

    gst_object_unref(vtee_src);
    gst_object_unref(vqueue_sink);
    gst_object_unref(vqueue_src);
    gst_object_unref(vcf_sink);
    gst_object_unref(vcf_src);
    gst_object_unref(webrtc_vsink);

    // Link downstream mixed audio broadcast (atee) -> a_queue -> a_cf -> webrtcbin sink_1
    GstPad *atee_src = gst_element_request_pad_simple(state.audio_tee, "src_%u");
    GstPad *aqueue_sink = gst_element_get_static_pad(a_queue, "sink");
    GstPad *aqueue_src = gst_element_get_static_pad(a_queue, "src");
    GstPad *acf_sink = gst_element_get_static_pad(a_cf, "sink");
    GstPad *acf_src = gst_element_get_static_pad(a_cf, "src");
    GstPad *webrtc_asink = gst_element_request_pad_simple(webrtc, "sink_1");

    gst_pad_link(atee_src, aqueue_sink);
    gst_pad_link(aqueue_src, acf_sink);
    gst_pad_link(acf_src, webrtc_asink);

    gst_object_unref(atee_src);
    gst_object_unref(aqueue_sink);
    gst_object_unref(aqueue_src);
    gst_object_unref(acf_sink);
    gst_object_unref(acf_src);
    gst_object_unref(webrtc_asink);

    // Enforce SENDRECV direction on transceivers
    GArray *transceivers = NULL;
    g_signal_emit_by_name(webrtc, "get-transceivers", &transceivers);
    if (transceivers) {
        for (guint i = 0; i < transceivers->len; i++) {
            GstWebRTCRTPTransceiver *trans = g_array_index(transceivers, GstWebRTCRTPTransceiver *, i);
            g_object_set(trans, "direction", GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDRECV, NULL);
        }
        g_array_unref(transceivers);
    }

    // Sync state after elements are added and linked
    gst_element_sync_state_with_parent(v_queue);
    gst_element_sync_state_with_parent(v_cf);
    gst_element_sync_state_with_parent(a_queue);
    gst_element_sync_state_with_parent(a_cf);
    gst_element_sync_state_with_parent(webrtc);

    g_hash_table_insert(state.webrtcbins, g_strdup(peer_id), peer);

    // Connect GObject signaling handlers
    g_signal_connect(webrtc, "on-ice-candidate", G_CALLBACK(on_ice_candidate), peer);
    g_signal_connect(webrtc, "pad-added", G_CALLBACK(on_incoming_pad), peer);
    g_signal_connect(webrtc, "notify::ice-connection-state", G_CALLBACK(on_ice_state_change), peer);

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
    if (peer->v_scale) {
        gst_element_set_state(peer->v_scale, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->v_scale);
    }
    if (peer->v_convert) {
        gst_element_set_state(peer->v_convert, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->v_convert);
    }
    if (peer->v_in_queue) {
        gst_element_set_state(peer->v_in_queue, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->v_in_queue);
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
    if (peer->a_in_queue) {
        gst_element_set_state(peer->a_in_queue, GST_STATE_NULL);
        gst_bin_remove(GST_BIN(state.pipeline), peer->a_in_queue);
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
            g_printerr("DEBUG: Received SDP answer for peer %s\n", peer_id);
            GstSDPMessage *sdp = NULL;
            gst_sdp_message_new(&sdp);
            gst_sdp_message_parse_buffer((const guint8 *)sdp_text, strlen(sdp_text), sdp);

            /* Detect true BUNDLE: check if all mlines share the same ICE ufrag */
            gboolean is_bundled = FALSE;
            guint nmedia = gst_sdp_message_medias_len(sdp);
            if (nmedia >= 2) {
                const GstSDPMedia *m0 = gst_sdp_message_get_media(sdp, 0);
                const GstSDPMedia *m1 = gst_sdp_message_get_media(sdp, 1);
                const gchar *ufrag0 = gst_sdp_media_get_attribute_val(m0, "ice-ufrag");
                const gchar *ufrag1 = gst_sdp_media_get_attribute_val(m1, "ice-ufrag");
                /* Also check mline 1 port is not 0 (rejected) */
                guint port1 = gst_sdp_media_get_port(m1);
                if (ufrag0 && ufrag1 && g_strcmp0(ufrag0, ufrag1) == 0 && port1 != 0) {
                    is_bundled = TRUE;
                }
            }
            peer->bundled = is_bundled;
            g_printerr("DEBUG: SDP answer for peer %s: nmedia=%u, BUNDLE=%s\n",
                       peer_id, nmedia, is_bundled ? "yes" : "no");

            GstWebRTCSessionDescription *answer = gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, sdp);

            GstPromise *promise = gst_promise_new_with_change_func(on_remote_description_set, g_strdup(peer_id), NULL);
            g_signal_emit_by_name(webrtc, "set-remote-description", answer, promise);
            gst_webrtc_session_description_free(answer);
        }
    } else if (g_strcmp0(type, "ice_candidate") == 0) {
        const gchar *peer_id = json_object_get_string_member(root, "peer_id");
        JsonObject *candidate_obj = json_object_get_object_member(root, "candidate");
        gint mline_idx = json_object_get_int_member(candidate_obj, "sdpMLineIndex");
        const gchar *candidate_str = json_object_get_string_member(candidate_obj, "candidate");

        PeerInfo *peer = g_hash_table_lookup(state.webrtcbins, peer_id);
        GstElement *webrtc = peer ? peer->webrtc : NULL;
        if (peer && webrtc) {
            if (peer->remote_desc_set) {
                g_printerr("DEBUG: Adding remote ICE candidate for peer %s (mline %d): %s\n", peer_id, mline_idx, candidate_str);
                add_remote_ice_candidate_impl(webrtc, (guint)mline_idx, candidate_str, peer->bundled);
            } else {
                g_printerr("DEBUG: Queueing remote ICE candidate for peer %s (mline %d) until remote description is set\n", peer_id, mline_idx);
                PendingIceCandidate pending = { g_strdup(candidate_str), (guint)mline_idx };
                g_array_append_val(peer->pending_ice_candidates, pending);
            }
        }
    } else if (g_strcmp0(type, "peer_left") == 0) {
        const gchar *peer_id = json_object_get_string_member(root, "peer_id");
        cleanup_peer(peer_id);
    } else if (g_strcmp0(type, "exit") == 0) {
        g_printerr("DEBUG: Received exit request via stdin IPC, sending EOS to sinks...\n");
        GstElement *hlssink = gst_bin_get_by_name(GST_BIN(state.pipeline), "hlssink2");
        if (hlssink) {
            gst_element_send_event(hlssink, gst_event_new_eos());
            gst_object_unref(hlssink);
        }
        GstElement *mux = gst_bin_get_by_name(GST_BIN(state.pipeline), "mux");
        if (mux) {
            gst_element_send_event(mux, gst_event_new_eos());
            gst_object_unref(mux);
        }
    }
    g_object_unref(parser);
}

static gboolean is_wsl(void) {
    static gint in_wsl = -1;
    if (in_wsl != -1) return (gboolean)in_wsl;

    if (getenv("WSL_DISTRO_NAME") != NULL || getenv("WSL_INTEROP") != NULL) {
        in_wsl = 1;
        return TRUE;
    }

    FILE *f = fopen("/proc/sys/kernel/osrelease", "r");
    if (f) {
        char buf[256] = {0};
        if (fgets(buf, sizeof(buf), f)) {
            if (strstr(buf, "WSL") || strstr(buf, "microsoft") || strstr(buf, "Microsoft")) {
                fclose(f);
                in_wsl = 1;
                return TRUE;
            }
        }
        fclose(f);
    }

    in_wsl = 0;
    return FALSE;
}

static gchar *replace_wsl_ip(const gchar *candidate) {
    if (!candidate) return NULL;
    if (!is_wsl()) return g_strdup(candidate);

    const gchar *p = strstr(candidate, " 172.");
    if (!p) return g_strdup(candidate);

    const gchar *p_end = strchr(p + 1, ' ');
    if (!p_end) return g_strdup(candidate);

    GString *res = g_string_new_len(candidate, p - candidate);
    g_string_append(res, " 127.0.0.1");
    g_string_append(res, p_end);
    return g_string_free(res, FALSE);
}

static const gchar *get_wsl_gateway_ip(void) {
    static gchar gw_ip[64] = {0};
    if (gw_ip[0] != '\0') return gw_ip;

    FILE *f = popen("ip route show default 2>/dev/null", "r");
    if (f) {
        char buf[256] = {0};
        if (fgets(buf, sizeof(buf), f)) {
            char *p = strstr(buf, "via ");
            if (p) {
                p += 4;
                char *end = strchr(p, ' ');
                if (end) *end = '\0';
                g_strlcpy(gw_ip, p, sizeof(gw_ip));
            }
        }
        pclose(f);
    }
    if (gw_ip[0] == '\0') {
        g_strlcpy(gw_ip, "172.30.7.1", sizeof(gw_ip));
    }
    return gw_ip;
}

static void add_remote_ice_candidate_impl(GstElement *webrtc, guint mline_idx,
                                          const gchar *candidate_str, gboolean bundled) {
    if (!webrtc || !candidate_str) return;

    /* Always add to the declared mline */
    g_signal_emit_by_name(webrtc, "add-ice-candidate", mline_idx, candidate_str);
    /* Only mirror to the other mline when BUNDLE is confirmed (same ICE ufrag) */
    if (bundled) {
        g_signal_emit_by_name(webrtc, "add-ice-candidate", (mline_idx == 0 ? 1 : 0), candidate_str);
    }

    if (is_wsl()) {
        gchar *dup_cand_127 = replace_wsl_ip(candidate_str);
        if (dup_cand_127 && g_strcmp0(dup_cand_127, candidate_str) != 0) {
            g_printerr("DEBUG: WSL2 synthesized 127.0.0.1 remote candidate: %s\n", dup_cand_127);
            g_signal_emit_by_name(webrtc, "add-ice-candidate", mline_idx, dup_cand_127);
            if (bundled) {
                g_signal_emit_by_name(webrtc, "add-ice-candidate", (mline_idx == 0 ? 1 : 0), dup_cand_127);
            }
            g_free(dup_cand_127);
        } else if (dup_cand_127) {
            g_free(dup_cand_127);
        }

        const gchar *gw = get_wsl_gateway_ip();
        const gchar *p = strstr(candidate_str, " 172.");
        if (p && gw && gw[0] != '\0') {
            const gchar *p_end = strchr(p + 1, ' ');
            if (p_end) {
                GString *res = g_string_new_len(candidate_str, p - candidate_str);
                g_string_append_c(res, ' ');
                g_string_append(res, gw);
                g_string_append(res, p_end);
                if (g_strcmp0(res->str, candidate_str) != 0) {
                    g_printerr("DEBUG: WSL2 synthesized gateway (%s) remote candidate: %s\n", gw, res->str);
                    g_signal_emit_by_name(webrtc, "add-ice-candidate", mline_idx, res->str);
                }
                g_string_free(res, TRUE);
            }
        }
    }
}

static void add_remote_ice_candidate(GstElement *webrtc, guint mline_idx, const gchar *candidate_str) {
    add_remote_ice_candidate_impl(webrtc, mline_idx, candidate_str, TRUE);
}

static void on_ice_candidate(GstElement *webrtc, guint mline_idx, gchar *candidate, gpointer user_data) {
    PeerInfo *peer = (PeerInfo *)user_data;
    gchar *fixed_candidate = replace_wsl_ip(candidate);
    g_printerr("DEBUG: GStreamer emitted local ICE candidate for peer %s (mline %u): %s\n", peer->peer_id, mline_idx, fixed_candidate ? fixed_candidate : candidate);
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
    json_builder_set_member_name(builder, "sdpMid");
    json_builder_add_string_value(builder, mline_idx == 0 ? "video0" : "audio1");
    json_builder_set_member_name(builder, "candidate");
    json_builder_add_string_value(builder, fixed_candidate ? fixed_candidate : candidate);
    json_builder_end_object(builder);

    json_builder_end_object(builder);

    JsonNode *root = json_builder_get_root(builder);
    send_to_erlang(root);

    json_node_free(root);
    g_object_unref(builder);
    if (fixed_candidate) g_free(fixed_candidate);
}

// Link decoded raw pads into audio and video mixers
static void on_decoded_pad(GstElement *decodebin, GstPad *pad, gpointer user_data) {
    PeerInfo *peer = (PeerInfo *)user_data;
    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) {
        caps = gst_pad_query_caps(pad, NULL);
    }
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
        GstElement *scaler = gst_element_factory_make("videoscale", NULL);
        GstElement *in_queue = gst_element_factory_make("queue", NULL);
        g_object_set(in_queue, "leaky", 2, "max-size-buffers", 5, "max-size-bytes", 0, "max-size-time", (guint64) 0, NULL);

        peer->v_convert = converter;
        peer->v_scale = scaler;
        peer->v_in_queue = in_queue;
        gst_bin_add_many(GST_BIN(state.pipeline), converter, scaler, in_queue, NULL);

        GstPad *conv_sink = gst_element_get_static_pad(converter, "sink");
        GstPad *conv_src = gst_element_get_static_pad(converter, "src");
        GstPad *scale_sink = gst_element_get_static_pad(scaler, "sink");
        GstPad *scale_src = gst_element_get_static_pad(scaler, "src");
        GstPad *q_sink = gst_element_get_static_pad(in_queue, "sink");
        GstPad *q_src = gst_element_get_static_pad(in_queue, "src");

        GstPadLinkReturn ret1 = gst_pad_link(pad, conv_sink);
        GstPadLinkReturn ret2 = gst_pad_link(conv_src, scale_sink);
        GstPadLinkReturn ret3 = gst_pad_link(scale_src, q_sink);
        GstPadLinkReturn ret4 = gst_pad_link(q_src, comp_pad);
        g_printerr("DEBUG: video gst_pad_link results: pad->conv_sink=%d, conv_src->scale_sink=%d, scale_src->q_sink=%d, q_src->comp_pad=%d\n", ret1, ret2, ret3, ret4);

        gst_element_sync_state_with_parent(converter);
        gst_element_sync_state_with_parent(scaler);
        gst_element_sync_state_with_parent(in_queue);

        gst_object_unref(conv_sink);
        gst_object_unref(conv_src);
        gst_object_unref(scale_sink);
        gst_object_unref(scale_src);
        gst_object_unref(q_sink);
        gst_object_unref(q_src);

    } else if (g_str_has_prefix(name, "audio")) {
        gst_caps_unref(caps);
        g_printerr("DEBUG: Linking audio pad to audiomixer for peer: %s\n", peer->peer_id);

        GstPad *amix_pad = gst_element_request_pad_simple(state.audiomixer, "sink_%u");
        peer->amix_pad = amix_pad; // Keep ownership reference for cleanup

        GstElement *converter = gst_element_factory_make("audioconvert", NULL);
        GstElement *resampler = gst_element_factory_make("audioresample", NULL);
        GstElement *in_queue = gst_element_factory_make("queue", NULL);
        g_object_set(in_queue, "leaky", 2, "max-size-buffers", 5, "max-size-bytes", 0, "max-size-time", (guint64) 0, NULL);

        peer->a_convert = converter;
        peer->a_resample = resampler;
        peer->a_in_queue = in_queue;

        gst_bin_add_many(GST_BIN(state.pipeline), converter, resampler, in_queue, NULL);

        GstPad *conv_sink = gst_element_get_static_pad(converter, "sink");
        GstPad *conv_src = gst_element_get_static_pad(converter, "src");
        GstPad *res_sink = gst_element_get_static_pad(resampler, "sink");
        GstPad *res_src = gst_element_get_static_pad(resampler, "src");
        GstPad *q_sink = gst_element_get_static_pad(in_queue, "sink");
        GstPad *q_src = gst_element_get_static_pad(in_queue, "src");

        gst_pad_link(pad, conv_sink);
        gst_pad_link(conv_src, res_sink);
        gst_pad_link(res_src, q_sink);
        gst_pad_link(q_src, amix_pad);

        gst_element_sync_state_with_parent(converter);
        gst_element_sync_state_with_parent(resampler);
        gst_element_sync_state_with_parent(in_queue);

        gst_object_unref(conv_sink);
        gst_object_unref(conv_src);
        gst_object_unref(res_sink);
        gst_object_unref(res_src);
        gst_object_unref(q_sink);
        gst_object_unref(q_src);
    } else {
        gst_caps_unref(caps);
    }
}

static void on_incoming_pad(GstElement *webrtc, GstPad *pad, gpointer user_data) {
    PeerInfo *peer = (PeerInfo *)user_data;
    if (GST_PAD_DIRECTION(pad) != GST_PAD_SRC) return;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) {
        caps = gst_pad_query_caps(pad, NULL);
    }
    
    gboolean is_video = FALSE;
    gboolean is_audio = FALSE;

    if (caps) {
        if (gst_caps_get_size(caps) > 0) {
            const GstStructure *str = gst_caps_get_structure(caps, 0);
            const gchar *media = gst_structure_get_string(str, "media");
            if (media) {
                is_video = (g_strcmp0(media, "video") == 0);
                is_audio = (g_strcmp0(media, "audio") == 0);
            } else {
                const gchar *name = gst_structure_get_name(str);
                if (name && g_str_has_prefix(name, "video")) is_video = TRUE;
                else if (name && g_str_has_prefix(name, "audio")) is_audio = TRUE;
            }
        }
        gst_caps_unref(caps);
    }

    if (!is_video && !is_audio) {
        gchar *pname = gst_pad_get_name(pad);
        if (pname) {
            if (g_str_has_prefix(pname, "src_0") || strstr(pname, "video")) is_video = TRUE;
            else if (g_str_has_prefix(pname, "src_1") || strstr(pname, "audio")) is_audio = TRUE;
            g_free(pname);
        }
    }

    if (!is_video && !is_audio) {
        g_printerr("DEBUG: Could not determine media type for incoming pad from peer: %s\n", peer->peer_id);
        return;
    }

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
    g_printerr("DEBUG: Caught signal %d via GLib, sending EOS to sinks...\n", sig);
    GstElement *hlssink = gst_bin_get_by_name(GST_BIN(state.pipeline), "hlssink2");
    if (hlssink) {
        gst_element_send_event(hlssink, gst_event_new_eos());
        gst_object_unref(hlssink);
    }
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
            "raw_vtee. ! queue max-size-buffers=1000 max-size-bytes=0 max-size-time=0 ! x265enc bitrate=4000 speed-preset=ultrafast tune=zerolatency key-int-max=30 ! h265parse ! hlssink2.video "
            "raw_atee. ! queue max-size-buffers=1000 max-size-bytes=0 max-size-time=0 ! audioconvert ! audioresample ! audio/x-raw,rate=44100,channels=2 ! avenc_aac ! aacparse ! hlssink2.audio "
            "hlssink2 name=hlssink2 location=%s/segment_%" G_GINT64_FORMAT "_%%05d.ts playlist-location=%s/index.m3u8 playlist-root=\"\" target-duration=2 max-files=0 playlist-length=10",
            out_dir, ts, out_dir
        );
    } else {
        g_printerr("Using HLS segment generation format (H.264).\n");
        pipeline_str = g_strdup_printf(
            "videotestsrc pattern=black is-live=true ! timeoverlay valignment=bottom halignment=right font-desc=\"Sans, 48\" ! video/x-raw,width=1920,height=1080,framerate=30/1 ! mix.sink_0 "
            "audiotestsrc is-live=true volume=0 ! amix.sink_0 "
            "compositor name=mix ignore-inactive-pads=true ! videoconvert ! video/x-raw,format=I420,width=1920,height=1080,framerate=30/1 ! x264enc bitrate=4000 "
            "speed-preset=ultrafast key-int-max=30 tune=zerolatency ! video/x-h264,profile=baseline ! h264parse ! tee name=h264_tee "
            "h264_tee. ! queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 leaky=1 ! rtph264pay config-interval=1 pt=96 ! tee name=vtee "
            "audiomixer name=amix ignore-inactive-pads=true ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=2 ! tee name=raw_atee "
            "raw_atee. ! queue max-size-buffers=5 max-size-bytes=0 max-size-time=0 leaky=1 ! opusenc ! rtpopuspay pt=111 ! tee name=atee "
            "h264_tee. ! queue max-size-buffers=1000 max-size-bytes=0 max-size-time=0 ! hlssink2.video "
            "raw_atee. ! queue max-size-buffers=1000 max-size-bytes=0 max-size-time=0 ! audioconvert ! audioresample ! audio/x-raw,rate=44100,channels=2 ! avenc_aac ! aacparse ! hlssink2.audio "
            "hlssink2 name=hlssink2 location=%s/segment_%" G_GINT64_FORMAT "_%%05d.ts playlist-location=%s/index.m3u8 playlist-root=\"\" target-duration=2 max-files=0 playlist-length=10",
            out_dir, ts, out_dir
        );
    }
    
    GError *error = NULL;
    state.pipeline = gst_parse_launch(pipeline_str, &error);
    g_free(pipeline_str);

    if (!state.pipeline) {
        g_printerr("Error: Failed to parse GStreamer MCU pipeline: %s\n", error ? error->message : "unknown");
        if (error) g_error_free(error);
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
