%%% @doc Test backend module using an ets table as a db backend for merklet.
%%% @end
-module(merklet_ets_db_backend).

-export([spec/0]).

spec() ->
    #{ get => fun ets_get/2
     , put => fun ets_put/3
     , handle => ets_new()}.

%% NOTE: This relies on the identity hash being the second element of
%%       #leaf{} and #inner{}.
ets_new() ->
    ets:new(merklet_backend, [set, private, {keypos, 2}]).

ets_get(Key, Ets) ->
    [Rec] = ets:lookup(Ets, Key),
    Rec.

ets_put(Key, Val, Ets) ->
    %% Assert
    Key = element(2, Val),
    ets:insert(Ets, Val),
    Ets.
