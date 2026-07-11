-module(n2o_signaling).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

-record(state, {
    user_id :: binary(),
    room_id :: binary(),
    role :: binary()
}).

init(Req, State) ->
    Headers = cowboy_req:headers(Req),
    ClientCertDN = maps:get(<<"x-ssl-client-s-dn">>, Headers, <<>>),
    ClientCertSAN = maps:get(<<"x-ssl-client-san">>, Headers, <<>>),

    case auth_translation:verify_client_cert(ClientCertDN, ClientCertSAN) of
        {ok, UserId, RoomId, Role} ->
            {cowboy_websocket, Req, #state{user_id = UserId, room_id = RoomId, role = Role}};
        {error, unauthorized} ->
            Req2 = cowboy_req:reply(401, #{<<"content-type">> => <<"text/plain">>}, <<"Unauthorized Certificate">>, Req),
            {ok, Req2, State}
    end.

websocket_init(State) ->
    RoomId = State#state.room_id,
    ok = syn:join(RoomId, self()),
    
    {ok, RoomPid} = case syn:lookup(rooms, RoomId) of
        undefined ->
            {ok, Pid} = room_coordinator:start_link(RoomId),
            {ok, Pid};
        {Pid, _} ->
            {ok, Pid}
    end,

    ok = room_coordinator:join(RoomPid, #{
        id => State#state.user_id,
        role => State#state.role,
        pid => self()
    }),

    {ok, State}.

websocket_handle({text, Msg}, State) ->
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

websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info({broadcast, JsonMessage}, State) ->
    {reply, {text, JsonMessage}, State};

websocket_info({signal_peer, TargetUserId, SourceUserId, SignalData}, State) ->
    case State#state.user_id of
        TargetUserId ->
            Payload = jsone:encode(#{
                type => <<"signal">>,
                from => SourceUserId,
                signal => SignalData
            }),
            {reply, {text, Payload}, State};
        _ ->
            {ok, State}
    end;

websocket_info({presence, join, Participant}, State) ->
    Payload = jsone:encode(#{
        type => <<"presence">>,
        action => <<"join">>,
        user => Participant
    }),
    {reply, {text, Payload}, State};

websocket_info({presence, leave, ParticipantId}, State) ->
    Payload = jsone:encode(#{
        type => <<"presence">>,
        action => <<"leave">>,
        user_id => ParticipantId
    }),
    {reply, {text, Payload}, State};

websocket_info(_Info, State) ->
    {ok, State}.
