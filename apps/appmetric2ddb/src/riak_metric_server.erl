%%%-------------------------------------------------------------------
%%% @author neerajsharma
%%% @copyright (C) 2017, neeraj.sharma@alumni.iitg.ernet.in
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(riak_metric_server).
-author("neerajsharma").

-behaviour(gen_server).

-include("appmetric2ddb.hrl").

%% ignore unused function warning because the function
%% receive_riak_metrics is invoked in a separate
%% process.
-compile({nowarn_unused_function, [receive_riak_metrics/2,
                                   get_riak_stats/1,
                                   http_get_url/2]}).

%% API
-export([start_link/1]).
-export([receive_riak_metrics/2]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-define(HTTP_TIMEOUT_MSEC, 2000).
-define(HTTP_CONNECT_TIMEOUT_MSEC, 1000).

-record(state, {
    ddb_host :: undefined,
    ddb_port :: undefined | pos_integer(),
    bucket :: binary(),
    riak_host :: inet:ip_address() | inet:hostname(),
    riak_port :: pos_integer(),
    riak_base_url :: string(),
    ref :: reference(),
    interval = 1000 :: pos_integer(),
    peer_refresh_pid = undefined :: undefined | pid(),
    ddb = undefined
}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(integer()) ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Index) ->
    lager:info("~p Index=~p", [?SERVER, Index]),
    {ok, DdbConfig} = application:get_env(?CORE_APPLICATION_NAME, ddbconfig),
    lager:info("~p DdbConfig=~p", [?SERVER, DdbConfig]),
    RiakConfig = lists:nth(Index, proplists:get_value(riak, DdbConfig)),
    Name = proplists:get_value(name, RiakConfig),
    lager:info("~p starting actor ~p", [?SERVER, Name]),
    gen_server:start_link({local, Name}, ?MODULE, [DdbConfig, RiakConfig], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([DdbConfig, RiakConfig]) ->
    process_flag(trap_exit, true),
    lager:info("~p DdbConfig=~p, RiakConfig=~p", [?SERVER, DdbConfig, RiakConfig]),
    case proplists:get_value(enabled, DdbConfig, false) of
        true ->
            {DDBHost, DDBPort} = proplists:get_value(
                endpoint, DdbConfig),
            DDBBucketS = proplists:get_value(bucket, RiakConfig),
            DDBBucket = list_to_binary(DDBBucketS),
            {RiakHost, RiakPort} = proplists:get_value(
                riak_endpoint, RiakConfig),
            RiakBaseUrl = lists:flatten(io_lib:format("http://~s:~p", [RiakHost, RiakPort])),
            IntervalMsec = proplists:get_value(interval, RiakConfig),
            {ok, #state{interval = IntervalMsec, bucket = DDBBucket,
                ddb_host = DDBHost, ddb_port = DDBPort,
                riak_host = RiakHost, riak_port = RiakPort,
                riak_base_url = RiakBaseUrl},
                0};
        false -> {ok, #state{}}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast({riak, ProplistMetrics} = _Request,
    #state{interval = IntervalMsec, bucket = DDBBucket,
        ddb_host = DDBHost, ddb_port = DDBPort,
        ddb = DDB} = State) ->
    lager:debug("handle_cast(~p, ~p)", [_Request, State]),
    case try_connect(DDB, DDBHost, DDBPort, DDBBucket, IntervalMsec) of
        {ok, DDB1} ->
            TimeSec = erlang:system_time(second),
            [{stats, StatsInfo}] = ProplistMetrics,
            {_, DDB2} = ddb_tcp:batch_start(TimeSec, DDB1),
            DDB3 = lists:foldl(fun({Node, MapMetrics}, AccIn) ->
                lists:foldl(fun({Name, Value}, AccIn2) ->
                    ddb_send([<<"riak">>, <<"stats">>, Name, <<"node=", Node/binary>>], Value, AccIn2)
                    end, AccIn, maps:to_list(MapMetrics))
                end, DDB2, maps:to_list(StatsInfo)),
            {_, DDB4} = ddb_tcp:batch_end(DDB3),
            {noreply, State#state{ddb = DDB4}};
        _ ->
            {noreply, State}
    end;
handle_cast(_Request, State) ->
    lager:debug("handle_cast(~p, ~p)", [_Request, State]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info({timeout, _R, tick} = _Info,
    #state{ref = _R, interval = FlushInterval,
        riak_base_url = RiakBaseUrl,
        peer_refresh_pid = PeerRefreshPid} = State) ->
    lager:debug("handle_info(~p, ~p)", [_Info, State]),
    lager:debug("PeerRefreshPid=~p", [PeerRefreshPid]),
    NewPeerRefreshPid = case is_pid(PeerRefreshPid) of
                            true ->
                                case is_process_alive(PeerRefreshPid) of
                                    true ->
                                        PeerRefreshPid;
                                    false ->
                                        spawn_link(?MODULE,
                                            receive_riak_metrics,
                                            [RiakBaseUrl, self()])
                                end;
                            _ ->
                                spawn_link(?MODULE,
                                    receive_riak_metrics,
                                    [RiakBaseUrl, self()])
                            end,
    Ref = erlang:start_timer(FlushInterval, self(), tick),
    {noreply, State#state{ref = Ref,
        peer_refresh_pid = NewPeerRefreshPid}};
