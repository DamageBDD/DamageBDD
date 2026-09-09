%% Copyright Steven Joseph <steven@stevenjoseph.in>
%% SPDX-License-Identifier: Apache-2.0
-module(damage_ipfs).
-compile({no_auto_import, [get/1]}).
-behaviour(gen_server).
-export([
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
-export([
    pin/1,
    add/1,
    get/1, get/2,
    cat/1,
    cat_binary/1,
    ls/1,
    fetch_to/2,
    ensure_ipfs_asset/2,
    hydrate_feature_from_ipfs/1,
    test/0,
    pin_async/1,
    unpin_async/1,
    pin_status/1,
    status/0
]).

%% Legacy poolboy worker entry retained for a staged migration. It no longer
%% checks network availability in init. Remove that pool when installing sup.
start_link(Members) -> gen_server:start_link(?MODULE, Members, []).
init([{Host, Port} | _]) ->
    C = damage_ipfs_config:load(),
    H = damage_ipfs_config:text(Host),
    Authority =
        case lists:member($:, H) of
            true -> "[" ++ H ++ "]";
            false -> H
        end,
    {ok, C#{ipfs_api => "http://" ++ Authority ++ ":" ++ integer_to_list(Port)}};
init(C) when is_map(C) -> {ok, damage_ipfs_config:normalize(C)};
init(_) ->
    {stop, invalid_ipfs_members}.
handle_call(R, _, C) ->
    Result =
        try damage_ipfs_client:execute(R, C) of
            V -> V
        catch
            Class:Reason -> {error, {backend_exception, Class, Reason}}
        end,
    {reply, Result, C}.
handle_cast(_, C) -> {noreply, C}.
handle_info(_, C) -> {noreply, C}.
terminate(_, _) -> ok.
code_change(_, C, _) -> {ok, C}.

%% Immediate legacy API: response shapes remain owned by the ipfs dependency.
%% Use pin_async/1 to register durable desired state for retry/reconciliation.
pin(Hashes) -> request({pin, Hashes}).
add({data, _, _} = What) -> request({add, What});
add({file, _} = What) -> request({add, What});
add({directory, _} = What) -> request({add, What});
add(_) -> {error, invalid_add_request}.
ls(Cid) -> request({ls, Cid}).
get(Cid) -> cat_binary(Cid).
get(Cid, Path) -> fetch_request({get, Cid, Path}).
cat(Cid) -> fetch_request({cat, Cid}).
cat_binary(Cid) ->
    case cat(Cid) of
        {ok, B} when is_binary(B) -> {ok, B};
        B when is_binary(B) -> {ok, B};
        {error, _} = E -> E;
        Other -> {error, {invalid_ipfs_cat_response, Other}}
    end.
pin_async(Cid) -> damage_ipfs_pinner:pin(Cid).
unpin_async(Cid) -> damage_ipfs_pinner:unpin(Cid).
pin_status(Cid) -> damage_ipfs_store:lookup(Cid).
status() ->
    #{
        client => damage_ipfs_client:status(),
        fetcher => damage_ipfs_fetcher:status(),
        pinner => damage_ipfs_pinner:status(),
        reconciler => damage_ipfs_reconciler:status(),
        health => damage_ipfs_health:status(),
        peers => damage_ipfs_peers:status()
    }.
test() -> status().

request(R) ->
    case whereis(damage_ipfs_client) of
        undefined -> legacy_request(R);
        _ -> damage_ipfs_client:request(R)
    end.
fetch_request(R) ->
    case whereis(damage_ipfs_client) of
        undefined ->
            legacy_request(R);
        _ ->
            case R of
                {cat, Cid} -> damage_ipfs_fetcher:cat(Cid);
                {get, Cid, Path} -> damage_ipfs_fetcher:get(Cid, Path)
            end
    end.
legacy_request(R) ->
    case whereis(?MODULE) of
        undefined ->
            {error, not_started};
        _ ->
            T = maps:get(request_timeout_ms, damage_ipfs_config:load()),
            try
                poolboy:transaction(
                    ?MODULE,
                    fun(P) -> damage_ipfs_config:call(P, R, T + 1000) end,
                    1000
                )
            catch
                exit:_ -> {error, unavailable};
                error:undef -> {error, poolboy_unavailable}
            end
    end.

fetch_to(Cid, Path) ->
    case filelib:ensure_dir(Path) of
        ok -> get(Cid, Path);
        {error, R} -> {error, {mkdir, R}}
    end.
ensure_ipfs_asset(Cid, Path0) ->
    Path = damage_ipfs_config:text(Path0),
    case filelib:is_regular(Path) of
        true ->
            ok;
        false ->
            %% A single-file asset is staged atomically. A failed download must
            %% not leave a partial path that is treated as a cache hit later.
            case cat_binary(Cid) of
                {ok, B} -> atomic_write(Path, B);
                E -> E
            end
    end.
atomic_write(Path, B) ->
    case filelib:ensure_dir(Path) of
        ok ->
            Tmp =
                Path ++ ".ipfs-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])) ++
                    ".tmp",
            case file:open(Tmp, [write, binary, raw, exclusive]) of
                {ok, Fd} ->
                    R =
                        try
                            case file:write(Fd, B) of
                                ok -> file:sync(Fd);
                                E0 -> E0
                            end
                        after
                            file:close(Fd)
                        end,
                    Final =
                        case R of
                            ok -> file:rename(Tmp, Path);
                            E1 -> E1
                        end,
                    case Final of
                        ok ->
                            ok;
                        E2 ->
                            _ = file:delete(Tmp),
                            E2
                    end;
                E ->
                    E
            end;
        E ->
            E
    end.

hydrate_feature_from_ipfs(Json) when is_map(Json) ->
    case maps:get(feature_cid, Json, undefined) of
        undefined ->
            {error, missing_feature_cid};
        Cid ->
            case cat_binary(Cid) of
                {ok, Feature} ->
                    Vars =
                        case maps:get(vars, Json, #{}) of
                            M when is_map(M) -> M;
                            _ -> #{}
                        end,
                    {ok, maps:merge(Vars, maps:remove(vars, Json#{feature => Feature}))};
                E ->
                    {error, {ipfs_cat_failed, Cid, E}}
            end
    end;
hydrate_feature_from_ipfs(_) ->
    {error, invalid_feature_context}.
