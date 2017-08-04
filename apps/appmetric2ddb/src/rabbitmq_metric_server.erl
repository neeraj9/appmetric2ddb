%%%-------------------------------------------------------------------
%%% @author neerajsharma
%%% @copyright (C) 2017, neeraj.sharma@alumni.iitg.ernet.in
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(rabbitmq_metric_server).
-author("neerajsharma").

-behaviour(gen_server).

-include("appmetric2ddb.hrl").

%% API
-export([start_link/1]).

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
    rmq_host :: inet:ip_address() | inet:hostname(),
    rmq_port :: pos_integer(),
    rmq_user :: binary(),
    rmq_password :: binary(),
    rmq_base_url :: string(),
    rmq_http_basic_auth :: string(),
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
    RabbitMqConfig = lists:nth(Index, proplists:get_value(rabbitmq, DdbConfig)),
    Name = proplists:get_value(name, RabbitMqConfig),
    lager:info("~p starting actor ~p", [?SERVER, Name]),
    gen_server:start_link({local, Name}, ?MODULE, [DdbConfig, RabbitMqConfig], []).

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
init([DdbConfig, RabbitMqConfig]) ->
    process_flag(trap_exit, true),
    lager:info("~p DdbConfig=~p, RabbitMqConfig=~p", [?SERVER, DdbConfig, RabbitMqConfig]),
    case proplists:get_value(enabled, DdbConfig, false) of
        true ->
            {DDBHost, DDBPort} = proplists:get_value(
                endpoint, DdbConfig),
            DDBBucketS = proplists:get_value(bucket, RabbitMqConfig),
            DDBBucket = list_to_binary(DDBBucketS),
            {RmqHost, RmqPort} = proplists:get_value(
                rmq_endpoint, RabbitMqConfig),
            RmqUser = list_to_binary(proplists:get_value(rmq_user, RabbitMqConfig)),
            RmqPassword = list_to_binary(proplists:get_value(rmq_password, RabbitMqConfig)),
            RmqBaseUrl = io_lib:format("http://~p:~p", [RmqHost, RmqPort]),
            RmqHttpBasicAuth = "Basic " ++ base64:encode_to_string(RmqUser ++ ":" ++ RmqPassword),
            IntervalMsec = proplists:get_value(interval, RabbitMqConfig),
            {ok, #state{interval = IntervalMsec, bucket = DDBBucket,
                ddb_host = DDBHost, ddb_port = DDBPort,
                rmq_host = RmqHost, rmq_port = RmqPort,
                rmq_user = RmqUser, rmq_password = RmqPassword,
                rmq_base_url = RmqBaseUrl, rmq_http_basic_auth = RmqHttpBasicAuth},
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
handle_cast({rabbitmq, ProplistMetrics} = _Request,
    #state{interval = IntervalMsec, bucket = DDBBucket,
        ddb_host = DDBHost, ddb_port = DDBPort,
        ddb = DDB} = State) ->
    lager:debug("handle_cast(~p, ~p)", [_Request, State]),
    case try_connect(DDB, DDBHost, DDBPort, DDBBucket, IntervalMsec) of
        {ok, DDB1} ->
            TimeSec = erlang:system_time(second),
            [{nodes, NodesInfo}, {channels, ChannelsInfo}, {queues, QueuesInfo}] = ProplistMetrics,
            {_, DDB2} = ddb_tcp:batch_start(TimeSec, DDB1),
            DDB3 = lists:foldl(fun({Node, MapMetrics}, AccIn) ->
                lists:foldl(fun({Name, Value}, AccIn2) ->
                    ddb_send([<<"rmq">>, <<"nodes">>, Name, <<"node=", Node/binary>>], Value, AccIn2)
                    end, AccIn, maps:to_list(MapMetrics))
                end, DDB2, maps:to_list(NodesInfo)),
            DDB4 = lists:foldl(fun({{Node, PeerName}, MapMetrics}, AccIn) ->
                lists:foldl(fun({Name, Value}, AccIn2) ->
                    ddb_send([<<"rmq">>, <<"channels">>, Name, <<"node=", Node/binary>>, <<"rmq_peer=", PeerName/binary>>], Value, AccIn2)
                            end, AccIn, maps:to_list(MapMetrics))
                               end, DDB3, maps:to_list(ChannelsInfo)),
            DDB5 = lists:foldl(fun({{Node, QueueName}, MapMetrics}, AccIn) ->
                lists:foldl(fun({Name, Value}, AccIn2) ->
                    ddb_send([<<"rmq">>, <<"queues">>, Name, <<"node=", Node/binary>>, <<"rmq_queue=", QueueName/binary>>], Value, AccIn2)
                            end, AccIn, maps:to_list(MapMetrics))
                               end, DDB4, maps:to_list(QueuesInfo)),
            {_, DDB6} = ddb_tcp:batch_end(DDB5),
            {noreply, State#state{ddb = DDB6}};
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
        rmq_base_url = RmqBaseUrl, rmq_http_basic_auth = RmqHttpBasicAuth,
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
                                            fun receive_rabbitmq_metrics/3,
                                            [RmqBaseUrl, RmqHttpBasicAuth, self()])
                                end;
                            _ ->
                                spawn_link(?MODULE,
                                    fun receive_rabbitmq_metrics/3,
                                    [RmqBaseUrl, RmqHttpBasicAuth, self()])
                            end,
    Ref = erlang:start_timer(FlushInterval, self(), tick),
    {noreply, State#state{ref = Ref,
        peer_refresh_pid = NewPeerRefreshPid}};
