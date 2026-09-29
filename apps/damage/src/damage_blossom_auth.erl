%%%-------------------------------------------------------------------
%%% Blossom BUD-11 authorization verifier.
%%%
%%% Authorization: Nostr <base64url-without-padding JSON event>
%%% kind:24242 with expiration and action (`t`) tags. Optional `server` tags
%%% scope a token to a host; `x` scopes it to one or more blob hashes.
%%%-------------------------------------------------------------------
-module(damage_blossom_auth).

-export([verify/3, verify/4, verify_deferred_hash/2]).

-spec verify(map(), binary() | list(), binary() | undefined) ->
    {ok, map()} | {error, term()}.
verify(Req, Action, Hash) ->
    verify(Req, Action, Hash, public_server_name(Req)).

-spec verify(map(), binary() | list(), binary() | undefined, binary() | list()) ->
    {ok, map()} | {error, term()}.
verify(Req, Action0, Hash0, Server0) ->
    Action = lower_ascii(to_bin(Action0)),
    Hash = normalize_hash(Hash0),
    Server = lower_ascii(to_bin(Server0)),
    verify_request(Req, Action, Hash, Server, enforce_hash).

-spec verify_deferred_hash(map(), binary() | list()) ->
    {ok, map()} | {error, term()}.
verify_deferred_hash(Req, Action0) ->
    Action = lower_ascii(to_bin(Action0)),
    Server = public_server_name(Req),
    verify_request(Req, Action, undefined, Server, defer_hash).

verify_request(Req, Action, Hash, Server, HashMode) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Nostr ", Token/binary>> ->
            verify_token(Token, Action, Hash, Server, HashMode);
        _ ->
            {error, missing_authorization}
    end.

