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
            Conn1 = 'Elixir.Plug.Conn':put_resp_header(Conn, <<"content-type">>, <<"text/plain">>),
            'Elixir.Plug.Conn':send_resp(Conn1, 401, <<"Unauthorized Certificate">>)
    end.

get_header(Conn, Key) ->
    case 'Elixir.Plug.Conn':get_req_header(Conn, Key) of
        [Value | _] -> Value;
        [] -> <<>>
    end.

serve_static(Conn, Path) ->
    PrivDir = code:priv_dir(rtp),
    Joined = lists:join(<<"/">>, [PrivDir, <<"static">> | Path]),
    FullPath = iolist_to_binary(Joined),
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
        <<".js">> -> <<"application/javascript">>;
        <<".css">> -> <<"text/css">>;
        <<".png">> -> <<"image/png">>;
        <<".json">> -> <<"application/json">>;
        <<".svg">> -> <<"image/svg+xml">>;
        _ -> <<"application/octet-stream">>
    end.
