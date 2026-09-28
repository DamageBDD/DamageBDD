%%%-------------------------------------------------------------------
%%% NIP-98 HTTP authentication verifier for DamageBDD HTTP handlers.
%%% Keeps untrusted JSON keys as binaries and constructs the small event map
%%% expected by nostrlib explicitly (no atom creation from request data).
%%%-------------------------------------------------------------------
-module(damage_nip98).

-export([verify/2, verify/3, validate_file_payload/2]).

-define(DEFAULT_SKEW_SECONDS, 60).

-spec verify(map(), binary() | list()) -> {ok, map()} | {error, term()}.
verify(Req, ExpectedUrl) ->
    verify(Req, ExpectedUrl, cowboy_req:method(Req)).

-spec verify(map(), binary() | list(), binary() | list()) -> {ok, map()} | {error, term()}.
verify(Req, ExpectedUrl0, ExpectedMethod0) ->
    ExpectedUrl = to_bin(ExpectedUrl0),
    ExpectedMethod = upper_ascii(to_bin(ExpectedMethod0)),
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Nostr ", Token/binary>> ->
            verify_token(Token, ExpectedUrl, ExpectedMethod);
        _ ->
            {error, missing_authorization}
    end.

verify_token(Token, ExpectedUrl, ExpectedMethod) ->
    case decode_auth_event(Token) of
        {ok, Event0} ->
            case normalize_event(Event0) of
                {ok, Event, Tags} ->
                    Checks = [
                        fun() -> check_kind(Event) end,
                        fun() -> check_time(Event) end,
                        fun() -> check_tag(<<"u">>, ExpectedUrl, Tags) end,
                        fun() -> check_tag(<<"method">>, ExpectedMethod, Tags) end,
                        fun() -> check_optional_single_tag(<<"payload">>, Tags) end,
                        fun() -> check_signature(Event) end
                    ],
                    case run_checks(Checks) of
                        ok ->
                            {ok, #{
                                pubkey => maps:get(pubkey, Event),
                                event_id => maps:get(id, Event),
                                created_at => maps:get(created_at, Event),
                                payload => optional_tag_value(<<"payload">>, Tags),
                                event => Event
                            }};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec validate_file_payload(map(), binary()) -> ok | {error, payload_mismatch}.
