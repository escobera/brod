%%%
%%%   Copyright (c) 2019 Klarna Bank AB (publ)
%%%
%%%   Licensed under the Apache License, Version 2.0 (the "License");
%%%   you may not use this file except in compliance with the License.
%%%   You may obtain a copy of the License at
%%%
%%%       http://www.apache.org/licenses/LICENSE-2.0
%%%
%%%   Unless required by applicable law or agreed to in writing, software
%%%   distributed under the License is distributed on an "AS IS" BASIS,
%%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%   See the License for the specific language governing permissions and
%%%   limitations under the License.
%%%

-module(brod_group_subscriber_v2).

-behaviour(gen_server).

-behaviour(brod_group_member).

%% API:
-export([ ack/4
        , commit/4
        , start_link/1
        , stop/1
        ]).

%% brod_group_coordinator callbacks
-export([ get_committed_offsets/2
        , assignments_received/4
        , assignments_revoked/1
        , assign_partitions/3
        ]).

%% gen_server callbacks
-export([ handle_call/3
        , handle_cast/2
        , handle_info/2
        , init/1
        , terminate/2
        ]).

-export_type([ init_info/0
             , subscriber_config/0
             , commit_fun/0
             ]).

-include("brod_int.hrl").

-type subscriber_config() ::
        #{ client          := brod:client()
         , group_id        := brod:group_id()
         , topics          := [bord:topic()]
         , callback_module := module()
         , init_data       => term()
         , message_type    => message | message_set
         , consumer_config => brod:consumer_config()
         , group_config    => brod:group_config()
         }.

-type commit_fun() :: fun((brod:offset()) -> ok).

-type init_info() ::
        #{ group_id     := brod:group_id()
         , topic        := brod:topic()
         , partition    := brod:partition()
         , commit_fun   := commit_fun()
         }.

-type member_id() :: brod:group_member_id().

-callback init(brod_group_subscriber_v2:init_info(), _CbConfig) ->
  {ok, _State}.

-callback handle_message(brod:kafka_message(), State) ->
      {ok, commit, State}
    | {ok, ack, State}
    | {ok, State}.

%% Get committed offset (in case it is managed by the subscriber):
-callback get_committed_offset(State) ->
  {ok, brod:offset() | undefined, State}.

-define(DOWN(Reason), {down, brod_utils:os_time_utc_str(), Reason}).

-type worker() :: pid().

-type topic_partition() :: {brod:topic(), brod:partition()}.

-type workers() :: #{topic_partition() => workers()}.

-type committed_offsets() :: #{topic_partition() =>
                                 { brod:offset()
                                 , boolean()
                                 }}.

-record(state,
        { config                  :: subscriber_config()
        , group_id                :: brod:group_id()
        , coordinator             :: pid()
        , generation_id           :: integer() | ?undef
        , workers = #{}           :: workers()
        , committed_offsets = #{} :: committed_offsets()
        , cb_module               :: module()
        , cb_config               :: term()
        , client                  :: brod:client()
        }).

-type state() :: #state{}.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start (link) a group subscriber.
%% Client:
%%   Client ID (or pid, but not recommended) of the brod client.
%% GroupId:
%%   Consumer group ID which should be unique per kafka cluster
%% Topics:
%%   Predefined set of topic names to join the group.
%%   NOTE: The group leader member will collect topics from all members and
%%         assign all collected topic-partitions to members in the group.
%%         i.e. members can join with arbitrary set of topics.
%% GroupConfig:
%%   For group coordinator, @see brod_group_coordinator:start_link/5
%% ConsumerConfig:
%%   For partition consumer, @see brod_consumer:start_link/4
%% MessageType:
%%   The type of message that is going to be handled by the callback
%%   module. Can be either message or message set.
%% CbModule:
%%   Callback module which should have the callback functions
%%   implemented for message processing.
%% CbInitArg:
%%   The term() that is going to be passed to CbModule:init/1 when
%%   initializing the subscriger.
%% @end
-spec start_link(subscriber_config()) -> {ok, pid()} | {error, any()}.
start_link(Config) ->
  gen_server:start_link(?MODULE, Config, []).

%% @doc Stop group subscriber, wait for pid DOWN before return.
-spec stop(pid()) -> ok.
stop(Pid) ->
  Mref = erlang:monitor(process, Pid),
  ok = gen_server:cast(Pid, stop),
  receive
    {'DOWN', Mref, process, Pid, _Reason} ->
      ok
  end.

