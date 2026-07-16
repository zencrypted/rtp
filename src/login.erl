-module(login).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").
-include_lib("n2o/include/n2o.hrl").

event(init) ->
    error_logger:info_msg("login:event(init) called!~n"),
    nitro:update(loginButton, #button{id = loginButton, body = "Login",
                                      postback = login, source = [user, pass]});

event(login) ->
    User = nitro:to_list(nitro:q(user)),
    Room = nitro:to_list(nitro:q(pass)),
    n2o:user(User),
    n2o:session(room, Room),
    %% Navigate client-side: index.htm reads URL params, saves to localStorage, auto-joins
    URL = iolist_to_binary(["/app/index.htm?room=", Room, "&user=", User]),
    nitro:wire(<<"window.location.href='", URL/binary, "';">>);

event(_) -> [].
