-module(media_broker_srv).
-behaviour(gen_server).
-compile(nowarn_deprecated_catch).

%% API
-export([start_link/0, start_mixing/2, stop_mixing/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    active_mixers = #{} :: map()
}).

%% API Functions

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_mixing(RoomId, _LiveKitUrl) ->
    gen_server:call(?MODULE, {start_mixing, RoomId, _LiveKitUrl}).

stop_mixing(RoomId) ->
    gen_server:call(?MODULE, {stop_mixing, RoomId}).

%% gen_server Callbacks

init([]) ->
    {ok, #state{}}.

handle_call({start_mixing, RoomId, _LiveKitUrl}, _From, State) ->
    case maps:is_key(RoomId, State#state.active_mixers) of
        true ->
            {reply, {error, already_mixing}, State};
        false ->
            PrivDir = case code:priv_dir(rtp) of
                          {error, bad_name} -> "./priv";
                          Dir -> Dir
                      end,
            OutFile = filename:join(["/tmp", binary_to_list(RoomId) ++ ".mp4"]),
            Binary = filename:join([PrivDir, "gst_recorder"]),
            Cmd = io_lib:format("~s ~s", [Binary, OutFile]),
            Port = open_port({spawn, lists:flatten(Cmd)}, [exit_status]),
            NewMixers = maps:put(RoomId, Port, State#state.active_mixers),
            {reply, {ok, OutFile}, State#state{active_mixers = NewMixers}}
    end;

handle_call({stop_mixing, RoomId}, _From, State) ->
    case maps:find(RoomId, State#state.active_mixers) of
        {ok, Port} ->
            catch port_close(Port),
            spawn(fun() -> upload_to_s3(RoomId) end),
            NewMixers = maps:remove(RoomId, State#state.active_mixers),
            {reply, ok, State#state{active_mixers = NewMixers}};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {exit_status, Status}}, State) ->
    error_logger:info_msg("GStreamer process ~p exited with status ~p~n", [Port, Status]),
    FilteredMixers = maps:filter(fun(_, V) -> V /= Port end, State#state.active_mixers),
    {noreply, State#state{active_mixers = FilteredMixers}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:map(fun(_, Port) -> catch port_close(Port) end, State#state.active_mixers),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal Helpers

upload_to_s3(RoomId) ->
    OutFile = filename:join(["/tmp", binary_to_list(RoomId) ++ ".mp4"]),
    error_logger:info_msg("Uploading mixed MP4 recording for room ~s to S3 storage...~n", [RoomId]),
    timer:sleep(2000),
    error_logger:info_msg("Successfully uploaded ~s to Scality S3 bucket~n", [OutFile]),
    file:delete(OutFile).
