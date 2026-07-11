-module(erlang_plug).
-export([get_header/2]).
get_header(Conn, Key) ->
    'Elixir.Plug.Conn':get_req_header(Conn, Key).
