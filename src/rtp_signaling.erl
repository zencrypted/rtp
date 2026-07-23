-module(rtp_signaling).
-behaviour('Elixir.WebSock').

-export([init/1, handle_in/2, handle_info/2, terminate/2]).

-record(state, {
    user_id :: binary(),
    room_id :: binary(),
    role :: binary(),
    peer_id :: binary(),
    room_pid :: pid()
}).

init({UserId, RoomId, Role, Token}) ->
    PeerId = <<"peer_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, RoomPid} = rtp_coordinator:ensure_started(RoomId),
    rtp_token:cleanup_user(UserId, RoomId),
    case Token of
        undefined -> ok;
        <<>> -> ok;
        _ -> rtp_token:update_device(Token, PeerId)
    end,
    State = #state{
        user_id = UserId,
        room_id = RoomId,
        role = Role,
        peer_id = PeerId,
        room_pid = RoomPid
    },
    case Role of
        <<"participant">> ->
            ok = syn:register(rooms, PeerId, self());
        _ ->
            ok  %% broadcast/viewer: not a WebRTC peer, skip syn registration
    end,
    self() ! send_init_msg,
    {ok, State}.

handle_in({Msg, Opts} = Frame, State) ->
    error_logger:info_msg("Signaling handler received frame: ~p, state=~p~n", [Frame, State]),
    Opcode = proplists:get_value(opcode, Opts, text),
    case Opcode of
        text ->
            Data = jsone:decode(Msg),
            Type = maps:get(<<"type">>, Data, <<>>),
            PeerId = State#state.peer_id,
            case Type of
                <<"ready">> ->
                    case rtp_coordinator:originate_video(State#state.room_pid, PeerId, self()) of
                        {ok, StartedAt} ->
                            self() ! {send_room_info, StartedAt};
                        {pending, _StartedAt} ->
                            ok
                    end;
                <<"get_room_info">> ->
                    StartedAt = gen_server:call(State#state.room_pid, get_started_at),
                    if StartedAt =/= undefined -> self() ! {send_room_info, StartedAt}; true -> ok end;
                <<"ping">> ->
                    ok;
                <<"get_peers">> ->
                    Peers = gen_server:call(State#state.room_pid, get_peers),
                    Payload = jsone:encode(#{<<"type">> => <<"peer_list">>, <<"peers">> => Peers}),
                    self() ! {send_payload, Payload};
                _ ->
                    case Data of
                        #{<<"sdp">> := #{<<"type">> := <<"answer">>, <<"sdp">> := Sdp}} ->
                            rtp_coordinator:sdp_answer(State#state.room_pid, PeerId, Sdp);
                        #{<<"candidate">> := Candidate} ->
                            rtp_coordinator:ice_candidate(State#state.room_pid, PeerId, Candidate);
                        _ ->
                            ok
                    end
            end;
        _ ->
            ok
    end,
    {ok, State};
handle_in(Frame, State) ->
    error_logger:info_msg("Signaling handler received fallback frame: ~p, state=~p~n", [Frame, State]),
    {ok, State}.

handle_info(send_init_msg, State) ->
    InitMsg = jsone:encode(#{
        <<"type">> => <<"init">>,
        <<"peer_id">> => State#state.peer_id
    }),
    {push, {text, InitMsg}, State};

handle_info({send_room_info, StartedAt}, State) ->
    HlsFormat = application:get_env(rtp, hls_format, fmp4),
    RoomInfoMsg = jsone:encode(#{
        <<"type">> => <<"room_info">>,
        <<"started_at">> => StartedAt,
        <<"hls_format">> => HlsFormat
    }),
    {push, {text, RoomInfoMsg}, State};

handle_info({sdp_offer, Sdp}, State) ->
    Payload = jsone:encode(#{
        <<"sdp">> => #{
            <<"type">> => <<"offer">>,
            <<"sdp">> => Sdp
        }
    }),
    {push, {text, Payload}, State};

handle_info({ice_candidate, Candidate}, State) ->
    Payload = jsone:encode(#{
        <<"candidate">> => Candidate
    }),
    {push, {text, Payload}, State};

handle_info({peer_joined, PeerId}, State) ->
    Payload = jsone:encode(#{<<"type">> => <<"peer_joined">>, <<"peer_id">> => PeerId}),
    {push, {text, Payload}, State};

handle_info({peer_left, PeerId}, State) ->
    Payload = jsone:encode(#{<<"type">> => <<"peer_left">>, <<"peer_id">> => PeerId}),
    {push, {text, Payload}, State};

handle_info(reset_webrtc, State) ->
    Payload = jsone:encode(#{<<"type">> => <<"reset_webrtc">>}),
    {push, {text, Payload}, State};

handle_info({send_payload, Payload}, State) ->
    {push, {text, Payload}, State};

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, State) ->
    PeerId = State#state.peer_id,
    case State#state.role of
        <<"participant">> ->
            rtp_coordinator:peer_left(State#state.room_pid, PeerId),
            syn:unregister(rooms, PeerId);
        _ ->
            %% Broadcast/viewer roles are not WebRTC peers — no MCU cleanup needed
            ok
    end,
    ok.