%% @doc Commit offset for a topic-partition, but don't commit it to
%% Kafka. This is an asynchronous call
-spec ack(pid(), brod:topic(), brod:partition(), brod:offset()) -> ok.
ack(Pid, Topic, Partition, Offset) ->
  gen_server:cast(Pid, {ack_offset, Topic, Partition, Offset}).

%% @doc Ack offset for a topic-partition. This is an asynchronous call
-spec commit(pid(), brod:topic(), brod:partition(), brod:offset()) -> ok.
commit(Pid, Topic, Partition, Offset) ->
  gen_server:cast(Pid, {commit_offset, Topic, Partition, Offset}).

%%%===================================================================
%%% group_coordinator callbacks
%%%===================================================================

%% @doc Called by group coordinator when there is new assignment received.
-spec assignments_received(pid(), member_id(), integer(),
                           brod:received_assignments()) -> ok.
assignments_received(Pid, MemberId, GenerationId, TopicAssignments) ->
  gen_server:cast(Pid, {new_assignments, MemberId,
                        GenerationId, TopicAssignments}).

%% @doc Called by group coordinator before re-joining the consumer group.
-spec assignments_revoked(pid()) -> ok.
assignments_revoked(Pid) ->
  gen_server:call(Pid, unsubscribe_all_partitions, infinity).

