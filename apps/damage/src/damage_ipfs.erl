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
    %% Bounded, local-daemon reads for integrity-sensitive artifacts.
    cat_binary/2,
    cat_json/2,
    cat_fold/4,
    sha256/2,
    decode_json/2,
    valid_cid/1,
    valid_relative_path/1,
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

-ifdef(TEST).
-export([cat_fold_config/5, local_endpoint/1, cid_path/1]).
-endif.

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


%% ------------------------------------------------------------------
%% Bounded reads from the configured validating Kubo daemon.
%%
%% These APIs are additive: cat/1, cat_binary/1, get/1,2 and the legacy
%% client/fetcher/pool messages above keep their existing behaviour.
%%
%% One streaming implementation is shared by bounded binary reads, JSON
%% reads and SHA-256 hashing. Do not implement sha256 via cat_binary/1:
%% release packages can be gigabytes. Only the accumulator is retained.
%%
%% Options are a proplist:
%%   {max_bytes, N}  (default 1 MiB; request N+1 to detect truncation)
%%   {timeout, Ms}   (default shared request_timeout_ms, total fold deadline)
%%
%% Fold runs in a short-lived worker, not the caller. Pass all state through
%% Initial/the accumulator: process dictionary entries and self() are local to
%% that worker. Callbacks must not spawn unmanaged work or rely on side effects
%% being rolled back. A timeout cancels the worker and its linked Gun process;
%% it cannot undo completed external effects or preempt a blocking native NIF.
%%
%% Read ipfs_api from damage_ipfs_config:load(), not a second release-only
%% endpoint. The trusted reader deliberately requires numeric loopback,
%% HTTP and the standard RPC path. Never use a public gateway, proxy or
%% redirect here. Fail closed when the shared endpoint is not local.
%% These bounded calls own their Gun stream; they do not add unsupported
%% streaming messages to the existing client/fetcher implementations.
%% ------------------------------------------------------------------
-spec cat_binary(binary() | string(), proplists:proplist()) ->
    {ok, binary()} | {error, term()}.
cat_binary(Path, Options) ->
    case cat_fold(Path, fun(Data, Acc) -> [Data | Acc] end, [], Options) of
        {ok, Chunks} -> {ok, iolist_to_binary(lists:reverse(Chunks))};
        Error -> Error
    end.

-spec cat_json(binary() | string(), proplists:proplist()) ->
    {ok, term()} | {error, term()}.
cat_json(Path, Options) ->
    case cat_binary(Path, Options) of
        {ok, Data} -> decode_json(Data, Options);
        Error -> Error
    end.

%% Preserve binary JSON keys. Callers decide which JSON types/schema they
%% accept; the IPFS layer must not know release-specific metadata fields.
-spec decode_json(binary(), proplists:proplist()) ->
    {ok, term()} | {error, term()}.
decode_json(Data, Options) ->
    ipfs_guard(fun() ->
        Limit = read_limit(Options),
        ipfs_require(is_binary(Data), invalid_ipfs_json),
        ipfs_require(byte_size(Data) =< Limit, ipfs_object_too_large),
        %% Reuse the backend's shared decoder selection (OTP json,
        %% JSX, then Jiffy). Keep this facade's limits and error vocabulary;
        %% no release-specific JSON rules belong in either IPFS module.
        case damage_ipfs_backend:decode_json(Data) of
            {ok, Json} -> {ok, Json};
            {error, invalid_json} -> {error, invalid_ipfs_json};
            {error, json_decoder_unavailable} = Error -> Error
        end
    end).

-spec sha256(binary() | string(), proplists:proplist()) ->
    {ok, binary()} | {error, term()}.
sha256(Path, Options) ->
    case cat_fold(Path, fun(Data, State) -> crypto:hash_update(State, Data) end, crypto:hash_init(sha256), Options) of
        {ok, State} -> {ok, string:lowercase(binary:encode_hex(crypto:hash_final(State)))};
        Error -> Error
    end.

-spec cat_fold(binary() | string(), fun((binary(), term()) -> term()), term(),
    proplists:proplist()) -> {ok, term()} | {error, term()}.
