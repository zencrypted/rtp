-module(routes).
-include_lib("n2o/include/n2o.hrl").
-export([init/2, finish/2]).

finish(State, Ctx) -> {ok, State, Ctx}.

init(State, #cx{req = Req} = Cx) ->
    Path = case Req of
        #{request_path := P} -> P;
        #{path := P} -> P;
        _ -> <<"/">>
    end,
    Module = route_prefix(Path),
    error_logger:info_msg("routes:init called! Path = ~p, Module = ~p~n", [Path, Module]),
    {ok, State, Cx#cx{path = Path, module = Module}}.

route_prefix(<<"/ws/", P/binary>>) -> route(P);
route_prefix(<<"/", P/binary>>) -> route(P);
route_prefix(P) -> route(P).

route(<<>>) -> login;
route(<<"index", _/binary>>) -> index;
route(<<"login", _/binary>>) -> login;
route(<<"app/index", _/binary>>) -> index;
route(<<"app/login", _/binary>>) -> login;
route(_) -> login.
