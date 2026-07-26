-module(rtp_app).
-behaviour(application).
-export([start/2, stop/1, print_banner/0]).

stop(_State) -> ok.
start(_StartType, _StartArgs) ->
    print_banner(),
    kvs:join(),
    ok = syn:add_node_to_scopes([rooms, n2o_mq]),
    {ok, _} = 'Elixir.Bandit':start_link([{plug, 'Elixir.RTP.WS'},     {port, 8082}]),
    {ok, _} = 'Elixir.Bandit':start_link([{plug, 'Elixir.RTP.Static'}, {port, 8081}]),
    rtp_sup:start_link().

print_banner() ->
    Cores = erlang:system_info(logical_processors_online),
    MemStr = string:trim(os:cmd("sysctl -n hw.memsize 2>/dev/null || awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo 0")),
    MemBytes = try list_to_integer(MemStr) catch _:_ -> 0 end,
    MemGB = if MemBytes > 0 -> MemBytes div (1024*1024*1024); true -> unknown end,
    MaxRooms = Cores * 10,
    RoomCapacity = 50,
    MaxParticipants = MaxRooms * RoomCapacity,
    Logo = "\e[93;44mERP\e[97;45m/1\e[0m",
    io:format("~n"),
    io:format("╔════════════════════════════════════════════════════════╗~n"),
    io:format("║  ~s: RTP Server / Signaling & Telemetry             ║~n", [Logo]),
    io:format("║  WS  : ws://localhost:8082/ws/app/<page>.htm           ║~n"),
    io:format("║  HTTP: http://localhost:8081/app/login.htm             ║~n"),
    io:format("╚════════════════════════════════════════════════════════╝~n"),
    io:format("  Hardware   : ~p Cores, ~p GB RAM~n", [Cores, MemGB]),
    io:format("  Max Rooms  : ~p (heuristic based on cores)~n", [MaxRooms]),
    io:format("  Capacity   : ~p max participants (~p per room)~n", [MaxParticipants, RoomCapacity]),
    io:format("  RTP Codecs : Opus (Audio), VP8, VP9, H.264 (Video)~n"),
    io:format("~n").

