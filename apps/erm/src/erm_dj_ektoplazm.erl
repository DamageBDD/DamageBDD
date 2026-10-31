%% Ektoplazm release adapter. No global/default licence is inferred.
%% Only a release's own entry and explicit licensing paragraph are trusted.
-module(erm_dj_ektoplazm).
-export([discover/0, discover/1, parse_discovery/1, fetch_release/1, parse_release/2]).

-define(LISTING, <<"https://ektoplazm.com/free-music">>).
-define(MAX_HTML, 2097152).

discover() -> discover(20).
discover(Limit) when is_integer(Limit), Limit > 0, Limit =< 100 ->
    case erm_dj_http:get(?LISTING) of
        {ok, Html} ->
            case parse_discovery(Html) of
                {ok, URLs} -> {ok, lists:sublist(URLs, Limit)};
                E -> E
            end;
        E -> E
    end;
discover(_) -> {error, invalid_limit}.

parse_discovery(Html) when is_binary(Html), byte_size(Html) =< ?MAX_HTML ->
    URLs = unique([U || Raw <- capture_all(Html, <<"<a\\b[^>]*href=[\"']([^\"']+)[\"']">>),
                        {ok, U} <- [release_url(decode(Raw))]]),
    {ok, lists:sublist(URLs, 100)};
parse_discovery(_) -> {error, invalid_html}.

fetch_release(URL) ->
    case release_url(URL) of
        {ok, Safe} ->
            case erm_dj_http:get(Safe) of
                {ok, HTML} -> parse_release(HTML, Safe);
                E -> E
            end;
        E -> E
    end.