cat_fold(Path, Fold, Initial, Options) ->
    ipfs_guard(fun() ->
        Config = damage_ipfs_config:load(),
        cat_fold_config(Path, Fold, Initial, Options, Config)
    end).

%% Explicit Config stays private in production. Tests use it with an ephemeral
%% loopback HTTP server; no test-only endpoint override is exposed to requests.
cat_fold_config(Path0, Fold, Initial, Options, Config) ->
    ipfs_guard(fun() ->
        ipfs_require(is_function(Fold, 2), invalid_ipfs_fold),
        Limit = read_limit(Options),
        Timeout = proplists:get_value(timeout, Options,
            maps:get(request_timeout_ms, Config, 30000)),
        ipfs_require(is_integer(Timeout) andalso Timeout > 0, invalid_ipfs_timeout),
        Path = cid_path(Path0),
        {Host, Port} = local_endpoint(Config),
        Deadline = erlang:monotonic_time(millisecond) + Timeout,
        fold_with_deadline(fun(Guard, Tag) ->
            cat_stream(Path, Host, Port, Limit, Timeout, Fold, Initial, Deadline, Guard, Tag)
        end, Deadline)
    end).

cat_stream(Path, Host, Port, Limit, Timeout, Fold, Initial, Deadline, Guard, Tag) ->
    Query = uri_string:compose_query([
        {<<"arg">>, <<"/ipfs/", Path/binary>>},
        {<<"length">>, integer_to_binary(Limit + 1)}
    ]),
    case gun:open(Host, Port, #{transport => tcp, protocols => [http],
            %% Link at creation so cancellation cannot orphan a connection
            %% before the guard learns its PID. The handshake below moves
            %% that link to the guard before any callback is executed.
            supervise => false,
            connect_timeout => erlang:min(5000, Timeout), retry => 0}) of
        {ok, Conn} ->
            Guard ! {Tag, self(), connection, Conn},
            receive {Tag, Guard, connected} -> unlink(Conn) end,
            try
                case gun:await_up(Conn, remaining(Deadline)) of
                    {ok, http} ->
                        Ref = gun:post(Conn, <<"/api/v0/cat?", Query/binary>>,
                            [{<<"accept">>, <<"application/octet-stream">>},
                             {<<"te">>, <<"trailers">>}],
                            <<>>, #{flow => 1}),
                        cat_response(Conn, Ref, Limit, Fold, Initial, Deadline);
                    {error, timeout} -> {error, ipfs_timeout};
                    _ -> {error, ipfs_unavailable}
                end
            after
                close_stream(Conn)
            end;
        _ -> {error, ipfs_unavailable}
    end.

%% The guard never runs user callbacks. Its receive deadline covers connection
%% setup, reads, Fold/2 and normal connection cleanup. It also monitors the
%% caller: an outer release timeout must not orphan this inner operation.
fold_with_deadline(Fun, Deadline) ->
    Caller = self(),
    Tag = make_ref(),
    {Guard, Monitor} = spawn_monitor(fun() -> fold_guard(Caller, Tag, Fun, Deadline) end),
    receive
        {Tag, Guard, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Guard, _} ->
            {error, ipfs_read_failed}
    end.

fold_guard(Caller, Tag, Fun, Deadline) ->
    process_flag(trap_exit, true),
    CallerMonitor = erlang:monitor(process, Caller),
    Guard = self(),
    {Worker, WorkerMonitor} = spawn_opt(fun() ->
        Guard ! {Tag, self(), ipfs_guard(fun() -> Fun(Guard, Tag) end)}
    end, [link, monitor]),
    Reply =
        try
            fold_wait(Caller, CallerMonitor, Tag, Worker, WorkerMonitor, Deadline)
        after
            %% Use a fresh monitor: fold_wait may already have consumed DOWN.
            %% Joining before returning prevents late worker replies leaking
            %% into the caller. All worker/Gun messages stay in short-lived VM
            %% processes; no forced loading or caller process flags are used.
            stop_fold_process(Worker),
            erlang:demonitor(WorkerMonitor, [flush]),
            erlang:demonitor(CallerMonitor, [flush])
        end,
    case Reply of
        caller_down -> ok;
        {reply, Result} ->
            Final = case erlang:monotonic_time(millisecond) < Deadline of
                true -> Result;
                false -> {error, ipfs_timeout}
            end,
            Caller ! {Tag, self(), Final}
    end.

fold_wait(Caller, CallerMonitor, Tag, Worker, WorkerMonitor, Deadline) ->
    Left = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Tag, Worker, connection, Conn} when is_pid(Conn) ->
            %% Only the guard traps exits. It owns cancellation of both PIDs;
            %% callback errors, caller death and timeout all close the socket.
            link(Conn),
            try
                Worker ! {Tag, self(), connected},
                fold_wait(Caller, CallerMonitor, Tag, Worker, WorkerMonitor, Deadline)
            after
                stop_fold_process(Conn)
            end;
        {Tag, Worker, Result} -> {reply, Result};
        {'DOWN', CallerMonitor, process, Caller, _} -> caller_down;
        {'DOWN', WorkerMonitor, process, Worker, _} -> {reply, {error, ipfs_read_failed}}
    after Left ->
        {reply, {error, ipfs_timeout}}
    end.

