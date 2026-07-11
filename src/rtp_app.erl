-module(rtp_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    print_banner(),

    % 1. Initialize KVS schema bindings
    kvs:join(),

    % 2. Initialize Syn registry rooms scope
    ok = syn:add_node_to_scopes([rooms]),

    % 3. Start main HTTP/WebSocket listener on Port 8081
    Port = application:get_env(n2o, port, 8081),
    {ok, _} = 'Elixir.Bandit':start_link([{plug, rtp_router}, {port, Port}]),

    % 4. Start high-priority telemetry listener on Port 8082
    {ok, _} = 'Elixir.Bandit':start_link([{plug, rtp_router}, {port, 8082}]),

    rtp_sup:start_link().

stop(_State) ->
    ok.

print_banner() ->
    Cores = erlang:system_info(logical_processors_online),
    MemStr = string:trim(os:cmd("sysctl -n hw.memsize 2>/dev/null || awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo 0")),
    MemBytes = try list_to_integer(MemStr) catch _:_ -> 0 end,
    MemGB = if MemBytes > 0 -> MemBytes div (1024*1024*1024); true -> unknown end,
    
    % Example WebRTC capacity heuristics based on hardware
    MaxRooms = Cores * 10,
    RoomCapacity = 50,
    MaxParticipants = MaxRooms * RoomCapacity,
    
    TurnConfig = application:get_env(eturnal, listen, []),
    
    Logo = "\e[93;44mERP\e[97;45m/1\e[0m",
    io:format("~n"),
    io:format("╔════════════════════════════════════════════════════════╗~n"),
    io:format("║  ~s: RTP Server / Signaling & Telemetry             ║~n", [Logo]),
    io:format("╚════════════════════════════════════════════════════════╝~n"),
    io:format("  Hardware   : ~p Cores, ~p GB RAM~n", [Cores, MemGB]),
    io:format("  Max Rooms  : ~p (heuristic based on cores)~n", [MaxRooms]),
    io:format("  Capacity   : ~p max participants (~p per room)~n", [MaxParticipants, RoomCapacity]),
    io:format("  RTP Codecs : Opus (Audio), VP8, VP9, H.264 (Video)~n"),
    io:format("~n"),
    io:format("  TURN Configuration Table:~n"),
    [io:format("    - ~p:~p (~p) TLS: ~p, STUN: ~p~n", [IP, Port, Proto, Tls, Stun]) || {IP, Port, Proto, Tls, Stun} <- TurnConfig],
    io:format("~n").

