%% Private corpus policy. Principal must come from a trusted authentication
%% boundary, NEVER from a request body. BEAM callers are trusted application code.
-module(ecai_private_policy).
-export([resolve/3, destination/2, guard/1, fail/1, run/1, assert_public_record/1]).

-spec resolve(binary(), binary(), read | write) -> map().
resolve(Corpus, Principal, Action) ->
    guard(is_binary(Corpus) andalso byte_size(Corpus) > 0),
    case is_binary(Principal) andalso byte_size(Principal) > 0 of
        true -> ok;
        false -> fail(unauthenticated)
    end,
    Corpora = application:get_env(ecai, private_corpora, #{}),
    Config = case maps:find(Corpus, Corpora) of
        {ok, C} when is_map(C) -> C#{corpus => Corpus};
        _ -> fail(forbidden)
    end,
    Owner = maps:get(owner, Config),
    Members = case Action of
        read -> maps:get(readers, Config, []);
        write -> maps:get(writers, Config, [])
    end,
    case Principal =:= Owner orelse lists:member(Principal, Members) of
        true -> Config;
        false -> fail(forbidden)
    end.

%% A destination is an operator-defined ID, not a caller-selected URL/options.
-spec destination(map(), binary()) -> map().
destination(Config, Id) when is_binary(Id) ->
    case lists:member(Id, maps:get(llm_destinations, Config, [])) of
        false -> fail(llm_destination_forbidden);
        true -> ok
    end,
    Destinations = application:get_env(ecai, private_llm_destinations, #{}),
    case maps:find(Id, Destinations) of
        {ok, D} when is_map(D) -> D;
        _ -> fail(llm_destination_unavailable)
    end;
destination(_, _) -> fail(invalid_request).

guard(true) -> ok;
guard(false) -> fail(invalid_request).

%% Only fixed, non-sensitive atoms may be passed to this internal boundary.
fail(Reason) when is_atom(Reason) -> throw({ecai_private_error, Reason}).

%% Private operations do not run in long-lived gen_servers or public ETS.
%% Redact all unexpected exceptions, including crypto/NIF errors which may
%% contain their input arguments. This is not protection from privileged BEAM
%% code, OS administrators, swap, core dumps or hostile native code.
-spec run(fun(() -> term())) -> term().
run(Fun) when is_function(Fun, 0) ->
    Parent = self(),
    Reply = erlang:alias(),
    {Pid, Ref} = spawn_opt(fun() ->
        process_flag(sensitive, true),
        Result = try Fun()
                 catch
                     throw:{ecai_private_error, Reason} -> {error, Reason};
                     _:_ -> {error, private_operation_failed}
                 end,
        Reply ! {Reply, Result}
    end, [monitor, {max_heap_size, #{size => 16000000, kill => true,
                                   error_logger => false}}]),
    _ = spawn(fun() -> watch_worker(Parent, Pid) end),
    try
        receive
            {Reply, Result} ->
                erlang:demonitor(Ref, [flush]), Result;
            {'DOWN', Ref, process, Pid, _} ->
                {error, private_worker_failed}
        after 120000 ->
            exit(Pid, kill),
            receive {'DOWN', Ref, process, Pid, _} -> ok end,
            %% An append may already have committed. Retry with the SAME batch
            %% ID; immutable segment creation never overwrites that batch.
            {error, private_operation_timeout}
        end
    after
        erlang:unalias(Reply),
        receive {Reply, _Late} -> ok after 0 -> ok end
    end.

watch_worker(Parent, Worker) ->
    PRef = erlang:monitor(process, Parent),
    WRef = erlang:monitor(process, Worker),
    receive
        {'DOWN', WRef, process, Worker, _} -> ok;
        {'DOWN', PRef, process, Parent, _} -> exit(Worker, kill)
    after 120000 -> exit(Worker, kill)
    end.

%% Explicit privacy flags must never be silently dropped by public writers.
assert_public_record(Record) when is_map(Record) ->
    Fields = [{private, false}, {privacy, public}, {encryption, none}],
    lists:foreach(fun({Key, Default}) ->
        Values = [maps:get(K, Record, Default) || K <- [Key, atom_to_binary(Key, utf8)]],
        Allowed = case Key of
            private -> [false];
            privacy -> [public, <<"public">>, "public"];
            encryption -> [none]
        end,
        case lists:all(fun(V) -> lists:member(V, Allowed) end, Values) of
            true -> ok;
            false -> erlang:error(private_record_requires_private_api)
        end
    end, Fields),
    ok.
