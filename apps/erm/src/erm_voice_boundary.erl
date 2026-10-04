%% Pure wake/utterance state machine. Times are monotonic milliseconds.
-module(erm_voice_boundary).
-export([new/0, normalize/1, wake/2, feed/5, tick/3, cancel/1, suffix/2]).

new() ->
    #{
        phase => idle,
        text => <<>>,
        last_seen => undefined,
        changed => undefined,
        deadline => undefined,
        recent => #{},
        consumed => <<>>,
        wake_prefix => <<>>,
        prefix_at => undefined,
        utterance_id => undefined,
        finalized => false,
        structured => false,
        done => []
    }.
cancel(S) -> S#{phase => locked, text => <<>>, deadline => undefined}.

normalize(Text) ->
    Bin = unicode:characters_to_nfkc_binary(Text),
    true = is_binary(Bin),
    Folded = unicode:characters_to_binary(string:casefold(Bin)),
    true = is_binary(Folded),
    string:trim(
        re:replace(
            Folded,
            "[^\\p{L}\\p{M}\\p{N}_]+",
            " ",
            [global, unicode, {return, binary}]
        )
    ).

%% Addressed speech only: no wake word hidden in a song title or conversation.
%% Longer aliases win; aliases are explicit, never fuzzy/substring matched.
wake(Text, Phrases) ->
    Tokens = tokens(normalize(Text)),
    Aliases = lists:sort(
        fun(A, B) -> length(A) > length(B) end,
        [
            tokens(normalize(P))
         || P <- Phrases,
            normalize(P) =/= <<>>
        ]
    ),
    case wake_tokens(Tokens, Aliases) of
        {wake, Command} ->
            {wake,
                suffix(
                    unicode:characters_to_binary(Text),
                    length(Tokens) - length(tokens(Command))
                )};
        nomatch ->
            nomatch
    end.

%% Remove a counted matching prefix without normalizing command arguments.
%% Offsets returned by re are byte offsets into the original UTF-8 binary.
suffix(Text, N) ->
    case re:run(Text, "[\\p{L}\\p{M}\\p{N}_]+", [global, unicode, {capture, first, index}]) of
        {match, Matches} when N > 0, length(Matches) >= N ->
            [{At, Len}] = lists:nth(N, Matches),
            Rest = binary:part(Text, At + Len, byte_size(Text) - At - Len),
            re:replace(Rest, "^[\\s,:;.!?]+", "", [unicode, {return, binary}]);
        _ ->
            Text
    end.
wake_tokens(Tokens, Aliases) ->
    case strip_alias(Tokens, Aliases) of
        nomatch ->
            case Tokens of
                [P | Rest] when P =:= <<"hey">>; P =:= <<"okay">>; P =:= <<"ok">> ->
                    strip_alias(Rest, Aliases);
                _ ->
                    nomatch
            end;
        Match ->
            Match
    end.
strip_alias(_Tokens, []) ->
    nomatch;
strip_alias(Tokens, [Alias | Rest]) ->
    case lists:prefix(Alias, Tokens) of
        true -> {wake, join(lists:nthtail(length(Alias), Tokens))};
        false -> strip_alias(Tokens, Rest)
    end.
tokens(<<>>) -> [];
tokens(B) -> binary:split(B, <<" ">>, [global]).
join(Tokens) -> iolist_to_binary(lists:join(<<" ">>, Tokens)).

%% Structured input must come from an adapter with real utterance boundaries.
feed(#{utterance_id := Id, text := Text, final := Final}, Phrases, Now, S0, Opts) when
    is_binary(Id), byte_size(Id) > 0, byte_size(Id) =< 128, is_boolean(Final)
->
    case lists:member(Id, maps:get(done, S0)) of
        true ->
            S0;
        false ->
            case {maps:get(utterance_id, S0), maps:get(finalized, S0)} of
                {Id, true} ->
                    S0;
                {Previous, _} ->
                    S1 =
                        case Previous of
                            Id ->
                                S0;
                            undefined ->
                                (new())#{done => maps:get(done, S0)};
                            _ ->
                                (new())#{
                                    done => lists:sublist(
                                        [Previous | maps:get(done, S0)], 128
                                    )
                                }
                        end,
                    S2 = feed_plain(
                        Text,
                        Phrases,
                        Now,
                        S1#{utterance_id => Id, structured => true},
                        Opts
                    ),
                    S2#{finalized => Final}
            end
    end;
