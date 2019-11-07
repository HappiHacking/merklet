%%% @doc Test Merklet using a simple list-based model as a comparative
%%% implementation (test/merklet_model.erl).
-module(prop_model).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(OPTS, [{numtests,5000}, {to_file, user}]).
-define(run(Case), {timeout, timer:seconds(60),
                    ?_assert(proper:quickcheck(Case, ?OPTS))}).

eunit_no_db_test_() ->
    [?run(prop_insert_many_no_db()),
     ?run(prop_delete_random_no_db()),
     ?run(prop_delete_members_no_db()),
     ?run(prop_overwrite_no_db()),
     ?run(prop_insert_same_diff_no_db()),
     ?run(prop_insert_mixed_diff_no_db()),
     ?run(prop_insert_disjoint_diff_no_db()),
     ?run(prop_delete_random_diff_no_db()),
     ?run(prop_delete_members_diff_no_db()),
     ?run(prop_overwrite_diff_no_db()),
     ?run(prop_mixed_diff_no_db()),
     ?run(prop_mixed_dist_diff_no_db())
    ].

eunit_dict_db_test_() ->
    [?run(prop_insert_many_dict_db()),
     ?run(prop_delete_random_dict_db()),
     ?run(prop_delete_members_dict_db()),
     ?run(prop_overwrite_dict_db()),
     ?run(prop_insert_same_diff_dict_db()),
     ?run(prop_insert_mixed_diff_dict_db()),
     ?run(prop_insert_disjoint_diff_dict_db()),
     ?run(prop_delete_random_diff_dict_db()),
     ?run(prop_delete_members_diff_dict_db()),
     ?run(prop_overwrite_diff_dict_db()),
     ?run(prop_mixed_diff_dict_db()),
     ?run(prop_mixed_dist_diff_dict_db())
    ].

empty_tree(no_db) ->
    undefined;
empty_tree(dict_db) ->
    merklet:empty_db_tree().

%% Test insertion and reading the keys back
prop_insert_many_no_db() ->
    prop_insert_many(no_db).

prop_insert_many_dict_db() ->
    prop_insert_many(dict_db).

prop_insert_many(Backend) ->
    ?FORALL(Entries, keyvals(),
            merklet_model:keys(merklet_model:insert_many(Entries,undefined))
            =:=
            merklet:keys(merklet:insert_many(Entries,empty_tree(Backend)))
           ).

%% Delete keys that may or may not be in the tree
prop_delete_random_no_db() ->
    prop_delete_random(no_db).

prop_delete_random_dict_db() ->
    prop_delete_random(dict_db).

prop_delete_random(Backend) ->
    ?FORALL({Entries, ToDelete}, {keyvals(), list(binary())},
            merklet_model:keys(
                delete(merklet_model,
                       ToDelete,
                       merklet_model:insert_many(Entries,undefined)))
            =:=
            merklet:keys(
                delete(merklet,
                       ToDelete,
                       merklet:insert_many(Entries,empty_tree(Backend))))
           ).

%% Only delete keys that have previously been inserted in the tree
prop_delete_members_no_db() ->
    prop_delete_members(no_db).

prop_delete_members_dict_db() ->
    prop_delete_members(dict_db).

prop_delete_members(Backend) ->
    ?FORALL({Entries, ToDelete}, delete_keyvals(0.5),
            merklet_model:keys(
                delete(merklet_model,
                       ToDelete,
                       merklet_model:insert_many(Entries,undefined)))
            =:=
            merklet:keys(
                delete(merklet,
                       ToDelete,
                       merklet:insert_many(Entries,empty_tree(Backend))))
           ).

%% Overwrite existing entries, make sure nothing was lost or added
prop_overwrite_no_db() ->
    prop_overwrite(no_db).

prop_overwrite_dict_db() ->
    prop_overwrite(dict_db).

prop_overwrite(Backend) ->
    ?FORALL({Entries, ToUpdate}, overwrite_keyvals(0.5),
            merklet_model:keys(
                merklet_model:insert_many(ToUpdate,
                    merklet_model:insert_many(Entries,undefined)))
            =:=
            merklet:keys(
                merklet:insert_many(ToUpdate,
                    merklet:insert_many(Entries,empty_tree(Backend))))
           ).

%% Trees diffed with themselves should be stable
prop_insert_same_diff_no_db() ->
    prop_insert_same_diff(no_db).

prop_insert_same_diff_dict_db() ->
    prop_insert_same_diff(dict_db).

prop_insert_same_diff(Backend) ->
    ?FORALL(Entries, keyvals(),
            merklet_model:diff(merklet_model:insert_many(Entries,undefined),
                               merklet_model:insert_many(Entries,undefined))
            =:=
            merklet:diff(merklet:insert_many(Entries,empty_tree(Backend)),
                         merklet:insert_many(Entries,empty_tree(Backend)))
           ).

