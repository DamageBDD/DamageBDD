%%--------------------------------------------------------------------
%% damage_nip46
%%
%% Minimal NIP-46 payload handling for the Damage bunker.
%% Crypto is injected via callbacks owned by damage_nsecbunker_vault.
%%--------------------------------------------------------------------
-module(damage_nip46).

-export([
    decode_event/2,
    decode_plain/3,
    normalize_request/1,
    encode_response_map/3,
    encode_response_json/3,
    encode_encrypted_response/3,
    format_error/1
]).

-define(NIP46_KIND, 24133).

%% DecryptFun(ClientPubkey, Ciphertext) -> {ok, PlainJson} | {error, Reason}.
decode_event(Event0, DecryptFun) when is_map(Event0), is_function(DecryptFun, 2) ->
    Event = damage_nostr_event:normalize_event(Event0),
    case maps:get(kind, Event, undefined) of
        ?NIP46_KIND ->
            ClientPubkey = maps:get(pubkey, Event, undefined),
            Ciphertext = maps:get(content, Event, <<>>),
            CreatedAt = maps:get(created_at, Event, erlang:system_time(second)),
            case DecryptFun(ClientPubkey, Ciphertext) of
                {ok, PlainJson} -> decode_plain(ClientPubkey, CreatedAt, PlainJson);
                {error, Reason} -> {error, Reason}
            end;
        Other ->
            {error, {unexpected_nip46_event_kind, Other}}
    end.

decode_plain(ClientPubkey, CreatedAt, Plain0) ->
    case decode_json_map(Plain0) of
        {ok, Payload} ->
            request_from_payload(ClientPubkey, CreatedAt, Payload);
        {error, Reason} ->
            {error, Reason}
    end.

normalize_request(Request0) when is_map(Request0) ->
    Method = method_bin(get_either(<<"method">>, method, Request0, <<>>)),
    Event0 = get_either(<<"event">>, event, Request0, undefined),
    Request1 = #{
        requester_pubkey => bin(
            get_either(
                <<"requester_pubkey">>,
                requester_pubkey,
                Request0,
                get_either(<<"client_pubkey">>, client_pubkey, Request0, <<>>)
            )
        ),
        request_id => bin(
            get_either(
                <<"request_id">>,
                request_id,
                Request0,
                get_either(<<"id">>, id, Request0, <<"direct">>)
            )
        ),
        method => Method,
        created_at => int(
            get_either(<<"created_at">>, created_at, Request0, erlang:system_time(second))
        ),
        params => get_either(<<"params">>, params, Request0, [])
    },
    case {Method, Event0} of
        {<<"sign_event">>, undefined} ->
            case event_from_params(maps:get(params, Request1, [])) of
                {ok, Event} -> Request1#{event => Event};
                {error, _} -> Request1
            end;
        {<<"sign_event">>, _} ->
            Request1#{event => damage_nostr_event:normalize_event(Event0)};
        _ ->
            Request1
    end.

encode_response_map(Request, Result, Error) ->
    #{
        id => maps:get(request_id, Request, <<>>),
        result => Result,
        error => Error
    }.

encode_response_json(Request, Result, Error) ->
    jsx:encode(encode_response_map(Request, Result, Error)).

encode_encrypted_response(ResponseMap, ClientPubkey, Vault) ->
    Plain = jsx:encode(ResponseMap),
    damage_nsecbunker_vault:nip44_encrypt(Vault, ClientPubkey, Plain).

format_error(Reason) when is_binary(Reason) -> Reason;
format_error(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
format_error(Reason) -> unicode:characters_to_binary(io_lib:format("~p", [Reason])).

%%--------------------------------------------------------------------
%% Internal decoding
%%--------------------------------------------------------------------

request_from_payload(ClientPubkey, CreatedAt, Payload) ->
    Id = get_key(<<"id">>, Payload, get_key(id, Payload, <<>>)),
    Method = method_bin(get_key(<<"method">>, Payload, get_key(method, Payload, <<>>))),
    Params = get_key(<<"params">>, Payload, get_key(params, Payload, [])),
    Base = #{
        requester_pubkey => bin(ClientPubkey),
        request_id => bin(Id),
        method => Method,
        created_at => CreatedAt,
        params => Params
    },
    case Method of
        <<"sign_event">> ->
            case event_from_params(Params) of
                {ok, Event} -> {ok, Base#{event => Event}};
                {error, Reason} -> {error, Reason}
            end;
        _ ->
            {ok, Base}
    end.

event_from_params([Event]) when is_map(Event) ->
    {ok, damage_nostr_event:normalize_event(Event)};
event_from_params([EventJson]) when is_binary(EventJson) ->
    case decode_json_map(EventJson) of
        {ok, Event} -> {ok, damage_nostr_event:normalize_event(Event)};
        Error -> Error
    end;
event_from_params([EventJson]) when is_list(EventJson) ->
    event_from_params([unicode:characters_to_binary(EventJson)]);
event_from_params(Other) ->
    {error, {missing_or_invalid_sign_event_param, Other}}.

decode_json_map(Map) when is_map(Map) ->
    {ok, Map};
decode_json_map(Bin) when is_binary(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        Map when is_map(Map) -> {ok, Map};
        Other -> {error, {json_not_object, Other}}
    catch
        _:Reason -> {error, {invalid_json, Reason}}
    end;
decode_json_map(List) when is_list(List) ->
    decode_json_map(unicode:characters_to_binary(List));
decode_json_map(Other) ->
    {error, {invalid_json_payload, Other}}.

get_key(Key, Map, Default) when is_map(Map) ->
    maps:get(Key, Map, Default).

get_either(BinKey, AtomKey, Map, Default) when is_map(Map) ->
    maps:get(BinKey, Map, maps:get(AtomKey, Map, Default)).

method_bin(M) when is_binary(M) -> M;
method_bin(M) when is_atom(M) -> atom_to_binary(M, utf8);
method_bin(M) when is_list(M) -> unicode:characters_to_binary(M);
method_bin(M) -> bin(M).

bin(undefined) -> <<>>;
bin(B) when is_binary(B) -> B;
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).

int(I) when is_integer(I) -> I;
int(B) when is_binary(B) ->
    try binary_to_integer(B) of
        I when is_integer(I) ->
            I
    catch
        error:badarg ->
            0
    end;
int(_) ->
    0.
