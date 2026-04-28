-module(damage_nwc_client).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    parse_nwc_uri/1,
    secret_hex_to_keys/1,
    build_request_event/3,
    decrypt_response_event/2,
    publish/2,
    relays_for_conn/1,
    test/0
]).

-import(damage_utils, [to_bin/1]).

-define(NWC_REQ_KIND, 23194).
-define(NWC_RESP_KIND, 23195).

-spec parse_nwc_uri(binary() | list()) -> map().
parse_nwc_uri(Uri0) ->
    Uri = to_bin(Uri0),
    <<"nostr+walletconnect://", Rest/binary>> = Uri,
    [WalletPubKeyBin, QueryBin] = binary:split(Rest, <<"?">>),
    Params = damage_nostr:parse_kv_query(QueryBin),
    Relays0 = maps:get(<<"relay">>, Params, []),
    Relays =
        case Relays0 of
            R when is_binary(R) -> [R];
            Rs when is_list(Rs) -> lists:reverse(Rs);
            _ -> []
        end,
    #{
        wallet_pubkey => WalletPubKeyBin,
        relay =>
            case Relays of
                [R0 | _] -> R0;
                [] -> undefined
            end,
        relays => damage_nostr:normalize_relays(Relays),
        secret_hex => maps:get(<<"secret">>, Params),
        raw_uri => Uri
    }.

-spec secret_hex_to_keys(binary() | list()) -> map().
secret_hex_to_keys(SecretHex0) ->
    SecretHex = to_bin(SecretHex0),
    SecretBin = binary:decode_hex(SecretHex),
    {ok, ClientPubBin} = nostrlib_schnorr:new_publickey(SecretBin),
    #{
        secret_hex => SecretHex,
        private_key => SecretBin,
        public_key => lower_hex(ClientPubBin)
    }.

-spec build_request_event(map(), binary() | list(), map()) ->
    {ok, map(), binary()} | {error, term()}.
build_request_event(Conn, Method0, Params) ->
    Method = to_bin(Method0),
    WalletPubKey = maps:get(wallet_pubkey, Conn),
    SecretHex = maps:get(secret_hex, Conn),
    #{private_key := PrivKey, public_key := ClientPubHex} = secret_hex_to_keys(SecretHex),

    Payload = jsx:encode(#{
        method => Method,
        params => Params
    }),

    ?LOG_DEBUG("wallet_pubkey=~p size=~p", [WalletPubKey, byte_size(to_bin(WalletPubKey))]),
    ?LOG_DEBUG("privkey_size=~p", [byte_size(PrivKey)]),

    case damage_nostr:nip04_encrypt(Payload, PrivKey, WalletPubKey) of
        {ok, CipherB64, IvB64} ->
            EncContent = <<CipherB64/binary, "?iv=", IvB64/binary>>,
            TS = erlang:system_time(seconds),
            Event0 = damage_nostr:construct_event(
                ClientPubHex,
                ?NWC_REQ_KIND,
                EncContent,
                TS,
                [[<<"p">>, to_bin(WalletPubKey)]]
            ),
            Event = damage_nostr:finalize_event(Event0, PrivKey),
            {ok, Event, maps:get(<<"id">>, Event)};
        Error ->
            Error
    end.

-spec decrypt_response_event(map(), map()) -> {ok, map()} | {error, term()}.
decrypt_response_event(Conn, Event) ->
    SecretHex = maps:get(secret_hex, Conn),
    WalletPubKey = maps:get(wallet_pubkey, Conn),
    #{private_key := PrivKey} = secret_hex_to_keys(SecretHex),
    EncContent = maps:get(<<"content">>, Event),
    case damage_nostr:nip04_decrypt_content(EncContent, PrivKey, WalletPubKey) of
        {ok, Plain} ->
            try jsx:decode(Plain, [return_maps]) of
                M when is_map(M) -> {ok, M}
            catch
                C:R -> {error, {C, R}}
            end;
        Error ->
            Error
    end.

lower_hex(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).
publish(Event, Relays0) when is_map(Event), is_list(Relays0) ->
    Relays = damage_nostr:normalize_relays(Relays0),
    Sorted = damage_nostr:score_relays(Relays),
    EventId = maps:get(<<"id">>, Event, undefined),

    ?LOG_INFO("Publishing NWC event id=~p relays=~p", [EventId, Sorted]),

    case safe_ensure_pool(Sorted) of
        ok ->
            case safe_publish_sync(Event, Sorted, 35000) of
                ok ->
                    ok;
                {error, FirstReason} ->
                    ?LOG_WARNING(
                        "NWC publish failed id=~p reason=~p; resetting pool and retrying",
                        [EventId, FirstReason]
                    ),
                    _ = catch nostr_pool:reset(Sorted),
                    timer:sleep(300),
                    retry_publish(Event, Sorted, FirstReason)
            end;
        Error ->
            Error
    end;
publish(BadEvent, BadRelays) ->
    ?LOG_ERROR("Invalid publish args event_shape=~p relays_shape=~p", [
        term_shape(BadEvent),
        term_shape(BadRelays)
    ]),
    {error, {invalid_publish_args, term_shape(BadEvent), term_shape(BadRelays)}}.

