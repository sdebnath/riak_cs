%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc Supervisor for the riak_cs application.

-module(riak_cs_sup).

-behaviour(supervisor).

%% Public API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

-include("riak_cs.hrl").

-define(OPTIONS, [connection_pools,
                  {cs_ip, "0.0.0.0"},
                  {cs_port, 80},
                  admin_ip,
                  admin_port,
                  ssl,
                  admin_ssl,
                  {rewrite_module, riak_cs_s3_rewrite}]).

-type startlink_err() :: {'already_started', pid()} | 'shutdown' | term().
-type startlink_ret() :: {'ok', pid()} | 'ignore' | {'error', startlink_err()}.
-type proplist() :: proplists:proplist().

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc API for starting the supervisor.
-spec start_link() -> startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc supervisor callback.
-spec init([]) -> {ok, {{supervisor:strategy(),
                         non_neg_integer(),
                         non_neg_integer()},
                        [supervisor:child_spec()]}}.
init([]) ->
    catch dyntrace:p(),                    % NIF load trigger (R15B01+)
    Options = [get_option_val(Option) || Option <- ?OPTIONS],
    PoolSpecs = pool_specs(Options),
    {ok, { {one_for_one, 10, 10}, PoolSpecs ++
               process_specs() ++
               web_specs(Options)}}.

-spec process_specs() -> [supervisor:child_spec()].
process_specs() ->
    BagProcessSpecs = riak_cs_mb_helper:process_specs(),
    Archiver = {riak_cs_access_archiver_manager,
                {riak_cs_access_archiver_manager, start_link, []},
                permanent, 5000, worker,
                [riak_cs_access_archiver_manager]},
    Storage = {riak_cs_storage_d,
               {riak_cs_storage_d, start_link, []},
               permanent, 5000, worker, [riak_cs_storage_d]},
    GC = {riak_cs_gc_d,
          {riak_cs_gc_d, start_link, []},
          permanent, 5000, worker, [riak_cs_gc_d]},
    Stats = {riak_cs_stats, {riak_cs_stats, start_link, []},
             permanent, 5000, worker, dynamic},
    DeleteFsmSup = {riak_cs_delete_fsm_sup,
                    {riak_cs_delete_fsm_sup, start_link, []},
                    permanent, 5000, worker, dynamic},
    ListObjectsETSCacheSup = {riak_cs_list_objects_ets_cache_sup,
                              {riak_cs_list_objects_ets_cache_sup, start_link, []},
                              permanent, 5000, supervisor, dynamic},
    GetFsmSup = {riak_cs_get_fsm_sup,
                 {riak_cs_get_fsm_sup, start_link, []},
                 permanent, 5000, worker, dynamic},
    PutFsmSup = {riak_cs_put_fsm_sup,
                 {riak_cs_put_fsm_sup, start_link, []},
                 permanent, 5000, worker, dynamic},
    DiagsSup = {riak_cs_diags, {riak_cs_diags, start_link, []},
                   permanent, 5000, worker, dynamic},
    %% The user record cache is not ~1KB, with optimization it'll be 300B
    %% If million users had exist that'll be just ~1GB
    %% to turn this on, set user_cache_enabled=true
    UserKeyEtsCache = {'moss.users.cache',
                       {riak_cs_record_cache, start_link,
                        ['moss.users.cache', fun riak_cs_user:get_user/2]},
                       permanent, 5000, worker, dynamic},
    %% The bucket cache might be also <1KB if the acl is small,
    %% If million users had exist then 1KB * 100 * 1M ~100GB
    %% TODO: that's why we'll need capped cache in future
    %% or just leave this as default: off.
    %% turn it on by bucket_cache_enabled=true in app.config.
    BucketKeyEtsCache = {'moss.buckets.cache',
                         {riak_cs_record_cache, start_link,
                          ['moss.buckets.cache', fun riak_cs_bucket:fetch_bucket_object/2]},
                         permanent, 5000, worker, dynamic},
    BagProcessSpecs ++
        [Archiver,
         Storage,
         GC,
         Stats,
         ListObjectsETSCacheSup,
         DeleteFsmSup,
         GetFsmSup,
         PutFsmSup,
         DiagsSup,
         UserKeyEtsCache,
         BucketKeyEtsCache].

-spec get_option_val({atom(), term()} | atom()) -> {atom(), term()}.
get_option_val({Option, Default}) ->
    handle_get_env_result(Option, get_env(Option), Default);
get_option_val(Option) ->
    get_option_val({Option, undefined}).

-spec get_env(atom()) -> 'undefined' | {ok, term()}.
get_env(Key) ->
    application:get_env(riak_cs, Key).

-spec handle_get_env_result(atom(), {ok, term()} | 'undefined', term()) -> {atom(), term()}.
handle_get_env_result(Option, {ok, Value}, _) ->
    {Option, Value};
