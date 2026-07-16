-module(room_coordinator).
-behaviour(gen_server).
-compile(nowarn_deprecated_catch).

-include_lib("n2o/include/n2o.hrl").

%% API
-export([start_link/1, join/2, leave/2, get_state/1, start_recording/2, stop_recording/1,
         ensure_started/1, post_chat/3, originate_video/3, sdp_answer/3, ice_candidate/3,
         peer_left/2, terminate_room/1, active_participants/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    room_id :: binary(),
    participants = [] :: list(),
    publishers = [] :: list(),
    recording = false :: boolean(),
    recording_file = undefined :: string() | undefined,
    media_broker = undefined :: pid() | undefined
}).

%% API Functions

start_link(RoomId) ->
    gen_server:start_link(?MODULE, [RoomId], []).

ensure_started(RoomId) ->
    RoomIdBin = case is_binary(RoomId) of
        true -> RoomId;
        false -> list_to_binary(RoomId)
    end,
    case syn:lookup(rooms, RoomIdBin) of
        {Pid, _} -> {ok, Pid};
        undefined ->
            case gen_server:start(?MODULE, [RoomIdBin], []) of
                {ok, Pid} -> {ok, Pid};
                {error, {already_started, Pid}} -> {ok, Pid};
                {error, already_exists} ->
                    case syn:lookup(rooms, RoomIdBin) of
                        {Pid, _} -> {ok, Pid};
                        undefined -> {error, failed_to_start}
                    end;
                Else -> Else
            end
    end.

active_participants(RoomPid) ->
    case gen_server:call(RoomPid, get_state) of
        {ok, State} -> State#state.participants;
        _ -> []
    end.

join(RoomPid, Participant) ->
    gen_server:call(RoomPid, {join, Participant}).

leave(RoomPid, ParticipantId) ->
    gen_server:call(RoomPid, {leave, ParticipantId}).

post_chat(RoomPid, Sender, Message) ->
    gen_server:call(RoomPid, {chat, Sender, Message}).

originate_video(RoomPid, PeerId, ClientPid) ->
    gen_server:call(RoomPid, {originate_video, PeerId, ClientPid}).

sdp_answer(RoomPid, PeerId, Sdp) ->
    gen_server:call(RoomPid, {sdp_answer, PeerId, Sdp}).

ice_candidate(RoomPid, PeerId, Candidate) ->
    gen_server:call(RoomPid, {ice_candidate, PeerId, Candidate}).

peer_left(RoomPid, PeerId) ->
    gen_server:call(RoomPid, {peer_left, PeerId}).

terminate_room(RoomPid) ->
    gen_server:call(RoomPid, terminate_room).

get_state(RoomPid) ->
    gen_server:call(RoomPid, get_state).

start_recording(RoomPid, LiveKitUrl) ->
    gen_server:call(RoomPid, {start_recording, LiveKitUrl}).

stop_recording(RoomPid) ->
    gen_server:call(RoomPid, stop_recording).

%% gen_server Callbacks

init([RoomId]) ->
    case syn:register(rooms, RoomId, self()) of
        ok ->
            ok = mnesia_srv:create_room_table(RoomId),
            {ok, #state{room_id = RoomId}};
        {error, taken} ->
            {stop, already_exists}
    end.

handle_call({join, Participant}, _From, State) ->
    CleanParticipants = [P || P <- State#state.participants, maps:get(id, P) =/= maps:get(id, Participant)],
    NewParticipants = [Participant | CleanParticipants],
    NewState = State#state{participants = NewParticipants},
    syn:publish(rooms, State#state.room_id, {presence, join, Participant}),
    {reply, {ok, NewState}, NewState};

handle_call({leave, ParticipantId}, _From, State) ->
    NewParticipants = [P || P <- State#state.participants, maps:get(id, P) =/= ParticipantId],
    NewState = State#state{participants = NewParticipants},
    syn:publish(rooms, State#state.room_id, {presence, leave, ParticipantId}),
    {reply, ok, NewState};

handle_call({chat, Sender, Message}, _From, State) ->
    Timestamp = erlang:system_time(millisecond),
    ok = mnesia_srv:save_message_to_room(State#state.room_id, Sender, Message, Timestamp),
    Msg = {'$msg', kvs:seq([], []), [], [], Sender, Message},
    n2o:send({topic, State#state.room_id}, #client{data = Msg}),
    {reply, ok, State};

handle_call({originate_video, PeerId, ClientPid}, _From, State) ->
    {NewState, BrokerPid} = case State#state.media_broker of
        undefined ->
            {ok, Pid} = media_broker_srv:start_link(),
            {State#state{media_broker = Pid}, Pid};
        Pid ->
            {State, Pid}
    end,
    {ok, StartedAt} = media_broker_srv:peer_joined(BrokerPid, State#state.room_id, PeerId, ClientPid),
    {reply, {ok, StartedAt}, NewState};

handle_call({sdp_answer, PeerId, Sdp}, _From, State) ->
    case State#state.media_broker of
        undefined -> ok;
        BrokerPid -> media_broker_srv:sdp_answer(BrokerPid, State#state.room_id, PeerId, Sdp)
    end,
    {reply, ok, State};

handle_call({ice_candidate, PeerId, Candidate}, _From, State) ->
    case State#state.media_broker of
        undefined -> ok;
        BrokerPid -> media_broker_srv:ice_candidate(BrokerPid, State#state.room_id, PeerId, Candidate)
    end,
    {reply, ok, State};

handle_call({peer_left, PeerId}, _From, State) ->
    case State#state.media_broker of
        undefined -> ok;
        BrokerPid -> media_broker_srv:peer_left(BrokerPid, State#state.room_id, PeerId)
    end,
    {reply, ok, State};

handle_call(terminate_room, _From, State) ->
    case State#state.media_broker of
        undefined ->
            {reply, {error, not_found}, State};
        BrokerPid ->
            Res = media_broker_srv:terminate_room(BrokerPid, State#state.room_id),
            catch gen_server:stop(BrokerPid),
            {reply, Res, State#state{media_broker = undefined}}
    end;

handle_call({start_recording, _LiveKitUrl}, _From, State) ->
    case State#state.recording of
        true ->
            {reply, {error, already_recording}, State};
        false ->
            case State#state.media_broker of
                undefined ->
                    {reply, {error, no_media_broker}, State};
                _BrokerPid ->
                    %% Stub: start_mixing not implemented in media_broker_srv
                    {reply, {error, not_supported}, State}
            end
    end;

handle_call(stop_recording, _From, State) ->
    case State#state.recording of
        false ->
            {reply, {error, not_recording}, State};
        true ->
            case State#state.media_broker of
                undefined ->
                    {reply, {error, no_media_broker}, State};
                _BrokerPid ->
                    %% Stub
                    {reply, ok, State#state{recording = false}}
            end
    end;

handle_call(get_state, _From, State) ->
    {reply, {ok, State}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    syn:unregister(rooms, State#state.room_id),
    case State#state.media_broker of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
