-module(repl_property_test).

-export([confirm/0, make_load/2, verify_iteration/2]).
-include_lib("eunit/include/eunit.hrl").

-define(TEST_BUCKET, "riak-test-bucket").

%% @doc This test ensures validity of replication and garbage
%% collection, where all deleted data should be deleted under any type
%% of failure or race condition. This test may run for serveral or
%% infinite iterations (and also has a knob to notify otherwise)
%% 
%% Basic idea to verify the system is:
%%
%% 0. Set up 2x2 repl environment, unidirection (or should be bi?)
%% 1. run some workloads, including
%%   - Garbage collection batch
%%   - Replication fullsync, realtime
%%   - Fault or delay injection via intercepter or kill
%% 2. stop all workloads
%% 3. verify no orphan blocks remaining and all live data consistent
%% 4. back to 1.
%%
%% Configuration items for this test, in riak_test.config:
%%
%% {repl_property_test,
%%   [{iteration, non_neg_integer()|forever},
%%    {fault_injection, ??},
%%    {rtq_drop, ??}
%%    {notify, 'where to go?'},
%%    {bidirectional, boolean()}]},
%%
%% any other knobs described in code below;

-record(repl_property_test_config, {
          iteration = 1 :: non_neg_integer() | forever,
          fault_injection = false :: boolean(),
          rtq_drop_percentage = 0 :: non_neg_integer() ,
          notify = undefined :: undefined,
          bidirectional = false :: boolean()}).

