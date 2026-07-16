-module(rtp_router).
-export([init/1, call/2]).

init(Opts) -> Opts.

call(Conn, _Opts) ->
    Path = maps:get(path_info, Conn),
    case Path of
        [<<"ws">>, <<"signaling">>] ->
            upgrade_websock(Conn, n2o_signaling);
        [<<"ws">>, <<"telemetry">>] ->
            upgrade_websock(Conn, n2o_telemetry);
        [<<"ws">>, <<"app">> | SubPath] ->
            Joined = iolist_to_binary(lists:join(<<"/">>, SubPath)),
            upgrade_websock_n2o(Conn, <<"/app/", Joined/binary>>);
        _ ->
            serve_static(Conn, Path)
    end.

upgrade_websock(Conn, Handler) ->
    ClientCertDN = get_header(Conn, <<"x-ssl-client-s-dn">>),
    ClientCertSAN = get_header(Conn, <<"x-ssl-client-san">>),
    case auth_translation:verify_client_cert(ClientCertDN, ClientCertSAN) of
        {ok, UserId, RoomId, Role} ->
            State = case Handler of
                n2o_signaling -> {UserId, RoomId, Role};
                n2o_telemetry -> {UserId, RoomId, "http://otel-collector.erp-telemetry.svc.cluster.local:4318/v1/metrics"}
            end,
            'Elixir.WebSockAdapter':upgrade(Conn, Handler, State, []);
        {error, unauthorized} ->
            case get_query_params(Conn) of
                {ok, UserId, RoomId, Role} ->
                    State = case Handler of
                        n2o_signaling -> {UserId, RoomId, Role};
                        n2o_telemetry -> {UserId, RoomId, "http://otel-collector.erp-telemetry.svc.cluster.local:4318/v1/metrics"}
                    end,
                    'Elixir.WebSockAdapter':upgrade(Conn, Handler, State, []);
                _ ->
                    Conn1 = 'Elixir.Plug.Conn':put_resp_header(Conn, <<"content-type">>, <<"text/plain">>),
                    'Elixir.Plug.Conn':send_resp(Conn1, 401, <<"Unauthorized Certificate">>)
            end
    end.

get_query_params(Conn) ->
    case Conn of
        #{query_string := QS} when QS /= <<>> ->
            Params = uri_string:dissect_query(QS),
            User = proplists:get_value(<<"user">>, Params, <<"test-user">>),
            Room = proplists:get_value(<<"room">>, Params, <<"court-room-room123">>),
            Role = proplists:get_value(<<"role">>, Params, <<"participant">>),
            error_logger:info_msg("Router fallback auth query params: user=~p, room=~p, role=~p~n", [User, Room, Role]),
            {ok, User, Room, Role};
        _ ->
            error
    end.

upgrade_websock_n2o(Conn, Path) ->
    'Elixir.WebSockAdapter':upgrade(Conn, n2o_websock, {Conn, Path}, []).

get_header(Conn, Key) ->
    case 'Elixir.Plug.Conn':get_req_header(Conn, Key) of
        [Value | _] -> Value;
        [] -> <<>>
    end.

serve_static(Conn, Path) ->
    case Path of
        [<<"n2o">>, File] ->
            PrivDir = case code:priv_dir(n2o) of
                {error, bad_name} -> "./_build/default/lib/n2o/priv";
                D -> D
            end,
            send_file(Conn, filename:join(PrivDir, File));
        [<<"nitro">>, <<"js">>, File] ->
            PrivDir = case code:priv_dir(nitro) of
                {error, bad_name} -> "./_build/default/lib/nitro/priv";
                D -> D
            end,
            send_file(Conn, filename:join([PrivDir, <<"js">>, File]));
        [<<"nitro">>, <<"css">>, File] ->
            PrivDir = case code:priv_dir(nitro) of
                {error, bad_name} -> "./_build/default/lib/nitro/priv";
                D -> D
            end,
            send_file(Conn, filename:join([PrivDir, <<"css">>, File]));
        [<<"output.mp4">>] ->
            send_file(Conn, <<"output.mp4">>);
        _ ->
            PrivDir = case code:priv_dir(rtp) of
                {error, bad_name} -> "./priv";
                D -> D
            end,
            Joined = lists:join(<<"/">>, [PrivDir, <<"static">> | Path]),
            FullPath = iolist_to_binary(Joined),
            send_file(Conn, FullPath)
    end.

send_file(Conn, FullPath) ->
    case file:read_file(FullPath) of
        {ok, Bin} ->
            Conn1 = 'Elixir.Plug.Conn':put_resp_header(Conn, <<"content-type">>, get_mime(FullPath)),
            'Elixir.Plug.Conn':send_resp(Conn1, 200, Bin);
        _ ->
            'Elixir.Plug.Conn':send_resp(Conn, 404, <<"Not Found">>)
    end.

get_mime(Path) ->
    case filename:extension(Path) of
        <<".html">> -> <<"text/html">>;
        <<".htm">> -> <<"text/html">>;
        <<".js">> -> <<"application/javascript">>;
        <<".css">> -> <<"text/css">>;
        <<".png">> -> <<"image/png">>;
        <<".json">> -> <<"application/json">>;
        <<".svg">> -> <<"image/svg+xml">>;
        <<".mp4">> -> <<"video/mp4">>;
        _ -> <<"application/octet-stream">>
    end.