handle_info(timeout, State = #state{interval = IntervalMsec,
    rmq_base_url = RmqBaseUrl, rmq_http_basic_auth = RmqHttpBasicAuth}) ->
    lager:debug("handle_info(~p, ~p)", [timeout, State]),
    lager:debug("starting tick timer"),
    %% refresh the list immediately for local caching
    PeerRefreshPid = spawn_link(node(), ?MODULE, fun receive_rabbitmq_metrics/3,
        [RmqBaseUrl, RmqHttpBasicAuth, self()]),
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
        {error, Reason} ->
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

%%%===================================================================
%%% Internal functions
%%%===================================================================

receive_rabbitmq_metrics(RmqBaseUrl, RmqHttpBasicAuth, CallbackPid) ->
    NodesInfo = get_rabbitmq_nodes_info(RmqBaseUrl, RmqHttpBasicAuth),
    ChannelsInfo = get_rabbitmq_channels_info(RmqBaseUrl, RmqHttpBasicAuth),
    QueuesInfo = get_rabbitmq_queues_info(RmqBaseUrl, RmqHttpBasicAuth),
    R = [{nodes, NodesInfo}, {channels, ChannelsInfo}, {queues, QueuesInfo}],
    gen_server:cast(CallbackPid, {rabbitmq, R}).


get_rabbitmq_nodes_info(RmqBaseUrl, RmqHttpBasicAuth) ->
    case http_get_url("/api/nodes", RmqBaseUrl, RmqHttpBasicAuth) of
        {ok, {{_, 200, _}, _, Body}} ->
            Maps = jsone:decode(Body, [{object_format, map}]),
            SelectedMaps = [maps:with([
                <<"name">>,
                <<"running">>, <<"fd_used">>,
                <<"fd_total">>, <<"sockets_used">>, <<"sockets_total">>,
                <<"mem_used">>, <<"mem_limit">>, <<"disk_free_limit">>,
                <<"disk_free">>, <<"proc_used">>, <<"proc_total">>,
                <<"uptime">>, <<"run_queue">>, <<"processors">>], X)
                || X <- Maps],
            lists:foldl(fun(E, AccIn) ->
                #{<<"name">> := Name, <<"uptime">> := UptimeMsec} = E,
                EWithout = maps:without([<<"name">>, <<"uptime">>], E),
                UptimeDays = UptimeMsec / (24 * 60 * 60 * 1000),
                UptimeHours = UptimeMsec / (60 * 60 * 1000),
                UptimeMins = UptimeMsec / (60 * 1000),
                AccIn#{Name => EWithout#{
                    <<"uptime_days">> => UptimeDays,
                    <<"uptime_hours">> => UptimeHours,
                    <<"uptime_mins">> => UptimeMins}}
                        end, #{}, SelectedMaps);
        _ -> undefined
    end.

