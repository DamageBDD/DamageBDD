%%% NIP-01 validation and picture-first event helpers. OTP 27+.
%%% All externally sourced events MUST pass verify/1 before model insertion.
-module(erm_lens_nostr).
-export([
    verify/1,
    event_fields/1,
    validate/1,
    id/1,
    canonical/1,
    post/1,
    tags/2,
    last_tag/2,
    matches/2,
    draft/4,
    picture/5, picture/6,
    reaction/2,
    comment/3,
    hex/1,
    is_hex/2
]).

-spec verify(map()) -> ok | {error, term()}.
verify(E) ->
    case validate(E) of
        ok ->
            try
                Hash = crypto:hash(sha256, canonical(E)),
                case hex(Hash) =:= maps:get(<<"id">>, E) of
                    false ->
                        {error, bad_event_id};
                    true ->
                        Pub = binary:decode_hex(maps:get(<<"pubkey">>, E)),
                        Sig = binary:decode_hex(maps:get(<<"sig">>, E)),
                        case nostrlib_schnorr:verify(Hash, Pub, Sig) of
                            true -> ok;
                            _ -> {error, bad_signature}
                        end
                end
            catch
                error:undef -> {error, schnorr_verifier_unavailable};
                _:_ -> {error, verification_failed}
            end;
        Error ->
            Error
    end.

%% Strip unsigned extension fields before retention and retransmission.
event_fields(E) ->
    maps:with(
        [
            <<"id">>,
            <<"pubkey">>,
            <<"sig">>,
            <<"created_at">>,
            <<"kind">>,
            <<"content">>,
            <<"tags">>
        ],
        E
    ).

-spec validate(term()) -> ok | {error, invalid_event}.
validate(E) ->
    %% Malformed local terms (including improper tag lists) fail closed too.
    try
        validate_fields(E)
    catch
        _:_ -> {error, invalid_event}
    end.

validate_fields(#{
    <<"id">> := Id,
    <<"pubkey">> := Pub,
    <<"sig">> := Sig,
    <<"created_at">> := T,
    <<"kind">> := K,
    <<"content">> := C,
    <<"tags">> := Tags
}) when
    is_integer(T),
    T >= 0,
    T =< 9007199254740991,
    is_integer(K),
    K >= 0,
    K =< 65535,
    is_binary(C),
    byte_size(C) =< 65536,
    is_list(Tags),
    length(Tags) =< 256
->
    GoodTags = valid_tags(Tags, 256, 98304),
    case
        is_hex(Id, 64) andalso is_hex(Pub, 64) andalso is_hex(Sig, 128) andalso
            utf8(C) andalso GoodTags
    of
        true -> ok;
        false -> {error, invalid_event}
    end;
validate_fields(_) ->
    {error, invalid_event}.

%% Count byte budgets incrementally, without allocating term_to_binary/1 for
%% an attacker-controlled tag tree. Include small per-element framing costs.
valid_tags([], _Left, Budget) ->
    Budget >= 0;
valid_tags([Tag | Rest], Left, Budget) when Left > 0, Budget >= 0 ->
    case tag_budget(Tag, 32, Budget - 2) of
        {ok, Remaining} -> valid_tags(Rest, Left - 1, Remaining);
        error -> false
    end;
valid_tags(_, _, _) ->
    false.

tag_budget([], _Left, Budget) when Budget >= 0 -> {ok, Budget};
tag_budget([V | Rest], Left, Budget) when
    Left > 0,
    is_binary(V),
    byte_size(V) =< 8192,
    Budget >= byte_size(V) + 4
->
    case utf8(V) of
        true -> tag_budget(Rest, Left - 1, Budget - byte_size(V) - 4);
        false -> error
    end;
tag_budget(_, _, _) ->
    error.

utf8(B) -> is_list(unicode:characters_to_list(B, utf8)).
is_hex(B, N) when is_binary(B), byte_size(B) =:= N ->
    lists:all(
        fun(C) ->
            (C >= $0 andalso C =< $9) orelse
                (C >= $a andalso C =< $f)
        end,
        binary_to_list(B)
    );
is_hex(_, _) ->
    false.
hex(B) -> string:lowercase(binary:encode_hex(B)).
id(E) -> hex(crypto:hash(sha256, canonical(E))).

