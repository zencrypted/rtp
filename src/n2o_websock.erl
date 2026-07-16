-module(n2o_websock).
-behaviour('Elixir.WebSock').
-include_lib("n2o/include/n2o.hrl").

-export([init/1, handle_in/2, handle_info/2, terminate/2]).

init({Req, Path}) ->
    Cookies = case maps:find(req_cookies, Req) of
        {ok, C} -> maps:to_list(C);
        error -> []
    end,
    Zero = n2o_proto:cx(Cookies, Req),
    Ctx = fold(init, Zero#cx.handlers, Zero#cx{path = Path}),
    put(context, Ctx),
    {ok, Ctx}.

handle_in({Data, Opts}, Ctx) ->
    put(context, Ctx),
    Opcode = proplists:get_value(opcode, Opts, text),
    Message = case Opcode of
        binary -> n2o:decode(Data);
        text -> {text, Data}
    end,
    case n2o_proto:info(Message, [], Ctx) of
        {reply, {binary, Bin}, NewCtx} ->
            {reply, {binary, Bin}, NewCtx};
        {reply, {bert, Term}, NewCtx} ->
            {reply, {binary, n2o:encode(Term)}, NewCtx};
        {reply, {text, Text}, NewCtx} ->
            {reply, {text, Text}, NewCtx};
        {reply, Other, NewCtx} ->
            {reply, Other, NewCtx};
        _ ->
            {ok, Ctx}
    end.

handle_info(Msg, Ctx) ->
    put(context, Ctx),
    case n2o_proto:info(Msg, [], Ctx) of
        {reply, {binary, Bin}, NewCtx} ->
            {reply, {binary, Bin}, NewCtx};
        {reply, {bert, Term}, NewCtx} ->
            {reply, {binary, n2o:encode(Term)}, NewCtx};
        {reply, {text, Text}, NewCtx} ->
            {reply, {text, Text}, NewCtx};
        _ ->
            {ok, Ctx}
    end.

terminate(_Reason, Ctx) ->
    put(context, Ctx),
    n2o_proto:terminate([], Ctx),
    ok.

fold(Fun, Handlers, Ctx) ->
    lists:foldl(fun ({_, []}, C) -> C;
                    ({_, Module}, Ctx1) ->
                        {ok, _, NewCtx} = Module:Fun([], Ctx1),
                        NewCtx
                end,
                Ctx,
                Handlers).
