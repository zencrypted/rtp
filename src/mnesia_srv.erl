-module(mnesia_srv).
-behaviour(gen_server).

%% API
-export([start_link/0, save_message/4, get_messages/1, save_room/2, get_room/1,
         create_room_table/1, save_message_to_room/4, get_messages_from_room/1,
         room_table_name/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

-record(chat_message, {
    id :: {binary(), integer()},
    room_id :: binary(),
    sender :: binary(),
    text :: binary()
}).

-record(room_state, {
    room_id :: binary(),
    state_data :: any()
}).

%% API Functions

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

save_message(RoomId, Sender, Text, Timestamp) ->
    gen_server:call(?MODULE, {save_message, RoomId, Sender, Text, Timestamp}).

get_messages(RoomId) ->
    gen_server:call(?MODULE, {get_messages, RoomId}).

save_room(RoomId, RoomState) ->
    gen_server:call(?MODULE, {save_room, RoomId, RoomState}).

get_room(RoomId) ->
    gen_server:call(?MODULE, {get_room, RoomId}).

create_room_table(RoomId) ->
    gen_server:call(?MODULE, {create_room_table, RoomId}).

save_message_to_room(RoomId, Sender, Text, Timestamp) ->
    gen_server:call(?MODULE, {save_message_to_room, RoomId, Sender, Text, Timestamp}).

get_messages_from_room(RoomId) ->
    gen_server:call(?MODULE, {get_messages_from_room, RoomId}).

room_table_name(RoomId) when is_binary(RoomId) ->
    list_to_atom("chat_room_" ++ binary_to_list(RoomId));
room_table_name(RoomId) when is_list(RoomId) ->
    list_to_atom("chat_room_" ++ RoomId).

%% gen_server Callbacks

init([]) ->
    Node = node(),
    Dir = application:get_env(mnesia, dir, "Mnesia." ++ atom_to_list(Node)),
    case filelib:ensure_dir(filename:join(Dir, "schema.DAT")) of
        ok ->
            ok;
        {error, _} ->
            LocalDir = "./mnesia_data",
            error_logger:warning_msg("Could not create configured Mnesia directory ~s. Falling back to ~s~n", [Dir, LocalDir]),
            ok = filelib:ensure_dir(filename:join(LocalDir, "schema.DAT")),
            application:set_env(mnesia, dir, LocalDir)
    end,
    _ = mnesia:stop(),
    case mnesia:create_schema([Node]) of
        ok -> error_logger:info_msg("Mnesia database schema created successfully~n");
        {error, {Node, {already_exists, Node}}} -> ok
    end,
    ok = mnesia:start(),

    % Create tables with disc_copies configuration for PVC durability
    case mnesia:create_table(chat_message, [
        {disc_copies, [Node]},
        {attributes, record_info(fields, chat_message)},
        {type, ordered_set}
    ]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, chat_message}} -> ok
    end,

    case mnesia:create_table(room_state, [
        {disc_copies, [Node]},
        {attributes, record_info(fields, room_state)},
        {type, set}
    ]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, room_state}} -> ok
    end,

    ok = mnesia:wait_for_tables([chat_message, room_state], 5000),
    {ok, #state{}}.

handle_call({save_message, RoomId, Sender, Text, Timestamp}, _From, State) ->
    Record = #chat_message{
        id = {RoomId, Timestamp},
        room_id = RoomId,
        sender = Sender,
        text = Text
    },
    WriteFun = fun() -> mnesia:write(Record) end,
    case mnesia:transaction(WriteFun) of
        {atomic, ok} -> {reply, ok, State};
        {aborted, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({get_messages, RoomId}, _From, State) ->
    MatchFun = fun() ->
        MatchHead = #chat_message{room_id = RoomId, _ = '_'},
        mnesia:match_object(MatchHead)
    end,
    case mnesia:transaction(MatchFun) of
        {atomic, List} ->
            Sorted = lists:keysort(#chat_message.id, List),
            Formatted = [#{sender => S, text => T} || #chat_message{sender = S, text = T} <- Sorted],
            {reply, {ok, Formatted}, State};
        {aborted, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({save_room, RoomId, RoomState}, _From, State) ->
    Record = #room_state{
        room_id = RoomId,
        state_data = RoomState
    },
    WriteFun = fun() -> mnesia:write(Record) end,
    case mnesia:transaction(WriteFun) of
        {atomic, ok} -> {reply, ok, State};
        {aborted, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({get_room, RoomId}, _From, State) ->
    ReadFun = fun() -> mnesia:read(room_state, RoomId) end,
    case mnesia:transaction(ReadFun) of
        {atomic, [#room_state{state_data = RoomState}]} ->
            {reply, {ok, RoomState}, State};
        {atomic, []} ->
            {reply, {error, not_found}, State};
        {aborted, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({create_room_table, RoomId}, _From, State) ->
    TableName = room_table_name(RoomId),
    Node = node(),
    Result = case mnesia:create_table(TableName, [
        {disc_copies, [Node]},
        {attributes, record_info(fields, chat_message)},
        {type, ordered_set}
    ]) of
        {atomic, ok} ->
            ok = mnesia:wait_for_tables([TableName], 5000),
            ok;
        {aborted, {already_exists, TableName}} ->
            ok = mnesia:wait_for_tables([TableName], 5000),
            ok;
        {aborted, Reason} ->
            {error, Reason}
    end,
    {reply, Result, State};

handle_call({save_message_to_room, RoomId, Sender, Text, Timestamp}, _From, State) ->
    TableName = room_table_name(RoomId),
    RoomIdBin = case is_binary(RoomId) of true -> RoomId; false -> list_to_binary(RoomId) end,
    Record = #chat_message{
        id = {RoomIdBin, Timestamp},
        room_id = RoomIdBin,
        sender = case is_binary(Sender) of true -> Sender; false -> list_to_binary(Sender) end,
        text = case is_binary(Text) of true -> Text; false -> list_to_binary(Text) end
    },
    Tuple = setelement(1, Record, TableName),
    WriteFun = fun() -> mnesia:write(TableName, Tuple, write) end,
    case mnesia:transaction(WriteFun) of
        {atomic, ok} -> {reply, ok, State};
        {aborted, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({get_messages_from_room, RoomId}, _From, State) ->
    TableName = room_table_name(RoomId),
    ReadFun = fun() ->
        mnesia:select(TableName, [{'_', [], ['$_']}])
    end,
    case mnesia:transaction(ReadFun) of
        {atomic, List} ->
            Formatted = [
                begin
                    Msg = setelement(1, Tuple, chat_message),
                    #{sender => Msg#chat_message.sender, text => Msg#chat_message.text}
                end
                || Tuple <- List
            ],
            {reply, {ok, Formatted}, State};
        {aborted, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    mnesia:stop(),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