%% Two independent trees diffed together (no verification of commutativity)
prop_insert_mixed_diff_no_db() ->
    prop_insert_mixed_diff(no_db).

prop_insert_mixed_diff_dict_db() ->
    prop_insert_mixed_diff(dict_db).

prop_insert_mixed_diff(Backend) ->
    ?FORALL({Entries1, Entries2}, {keyvals(), keyvals()},
            merklet_model:diff(merklet_model:insert_many(Entries1,undefined),
                               merklet_model:insert_many(Entries2,undefined))
            =:=
            merklet:diff(merklet:insert_many(Entries1,empty_tree(Backend)),
                         merklet:insert_many(Entries2,empty_tree(Backend)))
           ).

%% Two independent trees with no overlapping data sets diffed together
%% (no verification of commutativity)
prop_insert_disjoint_diff_no_db() ->
    prop_insert_disjoint_diff(no_db).

prop_insert_disjoint_diff_dict_db() ->
    prop_insert_disjoint_diff(dict_db).

prop_insert_disjoint_diff(Backend) ->
    ?FORALL(Lists, disjoint_keyvals(),
        begin
            {Entries1, Entries2} = Lists,
            merklet_model:diff(merklet_model:insert_many(Entries1,undefined),
                               merklet_model:insert_many(Entries2,undefined))
            =:=
            merklet:diff(merklet:insert_many(Entries1,empty_tree(Backend)),
                         merklet:insert_many(Entries2,empty_tree(Backend)))
        end).

%% Diffing two trees that had random element deletion that may or may
%% not be present (tests commutativity)
prop_delete_random_diff_no_db() ->
    prop_delete_random_diff(no_db).

prop_delete_random_diff_dict_db() ->
    prop_delete_random_diff(dict_db).

prop_delete_random_diff(Backend) ->
    ?FORALL({Entries, ToDelete}, {keyvals(), list(binary())},
        begin
            ModelFull = merklet_model:insert_many(Entries,undefined),
            ModelDelete = delete(merklet_model, ToDelete, ModelFull),
            MerkletFull = merklet:insert_many(Entries,empty_tree(Backend)),
            MerkletDelete = delete(merklet, ToDelete, MerkletFull),
            (merklet_model:diff(ModelFull, ModelDelete)
             =:= merklet:diff(MerkletFull, MerkletDelete))
            andalso
            (merklet_model:diff(ModelDelete, ModelFull)
             =:= merklet:diff(MerkletDelete, MerkletFull))
        end).

%% Diffing two trees that had member element deletion (tests commutativity)
prop_delete_members_diff_no_db() ->
    prop_delete_members_diff(no_db).

prop_delete_members_diff_dict_db() ->
    prop_delete_members_diff(dict_db).

prop_delete_members_diff(Backend) ->
    ?FORALL({Entries, ToDelete}, delete_keyvals(0.5),
        begin
            ModelFull = merklet_model:insert_many(Entries,undefined),
            ModelDelete = delete(merklet_model, ToDelete, ModelFull),
            MerkletFull = merklet:insert_many(Entries,empty_tree(Backend)),
            MerkletDelete = delete(merklet, ToDelete, MerkletFull),
            (merklet_model:diff(ModelFull, ModelDelete)
             =:= merklet:diff(MerkletFull, MerkletDelete))
            andalso
            (merklet_model:diff(ModelDelete, ModelFull)
             =:= merklet:diff(MerkletDelete, MerkletFull))
        end).

%% Diffing trees that had overwritten pieces of data (tests commutativity)
prop_overwrite_diff_no_db() ->
    prop_overwrite_diff(no_db).

prop_overwrite_diff_dict_db() ->
    prop_overwrite_diff(dict_db).

prop_overwrite_diff(Backend) ->
    ?FORALL({Entries, ToUpdate}, overwrite_keyvals(0.5),
        begin
            ModelFull = merklet_model:insert_many(Entries, undefined),
            ModelUpdate = merklet_model:insert_many(ToUpdate, ModelFull),
            MerkletFull = merklet:insert_many(Entries, empty_tree(Backend)),
            MerkletUpdate = merklet:insert_many(ToUpdate, MerkletFull),
            (merklet_model:diff(ModelFull, ModelUpdate)
             =:= merklet:diff(MerkletFull, MerkletUpdate))
            andalso
            (merklet_model:diff(ModelUpdate, ModelFull)
             =:= merklet:diff(MerkletUpdate, MerkletFull))
        end).

%% Commutative verification of various trees that had their keys
%% inserted, updated, and randomly deleted.
prop_mixed_diff_no_db() ->
    prop_mixed_diff(no_db).

prop_mixed_diff_dict_db() ->
    prop_mixed_diff(dict_db).

