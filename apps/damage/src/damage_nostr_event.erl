%%--------------------------------------------------------------------
%% damage_nostr_event
%%
%% Shared Nostr event helpers used across DamageBDD applications. Signing stays
%% delegated to callers; this module normalizes, hashes, and verifies events.
%%--------------------------------------------------------------------
-module(damage_nostr_event).

-export([
    id/1,
    ensure_event_id/1,
    verify/1,
    nip46_response_event/2,
    normalize_event/1,
    normalize_tags/1,
    has_tag/2,
    tag_values/2,
    lower_hex/1
]).

-define(NIP46_KIND, 24133).

id(Event0) when is_map(Event0) ->
    Event = normalize_event(Event0),
    Pubkey = maps:get(pubkey, Event),
    CreatedAt = maps:get(created_at, Event),
    Kind = maps:get(kind, Event),
    Tags = maps:get(tags, Event, []),
    Content = maps:get(content, Event, <<>>),
    Json = jsx:encode([0, Pubkey, CreatedAt, Kind, Tags, Content]),
    lower_hex(crypto:hash(sha256, Json)).

ensure_event_id(Event0) ->
    Event = normalize_event(Event0),
    Event#{id => id(Event)}.

%% Verify the two cryptographic invariants common to all Nostr events:
%% the canonical event id and the BIP-340 Schnorr signature over that id.
%% Returns the normalized event so callers do not need to normalize twice.
verify(Event0) when is_map(Event0) ->
    Event = normalize_event(Event0),
    case {
        maps:find(id, Event),
        maps:find(pubkey, Event),
        maps:find(created_at, Event),
        maps:find(kind, Event),
        maps:find(tags, Event),
        maps:find(content, Event),
        maps:find(sig, Event)
    } of
        {
            {ok, EventId}, {ok, Pubkey}, {ok, CreatedAt}, {ok, Kind},
            {ok, Tags}, {ok, Content}, {ok, Sig}
        } when
            is_binary(EventId), is_binary(Pubkey), is_integer(CreatedAt),
            is_integer(Kind), is_list(Tags), is_binary(Content), is_binary(Sig)
        ->
            case {lower_hex_string(EventId, 64), lower_hex_string(Pubkey, 64),
                  lower_hex_string(Sig, 128)} of
                {true, true, true} ->
                    try id(Event) of
                        EventId -> verify_schnorr(Event, EventId, Pubkey, Sig);
                        ExpectedId -> {error, {event_id_mismatch, EventId, ExpectedId}}
                    catch
                        _:_ -> {error, invalid_event}
                    end;
                _ ->
                    {error, invalid_signature_fields}
            end;
        _ ->
            {error, invalid_event}
    end;
verify(_) ->
    {error, invalid_event}.

lower_hex_string(Bin, Size) when is_binary(Bin), byte_size(Bin) =:= Size ->
    lists:all(
        fun(C) ->
            (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f)
        end,
        binary_to_list(Bin)
    );
lower_hex_string(_, _) ->
    false.

verify_schnorr(Event, EventId, Pubkey, Sig) ->
    try
        HashBin = hex_to_binary(EventId),
        PubkeyBin = hex_to_binary(Pubkey),
        SigBin = hex_to_binary(Sig),
        case {byte_size(HashBin), byte_size(PubkeyBin), byte_size(SigBin)} of
            {32, 32, 64} ->
                case nostrlib_schnorr:verify(HashBin, PubkeyBin, SigBin) of
                    true -> {ok, Event};
                    false -> {error, invalid_signature};
                    Other -> {error, {unexpected_signature_result, Other}}
                end;
            _ ->
                {error, invalid_signature_fields}
        end
    catch
        _:_ -> {error, invalid_signature_fields}
    end.

hex_to_binary(Bin) when is_binary(Bin), byte_size(Bin) rem 2 =:= 0 ->
    << <<(hex_byte(Hi, Lo))>> || <<Hi, Lo>> <= Bin >>;
hex_to_binary(_) ->
    error(bad_hex).

hex_byte(Hi, Lo) ->
    (hex_nibble(Hi) bsl 4) bor hex_nibble(Lo).

hex_nibble(C) when C >= $0, C =< $9 -> C - $0;
hex_nibble(C) when C >= $a, C =< $f -> 10 + C - $a;
hex_nibble(C) when C >= $A, C =< $F -> 10 + C - $A;
hex_nibble(_) -> error(bad_hex).

nip46_response_event(ClientPubkey, Ciphertext) ->
    #{
        created_at => erlang:system_time(second),
        kind => ?NIP46_KIND,
        tags => [[<<"p">>, ClientPubkey]],
        content => Ciphertext
    }.

normalize_event(Event0) when is_map(Event0) ->
    Event1 = normalize_keys(Event0),
    Tags = normalize_tags(maps:get(tags, Event1, [])),
    Event1#{
        kind => maps:get(kind, Event1, undefined),
        created_at => maps:get(created_at, Event1, erlang:system_time(second)),
        tags => Tags,
        content => bin(maps:get(content, Event1, <<>>))
    };
normalize_event(Other) ->
    #{
        kind => undefined,
        created_at => erlang:system_time(second),
        tags => [],
        content => bin(Other)
    }.

normalize_keys(Map) ->
    maps:fold(fun(K, V, Acc) -> Acc#{normalize_key(K) => normalize_value(V)} end, #{}, Map).

normalize_value(V) when is_map(V) -> normalize_keys(V);
normalize_value(V) when is_list(V) -> [normalize_value(I) || I <- V];
normalize_value(V) -> V.

normalize_key(<<"id">>) -> id;
normalize_key(<<"pubkey">>) -> pubkey;
normalize_key(<<"created_at">>) -> created_at;
normalize_key(<<"kind">>) -> kind;
normalize_key(<<"tags">>) -> tags;
normalize_key(<<"content">>) -> content;
normalize_key(<<"sig">>) -> sig;
normalize_key(K) -> K.

normalize_tags(Tags) when is_list(Tags) ->
    [normalize_tag(Tag) || Tag <- Tags];
normalize_tags(_) ->
    [].

normalize_tag(Tag) when is_list(Tag) ->
    [bin(Item) || Item <- Tag];
normalize_tag(Tag) when is_tuple(Tag) ->
    normalize_tag(tuple_to_list(Tag));
normalize_tag(Other) ->
    [bin(Other)].

has_tag(Event0, TagName0) ->
    Event = normalize_event(Event0),
    TagName = bin(TagName0),
    lists:any(
        fun
            ([Name | _]) -> Name =:= TagName;
            (_) -> false
        end,
        maps:get(tags, Event, [])
    ).

tag_values(Event0, TagName0) ->
    Event = normalize_event(Event0),
    TagName = bin(TagName0),
    [Value || [Name, Value | _] <- maps:get(tags, Event, []), Name =:= TagName].

lower_hex(Bin) when is_binary(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).

bin(undefined) -> <<>>;
bin(B) when is_binary(B) -> B;
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).
