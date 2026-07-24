-module(rtp_room).
-export([event/1, jse/1]).
-include_lib("nitro/include/nitro.hrl").
-include_lib("n2o/include/n2o.hrl").
-include("rtp_token.hrl").

event(init) ->
    Req = (get(context))#cx.req,
    QS  = case is_map(Req) of
        true -> maps:get(qs, Req, <<>>);
        false -> <<>>
    end,
    Params = uri_string:dissect_query(QS),

    ParamUser  = proplists:get_value(<<"user">>, Params, <<>>),
    ParamRoom  = proplists:get_value(<<"room">>, Params, <<>>),
    ParamToken = proplists:get_value(<<"token">>, Params, <<>>),

    Validated = case rtp_token:validate(ParamToken) of
        {ok, #rtp_token{user = TokenUser, room = TokenRoom, token = ValidToken}} ->
            {ok, TokenUser, TokenRoom, ValidToken};
        _ ->
            if ParamUser =/= <<>> andalso ParamRoom =/= <<>> ->
                NewToken = rtp_token:issue(ParamUser, ParamRoom),
                {ok, ParamUser, ParamRoom, NewToken};
               true ->
                SessToken = case n2o:session(token) of undefined -> <<>>; T -> T end,
                case rtp_token:validate(SessToken) of
                    {ok, #rtp_token{user = SU, room = SR, token = ST}} ->
                        {ok, SU, SR, ST};
                    _ ->
                        error
                end
            end
    end,

    case Validated of
        {ok, UserBin, RoomBin, Token} ->
            Room = binary_to_list(RoomBin),
            User = binary_to_list(UserBin),

            %% Process Dictionary Isolation per WebSocket Connection Process / Tab
            put(rtp_room, Room),
            put(rtp_user, User),
            put(rtp_token, Token),

            n2o:session(room, Room),
            n2o:user(User),
            n2o:session(token, Token),
            Key  = {topic, Room},
            n2o:reg(Key),
            n2o:reg(n2o:sid()),
            nitro:clear(history),
            nitro:update(logout,    #button{id = logout, body = "Logout " ++ User, postback = logout}),
            nitro:update(heading,   #h2{id = heading, body = Room}),
            nitro:update(upload,    #upload{}),
            nitro:update(send,      #button{id = send, body = <<"Chat">>,
                                            postback = chat, source = [message]}),
            nitro:update(terminate, #button{id = terminate, body = <<"⏹ Terminate Room">>,
                                            postback = terminate_room, class = <<"btn-danger">>}),
            RecPath = rtp_broker:recording_path(RoomBin),
            nitro:update(recording_info, #span{id = recording_info,
                                               body = [<<"📹 ">>, RecPath]}),

            %% Ensure room coordinator is started (which creates the Mnesia table)
            {ok, RoomPid} = rtp_coordinator:ensure_started(Room),

            %% Join room coordinator list of participants
            {ok, _} = rtp_coordinator:join(RoomPid, #{id => list_to_binary(User), pid => self()}),

            %% Fetch room-specific history
            {ok, History} = rtp_store:get_messages_from_room(Room),
            [ nitro:insert_top(history, nitro:render(#message{body = [#author{body = MapUser}, MapMsg]}))
              || #{sender := MapUser, text := MapMsg} <- History ],

            %% Draw active members list
            Participants = rtp_coordinator:active_participants(RoomPid),
            [ begin
                  UserStr = binary_to_list(maps:get(id, P)),
                  EscId   = "member-" ++ re:replace(UserStr, "[^a-zA-Z0-9]", "-", [global, {return, list}]),
                  JS = iolist_to_binary([
                      "var id='", EscId, "';"
                      "if(!document.getElementById(id)){"
                          "var d=document.createElement('div');"
                          "d.id=id; d.className='user-item';"
                          "d.innerHTML='<div class=\"user-status\"></div><span>", UserStr, "</span>';"
                          "document.getElementById('membersList').appendChild(d);"
                      "}"
                  ]),
                  nitro:wire(JS)
              end || P <- Participants ],

            n2o:send(Key, #client{data = {member_joined, User}});
        _ ->
            nitro:redirect("/app/login.htm")
    end;

event(logout) ->
    Room  = get_room(),
    User  = get_user(),
    Token = get_token(),
    case Token of
        "" -> ok;
        undefined -> ok;
        _ -> ets:delete(rtp_tokens, list_to_binary(Token))
    end,
    case Room of
        "" -> ok;
        undefined -> ok;
        _ ->
            {ok, RoomPid} = rtp_coordinator:ensure_started(Room),
            ok = rtp_coordinator:leave(RoomPid, list_to_binary(User)),
            n2o:send({topic, Room}, #client{data = {member_left, User}})
    end,
    put(rtp_user, undefined),
    put(rtp_room, undefined),
    put(rtp_token, undefined),
    n2o:user([]),
    n2o:session(token, undefined),
    nitro:redirect("/app/login.htm");

event(chat) -> chat(nitro:q(message), nitro);

event(terminate_room) ->
    Room = get_room(),
    {ok, RoomPid} = rtp_coordinator:ensure_started(Room),
    case rtp_coordinator:terminate_room(RoomPid) of
        {ok, Path} ->
            nitro:update(recording_info,
                #span{id = recording_info, body = [<<"✅ Saved: ">>, Path]}),
            nitro:wire(#alert{text = iolist_to_binary(["Recording saved: ", Path])});
        {error, not_found} ->
            nitro:wire(#alert{text = <<"No active recording for this room.">>})
    end;

event(#client{data = {member_joined, User}}) ->
    UserStr = nitro:to_list(User),
    EscId   = "member-" ++ re:replace(UserStr, "[^a-zA-Z0-9]", "-", [global, {return, list}]),
    JS = iolist_to_binary([
        "var id='", EscId, "';"
        "if(!document.getElementById(id)){"
            "var d=document.createElement('div');"
            "d.id=id; d.className='user-item';"
            "d.innerHTML='<div class=\"user-status\"></div><span>", UserStr, "</span>';"
            "document.getElementById('membersList').appendChild(d);"
        "}"
    ]),
    nitro:wire(JS);

event(#client{data = {member_left, User}}) ->
    UserStr = nitro:to_list(User),
    EscId   = "member-" ++ re:replace(UserStr, "[^a-zA-Z0-9]", "-", [global, {return, list}]),
    JS = iolist_to_binary([
        "var el=document.getElementById('", EscId, "');"
        "if(el)el.remove();"
    ]),
    nitro:wire(JS);

event(#client{data = {'$msg', _, _, _, User, Message}}) ->
    nitro:wire(#jq{target = message, method = [focus, select]}),
    nitro:insert_top(history, nitro:render(
        #message{body = [#author{body = User}, Message]}));

event(#ftp{sid = Sid, filename = Filename, status = {event, stop}}) ->
    Name = hd(lists:reverse(string:tokens(nitro:to_list(Filename), "/"))),
    chat(nitro:render(#link{href = iolist_to_binary(["/app/", Sid, "/", Name]), body = Name}), index);

event(terminate) ->
    Room = get_room(),
    User = get_user(),
    case {Room, User} of
        {R, U} when R =/= "" andalso R =/= undefined andalso U =/= "" andalso U =/= undefined ->
            {ok, RoomPid} = rtp_coordinator:ensure_started(R),
            ok = rtp_coordinator:leave(RoomPid, list_to_binary(U)),
            n2o:send({topic, R}, #client{data = {member_left, U}});
        _ ->
            ok
    end;

event(_Event) -> ok.

jse(X) -> X.

chat(Message, F) ->
    Room = get_room(),
    User = get_user(),
    {ok, RoomPid} = rtp_coordinator:ensure_started(Room),
    rtp_coordinator:post_chat(RoomPid, User, F:jse(Message)).

get_user() ->
    case get(rtp_user) of
        undefined -> case n2o:user() of undefined -> ""; U -> nitro:to_list(U) end;
        U -> U
    end.

get_room() ->
    case get(rtp_room) of
        undefined -> case n2o:session(room) of undefined -> ""; R -> nitro:to_list(R) end;
        R -> R
    end.

get_token() ->
    case get(rtp_token) of
        undefined -> case n2o:session(token) of undefined -> ""; T -> nitro:to_list(T) end;
        T -> T
    end.
