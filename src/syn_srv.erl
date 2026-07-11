-module(syn_srv).

-export([
    register_room/2,
    unregister_room/1,
    lookup_room/1,
    join_room_pubsub/2,
    publish_room_msg/2
]).

register_room(RoomId, Pid) ->
    syn:register(rooms, RoomId, Pid).

unregister_room(RoomId) ->
    syn:unregister(rooms, RoomId).

lookup_room(RoomId) ->
    case syn:lookup(rooms, RoomId) of
        undefined -> undefined;
        {Pid, _Meta} -> {ok, Pid}
    end.

join_room_pubsub(RoomId, Pid) ->
    syn:join(RoomId, Pid).

publish_room_msg(RoomId, Msg) ->
    syn:publish(RoomId, Msg).