%% @doc Called by group coordinator when initializing the assignments
%% for subscriber.
%%
%% NOTE: This function is called only when `offset_commit_policy' is set to
%%       `consumer_managed' in group config.
%%
%% NOTE: The committed offsets should be the offsets for successfully processed
%%       (acknowledged) messages, not the `begin_offset' to start fetching from.
%% @end
-spec get_committed_offsets(pid(), [topic_partition()]) ->
        {ok, [{topic_partition(), brod:offset()}]}.
get_committed_offsets(Pid, TopicPartitions) ->
  gen_server:call(Pid, {get_committed_offsets, TopicPartitions}, infinity).

%% @doc This function is called only when `partition_assignment_strategy'
%% is set for `callback_implemented' in group config.
%% @end
-spec assign_partitions(pid(), [brod:group_member()],
                        [{brod:topic(), brod:partition()}]) ->
        [{member_id(), [brod:partition_assignment()]}].
assign_partitions(Pid, Members, TopicPartitionList) ->
  %% TODO: Not implemented
  Call = {assign_partitions, Members, TopicPartitionList},
  gen_server:call(Pid, Call, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initialize the server and start group coordinator
%% @end
%%--------------------------------------------------------------------
-spec init(subscriber_config()) -> {ok, state()}.
init(Config) ->
  process_flag(trap_exit, true),
  #{ client    := Client
   , group_id  := GroupId
   , topics    := Topics
   , cb_module := CbModule
   } = Config,
  DefaultGroupConfig = [],
  GroupConfig = maps:get(group_config, Config, DefaultGroupConfig),
  CbConfig = maps:get(init_data, Config, undefined),
  ok = brod_utils:assert_client(Client),
  ok = brod_utils:assert_group_id(GroupId),
  ok = brod_utils:assert_topics(Topics),
  {ok, Pid} = brod_group_coordinator:start_link( Client
                                               , GroupId
                                               , Topics
                                               , GroupConfig
                                               , ?MODULE
                                               , self()
                                               ),
  State = #state{ config      = Config
                , client      = Client
                , coordinator = Pid
                , cb_module   = CbModule
                , cb_config   = CbConfig
                , group_id    = GroupId
                },
  {ok, State}.

handle_call({get_committed_offsets, TopicPartitions}, _From,
            #state{ cb_module = CbModule
                  , workers   = Workers
                  } = State) ->
  Fun = fun(TopicPartition) ->
            case Workers of
              #{TopicPartition := Pid} ->
                case CbModule:get_committed_offset(Pid) of
                  Offset when is_integer(Offset) ->
                    {true, {TopicPartition, Offset}};
                  undefined ->
                    false
                end;
              _ ->
                false
            end
        end,
  Result = lists:filtermap(Fun, TopicPartitions),
  {reply, {ok, Result}, State};
handle_call(unsubscribe_all_partitions, _From,
            #state{ workers   = Workers
                  } = State) ->
  terminate_all_workers(Workers),
  {reply, ok, State#state{ workers = #{}
                         }};
handle_call(Call, _From, State) ->
  {reply, {error, {unknown_call, Call}}, State}.

%% @private
handle_cast({commit_offset, Topic, Partition, Offset}, State) ->
  #state{ coordinator   = Coordinator
        , generation_id = GenerationId
        } = State,
  %% Ask brod_consumer for more data:
  do_ack(Topic, Partition, Offset, State),
  %% Send an async message to group coordinator for offset commit:
  ok = brod_group_coordinator:ack( Coordinator
                                 , GenerationId
                                 , Topic
                                 , Partition
                                 , Offset
                                 ),
  {noreply, State};
handle_cast({ack_offset, Topic, Partition, Offset}, State) ->
  do_ack(Topic, Partition, Offset, State),
  {noreply, State};
handle_cast({new_assignments, MemberId, GenerationId, Assignments},
            #state{ config = Config
                  } = State0) ->
  %% Start worker processes:
  DefaultConsumerConfig = [],
  ConsumerConfig = maps:get( consumer_config
                           , Config
                           , DefaultConsumerConfig
                           ),
  State1 = State0#state{generation_id = GenerationId},
  State = lists:foldl( fun(Assignment, State_) ->
                           #brod_received_assignment
                             { topic        = Topic
                             , partition    = Partition
                             , begin_offset = BeginOffset
                             } = Assignment,
                           maybe_start_worker( MemberId
                                             , ConsumerConfig
                                             , Topic
                                             , Partition
                                             , BeginOffset
                                             , State_
                                             )
                       end
                     , State1
                     , Assignments
                     ),
  {noreply, State};
handle_cast(stop, State) ->
  {stop, normal, State};
handle_cast(_Cast, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
                     {noreply, NewState :: term()} |
                     {noreply, NewState :: term(), Timeout :: timeout()} |
                     {noreply, NewState :: term(), hibernate} |
                     {stop, Reason :: normal | term(), NewState :: term()}.
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Terminate all workers and brod consumers
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                State :: term()) -> any().
terminate(_Reason, #state{ workers = Workers
                         }) ->
  terminate_all_workers(Workers),
  ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec terminate_all_workers(workers()) -> ok.
terminate_all_workers(Workers) ->
  maps:map( fun(_, Worker) ->
                terminate_worker(Worker)
            end
          , Workers
          ),
  ok.

-spec terminate_worker(worker()) -> ok.
terminate_worker(WorkerPid) ->
  case is_process_alive(WorkerPid) of
    true ->
      brod_topic_subscriber:stop(WorkerPid);
    false ->
      ok
  end.

-spec maybe_start_worker( member_id()
                        , brod:consumer_config()
                        , brod:topic()
                        , brod:partition()
                        , brod:offset() | undefined
                        , state()
                        ) -> state().
maybe_start_worker( _MemberId
                  , ConsumerConfig
                  , Topic
                  , Partition
                  , BeginOffset
                  , State
                  ) ->
  #state{ workers   = Workers
        , client    = Client
        , cb_module = CbModule
        , cb_config = CbConfig
        , group_id  = GroupId
        } = State,
  TopicPartition = {Topic, Partition},
  case Workers of
    #{TopicPartition := _Worker} ->
      State;
    _ ->
      CommitFun = fun(Offset) ->
                      commit(self(), Topic, Partition, Offset)
                  end,
      StartOptions = #{ cb_module    => CbModule
                      , cb_config    => CbConfig
                      , partition    => Partition
                      , begin_offset => BeginOffset
                      , group_id     => GroupId
                      , commit_fun   => CommitFun
                      , topic        => Topic
                      },
      {ok, Pid} = start_worker( Client
                              , Topic
                              , Partition
                              , ConsumerConfig
                              , StartOptions
                              ),
      NewWorkers = Workers #{TopicPartition => Pid},
      State#state{workers = NewWorkers}
  end.

-spec start_worker( brod:client()
                  , brod:topic()
                  , brod:partition()
                  , brod:consumer_config()
                  , brod_group_subscriber_worker:start_options()
                  ) -> {ok, pid()}.
start_worker(Client, Topic, Partition, ConsumerConfig, StartOptions) ->
  brod_topic_subscriber:start_link( Client
                                  , Topic
                                  , [Partition]
                                  , ConsumerConfig
                                  , brod_group_subscriber_worker
                                  , StartOptions
                                  ).

-spec do_ack(brod:topic(), brod:partition(), brod:offset(), state()) ->
                ok | {error, term()}.
do_ack(Topic, Partition, Offset, #state{ workers = Workers
                                       }) ->
  TopicPartition = {Topic, Partition},
  case Workers of
    #{TopicPartition := Pid} ->
      brod_topic_subscriber:ack(Pid, Partition, Offset),
      ok;
    _ ->
      {error, unknown_topic_or_partition}
  end.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End: