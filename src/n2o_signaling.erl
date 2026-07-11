-module(n2o_signaling).
-behaviour('Elixir.WebSock').

-export([init/1, handle_in/2, handle_info/2, terminate/2]).

-record(state, {
    user_id :: binary(),
    room_id :: binary(),
    role :: binary()
}).

init({UserId, RoomId, Role}) ->
    State = #state{user_id = UserId, room_id = RoomId, role = Role},
    ok = syn:join(RoomId, self()),
    
    {ok, RoomPid} = case syn:lookup(rooms, RoomId) of
        undefined ->
            {ok, Pid} = room_coordinator:start_link(RoomId),
            {ok, Pid};
        {Pid, _} ->
            {ok, Pid}
    end,

    ok = room_coordinator:join(RoomPid, #{
        id => UserId,
        role => Role,
        pid => self()
    }),

    {ok, State}.

handle_in({text, Msg}, State) ->
    Data = jsone:decode(Msg),
    Type = maps:get(<<"type">>, Data),
    
    case Type of
        <<"chat_message">> ->
            BroadcastMsg = #{
                type => <<"chat">>,
                from => State#state.user_id,
                text => maps:get(<<"text">>, Data)
            },
            syn:publish(State#state.room_id, {broadcast, jsone:encode(BroadcastMsg)});
        
        <<"webrtc_signal">> ->
            TargetUserId = maps:get(<<"target_user_id">>, Data),
            SignalData = maps:get(<<"signal">>, Data),
            syn:publish(State#state.room_id, {signal_peer, TargetUserId, State#state.user_id, SignalData})
    end,
    {ok, State};

handle_in(_Frame, State) ->
    {ok, State}.

handle_info({broadcast, JsonMessage}, State) ->
    {push, {text, JsonMessage}, State};

handle_info({signal_peer, TargetUserId, SourceUserId, SignalData}, State) ->
    case State#state.user_id of
        TargetUserId ->
            Payload = jsone:encode(#{
                type => <<"signal">>,
                from => SourceUserId,
                signal => SignalData
            }),
            {push, {text, Payload}, State};
        _ ->
            {ok, State}
    end;

handle_info({presence, join, Participant}, State) ->
    Payload = jsone:encode(#{
        type => <<"presence">>,
        action => <<"join">>,
        user => Participant
    }),
    {push, {text, Payload}, State};

handle_info({presence, leave, ParticipantId}, State) ->
    Payload = jsone:encode(#{
        type => <<"presence">>,
        action => <<"leave">>,
        user_id => ParticipantId
    }),
    {push, {text, Payload}, State};

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
