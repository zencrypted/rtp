-module(rtp_syn).
-description('Custom N2O SYN MQ Backend for Syn v3').
-include_lib("n2o/include/n2o.hrl").
-export([init/0, send/2, reg/1, reg/2, unreg/1]).

init() -> ok.

send(Pool, Message) ->
    syn:publish(n2o_mq, term_to_binary(Pool), Message).

reg(Pool) -> reg(Pool, undefined).

reg(Pool, _Value) ->
    case get({pool, Pool}) of
         undefined ->
             case syn:join(n2o_mq, term_to_binary(Pool), self()) of
                 ok -> put({pool, Pool}, Pool);
                 {error, Reason} -> error_logger:error_msg("rtp_syn:join failed: ~p~n", [Reason])
             end;
         _Defined -> skip
    end.

unreg(Pool) ->
    case get({pool, Pool}) of
         undefined -> skip;
         _Defined ->
             _ = syn:leave(n2o_mq, term_to_binary(Pool), self()),
             erase({pool, Pool})
    end.
