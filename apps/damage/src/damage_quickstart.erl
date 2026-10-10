%% Copyright (c) DamageBDD. Licensed under Apache-2.0.
%% Deterministic, network-free URL -> supported DamageBDD HTTP steps.
-module(damage_quickstart).

-export([generate/1, parse_url/1, trial_target_allowed/1, public_ipv4/1]).

-define(MAX_URL_BYTES, 2048).

-spec generate(binary() | string()) -> {ok, map()} | {error, atom()}.
generate(Url) ->
    case parse_url(Url) of
        {ok, #{host := Host, path := Path, origin := Origin, url := Canonical}} ->
            Feature = iolist_to_binary([
                <<"Feature: First API verification\n\n">>,
                <<"  Scenario: GET endpoint returns HTTP 200\n">>,
                <<"    Given I am using server \"">>, Origin, <<"\"\n">>,
                <<"    When I make a GET request to \"">>, Path, <<"\"\n">>,
                <<"    Then the response status must be \"200\"\n">>
            ]),
            {ok, #{url => Canonical, host => Host, path => Path,
                   origin => Origin, expected_status => 200, feature => Feature}};
        {error, _} = Error -> Error
    end.

-spec parse_url(binary() | string()) -> {ok, map()} | {error, atom()}.
parse_url(Url0) when is_binary(Url0); is_list(Url0) ->
    try
        Url = unicode:characters_to_binary(Url0),
        case byte_size(Url) =< ?MAX_URL_BYTES andalso byte_size(Url) > 0 of
            false -> {error, invalid_url_length};
            true -> from_parsed(uri_string:parse(binary_to_list(Url)))
        end
    catch _:_ -> {error, invalid_url} end;
parse_url(_) ->
    {error, invalid_url}.

from_parsed(#{scheme := Scheme0, host := Host0} = Parts) ->
    Scheme = as_binary(Scheme0),
    Host = lowercase(as_binary(Host0)),
    Path0 = as_binary(maps:get(path, Parts, "/")),
    Path = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
    case {Scheme, valid_host(Host), valid_path(Path),
          maps:is_key(port, Parts), maps:is_key(userinfo, Parts),
          maps:is_key(query, Parts), maps:is_key(fragment, Parts)} of
        {<<"https">>, true, true, false, false, false, false} ->
            Origin = <<"https://", Host/binary>>,
            {ok, #{host => Host, path => Path, origin => Origin,
                   url => <<Origin/binary, Path/binary>>}};
        {<<"https">>, _, _, _, _, _, _} -> {error, unsafe_or_unsupported_url};
        _ -> {error, https_required}
    end;
from_parsed(_) ->
    {error, invalid_url}.

valid_host(Host) when byte_size(Host) >= 4, byte_size(Host) =< 253 ->
    Labels = binary:split(Host, <<".">>, [global]),
    length(Labels) >= 2 andalso
    lists:all(fun valid_label/1, Labels) andalso
    valid_tld(lists:last(Labels));
valid_host(_) -> false.

valid_label(Label) when byte_size(Label) > 0, byte_size(Label) =< 63 ->
    First = binary:first(Label),
    Last = binary:last(Label),
    alnum(First) andalso alnum(Last) andalso
    re:run(Label, <<"^[a-z0-9-]+$">>, [{capture, none}]) =:= match;
valid_label(_) -> false.

valid_tld(Tld) when byte_size(Tld) >= 2 ->
    re:run(Tld, <<"^[a-z-]+$">>, [{capture, none}]) =:= match;
valid_tld(_) -> false.

alnum(C) -> (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9).

valid_path(<<>>) -> true;
valid_path(<<"/", _/binary>> = Path) ->
    byte_size(Path) =< 1024 andalso
    re:run(Path, <<"^/[A-Za-z0-9_./~%-]*$">>, [{capture, none}]) =:= match;
valid_path(_) -> false.

%% Paths are *exact* strings, never prefixes or arbitrary regexes.
-spec trial_target_allowed(map()) -> boolean().
trial_target_allowed(#{host := Host, path := Path}) ->
    case application:get_env(damage, quickstart_trial_targets, []) of
        Targets when is_list(Targets) ->
            lists:any(
              fun({AllowedHost, AllowedPaths}) when is_list(AllowedPaths) ->
                      lowercase(as_binary(AllowedHost)) =:= Host andalso
                      lists:member(Path, [as_binary(P) || P <- AllowedPaths]);
                 (_) -> false
              end, Targets);
        _ -> false
    end;
trial_target_allowed(_) -> false.

%% Connect only to a pre-resolved IPv4 address. Refuse non-global destinations,
%% including loopback, RFC1918, CGNAT, link-local, documentation and multicast.
-spec public_ipv4(tuple()) -> boolean().
public_ipv4({A, B, C, D}) when
    A >= 0, A =< 255, B >= 0, B =< 255,
    C >= 0, C =< 255, D >= 0, D =< 255 ->
    not (
        A =:= 0 orelse A =:= 10 orelse A =:= 127 orelse A >= 224 orelse
        (A =:= 100 andalso B >= 64 andalso B =< 127) orelse
        (A =:= 169 andalso B =:= 254) orelse
        (A =:= 172 andalso B >= 16 andalso B =< 31) orelse
        (A =:= 192 andalso (B =:= 0 orelse B =:= 168 orelse
                              (B =:= 88 andalso C =:= 99))) orelse
        (A =:= 192 andalso B =:= 0 andalso C =:= 2) orelse
        (A =:= 198 andalso (B =:= 18 orelse B =:= 19 orelse
                              (B =:= 51 andalso C =:= 100))) orelse
        (A =:= 203 andalso B =:= 0 andalso C =:= 113)
    );
public_ipv4(_) -> false.

as_binary(V) when is_binary(V) -> V;
as_binary(V) when is_list(V) -> unicode:characters_to_binary(V).
lowercase(B) -> list_to_binary(string:lowercase(binary_to_list(B))).