get_rabbitmq_channels_info(RmqBaseUrl, RmqHttpBasicAuth) ->
    case http_get_url("/api/channels", RmqBaseUrl, RmqHttpBasicAuth) of
        {ok, {{_, 200, _}, _, Body}} ->
            CurrentEpocSec = erlang:system_time(second),
            Maps = jsone:decode(Body, [{object_format, map}]),
            %% Aggregate metrics per peer_host (ip address but independent of port)
            lists:foldl(fun(E, AccIn) ->
                Peer = maps:get(<<"peer_host">>, maps:get(<<"connection_details">>, E, #{}), undefined),
                Node = maps:get(<<"node">>, E, undefined),
                Info = maps:with([<<"consumer_count">>, <<"messages_unacknowledged">>,
                    <<"messages_unconfirmed">>, <<"messages_uncommitted">>,
                    <<"acks_uncommitted">>, <<"prefetch_count">>], E),
                MessageStats = maps:get(<<"message_stats">>, E, #{}),
                Publish = maps:get(<<"publish">>, MessageStats, 0),
                PublishRate = maps:get(<<"rate">>, maps:get(<<"publish_details">>, MessageStats, #{}), 0.0),
                Ack = maps:get(<<"ack">>, MessageStats, 0),
                AckRate = maps:get(<<"rate">>, maps:get(<<"ack_details">>, MessageStats, #{}), 0.0),
                Deliver = maps:get(<<"deliver">>, MessageStats, 0),
                DeliverRate = maps:get(<<"rate">>, maps:get(<<"deliver_details">>, MessageStats, #{}), 0.0),
                DeliverGet = maps:get(<<"deliver_get">>, MessageStats, 0),
                DeliverGetRate = maps:get(<<"rate">>, maps:get(<<"deliver_get_details">>, MessageStats, #{}), 0.0),
                IdleSinceEpocSec = qdate:to_unixtime(maps:get(<<"idle_since">>, E)),
                MetricInfo = Info#{
                    <<"publish">> => Publish, <<"publish_rate">> => PublishRate,
                    <<"ack">> => Ack, <<"ack_rate">> => AckRate,
                    <<"deliver">> => Deliver, <<"deliver_rate">> => DeliverRate,
                    <<"deliver_get">> => DeliverGet, <<"deliver_get_rate">> => DeliverGetRate,
                    <<"idle_since_sec">> => CurrentEpocSec - IdleSinceEpocSec},
                OldMetricInfo = maps:get({Node, Peer}, AccIn, #{}),
                UpdatedMetricInfo = maps:fold(fun(K, V, AccIn2) ->
                    case maps:get(K, AccIn2, undefined) of
                        undefined -> AccIn2#{K => V};
                        V2 -> AccIn2#{K => V + V2}
                    end
                    end, MetricInfo, OldMetricInfo),
                AccIn#{{Node, Peer} => UpdatedMetricInfo}
                end, #{}, Maps);
        _ -> undefined
    end.

get_rabbitmq_queues_info(RmqBaseUrl, RmqHttpBasicAuth) ->
    case http_get_url("/api/queues", RmqBaseUrl, RmqHttpBasicAuth) of
        {ok, {{_, 200, _}, _, Body}} ->
            CurrentEpocSec = erlang:system_time(second),
            Maps = jsone:decode(Body, [{object_format, map}]),
            %% get metrics per queue
            lists:foldl(fun(E, AccIn) ->
                Name = maps:get(<<"name">>, E, undefined),
                Node = maps:get(<<"node">>, E, undefined),
                Info = maps:with([<<"memory">>, <<"messages">>,
                    <<"messages_ready">>, <<"messages_unacknowledged">>,
                    <<"consumers">>], E),
                MessageStats = maps:get(<<"message_stats">>, E, #{}),
                Publish = maps:get(<<"publish">>, MessageStats, 0),
                PublishRate = maps:get(<<"rate">>, maps:get(<<"publish_details">>, MessageStats, #{}), 0.0),
                Ack = maps:get(<<"ack">>, MessageStats, 0),
                AckRate = maps:get(<<"rate">>, maps:get(<<"ack_details">>, MessageStats, #{}), 0.0),
                Deliver = maps:get(<<"deliver">>, MessageStats, 0),
                DeliverRate = maps:get(<<"rate">>, maps:get(<<"deliver_details">>, MessageStats, #{}), 0.0),
                DeliverGet = maps:get(<<"deliver_get">>, MessageStats, 0),
                DeliverGetRate = maps:get(<<"rate">>, maps:get(<<"deliver_get_details">>, MessageStats, #{}), 0.0),
                Get = maps:get(<<"get">>, MessageStats, 0),
                GetRate = maps:get(<<"rate">>, maps:get(<<"get_details">>, MessageStats, #{}), 0.0),
                Redeliver = maps:get(<<"redeliver">>, MessageStats, 0),
                RedeliverRate = maps:get(<<"rate">>, maps:get(<<"redeliver_details">>, MessageStats, #{}), 0.0),
                IdleSinceEpocSec = qdate:to_unixtime(maps:get(<<"idle_since">>, E)),
                BackingQueueStatus = maps:get(<<"backing_queue_status">>, E),
                #{
                    <<"bqs_q1">> := BqsQ1,
                    <<"bqs_q2">> := BqsQ2,
                    <<"bqs_q3">> := BqsQ3,
                    <<"bqs_q4">> := BqsQ4,
                    <<"bqs_len">> := BqsLen,
                    <<"bqs_pending_acks">> := BqsPendingAcks,
                    <<"bqs_ram_msg_count">> := BqsRamMsgCount,
                    <<"bqs_ram_ack_count">> := BqsRamAckCount,
                    <<"bqs_next_seq_id">> := BqsNextSeqId,
                    <<"bqs_persistent_count">> := BqsPersistentCount,
                    <<"bqs_avg_ingress_rate">> := BqsAvgIngressRate,
                    <<"bqs_avg_egress_rate">> := BqsAvgEgressRate,
                    <<"bqs_avg_ack_ingress_rate">> := BqsAvgAckIngressRate,
                    <<"bqs_avg_ack_egress_rate">> := BqsAvgAckEgressRate
                } = BackingQueueStatus,
                MetricInfo = Info#{
                    <<"publish">> => Publish, <<"publish_rate">> => PublishRate,
                    <<"ack">> => Ack, <<"ack_rate">> => AckRate,
                    <<"deliver">> => Deliver, <<"deliver_rate">> => DeliverRate,
                    <<"deliver_get">> => DeliverGet, <<"deliver_get_rate">> => DeliverGetRate,
                    <<"get">> => Get, <<"get_rate">> => GetRate,
                    <<"redeliver">> => Redeliver, <<"redeliver_rate">> => RedeliverRate,
                    <<"idle_since_sec">> => CurrentEpocSec - IdleSinceEpocSec,
                    <<"bqs_q1">> => BqsQ1,
                    <<"bqs_q2">> => BqsQ2,
                    <<"bqs_q3">> => BqsQ3,
                    <<"bqs_q4">> => BqsQ4,
                    <<"bqs_len">> => BqsLen,
                    <<"bqs_pending_acks">> => BqsPendingAcks,
                    <<"bqs_ram_msg_count">> => BqsRamMsgCount,
                    <<"bqs_ram_ack_count">> => BqsRamAckCount,
                    <<"bqs_next_seq_id">> => BqsNextSeqId,
                    <<"bqs_persistent_count">> => BqsPersistentCount,
                    <<"bqs_avg_ingress_rate">> => BqsAvgIngressRate,
                    <<"bqs_avg_egress_rate">> => BqsAvgEgressRate,
                    <<"bqs_avg_ack_ingress_rate">> => BqsAvgAckIngressRate,
                    <<"bqs_avg_ack_egress_rate">> => BqsAvgAckEgressRate},
                AccIn#{{Node, Name} => MetricInfo}
                        end, #{}, Maps);
        _ -> undefined
    end.


-spec http_get_url(Path, RmqBaseUrl, RmqHttpBasicAuth) ->
    {ok, {Status :: term(), Header :: list(), Body :: string()}} |
    {error, {term(), term()}}.
http_get_url(Path, RmqBaseUrl, RmqHttpBasicAuth) ->
    HTTPOptions = [{timeout, ?HTTP_TIMEOUT_MSEC}, {connect_timeout, ?HTTP_CONNECT_TIMEOUT_MSEC}],
    Options = [{body_format, binary}],
    try
        httpc:request(get, {RmqBaseUrl ++ Path, [{"Authorization", RmqHttpBasicAuth}]}, HTTPOptions, Options)
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
ddb_send(Metric, Value, DDB) when is_integer(Value) ->
    {_, DDB1} = ddb_tcp:batch(Metric, mmath_bin:from_list([Value]), DDB),
    DDB1;
ddb_send(Metric, Value, DDB) when is_float(Value) ->
    RoundedValue = round(Value * 100) / 100,
    {_, DDB1} = ddb_tcp:batch(Metric, mmath_bin:from_list([RoundedValue]), DDB),
    DDB1.