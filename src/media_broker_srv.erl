-module(media_broker_srv).
-behaviour(gen_server).
-compile(nowarn_deprecated_catch).
-include_lib("n2o/include/n2o.hrl").

%% API
-export([start_link/0, peer_joined/4, sdp_answer/4, ice_candidate/4, peer_left/3, terminate_room/2, recording_path/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    ports = #{},       % RoomId :: binary() -> Port :: port()
    room_peers = #{},  % RoomId :: binary() -> [PeerId :: binary()]
    peer_rooms = #{},   % PeerId :: binary() -> RoomId :: binary()
    room_started_at = #{}, % RoomId :: binary() -> Timestamp :: integer()
    monitors = #{}     % MonitorRef :: reference() -> {RoomId, PeerId}
}).

%% API Functions

start_link() ->
    gen_server:start_link(?MODULE, [], []).

peer_joined(BrokerPid, RoomId, PeerId, ClientPid) ->
    gen_server:call(BrokerPid, {peer_joined, RoomId, PeerId, ClientPid}).

sdp_answer(BrokerPid, RoomId, PeerId, Sdp) ->
    gen_server:cast(BrokerPid, {sdp_answer, RoomId, PeerId, Sdp}).

ice_candidate(BrokerPid, RoomId, PeerId, Candidate) ->
    gen_server:cast(BrokerPid, {ice_candidate, RoomId, PeerId, Candidate}).

peer_left(BrokerPid, RoomId, PeerId) ->
    gen_server:cast(BrokerPid, {peer_left, RoomId, PeerId}).

terminate_room(BrokerPid, RoomId) ->
    gen_server:call(BrokerPid, {terminate_room, RoomId}).

recording_path(RoomId) ->
    case RoomId of
        <<"court-room-room123">> -> filename:absname("priv/static/rooms/court-room-room123/index.m3u8");
        _ -> filename:absname("priv/static/rooms/" ++ binary_to_list(RoomId) ++ "/index.m3u8")
    end.

%% gen_server Callbacks