%% NIP-01 canonical JSON; never serialize the entire map to calculate an ID.
%% Preserve UTF-8, do not escape '/' or add whitespace.
canonical(E) ->
    iolist_to_binary([
        "[0,",
        quoted(maps:get(<<"pubkey">>, E)),
        ",",
        integer_to_binary(maps:get(<<"created_at">>, E)),
        ",",
        integer_to_binary(maps:get(<<"kind">>, E)),
        ",",
        array([array([quoted(V) || V <- Tag]) || Tag <- maps:get(<<"tags">>, E)]),
        ",",
        quoted(maps:get(<<"content">>, E)),
        "]"
    ]).
array(Values) -> ["[", lists:join(",", Values), "]"].
quoted(B) -> [$", [escape(C) || <<C>> <= B], $"].
escape($") -> <<"\\\"">>;
escape($\\) -> <<"\\\\">>;
escape(8) -> <<"\\b">>;
escape(9) -> <<"\\t">>;
escape(10) -> <<"\\n">>;
escape(12) -> <<"\\f">>;
escape(13) -> <<"\\r">>;
escape(C) when C < 32 -> io_lib:format("\\u~4.16.0b", [C]);
escape(C) -> C.

tags(E, Name) -> [V || [N, V | _] <- maps:get(<<"tags">>, E, []), N =:= Name].
last_tag(E, Name) ->
    case tags(E, Name) of
        [] -> undefined;
        Values -> lists:last(Values)
    end.

-spec post(map()) -> {ok, map()} | skip.
post(E = #{<<"kind">> := K}) when K =:= 20; K =:= 1 ->
    %% Hide content-warning events by default, including tags with no reason.
    Warning = lists:any(
        fun
            ([<<"content-warning">> | _]) -> true;
            (_) -> false
        end,
        maps:get(<<"tags">>, E, [])
    ),
    %% Kind-1 replies stay in their thread, not the discovery feed.
    Reply = K =:= 1 andalso tags(E, <<"e">>) =/= [],
    Imeta = [
        M
     || [<<"imeta">> | Values] <- maps:get(<<"tags">>, E, []),
        M <- [parse_imeta(Values)],
        M =/= skip
    ],
    Images0 =
        case {Imeta, K} of
            {[], 1} -> content_images(maps:get(<<"content">>, E, <<>>));
            _ -> Imeta
        end,
    Images = lists:sublist(unique_images(Images0), 10),
    case Warning orelse Reply orelse Images =:= [] of
        true ->
            skip;
        false ->
            {ok, #{
                event => E,
                id => maps:get(<<"id">>, E),
                author => maps:get(<<"pubkey">>, E),
                created_at => maps:get(<<"created_at">>, E),
                caption => maps:get(<<"content">>, E),
                images => Images
            }}
    end;
post(_) ->
    skip.

parse_imeta(Values) ->
    Fields = lists:foldl(
        fun(V, A) ->
            case binary:split(V, <<" ">>) of
                [Key, Value] -> A#{Key => Value};
                _ -> A
            end
        end,
        #{},
        Values
    ),
    Url = maps:get(<<"url">>, Fields, <<>>),
    Mime = maps:get(<<"m">>, Fields, <<>>),
    Hash = maps:get(<<"x">>, Fields, <<>>),
    case
        safe_url(Url) andalso (image_mime(Mime) orelse image_extension(Url)) andalso
            (Hash =:= <<>> orelse is_hex(Hash, 64))
    of
        true ->
            #{
                url => Url,
                mime => Mime,
                alt => maps:get(<<"alt">>, Fields, <<>>),
                sha256 => maps:get(<<"x">>, Fields, <<>>)
            };
        false ->
            skip
    end.
image_mime(M) ->
    lists:member(M, [
        <<"image/png">>,
        <<"image/jpeg">>,
        <<"image/webp">>,
        <<"image/gif">>,
        <<"image/avif">>,
        <<"image/apng">>
    ]).
image_extension(Url) ->
    re:run(
        Url,
        <<"\\.(png|jpe?g|webp|gif|avif)(?:[?#]|$)">>,
        [caseless, {capture, none}]
    ) =:= match.
safe_url(<<"https://", _/binary>> = Url) when byte_size(Url) =< 4096 ->
    %% DNS/IP policy remains in the pinned HTTPS decoder, never in GTK.
    try
        #{scheme := <<"https">>, host := Host} = U = uri_string:parse(Url),
        byte_size(Host) > 0 andalso
            not maps:is_key(userinfo, U) andalso
            not maps:is_key(fragment, U) andalso
            maps:get(port, U, 443) =:= 443 andalso
            lists:all(fun(X) -> X > 32 andalso X =/= 127 end, binary_to_list(Url))
    catch
        _:_ -> false
    end;
