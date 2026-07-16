-module(session_token).
-export([init_table/0, issue/2, validate/1, update_device/2]).
-include("session_token.hrl").

init_table() ->
    case ets:info(session_tokens) of
        undefined ->
            ets:new(session_tokens, [set, public, named_table, {keypos, #session_token.token}]);
        _ ->
            ok
    end.

issue(User, Room) ->
    init_table(),
    Token = n2o_secret:sid(os:timestamp()),
    Now = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    Expiry = Now + 180, % 3 minutes (180 seconds)
    Record = #session_token{
        token = Token,
        user = case is_binary(User) of true -> User; false -> list_to_binary(User) end,
        room = case is_binary(Room) of true -> Room; false -> list_to_binary(Room) end,
        device = undefined,
        expiry = Expiry
    },
    ets:insert(session_tokens, Record),
    Token.

validate(Token) ->
    init_table(),
    Now = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    case ets:lookup(session_tokens, Token) of
        [#session_token{expiry = Expiry} = ST] when Expiry >= Now ->
            {ok, ST};
        [#session_token{token = T}] ->
            %% Expired
            ets:delete(session_tokens, T),
            {error, expired};
        [] ->
            {error, not_found}
    end.

update_device(Token, Device) ->
    init_table(),
    case ets:lookup(session_tokens, Token) of
        [ST] ->
            NewST = ST#session_token{device = case is_binary(Device) of true -> Device; false -> list_to_binary(Device) end},
            ets:insert(session_tokens, NewST),
            ok;
        [] ->
            {error, not_found}
    end.