feed(Text, Phrases, Now, S, Opts) when is_binary(Text); is_list(Text) ->
    %% Do not mix rolling text into an active structured utterance.
    case maps:get(structured, S) of
        true -> S;
        false -> feed_plain(Text, Phrases, Now, S, Opts)
    end;
feed(_, _, _, S, _) ->
    cancel(S).

feed_plain(Text0, Phrases, Now, S0, Opts) ->
    %% Bound untrusted STT input before normalizing or retaining it.
    Text = unicode:characters_to_binary(Text0),
    case is_binary(Text) andalso byte_size(Text) =< 4096 of
        false -> cancel(S0);
        true -> feed_text(string:trim(Text), Phrases, Now, S0, Opts)
    end.
feed_text(<<>>, _Phrases, _Now, S, _Opts) ->
    S;
feed_text(Text, Phrases, Now, S0, Opts) ->
    S = expire_capture(Now, expire_lock(Now, S0, Opts)),
    {Match, Prefixed} = match_with_prefix(Text, Phrases, Now, S),
    Seen = Prefixed#{last_seen => Now},
    case {maps:get(phase, S), Match} of
        {idle, {wake, Command}} ->
            candidate(
                Command,
                Now,
                Seen#{
                    phase => capturing,
                    deadline => Now + maps:get(command_window_ms, Opts, 8000)
                },
                Opts
            );
        {capturing, {wake, Command}} ->
            candidate(Command, Now, Seen, Opts);
        {capturing, nomatch} ->
            %% A wake-only record may be followed by a separate command record.
            %% Otherwise accept rolling-prefix/suffix overlaps only. Unrelated
            %% background speech closes the capture instead of entering context.
            Old = maps:get(text, S),
            case merge(Old, Text) of
                unrelated -> cancel(Seen);
                Joined -> candidate(Joined, Now, Seen, Opts)
            end;
        {locked, _} ->
            Seen;
        _ ->
            Seen
    end.