stop_fold_process(Worker) ->
    Monitor = erlang:monitor(process, Worker),
    exit(Worker, kill),
    receive {'DOWN', Monitor, process, Worker, _} -> ok end.

cat_response(Conn, Ref, Limit, Fold, Initial, Deadline) ->
    case gun:await(Conn, Ref, remaining(Deadline)) of
        {inform, _, _} -> cat_response(Conn, Ref, Limit, Fold, Initial, Deadline);
        {response, nofin, 200, _} ->
            cat_body(Conn, Ref, Limit, 0, Fold, Initial, Deadline);
        {response, fin, 200, _} -> {ok, Initial};
        %% Kubo uses 500 for RPC errors, including unresolved object paths.
        %% Keep the HTTP status, but never return a raw error body/header.
        {response, _, Status, _} when is_integer(Status), Status >= 100, Status =< 599 ->
            {error, {ipfs_http_status, Status}};
        {error, timeout} -> {error, ipfs_timeout};
        _ -> {error, ipfs_read_failed}
    end.

cat_body(Conn, Ref, Limit, Size, Fold, Acc, Deadline) ->
    case gun:await(Conn, Ref, remaining(Deadline)) of
        {data, Fin, Data} when Size + byte_size(Data) =< Limit ->
            Next = Fold(Data, Acc),
            _ = remaining(Deadline),
            case Fin of
                fin -> {ok, Next};
                nofin ->
                    gun:update_flow(Conn, Ref, 1),
                    cat_body(Conn, Ref, Limit, Size + byte_size(Data), Fold, Next, Deadline)
            end;
        {data, _, _} -> {error, ipfs_object_too_large};
        {trailers, []} -> {ok, Acc};
        %% Preserve the existing fail-closed policy for nonempty trailers.
        %% Do not include their values (potentially sensitive) in reports.
        {trailers, _} -> {error, ipfs_stream_error};
        {error, timeout} -> {error, ipfs_timeout};
        %% A streaming Kubo error can arrive after HTTP 200. Never turn a
        %% partial body + error trailer into a successful JSON/hash result.
        _ -> {error, ipfs_read_failed}
    end.

close_stream(Conn) ->
    %% Wait for termination before flushing so late Gun messages cannot leak
    %% into the caller's mailbox. This cleanup also runs on callback errors.
    Monitor = erlang:monitor(process, Conn),
    try gun:close(Conn) catch _:_ -> ok end,
    receive
        {'DOWN', Monitor, process, Conn, _} -> ok
    after 1000 ->
        erlang:demonitor(Monitor, [flush])
    end,
    gun:flush(Conn).

