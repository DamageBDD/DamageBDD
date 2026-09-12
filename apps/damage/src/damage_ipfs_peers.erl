%% Copyright Steven Joseph. SPDX-License-Identifier: Apache-2.0
%% Non-blocking, supervised peer maintenance against the SAME configured node
%% used by pinning and health. Runtime peer edits persist until subtree restart.
-module(damage_ipfs_peers).
-export([
    start_link/0, start_link/1,
    ensure_started/0,
    add_peers/1,
    set_peers/1,
    get_peers/0,
    connect_all/0,
    status/0,
    run/2,
    normalize/1,
    normalize_groups/1,
    target_id/1
]).

start_link() -> start_link(damage_ipfs_config:load()).
start_link(Opts) when is_list(Opts) -> start_link(damage_ipfs_config:normalize(Opts));
start_link(Opts) ->
    C0 =
        case maps:find(retry_interval, Opts) of
            {ok, I} -> Opts#{peer_interval_ms => I};
            error -> Opts
        end,
    C = damage_ipfs_config:normalize(C0),
    case validated(maps:get(ipfs_peers, C), C) of
        {ok, Peers} ->
            damage_ipfs_loop:start_link(
                ?MODULE,
                ?MODULE,
                maps:get(peer_interval_ms, C),
                C,
                #{peers => Peers, cursor => 0, addr_cursor => 0}
            );
        {error, R} ->
            {error, R}
    end.
ensure_started() ->
    case whereis(?MODULE) of
        P when is_pid(P) -> {ok, P};
        undefined -> {error, ipfs_supervisor_required}
    end.
get_peers() ->
    case damage_ipfs_loop:data(?MODULE) of
        #{peers := P} -> addresses(P);
        E -> E
    end.
set_peers(Peers) -> change_peers(Peers, replace).
add_peers(Peers) ->
    case change_peers(Peers, append) of
        {ok, scheduled} -> ok;
        E -> E
    end.