match_with_prefix(Text, Phrases, Now, S = #{phase := idle}) ->
    Prefix = maps:get(wake_prefix, S),
    At = maps:get(prefix_at, S),
    Clear = S#{wake_prefix => <<>>, prefix_at => undefined},
    case wake(Text, Phrases) of
        nomatch ->
            Combined =
                case Prefix =/= <<>> andalso is_integer(At) andalso Now - At =< 1500 of
                    true -> <<Prefix/binary, " ", Text/binary>>;
                    false -> Text
                end,
            case wake(Combined, Phrases) of
                nomatch ->
                    case wake_prefix(Combined, Phrases) of
                        true -> {nomatch, Clear#{wake_prefix => Combined, prefix_at => Now}};
                        false -> {nomatch, Clear}
                    end;
                Match ->
                    {Match, Clear}
            end;
        Match ->
            {Match, Clear}
    end;
match_with_prefix(Text, Phrases, _Now, S) ->
    {wake(Text, Phrases), S}.
wake_prefix(Text, Phrases) ->
    T0 = tokens(normalize(Text)),
    T =
        case T0 of
            [P | Rest] when P =:= <<"hey">>; P =:= <<"ok">>; P =:= <<"okay">> -> Rest;
            _ -> T0
        end,
    T =/= [] andalso
        lists:any(
            fun(P) ->
                Alias = tokens(normalize(P)),
                length(T) < length(Alias) andalso lists:prefix(T, Alias)
            end,
            Phrases
        ).

candidate(Text, Now, S, Opts) ->
    case byte_size(Text) =< maps:get(max_command_bytes, Opts, 512) of
        false ->
            cancel(S);
        true ->
            case Text =:= maps:get(text, S) of
                true -> S;
                false -> S#{text => Text, changed => Now}
            end
    end.
merge(<<>>, Text) ->
    Text;
merge(Old, Text) ->
    A = tokens(normalize(Old)),
    B = tokens(normalize(Text)),
    case lists:prefix(A, B) orelse lists:prefix(B, A) of
        true ->
            Text;
        false ->
            case overlap(A, B, min(length(A), length(B))) of
                unrelated -> unrelated;
                N -> <<Old/binary, " ", (suffix(Text, N))/binary>>
            end
    end.
overlap(_A, _B, 0) ->
    unrelated;
overlap(A, B, N) ->
    case lists:nthtail(length(A) - N, A) =:= lists:sublist(B, N) of
        true -> N;
        false -> overlap(A, B, N - 1)
    end.

tick(Now, S0, Opts) ->
    S = expire_lock(Now, S0, Opts),
    case maps:get(phase, S) of
        capturing ->
            Text = maps:get(text, S),
            Deadline = maps:get(deadline, S),
            Changed = maps:get(changed, S),
            Ready =
                case maps:get(structured, S) of
                    true ->
                        maps:get(finalized, S);
                    false ->
                        not maps:get(require_final, Opts, false) andalso
                            is_integer(Changed) andalso
                            Now - Changed >= settle_delay(Text, Opts)
                end,
            case {Now >= Deadline, Text =/= <<>> andalso Ready} of
                %% Never execute a truncated timeout.
                {true, _} ->
                    {none, cancel(S)};
                {false, true} ->
                    Recent = maps:filter(
                        fun(_, At) ->
                            Now - At < maps:get(command_dedupe_ms, Opts, 3000)
                        end,
                        maps:get(recent, S)
                    ),
                    Key = normalize(Text),
                    Done =
                        case maps:get(utterance_id, S) of
                            undefined -> maps:get(done, S);
                            Id -> lists:sublist([Id | maps:get(done, S)], 128)
                        end,
                    Locked = (cancel(S))#{
                        recent => maps:put(Key, Now, Recent),
                        consumed => Text,
                        done => Done
                    },
                    case not maps:get(structured, S) andalso maps:is_key(Key, Recent) of
                        true -> {none, Locked};
                        false -> {{command, Text}, Locked}
                    end;
                _ ->
                    {none, S}
            end;
        _ ->
            {none, S}
    end.
expire_capture(Now, S = #{phase := capturing, deadline := Deadline}) when Now >= Deadline ->
    cancel(S);
expire_capture(_, S) ->
    S.
expire_lock(_Now, S = #{structured := true}, _Opts) ->
    S;
expire_lock(Now, S = #{phase := locked, last_seen := Last}, Opts) when
    is_integer(Last)
->
    case Now - Last >= maps:get(rearm_silence_ms, Opts, 6000) of
        true -> S#{phase => idle, text => <<>>};
        false -> S
    end;
expire_lock(_Now, S, _Opts) ->
    S.

%% Exact reversible interruption commands need less settling than open-ended
%% speech. Do not widen wake matching or treat arbitrary prefixes as commands.
settle_delay(Text, Opts) ->
    Normal = maps:get(settle_ms, Opts, 1100),
    case normalize(Text) of
        <<"stop">> -> min(Normal, maps:get(urgent_settle_ms, Opts, 300));
        <<"stop music">> -> min(Normal, maps:get(urgent_settle_ms, Opts, 300));
        <<"pause">> -> min(Normal, maps:get(urgent_settle_ms, Opts, 300));
        <<"pause music">> -> min(Normal, maps:get(urgent_settle_ms, Opts, 300));
        _ -> Normal
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
urgent_stop_before_noise_test() ->
    O = #{settle_ms => 1100},
    S1 = feed("Hey Bob", ["bob"], 0, new(), O),
    S2 = feed("Hey Bob stop", ["bob"], 508, S1, O),
    {none, S3} = tick(800, S2, O),
    {{command, <<"stop">>}, S4} = tick(900, S3, O),
    S5 = feed("Hey Bob stop music", ["bob"], 1048, S4, O),
    {none, S6} = tick(1500, S5, O),
    S7 = feed("Thank you", ["bob"], 2026, S6, O),
    ?assertMatch({none, _}, tick(2300, S7, O)).
urgent_corrected_stop_test() ->
    O = #{settle_ms => 1100},
    S1 = feed("Hey Bob it's tough music", ["bob"], 0, new(), O),
    S2 = feed("Hey Bob stop music", ["bob"], 500, S1, O),
    {{command, <<"stop music">>}, S3} = tick(850, S2, O),
    S4 = feed("Hey Bobs tough music", ["bob"], 1530, S3, O),
    S5 = feed("Hey Bob stop music", ["bob"], 1531, S4, O),
    ?assertMatch({none, _}, tick(2700, S5, O)).
urgent_scope_test() ->
    O = #{settle_ms => 1100},
    ?assertEqual(nomatch, wake("Hey Bobs stop music", ["bob"])),
    ?assertEqual(1100, settle_delay(<<"play song stop music">>, O)),
    ?assertEqual(1100, settle_delay(<<"stop music after this song">>, O)),
    ?assertEqual(300, settle_delay(<<"pause music">>, O)),
    ?assertEqual(700, settle_delay(<<"stop">>, O#{urgent_settle_ms => 700})),
    S1 = feed("Bob stop", ["bob"], 0, new(), O),
    S2 = feed("Bob do not stop", ["bob"], 100, S1, O),
    ?assertMatch({none, _}, tick(400, S2, O)).
-endif.
