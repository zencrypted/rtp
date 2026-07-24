-module(rtp_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    ChildSpecs = [
        #{
            id => rtp_store,
            start => {rtp_store, start_link, []},
            restart => permanent,
            shutdown => 2000,
            type => worker,
            modules => [rtp_store]
        },
        #{
            id => rtp_broker,
            start => {rtp_broker, start_link, []},
            restart => permanent,
            shutdown => 2000,
            type => worker,
            modules => [rtp_broker]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