validate_file_payload(#{payload := undefined}, _HashHex) ->
    ok;
validate_file_payload(#{payload := <<>>}, _HashHex) ->
    ok;
validate_file_payload(#{payload := Payload0}, HashHex0) ->
    Payload = to_bin(Payload0),
    HashHex = lower_ascii(to_bin(HashHex0)),
    case decode_hex(HashHex) of
        {ok, HashRaw} ->
            B64 = base64:encode(HashRaw),
            B64NoPad = trim_b64_padding(B64),
            %% NIP-96 specifies base64(file-sha256); some NIP-98 clients use
            %% the generic NIP-98 hex representation. Accept both while still
            %% binding authentication to the exact uploaded bytes.
            case Payload =:= HashHex orelse Payload =:= B64 orelse Payload =:= B64NoPad of
                true -> ok;
                false -> {error, payload_mismatch}
            end;
        error ->
            {error, payload_mismatch}
    end.

%% ------------------------------------------------------------------
%% Event parsing / validation
%% ------------------------------------------------------------------

decode_auth_event(Token) when is_binary(Token), byte_size(Token) =< 16384 ->
    try
        Json = decode_base64(Token),
        case jsx:decode(Json, [return_maps]) of
            M when is_map(M) -> {ok, M};
            _ -> {error, invalid_authorization_event}
        end
    catch
        _:_ -> {error, invalid_authorization_event}
    end;
decode_auth_event(_) ->
    {error, invalid_authorization_event}.

decode_base64(Token) ->
    case byte_size(Token) rem 4 of
        0 -> base64:decode(Token);
        2 -> base64:decode(<<Token/binary, "==">>);
        3 -> base64:decode(<<Token/binary, "=">>);
        _ -> erlang:error(invalid_base64)
    end.

normalize_event(M) when is_map(M) ->
    try
        Id = require_binary(<<"id">>, M),
        Pubkey = require_binary(<<"pubkey">>, M),
        Sig = require_binary(<<"sig">>, M),
        Content = maps:get(<<"content">>, M, <<>>),
        Kind = require_integer(<<"kind">>, M),
        CreatedAt = require_integer(<<"created_at">>, M),
        Tags = normalize_tags(maps:get(<<"tags">>, M, [])),
        true = is_binary(Content),
        {ok,
            #{
                id => Id,
                pubkey => Pubkey,
                sig => Sig,
                content => Content,
                kind => Kind,
                created_at => CreatedAt,
                tags => Tags
            },
            Tags}
    catch
        _:_ -> {error, invalid_authorization_event}
    end;
normalize_event(_) ->
    {error, invalid_authorization_event}.

normalize_tags(Tags) when is_list(Tags) ->
    [normalize_tag(T) || T <- Tags];
normalize_tags(_) ->
    erlang:error(invalid_tags).

normalize_tag(T) when is_list(T), length(T) >= 2 ->
    [to_bin(V) || V <- T];
normalize_tag(_) ->
    erlang:error(invalid_tag).

require_binary(Key, M) ->
    case maps:get(Key, M, undefined) of
        B when is_binary(B), byte_size(B) > 0 -> B;
        _ -> erlang:error({invalid_field, Key})
    end.

require_integer(Key, M) ->
    case maps:get(Key, M, undefined) of
        I when is_integer(I), I >= 0 -> I;
        _ -> erlang:error({invalid_field, Key})
    end.

check_signature(Event) ->
    try nostrlib:verify(Event) of
        true -> ok;
        _ -> {error, invalid_signature}
    catch
        _:_ -> {error, invalid_signature}
    end.

check_kind(#{kind := 27235}) -> ok;
check_kind(_) -> {error, invalid_kind}.

check_time(#{created_at := CreatedAt}) ->
    Now = erlang:system_time(second),
    Skew = application:get_env(damage, nip98_skew_seconds, ?DEFAULT_SKEW_SECONDS),
    case is_integer(Skew) andalso Skew > 0 andalso abs(Now - CreatedAt) =< Skew of
        true -> ok;
        false -> {error, stale_authorization}
    end.

check_tag(Name, Expected, Tags) ->
    case tag_values(Name, Tags) of
        [Expected] -> ok;
        [] -> {error, {missing_tag, Name}};
        [_] -> {error, {tag_mismatch, Name}};
        _ -> {error, {duplicate_tag, Name}}
    end.

check_optional_single_tag(Name, Tags) ->
    case tag_values(Name, Tags) of
        [] -> ok;
        [_] -> ok;
        _ -> {error, {duplicate_tag, Name}}
    end.

optional_tag_value(Name, Tags) ->
    case tag_values(Name, Tags) of
        [Value] -> Value;
        [] -> undefined
    end.

tag_values(Name, Tags) ->
    [Value || [TagName, Value | _] <- Tags, TagName =:= Name].

run_checks([]) -> ok;
run_checks([F | Rest]) ->
    case F() of
        ok -> run_checks(Rest);
        {error, _} = Error -> Error
    end.

%% ------------------------------------------------------------------
%% Small binary helpers
%% ------------------------------------------------------------------

decode_hex(Hex) when is_binary(Hex), byte_size(Hex) =:= 64 ->
    try {ok, binary:decode_hex(upper_ascii(Hex))}
    catch
        _:_ -> error
    end;
decode_hex(_) -> error.

trim_b64_padding(Bin) ->
    binary:replace(Bin, <<"=">>, <<>>, [global]).

upper_ascii(B) ->
    << <<(upper_char(C))>> || <<C>> <= B >>.
upper_char(C) when C >= $a, C =< $z -> C - 32;
upper_char(C) -> C.

lower_ascii(B) ->
    << <<(lower_char(C))>> || <<C>> <= B >>.
lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
