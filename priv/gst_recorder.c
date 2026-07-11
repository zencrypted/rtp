#define GST_USE_UNSTABLE_API

#include <gst/gst.h>
#include <gst/webrtc/webrtc.h>
#include <gst/sdp/sdp.h>
#include <json-glib/json-glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WIDTH 1920
#define HEIGHT 1080

typedef struct {
    GstElement *pipeline;
    GstElement *compositor;
    GstElement *audiomixer;
    GstElement *video_tee;
    GstElement *audio_tee;
    GHashTable *webrtcbins; // Maps peer_id (gchar*) -> GstElement*
    GMainLoop *loop;
    gint pad_index;
} RecorderState;

static RecorderState state;

// Prototypes
static void on_incoming_pad(GstElement *webrtc, GstPad *pad, gpointer peer_id);
static void on_ice_candidate(GstElement *webrtc, guint mline_idx, gchar *candidate, gpointer peer_id);
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

    if (g_io_channel_read_line(source, &line, &length, NULL, &error) == G_IO_STATUS_NORMAL) {
        if (line) {
            handle_signaling_message(line);
            g_free(line);
        }
    }
    if (error) {
        g_printerr("Error reading stdin: %s\n", error->message);
        g_clear_error(&error);
    }
    return TRUE;
}

// Handle offer creation callback
static void on_offer_created(GstPromise *promise, gpointer user_data) {
    gchar *peer_id = (gchar *)user_data;
    const GstStructure *reply = gst_promise_get_reply(promise);
    GstWebRTCSessionDescription *offer = NULL;
    gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, NULL);

    GstElement *webrtc = g_hash_table_lookup(state.webrtcbins, peer_id);
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
    g_print("DEBUG: Setting up webrtcbin for peer: %s\n", peer_id);
    gchar *bin_name = g_strdup_printf("webrtc_%s", peer_id);
    GstElement *webrtc = gst_element_factory_make("webrtcbin", bin_name);
    g_free(bin_name);

    if (!webrtc) {
        g_printerr("Error: Failed to create webrtcbin\n");
        return;
    }

    gst_bin_add(GST_BIN(state.pipeline), webrtc);
    gst_element_sync_state_with_parent(webrtc);
    g_hash_table_insert(state.webrtcbins, g_strdup(peer_id), webrtc);

    // Link downstream mixed video broadcast (vtee) to this peer's webrtcbin
    GstElement *v_queue = gst_element_factory_make("queue", NULL);
    gst_bin_add(GST_BIN(state.pipeline), v_queue);
    gst_element_sync_state_with_parent(v_queue);

    GstPad *vtee_src = gst_element_request_pad_simple(state.video_tee, "src_%u");
    GstPad *vqueue_sink = gst_element_get_static_pad(v_queue, "sink");
    GstPad *vqueue_src = gst_element_get_static_pad(v_queue, "src");
    GstPad *webrtc_vsink = gst_element_request_pad_simple(webrtc, "sink_%u");

    gst_pad_link(vtee_src, vqueue_sink);
    gst_pad_link(vqueue_src, webrtc_vsink);

    gst_object_unref(vtee_src);
    gst_object_unref(vqueue_sink);
    gst_object_unref(vqueue_src);
    gst_object_unref(webrtc_vsink);

    // Link downstream mixed audio broadcast (atee) to this peer's webrtcbin
    GstElement *a_queue = gst_element_factory_make("queue", NULL);
    gst_bin_add(GST_BIN(state.pipeline), a_queue);
    gst_element_sync_state_with_parent(a_queue);

    GstPad *atee_src = gst_element_request_pad_simple(state.audio_tee, "src_%u");
    GstPad *aqueue_sink = gst_element_get_static_pad(a_queue, "sink");
    GstPad *aqueue_src = gst_element_get_static_pad(a_queue, "src");
    GstPad *webrtc_asink = gst_element_request_pad_simple(webrtc, "sink_%u");

    gst_pad_link(atee_src, aqueue_sink);
    gst_pad_link(aqueue_src, webrtc_asink);

    gst_object_unref(atee_src);
    gst_object_unref(aqueue_sink);
    gst_object_unref(aqueue_src);
    gst_object_unref(webrtc_asink);

    // Connect GObject signaling handlers
    g_signal_connect(webrtc, "on-ice-candidate", G_CALLBACK(on_ice_candidate), g_strdup(peer_id));
    g_signal_connect(webrtc, "pad-added", G_CALLBACK(on_incoming_pad), g_strdup(peer_id));

    // Create SDP Offer
    GstPromise *promise = gst_promise_new_with_change_func(on_offer_created, g_strdup(peer_id), NULL);
    g_signal_emit_by_name(webrtc, "create-offer", NULL, promise);
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
        
        GstElement *webrtc = g_hash_table_lookup(state.webrtcbins, peer_id);
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

        GstElement *webrtc = g_hash_table_lookup(state.webrtcbins, peer_id);
        if (webrtc) {
            g_signal_emit_by_name(webrtc, "add-ice-candidate", mline_idx, candidate_str);
        }
    }
    g_object_unref(parser);
}

