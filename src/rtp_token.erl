-module(rtp_token).
-export([init_table/0, issue/2, validate/1, update_device/2, cleanup_user/2]).
-include("rtp_token.hrl").

-define(DEFAULT_TTL, 180). % seconds default token TTL

init_table() ->
    case ets:info(rtp_tokens) of
        undefined ->
            ets:new(rtp_tokens, [set, public, named_table, {keypos, #rtp_token.token}]);
        _ ->
            ok
    end.

issue(User, Room) ->
    init_table(),
    Token = n2o_secret:sid(os:timestamp()),
    Now = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    Ttl = application:get_env(rtp, token_ttl, ?DEFAULT_TTL),
    Expiry = Now + Ttl, % token TTL seconds
    Record = #rtp_token{
        token = Token,
        user = case is_binary(User) of true -> User; false -> list_to_binary(User) end,
        room = case is_binary(Room) of true -> Room; false -> list_to_binary(Room) end,
        device = undefined,
        expiry = Expiry
    },
    ets:insert(rtp_tokens, Record),
    Token.

validate(Token) ->
    init_table(),
    Now = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    case ets:lookup(rtp_tokens, Token) of
        [#rtp_token{expiry = Expiry} = ST] when Expiry >= Now ->
            {ok, ST};
        [#rtp_token{token = T}] ->
            %% Expired
            ets:delete(rtp_tokens, T),
            {error, expired};
        [] ->
            {error, not_found}
    end.

update_device(Token, Device) ->
    init_table(),
    case ets:lookup(rtp_tokens, Token) of
        [ST] ->
            NewST = ST#rtp_token{device = case is_binary(Device) of true -> Device; false -> list_to_binary(Device) end},
            ets:insert(rtp_tokens, NewST),
            ok;
        [] ->
            {error, not_found}
    end.
%% Clean up stale tokens for a user/room
cleanup_user(User, Room) ->
    init_table(),
    Pattern = #rtp_token{user = case is_binary(User) of true -> User; false -> list_to_binary(User) end,
                        room = case is_binary(Room) of true -> Room; false -> list_to_binary(Room) end,
                        token = '_', device = '_', expiry = '_'},
    ets:match_delete(rtp_tokens, Pattern),
    ok.
