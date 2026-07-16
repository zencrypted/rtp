-module(index).
-export([event/1, jse/1]).
-include_lib("nitro/include/nitro.hrl").
-include_lib("n2o/include/n2o.hrl").
-include("session_token.hrl").

event(init) ->
    Req = (get(context))#cx.req,
    QS  = case is_map(Req) of
        true -> maps:get(qs, Req, <<>>);
        false -> <<>>
    end,
    Params = uri_string:dissect_query(QS),
    Token = case proplists:get_value(<<"token">>, Params) of
        undefined ->
            case n2o:session(token) of
                undefined -> <<>>;
                T0 -> T0
            end;
        T -> T
    end,
    case session_token:validate(Token) of
        {ok, #session_token{user = UserBin, room = RoomBin}} ->
            Room = binary_to_list(RoomBin),
            User = binary_to_list(UserBin),
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
            RecPath = media_broker_srv:recording_path(RoomBin),
            nitro:update(recording_info, #span{id = recording_info,
                                               body = [<<"📹 ">>, RecPath]}),
            
            %% Ensure room coordinator is started (which creates the Mnesia table)
            {ok, RoomPid} = room_coordinator:ensure_started(Room),

            %% Join room coordinator list of participants
            {ok, _} = room_coordinator:join(RoomPid, #{id => list_to_binary(User), pid => self()}),

            %% Fetch room-specific history
            {ok, History} = mnesia_srv:get_messages_from_room(Room),
            [ nitro:insert_top(history, nitro:render(#message{body = [#author{body = MapUser}, MapMsg]}))
              || #{sender := MapUser, text := MapMsg} <- History ],

            %% Draw active members list
            Participants = room_coordinator:active_participants(RoomPid),
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
    Room = n2o:session(room),
    User = n2o:user(),
    Token = n2o:session(token),
    case Token of
        undefined -> ok;
        _ -> ets:delete(session_tokens, Token)
    end,
    case Room of
        undefined -> ok;
        _ ->
            {ok, RoomPid} = room_coordinator:ensure_started(Room),
            ok = room_coordinator:leave(RoomPid, list_to_binary(User)),
            n2o:send({topic, Room}, #client{data = {member_left, User}})
    end,
    n2o:user([]),
    n2o:session(token, undefined),
    nitro:redirect("/app/login.htm");

event(chat) -> chat(nitro:q(message), nitro);

event(terminate_room) ->
    Room = n2o:session(room),
    {ok, RoomPid} = room_coordinator:ensure_started(Room),
    case room_coordinator:terminate_room(RoomPid) of
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
    Room = n2o:session(room),
    User = n2o:user(),
    case {Room, User} of
        {R, U} when R =/= undefined andalso R =/= [] andalso U =/= undefined andalso U =/= [] ->
            {ok, RoomPid} = room_coordinator:ensure_started(R),
            ok = room_coordinator:leave(RoomPid, list_to_binary(U)),
            n2o:send({topic, R}, #client{data = {member_left, U}});
        _ ->
            ok
    end;

event(_Event) -> ok.

jse(X) -> X.

chat(Message, F) ->
    Room = n2o:session(room),
    User = n2o:user(),
    {ok, RoomPid} = room_coordinator:ensure_started(Room),
    room_coordinator:post_chat(RoomPid, User, F:jse(Message)).