verify_token(Token, Action, Hash, Server, HashMode) ->
    case decode_auth_event(Token) of
        {ok, Event0} ->
            case normalize_event(Event0) of
                {ok, Event, Tags} ->
                    Checks = [
                        fun() -> check_kind(Event) end,
                        fun() -> check_pubkey(Event) end,
                        fun() -> check_created_at(Event) end,
                        fun() -> check_expiration(Tags) end,
                        fun() -> check_action(Action, Tags) end,
                        fun() -> check_server(Server, Tags) end,
                        fun() -> check_hash_scope_mode(HashMode, Action, Hash, Tags) end,
                        fun() -> check_signature(Event) end
                    ],
                    case run_checks(Checks) of
                        ok ->
                            {ok, #{
                                pubkey => maps:get(pubkey, Event),
                                event_id => maps:get(id, Event),
                                created_at => maps:get(created_at, Event),
                                expiration => expiration(Tags),
                                action => Action,
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

%% ------------------------------------------------------------------
%% Event parsing
%% ------------------------------------------------------------------

decode_auth_event(Token) when is_binary(Token), byte_size(Token) =< 16384 ->
    try
        Json = decode_base64url(Token),
        case jsx:decode(Json, [return_maps]) of
            M when is_map(M) -> {ok, M};
            _ -> {error, invalid_authorization_event}
        end
    catch
        _:_ -> {error, invalid_authorization_event}
    end;
decode_auth_event(_) ->
    {error, invalid_authorization_event}.

decode_base64url(Token) ->
    %% BUD-11 specifies unpadded base64url. Amethyst 1.16+ deliberately
    %% sends conventional padded Base64 for interoperability. The encoding
    %% is only a transport wrapper; authenticity is provided by the signed
    %% Nostr event, so accept both standard/Base64url and padded/unpadded.
    Std0 = binary:replace(Token, <<"-">>, <<"+">>, [global]),
    Std1 = binary:replace(Std0, <<"_">>, <<"/">>, [global]),
    Std = strip_base64_padding(Std1),
    case binary:match(Std, <<"=">>) of
        nomatch -> ok;
        _ -> erlang:error(invalid_base64_padding)
    end,
    Padded =
        case byte_size(Std) rem 4 of
            0 -> Std;
            2 -> <<Std/binary, "==">>;
            3 -> <<Std/binary, "=">>;
            _ -> erlang:error(invalid_base64)
        end,
    base64:decode(Padded).

strip_base64_padding(Bin) when is_binary(Bin) ->
    case byte_size(Bin) of
        0 ->
            Bin;
        N ->
            case binary:last(Bin) of
                $= -> strip_base64_padding(binary:part(Bin, 0, N - 1));
                _ -> Bin
            end
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

%% ------------------------------------------------------------------
%% BUD-11 validation
%% ------------------------------------------------------------------

check_kind(#{kind := 24242}) -> ok;
check_kind(_) -> {error, invalid_kind}.

check_pubkey(#{pubkey := Pubkey}) ->
    case valid_hex64(lower_ascii(Pubkey)) of
        true -> ok;
        false -> {error, invalid_pubkey}
    end.

check_created_at(#{created_at := CreatedAt}) ->
    Now = erlang:system_time(second),
    Skew = clock_skew_seconds(),
    Delta = CreatedAt - Now,
    case Delta =< Skew of
        true -> ok;
        false -> {error, {authorization_from_future, Delta, Skew}}
    end.

clock_skew_seconds() ->
    case application:get_env(damage, blossom_auth_clock_skew_seconds, 5) of
        N when is_integer(N), N >= 0, N =< 300 -> N;
        _ -> 0
    end.

check_expiration(Tags) ->
    Now = erlang:system_time(second),
    case tag_values(<<"expiration">>, Tags) of
        [Value] ->
            case parse_nonneg_int(Value) of
                {ok, Expiration} when Expiration > Now -> ok;
                {ok, _} -> {error, authorization_expired};
                error -> {error, invalid_expiration}
            end;
        [] -> {error, missing_expiration};
        _ -> {error, duplicate_expiration}
    end.

expiration(Tags) ->
    case tag_values(<<"expiration">>, Tags) of
        [Value] ->
            case parse_nonneg_int(Value) of
                {ok, I} -> I;
                error -> 0
            end;
        _ -> 0
    end.

check_action(Action, Tags) ->
    case tag_values(<<"t">>, Tags) of
        [Action] -> ok;
        [] -> {error, missing_action};
        [_] -> {error, wrong_action};
        _ -> {error, duplicate_action}
    end.

check_server(Server, Tags) ->
    Servers = [lower_ascii(V) || V <- tag_values(<<"server">>, Tags)],
    case Servers of
        [] -> ok;
        _ ->
            case lists:any(fun(V) -> V =:= Server end, Servers) of
                true -> ok;
                false -> {error, wrong_server}
            end
    end.

check_hash_scope_mode(defer_hash, _Action, _Hash, _Tags) ->
    %% Used only as a pre-body admission check for PUT /upload when the
    %% optional X-SHA-256 header is absent. The same token is verified again
    %% against the computed body hash before anything is persisted.
    ok;
check_hash_scope_mode(enforce_hash, Action, Hash, Tags) ->
    check_hash_scope(Action, Hash, Tags).

check_hash_scope(Action, Hash, Tags) ->
    Xs = [lower_ascii(V) || V <- tag_values(<<"x">>, Tags)],
    case requires_hash(Action) of
        true ->
            case Hash of
                undefined -> {error, missing_hash_scope};
                _ ->
                    case lists:any(fun(V) -> V =:= Hash end, Xs) of
                        true -> ok;
                        false -> {error, wrong_hash_scope}
                    end
            end;
        false ->
            %% For GET tokens `x` is optional, but when supplied it still
            %% narrows the token. List tokens have no implied blob hash.
            case {Action, Hash, Xs} of
                {<<"get">>, H, [_ | _]} when is_binary(H) ->
                    case lists:any(fun(V) -> V =:= H end, Xs) of
                        true -> ok;
                        false -> {error, wrong_hash_scope}
                    end;
                _ -> ok
            end
    end.

requires_hash(<<"upload">>) -> true;
requires_hash(<<"delete">>) -> true;
requires_hash(<<"media">>) -> true;
requires_hash(_) -> false.

check_signature(Event) ->
    %% Do not use nostrlib:verify/1 here. Blossom auth uses an arbitrary
    %% Nostr kind (24242), while some nostrlib revisions normalize/interpret
    %% event kinds before verification. Verify the two NIP-01 properties
    %% explicitly instead:
    %%
    %%   1. id == sha256([0,pubkey,created_at,kind,tags,content])
    %%   2. sig is a valid BIP-340 signature of that 32-byte id.
    %%
    %% This also distinguishes a canonical event-id failure from an actual
    %% Schnorr signature failure in the dedicated Blossom log.
    SuppliedId = lower_ascii(maps:get(id, Event)),
    ComputedId = canonical_event_id(Event),
    case SuppliedId =:= ComputedId of
        false ->
            logger:warning(
                "Blossom BUD-11 event id mismatch supplied=~s computed=~s pubkey=~s kind=~p",
                [
                    SuppliedId,
                    ComputedId,
                    maps:get(pubkey, Event),
                    maps:get(kind, Event)
                ]
            ),
            {error, invalid_event_id};
        true ->
            verify_schnorr_signature(Event)
    end.

canonical_event_id(Event) ->
    Serialized = jsx:encode([
        0,
        maps:get(pubkey, Event),
        maps:get(created_at, Event),
        maps:get(kind, Event),
        maps:get(tags, Event, []),
        maps:get(content, Event, <<>>)
    ]),
    lower_hex(crypto:hash(sha256, Serialized)).

verify_schnorr_signature(Event) ->
    IdHex = lower_ascii(maps:get(id, Event)),
    PubkeyHex = lower_ascii(maps:get(pubkey, Event)),
    SigHex = lower_ascii(maps:get(sig, Event)),
    case {
        decode_hex_exact(IdHex, 32),
        decode_hex_exact(PubkeyHex, 32),
        decode_hex_exact(SigHex, 64)
    } of
        {{ok, Id}, {ok, Pubkey}, {ok, Sig}} ->
            try nostrlib_schnorr:verify(Id, Pubkey, Sig) of
                true ->
                    ok;
                false ->
                    logger:warning(
                        "Blossom BUD-11 Schnorr verification failed event_id=~s pubkey=~s",
                        [IdHex, PubkeyHex]
                    ),
                    {error, invalid_signature};
                Other ->
                    logger:warning(
                        "Blossom BUD-11 Schnorr verifier returned ~p event_id=~s pubkey=~s",
                        [Other, IdHex, PubkeyHex]
                    ),
                    {error, invalid_signature}
            catch
                Class:Reason ->
                    logger:warning(
                        "Blossom BUD-11 Schnorr verifier crashed class=~p reason=~p event_id=~s pubkey=~s",
                        [Class, Reason, IdHex, PubkeyHex]
                    ),
                    {error, invalid_signature}
            end;
        _ ->
            logger:warning(
                "Blossom BUD-11 invalid signature field encoding "
                "id_len=~p pubkey_len=~p sig_len=~p event_id=~s pubkey=~s",
                [
                    byte_size(IdHex),
                    byte_size(PubkeyHex),
                    byte_size(SigHex),
                    IdHex,
                    PubkeyHex
                ]
            ),
            {error, invalid_signature_format}
    end.

decode_hex_exact(Hex, Bytes) when is_binary(Hex), byte_size(Hex) =:= Bytes * 2 ->
    case re:run(Hex, <<"\\A[0-9a-fA-F]+\\z">>, [{capture, none}]) of
        match ->
            %% Use OTP's hex decoder directly. This avoids depending on
            %% nostrlib:hex_to_binary/1 being exported by the exact nostrlib
            %% revision bundled with DamageBDD.
            try binary:decode_hex(Hex) of
                Bin when is_binary(Bin), byte_size(Bin) =:= Bytes -> {ok, Bin};
                _ -> error
            catch
                error:badarg -> error
            end;
        nomatch ->
            error
    end;
decode_hex_exact(_, _) ->
    error.

lower_hex(Bin) when is_binary(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Bin]).


tag_values(Name, Tags) ->
    [Value || [TagName, Value | _] <- Tags, TagName =:= Name].

run_checks([]) -> ok;
run_checks([F | Rest]) ->
    case F() of
        ok -> run_checks(Rest);
        {error, _} = Error -> Error
    end.

%% ------------------------------------------------------------------
%% Server/hash helpers
%% ------------------------------------------------------------------

public_server_name(Req) ->
    case application:get_env(damage, blossom_public_base_url) of
        {ok, Base0} ->
            Base = to_bin(Base0),
            case uri_string:parse(binary_to_list(Base)) of
                #{host := Host} ->
                    lower_ascii(to_bin(Host));
                _ ->
                    lower_ascii(cowboy_req:host(Req))
            end;
        undefined ->
            %% Host is preserved by the trusted reverse proxy:
            %% proxy_set_header Host $host;
            lower_ascii(cowboy_req:host(Req))
    end.

normalize_hash(undefined) -> undefined;
normalize_hash(Hash0) ->
    Hash = lower_ascii(to_bin(Hash0)),
    case valid_hex64(Hash) of
        true -> Hash;
        false -> undefined
    end.

valid_hex64(Bin) when is_binary(Bin), byte_size(Bin) =:= 64 ->
    re:run(Bin, <<"\\A[0-9a-f]{64}\\z">>, [{capture, none}]) =:= match;
valid_hex64(_) -> false.

parse_nonneg_int(Bin) when is_binary(Bin) ->
    try binary_to_integer(Bin) of
        I when I >= 0 -> {ok, I};
        _ -> error
    catch
        _:_ -> error
    end;
parse_nonneg_int(_) -> error.

lower_ascii(B) ->
    << <<(lower_char(C))>> || <<C>> <= B >>.
lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
