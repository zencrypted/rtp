-module(media_broker_srv).
-behaviour(gen_server).
-compile(nowarn_deprecated_catch).

%% API
-export([start_link/0, peer_joined/3, sdp_answer/3, ice_candidate/3, peer_left/2, terminate_room/1, recording_path/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    ports = #{},       % RoomId :: binary() -> Port :: port()
    room_peers = #{},  % RoomId :: binary() -> [PeerId :: binary()]
    peer_rooms = #{}   % PeerId :: binary() -> RoomId :: binary()
}).

%% API Functions

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

peer_joined(RoomId, PeerId, ClientPid) ->
    gen_server:call(?MODULE, {peer_joined, RoomId, PeerId, ClientPid}).

sdp_answer(RoomId, PeerId, Sdp) ->
    gen_server:cast(?MODULE, {sdp_answer, RoomId, PeerId, Sdp}).

ice_candidate(RoomId, PeerId, Candidate) ->
    gen_server:cast(?MODULE, {ice_candidate, RoomId, PeerId, Candidate}).

peer_left(RoomId, PeerId) ->
    gen_server:cast(?MODULE, {peer_left, RoomId, PeerId}).

terminate_room(RoomId) ->
    gen_server:call(?MODULE, {terminate_room, RoomId}).

recording_path(RoomId) ->
    case RoomId of
        <<"court-room-room123">> -> filename:absname("output.mp4");
        _ -> filename:absname("room_" ++ binary_to_list(RoomId) ++ ".mp4")
    end.

%% gen_server Callbacks

init([]) ->
    {ok, #state{}}.

handle_call({peer_joined, RoomId, PeerId, _ClientPid}, _From, State) ->
    {Port, NewPorts} = case maps:find(RoomId, State#state.ports) of
        {ok, P} ->
            {P, State#state.ports};
        error ->
            Binary = filename:absname(find_binary()),
            OutFile = case RoomId of
                <<"court-room-room123">> -> "output.mp4";
                _ -> "room_" ++ binary_to_list(RoomId) ++ ".mp4"
            end,
            error_logger:info_msg("Spawning GStreamer mixer for room ~s writing to ~s~n", [RoomId, OutFile]),
            P = open_port({spawn_executable, Binary}, [
                binary,
                stream,
                {args, [OutFile]},
                use_stdio,
                stderr_to_stdout,
                exit_status,
                {line, 16384}
            ]),
            {P, maps:put(RoomId, P, State#state.ports)}
    end,
    
    send_to_port(Port, #{
        <<"type">> => <<"peer_joined">>,
        <<"peer_id">> => PeerId
    }),
    
    Peers = maps:get(RoomId, State#state.room_peers, []),
    NewRoomPeers = maps:put(RoomId, [PeerId | Peers], State#state.room_peers),
    NewPeerRooms = maps:put(PeerId, RoomId, State#state.peer_rooms),
    
    {reply, ok, State#state{
        ports = NewPorts,
        room_peers = NewRoomPeers,
        peer_rooms = NewPeerRooms
    }};

handle_call({terminate_room, RoomId}, _From, State) ->
    case maps:find(RoomId, State#state.ports) of
        {ok, Port} ->
            error_logger:info_msg("Terminating GStreamer for room ~s, finalizing mp4~n", [RoomId]),
            catch port_close(Port),
            Peers = maps:get(RoomId, State#state.room_peers, []),
            NewPeerRooms = lists:foldl(fun(P, M) -> maps:remove(P, M) end, State#state.peer_rooms, Peers),
            {reply, {ok, recording_path(RoomId)}, State#state{
                ports     = maps:remove(RoomId, State#state.ports),
                room_peers = maps:remove(RoomId, State#state.room_peers),
                peer_rooms = NewPeerRooms
            }};
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

handle_info({_Port, {data, {eol, LineBin}}}, State) ->
    case catch jsone:decode(LineBin) of
        #{<<"type">> := <<"sdp_offer">>, <<"peer_id">> := PeerId, <<"sdp">> := Sdp} ->
            case syn:lookup(rooms, PeerId) of
                {Pid, _} -> Pid ! {sdp_offer, Sdp};
                undefined -> ok
            end;
        #{<<"type">> := <<"ice_candidate">>, <<"peer_id">> := PeerId, <<"candidate">> := Candidate} ->
            case syn:lookup(rooms, PeerId) of
                {Pid, _} -> Pid ! {ice_candidate, Candidate};
                undefined -> ok
            end;
        _Other ->
            error_logger:info_msg("GStreamer Output (~p): ~s~n", [self(), LineBin])
    end,
    {noreply, State};

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
