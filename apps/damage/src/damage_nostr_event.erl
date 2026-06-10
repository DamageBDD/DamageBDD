%%--------------------------------------------------------------------
%% damage_nostr_event
%%
%% Small Nostr event helpers used by damage_nsecbunker. Signing is delegated
%% to the configured crypto backend; this module only normalizes and hashes.
%%--------------------------------------------------------------------
-module(damage_nostr_event).

-export([
    id/1,
    ensure_event_id/1,
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
            ([TagName | _]) -> true;
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