static void on_ice_candidate(GstElement *webrtc, guint mline_idx, gchar *candidate, gpointer peer_id) {
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "type");
    json_builder_add_string_value(builder, "ice_candidate");
    json_builder_set_member_name(builder, "peer_id");
    json_builder_add_string_value(builder, (gchar *)peer_id);
    
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
    GstCaps *caps = gst_pad_get_current_caps(pad);
    const GstStructure *str = gst_caps_get_structure(caps, 0);
    const gchar *name = gst_structure_get_name(str);

    if (g_str_has_prefix(name, "video")) {
        gst_caps_unref(caps);
        
        // Request compositor sink pad and lay it out in the grid
        GstPad *comp_pad = gst_element_request_pad_simple(state.compositor, "sink_%u");
        
        gint idx = state.pad_index++;
        gint w = WIDTH / 2;
        gint h = HEIGHT / 2;
        gint x = (idx % 2) * w;
        gint y = (idx / 2) * h;

        g_object_set(comp_pad, "xpos", x, "ypos", y, "width", w, "height", h, NULL);
        g_print("DEBUG: Linked video pad to compositor quadrant position (%d, %d)\n", x, y);

        GstElement *converter = gst_element_factory_make("videoconvert", NULL);
        gst_bin_add(GST_BIN(state.pipeline), converter);
        gst_element_sync_state_with_parent(converter);

        GstPad *conv_sink = gst_element_get_static_pad(converter, "sink");
        GstPad *conv_src = gst_element_get_static_pad(converter, "src");

        gst_pad_link(pad, conv_sink);
        gst_pad_link(conv_src, comp_pad);

        gst_object_unref(conv_sink);
        gst_object_unref(conv_src);
        gst_object_unref(comp_pad);

    } else if (g_str_has_prefix(name, "audio")) {
        gst_caps_unref(caps);
        g_print("DEBUG: Linking audio pad to audiomixer\n");

        GstPad *amix_pad = gst_element_request_pad_simple(state.audiomixer, "sink_%u");

        GstElement *converter = gst_element_factory_make("audioconvert", NULL);
        GstElement *resampler = gst_element_factory_make("audioresample", NULL);
        
        gst_bin_add_many(GST_BIN(state.pipeline), converter, resampler, NULL);
        gst_element_sync_state_with_parent(converter);
        gst_element_sync_state_with_parent(resampler);

        GstPad *conv_sink = gst_element_get_static_pad(converter, "sink");
        GstPad *conv_src = gst_element_get_static_pad(converter, "src");
        GstPad *res_sink = gst_element_get_static_pad(resampler, "sink");
        GstPad *res_src = gst_element_get_static_pad(resampler, "src");

        gst_pad_link(pad, conv_sink);
        gst_pad_link(conv_src, res_sink);
        gst_pad_link(res_src, amix_pad);

        gst_object_unref(conv_sink);
        gst_object_unref(conv_src);
        gst_object_unref(res_sink);
        gst_object_unref(res_src);
        gst_object_unref(amix_pad);
    } else {
        gst_caps_unref(caps);
    }
}

static void on_incoming_pad(GstElement *webrtc, GstPad *pad, gpointer peer_id) {
    if (GST_PAD_DIRECTION(pad) != GST_PAD_SRC) return;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    const GstStructure *str = gst_caps_get_structure(caps, 0);
    const gchar *name = gst_structure_get_name(str);
    gboolean is_video = g_str_has_prefix(name, "video");
    gboolean is_audio = g_str_has_prefix(name, "audio");
    gst_caps_unref(caps);

    if (!is_video && !is_audio) return;

    g_print("DEBUG: New incoming track from peer: %s\n", (gchar *)peer_id);

    // Create decodebin for track decoding
    GstElement *decodebin = gst_element_factory_make("decodebin", NULL);
    gst_bin_add(GST_BIN(state.pipeline), decodebin);
    gst_element_sync_state_with_parent(decodebin);

    GstPad *sinkpad = gst_element_get_static_pad(decodebin, "sink");
    gst_pad_link(pad, sinkpad);
    gst_object_unref(sinkpad);

    g_signal_connect(decodebin, "pad-added", G_CALLBACK(on_decoded_pad), NULL);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        g_printerr("Usage: %s <output_file>\n", argv[0]);
        return 1;
    }
    const gchar *out_file = argv[1];

    gst_init(&argc, &argv);

    state.webrtcbins = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_object_unref);
    state.pad_index = 0;
    state.loop = g_main_loop_new(NULL, FALSE);

    // Build the complete MCU mixing, recording, and broadcasting pipeline
    gchar *pipeline_str = g_strdup_printf(
        "compositor name=mix ! videoconvert ! x264enc bitrate=4000 speed-preset=ultrafast key-int-max=30 ! h264parse ! rtph264pay config-interval=1 ! tee name=vtee "
        "audiomixer name=amix ! audioconvert ! audioresample ! opusenc ! rtpopuspay ! tee name=atee "
        "vtee. ! queue ! h264parse ! mux. "
        "atee. ! queue ! opusparse ! mux. "
        "mp4mux name=mux ! filesink location=%s",
        out_file
    );
    state.pipeline = gst_parse_launch(pipeline_str, NULL);
    g_free(pipeline_str);

    if (!state.pipeline) {
        g_printerr("Error: Failed to parse GStreamer MCU pipeline\n");
        return 1;
    }

    state.compositor = gst_bin_get_by_name(GST_BIN(state.pipeline), "mix");
    state.audiomixer = gst_bin_get_by_name(GST_BIN(state.pipeline), "amix");
    state.video_tee = gst_bin_get_by_name(GST_BIN(state.pipeline), "vtee");
    state.audio_tee = gst_bin_get_by_name(GST_BIN(state.pipeline), "atee");

    gst_element_set_state(state.pipeline, GST_STATE_PLAYING);

    // Setup stdin signaling channel reader via GLib IO channels
    GIOChannel *stdin_chan = g_io_channel_unix_new(0); // 0 = stdin
    g_io_add_watch(stdin_chan, G_IO_IN | G_IO_PRI, on_stdin_message, NULL);
    g_io_channel_unref(stdin_chan);

    g_print("DEBUG: GStreamer MCU C process started\n");
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
