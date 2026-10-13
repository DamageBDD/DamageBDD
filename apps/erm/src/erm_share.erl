%% Durable local share inbox; all ingestion requires an explicit accept/1.
-module(erm_share).
-behaviour(gen_server).
-export([
    start_link/0,
    start/0,
    stop/0,
    sync/0,
    status/0,
    items/0,
    accept/1,
    reject/1,
    forget/1,
    submit/3,
    config/0,
    show/0,
    ask/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-define(TABLE, erm_share_items).

config() ->
    Raw = application:get_env(erm, share, #{}),
    C =
        case is_map(Raw) of
            true -> Raw;
            false -> maps:from_list(Raw)
        end,
    Base = filename:basedir(user_data, "erm"),
    Defaults = #{
        enabled => false,
        directory => filename:join(Base, "share"),
        max_file_bytes => 16777216,
        max_total_bytes => 536870912,
        max_items => 1000,
        poll_ms => 1000,
        corpus => undefined,
        principal => undefined,
        kdeconnect => #{enabled => false, device_ids => [], roots => []},
        airdrop => #{enabled => false, directory => filename:join(Base, "airdrop")}
    },
    maps:merge(Defaults, C).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, config(), []).
start() ->
    case whereis(erm_sup) of
        undefined ->
            {error, erm_sup_not_running};
        _ ->
            supervisor:start_child(erm_sup, #{
                id => ?MODULE,
                start => {?MODULE, start_link, []},
                restart => transient,
                shutdown => 5000,
                type => worker,
                modules => [?MODULE]
            })
    end.
stop() ->
    case whereis(erm_sup) of
        undefined ->
            ok;
        _ ->
            _ = supervisor:terminate_child(erm_sup, ?MODULE),
            _ = supervisor:delete_child(erm_sup, ?MODULE),
            ok
    end.
sync() ->
    case {maps:get(enabled, config()), whereis(?MODULE)} of
        {false, _} ->
            stop();
        {true, P} when is_pid(P) -> {ok, P};
        {true, _} ->
            case start() of
                {error, already_present} -> supervisor:restart_child(erm_sup, ?MODULE);
                Result -> Result
            end
    end.
show() -> erm_share_ui:show().
status() -> call(status).
items() -> call(items).
accept(Id) -> call({accept, Id}).
reject(Id) -> call({reject, Id}).
forget(Id) -> call({forget, Id}).
%% Trusted BEAM API. Remote adapters use completion manifests, never this API
%% across HTTP/distributed Erlang with untrusted caller-selected paths.
submit(Kind, Value, Name) -> call({submit, Kind, Value, Name}).
ask(Question, Destination) ->
    C = config(),
    ecai_share:ask(maps:get(corpus, C), maps:get(principal, C), Question, Destination).
call(Request) ->
    case whereis(?MODULE) of
        undefined -> {error, not_started};
        _ -> gen_server:call(?MODULE, Request, 30000)
    end.

init(C) ->
    process_flag(trap_exit, true),
    process_flag(sensitive, true),
    try
        true = maps:get(enabled, C),
        lists:foreach(
            fun(K) ->
                V = maps:get(K, C),
                true = is_integer(V) andalso V > 0
            end,
            [max_file_bytes, max_total_bytes, max_items, poll_ms]
        ),
        true = maps:get(max_file_bytes, C) =< 67108864,
        Dir = erm_share_files:directory(maps:get(directory, C)),
        Objects = erm_share_files:directory(filename:join(Dir, "objects")),
        Events = erm_share_files:directory(filename:join(Dir, "events")),
        Db = filename:join(Dir, "inbox.dets"),
        {ok, ?TABLE} = dets:open_file(?TABLE, [{file, Db}, {type, set}, {auto_save, infinity}]),
        ok = file:change_mode(Db, 8#600),
        Existing = dets:foldl(fun({Id, I}, Acc) -> Acc#{Id => I} end, #{}, ?TABLE),
        Recovered = maps:map(
            fun(_, I) ->
                case maps:get(state, I) of
                    indexing -> I#{state := pending};
                    _ -> I
                end
            end,
            Existing
        ),
        maps:foreach(fun(_, I) -> persist(I) end, Recovered),
        A = maps:get(airdrop, C),
        AirEvents =
            case maps:get(enabled, A, false) of
                true ->
                    AD = erm_share_files:directory(maps:get(directory, A)),
                    [erm_share_files:directory(filename:join(AD, ".ecai-events"))];
                false ->
                    []
            end,
        self() ! poll,
        {ok, #{
            config => C,
            objects => Objects,
            events => Events,
            air_events => AirEvents,
            items => Recovered,
            worker => undefined,
            bridge => undefined,
            bridge_status => stopped,
            timer => undefined,
            last_error => undefined
        }}
    catch
        _:_ -> {stop, invalid_share_configuration_or_storage}
    end.

handle_call(status, _, S) ->
    {reply,
        #{
            count => map_size(maps:get(items, S)),
            bytes => total(S),
            bridge => maps:get(bridge_status, S),
            last_error => maps:get(last_error, S),
            busy => maps:get(worker, S) =/= undefined
        },
        S};
