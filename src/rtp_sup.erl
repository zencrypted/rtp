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
            id => mnesia_srv,
            start => {mnesia_srv, start_link, []},
            restart => permanent,
            shutdown => 2000,
            type => worker,
            modules => [mnesia_srv]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