handle_get_env_result(Option, undefined, Default) ->
    {Option, Default}.

-spec web_specs(proplist()) -> [supervisor:child_spec()].
web_specs(Options) ->
    WebConfigs =
        case single_web_interface(proplists:get_value(admin_ip, Options)) of
            true ->
                [{object_web, add_admin_dispatch_table(object_web_config(Options))}];
            false ->
                [{admin_web, admin_web_config(Options)},
                 {object_web, object_web_config(Options)}]
        end,
    [web_spec(Name, Config) || {Name, Config} <- WebConfigs].

-spec pool_specs(proplist()) -> [supervisor:child_spec()].
pool_specs(Options) ->
    rc_pool_specs(Options) ++
        pbc_pool_specs(Options).

rc_pool_specs(Options) ->
    WorkerStop = fun(Worker) -> riak_cs_riak_client:stop(Worker) end,
    MasterPools = proplists:get_value(connection_pools, Options),
    [{Name,
      {poolboy, start_link, [[{name, {local, Name}},
                              {worker_module, riak_cs_riak_client},
                              {size, Workers},
                              {max_overflow, Overflow},
                              {stop_fun, WorkerStop}],
                             []]},
      permanent, 5000, worker, [poolboy]} ||
        {Name, {Workers, Overflow}} <- MasterPools].

pbc_pool_specs(Options) ->
    WorkerStop = fun(Worker) -> riak_cs_riakc_pool_worker:stop(Worker) end,
    %% Use sums of fixed/overflow for pbc pool
    MasterPools = proplists:get_value(connection_pools, Options),
    {FixedSum, OverflowSum} = lists:foldl(fun({_, {Fixed, Overflow}}, {FAcc, OAcc}) ->
                                                  {Fixed + FAcc, Overflow + OAcc}
                                          end,
                                          {0, 0}, MasterPools),
    Bags = riak_cs_mb_helper:bags(),
    [pbc_pool_spec(BagId, FixedSum, OverflowSum, Address, Port, WorkerStop)
     || {BagId, Address, Port} <- Bags].

-spec pbc_pool_spec(bag_id(), non_neg_integer(), non_neg_integer(),
                string(), non_neg_integer(), function()) ->
                       supervisor:child_spec().
pbc_pool_spec(BagId, Fixed, Overflow, Address, Port, WorkerStop) ->
    Name = riak_cs_riak_client:pbc_pool_name(BagId),
    {Name,
     {poolboy, start_link, [[{name, {local, Name}},
                             {worker_module, riak_cs_riakc_pool_worker},
                             {size, Fixed},
                             {max_overflow, Overflow},
                             {stop_fun, WorkerStop}],
                            [{address, Address}, {port, Port}]]},
     permanent, 5000, worker, [poolboy]}.

-spec web_spec(atom(), proplist()) -> supervisor:child_spec().
web_spec(Name, Config) ->
    {Name,
     {webmachine_mochiweb, start, [Config]},
     permanent, 5000, worker, dynamic}.

-spec object_web_config(proplist()) -> proplist().
object_web_config(Options) ->
    [{dispatch, riak_cs_web:object_api_dispatch_table()},
     {name, object_web},
     {dispatch_group, object_web},
     {ip, proplists:get_value(cs_ip, Options)},
     {port, proplists:get_value(cs_port, Options)},
     {nodelay, true},
     {rewrite_module, proplists:get_value(rewrite_module, Options)},
     {error_handler, riak_cs_wm_error_handler},
     {resource_module_option, submodule}] ++
        maybe_add_ssl_opts(proplists:get_value(ssl, Options)).

-spec admin_web_config(proplist()) -> proplist().
admin_web_config(Options) ->
    [{dispatch, riak_cs_web:admin_api_dispatch_table()},
     {name, admin_web},
     {dispatch_group, admin_web},
     {ip, proplists:get_value(admin_ip, Options)},
     {port, proplists:get_value(admin_port, Options, 8000)},
     {nodelay, true},
     {error_handler, riak_cs_wm_error_handler}] ++
        maybe_add_ssl_opts(proplists:get_value(admin_ssl, Options)).

-spec single_web_interface('undefined' | term()) -> boolean().
single_web_interface(undefined) ->
    true;
single_web_interface(_) ->
    false.

-spec maybe_add_ssl_opts('undefined' | proplist()) -> proplist().
maybe_add_ssl_opts(undefined) ->
    [];
maybe_add_ssl_opts(SSLOpts) ->
    [{ssl, true}, {ssl_opts, SSLOpts}].

-spec add_admin_dispatch_table(proplist()) -> proplist().
add_admin_dispatch_table(Config) ->
    UpdDispatchTable = proplists:get_value(dispatch, Config) ++
        riak_cs_web:admin_api_dispatch_table(),
    [{dispatch, UpdDispatchTable} | proplists:delete(dispatch, Config)].