handle_call(items, _, S) ->
    List = lists:sort(
        fun(A, B) -> maps:get(received_at, A) > maps:get(received_at, B) end,
        maps:values(maps:get(items, S))
    ),
    {reply, List, S};
handle_call({submit, Kind, Value, Name}, _, S) when Kind =:= text; Kind =:= url ->
    {Reply, Next} = store(Kind, Value, Name, <<"local">>, <<>>, S),
    {reply, Reply, Next};
handle_call({accept, Id}, _, S = #{worker := undefined, items := Items, config := C}) ->
    case {maps:find(Id, Items), maps:get(corpus, C), maps:get(principal, C)} of
        {{ok, I = #{state := State}}, Corpus, Principal} when
            (State =:= pending orelse State =:= failed),
            is_binary(Corpus),
            byte_size(Corpus) > 0,
            is_binary(Principal),
            byte_size(Principal) > 0
        ->
            %% Bind retries to the original target, even after a config edit.
            Target = {Corpus, Principal},
            case maps:get(target, I, Target) of
                Target ->
                    New = I#{state := indexing, target => Target, error => undefined},
                    S1 = put_item(New, S),
                    Parent = self(),
                    {Pid, Ref} = spawn_monitor(fun() ->
                        process_flag(sensitive, true),
                        Result =
                            try
                                {ok, Bytes} = read_item(New, S1),
                                ecai_share:ingest(New, Bytes, Corpus, Principal)
                            catch
                                _:_ -> {error, ingestion_failed}
                            end,
                        Parent ! {indexed, self(), Id, Result}
                    end),
                    Timer = erlang:send_after(150000, self(), {index_timeout, Pid}),
                    {reply, {ok, indexing}, S1#{worker := {Pid, Ref, Id, Timer}}};
                _ ->
                    {reply, {error, target_changed}, S}
            end;
        {{ok, _}, _, _} ->
            {reply, {error, not_pending_or_unconfigured}, S};
        _ ->
            {reply, {error, not_found}, S}
    end;
handle_call({accept, _}, _, S) ->
    {reply, {error, busy}, S};
handle_call({reject, Id}, _, S) ->
    change_item(Id, rejected, S);
handle_call({forget, Id}, _, S = #{items := Items}) ->
    case maps:find(Id, Items) of
        {ok, #{state := indexing}} ->
            {reply, {error, busy}, S};
        {ok, I} ->
            ok = dets:delete(?TABLE, Id),
            ok = dets:sync(?TABLE),
            _ = file:delete(object_path(I, S)),
            {reply, ok, S#{items := maps:remove(Id, Items)}};
        error ->
            {reply, {error, not_found}, S}
    end;
handle_call(_, _, S) ->
    {reply, {error, unsupported_request}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(poll, S) ->
    Next =
        try
            WithBridge = bridge(S),
            Dirs = [maps:get(events, S) | maps:get(air_events, S)],
            lists:foldl(fun scan/2, WithBridge, Dirs)
        catch
            _:_ -> S#{last_error := event_scan_failed}
        end,
    T = erlang:send_after(maps:get(poll_ms, maps:get(config, S)), self(), poll),
    {noreply, Next#{timer := T}};
handle_info({indexed, Pid, Id, Result}, S = #{worker := {Pid, Ref, Id, Timer}}) ->
    erlang:demonitor(Ref, [flush]),
    erlang:cancel_timer(Timer),
    I = maps:get(Id, maps:get(items, S)),
    New =
        case Result of
            {ok, _} -> I#{state := indexed, error => undefined};
            {error, Reason} when is_atom(Reason) -> I#{state := failed, error => Reason};
            _ -> I#{state := failed, error => ingestion_failed}
        end,
    {noreply, put_item(New, S#{worker := undefined})};
handle_info({'DOWN', Ref, process, Pid, _}, S = #{worker := {Pid, Ref, Id, Timer}}) ->
    erlang:cancel_timer(Timer),
    I = maps:get(Id, maps:get(items, S)),
    {noreply, put_item(I#{state := failed, error => worker_failed}, S#{worker := undefined})};
handle_info({index_timeout, Pid}, S = #{worker := {Pid, _, _, _}}) ->
    exit(Pid, kill),
    {noreply, S};
handle_info({Port, {exit_status, Code}}, S = #{bridge := Port}) ->
    {noreply, S#{bridge := undefined, bridge_status := {exited, Code}}};
handle_info({'EXIT', Port, _}, S = #{bridge := Port}) ->
    {noreply, S#{bridge := undefined, bridge_status := stopped}};
handle_info({Port, {data, {eol, <<"ready">>}}}, S = #{bridge := Port}) ->
    {noreply, S#{bridge_status := listening}};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, S) ->
    case maps:get(worker, S) of
        undefined -> ok;
        {Pid, _, _, _} -> exit(Pid, kill)
    end,
    case maps:get(bridge, S) of
        undefined ->
            ok;
        P ->
            try
                port_close(P)
            catch
                _:_ -> ok
            end
    end,
    case maps:get(timer, S) of
        undefined -> ok;
        T -> erlang:cancel_timer(T)
    end,
    _ = dets:sync(?TABLE),
    _ = dets:close(?TABLE),
    ok.
code_change(_, S, _) -> {ok, S}.

change_item(Id, State, S = #{items := Items}) ->
    case maps:find(Id, Items) of
        {ok, #{state := indexing}} -> {reply, {error, busy}, S};
        {ok, #{state := indexed}} -> {reply, {error, already_indexed}, S};
        {ok, I} -> {reply, ok, put_item(I#{state := State}, S)};
        error -> {reply, {error, not_found}, S}
    end.
put_item(I, S) ->
    persist(I),
    S#{items := (maps:get(items, S))#{maps:get(id, I) => I}}.
persist(I) ->
    ok = dets:insert(?TABLE, {maps:get(id, I), I}),
    ok = dets:sync(?TABLE).
total(S) -> lists:sum([maps:get(size, I) || I <- maps:values(maps:get(items, S))]).
object_path(I, S) -> filename:join(maps:get(objects, S), binary_to_list(maps:get(id, I))).
read_item(I, S) ->
    case erm_share_files:read(object_path(I, S), [maps:get(objects, S)], maps:get(size, I)) of
        {ok, B} ->
            case erm_share_files:hex(crypto:hash(sha256, B)) =:= maps:get(sha256, I) of
                true -> {ok, B};
                false -> {error, corrupt_snapshot}
            end;
        E ->
            E
    end.

store(Kind, Bytes, Name, Transport, Device, S) ->
    try
        C = maps:get(config, S),
        true = is_binary(Bytes),
        true = byte_size(Bytes) =< maps:get(max_file_bytes, C),
        true = is_binary(Name) andalso byte_size(Name) > 0 andalso byte_size(Name) =< 1024,
        true = erm_share_files:utf8(Name),
        true = Kind =:= file orelse erm_share_files:utf8(Bytes),
        true = Kind =/= url orelse valid_url(Bytes),
        Hash = erm_share_files:hex(crypto:hash(sha256, Bytes)),
        <<Key:16/binary, _/binary>> = crypto:hash(
            sha256, term_to_binary({Transport, Device, Kind, Name, Hash})
        ),
        Id = erm_share_files:hex(Key),
        case maps:is_key(Id, maps:get(items, S)) of
            true ->
                {{ok, Id}, S};
            false ->
                case
                    map_size(maps:get(items, S)) < maps:get(max_items, C) andalso
                        total(S) + byte_size(Bytes) =< maps:get(max_total_bytes, C)
                of
                    false ->
                        {{error, inbox_full}, S};
                    true ->
                        I = #{
                            id => Id,
                            name => Name,
                            kind => Kind,
                            sha256 => Hash,
                            transport => Transport,
                            device => Device,
                            state => pending,
                            size => byte_size(Bytes),
                            received_at => erlang:system_time(millisecond)
                        },
                        try
                            ok = erm_share_files:write(object_path(I, S), Bytes),
                            {{ok, Id}, put_item(I, S)}
                        catch
                            _:_ -> {{error, storage_unavailable}, S}
                        end
                end
        end
    catch
        _:_ -> {{error, invalid_or_unavailable_share}, S}
    end.

valid_url(B) ->
    case uri_string:parse(B) of
        #{scheme := Scheme, host := Host} when
            (Scheme =:= <<"https">> orelse Scheme =:= <<"http">>), byte_size(Host) > 0
        ->
            true;
        _ ->
            false
    end.

scan(Dir, S) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foldl(
                fun(N, Acc) -> event(filename:join(Dir, N), Dir, Acc) end,
                S,
                lists:sublist(lists:sort([N || N <- Names, filename:extension(N) =:= ".json"]), 32)
            );
        _ ->
            S#{last_error := spool_unavailable}
    end.
event(Path, Dir, S) ->
    Result =
        try
            {ok, B} = erm_share_files:read(Path, [Dir], 131072),
            M = jsx:decode(B, [return_maps]),
            dispatch(M, Dir, S)
        catch
            _:_ -> {{error, invalid_event}, S}
        end,
    case Result of
        {{ok, _}, Next} ->
            _ = file:delete(Path),
            Next;
        {{error, Reason}, Next} when Reason =:= inbox_full; Reason =:= storage_unavailable ->
            Next#{last_error := Reason};
        {{error, Reason}, Next} ->
            %% Keep bounded diagnostic metadata, not unbounded poison manifests.
            _ = file:delete(Path),
            Next#{last_error := Reason}
    end.

dispatch(#{<<"v">> := 1, <<"transport">> := <<"airdrop">>, <<"name_b64">> := N}, Dir, S) ->
    true = lists:member(Dir, maps:get(air_events, S)),
    Name = base64:decode(N),
    true = filename:basename(Name) =:= Name andalso Name =/= <<"..">> andalso Name =/= <<".">>,
    A = maps:get(airdrop, maps:get(config, S)),
    Root = maps:get(directory, A),
    {ok, Bytes} = erm_share_files:read(
        filename:join(Root, unicode:characters_to_list(Name)),
        [Root],
        maps:get(max_file_bytes, maps:get(config, S))
    ),
    store(file, Bytes, Name, <<"airdrop">>, <<>>, S);
dispatch(
    #{
        <<"v">> := 1,
        <<"transport">> := <<"kdeconnect">>,
        <<"device_b64">> := D,
        <<"kind">> := Kind,
        <<"value_b64">> := V
    },
    Dir,
    S
) ->
    true = Dir =:= maps:get(events, S),
    K = maps:get(kdeconnect, maps:get(config, S)),
    true = maps:get(enabled, K, false),
    Device = base64:decode(D),
    true = lists:member(Device, maps:get(device_ids, K, [])),
    Value = base64:decode(V),
    case Kind of
        <<"text">> ->
            store(text, Value, <<"Shared text">>, <<"kdeconnect">>, Device, S);
        <<"uri">> ->
            case local_path(Value) of
                {ok, Path} ->
                    {ok, Bytes} = erm_share_files:read(
                        Path,
                        maps:get(roots, K, []),
                        maps:get(max_file_bytes, maps:get(config, S))
                    ),
                    Name = unicode:characters_to_binary(filename:basename(Path)),
                    store(file, Bytes, Name, <<"kdeconnect">>, Device, S);
                _ ->
                    store(url, Value, <<"Shared link">>, <<"kdeconnect">>, Device, S)
            end
    end.

%% QUrl::toString uses PrettyDecoded: spaces/Unicode may be unescaped. Parse
%% local file URIs separately without relaxing HTTP scheme/host validation.
local_path(<<"file:///", Rest/binary>>) -> decoded_path(<<"/", Rest/binary>>);
local_path(<<"file://localhost/", Rest/binary>>) -> decoded_path(<<"/", Rest/binary>>);
local_path(_) -> not_local.
decoded_path(P) ->
    true = binary:match(P, [<<"?">>, <<"#">>]) =:= nomatch,
    Decoded = uri_string:percent_decode(P),
    true = erm_share_files:utf8(Decoded),
    {ok, unicode:characters_to_list(Decoded)}.

bridge(S = #{bridge := Port}) when is_port(Port) -> S;
bridge(S) ->
    K = maps:get(kdeconnect, maps:get(config, S)),
    case maps:get(enabled, K, false) of
        false ->
            S#{bridge_status := disabled};
        true ->
            Priv =
                case code:priv_dir(erm) of
                    {error, _} -> "apps/erm/priv";
                    P -> P
                end,
            Exe = maps:get(helper, K, filename:join(Priv, "erm_kdeconnect_share")),
            try
                Port = open_port(
                    {spawn_executable, filename:absname(Exe)},
                    [binary, exit_status, use_stdio, {line, 1024}, {args, [maps:get(events, S)]}]
                ),
                S#{bridge := Port, bridge_status := starting}
            catch
                _:_ -> S#{bridge_status := helper_unavailable}
            end
    end.
