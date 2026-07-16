-module(n2o_signaling).
-behaviour('Elixir.WebSock').

-export([init/1, handle_in/2, handle_info/2, terminate/2]).

-record(state, {
    user_id :: binary(),
    room_id :: binary(),
    role :: binary(),
    peer_id :: binary()
}).

init({UserId, RoomId, Role}) ->
    PeerId = <<"peer_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    State = #state{
        user_id = UserId,
        room_id = RoomId,
        role = Role,
        peer_id = PeerId
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
            RoomId = State#state.room_id,
            case Type of
                <<"ready">> ->
                    media_broker_srv:peer_joined(RoomId, PeerId, self());
                _ ->
                    case Data of
                        #{<<"sdp">> := #{<<"type">> := <<"answer">>, <<"sdp">> := Sdp}} ->
                            media_broker_srv:sdp_answer(RoomId, PeerId, Sdp);
                        #{<<"candidate">> := Candidate} ->
                            media_broker_srv:ice_candidate(RoomId, PeerId, Candidate);
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
    RoomId = State#state.room_id,
    media_broker_srv:peer_left(RoomId, PeerId),
    syn:unregister(rooms, PeerId),
    ok.
