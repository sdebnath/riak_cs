%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2007-2015 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------

-module(riak_cs_stats).

%% API
-export([safe_update/2,
         update/2,
         update_with_start/2,
         report_json/0,
         report_pretty_json/0,
         get_stats/0]).

-export([init/0]).

-type metric_key() :: atom().
-export_type([metric_key/0]).

-spec duration_metrics() -> [metric_key()].
duration_metrics() ->
        [
         service_get_bucket,
         bucket_list_keys,
         bucket_create,
         bucket_head,
         bucket_delete,
         bucket_get_acl,
         bucket_put_acl,
         bucket_put_policy,

         object_get,
         object_put,
         object_put_copy,
         object_head,
         object_delete,
         object_get_acl,
         object_put_acl,

         manifest_siblings_bp_sleep,

         block_get,
         block_get_retry,
         block_put,
         block_delete
        ].

%% ====================================================================
%% API
%% ====================================================================

%% TODO: Who uses this function?
-spec safe_update(metric_key(), integer()) -> ok | {error, any()}.
safe_update(Key, ElapsedUs) ->
    %% Just in case those metrics happen to be not registered; should
    %% be a bug and also should not interrupt handling requests by
    %% crashing.
    try
        update(Key, ElapsedUs)
    catch T:E ->
            lager:error("Failed on storing some metrics: ~p,~p", [T,E])
    end.

-spec update(metric_key(), integer()) -> ok | {error, any()}.
update(Key, ElapsedUs) ->
    ok = exometer:update([riak_cs, spiral, Key], 1),
    ok = exometer:update([riak_cs, histogram, Key], ElapsedUs).

-spec update_with_start(metric_key(), erlang:timestamp()) ->
                                   ok | {error, any()}.
update_with_start(BaseId, StartTime) ->
    update(BaseId, timer:now_diff(os:timestamp(), StartTime)).

-spec report_json() -> string().
report_json() ->
    lists:flatten(mochijson2:encode({struct, get_stats()})).

-spec report_pretty_json() -> string().
report_pretty_json() ->
    lists:flatten(riak_cs_utils:json_pp_print(report_json())).

-spec get_stats() -> proplists:proplist().
get_stats() ->
    Stats = [report_duration_item(K, spiral) || K <- duration_metrics()]
        ++ [report_duration_item(K, histogram) || K <- duration_metrics()]
        ++ [raw_report_pool(P) || P <- [request_pool, bucket_list_pool]],
    lists:flatten(Stats).

%% ====================================================================
%% Internal
%% ====================================================================

init() ->
    _ = [init_duration_item(I) || I <- duration_metrics()],
    ok.

init_duration_item(Key) ->
    ok = exometer:re_register([riak_cs, spiral, Key], spiral, []),
    ok = exometer:re_register([riak_cs, histogram, Key], histogram, []).

report_duration_item(Key, Type) ->
    AtomKeys = [metric_to_atom(Key, Suffix) || Suffix <- suffixes(Type)],
    {ok, Values} = exometer:get_value([riak_cs, Type, Key], datapoints(Type)),
    [{AtomKey, Value} ||
        {AtomKey, {_DP, Value}} <- lists:zip(AtomKeys, Values)].

datapoints(histogram) ->
    [mean, median, 95, 99, 100];
datapoints(spiral) ->
    [one, count].

suffixes(histogram) ->
    ["_time_mean", "_time_median", "_time_95", "_time_99", "_time_100"];
suffixes(spiral) ->
    ["_one", "_count"].

raw_report_pool(Pool) ->
    {_PoolState, PoolWorkers, PoolOverflow, PoolSize} = poolboy:status(Pool),
    Name = binary_to_list(atom_to_binary(Pool, latin1)),
    [{list_to_atom(lists:flatten([Name, $_, "workers"])), PoolWorkers},
     {list_to_atom(lists:flatten([Name, $_, "overflow"])), PoolOverflow},
     {list_to_atom(lists:flatten([Name, $_, "size"])), PoolSize}].

metric_to_atom(Key, Suffix) when is_atom(Key) ->
    list_to_atom(lists:flatten([atom_to_list(Key), Suffix])).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

stats_test_() ->
    Apps = [setup, compiler, syntax_tools, goldrush, lager, exometer_core],
    {setup,
     fun() ->
             [ok = application:start(App) || App <- Apps],
             ok = riak_cs_stats:init()
     end,
     fun(_) ->
             [ok = application:stop(App) || App <- Apps]
     end,
     [{inparallel, [fun() ->
                            riak_cs_stats:update(Key, 16#deadbeef)
                    end || Key <- duration_metrics()]},
      fun() ->
              [begin
                   ?assertEqual([1, 1],
                                [N || {_, N} <- report_duration_item(I, spiral)]),
                   ?assertEqual([16#deadbeef, 16#deadbeef, 16#deadbeef, 16#deadbeef, 0],
                                [N || {_, N} <- report_duration_item(I, histogram)])
               end || I <- duration_metrics()]
      end]}.

-endif.
