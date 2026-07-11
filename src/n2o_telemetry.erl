-module(n2o_telemetry).
-behaviour('Elixir.WebSock').

-export([init/1, handle_in/2, handle_info/2, terminate/2]).

-record(state, {
    user_id :: binary(),
    room_id :: binary(),
    otel_collector_url :: string()
}).

init({UserId, RoomId, CollectorUrl}) ->
    {ok, #state{user_id = UserId, room_id = RoomId, otel_collector_url = CollectorUrl}}.

handle_in({text, Msg}, State) ->
    Stats = jsone:decode(Msg),
    OtlpMetrics = format_otlp_metrics(State#state.user_id, State#state.room_id, Stats),
    spawn(fun() -> ship_to_otel(State#state.otel_collector_url, OtlpMetrics) end),
    {ok, State};

handle_in(_Frame, State) ->
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

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
