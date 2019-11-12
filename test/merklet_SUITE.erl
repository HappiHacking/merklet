-module(merklet_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> [ regression_diff
         , regression_diff_dict_db
         , regression_diff_ets_db
         , regression_visit_nodes
         , regression_visit_nodes_dict_db
         , regression_visit_nodes_ets_db
         ].

regression_diff(_) ->
    regression_diff_common(undefined).

regression_diff_dict_db(_) ->
    T0 = merklet:empty_db_tree(),
    regression_diff_common(T0).

regression_diff_ets_db(_) ->
    T0 = merklet:empty_db_tree(merklet_ets_db_backend:spec()),
    regression_diff_common(T0).

regression_diff_common(T0) ->
    T1 = insert_all([{<<1>>,<<1>>},{<<2>>,<<2>>},{<<3>>,<<3>>}], T0),
    T2 = insert_all([{<<1>>,<<0>>}], T0),
    ?assertEqual([<<1>>,<<2>>,<<3>>], merklet:diff(T1,T2)),
    ?assertEqual([<<1>>,<<2>>,<<3>>], merklet:diff(T2,T1)).

regression_visit_nodes(_) ->
    regression_visit_nodes_common(undefined).

regression_visit_nodes_dict_db(_) ->
    T0 = merklet:empty_db_tree(),
    regression_visit_nodes_common(T0).

regression_visit_nodes_ets_db(_) ->
    T0 = merklet:empty_db_tree(merklet_ets_db_backend:spec()),
    regression_visit_nodes_common(T0).

regression_visit_nodes_common(T0) ->
    AllVals = [{<<1>>,<<1>>},{<<2>>,<<2>>},{<<3>>,<<3>>}],
    T1 = insert_all(AllVals, T0),
    Fun = fun(Type,_Hash,_Node, Count) ->
                  orddict:update_counter(Type, 1, Count)
          end,
    Count = merklet:visit_nodes(Fun, [], T1),
    ?assertEqual(length(AllVals), orddict:fetch(leaf, Count)).

%%%%%%%%%%%%%%%%
%%% Builders %%%
%%%%%%%%%%%%%%%%
insert_all(KeyVals) -> insert_all(KeyVals, undefined).
insert_all(KeyVals, Tree) -> lists:foldl(fun merklet:insert/2, Tree, KeyVals).
