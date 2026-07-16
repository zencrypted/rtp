-module(login).
-export([event/1]).
-include_lib("nitro/include/nitro.hrl").
-include_lib("n2o/include/n2o.hrl").
-include("session_token.hrl").

event(init) ->
    error_logger:info_msg("login:event(init) called!~n"),
    nitro:update(loginButton, #button{id = loginButton, body = "Login",
                                      postback = login, source = [user, pass]});

event(login) ->
    User = nitro:to_list(nitro:q(user)),
    Room = nitro:to_list(nitro:q(pass)),
    Token = session_token:issue(User, Room),
    n2o:user(User),
    n2o:session(room, Room),
    n2o:session(token, Token),
    %% Navigate client-side: index.htm reads URL params, saves to localStorage, auto-joins
    URL = iolist_to_binary(["/app/index.htm?room=", Room, "&user=", User, "&token=", Token]),
    nitro:wire(<<"window.location.href='", URL/binary, "';">>);

event(_) -> [].