remaining(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 -> Left;
        _ -> throw({ipfs_error, ipfs_timeout})
    end.

read_limit(Options) when is_list(Options) ->
    %% Reject typos/duplicates instead of silently weakening a requested cap.
    Keys = [Key || {Key, _} <- Options],
    ipfs_require(length(Keys) =:= length(Options) andalso
        length(lists:usort(Keys)) =:= length(Keys) andalso
        lists:all(fun(K) -> K =:= max_bytes orelse K =:= timeout end, Keys),
        invalid_ipfs_read_options),
    Limit = proplists:get_value(max_bytes, Options, 1048576),
    ipfs_require(is_integer(Limit) andalso Limit >= 0 andalso Limit < 16#7fffffffffffffff,
        invalid_ipfs_limit),
    Limit;
read_limit(_) -> throw({ipfs_error, invalid_ipfs_read_options}).

local_endpoint(Config) ->
    URL = ipfs_text(maps:get(ipfs_api, Config)),
    case uri_string:parse(URL) of
        #{scheme := <<"http">>, host := Host} = Parsed ->
            ipfs_require(not maps:is_key(userinfo, Parsed) andalso
                not maps:is_key(query, Parsed) andalso not maps:is_key(fragment, Parsed),
                invalid_ipfs_api),
            ipfs_require(lists:member(maps:get(path, Parsed, <<>>),
                [<<>>, <<"/">>, <<"/api/v0">>, <<"/api/v0/">>]), invalid_ipfs_api),
            Address = case Host of
                <<"127.0.0.1">> -> {127, 0, 0, 1};
                <<"::1">> -> {0, 0, 0, 0, 0, 0, 0, 1};
                _ -> throw({ipfs_error, ipfs_api_must_be_loopback})
            end,
            Port = maps:get(port, Parsed, 80),
            ipfs_require(is_integer(Port) andalso Port > 0 andalso Port =< 65535,
                invalid_ipfs_api_port),
            {Address, Port};
        _ -> throw({ipfs_error, invalid_ipfs_api})
    end.

%% Same immutable CID/path grammar used by release publication and discovery.
%% Validation is syntactic; the configured Kubo daemon validates IPFS blocks.
valid_cid(Value) when is_binary(Value) ->
    re:run(Value, <<"\\A(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{20,127})\\z">>,
        [{capture, none}]) =:= match;
valid_cid(_) -> false.

valid_relative_path(<<>>) -> true;
valid_relative_path(Path) when is_binary(Path), byte_size(Path) =< 512 ->
    lists:all(fun(Part) ->
        Part =/= <<".">> andalso Part =/= <<"..">> andalso
            re:run(Part, <<"\\A[A-Za-z0-9._+-]+\\z">>, [{capture, none}]) =:= match
    end, binary:split(Path, <<"/">>, [global]));
valid_relative_path(_) -> false.

cid_path(Path0) ->
    Path = case ipfs_text(Path0) of
        <<"ipfs://", Rest/binary>> -> Rest;
        <<"/ipfs/", Rest/binary>> -> Rest;
        Other -> Other
    end,
    case binary:split(Path, <<"/">>) of
        [Cid] -> ipfs_require(valid_cid(Cid), invalid_ipfs_path);
        [Cid, Relative] ->
            ipfs_require(valid_cid(Cid) andalso Relative =/= <<>> andalso
                valid_relative_path(Relative), invalid_ipfs_path)
    end,
    Path.

ipfs_text(Bin) when is_binary(Bin) -> Bin;
ipfs_text(List) when is_list(List) ->
    case unicode:characters_to_binary(List) of
        Bin when is_binary(Bin) -> Bin;
        _ -> throw({ipfs_error, invalid_ipfs_text})
    end;
ipfs_text(_) -> throw({ipfs_error, invalid_ipfs_text}).

ipfs_require(true, _) -> ok;
ipfs_require(false, Reason) -> throw({ipfs_error, Reason}).

ipfs_guard(Fun) ->
    try Fun() catch
        throw:{ipfs_error, Reason} -> {error, Reason};
        Class:Reason -> {error, {ipfs_exception, Class, ipfs_exception_tag(Reason)}}
    end.

%% Exception terms may contain request data, configuration or callback state.
%% Preserve only a fixed classification, never arguments or a stacktrace.
ipfs_exception_tag({Tag, _}) -> ipfs_exception_tag(Tag);
ipfs_exception_tag(Tag) when
    Tag =:= undef; Tag =:= badarg; Tag =:= badmatch;
    Tag =:= function_clause; Tag =:= case_clause; Tag =:= badmap;
    Tag =:= system_limit; Tag =:= nif_not_loaded; Tag =:= noproc
-> Tag;
ipfs_exception_tag(_) -> unexpected.