prop_mixed_diff(Backend) ->
    ?FORALL({{Entries, ToUpdate}, ToDelete}, {overwrite_keyvals(0.5), list(binary())},
        begin
            ModelFull = merklet_model:insert_many(Entries, undefined),
            ModelDelete = delete(merklet_model, ToDelete, ModelFull),
            ModelUpdate = merklet_model:insert_many(ToUpdate, ModelDelete),
            MerkletFull = merklet:insert_many(Entries, empty_tree(Backend)),
            MerkletDelete = delete(merklet, ToDelete, MerkletFull),
            MerkletUpdate = merklet:insert_many(ToUpdate, MerkletDelete),
            %% Full vs. Update
            (merklet_model:diff(ModelFull, ModelUpdate)
             =:= merklet:diff(MerkletFull, MerkletUpdate))
            andalso
            (merklet_model:diff(ModelUpdate, ModelFull)
             =:= merklet:diff(MerkletUpdate, MerkletFull))
            %% Full vs. Delete
            andalso
            (merklet_model:diff(ModelFull, ModelDelete)
             =:= merklet:diff(MerkletFull, MerkletDelete))
            andalso
            (merklet_model:diff(ModelDelete, ModelFull)
             =:= merklet:diff(MerkletDelete, MerkletFull))
            %% Delete vs. Update
            andalso
            (merklet_model:diff(ModelUpdate, ModelDelete)
             =:= merklet:diff(MerkletUpdate, MerkletDelete))
            andalso
            (merklet_model:diff(ModelDelete, ModelUpdate)
             =:= merklet:diff(MerkletDelete, MerkletUpdate))
        end).

%% Commutative verification of various trees that had their keys
%% inserted, updated, and randomly deleted, while using the
%% distributed/serialized interface.
prop_mixed_dist_diff_no_db() ->
    prop_mixed_dist_diff(no_db).

prop_mixed_dist_diff_dict_db() ->
    prop_mixed_dist_diff(dict_db).

prop_mixed_dist_diff(Backend) ->
    ?FORALL({{Entries, ToUpdate}, ToDelete}, {overwrite_keyvals(0.5), list(binary())},
        begin
            ModelFull = merklet_model:insert_many(Entries, undefined),
            ModelDelete = delete(merklet_model, ToDelete, ModelFull),
            ModelUpdate = merklet_model:insert_many(ToUpdate, ModelDelete),
            MerkletFull = merklet:insert_many(Entries, empty_tree(Backend)),
            MerkletDelete = delete(merklet, ToDelete, MerkletFull),
            MerkletUpdate = merklet:insert_many(ToUpdate, MerkletDelete),
            DistFull = merklet:access_unserialize(merklet:access_serialize(MerkletFull)),
            DistDelete = merklet:access_unserialize(merklet:access_serialize(MerkletDelete)),
            DistUpdate = merklet:access_unserialize(merklet:access_serialize(MerkletUpdate)),
            %% Full vs. Update
            (merklet_model:diff(ModelFull, ModelUpdate)
             =:= merklet:dist_diff(MerkletFull, DistUpdate))
            andalso
            (merklet_model:diff(ModelUpdate, ModelFull)
             =:= merklet:dist_diff(MerkletUpdate, DistFull))
            %% Full vs. Delete
            andalso
            (merklet_model:diff(ModelFull, ModelDelete)
             =:= merklet:dist_diff(MerkletFull, DistDelete))
            andalso
            (merklet_model:diff(ModelDelete, ModelFull)
             =:= merklet:dist_diff(MerkletDelete, DistFull))
            %% Delete vs. Update
            andalso
            (merklet_model:diff(ModelUpdate, ModelDelete)
             =:= merklet:dist_diff(MerkletUpdate, DistDelete))
            andalso
            (merklet_model:diff(ModelDelete, ModelUpdate)
             =:= merklet:dist_diff(MerkletDelete, DistUpdate))
        end).

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
delete(_Mod, [], Struct) -> Struct;
delete(Mod, [H|T], Struct) -> delete(Mod, T, Mod:delete(H, Struct)).


%%%%%%%%%%%%%%%%%%
%%% GENERATORS %%%
%%%%%%%%%%%%%%%%%%
keyvals() -> list({binary(), binary()}).

delete_keyvals(Rate) ->
    ?LET(KeyVals, keyvals(),
         begin
          Rand = rand:uniform(),
          ToDelete = [Key || {Key,_} <- KeyVals, Rate > Rand],
          {KeyVals, ToDelete}
         end).

overwrite_keyvals(Rate) ->
    ?LET(KeyVals, keyvals(),
         begin
          Rand = rand:uniform(),
          ToUpdate = [{Key, <<0,Val/binary>>} || {Key,Val} <- KeyVals, Rate > Rand],
          {KeyVals, ToUpdate}
         end).

disjoint_keyvals() ->
    ?SUCHTHAT({KV1, KV2}, {keyvals(), keyvals()},
            begin
              KS1 = [K || {K, _} <- KV1],
              KS2 = [K || {K, _} <- KV2],
              lists:all(fun(K) -> not lists:member(K,KS2) end, KS1)
            end).