parse_release(Html, URL) when is_binary(Html), byte_size(Html) =< ?MAX_HTML ->
    try
        {ok, PageURL} = release_url(URL),
        %% Scope before reading links: unrelated footer and comment licences
        %% must never turn an unlicensed release into a licensed one.
        {ok, Post} = first_element(<<"div">>, <<"post">>, Html),
        {ok, Entry} = first_element(<<"div">>, <<"entry">>, Post),
        {ok, Licence} = release_license(Entry),
        Name = text(first_capture(Post, <<"<h[12]\\b[^>]*>(.*?)</h[12]>">>, <<>>)),
        true = byte_size(Name) > 0,
        {Artist, Album} = artist_album(Name),
        Tags = unique([string:lowercase(text(T)) || T <-
             capture_all(Post, <<"<a\\b[^>]*href=[\"'](?:https://(?:www\\.)?ektoplazm\\.com)?/style/[^\"']*[\"'][^>]*>(.*?)</a>">>)]),
        Names = [text(N) || N <- capture_all(Entry,
                   <<"<span\\b[^>]*class=[\"']t[\"'][^>]*>(.*?)</span>">>)],
        Decoded = binary:replace(decode(Entry), <<"\\/">>, <<"/">>, [global]),
        Audio = unique([U || Raw <- capture_all(Decoded, <<"(https?://[^\\s\"'<>]+)">>),
                            {ok, U} <- [media_url(Raw, audio)]]),
        Downloads = unique([U || Raw <- capture_all(Entry, <<"<a\\b[^>]*href=[\"']([^\"']+)[\"']">>),
                                {ok, U} <- [media_url(decode(Raw), zip)]]),
        Evidence = #{page_url => PageURL, html_sha256 => hex(crypto:hash(sha256, Html)),
                     kind => release_page_assertion,
                     license_url => maps:get(url, Licence)},
        Base = #{source => ektoplazm, artist => Artist, album => Album,
                 source_url => PageURL, license => Licence, license_evidence => Evidence,
                 tags => Tags, media_kind => preview},
        Tracks = [Base#{id => digest(<<PageURL/binary, "#", U/binary>>),
                        title => nth_or_filename(N, Names, U), media_url => U,
                        track_number => N} || {N, U} <- lists:zip(lists:seq(1, length(Audio)), Audio)],
        {ok, #{id => digest(PageURL), source => ektoplazm, title => Album,
               artist => Artist, display_title => Name, source_url => PageURL,
               license => Licence, license_evidence => Evidence, tags => Tags,
               tracks => Tracks,
               downloads => [#{url => U, format => zip} || U <- Downloads]}}
    catch
        error:{badmatch, {error, Reason}} -> {error, Reason};
        error:{badmatch, false} -> {error, missing_release_title};
        _:_ -> {error, invalid_release_page}
    end;
parse_release(_, _) -> {error, invalid_html}.

release_url(URL) ->
    case erm_dj_http:validate_url(URL) of
        {ok, U} ->
            P = uri_string:parse(U),
            case re:run(maps:get(path, P, <<>>), <<"^/free-music/[a-zA-Z0-9_-]+/?$">>) of
                {match, _} ->
                    case maps:is_key(query, P) of
                        true -> {error, invalid_release_url};
                        false -> {ok, uri_string:recompose(P#{host => <<"ektoplazm.com">>})}
                    end;
                nomatch -> {error, invalid_release_url}
            end;
        E -> E
    end.

media_url(URL, Kind) ->
    case erm_dj_http:validate_url(URL) of
        {ok, U} ->
            #{path := P} = uri_string:parse(U),
            Pattern = case Kind of
                audio -> <<"^/(audio|mp3|files)/.+\\.(mp3|ogg|flac|wav)$">>;
                zip -> <<"^/files/.+\\.zip$">>
            end,
            case re:run(P, Pattern, [caseless]) of
                {match, _} -> {ok, U};
                nomatch -> {error, unsupported_media_url}
            end;
        E -> E
    end.

release_license(Entry) ->
    %% Require a licensing statement inside the release body. A lone CC icon,
    %% linked artist biography or site footer is insufficient evidence.
    Paragraphs = capture_all(Entry, <<"<p\\b[^>]*>(.*?)</p>">>),
    Statements = [P || P <- Paragraphs,
        re:run(text(P), <<"(released under|licensed under|licensed to|licensed.*creative commons)">>, [caseless]) =/= nomatch],
    Links = unique(lists:append([capture_all(P, <<"<a\\b[^>]*href=[\"']([^\"']+)[\"']">>) || P <- Statements])),
    CCLinks = [L || L <- Links, re:run(L, <<"^https?://(?:www\\.)?creativecommons\\.org/">>, [caseless]) =/= nomatch],
    case CCLinks of
        [] -> {error, missing_release_license};
        _ ->
            Parsed = [parse_license(decode(L)) || L <- CCLinks],
            case lists:all(fun({ok, _}) -> true; (_) -> false end, Parsed) of
                false -> {error, unsupported_release_license};
                true ->
                    Licences = unique([L || {ok, L} <- Parsed]),
                    case Licences of [L] -> {ok, L}; _ -> {error, ambiguous_release_license} end
            end
    end.

parse_license(URL) ->
    case re:run(URL, <<"^https?://(?:www\\.)?creativecommons\\.org/licenses/(by|by-sa|by-nd|by-nc|by-nc-sa|by-nc-nd)/(1\\.0|2\\.0|2\\.5|3\\.0|4\\.0)/?(?:deed(?:\\.[a-z]+)?)?$">>,
                [caseless, {capture, [1, 2], binary}]) of
        {match, [Code0, Version]} ->
            Code = string:lowercase(Code0),
            Canonical = <<"https://creativecommons.org/licenses/", Code/binary, "/", Version/binary, "/">>,
            {ok, #{id => <<"CC-", (string:uppercase(Code))/binary, "-", Version/binary>>,
                   url => Canonical, version => Version,
                   nc => binary:match(Code, <<"nc">>) =/= nomatch,
                   nd => binary:match(Code, <<"nd">>) =/= nomatch,
                   sa => binary:match(Code, <<"sa">>) =/= nomatch}};
        nomatch -> {error, unsupported_license}
    end.

%% Narrow HTML element extraction with balanced same-name tags. This is not
%% an HTML renderer: malformed or changed page structure fails closed.
first_element(Tag, Class, Html) ->
    Pattern = <<"<", Tag/binary, "\\b[^>]*>">>,
    case re:run(Html, Pattern, [global, caseless, {capture, first, index}]) of
        {match, Matches} -> find_element(Matches, Tag, Class, Html);
        nomatch -> {error, missing_release_content}
    end.
find_element([], _, _, _) -> {error, missing_release_content};
find_element([[{Start, Len}] | More], Tag, Class, Html) ->
    Open = binary:part(Html, Start, Len),
    Classes = first_capture(Open, <<"\\bclass=[\"']([^\"']*)[\"']">>, <<>>),
    case lists:member(Class, binary:split(Classes, <<" ">>, [global])) of
        true ->
            Tail = binary:part(Html, Start + Len, byte_size(Html) - Start - Len),
            case close_position(Tag, Tail) of
                {ok, N} -> {ok, binary:part(Tail, 0, N)};
                E -> E
            end;
        false -> find_element(More, Tag, Class, Html)
    end.
close_position(Tag, Html) ->
    Pattern = <<"</?", Tag/binary, "\\b[^>]*>">>,
    case re:run(Html, Pattern, [global, caseless, {capture, first, index}]) of
        {match, Matches} -> closing(Matches, Html, 1);
        nomatch -> {error, malformed_release_content}
    end.
closing([], _, _) -> {error, malformed_release_content};
closing([[{Pos, Len}] | More], Html, Depth) ->
    Token = binary:part(Html, Pos, Len),
    New = case Token of <<"</", _/binary>> -> Depth - 1; _ -> Depth + 1 end,
    case New of 0 -> {ok, Pos}; _ -> closing(More, Html, New) end.

capture_all(B, P) ->
    case re:run(B, P, [global, caseless, dotall, {capture, [1], binary}]) of
        {match, Rows} -> [V || [V] <- Rows];
        nomatch -> []
    end.
first_capture(B, P, Default) -> case capture_all(B, P) of [X | _] -> X; [] -> Default end.
text(B) ->
    Stripped = re:replace(B, <<"<[^>]*>">>, <<" ">>, [global, {return, binary}]),
    string:trim(re:replace(decode(Stripped), <<"\\s+">>, <<" ">>, [global, {return, binary}])).
decode(B) ->
    Basic = lists:foldl(fun({From, To}, A) -> binary:replace(A, From, To, [global]) end,
                        B, [{<<"&quot;">>, <<"\"">>}, {<<"&#039;">>, <<"'">>},
                            {<<"&apos;">>, <<"'">>}, {<<"&lt;">>, <<"<">>},
                            {<<"&gt;">>, <<">">>}, {<<"&nbsp;">>, <<" ">>},
                            {<<"&amp;">>, <<"&">>}]),
    decode_numeric(Basic).
decode_numeric(B) ->
    case re:run(B, <<"&#(x[0-9a-fA-F]+|[0-9]+);">>,
                [global, {capture, [0, 1], index}]) of
        {match, Matches} -> iolist_to_binary(decode_entities(Matches, B, 0, []));
        nomatch -> B
    end.
decode_entities([], B, Pos, Acc) ->
    lists:reverse([binary:part(B, Pos, byte_size(B) - Pos) | Acc]);
decode_entities([[{Start, Len}, {DigitStart, DigitLen}] | More], B, Pos, Acc) ->
    Digits = binary:part(B, DigitStart, DigitLen),
    Replacement = try
        N = case Digits of <<"x", Hex/binary>> -> binary_to_integer(Hex, 16); _ -> binary_to_integer(Digits) end,
        Converted = unicode:characters_to_binary([N]),
        case is_binary(Converted) of true -> Converted; false -> <<"?">> end
    catch _:_ -> <<"?">> end,
    Prefix = binary:part(B, Pos, Start - Pos),
    decode_entities(More, B, Start + Len, [Replacement, Prefix | Acc]).
artist_album(Name) ->
    case re:split(Name, <<" +(?:-|", 16#e2, 16#80, 16#93, "|",16#e2,16#80,16#94,") +">>, [{return, binary}, {parts, 2}]) of
        [Artist, Album] -> {Artist, Album};
        _ -> {<<"Various Artists">>, Name}
    end.
nth_or_filename(N, Names, URL) ->
    case length(Names) >= N of
        true -> lists:nth(N, Names);
        false ->
            #{path := P} = uri_string:parse(URL),
            filename:basename(uri_string:percent_decode(P))
    end.
unique(L) -> unique(L, #{}, []).
unique([], _, Acc) -> lists:reverse(Acc);
unique([X | Xs], Seen, Acc) ->
    case maps:is_key(X, Seen) of
        true -> unique(Xs, Seen, Acc);
        false -> unique(Xs, Seen#{X => true}, [X | Acc])
    end.
digest(B) -> hex(crypto:hash(sha256, B)).
hex(B) -> string:lowercase(binary:encode_hex(B)).