safe_url(_) ->
    false.
content_images(C) ->
    case re:run(C, <<"https://[^\\s<>\\\"]+">>, [global, {capture, first, binary}]) of
        {match, URLs} ->
            [
                #{url => U, mime => <<>>, alt => <<>>, sha256 => <<>>}
             || [U] <- URLs, image_extension(U), safe_url(U)
            ];
        nomatch ->
            []
    end.
unique_images(Images) ->
    {_, Rev} = lists:foldl(
        fun(M, {Seen, A}) ->
            U = maps:get(url, M),
            case maps:is_key(U, Seen) of
                true -> {Seen, A};
                false -> {Seen#{U => true}, [M | A]}
            end
        end,
        {#{}, []},
        Images
    ),
    lists:reverse(Rev).

%% Also enforce subscriptions locally: a relay is not a trusted query engine.
matches(E, F) ->
    lists:all(
        fun
            ({<<"kinds">>, Ks}) ->
                lists:member(maps:get(<<"kind">>, E, -1), Ks);
            ({<<"authors">>, Ps}) ->
                lists:member(maps:get(<<"pubkey">>, E, <<>>), Ps);
            ({<<"ids">>, Ids}) ->
                lists:member(maps:get(<<"id">>, E, <<>>), Ids);
            ({<<"since">>, T}) ->
                maps:get(<<"created_at">>, E, -1) >= T;
            ({<<"until">>, T}) ->
                maps:get(<<"created_at">>, E, T + 1) =< T;
            ({<<$#, Name/binary>>, Values}) ->
                lists:any(fun(V) -> lists:member(V, Values) end, tags(E, Name));
            ({<<"limit">>, _}) ->
                true;
            (_) ->
                false
        end,
        maps:to_list(F)
    ).

draft(Pub, Kind, Content, Tags) ->
    #{
        <<"pubkey">> => Pub,
        <<"kind">> => Kind,
        <<"content">> => Content,
        <<"created_at">> => erlang:system_time(second),
        <<"tags">> => Tags
    }.
picture(Pub, Url, Mime, Alt, Caption) ->
    picture(Pub, Url, Mime, Alt, Caption, <<"Picture">>).
picture(Pub, Url, Mime, Alt, Caption, Title) ->
    case
        is_hex(Pub, 64) andalso safe_url(Url) andalso image_mime(Mime) andalso
            is_binary(Alt) andalso byte_size(Alt) =< 8000 andalso utf8(Alt) andalso
            is_binary(Caption) andalso byte_size(Caption) =< 65536 andalso utf8(Caption) andalso
            is_binary(Title) andalso byte_size(Title) > 0 andalso byte_size(Title) =< 256 andalso
            utf8(Title)
    of
        true ->
            {ok,
                draft(Pub, 20, Caption, [
                    [<<"title">>, Title],
                    [
                        <<"imeta">>,
                        <<"url ", Url/binary>>,
                        <<"m ", Mime/binary>>,
                        <<"alt ", Alt/binary>>
                    ],
                    [<<"m">>, Mime]
                ])};
        false ->
            {error, invalid_image_url_or_mime}
    end.
reaction(Pub, E) ->
    draft(Pub, 7, <<"+">>, [
        [<<"e">>, maps:get(<<"id">>, E)],
        [<<"p">>, maps:get(<<"pubkey">>, E)],
        [<<"k">>, integer_to_binary(maps:get(<<"kind">>, E))]
    ]).
comment(Pub, E, Text) ->
    Id = maps:get(<<"id">>, E),
    Author = maps:get(<<"pubkey">>, E),
    K = integer_to_binary(maps:get(<<"kind">>, E)),
    case K of
        <<"1">> ->
            draft(Pub, 1, Text, [
                [<<"e">>, Id, <<>>, <<"root">>],
                [<<"p">>, Author]
            ]);
        _ ->
            draft(Pub, 1111, Text, [
                [<<"E">>, Id, <<>>, Author],
                [<<"K">>, K],
                [<<"P">>, Author],
                [<<"e">>, Id, <<>>, Author],
                [<<"k">>, K],
                [<<"p">>, Author]
            ])
    end.
