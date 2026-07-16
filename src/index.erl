-module(index).
-export([event/1, jse/1]).
-include_lib("nitro/include/nitro.hrl").
-include_lib("n2o/include/n2o.hrl").
-include_lib("kvs/include/cursors.hrl").

event(init) ->
    %% Session survives F5 (Mnesia-backed cookie). Fall back to URL query params
    %% if user arrives directly via URL without going through login.
    RawRoom = n2o:session(room),
    RawUser = n2o:user(),
    {Room, User} = case {RawRoom, RawUser} of
        {R, U} when R =/= [] andalso R =/= undefined andalso
                    U =/= [] andalso U =/= undefined ->
            {R, U};
        _ ->
            Req = (n2o:cx())#cx.req,
            QS  = maps:get(qs, Req, <<>>),
            Params = uri_string:dissect_query(QS),
            R2 = proplists:get_value(<<"room">>, Params, <<"lobby">>),
            U2 = proplists:get_value(<<"user">>, Params, <<"guest">>),
            n2o:session(room, R2),
            n2o:user(U2),
            {R2, U2}
    end,
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
    RecPath = media_broker_srv:recording_path(Room),
    nitro:update(recording_info, #span{id = recording_info,
                                       body = [<<"📹 ">>, RecPath]}),
    [ event(#client{data = E}) || E <- lists:reverse(kvs:feed(Key)) ],
    n2o:send(Key, #client{data = {member_joined, User}});

event(logout) ->
    Room = n2o:session(room),
    User = n2o:user(),
    n2o:send({topic, Room}, #client{data = {member_left, User}}),
    n2o:user([]),
    nitro:redirect("/app/login.htm");

event(chat) -> chat(nitro:q(message), nitro);

event(terminate_room) ->
    Room = n2o:session(room),
    case media_broker_srv:terminate_room(Room) of
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

event(_Event) -> ok.

jse(X) -> X.

chat(Message, F) ->
    Room = n2o:session(room),
    User = n2o:user(),
    Msg  = {'$msg', kvs:seq([], []), [], [], User, F:jse(Message)},
    kvs:append(Msg, {topic, Room}),
    n2o:send({topic, Room}, #client{data = Msg}).
