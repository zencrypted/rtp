-module(rtp_coordinator).
-behaviour(gen_server).
-compile(nowarn_deprecated_catch).
-include_lib("n2o/include/n2o.hrl").

%% API
-export([start_link/1, join/2, leave/2, get_state/1,
         ensure_started/1, post_chat/3, start_video/3, sdp_answer/3, ice_candidate/3,
         peer_left/2, terminate_room/1, active_participants/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    room_id :: binary(),
    participants = [] :: list(),
    publishers = [] :: list(),
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

start_video(RoomPid, PeerId, ClientPid) ->
    gen_server:call(RoomPid, {start_video, PeerId, ClientPid}).

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

%% gen_server Callbacks

init([RoomId]) ->
    case syn:register(rooms, RoomId, self()) of
        ok ->
            ok = rtp_store:create_room_table(RoomId),
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
    ok = rtp_store:save_message_to_room(State#state.room_id, Sender, Message, Timestamp),
    Msg = {'$msg', kvs:seq([], []), [], [], Sender, Message},
    n2o:send({topic, State#state.room_id}, #client{data = Msg}),
    {reply, ok, State};

handle_call({start_video, PeerId, ClientPid}, _From, State) ->
    {Status, StartedAt} = rtp_broker:peer_joined(rtp_broker, State#state.room_id, PeerId, ClientPid),
    {reply, {Status, StartedAt}, State};

handle_call({sdp_answer, PeerId, Sdp}, _From, State) ->
    rtp_broker:sdp_answer(rtp_broker, State#state.room_id, PeerId, Sdp),
    {reply, ok, State};

handle_call({ice_candidate, PeerId, Candidate}, _From, State) ->
    rtp_broker:ice_candidate(rtp_broker, State#state.room_id, PeerId, Candidate),
    {reply, ok, State};

handle_call({peer_left, PeerId}, _From, State) ->
    rtp_broker:peer_left(rtp_broker, State#state.room_id, PeerId),
    {reply, ok, State};

handle_call(get_started_at, _From, State) ->
    StartedAt = gen_server:call(rtp_broker, {get_started_at, State#state.room_id}),
    {reply, StartedAt, State};

handle_call(get_peers, _From, State) ->
    Peers = gen_server:call(rtp_broker, {get_peers, State#state.room_id}),
    {reply, Peers, State};

handle_call(terminate_room, _From, State) ->
    Res = rtp_broker:terminate_room(rtp_broker, State#state.room_id),
    {reply, Res, State};

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
