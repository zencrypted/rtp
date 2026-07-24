-module(rtp_room).
-export([event/1, jse/1]).
-include_lib("nitro/include/nitro.hrl").
-include_lib("n2o/include/n2o.hrl").

event(init) ->
    Room = n2o:session(room),
    User = n2o:user(),
    case {Room, User} of
        {undefined, _} -> nitro:redirect("/app/login.htm");
        {_, undefined} -> nitro:redirect("/app/login.htm");
        {R, U} when R =/= [] andalso U =/= [] ->
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
            RoomBin = list_to_binary(Room),
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
    Room  = n2o:session(room),
    User  = n2o:user(),
    case Room of
        undefined -> ok;
        _ ->
            {ok, RoomPid} = rtp_coordinator:ensure_started(Room),
            ok = rtp_coordinator:leave(RoomPid, list_to_binary(User)),
            n2o:send({topic, Room}, #client{data = {member_left, User}})
    end,
    n2o:user([]),
    nitro:redirect("/app/login.htm");

event(chat) -> chat(nitro:q(message), nitro);

event(terminate_room) ->
    Room = n2o:session(room),
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
    Room = n2o:session(room),
    User = n2o:user(),
    case {Room, User} of
        {R, U} when R =/= undefined andalso R =/= [] andalso U =/= undefined andalso U =/= [] ->
            {ok, RoomPid} = rtp_coordinator:ensure_started(R),
            ok = rtp_coordinator:leave(RoomPid, list_to_binary(U)),
            n2o:send({topic, R}, #client{data = {member_left, U}});
        _ ->
            ok
    end;

event(_Event) -> ok.

jse(X) -> X.

chat(Message, F) ->
    Room = n2o:session(room),
    User = n2o:user(),
    {ok, RoomPid} = rtp_coordinator:ensure_started(Room),
    rtp_coordinator:post_chat(RoomPid, User, F:jse(Message)).