handle_info(timeout, State = #state{interval = IntervalMsec,
    riak_base_url = RiakBaseUrl}) ->
    lager:debug("handle_info(~p, ~p)", [timeout, State]),
    lager:debug("starting tick timer"),
    %% refresh the list immediately for local caching
    PeerRefreshPid = spawn_link(node(), ?MODULE, receive_riak_metrics,
        [RiakBaseUrl, self()]),
    Ref = erlang:start_timer(IntervalMsec, self(), tick),
    {noreply, State#state{ref = Ref,
        peer_refresh_pid = PeerRefreshPid}};
handle_info({'EXIT', PeerRefreshPid, _} = _Info,
    #state{peer_refresh_pid = PeerRefreshPid} = State) ->
    lager:debug("handle_info(~p, ~p)", [_Info, State]),
    {noreply, State#state{peer_refresh_pid = undefined}};
handle_info({TcpEvent, _Socket}, State = #state{
    ddb = DDB, ddb_host = Host, ddb_port = Port, interval = IntervalMsec, bucket = Bucket})
    when TcpEvent == tcp_closed orelse TcpEvent == tcp_error ->
    %% Can validate that the socket is indeed of DDB,
    %% but for now lets just close DDB (just in case)
    ddb_tcp:close(DDB),
    case connect(Host, Port, Bucket, IntervalMsec) of
        {ok, DDB1} ->
            %% Timer is already running, so do not touch that
            {noreply, State#state{ddb = DDB1}};
        {error, _Reason} ->
            {noreply, State#state{ddb = undefined}}
    end;
handle_info(_Info, State) ->
    lager:debug("handle_info(~p, ~p)", [_Info, State]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, #state{ddb = DDB} = _State) ->
    close_ddb(DDB),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

receive_riak_metrics(RiakBaseUrl, CallbackPid) ->
    StatsInfo = get_riak_stats(RiakBaseUrl),
    R = [{stats, StatsInfo}],
    gen_server:cast(CallbackPid, {riak, R}).


%%%===================================================================
%%% Internal functions
%%%===================================================================

get_riak_stats(RiakBaseUrl) ->
    case http_get_url("/stats", RiakBaseUrl) of
        {ok, {{_, 200, _}, _, Body}} ->
            Maps = jsone:decode(Body, [{object_format, map}]),
            SelectedMaps = [maps:with([
                <<"nodename">>,
                <<"node_gets">>, <<"node_puts">>,
                <<"vnode_counter_update">>, <<"vnode_set_update">>,
                <<"vnode_map_update">>, <<"search_query_throughput_one">>,
                <<"search_index_throughtput_one">>, <<"consistent_gets">>,
                <<"consistent_puts">>, <<"vnode_index_reads">>,
                %% latency metrics
                <<"node_get_fsm_time_mean">>, <<"node_get_fsm_time_99">>,
                <<"node_put_fsm_time_mean">>, <<"node_put_fsm_time_99">>,
                <<"object_counter_merge_time_mean">>, <<"object_counter_merge_time_99">>,
                <<"object_set_merge_time_mean">>, <<"object_set_merge_time_99">>,
                <<"object_map_merge_time_mean">>, <<"object_map_merge_time_99">>,
                <<"search_query_latency_median">>, <<"search_query_latency_99">>,
                <<"search_index_latency_median">>, <<"search_index_latency_99">>,
                <<"consistent_get_time_mean">>, <<"consistent_get_time_99">>,
                <<"consistent_put_time_mean">>, <<"consistent_put_time_99">>,
                %% Erlang resource usage metrics
                <<"sys_process_count">>, <<"memory_processes">>,
                <<"memory_processes_used">>,
                %% General load health
                <<"node_get_fsm_siblings_mean">>, <<"node_get_fsm_siblings_99">>,
                <<"node_get_fsm_objsize_mean">>, <<"node_get_fsm_objsize_99">>,
                <<"riak_search_vnodeq_mean">>, <<"riak_search_vnodeq_99">>,
                <<"search_index_fail_one">>, <<"pbc_active">>,
                <<"pbc_connects">>, <<"read_repairs">>,
                <<"list_fsm_active">>, <<"node_get_fsm_rejected">>,
                <<"node_put_fsm_rejected">>,
                %% General search load metrics
                <<"search_index_bad_entry_count">>, <<"search_index_bad_entry_one">>,
                <<"search_index_extract_fail_count">>, <<"search_index_extract_fail_one">>
                ], X) || X <- Maps],
            lists:foldl(fun(E, AccIn) ->
                #{<<"nodename">> := Name} = E,
                EWithout = maps:without([<<"nodename">>], E),
                AccIn#{Name => EWithout}
                        end, #{}, SelectedMaps);
        E ->
            lager:error("Error, E=~p", [E]),
            undefined
    end.

-spec http_get_url(Path :: string(), RiakBaseUrl :: string()) ->
    {ok, {Status :: term(), Header :: list(), Body :: string()}} |
    {error, {term(), term()}}.
http_get_url(Path, RiakBaseUrl) ->
    HTTPOptions = [{timeout, ?HTTP_TIMEOUT_MSEC}, {connect_timeout, ?HTTP_CONNECT_TIMEOUT_MSEC}],
    Options = [{body_format, binary}],
    try
        httpc:request(get, {RiakBaseUrl ++ Path, []}, HTTPOptions, Options)
    catch
        Class:Error ->
            lager:error("http failure, Class=~p, Error=~p", [Class, Error]),
            {error, {Class, Error}}
    end.

-spec try_connect(DDB :: ddb_tcp:connection(),
    Host :: inet:ip_address() | inet:hostname(),
    Port :: inet:port_number(), Bucket :: binary(),
    IntervalMsec :: pos_integer()) ->
    {ok, ddb_tcp:connection()} | {error, ddb_tcp:connection()}.
try_connect(undefined, Host, Port, Bucket, IntervalMsec) ->
    connect(Host, Port, Bucket, IntervalMsec);
try_connect(DDB, Host, Port, Bucket, IntervalMsec) ->
    case ddb_tcp:connected(DDB) of
        true ->
            {ok, DDB};
        false ->
            connect(Host, Port, Bucket, IntervalMsec)
    end.

-spec connect(Host :: inet:ip_address() | inet:hostname(),
    Port :: inet:port_number(), Bucket :: binary(),
    IntervalMsec :: pos_integer()) ->
    {ok, ddb_tcp:connection()} | {error, ddb_tcp:connection()}.
connect(Host, Port, Bucket, IntervalMsec) ->
    {ok, DDB} = ddb_tcp:connect(Host, Port),
    case ddb_tcp:connected(DDB) of
        true ->
            case ddb_tcp:stream_mode(Bucket, IntervalMsec div 1000, DDB) of
                {ok, DDBx} ->
                    {ok, DDBx};
                {error, _, DDBx} ->
                    {ok, DDBx}
            end;
        false -> {error, DDB}
    end.

close_ddb(undefined) ->
    undefined;
close_ddb(DDB) ->
    ddb_tcp:close(DDB).

-spec ddb_send(Metric :: list(binary()), Value :: integer() | float(),
    DDB :: ddb_tcp:connection()) -> ddb_tcp:connection().
ddb_send(Metric, true, DDB) ->
    {_, DDB1} = ddb_tcp:batch(Metric, mmath_bin:from_list([1]), DDB),
    DDB1;
ddb_send(Metric, false, DDB) ->
    {_, DDB1} = ddb_tcp:batch(Metric, mmath_bin:from_list([0]), DDB),
    DDB1;
ddb_send(Metric, Value, DDB) when is_integer(Value) ->
    {_, DDB1} = ddb_tcp:batch(Metric, mmath_bin:from_list([Value]), DDB),
    DDB1;
ddb_send(Metric, Value, DDB) when is_float(Value) ->
    RoundedValue = round(Value * 100) / 100,
    {_, DDB1} = ddb_tcp:batch(Metric, mmath_bin:from_list([RoundedValue]), DDB),
    DDB1.