retry_publish(Event, Relays, FirstReason) ->
    case safe_publish_sync(Event, Relays, 15000) of
        ok ->
            ok;
        {error, Reason2} ->
            {error, {publish_failed_after_reset, FirstReason, Reason2}}
    end.

safe_ensure_pool(Relays) ->
    try nostr_pool:ensure_started(Relays) of
        ok -> ok;
        Other -> {error, {ensure_started_failed, Other}}
    catch
        Class:Reason:Stack ->
            {error, {ensure_started_crashed, Class, Reason, stack_top(Stack)}}
    end.

safe_publish_sync(Event, Relays, TimeoutMs) ->
    try nostr_pool:publish_sync(Event, Relays, TimeoutMs) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_publish_result, Other}}
    catch
        exit:{timeout, _} ->
            {error,
                {publish_timeout, maps:get(<<"id">>, Event, undefined), TimeoutMs,
                    relay_urls(Relays)}};
        exit:Reason ->
            {error, {publish_exit, Reason}};
        Class:Reason:Stack ->
            {error, {publish_crash, Class, Reason, stack_top(Stack)}}
    end.

relay_urls(Relays) ->
    [maps:get(url, R, R) || R <- Relays].

stack_top([{M, F, A, _} | _]) -> {M, F, A};
stack_top(_) -> undefined.

term_shape(Term) when is_map(Term) ->
    #{type => map, size => map_size(Term), keys => maps:keys(Term)};
term_shape(Term) when is_list(Term) ->
    #{type => list, length => length(Term)};
term_shape(Term) when is_tuple(Term) ->
    #{type => tuple, size => tuple_size(Term), tag => element(1, Term)};
term_shape(Term) when is_binary(Term) ->
    #{type => binary, bytes => byte_size(Term)};
term_shape(Term) ->
    Term.

relays_for_conn(#{relays := Relays}) when is_list(Relays), Relays =/= [] ->
    damage_nostr:normalize_relays(Relays);
relays_for_conn(#{relay := Relays}) when is_list(Relays), Relays =/= [] ->
    damage_nostr:normalize_relays(Relays);
relays_for_conn(Conn) ->
    Relay0 = maps:get(relay, Conn, undefined),
    case Relay0 of
        undefined -> damage_nostr:configured_relays();
        <<>> -> damage_nostr:configured_relays();
        Relay -> damage_nostr:normalize_relays([Relay | damage_nostr:configured_relays()])
    end.
test() ->
    Event =
        #{
            <<"content">> =>
                <<"Y6XCfBn6q+kQmb151TNk9GFfLO6d+wkSPXVlV8uJX5pKJ8Q1sohw3UQ4pqqqTWul3n4RRC0i962SEtNN1t3brnAeT13cSVT7BsL7/eJdsjdSc1tMFkYTywsD8iENuT1riu3CIbPyZDRX2k2e5JTHnAVQXwsUwWDYvYrJI+d/2Hq3s3ykoeHZG9vKmuB/VBBnRzIL2OMa89PRiC0Z9rwamnA+2lXK6GdhI2aqOIzdPncW3CdvycEgbM8ezqw19FmNtxRMJXEs8AxALHRLDnrMseeljbe3VjzU+ES4db6Y6C26LHF0cRRun9kZ0iKS1Hvixbr85rI2kFnonqOQzA2vd/RO0wzux4W5JG4yYRQsHT2QaPFQEvcbm3SXzs+NHc8+W6m1xGDz6+pVlt8j0jE8QlFkFRdC3Q1TrpLDBn9LDTFJJLPBeK8pgNXTO5mfSu2wCGqEhQqMc6D4+SmOqNIDEBxu8RzwSnpnx6Y17x6rblSYXu/Cs74VJEexwfgUUnIdDUDu0Cqf8zJJROF9bXbaX9tiGeIZf2N0eOO+FLQL6PhVLkO6u4R66Psd4N9mt9pV?iv=L+w5rQuK/IxqOEQnCbl9eQ==">>,
            <<"created_at">> => 1776672187,
            <<"id">> =>
                <<"3776602a2bacf3125ae6205224bb7a2e0ac53c9e8a5e71c8934349520e51cc91">>,
            <<"kind">> => 23194,
            <<"pubkey">> =>
                <<"6ebd6520f0d9afb9ac5f6ef1a98bea74ab3f257198de2690d68974b37f2e618b">>,
            <<"sig">> =>
                <<"a2e7e2c215f63b39a1779ac7381fe284dab14a2efccf14b1ed78a1a046756dbcf0a1dfa258e342996224e70139cd4629ca7f1444f3a4d7fcc039c7c2563264f8">>,
            <<"tags">> =>
                [
                    [
                        <<"p">>,
                        <<"ae6ce958e804be86b145e6a73cdcda8a42bb5e5427d5049fe6259b6dd0f02c7d">>
                    ]
                ]
        },
    publish(Event, damage_nostr:configured_relays()).
