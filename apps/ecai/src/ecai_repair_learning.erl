-module(ecai_repair_learning).

%% Persists verified repair evidence without promoting model output to fact prematurely.
-export([record/3, lookup/2, promotable/3, candidate_hash/1]).

-spec record(file:filename_all(), map(), map()) -> {ok, binary()} | {error, term()}.
record(Root, Capsule, Result) when is_map(Capsule), is_map(Result) ->
    Fingerprint = ecai_repair_capsule:fingerprint(Capsule),
    Event = #{
        schema => <<"ecai.verified-repair-event">>,
        version => 1,
        capsule_id => ecai_repair_capsule:id(Capsule),
        problem_fingerprint => Fingerprint,
        candidate_hash => candidate_hash(Result),
        verification => Result,
        recorded_at => erlang:system_time(millisecond)
    },
    ecai_repair_store:persist_event(Root, Fingerprint, Event).

-spec lookup(file:filename_all(), binary() | list()) -> {ok, [map()]} | {error, term()}.
lookup(Root0, Fingerprint0) ->
    Root = to_list(Root0),
    Fingerprint = to_list(Fingerprint0),
    Pattern = filename:join([Root, "events", Fingerprint, "*.term"]),
    Files = lists:sort(filelib:wildcard(Pattern)),
    {ok, [Event || File <- Files, {ok, Event} <- [ecai_repair_store:read_term(File)]]}.

-spec promotable(file:filename_all(), binary() | list(), pos_integer()) ->
    {ok, [map()]} | {error, term()}.
promotable(Root, Fingerprint, MinimumEvidence) when
    is_integer(MinimumEvidence), MinimumEvidence > 0
->
    case lookup(Root, Fingerprint) of
        {ok, Events} ->
            Groups = lists:foldl(fun group_event/2, #{}, Events),
            Candidates = lists:sort(fun candidate_order/2, [
                #{
                    candidate_hash => Hash,
                    evidence_count => length(Group),
                    evidence => lists:reverse(Group)
                }
             || {Hash, Group} <- maps:to_list(Groups),
                length(Group) >= MinimumEvidence
            ]),
            {ok, Candidates};
        Error ->
            Error
    end.

-spec candidate_hash(term()) -> binary().
candidate_hash(#{patch := Patch}) when is_binary(Patch), byte_size(Patch) > 0 ->
    hex(crypto:hash(sha256, Patch));
candidate_hash(#{patch := Patch}) when is_list(Patch), Patch =/= [] ->
    hex(crypto:hash(sha256, iolist_to_binary(Patch)));
candidate_hash(Result) ->
    Bin = ecai_repair_capsule:canonical_binary(strip_volatile(Result)),
    hex(crypto:hash(sha256, Bin)).

group_event(#{candidate_hash := Hash} = Event, Acc) ->
    maps:update_with(Hash, fun(Existing) -> [Event | Existing] end, [Event], Acc);
group_event(_Event, Acc) ->
    Acc.

candidate_order(
    #{evidence_count := A, candidate_hash := HA},
    #{evidence_count := B, candidate_hash := HB}
) ->
    case A =:= B of
        true -> HA =< HB;
        false -> A > B
    end.

strip_volatile(Map) when is_map(Map) -> maps:without([recorded_at, generated_at, timestamp], Map);
strip_volatile(Value) -> Value.

hex(Bin) -> iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Bin]).

to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value).
