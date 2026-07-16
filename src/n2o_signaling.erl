-module(n2o_signaling).
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
    {ok, RoomPid} = room_coordinator:ensure_started(RoomId),
    case Token of
        undefined -> ok;
        <<>> -> ok;
        _ -> session_token:update_device(Token, PeerId)
    end,
    State = #state{
        user_id = UserId,
        room_id = RoomId,
        role = Role,
        peer_id = PeerId,
        room_pid = RoomPid
    },
    ok = syn:register(rooms, PeerId, self()),
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
                    {ok, StartedAt} = room_coordinator:originate_video(State#state.room_pid, PeerId, self()),
                    self() ! {send_room_info, StartedAt};
                _ ->
                    case Data of
                        #{<<"sdp">> := #{<<"type">> := <<"answer">>, <<"sdp">> := Sdp}} ->
                            room_coordinator:sdp_answer(State#state.room_pid, PeerId, Sdp);
                        #{<<"candidate">> := Candidate} ->
                            room_coordinator:ice_candidate(State#state.room_pid, PeerId, Candidate);
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

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, State) ->
    PeerId = State#state.peer_id,
    room_coordinator:peer_left(State#state.room_pid, PeerId),
    syn:unregister(rooms, PeerId),
    ok.
