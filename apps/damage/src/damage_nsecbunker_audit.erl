%%--------------------------------------------------------------------
%% Deterministic redacted audit line builder.
%% No keys, payload bodies, plaintext NIP-46 payloads, or nonce material.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_audit).

-export([record/1, canonical_line/1]).

-spec record(map()) -> map().
record(Fields) ->
    #{
        schema_version => maps:get(schema_version, Fields, 1),
        ts_unix => maps:get(ts_unix, Fields, 0),
        requester_pubkey => maps:get(requester_pubkey, Fields, <<>>),
        request_id => maps:get(request_id, Fields, <<>>),
        method => maps:get(method, Fields, <<>>),
        decision => maps:get(decision, Fields, <<"rejected">>),
        deny_reason => maps:get(deny_reason, Fields, <<>>),
        event_kind => maps:get(event_kind, Fields, null),
        event_id => maps:get(event_id, Fields, <<>>),
        payload_sha256 => maps:get(payload_sha256, Fields, <<>>),
        bunker_pubkey => maps:get(bunker_pubkey, Fields, <<>>),
        contract_sha => maps:get(contract_sha, Fields, <<>>)
    }.

-spec canonical_line(map()) -> binary().
canonical_line(Record0) ->
    R = record(Record0),
    iolist_to_binary([
        <<"{">>,
        kv_int(<<"schema_version">>, maps:get(schema_version, R)), <<",">>,
        kv_int(<<"ts_unix">>, maps:get(ts_unix, R)), <<",">>,
        kv_bin(<<"requester_pubkey">>, maps:get(requester_pubkey, R)), <<",">>,
        kv_bin(<<"request_id">>, maps:get(request_id, R)), <<",">>,
        kv_bin(<<"method">>, maps:get(method, R)), <<",">>,
        kv_bin(<<"decision">>, maps:get(decision, R)), <<",">>,
        kv_bin(<<"deny_reason">>, maps:get(deny_reason, R)), <<",">>,
        kv_json(<<"event_kind">>, maps:get(event_kind, R)), <<",">>,
        kv_bin(<<"event_id">>, maps:get(event_id, R)), <<",">>,
        kv_bin(<<"payload_sha256">>, maps:get(payload_sha256, R)), <<",">>,
        kv_bin(<<"bunker_pubkey">>, maps:get(bunker_pubkey, R)), <<",">>,
        kv_bin(<<"contract_sha">>, maps:get(contract_sha, R)),
        <<"}\n">>
    ]).

kv_int(Key, Value) when is_integer(Value) ->
    [quote(Key), <<":">>, integer_to_binary(Value)].

kv_bin(Key, Value) when is_binary(Value) ->
    [quote(Key), <<":">>, quote(json_escape(Value))];
kv_bin(Key, Value) when is_atom(Value) ->
    kv_bin(Key, atom_to_binary(Value, utf8));
kv_bin(Key, Value) when is_integer(Value) ->
    kv_bin(Key, integer_to_binary(Value));
kv_bin(Key, _Value) ->
    kv_bin(Key, <<>>).

kv_json(Key, null) ->
    [quote(Key), <<":null">>];
kv_json(Key, Value) when is_integer(Value) ->
    kv_int(Key, Value);
kv_json(Key, Value) ->
    kv_bin(Key, Value).

quote(Bin) ->
    [<<"\"">>, Bin, <<"\"">>].

json_escape(Bin) ->
    json_escape(Bin, []).

json_escape(<<>>, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
json_escape(<<$", Rest/binary>>, Acc) ->
    json_escape(Rest, [<<"\\\"">> | Acc]);
json_escape(<<$\\, Rest/binary>>, Acc) ->
    json_escape(Rest, [<<"\\\\">> | Acc]);
json_escape(<<$\n, Rest/binary>>, Acc) ->
    json_escape(Rest, [<<"\\n">> | Acc]);
json_escape(<<$\r, Rest/binary>>, Acc) ->
    json_escape(Rest, [<<"\\r">> | Acc]);
json_escape(<<$\t, Rest/binary>>, Acc) ->
    json_escape(Rest, [<<"\\t">> | Acc]);
json_escape(<<C, Rest/binary>>, Acc) ->
    json_escape(Rest, [<<C>> | Acc]).