connect_all() -> damage_ipfs_loop:trigger(?MODULE).
status() -> damage_ipfs_loop:status(?MODULE).
change_peers(Peers, Mode) ->
    damage_ipfs_loop:update_data(?MODULE, fun(#{peers := Old}, C) ->
        case validated(Peers, C) of
            {ok, P0} ->
                Specs =
                    case Mode of
                        replace -> P0;
                        append -> Old ++ P0
                    end,
                case validated(Specs, C) of
                    {ok, P} -> {ok, #{peers => P, cursor => 0, addr_cursor => 0}};
                    E -> E
                end;
            E ->
                E
        end
    end).

run(_, #{peers := []} = D) ->
    {ok, summary(), D};
run(C, #{peers := Peers, cursor := Cursor} = D) ->
    Deadline =
        erlang:monotonic_time(millisecond) + maps:get(loop_timeout_ms, C) -
            maps:get(request_timeout_ms, C) - 2000,
    %% Refresh identity each pass: Kubo may have restarted with another repo.
    case damage_ipfs_client:request(identity) of
        {ok, #{<<"ID">> := Self}} when is_binary(Self) ->
            {Before, After} = lists:split(Cursor rem length(Peers), Peers),
            connect(
                After ++ Before,
                Self,
                Deadline,
                D,
                0,
                maps:get(addr_cursor, D, 0),
                summary()
            );
        {error, _} = E ->
            E;
        _ ->
            {error, invalid_identity_response}
    end.
connect([], _, _, D, N, _, Summary) ->
    peer_result(D, N, 0, Summary);
connect([#{peer_id := Id, addrs := Addrs} | Rest], Self, Deadline, D, N, Offset, Summary) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            peer_result(D, N, Offset, Summary#{partial => true});
        false ->
            case Id =:= Self of
                true ->
                    connect(Rest, Self, Deadline, D, N + 1, 0, inc(skipped_self, Summary));
                false ->
                    %% Resume inside a peer when a slow failed address consumed
                    %% the previous pass. Otherwise its fallback could starve.
                    Remaining = lists:nthtail(Offset, Addrs),
                    case connect_addrs(Remaining, Deadline, Offset, Summary) of
                        {connected, S1} ->
                            connect(Rest, Self, Deadline, D, N + 1, 0, inc(connected, S1));
                        {failed, S1} ->
                            connect(Rest, Self, Deadline, D, N + 1, 0, inc(failed, S1));
                        {partial, NextOffset, S1} ->
                            peer_result(D, N, NextOffset, S1#{partial => true})
                    end
            end
    end.
connect_addrs([], _, _, Summary) ->
    {failed, Summary};
connect_addrs([Addr | Rest], Deadline, Offset, Summary) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            {partial, Offset, Summary};
        false ->
            S1 = inc(attempted_addresses, Summary),
            case damage_ipfs_client:request({connect, Addr}) of
                {ok, _} -> {connected, S1};
                _ -> connect_addrs(Rest, Deadline, Offset + 1, inc(address_failures, S1))
            end
    end.
peer_result(D = #{peers := Peers, cursor := Cursor}, N, Offset, Summary) ->
    {ok, Summary#{attempted => N}, D#{
        cursor => (Cursor + N) rem length(Peers), addr_cursor => Offset
    }}.
summary() ->
    #{
        connected => 0,
        skipped_self => 0,
        failed => 0,
        attempted => 0,
        attempted_addresses => 0,
        address_failures => 0
    }.
inc(Key, Summary) -> Summary#{Key => maps:get(Key, Summary) + 1}.

validated(Peers, C) ->
    case normalize_groups(Peers) of
        {ok, P} ->
            %% Preserve the old total-address bound as well as peer grouping.
            case length(addresses(P)) =< maps:get(max_peers, C) of
                true -> {ok, P};
                false -> {error, too_many_peers}
            end;
        E ->
            E
    end.
%% Retain the flat public normalization/get_peers result while using grouped
%% state internally. Both peer order and transport preference are stable.
normalize(Peers) ->
    case normalize_groups(Peers) of
        {ok, Groups} -> {ok, addresses(Groups)};
        E -> E
    end.
normalize_groups(Peers) when is_list(Peers) ->
    try
        Addrs = lists:append([peer(P) || P <- Peers]),
        {Order, Groups} = lists:foldl(
            fun(A, {Ids, G}) ->
                Id = target_id(A),
                case maps:find(Id, G) of
                    error ->
                        {[Id | Ids], G#{Id => [A]}};
                    {ok, Existing} ->
                        case lists:member(A, Existing) of
                            true -> {Ids, G};
                            false -> {Ids, G#{Id => [A | Existing]}}
                        end
                end
            end,
            {[], #{}},
            Addrs
        ),
        {ok, [
            #{peer_id => Id, addrs => lists:reverse(maps:get(Id, Groups))}
         || Id <- lists:reverse(Order)
        ]}
    catch
        error:_ -> {error, invalid_peer_spec}
    end;
normalize_groups(_) ->
    {error, invalid_peer_spec}.
addresses(Groups) -> lists:append([As || #{addrs := As} <- Groups]).
peer([{K, _} | _] = Opts) when is_atom(K) ->
    true = lists:all(
        fun
            ({Key, _}) when is_atom(Key) -> true;
            (_) -> false
        end,
        Opts
    ),
    peer(maps:from_list(lists:reverse(Opts)));
peer(P) when is_list(P); is_binary(P) -> [address(P)];
peer(#{peer_id := Id0, addrs := Addrs}) when is_list(Addrs), Addrs =/= [] ->
    Id = iolist_to_binary(Id0),
    {ok, Id} = damage_ipfs_config:cid(Id),
    [
        begin
            A = address_text(A0),
            case target_id(A) of
                undefined -> address(<<A/binary, "/p2p/", Id/binary>>);
                Id -> address(A);
                _ -> error(peer_id_mismatch)
            end
        end
     || A0 <- Addrs
    ];
peer(#{addrs := Addrs}) when is_list(Addrs), Addrs =/= [] -> [address(A) || A <- Addrs].
address(A0) ->
    A = address_text(A0),
    case target_id(A) of
        undefined -> error(missing_target_peer_id);
        _ -> A
    end.
address_text(A0) ->
    A = iolist_to_binary(A0),
    true = byte_size(A) > 1 andalso byte_size(A) =< 4096,
    <<"/", _/binary>> = A,
    nomatch = re:run(A, "[\\x00-\\x20\\x7f?#]", [{capture, none}]),
    A.
%% The destination is the terminal /p2p/<id>, not the relay's peer ID.
%% /p2p-circuit is valueless, so parsing pairs from the front is incorrect.
target_id(A0) ->
    Parts = binary:split(iolist_to_binary(A0), <<"/">>, [global, trim_all]),
    case lists:reverse(Parts) of
        [Id, <<"p2p">> | _] when byte_size(Id) > 0 -> Id;
        [Id, <<"ipfs">> | _] when byte_size(Id) > 0 -> Id;
        _ -> undefined
    end.
