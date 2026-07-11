-module(n2o_telemetry).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

-record(state, {
    user_id :: binary(),
    room_id :: binary(),
    otel_collector_url :: string()
}).

init(Req, State) ->
    Headers = cowboy_req:headers(Req),
    ClientCertDN = maps:get(<<"x-ssl-client-s-dn">>, Headers, <<>>),
    ClientCertSAN = maps:get(<<"x-ssl-client-san">>, Headers, <<>>),

    case auth_translation:verify_client_cert(ClientCertDN, ClientCertSAN) of
        {ok, UserId, RoomId, _Role} ->
            CollectorUrl = "http://otel-collector.erp-telemetry.svc.cluster.local:4318/v1/metrics",
            {cowboy_websocket, Req, #state{user_id = UserId, room_id = RoomId, otel_collector_url = CollectorUrl}};
        {error, unauthorized} ->
            Req2 = cowboy_req:reply(401, #{}, <<"Unauthorized Telemetry">>, Req),
            {ok, Req2, State}
    end.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Msg}, State) ->
    Stats = jsone:decode(Msg),
    OtlpMetrics = format_otlp_metrics(State#state.user_id, State#state.room_id, Stats),
    spawn(fun() -> ship_to_otel(State#state.otel_collector_url, OtlpMetrics) end),
    {ok, State};

websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info(_Info, State) ->
    {ok, State}.

%% Internal Functions

format_otlp_metrics(UserId, RoomId, Stats) ->
    #{
        resourceMetrics => [#{
            resource => #{
                attributes => [
                    #{key => <<"service.name">>, value => #{stringValue => <<"rtp-webrtc-client">>}},
                    #{key => <<"user.id">>, value => #{stringValue => UserId}},
                    #{key => <<"room.id">>, value => #{stringValue => RoomId}}
                ]
            },
            scopeMetrics => [#{
                scope => #{name => <<"client-telemetry-probe">>},
                metrics => [
                    #{
                        name => <<"webrtc.packet_loss_percentage">>,
                        gauge => #{dataPoints => [#{
                            value => maps:get(<<"packet_loss">>, Stats, 0.0),
                            timeUnixNano => integer_to_binary(erlang:system_time(nanosecond))
                        }]}
                    },
                    #{
                        name => <<"webrtc.rtt_ms">>,
                        gauge => #{dataPoints => [#{
                            value => maps:get(<<"rtt">>, Stats, 0),
                            timeUnixNano => integer_to_binary(erlang:system_time(nanosecond))
                        }]}
                    },
                    #{
                        name => <<"webrtc.jitter">>,
                        gauge => #{dataPoints => [#{
                            value => maps:get(<<"jitter">>, Stats, 0.0),
                            timeUnixNano => integer_to_binary(erlang:system_time(nanosecond))
                        }]}
                    }
                ]
            }]
        }]
    }.

ship_to_otel(CollectorUrl, Payload) ->
    JsonPayload = jsone:encode(Payload),
    httpc:request(post, {CollectorUrl, [{"Content-Type", "application/json"}], "application/json", JsonPayload}, [], []).