init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call({get_started_at, RoomId}, _From, State) ->
    StartedAt = maps:get(RoomId, State#state.room_started_at, undefined),
    {reply, StartedAt, State};

handle_call({get_peers, RoomId}, _From, State) ->
    Peers = maps:get(RoomId, State#state.room_peers, []),
    {reply, Peers, State};

handle_call({peer_joined, RoomId, PeerId, ClientPid}, _From, State) ->
    {Port, NewPorts, StartedAt, NewStartedAt} = case maps:find(RoomId, State#state.ports) of
        {ok, P} ->
            {P, State#state.ports, maps:get(RoomId, State#state.room_started_at), State#state.room_started_at};
        error ->
            Now = erlang:system_time(millisecond),
            Binary = filename:absname(find_binary()),
            OutDir = case RoomId of
                <<"court-room-room123">> -> filename:absname("priv/static/rooms/court-room-room123");
                _ -> filename:absname("priv/static/rooms/" ++ binary_to_list(RoomId))
            end,
            filelib:ensure_dir(OutDir ++ "/"),
            os:cmd("rm -f " ++ OutDir ++ "/*"),
            error_logger:info_msg("Spawning GStreamer mixer for room ~s writing to ~s~n", [RoomId, OutDir]),
            HlsFormat = application:get_env(rtp, hls_format, fmp4),
            FormatStr = atom_to_list(HlsFormat),
            Args = [OutDir, FormatStr],
            error_logger:info_msg("Starting GStreamer MCU: ~p ~p~n", [Binary, Args]),
            P = open_port({spawn_executable, Binary}, [
                binary,
                stream,
                {args, Args},
                use_stdio,
                stderr_to_stdout,
                exit_status,
                {line, 16384},
                {env, [
                    {"GST_GL_WINDOW", "none"},
                    {"GST_PLUGIN_FEATURE_FILTER", "opengl:0,applemedia:0"}
                ]}
            ]),
            {P, maps:put(RoomId, P, State#state.ports), Now, maps:put(RoomId, Now, State#state.room_started_at)}
    end,
    
    send_to_port(Port, #{
        <<"type">> => <<"peer_joined">>,
        <<"peer_id">> => PeerId
    }),
    
    Ref = monitor(process, ClientPid),
    NewMonitors = maps:put(Ref, {RoomId, PeerId}, State#state.monitors),
    
    Peers = maps:get(RoomId, State#state.room_peers, []),
    NewRoomPeers = maps:put(RoomId, [PeerId | Peers], State#state.room_peers),
    NewPeerRooms = maps:put(PeerId, RoomId, State#state.peer_rooms),
    
    lists:foreach(fun(PidPeer) ->
        case syn:lookup(rooms, PidPeer) of
            {Pid, _} -> Pid ! {peer_joined, PeerId};
            undefined -> ok
        end
    end, Peers),
    
    PlaylistPath = recording_path(RoomId),
    Status = case filelib:is_regular(PlaylistPath) of
        true -> ok;
        false -> pending
    end,
    
    {reply, {Status, StartedAt}, State#state{
        ports = NewPorts,
        room_peers = NewRoomPeers,
        peer_rooms = NewPeerRooms,
        room_started_at = NewStartedAt,
        monitors = NewMonitors
    }};

handle_call({terminate_room, RoomId}, _From, State) ->
    case maps:find(RoomId, State#state.ports) of
        {ok, Port} ->
            error_logger:info_msg("Terminating GStreamer for room ~s, finalizing mp4~n", [RoomId]),
            send_to_port(Port, #{<<"type">> => <<"exit">>}),
            {reply, {ok, recording_path(RoomId)}, State};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({sdp_answer, RoomId, PeerId, Sdp}, State) ->
    case maps:find(RoomId, State#state.ports) of
        {ok, Port} ->
            send_to_port(Port, #{
                <<"type">> => <<"sdp_answer">>,
                <<"peer_id">> => PeerId,
                <<"sdp">> => Sdp
            });
        error ->
            ok
    end,
    {noreply, State};

handle_cast({ice_candidate, RoomId, PeerId, Candidate}, State) ->
    case maps:find(RoomId, State#state.ports) of
        {ok, Port} ->
            send_to_port(Port, #{
                <<"type">> => <<"ice_candidate">>,
                <<"peer_id">> => PeerId,
                <<"candidate">> => Candidate
            });
        error ->
            ok
    end,
    {noreply, State};

handle_cast({peer_left, RoomId, PeerId}, State) ->
    State1 = handle_peer_departure(RoomId, PeerId, State),
    {noreply, State1};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {data, {eol, LineBin}}}, State) ->
    case catch jsone:decode(LineBin) of
        #{<<"type">> := <<"sdp_offer">>, <<"peer_id">> := PeerId, <<"sdp">> := Sdp} ->
            case syn:lookup(rooms, PeerId) of
                {Pid, _} -> Pid ! {sdp_offer, Sdp};
                undefined -> ok
            end,
            {noreply, State};
        #{<<"type">> := <<"ice_candidate">>, <<"peer_id">> := PeerId, <<"candidate">> := Candidate} ->
            case syn:lookup(rooms, PeerId) of
                {Pid, _} -> Pid ! {ice_candidate, Candidate};
                undefined -> ok
            end,
            {noreply, State};
        #{<<"type">> := <<"recording_started">>} ->
            RoomId = find_room_by_port(Port, State#state.ports),
            case RoomId of
                undefined -> {noreply, State};
                _ ->
                    RealStart = erlang:system_time(millisecond),
                    self() ! {poll_manifest, RoomId, RealStart, 0},
                    NewStartedAt = maps:put(RoomId, RealStart, State#state.room_started_at),
                    {noreply, State#state{room_started_at = NewStartedAt}}
            end;
        _Other ->
            error_logger:info_msg("GStreamer Output (~p): ~s~n", [self(), LineBin]),
            {noreply, State}
    end;

handle_info({Port, {exit_status, Status}}, State) ->
    error_logger:info_msg("GStreamer port ~p exited with status ~p~n", [Port, Status]),
    RoomId = find_room_by_port(Port, State#state.ports),
    case RoomId of
        undefined ->
            {noreply, State};
        _ ->
            NewPorts = maps:remove(RoomId, State#state.ports),
            Peers = maps:get(RoomId, State#state.room_peers, []),
            NewPeerRooms = lists:foldl(fun(P, M) -> maps:remove(P, M) end, State#state.peer_rooms, Peers),
            NewRoomPeers = maps:remove(RoomId, State#state.room_peers),
            {noreply, State#state{
                ports = NewPorts,
                room_peers = NewRoomPeers,
                peer_rooms = NewPeerRooms
            }}
    end;

handle_info({'EXIT', From, Reason}, State) ->
    case is_port(From) of
        true ->
            {noreply, State};
        false ->
            error_logger:info_msg("media_broker_srv parent exited: ~p (~p). Terminating.~n", [From, Reason]),
            {stop, Reason, State}
    end;

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    case maps:find(Ref, State#state.monitors) of
        {ok, {RoomId, PeerId}} ->
            NewMonitors = maps:remove(Ref, State#state.monitors),
            Peers = maps:get(RoomId, State#state.room_peers, []),
            case lists:member(PeerId, Peers) of
                true ->
                    error_logger:info_msg("media_broker_srv: Peer ~s process died. Cleaning up.~n", [PeerId]),
                    State1 = handle_peer_departure(RoomId, PeerId, State),
                    {noreply, State1#state{monitors = NewMonitors}};
                false ->
                    {noreply, State#state{monitors = NewMonitors}}
            end;
        error ->
            {noreply, State}
    end;

handle_info({poll_manifest, RoomId, StartedAt, Attempts}, State) ->
    PlaylistPath = recording_path(RoomId),
    case filelib:is_regular(PlaylistPath) of
        true ->
            error_logger:info_msg("HLS manifest ~s is ready on disk. Notifying clients.~n", [PlaylistPath]),
            notify_room_info(RoomId, StartedAt, State),
            {noreply, State};
        false ->
            if
                Attempts < 1000 ->
                    erlang:send_after(100, self(), {poll_manifest, RoomId, StartedAt, Attempts + 1}),
                    {noreply, State};
                true ->
                    error_logger:error_msg("Timeout waiting for HLS manifest ~s~n", [PlaylistPath]),
                    {noreply, State}
            end
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:map(fun(_, Port) -> catch port_close(Port) end, State#state.ports),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal Helpers

send_to_port(Port, Map) ->
    Json = jsone:encode(Map),
    port_command(Port, [Json, <<"\n">>]).

notify_room_info(RoomId, StartedAt, State) ->
    HlsFormat = application:get_env(rtp, hls_format, fmp4),
    RoomInfoMsg = jsone:encode(#{
        <<"type">> => <<"room_info">>,
        <<"started_at">> => StartedAt,
        <<"hls_format">> => HlsFormat
    }),
    Msg = {'$msg', kvs:seq([], []), [], [], <<"System">>, RoomInfoMsg},
    n2o:send({topic, binary_to_list(RoomId)}, #client{data = Msg}),
    
    Peers = maps:get(RoomId, State#state.room_peers, []),
    lists:foreach(fun(PeerId) ->
        case syn:lookup(rooms, PeerId) of
            {Pid, _} -> Pid ! {send_room_info, StartedAt};
            undefined -> ok
        end
    end, Peers).

handle_peer_departure(RoomId, PeerId, State) ->
    case maps:find(RoomId, State#state.ports) of
        {ok, Port} ->
            send_to_port(Port, #{
                <<"type">> => <<"peer_left">>,
                <<"peer_id">> => PeerId
            }),
            Peers = maps:get(RoomId, State#state.room_peers, []),
            NewPeers = lists:delete(PeerId, Peers),
            NewPeerRooms = maps:remove(PeerId, State#state.peer_rooms),
            
            lists:foreach(fun(PidPeer) ->
                case syn:lookup(rooms, PidPeer) of
                    {Pid, _} -> Pid ! {peer_left, PeerId};
                    undefined -> ok
                end
            end, NewPeers),
            
            case NewPeers of
                [] ->
                    error_logger:info_msg("Last peer left room ~s. Closing GStreamer port.~n", [RoomId]),
                    catch port_close(Port),
                    NewPorts = maps:remove(RoomId, State#state.ports),
                    NewRoomPeers = maps:remove(RoomId, State#state.room_peers),
                    State#state{
                        ports = NewPorts,
                        room_peers = NewRoomPeers,
                        peer_rooms = NewPeerRooms
                    };
                _ ->
                    NewRoomPeers = maps:put(RoomId, NewPeers, State#state.room_peers),
                    State#state{
                        room_peers = NewRoomPeers,
                        peer_rooms = NewPeerRooms
                    }
            end;
        error ->
            State
    end.

find_room_by_port(Port, Ports) ->
    List = maps:to_list(Ports),
    case lists:keyfind(Port, 2, List) of
        {RoomId, _} -> RoomId;
        false -> undefined
    end.

find_binary() ->
    Paths = [
        case code:priv_dir(rtp) of
            {error, bad_name} -> "./priv/gst";
            D -> filename:join(D, "gst")
        end,
        "./priv/gst",
        "../priv/gst",
        "../../priv/gst"
    ],
    find_existing_path(Paths).

find_existing_path([Path | T]) ->
    case filelib:is_regular(Path) of
        true -> Path;
        false -> find_existing_path(T)
    end;
find_existing_path([]) ->
    "./priv/gst".
