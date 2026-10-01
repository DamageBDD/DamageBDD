%% Pure wake/utterance state machine. Times are monotonic milliseconds.
-module(erm_voice_boundary).
-export([new/0, normalize/1, wake/2, feed/5, tick/3, cancel/1]).

new() -> #{phase => idle, text => <<>>, last_seen => undefined,
           changed => undefined, deadline => undefined, recent => #{}, consumed => <<>>,
           wake_prefix => <<>>, prefix_at => undefined}.
cancel(S) -> S#{phase => locked, text => <<>>, deadline => undefined}.

normalize(Text) ->
    Bin = unicode:characters_to_nfkc_binary(Text),
    true = is_binary(Bin),
    Folded = unicode:characters_to_binary(string:casefold(Bin)),
    true = is_binary(Folded),
    string:trim(re:replace(Folded, "[^\\p{L}\\p{M}\\p{N}_]+", " ",
                           [global, unicode, {return, binary}])).

%% Addressed speech only: no wake word hidden in a song title or conversation.
%% Longer aliases win; aliases are explicit, never fuzzy/substring matched.
wake(Text, Phrases) ->
    Tokens = tokens(normalize(Text)),
    Aliases = lists:sort(fun(A, B) -> length(A) > length(B) end,
                        [tokens(normalize(P)) || P <- Phrases,
                         normalize(P) =/= <<>>]),
    wake_tokens(Tokens, Aliases).
wake_tokens(Tokens, Aliases) ->
    case strip_alias(Tokens, Aliases) of
        nomatch ->
            case Tokens of
                [P | Rest] when P =:= <<"hey">>; P =:= <<"okay">>; P =:= <<"ok">> ->
                    strip_alias(Rest, Aliases);
                _ -> nomatch
            end;
        Match -> Match
    end.
strip_alias(_Tokens, []) -> nomatch;
strip_alias(Tokens, [Alias | Rest]) ->
    case lists:prefix(Alias, Tokens) of
        true -> {wake, join(lists:nthtail(length(Alias), Tokens))};
        false -> strip_alias(Tokens, Rest)
    end.
tokens(<<>>) -> [];
tokens(B) -> binary:split(B, <<" ">>, [global]).
join(Tokens) -> iolist_to_binary(lists:join(<<" ">>, Tokens)).

feed(Text0, Phrases, Now, S0, Opts) ->
    %% Bound untrusted STT input before normalizing or retaining it.
    Text = unicode:characters_to_binary(Text0),
    case is_binary(Text) andalso byte_size(Text) =< 4096 of
        false -> cancel(S0);
        true -> feed_text(normalize(Text), Phrases, Now, S0, Opts)
    end.
feed_text(<<>>, _Phrases, _Now, S, _Opts) -> S;
feed_text(Text, Phrases, Now, S0, Opts) ->
    S = expire_lock(Now, S0, Opts),
    {Match, Prefixed} = match_with_prefix(Text, Phrases, Now, S),
    Seen = Prefixed#{last_seen => Now},
    case {maps:get(phase, S), Match} of
        {idle, {wake, Command}} ->
            candidate(Command, Now, Seen#{phase => capturing,
                deadline => Now + maps:get(command_window_ms, Opts, 8000)}, Opts);
        {capturing, {wake, Command}} -> candidate(Command, Now, Seen, Opts);
        {capturing, nomatch} ->
            %% A wake-only record may be followed by a separate command record.
            %% Otherwise accept rolling-prefix/suffix overlaps only. Unrelated
            %% background speech closes the capture instead of entering context.
            Old = maps:get(text, S),
            case merge(Old, Text) of
                unrelated -> cancel(Seen);
                Joined -> candidate(Joined, Now, Seen, Opts)
            end;
        {locked, {wake, Command}} ->
            %% A different addressed action (e.g. pause after next) can start
            %% immediately. Same-verb revisions stay locked until re-armed.
            case different_action(maps:get(consumed, S), Command) of
                true -> candidate(Command, Now, Seen#{phase => capturing,
                    deadline => Now + maps:get(command_window_ms, Opts, 8000)}, Opts);
                false -> Seen
            end;
        {locked, nomatch} -> Seen#{phase => idle, text => <<>>};
        _ -> Seen
    end.
