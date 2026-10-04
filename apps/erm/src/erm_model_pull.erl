%% One asynchronous pull at a time; immutable verified model directories.
-module(erm_model_pull).
-behaviour(gen_server).
-export([start_link/0, start_link/1, child_spec/0, ensure/1, retry/1, status/0, cancel/0, models/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.
start_link() -> start_link(application:get_env(erm, model_pull, [])).
start_link(O) -> gen_server:start_link({local, ?MODULE}, ?MODULE, O, []).
ensure(Id) -> call({ensure, Id, false}).
retry(Id) -> call({ensure, Id, true}).
status() -> call(status).
models() -> call(models).
cancel() -> call(cancel).
call(R) ->
    try
        gen_server:call(?MODULE, R, 1000)
    catch
        exit:{noproc, _} -> {error, disabled};
        exit:{timeout, _} -> {error, timeout}
    end.
init(O0) ->
    process_flag(trap_exit, true),
    logger:update_process_metadata(#{domain => [erm, tts, models]}),
    O =
        case O0 of
            Map when is_map(Map) -> Map;
            L when is_list(L) -> proplists:to_map(L)
        end,
    Root = maps:get(cache_dir, O, filename:basedir(user_cache, "erm/models")),
    absolute = filename:pathtype(Root),
    Timeout = maps:get(timeout_ms, O, 600000),
    true = is_integer(Timeout) andalso Timeout >= 1000 andalso Timeout =< 3600000,
    %% Custom manifests are trusted configuration, never supplied by voice/LLM output.
    Catalog = maps:merge(erm_model_catalog:all(), maps:get(manifests, O, #{})),
    maps:foreach(fun(_, M) -> validate(M) end, Catalog),
    {ok, #{
        root => Root, catalog => Catalog, timeout => Timeout, active => undefined, models => #{}
    }}.
handle_call(models, _, S) ->
    {reply, lists:sort(maps:keys(maps:get(catalog, S))), S};
handle_call(status, _, S) ->
    {reply, maps:with([active, models], public(S)), S};
handle_call({ensure, Id, Force}, _, S = #{catalog := Cat, models := States, active := A}) ->
    case maps:find(Id, Cat) of
        error ->
            {reply, {error, unknown_model}, S};
        {ok, M} ->
            case {cached_entry(maps:get(Id, States, undefined), M), A, Force} of
                {#{state := ready, paths := P}, _, false} ->
                    {reply, {ok, P}, S};
                {#{state := failed, error := R}, _, false} ->
                    {reply, {error, R}, S};
                {_, #{id := Id}, _} ->
                    {reply, {pending, maps:get(Id, States)}, S};
                {_, Other, _} when Other =/= undefined -> {reply, {error, busy}, S};
                _ ->
                    Root = maps:get(root, S),
                    Key = hex(crypto:hash(sha256, term_to_binary(M))),
                    Dir = filename:join(Root, Key),
                    Stage = Dir ++ ".stage-" ++ hex(crypto:strong_rand_bytes(12)),
                    Owner = self(),
                    Timeout = maps:get(timeout, S),
                    Pid = spawn_link(fun() ->
                        Result =
                            try
                                {ok, install(M, Dir, Stage, Owner, Timeout)}
                            catch
                                C:R -> {error, sanitise(C, R)}
                            end,
                        Owner ! {finished, self(), Result}
                    end),
                    Timer = erlang:send_after(Timeout, self(), {deadline, Pid}),
                    Entry = #{
                        state => checking,
                        bytes => 0,
                        total_bytes => lists:sum([maps:get(bytes, F) || F <- maps:get(files, M)])
                    },
                    Next = S#{
                        active => #{pid => Pid, id => Id, stage => Stage, timer => Timer},
                        models => States#{Id => Entry}
                    },
                    {reply, {pending, Entry}, Next}
            end
    end;
handle_call(cancel, _, S = #{active := undefined}) ->
    {reply, ok, S};
handle_call(cancel, _, S = #{active := #{pid := P} = A}) ->
    exit(P, shutdown),
    {reply, ok, S#{active => A#{failure => cancelled}}};
handle_call(_, _, S) ->
    {reply, {error, unsupported_call}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info({progress, P, Update}, S = #{active := #{pid := P, id := Id}, models := Ms}) ->
    {noreply, S#{models => Ms#{Id => maps:merge(maps:get(Id, Ms), Update)}}};
handle_info({finished, P, Result}, S = #{active := #{pid := P} = A}) ->
    case maps:is_key(failure, A) of
        true -> {noreply, S};
        false -> {noreply, finish(Result, S)}
    end;
handle_info({'EXIT', P, R}, S = #{active := #{pid := P} = A}) ->
    {noreply, finish({error, maps:get(failure, A, {worker_exit, R})}, S)};
handle_info({deadline, P}, S = #{active := #{pid := P} = A}) ->
    exit(P, shutdown),
    {noreply, S#{active => A#{failure => download_timeout}}};
handle_info(_, S) ->
    {noreply, S}.
finish(Result, S = #{active := #{id := Id, stage := Stage, timer := T}, models := Ms}) ->
    erlang:cancel_timer(T),
    cleanup(Stage),
    Entry =
        case Result of
            {ok, Paths} ->
                logger:notice("model ~p ready", [Id]),
                #{state => ready, paths => Paths};
            {error, R} ->
                logger:warning("model ~p pull failed: ~tp", [Id, R]),
                #{state => failed, error => R}
        end,
    S#{active => undefined, models => Ms#{Id => Entry}}.
public(S = #{active := undefined}) -> S;
public(S = #{active := A}) -> S#{active => maps:with([id], A)}.
install(M, Dir, Stage, Owner, Timeout) ->
    Files = maps:get(files, M),
    cleanup_staging(Dir),
    case valid_directory(Dir, Files) of
        true ->
            paths(Dir, Files);
        false ->
            %% Existing invalid cache is left intact until a replacement is verified.
            ok = filelib:ensure_dir(filename:join(Stage, "placeholder")),
            try
                lists:foldl(
                    fun(F, Base) ->
                        Owner !
                            {progress, self(), #{
                                state => downloading, file => maps:get(name, F), bytes => Base
                            }},
                        Progress = fun(N) -> Owner ! {progress, self(), #{bytes => Base + N}} end,
                        ok = erm_model_http:fetch(
                            F, filename:join(Stage, maps:get(name, F)), Progress, Timeout
                        ),
                        Base + maps:get(bytes, F)
                    end,
                    0,
                    Files
                ),
                true = valid_directory(Stage, Files),
                Owner ! {progress, self(), #{state => installing}},
                publish(Stage, Dir, Files),
                paths(Dir, Files)
            after
                cleanup(Stage)
            end
    end.
publish(Stage, Dir, Files) ->
    case file:rename(Stage, Dir) of
        ok ->
            ok;
        {error, R} when R =:= eexist; R =:= enotempty ->
            case valid_directory(Dir, Files) of
                true ->
                    ok;
                false ->
                    Quarantine = Dir ++ ".invalid-" ++ hex(crypto:strong_rand_bytes(8)),
                    ok = file:rename(Dir, Quarantine),
                    case file:rename(Stage, Dir) of
                        ok ->
                            cleanup(Quarantine);
                        Error ->
                            file:rename(Quarantine, Dir),
                            error({publish, Error})
                    end
            end;
        Error ->
            error({publish, Error})
    end.
valid_directory(Dir, Files) ->
    lists:all(
        fun(F) ->
            P = filename:join(Dir, maps:get(name, F)),
            filelib:is_regular(P) andalso filelib:file_size(P) =:= maps:get(bytes, F) andalso
                hash_file(P) =:= maps:get(sha256, F)
        end,
        Files
    ).
hash_file(P) ->
    case file:open(P, [read, binary, raw]) of
        {ok, F} ->
            try
                hash_chunks(F, crypto:hash_init(sha256))
            after
                file:close(F)
            end;
        _ ->
            invalid
    end.
hash_chunks(F, H) ->
    case file:read(F, 1048576) of
        {ok, B} -> hash_chunks(F, crypto:hash_update(H, B));
        eof -> hex(crypto:hash_final(H));
        _ -> invalid
    end.
paths(Dir, Files) ->
    maps:from_list([{maps:get(role, F), filename:join(Dir, maps:get(name, F))} || F <- Files]).
validate(#{files := Files}) when is_list(Files), Files =/= [], length(Files) =< 10 ->
    lists:foreach(
        fun(#{name := Name, role := Role, url := Url, sha256 := Hash, bytes := N}) ->
            true = is_list(Name) andalso length(Name) > 0 andalso length(Name) < 200,
            match = re:run(Name, "^[A-Za-z0-9][A-Za-z0-9_.-]*$", [{capture, none}]),
            true = is_atom(Role),
            true = is_integer(N) andalso N > 0 andalso N =< 10737418240,
            match = re:run(Hash, "^[a-f0-9]{64}$", [{capture, none}]),
            #{scheme := "https", host := Host} = Parsed = uri_string:parse(Url),
            true = Host =/= [],
            false = maps:is_key(userinfo, Parsed)
        end,
        Files
    ),
    true = length(lists:usort([maps:get(name, F) || F <- Files])) =:= length(Files),
    true = length(lists:usort([maps:get(role, F) || F <- Files])) =:= length(Files),
    ok.
cleanup(Path) ->
    case file:del_dir_r(Path) of
        ok -> ok;
        {error, enoent} -> ok;
        E -> logger:warning("model staging cleanup failed: ~tp", [E])
    end.
sanitise(error, {badmatch, false}) ->
    verification_failed;
sanitise(_, R) when is_atom(R) -> R;
sanitise(_, {http_request_failed, R}) ->
    {http_request_failed, R};
sanitise(_, {http_status, N}) ->
    {http_status, N};
sanitise(_, {size_mismatch, N}) ->
    {size_mismatch, N};
sanitise(_, R) ->
    case R of
        {badmatch, {error, E}} when is_atom(E) -> {filesystem_or_transport, E};
        _ -> pull_failed
    end.
hex(B) -> lists:flatten([io_lib:format("~2.16.0b", [X]) || <<X>> <= B]).
terminate(_, #{active := undefined}) ->
    ok;
terminate(_, #{active := #{pid := P}}) ->
    exit(P, shutdown),
    ok.
code_change(_, S, _) -> {ok, S}.

cached_entry(#{state := ready, paths := Ps} = Entry, #{files := Files}) ->
    case
        lists:all(
            fun(F) ->
                P = maps:get(maps:get(role, F), Ps),
                filelib:is_regular(P) andalso filelib:file_size(P) =:= maps:get(bytes, F)
            end,
            Files
        )
    of
        true -> Entry;
        false -> undefined
    end;
cached_entry(Entry, _) ->
    Entry.
cleanup_staging(Dir) ->
    Root = filename:dirname(Dir),
    Prefix = filename:basename(Dir) ++ ".stage-",
    case file:list_dir(Root) of
        {ok, Names} ->
            lists:foreach(
                fun(N) ->
                    case lists:prefix(Prefix, N) andalso length(N) =:= length(Prefix) + 24 of
                        true -> cleanup(filename:join(Root, N));
                        false -> ok
                    end
                end,
                Names
            );
        _ ->
            ok
    end.
