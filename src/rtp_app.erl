-module(rtp_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    % 1. Initialize KVS schema bindings
    kvs:join(),

    % 2. Initialize Syn registry rooms scope
    ok = syn:add_node_to_scopes([rooms]),

    % 3. Compile Cowboy routes
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/ws/signaling", n2o_signaling, []},
            {"/ws/telemetry", n2o_telemetry, []},
            {"/[...]", cowboy_static, {priv_dir, rtp, "static"}}
        ]}
    ]),

    % 4. Start HTTP/WebSocket signaling listener on Port 8081
    Port = application:get_env(n2o, port, 8081),
    {ok, _} = cowboy:start_clear(http_signaling_listener,
        [{port, Port}],
        #{env => #{dispatch => Dispatch}}
    ),

    % 5. Start high-priority telemetry listener on Port 8082
    {ok, _} = cowboy:start_clear(http_telemetry_listener,
        [{port, 8082}],
        #{env => #{dispatch => Dispatch}}
    ),

    rtp_sup:start_link().

stop(_State) ->
    cowboy:stop_listener(http_signaling_listener),
    cowboy:stop_listener(http_telemetry_listener),
    ok.
