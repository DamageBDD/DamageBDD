%%%-------------------------------------------------------------------
%%% Shared support for damage_context EUnit modules.
%%%
%%% Every test fixture gets its own DETS file and deterministic master key.
%%% No test reads or writes the node's configured context store or secrets vault.
%%%-------------------------------------------------------------------
-module(damage_context_test_support).

-include_lib("kernel/include/file.hrl").

-export([
    setup_store/0,
    cleanup_store/1,
    restart_store/0,
    stop_store/0,
    account/1,
    account_scope/1,
    wallet_scope/2,
    agent_scope/2,
    entry/1,
    entry/2,
    store_file/1,
    hex/1
]).

-define(ETS_TABLE, damage_context_cache).
-define(DETS_TABLE, damage_context_store_dets).

-spec setup_store() -> map().
setup_store() ->
    {ok, _} = application:ensure_all_started(crypto),
    OldEnv = save_env([
        context_store_file,
        context_store_master_key,
        context_sync_writes,
        context_max_bytes,
        context_data_dir
    ]),
    ok = stop_store(),
    Dir = unique_tmp_dir(),
    StoreFile = filename:join(Dir, "context.dets"),
    ok = filelib:ensure_dir(StoreFile),
    MasterKey = crypto:hash(sha256, <<"damage-context-eunit-master-key">>),
    ok = application:set_env(damage, context_store_file, StoreFile),
    ok = application:set_env(damage, context_store_master_key, MasterKey),
    ok = application:set_env(damage, context_sync_writes, true),
    ok = application:unset_env(damage, context_max_bytes),
    ok = damage_context_store:ensure_started(),
    #{dir => Dir, store_file => StoreFile, old_env => OldEnv}.

-spec cleanup_store(map()) -> ok.
cleanup_store(#{dir := Dir, old_env := OldEnv}) ->
    ok = stop_store(),
    restore_env(OldEnv),
    rm_rf(Dir),
    ok.

-spec restart_store() -> ok.
restart_store() ->
    ok = stop_store(),
    ok = damage_context_store:ensure_started().

-spec stop_store() -> ok.
stop_store() ->
    case whereis(damage_context_store) of
        undefined ->
            ok;
        Pid when is_pid(Pid) ->
            Ref = erlang:monitor(process, Pid),
            _ = ignore_exception(fun damage_context_store:stop/0),
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            after 5000 ->
                erlang:demonitor(Ref, [flush]),
                exit({damage_context_store_stop_timeout, Pid})
            end
    end,
    _ = ignore_exception(fun() -> dets:close(?DETS_TABLE) end),
    _ = ignore_exception(fun() -> ets:delete(?ETS_TABLE) end),
    ok.

-spec account(iodata()) -> binary().
account(Seed0) ->
    Seed = iolist_to_binary(Seed0),
    PubKey = crypto:hash(sha256, <<"damage-context-test-account:", Seed/binary>>),
    try aeser_api_encoder:encode(account_pubkey, PubKey) of
        Encoded when is_binary(Encoded) -> Encoded;
        Encoded when is_list(Encoded) -> unicode:characters_to_binary(Encoded)
    catch
        _:_ -> <<"ak_", (hex(PubKey))/binary>>
    end.

-spec account_scope(iodata()) -> map().
account_scope(Seed) ->
    #{kind => account, owner => account(Seed), id => <<"default">>}.

-spec wallet_scope(iodata(), term()) -> map().
wallet_scope(Seed, WalletId) ->
    #{kind => wallet, owner => account(Seed), id => stable_id(WalletId)}.

-spec agent_scope(iodata(), term()) -> map().
agent_scope(Seed, AgentId) ->
    #{kind => agent, owner => account(Seed), id => stable_id(AgentId)}.

-spec entry(term()) -> map().
entry(Value) ->
    entry(Value, #{}).

-spec entry(term(), map()) -> map().
entry(Value, Overrides) ->
    maps:merge(
        #{
            value => Value,
            sensitive => false,
            exposure => template,
            inheritance => none,
            locked => false,
            updated_at => 1000
        },
        Overrides
    ).

-spec store_file(map()) -> file:filename_all().
store_file(#{store_file := File}) ->
    File.

-spec hex(binary()) -> binary().
hex(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

stable_id(Value) ->
    hex(crypto:hash(sha256, term_to_binary(Value, [deterministic]))).

save_env(Keys) ->
    [{Key, application:get_env(damage, Key)} || Key <- Keys].

restore_env([{Key, undefined} | Rest]) ->
    ok = application:unset_env(damage, Key),
    restore_env(Rest);
restore_env([{Key, {ok, Value}} | Rest]) ->
    ok = application:set_env(damage, Key, Value),
    restore_env(Rest);
restore_env([]) ->
    ok.

ignore_exception(Fun) when is_function(Fun, 0) ->
    try Fun() of
        Result -> Result
    catch
        _Class:_Reason -> ignored
    end.

unique_tmp_dir() ->
    Root =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Value -> Value
        end,
    Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])),
    filename:join(Root, "damage_context_eunit_" ++ Suffix).

rm_rf(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            case file:list_dir(Path) of
                {ok, Names} ->
                    lists:foreach(fun(Name) -> rm_rf(filename:join(Path, Name)) end, Names);
                {error, enoent} ->
                    ok
            end,
            _ = file:del_dir(Path),
            ok;
        {ok, _Info} ->
            _ = file:delete(Path),
            ok;
        {error, enoent} ->
            ok;
        {error, _Reason} ->
            ok
    end.
