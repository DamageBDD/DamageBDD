%%%-------------------------------------------------------------------
%%% Blossom BUD-11 authorization verifier.
%%%
%%% Authorization: Nostr <base64url-without-padding JSON event>
%%% kind:24242 with expiration and action (`t`) tags. Optional `server` tags
%%% scope a token to a host; `x` scopes it to one or more blob hashes.
%%%-------------------------------------------------------------------
-module(damage_blossom_auth).

-export([verify/3, verify/4]).

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
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Nostr ", Token/binary>> ->
            verify_token(Token, Action, Hash, Server);
        _ ->
            {error, missing_authorization}
    end.

verify_token(Token, Action, Hash, Server) ->
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
                        fun() -> check_hash_scope(Action, Hash, Tags) end,
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
    case binary:match(Token, <<"=">>) of
        nomatch -> ok;
        _ -> erlang:error(padded_base64url_not_allowed)
    end,
    Std0 = binary:replace(Token, <<"-">>, <<"+">>, [global]),
    Std = binary:replace(Std0, <<"_">>, <<"/">>, [global]),
    Padded =
        case byte_size(Std) rem 4 of
            0 -> Std;
            2 -> <<Std/binary, "==">>;
            3 -> <<Std/binary, "=">>;
            _ -> erlang:error(invalid_base64url)
        end,
    base64:decode(Padded).

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
    case CreatedAt =< Now of
        true -> ok;
        false -> {error, authorization_from_future}
    end.

check_expiration(Tags) ->
    case tag_values(<<"expiration">>, Tags) of
        [Value] ->
            case parse_nonneg_int(Value) of
                {ok, Expiration} when Expiration > erlang:system_time(second) -> ok;
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
    try nostrlib:verify(Event) of
        true -> ok;
        _ -> {error, invalid_signature}
    catch
        _:_ -> {error, invalid_signature}
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
%% Server/hash helpers
%% ------------------------------------------------------------------

public_server_name(Req) ->
    Base =
        case application:get_env(damage, blossom_public_base_url) of
            {ok, V} -> to_bin(V);
            undefined ->
                case application:get_env(damage, nip96_public_base_url) of
                    {ok, V} -> to_bin(V);
                    undefined ->
                        case application:get_env(damage, api_url) of
                            {ok, V} -> to_bin(V);
                            undefined -> <<(cowboy_req:scheme(Req))/binary, "://", (cowboy_req:host(Req))/binary>>
                        end
                end
        end,
    case uri_string:parse(binary_to_list(Base)) of
        #{host := Host} -> lower_ascii(to_bin(Host));
        _ -> lower_ascii(cowboy_req:host(Req))
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