different_action(Old, <<>>) when Old =/= <<>> -> true;
different_action(Old, New) ->
    case {tokens(Old), tokens(New)} of
        {[A | _], [B | _]} -> A =/= B;
        _ -> false
    end.

match_with_prefix(Text, Phrases, Now, S = #{phase := idle}) ->
    Prefix = maps:get(wake_prefix, S),
    At = maps:get(prefix_at, S),
    Clear = S#{wake_prefix => <<>>, prefix_at => undefined},
    case wake(Text, Phrases) of
        nomatch ->
            Combined = case Prefix =/= <<>> andalso is_integer(At) andalso Now - At =< 1500 of
                true -> <<Prefix/binary, " ", Text/binary>>;
                false -> Text
            end,
            case wake(Combined, Phrases) of
                nomatch ->
                    case wake_prefix(Combined, Phrases) of
                        true -> {nomatch, Clear#{wake_prefix => Combined, prefix_at => Now}};
                        false -> {nomatch, Clear}
                    end;
                Match -> {Match, Clear}
            end;
        Match -> {Match, Clear}
    end;
match_with_prefix(Text, Phrases, _Now, S) -> {wake(Text, Phrases), S}.
wake_prefix(Text, Phrases) ->
    T0 = tokens(Text),
    T = case T0 of
        [P | Rest] when P =:= <<"hey">>; P =:= <<"ok">>; P =:= <<"okay">> -> Rest;
        _ -> T0
    end,
    T =/= [] andalso lists:any(fun(P) ->
        Alias = tokens(normalize(P)),
        length(T) < length(Alias) andalso lists:prefix(T, Alias)
    end, Phrases).

candidate(Text, Now, S, Opts) ->
    case byte_size(Text) =< maps:get(max_command_bytes, Opts, 512) of
        false -> cancel(S);
        true ->
            case Text =:= maps:get(text, S) of
                true -> S;
                false -> S#{text => Text, changed => Now}
            end
    end.
merge(<<>>, Text) -> Text;
merge(Old, Text) ->
    A = tokens(Old), B = tokens(Text),
    case lists:prefix(A, B) orelse lists:prefix(B, A) of
        true -> Text;
        false -> overlap(A, B, min(length(A), length(B)))
    end.
overlap(_A, _B, 0) -> unrelated;
overlap(A, B, N) ->
    case lists:nthtail(length(A) - N, A) =:= lists:sublist(B, N) of
        true -> join(A ++ lists:nthtail(N, B));
        false -> overlap(A, B, N - 1)
    end.

tick(Now, S0, Opts) ->
    S = expire_lock(Now, S0, Opts),
    case maps:get(phase, S) of
        capturing ->
            Text = maps:get(text, S),
            Deadline = maps:get(deadline, S),
            Changed = maps:get(changed, S),
            case {Now >= Deadline, Text =/= <<>> andalso is_integer(Changed)
                  andalso Now - Changed >= maps:get(settle_ms, Opts, 1100)} of
                {true, _} -> {none, cancel(S)}; %% Never execute a truncated timeout.
                {false, true} ->
                    Recent = maps:filter(fun(_, At) ->
                        Now - At < maps:get(command_dedupe_ms, Opts, 3000)
                    end, maps:get(recent, S)),
                    Locked = (cancel(S))#{recent => maps:put(Text, Now, Recent), consumed => Text},
                    case maps:is_key(Text, Recent) of
                        true -> {none, Locked};
                        false -> {{command, Text}, Locked}
                    end;
                _ -> {none, S}
            end;
        _ -> {none, S}
    end.
expire_lock(Now, S = #{phase := locked, last_seen := Last}, Opts)
  when is_integer(Last) ->
    case Now - Last >= maps:get(rearm_silence_ms, Opts, 6000) of
        true -> S#{phase => idle, text => <<>>};
        false -> S
    end;
expire_lock(_Now, S, _Opts) -> S.
