-module(room_coordinator).
-behaviour(gen_server).

%% API
-export([start_link/1, join/2, leave/2, get_state/1, start_recording/2, stop_recording/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    room_id :: binary(),
    participants = [] :: list(),
    publishers = [] :: list(),
    recording = false :: boolean(),
    recording_file = undefined :: string() | undefined
}).

%% API Functions

start_link(RoomId) ->
    gen_server:start_link(?MODULE, [RoomId], []).

join(RoomPid, Participant) ->
    gen_server:call(RoomPid, {join, Participant}).

leave(RoomPid, ParticipantId) ->
    gen_server:call(RoomPid, {leave, ParticipantId}).

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
            {ok, #state{room_id = RoomId}};
        {error, taken} ->
            {stop, already_exists}
    end.

handle_call({join, Participant}, _From, State) ->
    NewParticipants = [Participant | lists:keydelete(maps:get(id, Participant), id, State#state.participants)],
    NewState = State#state{participants = NewParticipants},
    syn:publish(State#state.room_id, {presence, join, Participant}),
    {reply, {ok, NewState}, NewState};

handle_call({leave, ParticipantId}, _From, State) ->
    NewParticipants = lists:keydelete(ParticipantId, id, State#state.participants),
    NewState = State#state{participants = NewParticipants},
    syn:publish(State#state.room_id, {presence, leave, ParticipantId}),
    {reply, {ok, NewState}, NewState};

handle_call({start_recording, LiveKitUrl}, _From, State) ->
    case State#state.recording of
        true ->
            {reply, {error, already_recording}, State};
        false ->
            % Make an in-process local call to the monitored media_broker_srv
            case media_broker_srv:start_mixing(State#state.room_id, LiveKitUrl) of
                {ok, OutFile} ->
                    NewState = State#state{recording = true, recording_file = OutFile},
                    {reply, {ok, OutFile}, NewState};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;

handle_call(stop_recording, _From, State) ->
    case State#state.recording of
        false ->
            {reply, {error, not_recording}, State};
        true ->
            ok = media_broker_srv:stop_mixing(State#state.room_id),
            NewState = State#state{recording = false, recording_file = undefined},
            {reply, ok, NewState}
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
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