repl_property_test_config() ->
    Config = rt_config:get(repl_property_test, []),
    lists:foldl(fun({iteration, I}, Prop) ->  Prop#repl_property_test_config{iteration=I};
                   (_, Prop) -> Prop end, #repl_property_test_config{}, Config).                         

confirm() ->
    %% Config = [{stanchion, rtcs:stanchion_config()},
    %%           {cs, rtcs:cs_config([{gc_interval, infinity}])}],
    {AdminConfig, {RiakNodes, CSNodes, Stanchion}} = rtcs:setup2x2(),
    % lager:info("UserConfig = ~p", [UserConfig]),
    [A,B,C,D] = RiakNodes,
    [CSSource, _, CSSink, _] = CSNodes,
    rt:setup_log_capture(CSSink),
    rt:setup_log_capture(CSSource),

    TestConfig = repl_property_test_config(),
    lager:info("repl_property_test configuraiton: ~p", [TestConfig]),

    SourceNodes = [A,B],
    SinkNodes = [C,D],
    lager:info("SourceNodes: ~p", [SourceNodes]),
    lager:info("SinkNodes: ~p", [SinkNodes]),

    [E, F, G, H] = CSNodes,
    _SourceCSNodes = [E, F],
    _SinkCSNodes = [G, H],

    SourceFirst = hd(SourceNodes),
    SinkFirst = hd(SinkNodes),

    SourceFirst = hd(SourceNodes),
    SinkFirst = hd(SinkNodes),

    %% Setup All replication here
    {ok, {SourceLeader, SinkLeader}} =
        repl_helpers:configure_all_repl(SourceNodes, "source",
                                        SinkNodes, "sink"),

    %{AccessKeyId, SecretAccessKey} = rtcs:create_user(SourceFirst, 1),
    %% User 1, Source config
    %SourceConfig = rtcs:config(AccessKeyId, SecretAccessKey, rtcs:cs_port(SourceFirst)),
    %% User 1, Sink config
    %_SinkConfig = rtcs:config(AccessKeyId, SecretAccessKey, rtcs:cs_port(SinkFirst)),

    History = 
        [{cs_suites, set_node1_version, [current]},
         {cs_suites, run,["1st"]}],

    {ok, InitialState} = cs_suites:new({AdminConfig,
                                        {RiakNodes, CSNodes, Stanchion}}),
    {ok, EvolvedState} = cs_suites:fold_with_state(InitialState, History),

    %% LeaderA = SourceLeader, _LeaderB = SinkLeader,
    repeat(EvolvedState, {SourceLeader, SinkLeader}, forever, 1).
           %% TestConfig#repl_property_test_config.iteration, 1).

make_load(SourceLeader, State) ->
    _UserConfig = cs_suites:admin_config(State),
    %% %% run an initial fullsync, 
    repl_helpers:start_and_wait_until_fullsync_complete13(SourceLeader),

    [SourceCSNode, _B,SinkCSNode, _D] = cs_suites:nodes_of(cs, State),
    %% %% wait for leeway
    timer:sleep(5000),
    %% Run GC in Sink side
    start_and_wait_for_gc(SourceCSNode),
    start_and_wait_for_gc(SinkCSNode),
    {ok, State}.

verify_iteration(_Leaders, State) ->
    _UserConfig = cs_suites:admin_config(State),
    [A, B, C, D] = cs_suites:nodes_of(riak, State),
    SourceNodes = [A, B],
    _SinkNodes = [C, D],
    %% Make sure no blocks are in Source side
    {ok, Keys0} = rc_helper:list_keys(SourceNodes, blocks, ?TEST_BUCKET),
    ?assertEqual([],
                 rc_helper:filter_tombstones(SourceNodes, blocks,
                                             ?TEST_BUCKET, Keys0)),
    
    %% Boom!!!!
    %% Make sure no blocks are in Sink side: will fail in Riak CS 2.0
    %% or older. Or turn on {delete_mode, keep}
    %% {ok, Keys1} = rc_helper:list_keys(SinkNodes, blocks, ?TEST_BUCKET),
    %% ?assertEqual([],
    %%              rc_helper:filter_tombstones(SinkNodes, blocks,
    %%                                          ?TEST_BUCKET, Keys1)),

    {ok, State}.

repeat(State, _, 0, _Count) ->
    {ok, _FinalState}  = cs_suites:cleanup(State),
    rtcs:pass();
repeat(State, Leaders = {SourceLeader, _SinkLeader}, Rest, Count) ->
    lager:info("Loop count: ~p remaining / ~p done", [Rest, Count]),

    Str = io_lib:format("~p-~p", [Rest, Count]),
    Repeat =
        [{cs_suites, run,[Str]},
         {?MODULE, make_load, [SourceLeader]},
         {?MODULE, verify_iteration, [Leaders]}],

    {ok, NextState} = cs_suites:fold_with_state(State, Repeat),
    NextRest = case Rest of
                    forever -> forever;
                    _ when is_integer(Rest) -> Rest - 1
                end,
    repeat(NextState, Leaders, NextRest, Count+1).

start_and_wait_for_gc(CSNode) ->
    rtcs:gc(rtcs:node_id(CSNode), "batch 1"),
    true = rt:expect_in_log(CSNode,
                            "Finished garbage collection: \\d+ seconds, "
                            "\\d+ batch_count, 0 batch_skips, "
                            "\\d+ manif_count, \\d+ block_count").

    %% lager:info("UserConfig ~p", [U1C1Config]),
    %% ?assertEqual([{buckets, []}], erlcloud_s3:list_buckets(U1C1Config)),

    %% lager:info("creating bucket ~p", [?TEST_BUCKET]),
    %% ?assertEqual(ok, erlcloud_s3:create_bucket(?TEST_BUCKET, U1C1Config)),

    %% ?assertMatch([{buckets, [[{name, ?TEST_BUCKET}, _]]}],
    %%              erlcloud_s3:list_buckets(U1C1Config)),

    %% Object1 = crypto:rand_bytes(4194304),

    %% erlcloud_s3:put_object(?TEST_BUCKET, "object_one", Object1, U1C1Config),

    %% ObjList2 = erlcloud_s3:list_objects(?TEST_BUCKET, U1C1Config),
    %% ?assertEqual(["object_one"],
    %%              [proplists:get_value(key, O) ||
    %%                  O <- proplists:get_value(contents, ObjList2)]),
    
    %% Obj = erlcloud_s3:get_object(?TEST_BUCKET, "object_one", U1C1Config),
    %% ?assertEqual(Object1, proplists:get_value(content, Obj)),


    %% lager:info("User 1 has the test bucket on the secondary cluster now"),
    %% ?assertMatch([{buckets, [[{name, ?TEST_BUCKET}, _]]}],
    %%              erlcloud_s3:list_buckets(U1C2Config)),

    %% lager:info("Object written on primary cluster is readable from Source"),
    %% Obj2 = erlcloud_s3:get_object(?TEST_BUCKET, "object_one", U1C1Config),
    %% ?assertEqual(Object1, proplists:get_value(content, Obj2)),

    %% lager:info("check we can still read the fullsynced object"),
    %% Obj3 = erlcloud_s3:get_object(?TEST_BUCKET, "object_one", U1C2Config),
    %% ?assertEqual(Object1, proplists:get_value(content, Obj3)),

    %% lager:info("delete object_one in Source"),
    %% erlcloud_s3:delete_object(?TEST_BUCKET, "object_one", U1C1Config),

    %% %%lager:info("object_one is still visible on secondary cluster"),
    %% %%Obj9 = erlcloud_s3:get_object(?TEST_BUCKET, "object_one", U1C2Config),
    %% %%?assertEqual(Object1, proplists:get_value(content, Obj9)),


    %% %% Propagate deleted manifests
    %% repl_helpers:start_and_wait_until_fullsync_complete13(LeaderA),

    %% lager:info("object_one is invisible in Sink"),
    %% ?assertError({aws_error, _},
    %%              erlcloud_s3:get_object(?TEST_BUCKET, "object_one", U1C2Config)),

    %% lager:info("object_one is invisible in Source"),
    %% ?assertError({aws_error, _},
    %%              erlcloud_s3:get_object(?TEST_BUCKET, "object_one", U1C1Config)),

    %% lager:info("secondary cluster now has 'A' version of object four"),


    %% Verify no blocks are in sink and source

