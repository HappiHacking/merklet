-module(prop_merklet).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(OPTS, [{numtests,1000}, {to_file, user}]).
-define(run(Case), {timeout, timer:seconds(60),
                    ?_assert(proper:quickcheck(Case, ?OPTS))}).

eunit_no_db_test_() ->
    [?run(prop_diff_no_db()),
     ?run(prop_dist_diff_no_db()),
     ?run(prop_delete_no_db()),
     ?run(prop_modify_no_db())].

eunit_dict_db_test_() ->
    [?run(prop_diff_dict_db()),
     ?run(prop_dist_diff_dict_db()),
     ?run(prop_delete_dict_db()),
     ?run(prop_modify_dict_db())
    ].

eunit_ets_db_test_() ->
    [?run(prop_diff_ets_db()),
     ?run(prop_dist_diff_ets_db()),
     ?run(prop_delete_ets_db()),
     ?run(prop_modify_ets_db())
    ].

%%%%%%%%%%%%%%%%%%
%%% Properties %%%
%%%%%%%%%%%%%%%%%%
prop_diff_no_db() ->
    prop_diff(no_db).

prop_diff_dict_db() ->
    prop_diff(dict_db).

prop_diff_ets_db() ->
    prop_diff(ets_db).

prop_diff(Backend) ->
    %% All differences between trees can be found no matter the order,
    %% and returns the list of different keys.
    ?FORALL({KV1,KV2}, diff_keyvals(),
            begin
                Keys = [K || {K,_} <- KV2],
                T1 = insert_all(KV1, Backend),
                T2 = extend(KV2, T1),
                Diff1 = merklet:diff(T1,T2),
                Diff2 = merklet:diff(T2,T1),
                Diff1 =:= Diff2
                andalso
                Diff1 =:= lists:sort(Keys)
            end).

prop_dist_diff_no_db() ->
    prop_dist_diff(no_db).

prop_dist_diff_dict_db() ->
    prop_dist_diff(dict_db).

prop_dist_diff_ets_db() ->
    prop_dist_diff(ets_db).

prop_dist_diff(Backend) ->
    %% All differences between trees can be found no matter the order,
    %% and returns the list of different keys. Same as previous case, but
    %% uses the internal serialization format and distribution API
    %% functions of merklet to do its thing.
    ?FORALL({KV1,KV2}, diff_keyvals(),
            begin
                Keys = [K || {K,_} <- KV2],
                T1 = insert_all(KV1, Backend),
                T2 = extend(KV2, T1),
                %% remmote version of the trees, should be handled
                %% by merklet:unserialize/1. In practice, this kind
                %% of thing would take place over the network, and
                %% merklet:access_serialize/2, and R1 and R2 would be
                %% be wrapped in other functions to help.
                R1 = merklet:access_serialize(T1),
                R2 = merklet:access_serialize(T2),
                %% Remote diffing
                Diff1 = merklet:dist_diff(T1,merklet:access_unserialize(R2)),
                Diff2 = merklet:dist_diff(T2,merklet:access_unserialize(R1)),
                Diff1 =:= Diff2
                andalso
                Diff1 =:= lists:sort(Keys)
            end).

prop_delete_no_db() ->
    prop_delete(no_db).

prop_delete_dict_db() ->
    prop_delete(dict_db).

prop_delete_ets_db() ->
    prop_delete(ets_db).

prop_delete(Backend) ->
    %% Having a tree and deleting a percentage of it yields the same tree
    %% without said keys.
    ?FORALL({All, Partial, ToDelete}, delete_keyvals(0.50),
            begin
                Tree = insert_all(All, Backend),
                PartialTree = insert_all(Partial, Backend),
                DeletedTree = delete_keys(ToDelete, Tree),
                [] =:= merklet:diff(PartialTree, DeletedTree)
                andalso
                merklet:keys(DeletedTree) =:= merklet:keys(PartialTree)
                andalso
                merklet:expand_db_tree(DeletedTree) =:= merklet:expand_db_tree(PartialTree)
            end).

prop_modify_no_db() ->
    prop_modify(no_db).

prop_modify_dict_db() ->
    prop_modify(dict_db).

prop_modify_ets_db() ->
    prop_modify(ets_db).

prop_modify(Backend) ->
    %% Updating records' values should show detections as part of merklet's
    %% diff operations, even if none of the keys change.
    ?FORALL({All, ToChange}, modify_keyvals(0.50),
            begin
                Tree = insert_all(All, Backend),
                KVSet = [{K, term_to_binary(make_ref())} || K <- ToChange],
                Modified = extend(KVSet, Tree),
                merklet:keys(Tree) =:= merklet:keys(Modified)
                andalso
                lists:sort(ToChange) =:= merklet:diff(Tree, Modified)
                andalso
                lists:sort(ToChange) =:= merklet:diff(Modified, Tree)
            end).

%%%%%%%%%%%%%%%%
%%% Builders %%%
%%%%%%%%%%%%%%%%
insert_all(KeyVals, no_db) -> extend(KeyVals, undefined);
insert_all(KeyVals, dict_db) -> extend(KeyVals, merklet:empty_db_tree());
insert_all(KeyVals, ets_db) -> extend(KeyVals, merklet:empty_db_tree(merklet_ets_db_backend:spec())).

extend(KeyVals, Tree) -> lists:foldl(fun merklet:insert/2, Tree, KeyVals).

delete_keys(Keys, Tree) -> lists:foldl(fun merklet:delete/2, Tree, Keys).

keyvals() -> list({binary(), binary()}).

diff_keyvals() ->
    ?SUCHTHAT({KV1,KV2}, {keyvals(), keyvals()},
              begin
                K1 = [K || {K,_} <- KV1],
                K2 = [K || {K,_} <- KV2],
                lists:all(fun(K) -> not lists:member(K,K2) end, K1)
                 andalso
                length(lists:usort(K2)) =:= length(K2)
              end).

delete_keyvals(Rate) ->
    ?LET(KeyVals, keyvals(),
         begin
          Rand = rand:uniform(),
          ToDelete = [Key || {Key,_} <- KeyVals, Rate > Rand],
          WithoutDeleted = [{K,V} || {K,V} <- KeyVals, Rate < Rand],
          {KeyVals, WithoutDeleted, ToDelete}
         end).

modify_keyvals(Rate) ->
    % similar as delete_keyvals but doesn't allow duplicate updates
    ?SUCHTHAT({_,ToChange},
              ?LET(KeyVals, keyvals(),
                begin
                  Rand = rand:uniform(),
                  ToDelete = [Key || {Key,_} <- KeyVals, Rate > Rand],
                  {KeyVals, lists:usort(ToDelete)}
                end),
              ToChange =/= []).
