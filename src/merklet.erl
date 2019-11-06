%%% @doc Merkle Trees are a data structures devised especially to find
%%% conflicts or diverging pieces of data between two data sets.
%%%
%%% They're more or less a hybrid between a sparse K-ary tree and a
%%% trie of hash values.
%%%
%%% Each `{Key, Value}' pair gets two hashes: a hash of the key (Hkey), and
%%% a hash of the hashed key and the hashed value (Hash).
%%%
%%% The Hkey is used as the main index and to build a tree. If we have three
%%% hashes with the values `<<213,21,54,...>>', `<<213,33,98,...>>', and
%%% `<<11,45,101,...>>', the resulting tree/trie is:
%%%
%%%                (Root)
%%%                 Inner
%%%                /    \
%%%               /      \
%%%            (11)      (213)
%%%  <<11,45,101,...>>   Inner
%%%                     /     \
%%%                    /       \
%%%                 (21)       (33)
%%%      <<213,21,54,...>>     <<213,33,98,...>>
%%%
%%% Each of the leaf nodes will contain both hashes, along with a non-hashed
%%% version of the key. Each Inner node contains a hash of all its children's
%%% hash values, and indexes them by the hash byte at the given depth.
%%%
%%% This structure allows to quickly compare for changes in values, missing
%%% nodes, and so on, but more importantly allows to quickly know if the data
%%% sets (or subsets of them) are identical.
%%%
%%% It also allows to do a level-order traversal node-per-node over the network
%%% allowing somewhat efficient diffing.
%%% @end
-module(merklet).

-record(leaf, {hash :: binary(),      % hash(hash(key), hash(value))
               userkey :: binary(),   % user submitted key
               hashkey :: binary()}). % hash of the user submitted key
-record(inner, {hashchildren :: binary(), % hash of children's hashes
                %% The children is really nonempty but, we abuse it in
                %% unserialize, which Dialyzer finds.
                children :: [{offset(), #inner{} | #leaf{} | binary()}],
                offset :: non_neg_integer()}). % byte offset

-record(db, { get    :: get_fun()
            , put    :: put_fun()
            , handle :: term()
            }).

-record(dbtree, { db   :: db()
                , hash :: 'undefined' | binary()
                }).

-define(HASHPOS, 2). % #leaf.hash =:= #inner.hashchildren

-type offset() :: byte().
-type leaf() :: #leaf{}.
-type inner() :: #inner{}.

-type non_db_tree() :: leaf() | inner() | 'undefined'.
-type db_tree() :: #dbtree{}.
-type tree() :: db_tree() | non_db_tree().

-type key() :: binary().
-type value() :: binary().
-type path() :: binary().
-type access_fun() :: fun((at | child_at | keys | {keys, Hash::binary()}, path()) -> non_db_tree()).
-type serial_fun() :: fun((at | child_at | keys | {keys, Hash::binary()}, path()) -> binary()).

-type db() :: #db{}.
-type db_handle() :: term().
-type get_fun() :: fun((Key :: binary(), db_handle()) -> non_db_tree()).
-type put_fun() :: fun((Key :: binary(), Node :: leaf() | inner(), db_handle()) -> db_handle()).

-export_type([tree/0, key/0, value/0, path/0, access_fun/0, serial_fun/0]).
-export_type([get_fun/0, put_fun/0, db_handle/0]).
-export([insert/2, insert_many/2, delete/2, keys/1, diff/2]).
-export([dist_diff/2, access_serialize/1, access_unserialize/1]).
-export([empty_db_tree/0, expand_db_tree/1]).

-ifdef(TEST).
%% Test interface
-export([ expand_db_tree/1
        ]).
-endif.

-define(HASH, sha).
-define(HASHBYTES, 20).

-define(VSN, 1).
-define(UNDEFINED, 0).
-define(INNER, 1).
-define(LEAF, 2).
-define(OFFSETBYTE, 3).
-define(KEYS, 4).
-define(KEYS_SKIP, 5).
-define(KEYS_SKIP_UNSEEN, 0).
-define(KEYS_SKIP_SAME, 1).
-define(KEYS_SKIP_DIFF, 2).

%%%%%%%%%%%
%%% API %%%
%%%%%%%%%%%

-spec empty_db_tree() -> db_tree().
empty_db_tree() ->
    empty_db_tree(#{ get    => fun dict:fetch/2
                   , put    => fun dict:store/3
                   , handle => dict:new()
                   }).

-spec empty_db_tree(#{ get    := get_fun()
                     , put    := put_fun()
                     , handle := db_handle()}) -> db_tree().
empty_db_tree(#{ get := GetFun
               , put := PutFun
               , handle := Handle}) when is_function(GetFun, 2),
                                         is_function(PutFun, 3) ->
    #dbtree{ hash = undefined
           , db   = #db{ get=GetFun
                       , put=PutFun
                       , handle=Handle
                       }}.


-ifdef(TEST).
%% Test interface to facilitate comparing trees
expand_db_tree(#dbtree{hash=undefined}) ->
    undefined;
expand_db_tree(#dbtree{hash=H, db=DB}) ->
    expand_db_tree(db_get(H, DB), DB);
expand_db_tree(Tree) ->
    Tree.

expand_db_tree(#leaf{} = L,_DB) ->
    L;
expand_db_tree(#inner{children=Children} = I, DB) ->
    Expand = fun(_, Child) -> expand_db_tree(db_get(Child, DB), DB)end,
    I#inner{children=orddict:map(Expand, Children)}.
-endif.

unpack_db_tree(#dbtree{hash=H, db=DB}) -> {db_get(H, DB), DB};
unpack_db_tree(#leaf{} = T) -> {T, no_db};
unpack_db_tree(#inner{} = T) -> {T, no_db};
unpack_db_tree(undefined) -> {undefined, no_db}.

pack_db_tree({T, no_db}) -> T;
pack_db_tree({#leaf{hash=H}, #db{} = DB}) -> #dbtree{hash=H, db=DB};
pack_db_tree({#inner{hashchildren=H}, #db{} = DB}) -> #dbtree{hash=H, db=DB};
pack_db_tree({undefined, #db{} = DB}) -> #dbtree{hash=undefined, db=DB}.

%% @doc Adds a key to the tree, or overwrites an exiting one.
-spec insert({key(), value()}, tree()) -> tree().
insert({Key, Value}, Tree0) ->
    {Tree, DB} = unpack_db_tree(Tree0),
    pack_db_tree(insert(0, to_leaf(Key, Value), Tree, DB)).

%% @doc Adds multiple keys to the tree, or overwrites existing ones.
-spec insert_many([{key(), value()}], tree()) -> tree().
insert_many(List, Tree0) ->
    {Tree, DB} = unpack_db_tree(Tree0),
    insert_many(List, Tree, DB).

insert_many([{Key, Value}|T], Tree, DB) ->
    {Tree1, DB1} = insert(0, to_leaf(Key, Value), Tree, DB),
    insert_many(T, Tree1, DB1);
insert_many([], Tree, DB) ->
    pack_db_tree({Tree, DB}).

%% @doc Removes a key from a tree, if present.
-spec delete(key(), tree()) -> tree().
delete(Key, Tree0) ->
    {Tree, DB} = unpack_db_tree(Tree0),
    pack_db_tree(delete_leaf(to_leaf(Key, <<>>), Tree, DB)).

%% @doc Returns a sorted list of all the keys in the tree
-spec keys(tree()) -> [key()].
keys(Tree0) ->
    {Tree, DB} = unpack_db_tree(Tree0),
    lists:usort(raw_keys(Tree, DB)).

%% @doc Takes two trees and returns the different keys between them.
-spec diff(tree(), tree()) -> [key()].
diff(Tree10, Tree20) ->
    %% We use the remote access for this local comparison. This is
    %% slower than a dedicated traversal algorithm, but less code
    %% means fewer chances of breaking stuff.
    {Tree1, DB1} = unpack_db_tree(Tree10),
    {Tree2, DB2} = unpack_db_tree(Tree20),
    Fun = access_local(Tree2, DB2),
    diff(Tree1, DB1, Fun, <<>>).

%% @doc Takes a local tree, and an access function to another tree,
%% and returns the keys associated with diverging parts of both trees.
%% The access fun takes an atom and a path and must return a flat tree
%% node or a subtree. (`fun(Verb, Path) -> Node | undefined').
%%
%% The Path is a sequence of bytes (in a `binary()') telling how to get to
%% a specific node:
%%
%% - `<<>>' means returning the current node, at whatever point we are in the
%%   tree's traversal.
%% - `<<Offset,...>>' means to return the node at the given offset for the
%%   current tree level. For example, a value of `<<0>>' means to return the
%%   leftmost child of the current node, whereas `<<3>>' should return the
%%   4th leftmost child. Any time the path is larger than the number of
%%   children, we return `undefined'.
%%   This is the case where we can recurse.
%% - Any invalid path returns `undefined'.
%%
%% The three terms required are:
%% - `at': Uses the path as above to traverse the tree and return a node.
%% - `keys': Returns all the keys held (recursively) by the node at a given
%%   path. A special variant exists of the form `{keys, Key, Hash}', where the
%%   function must return the key set minus the one that would contain either
%%   `Key' or `Hash', but by specifying if the key and hash were encountered,
%%   and if so, if they matched or not.
%% - `child_at': Special case of `at' used when comparing child nodes of two
%%   inner nodes. Basically the same as `at', but with one new rule:
%%
%%     Whenever we hit a path that is `<<N>>' and we are on an inner node,
%%     it means we only have a child to look at. Return that child along
%%     with its byte at the offset in the dictionary structure
%%     (`{ByteAtOffset, Node}').
%%
%%  Examples of navigation through a tree of the form:
%%
%%   0 |             ___.-A-._____
%%     |           /      |       \
%%   1 |        .-B-.     C      .-D-.
%%     |       /     \          /     \
%%   2 |      E       F       .G.      H
%%     |                     /   \
%%   3 |                    I     J
%%
%%  Which is four levels deep. The following paths lead to following nodes:
%%
%%  +==============+===========+    +==============+===========+
%%  |    Path      |    Node   |    |    Path      |    Node   |
%%  +==============+===========+    +==============+===========+
%%  | <<>>         |     A     |    | <<0,1>>      |     F     |
%%  | <<0>>        |     B     |    | <<2,0>>      |     G     |
%%  | <<1>>        |     C     |    | <<2,1>>      |     H     |
%%  | <<2>>        |     D     |    | <<2,0,0>>    |     I     |
%%  | <<3>>        | undefined |    | <<2,0,1>>    |     J     |
%%  | <<0,0>>      |     E     |    | <<2,0,1,3>>  | undefined |
%%  +--------------+-----------+    +--------------+-----------+
%%
%% The values returned are all the keys that differ across both trees.
-spec dist_diff(tree(), access_fun()) -> [key()].
dist_diff(Tree0, Fun) when is_function(Fun,2) ->
    {Tree, DB} = unpack_db_tree(Tree0),
    diff(Tree, DB, Fun, <<>>).

%% @doc Returns an `access_fun()' for the current tree. This function
%% can be put at the end of a connection to a remote node, and it
%% will return serialized tree nodes.
-spec access_serialize(tree()) -> serial_fun().
access_serialize(Tree0) ->
    {Tree, DB} = unpack_db_tree(Tree0),
    fun(at, Path) -> serialize(at(Path, Tree, DB));
       (child_at, Path) -> serialize(child_at(Path, Tree, DB));
       (keys, Path) -> serialize(raw_keys(at(Path, Tree, DB), DB));
       ({keys,Key,Skip}, Path) -> serialize(raw_keys(at(Path, Tree, DB), Key, Skip, DB))
    end.

%% @doc Takes an {@link access_fun()} that fetches nodes serialized according
%% to the format used by {@link access_serialize/2}, and returns a new {@link
%% access_fun()} that will unserialized and can be used directly in
%% {@link dist_diff/2}
-spec access_unserialize(serial_fun()) -> access_fun().
access_unserialize(Fun) ->
    fun(Arg, Path) -> unserialize(Fun(Arg,Path)) end.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%

%% if the tree is empty, just use the leaf
insert(_Offset, Leaf, undefined, DB) ->
    {Leaf, db_put(Leaf, DB)};
%% If the offset is at the max value for the hash, return the leaf --
%% We can't go deeper anyway.
insert(?HASHBYTES, Leaf, _, DB) ->
    {Leaf, db_put(Leaf, DB)};
%% if the current node of the tree is a leaf and both keys are the same,
%% replace it.
insert(_Offset, Leaf=#leaf{hashkey=Key}, #leaf{hashkey=Key}, DB) ->
    {Leaf, db_put(Leaf, DB)};
%% if the current node of the tree is a leaf, and keys are different, turn the
%% current leaf into an inner node, and insert the new one in it.
insert(Offset, NewLeaf, OldLeaf=#leaf{}, DB) ->
    Inner = to_inner(Offset, OldLeaf, DB),
    insert(Offset, NewLeaf, Inner, db_put(Inner, DB));
%% Insert to an inner node!
insert(Offset, Leaf=#leaf{hashkey=Key}, Inner=#inner{children=Children}, DB) ->
    Byte = binary:at(Key, Offset),
    case orddict:find(Byte, Children) of
        error ->
            DB1 = db_put(Leaf, DB),
            NewChildren = orddict:store(Byte, db_ref(Leaf, DB1), Children),
            NewInner = Inner#inner{hashchildren=children_hash(NewChildren),
                                   children=NewChildren},
            {NewInner, db_put(NewInner, DB1)};
        {ok, SubtreeRef} ->
            Subtree = db_get(SubtreeRef, DB),
            {Subtree1, DB1} = insert(Offset+1, Leaf, Subtree, DB),
            NewChildren = orddict:store(Byte, db_ref(Subtree1, DB1), Children),
            NewInner = Inner#inner{hashchildren=children_hash(NewChildren),
                                   children=NewChildren},
            {NewInner, db_put(NewInner, DB1)}
    end.

%% Not found or empty tree. Leave as is.
delete_leaf(_, undefined, DB) ->
    {undefined, DB};
%% If we have the same leaf node we were looking for, kill it.
delete_leaf(#leaf{hashkey=K}, #leaf{hashkey=K}, DB) ->
    {undefined, DB};
%% If it's a different leaf, the item to delete is already gone. Leave as is.
delete_leaf(#leaf{}, Leaf=#leaf{}, DB) ->
    {Leaf, DB};
%% if it's an inner node, look inside
delete_leaf(Leaf=#leaf{hashkey=K}, Inner=#inner{offset=Offset, children=Children}, DB) ->
    Byte = binary:at(K, Offset),
    case orddict:find(Byte, Children) of
        error -> % not found, leave as is
            {Inner, DB};
        {ok, SubtreeHandle} ->
            Subtree = db_get(SubtreeHandle, DB),
            {Subtree1, DB1} = delete_leaf(Leaf, Subtree, DB),
            case maybe_shrink(Subtree1, DB) of
                {undefined, DB1} -> % leaf gone
                    NewChildren = orddict:erase(Byte, Children),
                    NewInner = Inner#inner{hashchildren=children_hash(NewChildren),
                                           children=NewChildren},
                    maybe_shrink(NewInner, DB1);
                {Node, DB1} -> % replacement node
                    NewChildren = orddict:store(Byte, db_ref(Node, DB), Children),
                    NewInner = Inner#inner{hashchildren=children_hash(NewChildren),
                                           children=NewChildren},
                    maybe_shrink(NewInner, DB1)
            end
    end.

raw_keys(undefined,_DB) ->
    [];
raw_keys(#leaf{userkey=Key},_DB) ->
    [Key];
raw_keys(#inner{children=Children}, DB) ->
    lists:append(orddict:fold(
        fun(_Byte, NodeHandle, Acc) ->
                [raw_keys(db_get(NodeHandle, DB), DB)|Acc] end,
        [],
        Children
    )).

%% Same as raw_keys/1, but reports on a given hash and key
raw_keys(I=#inner{}, KeyToWatch, ToSkip, DB) -> raw_keys(I, KeyToWatch, ToSkip, unseen, DB).

raw_keys(undefined, _, _, Status,_DB) ->
    {Status, []};
raw_keys(#leaf{hash=Hash}, _, Hash, Status,_DB) ->
    {merge_status(same, Status), []};
raw_keys(#leaf{userkey=Key}, Key, _, Status,_DB) ->
    {merge_status(diff, Status), []};
raw_keys(#leaf{userkey=Key}, _, _, Status,_DB) ->
    {Status, [Key]};
raw_keys(#inner{children=Children}, Key, ToSkip, InitStatus, DB) ->
    {Status, DeepList} = lists:foldl(
        fun({_, NodeHandle}, {Status, Acc}) ->
            Node = db_get(NodeHandle, DB),
            {NewStatus, ToAdd} = raw_keys(Node, Key, ToSkip, Status, DB),
            {NewStatus, [ToAdd|Acc]}
        end,
        {InitStatus, []},
        Children
    ),
    {Status, lists:append(DeepList)}.

%% We shouldn't get to see both 'seen' and 'diff' at once.
%% That would mean the tree may contain many similar keys
%% in many places
merge_status(same, unseen) -> same;
merge_status(diff, unseen) -> diff.

-spec diff(tree(), db(), access_fun(), path()) -> [key()].
diff(Tree, DB, Fun, Path) ->
    lists:usort(raw_diff(Tree, Fun(at, Path), Fun, Path, DB)).


%% Empty trees yield all keys of remaining trees
raw_diff(undefined, undefined, _, _, _) ->
    [];
raw_diff(undefined, _Tree2, Fun, Path,_DB) ->
    Fun(keys, Path);
raw_diff(Tree1, undefined, _, _, DB) ->
    raw_keys(Tree1, DB);
%% If hashes are the same, we're done.
raw_diff(#leaf{hash=Hash}, #leaf{hash=Hash}, _, _, _) ->
    [];
raw_diff(#leaf{hash=Hash}, #inner{hashchildren=Hash}, _, _, _) ->
    [];
raw_diff(#inner{hashchildren=Hash}, #leaf{hash=Hash}, _, _, _) ->
    [];
raw_diff(#inner{hashchildren=Hash}, #inner{hashchildren=Hash}, _, _, _) ->
    [];
%% if they differ and both nodes are leaf nodes, return both values
raw_diff(#leaf{userkey=Key1}, #leaf{userkey=Key2}, _, _, _) ->
    [Key1,Key2];
%% if both differ but one is an inner node, return everything
raw_diff(#leaf{userkey=Key, hash=ToSkip}, #inner{}, Fun, Path,_DB) ->
    %% We can only get rid of the current Key if the hashes are the same
    case Fun({keys, Key, ToSkip}, Path) of
        {same, Keys} -> Keys;
        {diff, Keys} -> [Key|Keys];
        {unseen, Keys} -> [Key|Keys]
    end;
raw_diff(Inner=#inner{}, #leaf{userkey=Key, hash=ToSkip}, _, _, DB) ->
    %% We can only get rid of the current Key if the hashes are the same
    case raw_keys(Inner, Key, ToSkip, DB) of
        {same, Keys} -> Keys;
        {diff, Keys} -> [Key|Keys];
        {unseen, Keys} -> [Key|Keys]
    end;
%% if both nodes are inner and populated, compare them offset by offset.
raw_diff(#inner{children=Children}, #inner{}, Fun, Path, DB) ->
    ChildPath = <<Path/binary, 0>>,
    diff_offsets(children_offsets(Children),
                 Fun(child_at, ChildPath),
                 Fun,
                 ChildPath,
                 DB).

%% Whatever is left alone is returned
diff_offsets([], undefined, _, _, _) ->
    [];
diff_offsets(List, undefined, _, _, DB) ->
    lists:append([raw_keys(db_get(Child, DB), DB) || {_, Child} <- List]);
diff_offsets([], _, Fun, Path, DB) ->
    Keys = Fun(keys, Path),
    case next_child_path(Path) of
        undefined -> Keys;
        Next -> Keys ++ diff_offsets([], Fun(child_at, Next), Fun, Next, DB)
    end;
%% If both offsets are the same, compare recursively.
diff_offsets(L=[{OffL, Child0}|Rest], R={OffR,Node}, Fun, Path, DB) ->
    Child = db_get(Child0, DB),
    if OffL =:= OffR ->
            Diff = raw_diff(Child, Node, Fun, Path, DB),
            case next_child_path(Path) of
                undefined -> Diff;
                Next -> Diff ++ diff_offsets(Rest, Fun(child_at, Next), Fun, Next, DB)
            end;
       OffL < OffR ->
            raw_keys(Child, DB) ++ diff_offsets(Rest, R, Fun, Path, DB);
       OffL > OffR ->
            Keys = Fun(keys, Path),
            case next_child_path(Path) of
                undefined -> Keys;
                Next -> Keys ++ diff_offsets(L, Fun(child_at, Next), Fun, Next, DB)
            end
    end.

next_child_path(Path) ->
    ParentSize = byte_size(Path) - 1,
    <<ParentPath:ParentSize/binary, ChildByte>> = Path,
    case ChildByte+1 of
        256 -> undefined;
        Next -> <<ParentPath/binary, Next>>
    end.

%%% Basic Tree Management Functions

%% @doc Takes a Key and a Value and turns them to a leaf node.
-spec to_leaf(key(), value()) -> leaf().
to_leaf(Key, Value) when is_binary(Key) ->
    %% We use the hash of the value as part of the 'hash' entry,
    %% but not the 'hashkey'. This allows a tree where the structure
    %% is based on the keys, but we can still compare and use both
    %% the key and its value to do comparison when diffing.
    HashKey = crypto:hash(?HASH, Key),
    HashVal = crypto:hash(?HASH, Value),
    #leaf{userkey=Key,
          hashkey=HashKey,
          hash=crypto:hash(?HASH, <<HashKey/binary, HashVal/binary>>)}.

%% @doc We build a Key-Value list of the child nodes and their offset
%% to be used as a sparse K-ary tree.
-spec to_inner(offset(), leaf(), db()) -> inner().
to_inner(Offset, Child=#leaf{hashkey=Hash}, DB) ->
    ChildRef = db_ref(Child, DB),
    Children = orddict:store(binary:at(Hash, Offset), ChildRef, orddict:new()),
    #inner{hashchildren=children_hash(Children),
           children=Children,
           offset=Offset}.

%% @doc The hash for the node is put together in a somewhat portable way:
%% fetch the hashes for all the children, sort them by the value
%% they would yield for each byte being converted as an integer, and
%% then apply the ?HASH to the entire sequence in that order.
%%
%% We use the 'hash' value for leaf nodes so that comparison can be done
%% while caring about both keys and values. This has no impact on position
%% of inner nodes, because it is dictated by the children's keyhashes, and
%% not the inner node's own hashes.
%% @todo consider endianness for absolute portability
-spec children_hash([{offset(), leaf()}, ...]) -> binary().
children_hash([{_, B}|_] = Children) when is_binary(B) ->
    %% This is in db mode
    Hashes = [ChildHash || {_Offset, ChildHash} <- Children],
    crypto:hash(?HASH, Hashes);
children_hash(Children) ->
    Hashes = [element(?HASHPOS, Child) || {_Offset, Child} <- Children],
    crypto:hash(?HASH, Hashes).

%% @doc Checks if the node can be shrunken down to a single leaf it contains
%% or should just be returned as is.
%% This avoids a problem where a deleted subtree results in an inner node
%% with a single element, which wastes space and can slow down diffing.
maybe_shrink(Leaf = #leaf{}, DB) ->
    {Leaf, DB};
maybe_shrink(undefined, DB) ->
    {undefined, DB};
maybe_shrink(Inner = #inner{children=Children}, DB) ->
    %% The trick for this one is that if we have *any* child set that
    %% is anything else than a single leaf node, we can't shrink. We use
    %% a fold with a quick try ... catch to quickly figure this out, in
    %% two iterations at most.
    try
        orddict:fold(fun(_Offset, NodeHandle, 0) ->
                             case db_get(NodeHandle, DB) of
                                 #leaf{} = Leaf ->
                                     {Leaf, DB};
                                 _ ->
                                     throw(false)
                             end;
                        (_, _, _) -> throw(false)
                     end, 0, Children)
    catch
        throw:false -> {Inner, db_put(Inner, DB)}
    end.

%% @doc Returns the sorted offsets of a given child. Because we're using
%% orddicts, we can just straight up return the children as is, but another
%% data structure would need to transform them into a key/value list sorted
%% by the offset: [{Offet, ChildNode}].
children_offsets(Children) -> Children.

%% Wrapper for the diff function.
access_local(Node, DB) ->
    fun(at, Path) -> at(Path, Node, DB);
       (child_at, Path) -> child_at(Path, Node, DB);
       (keys, Path) -> raw_keys(at(Path, Node, DB), DB);
       ({keys, Key, Skip}, Path) -> raw_keys(at(Path, Node, DB), Key, Skip, DB)
    end.

%% Return the node at a given position in a tree.
at(Path, Tree, DB) ->
    case child_at(Path, Tree, DB) of
        {_Off, Node} -> Node;
        Node -> Node
    end.

%% Special case of at/2 that returns the node at a given position in a tree,
%% but if the resulting node is the child of an inner node, return it with
%% its indexed offset.
%% This allows to diff inner nodes without contextual info while in the
%% offset traversal.
child_at(<<>>, Node,_DB) ->
    %% End of path, return whatever
    Node;
child_at(<<N,Rest/binary>>, #inner{children=Children}, DB) ->
    %% Depending on the path depth, the behavior changes. If the path depth
    %% left is of one (i.e. `<<N>> = <<N,Rest/binary>>') and that we are in
    %% an inner node, then we're looking for the child definition as
    %% `{ByteAtOffset, ChildNode}'.
    %% Otherwise, this is how we keep recursing by looking deeper in a
    %% inner node.
    %% If the path goes past what the node contains, we return `undefined'.
    try
        orddict:fold(fun(Off, Node, 0) when Rest =:= <<>> -> throw({Off,Node});
                        (_, Node, 0) -> throw(Node);
                        (_, _, X) -> X-1
                     end, N, Children),
        undefined
    catch
        throw:{Off,Node} -> {Off, db_get(Node, DB)};
        throw:Node -> child_at(Rest, db_get(Node, DB), DB)
    end;
%% Invalid path
child_at(_, _, _) ->
    undefined.

%% Serialize nodes flatly. All terms are self-contained and their
%% trailing value can be used as one blob. A protocol using this format
%% of serialization should therefore frame each binary before concatenating
%% them.
%%
%% Note that this format is sufficient for diffing, but not to rebuild entire
%% trees from scratch.
serialize(undefined) ->
    <<?VSN, ?UNDEFINED>>;
serialize(#leaf{userkey=Key, hashkey=HKey, hash=Hash}) ->
    <<?VSN, ?LEAF, ?HASHBYTES:32, HKey/binary, Hash/binary, Key/binary>>;
serialize(#inner{hashchildren=Hash}) ->
    <<?VSN, ?INNER, ?HASHBYTES:32, Hash/binary>>;
serialize({Offset, Node}) when is_record(Node, leaf); is_record(Node, inner) ->
    <<?VSN, ?OFFSETBYTE, Offset, (serialize(Node))/binary>>;
serialize(Keys) when is_list(Keys) ->
    Serialized = << <<(byte_size(Key)):16, Key/binary>> || Key <- Keys >>,
    <<?VSN, ?KEYS, (length(Keys)):16, Serialized/binary>>;
serialize({Word, Keys}) when is_list(Keys), is_atom(Word) ->
    Seen = case Word of
        unseen -> ?KEYS_SKIP_UNSEEN;
        same -> ?KEYS_SKIP_SAME;
        diff -> ?KEYS_SKIP_DIFF
    end,
    Serialized = << <<(byte_size(Key)):16, Key/binary>> || Key <- Keys >>,
    <<?VSN, ?KEYS_SKIP, Seen:2, (length(Keys)):16, Serialized/binary>>.

%% Deserialize nodes flatly. Assume self-contained binaries.
%%
%% Note that this format is sufficient for diffing, but not to rebuild entire
%% trees from scratch.
unserialize(<<?VSN, ?UNDEFINED>>) ->
    undefined;
unserialize(<<?VSN, ?LEAF, ?HASHBYTES:32, HKey:?HASHBYTES/binary,
              Hash:?HASHBYTES/binary, Key/binary>>) ->
    #leaf{userkey=Key, hashkey=HKey, hash=Hash};
unserialize(<<?VSN, ?INNER, ?HASHBYTES:32, Hash:?HASHBYTES/binary>>) ->
    %% Cheat a little to please Dialyzer
    #inner{hashchildren=Hash, children=[], offset=256};
unserialize(<<?VSN, ?OFFSETBYTE, Byte, Node/binary>>) ->
    {Byte, unserialize(Node)};
unserialize(<<?VSN, ?KEYS, NumKeys:16, Serialized/binary>>) ->
    Keys = [Key || <<Size:16, Key:Size/binary>> <= Serialized],
    NumKeys = length(Keys),
    Keys;
unserialize(<<?VSN, ?KEYS_SKIP, Seen:2, NumKeys:16, Serialized/binary>>) ->
    Word = case Seen of
        ?KEYS_SKIP_UNSEEN -> unseen;
        ?KEYS_SKIP_SAME -> same;
        ?KEYS_SKIP_DIFF -> diff
    end,
    Keys = [Key || <<Size:16, Key:Size/binary>> <= Serialized],
    NumKeys = length(Keys),
    {Word, Keys}.

db_put(_, no_db) ->
    no_db;
db_put(#leaf{hash = Hash} = Node, #db{put=Put, handle=Handle} = DB) ->
    DB#db{handle=Put(Hash, Node, Handle)};
db_put(#inner{hashchildren = Hash} = Node, #db{put=Put, handle=Handle} = DB) ->
    DB#db{handle=Put(Hash, Node, Handle)}.

db_get(X, no_db) when is_record(X, inner) orelse is_record(X, leaf) orelse X =:= undefined ->
    X;
db_get(X, #db{get=Get, handle=Handle}) when is_binary(X) ->
    Get(X, Handle);
db_get(undefined, #db{}) ->
    undefined.

db_ref(X, no_db) when is_record(X, inner) orelse is_record(X, leaf) orelse X =:= undefined ->
    X;
db_ref(#leaf{hash=Hash}, #db{}) ->
    Hash;
db_ref(#inner{hashchildren=Hash}, #db{}) ->
    Hash.

