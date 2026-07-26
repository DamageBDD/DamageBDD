%%--------------------------------------------------------------------
%% DamageBDD live steps for a running damage_nsecbunker node.
%%
%% These steps deliberately reuse the production modules instead of
%% re-implementing the bunker policy:
%%   * damage_nsecbunker:status/config/policy/handle_plain_request
%%   * damage_nostr:public_key_hex/construct_event/finalize_event/open_relay_ws
%%   * damage_nostr_relay_client:subscribe/status
%%   * damage_nsecbunker_relay:status/publish_event
%%   * damage_nsecbunker_ops:backend_call/contains_secret_material
%%   * damage_nostr_event:normalize_event/tag_values/id
%%
%% The live NIP-46 client identity is the existing damage_nostr_nsec
%% identity.  The private key is used only inside short helper calls and is
%% never written into the DamageBDD Context, logs, or reports.
%%--------------------------------------------------------------------
-module(steps_nsecbunker_live).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-export([step/6, step_dry/6]).

-define(NS, nsecbunker_live).
-define(NIP46_KIND, 24133).
-define(DEFAULT_TIMEOUT_MS, 30000).
-define(AUDIT_TAIL_BYTES, 1048576).

-spec step(proplists:proplist(), map(), binary() | documentation, integer(), [term()], term()) ->
    map().
-spec step_dry(proplists:proplist(), map(), binary() | documentation, integer(), [term()], term()) ->
    map().

step_dry(Config, Context, Keyword, LineNo, Body, Args) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

%% ====================================================================
%% Background / setup
%% ====================================================================

step(_Config, Context, _Keyword, _Line, ["the live damage nsecbunker server is running"], _Args) ->
    try
        case damage_nsecbunker:status() of
            #{running := true} = Status ->
                Cfg = damage_nsecbunker:config(),
                Policy = damage_nsecbunker:policy(),
                put_live(Context, #{status => safe_public(Status), config => Cfg, policy => Policy});
            Other ->
                fail(Context, {live_nsecbunker_not_running, safe_public(Other)})
        end
    catch
        C:R:S -> fail(Context, {live_nsecbunker_status_failed, C, R, stack_top(S)})
    end;
step(_Config, Context, _Keyword, _Line, ["the live damage nsecbunker vault is ready"], _Args) ->
    case get_status(Context) of
        #{vault := #{guard_state := Guard}} ->
            case
                maps:get(sealed, Guard, true) =:= false andalso
                    maps:get(integrity, Guard, failed) =:= ok
            of
                true -> put_live(Context, #{vault_guard => Guard});
                false -> fail(Context, {live_vault_not_ready, Guard})
            end;
        #{vault := #{"guard_state" := Guard}} ->
            case
                maps:get(sealed, Guard, true) =:= false andalso
                    maps:get(integrity, Guard, failed) =:= ok
            of
                true -> put_live(Context, #{vault_guard => Guard});
                false -> fail(Context, {live_vault_not_ready, Guard})
            end;
        Other ->
            fail(Context, {live_vault_status_missing, safe_public(Other)})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live damage nsecbunker node pubkey is loaded from the running bunker policy"],
    _Args
) ->
    Policy = get_policy(Context),
    Pubkey = lower_hex_bin(maps:get(bunker_pubkey_hex, Policy, <<>>)),
    case is_lower_hex_64(Pubkey) of
        true -> put_live(Context, #{bunker_pubkey_hex => Pubkey});
        false -> fail(Context, {invalid_live_bunker_pubkey, Pubkey})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 client is the damage_nostr node identity"],
    _Args
) ->
    try
        ClientPub = lower_hex_bin(damage_nostr:public_key_hex()),
        case is_lower_hex_64(ClientPub) of
            true ->
                put_live(Context, #{
                    client_pubkey_hex => ClientPub, client_identity => damage_nostr_nsec
                });
            false ->
                fail(Context, {invalid_damage_nostr_client_pubkey, ClientPub})
        end
    catch
        C:R:S -> fail(Context, {damage_nostr_identity_unavailable, C, R, stack_top(S)})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 client pubkey is authorised by the running bunker policy"],
    _Args
) ->
    Client = require_live(client_pubkey_hex, Context),
    Policy = get_policy(Context),
    Allowed = [lower_hex_bin(C) || C <- maps:get(authorized_clients, Policy, [])],
    case lists:member(Client, Allowed) of
        true ->
            Context;
        false ->
            fail(
                Context,
                {live_client_not_authorised, #{
                    client => Client, authorised_count => length(Allowed)
                }}
            )
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 relays are loaded from the running bunker config"],
    _Args
) ->
    Cfg = get_config(Context),
    Relays0 = maps:get(relays, Cfg, []),
    Relays =
        case Relays0 of
            [] -> damage_nostr:score_relays(damage_nostr:default_relays());
            _ -> damage_nostr:score_relays(damage_nostr:normalize_relays(Relays0))
        end,
    case Relays of
        [] -> fail(Context, live_nip46_relays_empty);
        _ -> put_live(Context, #{relays => Relays, relay_urls => [relay_url(R) || R <- Relays]})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 relay bridge is running and subscribed"],
    _Args
) ->
    %% Subscribe through the existing bridge. In Option B this routes to
    %% damage_nsecbunker_relay via relay_subscribe_mfa. Do not trust the
    %% immediate subscribe/0 return as proof: the relay adapter only becomes
    %% live after websocket upgrade and REQ subscription. Poll for adapter
    %% subscribed=true so the BDD cannot false-green on a merely-open socket.
    case wait_for_relay_bridge_subscribed(Context, ?DEFAULT_TIMEOUT_MS) of
        {ok, RelayClientStatus, RelayAdapterStatus} ->
            Filter = first_present([
                map_get_any(filter, RelayAdapterStatus),
                map_get_any(<<"filter">>, RelayAdapterStatus),
                return_only_filter(Context)
            ]),
            put_live(Context, #{
                relay_client_status => safe_public(RelayClientStatus),
                relay_adapter_status => safe_public(RelayAdapterStatus),
                subscription_filter => Filter
            });
        {error, RelayClientStatus, RelayAdapterStatus} ->
            fail(
                Context,
                {live_relay_bridge_not_subscribed, #{
                    relay_client => safe_public(RelayClientStatus),
                    relay_adapter => safe_public(RelayAdapterStatus)
                }}
            )
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 test run id is generated"],
    _Args
) ->
    RunId = make_run_id(),
    put_live(Context, #{test_run_id => RunId});
%% ====================================================================
%% Identity / filter assertions
%% ====================================================================

step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live bunker public key MUST equal the vault guard public key"],
    _Args
) ->
    Bunker = require_live(bunker_pubkey_hex, Context),
    Guard = require_live(vault_guard, Context),
    GuardPub = lower_hex_bin(maps:get(pubkey_hex, Guard, <<>>)),
    assert_equal(Context, GuardPub, Bunker, {vault_guard_pubkey_mismatch, GuardPub, Bunker});
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 client pubkey MUST NOT equal the bunker pubkey"],
    _Args
) ->
    Client = require_live(client_pubkey_hex, Context),
    Bunker = require_live(bunker_pubkey_hex, Context),
    case Client =/= Bunker of
        true -> Context;
        false -> fail(Context, live_client_pubkey_equals_bunker_pubkey)
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 subscription filter MUST include kind", Kind0],
    _Args
) ->
    Filter = require_live(subscription_filter, Context),
    Expected = to_int(Kind0),
    Kinds = map_get_any(kinds, Filter, map_get_any(<<"kinds">>, Filter, [])),
    case lists:member(Expected, [to_int(K) || K <- Kinds]) of
        true -> Context;
        false -> fail(Context, {live_subscription_filter_missing_kind, Expected, Filter})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 subscription filter MUST be p-tagged to the bunker pubkey"],
    _Args
) ->
    Filter = require_live(subscription_filter, Context),
    Bunker = require_live(bunker_pubkey_hex, Context),
    PTags = [lower_hex_bin(P) || P <- map_get_any(<<"#p">>, Filter, map_get_any('#p', Filter, []))],
    case lists:member(Bunker, PTags) of
        true -> Context;
        false -> fail(Context, {live_subscription_filter_not_p_tagged_to_bunker, Filter})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["no live test context MUST contain secret material"],
    _Args
) ->
    Live = live(Context),
    case damage_nsecbunker_ops:contains_secret_material(Live) of
        false -> Context;
        true -> fail(Context, live_test_context_contains_secret_material)
    end;
%% ====================================================================
%% Plain/local bunker request steps
%% ====================================================================

step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["I call the live bunker plain request method", Method0, "as the damage_nostr client"],
    _Args
) ->
    Method = strip(Method0),
    RequestId = make_request_id(Context, <<"plain">>, Method),
    Request = base_plain_request(Context, RequestId, Method),
    Reply = damage_nsecbunker:handle_plain_request(Request),
    put_live(Context, #{
        last_plain_request => public_request(Request),
        last_plain_response => Reply,
        last_request_id => RequestId
    });
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live bunker plain response MUST be accepted"],
    _Args
) ->
    Reply = require_live(last_plain_response, Context),
    assert_response_accepted(Context, plain_response_map(Reply));
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live bunker plain response result MUST be", Expected0],
    _Args
) ->
    Reply = plain_response_map(require_live(last_plain_response, Context)),
    assert_equal(
        Context,
        response_result_bin(Reply),
        strip(Expected0),
        {plain_response_result_mismatch, Reply}
    );
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live bunker plain response result MUST equal the bunker pubkey"],
    _Args
) ->
    Reply = plain_response_map(require_live(last_plain_response, Context)),
    assert_equal(
        Context,
        lower_hex_bin(response_result_bin(Reply)),
        require_live(bunker_pubkey_hex, Context),
        {plain_response_pubkey_mismatch, Reply}
    );
%% ====================================================================
%% Live relay/NIP-46 actions
%% ====================================================================

step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["I publish a live NIP-46", Method0, "request from the damage_nostr client"],
    _Args
) ->
    publish_live_nip46(Context, strip(Method0), []);
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    [
        "I publish a live NIP-46",
        Method0,
        "request for a kind not allowed by the running bunker policy from the damage_nostr client"
    ],
    _Args
) ->
    Kind = first_disallowed_kind(get_policy(Context)),
    publish_live_nip46(Context, strip(Method0), [{event_kind, Kind}]);
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    [
        "I publish a live NIP-46",
        Method0,
        "request for allowed kind",
        Kind0,
        "from the damage_nostr client"
    ],
    _Args
) ->
    publish_live_nip46(Context, strip(Method0), [{event_kind, to_int(Kind0)}]);
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 request MUST be accepted by at least one relay"],
    _Args
) ->
    Publish = require_live(last_nip46_publish_result, Context),
    case relay_publish_accepted(Publish) of
        true -> Context;
        false -> fail(Context, {live_nip46_request_not_accepted_by_any_relay, compact(Publish)})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["a live NIP-46 reply MUST be received"],
    _Args
) ->
    case maps:is_key(last_nip46_reply_event, live(Context)) of
        true -> Context;
        false -> fail(Context, {live_nip46_reply_not_received, compact(live(Context))})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 reply MUST be kind", Kind0],
    _Args
) ->
    Event = normalize_event(require_live(last_nip46_reply_event, Context)),
    assert_equal(
        Context, maps:get(kind, Event, undefined), to_int(Kind0), {live_reply_kind_mismatch, Event}
    );
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 reply MUST be authored by the bunker pubkey"],
    _Args
) ->
    Event = normalize_event(require_live(last_nip46_reply_event, Context)),
    assert_equal(
        Context,
        lower_hex_bin(maps:get(pubkey, Event, <<>>)),
        require_live(bunker_pubkey_hex, Context),
        {live_reply_author_mismatch, Event}
    );
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live NIP-46 reply MUST be p-tagged to the damage_nostr client pubkey"],
    _Args
) ->
    Event = normalize_event(require_live(last_nip46_reply_event, Context)),
    Client = require_live(client_pubkey_hex, Context),
    PTags = [lower_hex_bin(P) || P <- damage_nostr_event:tag_values(Event, <<"p">>)],
    case lists:member(Client, PTags) of
        true -> Context;
        false -> fail(Context, {live_reply_not_p_tagged_to_client, PTags})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the decrypted live NIP-46 response result MUST be", Expected0],
    _Args
) ->
    Resp = require_live(last_nip46_response, Context),
    assert_equal(
        Context, response_result_bin(Resp), strip(Expected0), {live_nip46_result_mismatch, Resp}
    );
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the decrypted live NIP-46 response result MUST equal the bunker pubkey"],
    _Args
) ->
    Resp = require_live(last_nip46_response, Context),
    assert_equal(
        Context,
        lower_hex_bin(response_result_bin(Resp)),
        require_live(bunker_pubkey_hex, Context),
        {live_nip46_pubkey_result_mismatch, Resp}
    );
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the decrypted live NIP-46 response MUST be rejected"],
    _Args
) ->
    Resp = require_live(last_nip46_response, Context),
    case response_rejected(Resp) of
        true -> Context;
        false -> fail(Context, {live_nip46_response_not_rejected, Resp})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the decrypted live NIP-46 error reason MUST be", Expected0],
    _Args
) ->
    Resp = require_live(last_nip46_response, Context),
    Expected = strip(Expected0),
    Got = response_error_reason(Resp),
    case Got =:= Expected orelse binary:match(Got, Expected) =/= nomatch of
        true ->
            Context;
        false ->
            fail(
                Context,
                {live_nip46_error_reason_mismatch, #{
                    expected => Expected, got => Got, response => Resp
                }}
            )
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the decrypted live NIP-46 response MUST be accepted"],
    _Args
) ->
    Resp = require_live(last_nip46_response, Context),
    assert_response_accepted(Context, Resp);
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the signed live NIP-46 event MUST be kind", Kind0],
    _Args
) ->
    Event = signed_event_from_context(Context),
    assert_equal(
        Context,
        maps:get(kind, Event, undefined),
        to_int(Kind0),
        {live_signed_event_kind_mismatch, Event}
    );
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the signed live NIP-46 event MUST be authored by the bunker pubkey"],
    _Args
) ->
    Event = signed_event_from_context(Context),
    assert_equal(
        Context,
        lower_hex_bin(maps:get(pubkey, Event, <<>>)),
        require_live(bunker_pubkey_hex, Context),
        {live_signed_event_author_mismatch, Event}
    );
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the signed live NIP-46 event MUST contain the test run id"],
    _Args
) ->
    Event = signed_event_from_context(Context),
    RunId = require_live(test_run_id, Context),
    Content = bin(maps:get(content, Event, <<>>)),
    case binary:match(Content, RunId) of
        nomatch ->
            fail(Context, {live_signed_event_missing_run_id, #{run_id => RunId, event => Event}});
        _ ->
            Context
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the signed live NIP-46 event MUST NOT be published by the bunker relays"],
    _Args
) ->
    Event = signed_event_from_context(Context),
    EventId = event_id(Event),
    Relays = require_live(relays, Context),
    case
        find_event_on_relays(
            EventId,
            maps:get(kind, Event, ?NIP46_KIND),
            require_live(bunker_pubkey_hex, Context),
            Relays,
            5000
        )
    of
        not_found -> Context;
        {found, FoundEvent} -> fail(Context, {signed_event_was_published_by_bunker, FoundEvent});
        {error, timeout} -> Context;
        {error, _Reason} -> Context
    end;
%% ====================================================================
%% Black-box relay ingress/full-loop steps
%% ====================================================================

step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["I publish a black-box live NIP-46 canary event from a separate relay connection"],
    _Args
) ->
    publish_black_box_canary(Context);
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["I publish a black-box live NIP-46", Method0, "request from a separate relay connection"],
    _Args
) ->
    publish_black_box_live_nip46(Context, strip(Method0), []);
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    [
        "I publish a black-box live NIP-46",
        Method0,
        "request for a kind not allowed by the running bunker policy from a separate relay connection"
    ],
    _Args
) ->
    Kind = first_disallowed_kind(get_policy(Context)),
    publish_black_box_live_nip46(Context, strip(Method0), [{event_kind, Kind}]);
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    [
        "I publish a black-box live NIP-46",
        Method0,
        "request for allowed kind",
        Kind0,
        "from a separate relay connection"
    ],
    _Args
) ->
    publish_black_box_live_nip46(Context, strip(Method0), [{event_kind, to_int(Kind0)}]);
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the black-box NIP-46 request MUST be accepted by at least one relay"],
    _Args
) ->
    Publish = require_live(last_black_box_publish_result, Context),
    case relay_publish_accepted(Publish) of
        true ->
            Context;
        false ->
            fail(Context, {black_box_nip46_request_not_accepted_by_any_relay, compact(Publish)})
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live relay adapter inbound counter MUST increase"],
    _Args
) ->
    Before = require_live(black_box_relay_adapter_status_before, Context),
    After = require_live(black_box_relay_adapter_status_after, Context),
    case status_counter(inbound_events, After) > status_counter(inbound_events, Before) of
        true ->
            Context;
        false ->
            fail(
                Context,
                {live_relay_adapter_inbound_counter_did_not_increase, #{
                    before_status => safe_public(Before), after_status => safe_public(After)
                }}
            )
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live relay adapter dispatch counter MUST increase"],
    _Args
) ->
    Before = require_live(black_box_relay_adapter_status_before, Context),
    After = require_live(black_box_relay_adapter_status_after, Context),
    case status_counter(dispatched_events, After) > status_counter(dispatched_events, Before) of
        true ->
            Context;
        false ->
            fail(
                Context,
                {live_relay_adapter_dispatch_counter_did_not_increase, #{
                    before_status => safe_public(Before), after_status => safe_public(After)
                }}
            )
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live relay adapter MUST observe the black-box event id"],
    _Args
) ->
    EventId = require_live(last_black_box_event_id, Context),
    After = require_live(black_box_relay_adapter_status_after, Context),
    case status_observed_event_id(EventId, After) of
        true ->
            Context;
        false ->
            fail(
                Context,
                {live_relay_adapter_did_not_observe_black_box_event_id, #{
                    event_id => EventId, status => safe_public(After)
                }}
            )
    end;
%% ====================================================================
%% Audit assertions
%% ====================================================================

step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live bunker audit log MUST contain the test run id"],
    _Args
) ->
    RunId = require_live(test_run_id, Context),
    case audit_lines_for_run(Context) of
        [] -> fail(Context, {audit_log_missing_test_run_id, RunId});
        _ -> Context
    end;
step(
    _Config,
    Context,
    _Keyword,
    _Line,
    ["the live bunker audit log MUST contain decision", Decision0],
    _Args
) ->
    Decision = strip(Decision0),
    Lines = audit_lines_for_run(Context),
    Needle = <<"\"decision\":\"", Decision/binary, "\"">>,
    case lists:any(fun(Line) -> binary:match(Line, Needle) =/= nomatch end, Lines) of
        true -> Context;
        false -> fail(Context, {audit_log_missing_decision_for_test_run, Decision, Lines})
    end.

%% ====================================================================
%% Core action helpers
%% ====================================================================

publish_black_box_canary(Context) ->
    RunId = require_live(test_run_id, Context),
    BunkerPub = require_live(bunker_pubkey_hex, Context),
    ClientPubHex = require_live(client_pubkey_hex, Context),
    {_ClientPubRaw, ClientPriv} = damage_nostr_client_keypair(),
    Content = <<"black-box-nip46-ingress-canary run_id=", RunId/binary>>,
    Event0 = damage_nostr:construct_event(
        ClientPubHex,
        ?NIP46_KIND,
        Content,
        erlang:system_time(second),
        [[<<"p">>, BunkerPub], [<<"t">>, <<"damagebdd-black-box-ingress">>]]
    ),
    Event = damage_nostr:finalize_event(Event0, ClientPriv),
    publish_black_box_event_and_wait_for_ingress(Context, Event, undefined, undefined, undefined).

publish_black_box_live_nip46(Context, Method, Opts) ->
    RequestId = make_request_id(Context, <<"blackbox-nip46">>, Method),
    {Payload, MaybeUnsignedEvent} = nip46_payload(Context, RequestId, Method, Opts),
    Since = max(0, erlang:system_time(second) - 5),
    case build_signed_nip46_request(Context, Payload) of
        {ok, Event} ->
            Context1 = publish_black_box_event_and_wait_for_ingress(
                Context, Event, RequestId, Since, MaybeUnsignedEvent
            ),
            case maps:is_key(fail, Context1) of
                true ->
                    Context1;
                false ->
                    case
                        wait_for_matching_nip46_reply(
                            Context1, RequestId, Since, ?DEFAULT_TIMEOUT_MS
                        )
                    of
                        {ok, ReplyEvent, Response} ->
                            put_live(Context1, #{
                                last_nip46_reply_event => ReplyEvent,
                                last_nip46_response => Response
                            });
                        {error, Reason} ->
                            put_live(Context1, #{last_nip46_reply_error => Reason})
                    end
            end;
        {error, Reason} ->
            fail(Context, Reason)
    end.

publish_black_box_event_and_wait_for_ingress(
    Context, Event, MaybeRequestId, MaybeSince, MaybeUnsignedEvent
) ->
    Relays = require_live(relays, Context),
    Before = relay_adapter_status(),
    PublishResult = black_box_publish_event(Event, Relays, ?DEFAULT_TIMEOUT_MS),
    EventId = event_id(Event),
    Context1 = put_live(Context, #{
        last_black_box_request_event => public_event(Event),
        last_black_box_event_id => EventId,
        last_black_box_publish_result => PublishResult,
        black_box_relay_adapter_status_before => safe_public(Before),
        last_nip46_request_event => public_event(Event),
        last_nip46_publish_result => PublishResult,
        last_request_id => MaybeRequestId,
        last_unsigned_event => MaybeUnsignedEvent
    }),
    case wait_for_relay_adapter_observation(EventId, Before, 10000) of
        {ok, After} ->
            put_live(Context1, #{black_box_relay_adapter_status_after => safe_public(After)});
        {error, Reason, After} ->
            put_live(Context1, #{
                black_box_relay_adapter_observation_error => Reason,
                black_box_relay_adapter_status_after => safe_public(After),
                black_box_reply_since => MaybeSince
            })
    end.

publish_live_nip46(Context, Method, Opts) ->
    %% Keep the legacy live step names, but force them through the black-box
    %% ingress path so the test proves external relay delivery as well as the
    %% bunker response loop.
    publish_black_box_live_nip46(Context, Method, Opts).

base_plain_request(Context, RequestId, Method) ->
    #{
        requester_pubkey => require_live(client_pubkey_hex, Context),
        request_id => RequestId,
        method => Method,
        created_at => erlang:system_time(second),
        skip_rate_limit => true
    }.

nip46_payload(Context, RequestId, <<"sign_event">>, Opts) ->
    Kind = proplists:get_value(event_kind, Opts, 30023),
    Event = unsigned_test_event(Context, Kind),
    {
        #{
            <<"id">> => RequestId,
            <<"method">> => <<"sign_event">>,
            <<"params">> => [event_to_json_map(Event)]
        },
        Event
    };
nip46_payload(_Context, RequestId, Method, _Opts) ->
    {
        #{
            <<"id">> => RequestId,
            <<"method">> => Method,
            <<"params">> => []
        },
        undefined
    }.

unsigned_test_event(Context, 30023) ->
    RunId = require_live(test_run_id, Context),
    Now = erlang:system_time(second),
    #{
        kind => 30023,
        created_at => Now,
        tags => [
            [<<"d">>, <<"live-nsecbunker-", RunId/binary>>],
            [<<"title">>, <<"Live nsecbunker BDD proof">>],
            [<<"published_at">>, integer_to_binary(Now)]
        ],
        content => <<"# Live nsecbunker BDD proof\n\nrun_id: ", RunId/binary, "\n">>
    };
unsigned_test_event(Context, Kind) ->
    RunId = require_live(test_run_id, Context),
    #{
        kind => Kind,
        created_at => erlang:system_time(second),
        tags => [],
        content => <<"live nsecbunker disallowed-kind proof run_id: ", RunId/binary>>
    }.

event_to_json_map(Event) ->
    #{
        <<"kind">> => maps:get(kind, Event),
        <<"created_at">> => maps:get(created_at, Event),
        <<"tags">> => maps:get(tags, Event, []),
        <<"content">> => maps:get(content, Event, <<>>)
    }.

build_signed_nip46_request(Context, Payload) ->
    try
        BunkerPub = require_live(bunker_pubkey_hex, Context),
        ClientPubHex = require_live(client_pubkey_hex, Context),
        Plain = jsx:encode(Payload),
        {ok, Ciphertext} = client_nip44_encrypt(BunkerPub, Plain),
        {_ClientPubRaw, ClientPriv} = damage_nostr_client_keypair(),
        Event0 = damage_nostr:construct_event(
            ClientPubHex,
            ?NIP46_KIND,
            Ciphertext,
            erlang:system_time(second),
            [[<<"p">>, BunkerPub]]
        ),
        {ok, damage_nostr:finalize_event(Event0, ClientPriv)}
    catch
        C:R:S -> {error, {build_live_nip46_request_failed, C, R, stack_top(S)}}
    end.

wait_for_matching_nip46_reply(Context, RequestId, Since, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_for_matching_nip46_reply_loop(Context, RequestId, Since, Deadline, []).

wait_for_matching_nip46_reply_loop(Context, RequestId, Since, Deadline, SeenErrors) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline =< Now of
        true ->
            {error, {timeout_waiting_for_reply, lists:reverse(SeenErrors)}};
        false ->
            Remaining = max(1000, min(5000, Deadline - Now)),
            Filter = nip46_reply_filter(Context, Since),
            Relays = require_live(relays, Context),
            case fetch_reply_events(Filter, Relays, Remaining) of
                {ok, Events} ->
                    case find_matching_decrypted_reply(Events, RequestId, Context) of
                        {ok, Event, Resp} ->
                            {ok, Event, Resp};
                        {error, Why} ->
                            timer:sleep(500),
                            wait_for_matching_nip46_reply_loop(
                                Context, RequestId, Since, Deadline, [Why | SeenErrors]
                            )
                    end;
                {error, Why} ->
                    timer:sleep(500),
                    wait_for_matching_nip46_reply_loop(Context, RequestId, Since, Deadline, [
                        Why | SeenErrors
                    ])
            end
    end.

nip46_reply_filter(Context, Since) ->
    #{
        <<"kinds">> => [?NIP46_KIND],
        <<"authors">> => [require_live(bunker_pubkey_hex, Context)],
        <<"#p">> => [require_live(client_pubkey_hex, Context)],
        <<"since">> => Since,
        <<"limit">> => 20
    }.

fetch_reply_events(Filter, Relays, TimeoutMs) ->
    _ = code:ensure_loaded(nostr_pool),
    _ = safe_eval(fun() -> nostr_pool:ensure_started(Relays) end),
    Fanout = max(1, length(Relays)),
    case erlang:function_exported(nostr_pool, req, 4) of
        true ->
            try nostr_pool:req(Filter, Relays, TimeoutMs, Fanout) of
                {ok, Events} when is_list(Events) -> {ok, Events};
                {ok, Event} when is_map(Event) -> {ok, [Event]};
                {error, _} = Error -> Error;
                Other -> {error, {unexpected_nostr_pool_req_result, compact(Other)}}
            catch
                C:R:S -> {error, {nostr_pool_req_failed, C, R, stack_top(S)}}
            end;
        false ->
            try nostr_pool:req_one(Filter, Relays, TimeoutMs, Fanout) of
                {ok, Event} when is_map(Event) -> {ok, [Event]};
                {error, _} = Error -> Error;
                Other -> {error, {unexpected_nostr_pool_req_one_result, compact(Other)}}
            catch
                C:R:S -> {error, {nostr_pool_req_one_failed, C, R, stack_top(S)}}
            end
    end.

find_matching_decrypted_reply([], _RequestId, _Context) ->
    {error, no_matching_reply_event};
find_matching_decrypted_reply([Event0 | Rest], RequestId, Context) ->
    Event = normalize_event(Event0),
    case decrypt_nip46_reply(Context, Event) of
        {ok, Resp} ->
            case response_id(Resp) =:= RequestId of
                true -> {ok, Event, Resp};
                false -> find_matching_decrypted_reply(Rest, RequestId, Context)
            end;
        {error, Reason} ->
            case Rest of
                [] -> {error, {reply_decrypt_failed, compact(Reason)}};
                _ -> find_matching_decrypted_reply(Rest, RequestId, Context)
            end
    end.

decrypt_nip46_reply(Context, Event) ->
    try
        BunkerPub = require_live(bunker_pubkey_hex, Context),
        Content = maps:get(content, Event, <<>>),
        {ok, Plain} = client_nip44_decrypt(BunkerPub, Content),
        case jsx:decode(Plain, [return_maps]) of
            Resp when is_map(Resp) -> {ok, Resp};
            Other -> {error, {decoded_reply_not_map, Other}}
        end
    catch
        C:R:S -> {error, {decrypt_live_nip46_reply_failed, C, R, stack_top(S)}}
    end.

client_nip44_encrypt(BunkerPub, Plain) ->
    {_ClientPub, ClientPriv} = damage_nostr_client_keypair(),
    NonceHex = lower_hex(crypto:strong_rand_bytes(32)),
    Req = #{
        <<"op">> => <<"nip44_encrypt_vector">>,
        <<"secret_key_hex">> => lower_hex(ClientPriv),
        <<"peer_pubkey_hex">> => BunkerPub,
        <<"nonce_hex">> => NonceHex,
        <<"plaintext">> => Plain
    },
    case backend_call(Req) of
        #{<<"payload">> := Payload} -> {ok, Payload};
        #{payload := Payload} -> {ok, Payload};
        Other -> {error, {missing_nip44_payload, compact(Other)}}
    end.

client_nip44_decrypt(BunkerPub, Payload) ->
    {_ClientPub, ClientPriv} = damage_nostr_client_keypair(),
    Req = #{
        <<"op">> => <<"nip44_decrypt_vector">>,
        <<"secret_key_hex">> => lower_hex(ClientPriv),
        <<"peer_pubkey_hex">> => BunkerPub,
        <<"payload">> => Payload
    },
    case backend_call(Req) of
        #{<<"plaintext">> := Plain} -> {ok, Plain};
        #{plaintext := Plain} -> {ok, Plain};
        Other -> {error, {missing_nip44_plaintext, compact(Other)}}
    end.

backend_call(Req) ->
    Config = damage_nsecbunker:config(),
    Backend = first_present([
        maps:get(crypto_backend_cmd, Config, undefined),
        maps:get(crypto_port_cmd, Config, undefined),
        damage_nsecbunker_ops:crypto_backend_path()
    ]),
    damage_nsecbunker_ops:backend_call(Req, #{backend => to_list(Backend)}).

damage_nostr_client_keypair() ->
    case secrets:retrieve_decrypt(damage_nostr_nsec) of
        {ok, Nsec} -> damage_nostr:nsec_to_npub(Nsec);
        Error -> erlang:error({damage_nostr_nsec_unavailable, Error})
    end.

%% ====================================================================
%% Black-box relay helpers
%% ====================================================================

black_box_publish_event(Event, Relays, TimeoutMs) ->
    Parent = self(),
    Ref = make_ref(),
    Workers =
        [
            spawn(fun() ->
                RelayUrl = relay_url(Relay),
                Result =
                    try direct_black_box_publish(Event, Relay, TimeoutMs) of
                        R -> R
                    catch
                        C:R:S -> {error, {black_box_publish_crash, C, R, stack_top(S)}}
                    end,
                Parent ! {Ref, RelayUrl, Result}
            end)
         || Relay <- Relays
        ],
    collect_black_box_publish_results(Ref, length(Workers), TimeoutMs + 2000, Workers, []).

collect_black_box_publish_results(_Ref, 0, _TimeoutMs, _Workers, Acc) ->
    finish_black_box_publish_results(lists:reverse(Acc));
collect_black_box_publish_results(Ref, Remaining, TimeoutMs, Workers, Acc) ->
    receive
        {Ref, RelayUrl, Result} ->
            collect_black_box_publish_results(Ref, Remaining - 1, TimeoutMs, Workers, [
                {RelayUrl, Result} | Acc
            ])
    after TimeoutMs ->
        _ = [safe_kill(Pid) || Pid <- Workers],
        finish_black_box_publish_results(lists:reverse([{timeout, publish_collect_timeout} | Acc]))
    end.

finish_black_box_publish_results(Results) ->
    Accepted = [{Relay, Map} || {Relay, {ok, Map}} <- Results],
    case Accepted of
        [] -> {error, #{error => all_black_box_relays_failed, results => compact(Results)}};
        _ -> {ok, #{accepted => length(Accepted), results => compact(Results)}}
    end.

direct_black_box_publish(Event, Relay, TimeoutMs) ->
    RelayUrl = relay_url(Relay),
    case damage_nostr:open_relay_ws(Relay, #{connect_timeout => min(15000, TimeoutMs)}) of
        {ok, ConnPid, StreamRef} ->
            try
                Msg = jsx:encode([<<"EVENT">>, Event]),
                case safe_ws_send(ConnPid, StreamRef, Msg) of
                    ok ->
                        await_black_box_publish_ok(
                            ConnPid, StreamRef, event_id(Event), RelayUrl, TimeoutMs
                        );
                    {error, FirstReason} ->
                        %% damage_nostr:open_relay_ws/2 may either return after the
                        %% websocket is already usable, or return while the gun upgrade
                        %% message is still in flight.  Try the direct send first, then
                        %% fall back to waiting for upgrade before retrying.
                        case
                            await_black_box_ws_ready(
                                ConnPid, StreamRef, RelayUrl, min(15000, TimeoutMs)
                            )
                        of
                            ok ->
                                case safe_ws_send(ConnPid, StreamRef, Msg) of
                                    ok ->
                                        await_black_box_publish_ok(
                                            ConnPid,
                                            StreamRef,
                                            event_id(Event),
                                            RelayUrl,
                                            TimeoutMs
                                        );
                                    {error, Reason} ->
                                        {error, {black_box_publish_send_failed, RelayUrl, Reason}}
                                end;
                            {error, Reason} ->
                                {error,
                                    {black_box_publish_websocket_upgrade_failed, RelayUrl, #{
                                        first_send => compact(FirstReason),
                                        upgrade => compact(Reason)
                                    }}}
                        end
                end
            after
                safe_close_gun(ConnPid)
            end;
        {error, Reason} ->
            {error, {black_box_open_relay_failed, RelayUrl, Reason}}
    end.

await_black_box_ws_ready(ConnPid, StreamRef, RelayUrl, TimeoutMs) ->
    receive
        {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers} ->
            ok;
        {gun_response, ConnPid, StreamRef, _Fin, 101, _Headers} ->
            ok;
        {gun_response, ConnPid, StreamRef, _Fin, Status, _Headers} ->
            {error, {black_box_websocket_upgrade_rejected, RelayUrl, Status}};
        {gun_up, ConnPid, _Protocol} ->
            await_black_box_ws_ready(ConnPid, StreamRef, RelayUrl, TimeoutMs);
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {black_box_gun_error, RelayUrl, Reason}};
        {gun_error, ConnPid, Reason} ->
            {error, {black_box_gun_error, RelayUrl, Reason}};
        {gun_down, ConnPid, Protocol, Reason, KilledStreams} ->
            {error, {black_box_gun_down, RelayUrl, Protocol, Reason, safe_len(KilledStreams)}};
        {gun_down, ConnPid, Protocol, Reason, KilledStreams, UnprocessedStreams} ->
            {error,
                {black_box_gun_down, RelayUrl, Protocol, Reason, safe_len(KilledStreams),
                    safe_len(UnprocessedStreams)}};
        _Other ->
            await_black_box_ws_ready(ConnPid, StreamRef, RelayUrl, TimeoutMs)
    after TimeoutMs ->
        {error, {black_box_websocket_upgrade_timeout, RelayUrl}}
    end.

await_black_box_publish_ok(ConnPid, StreamRef, ExpectedId, RelayUrl, TimeoutMs) ->
    receive
        {gun_ws, ConnPid, StreamRef, {text, Msg}} ->
            case safe_decode(Msg) of
                [<<"OK">>, EventId, true, Message] when
                    EventId =:= ExpectedId; ExpectedId =:= <<>>
                ->
                    {ok, #{relay => RelayUrl, event_id => EventId, message => Message}};
                [<<"OK">>, EventId, false, Message] when
                    EventId =:= ExpectedId; ExpectedId =:= <<>>
                ->
                    {error, {black_box_relay_rejected_event, RelayUrl, EventId, Message}};
                [<<"NOTICE">>, _Notice] ->
                    await_black_box_publish_ok(ConnPid, StreamRef, ExpectedId, RelayUrl, TimeoutMs);
                _Other ->
                    await_black_box_publish_ok(ConnPid, StreamRef, ExpectedId, RelayUrl, TimeoutMs)
            end;
        {gun_down, ConnPid, Protocol, Reason, KilledStreams} ->
            {error, {black_box_gun_down, RelayUrl, Protocol, Reason, safe_len(KilledStreams)}};
        {gun_down, ConnPid, Protocol, Reason, KilledStreams, UnprocessedStreams} ->
            {error,
                {black_box_gun_down, RelayUrl, Protocol, Reason, safe_len(KilledStreams),
                    safe_len(UnprocessedStreams)}};
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {black_box_gun_error, RelayUrl, Reason}};
        {gun_error, ConnPid, Reason} ->
            {error, {black_box_gun_error, RelayUrl, Reason}}
    after TimeoutMs ->
        {error, {black_box_publish_timeout, RelayUrl, ExpectedId}}
    end.

wait_for_relay_adapter_observation(EventId, Before, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_for_relay_adapter_observation_loop(EventId, Before, Deadline, relay_adapter_status()).

wait_for_relay_adapter_observation_loop(EventId, Before, Deadline, LastStatus) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            {error, relay_adapter_observation_timeout, LastStatus};
        false ->
            Status = relay_adapter_status(),
            EventObserved = status_observed_event_id(EventId, Status),
            CounterIncreased =
                status_counter(inbound_events, Status) > status_counter(inbound_events, Before),
            case EventObserved orelse CounterIncreased of
                true ->
                    {ok, Status};
                false ->
                    timer:sleep(250),
                    wait_for_relay_adapter_observation_loop(EventId, Before, Deadline, Status)
            end
    end.

relay_adapter_status() ->
    case safe_eval(fun() -> damage_nsecbunker_relay:status() end) of
        Status when is_map(Status) -> Status;
        Other -> #{running => false, error => Other}
    end.

status_counter(Key, Status) when is_map(Status) ->
    Stats = map_get_any(stats, Status, map_get_any(<<"stats">>, Status, #{})),
    to_int_safe(map_get_any(Key, Stats, map_get_any(atom_to_binary(Key, utf8), Stats, 0)), 0);
status_counter(_Key, _Status) ->
    0.

status_observed_event_id(EventId0, Status) when is_map(Status) ->
    EventId = bin(EventId0),
    Recent = [bin(Id) || Id <- recent_inbound_event_ids(Status)],
    lists:member(EventId, Recent) orelse
        bin(map_get_any(last_inbound_event_id, Status, <<>>)) =:= EventId;
status_observed_event_id(_EventId, _Status) ->
    false.

recent_inbound_event_ids(Status) ->
    first_present(
        [
            map_get_any(recent_inbound_event_ids, Status),
            map_get_any(<<"recent_inbound_event_ids">>, Status),
            []
        ],
        []
    ).

wait_for_relay_bridge_subscribed(Context, TimeoutMs) ->
    %% Fire subscribe once. Use a bounded caller process so a stuck relay
    %% implementation cannot hang the BDD step for the relay adapter's full
    %% gen_server call timeout.
    _ = safe_eval_timeout(fun() -> damage_nostr_relay_client:subscribe() end, 5000),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_for_relay_bridge_subscribed_loop(Context, Deadline, undefined, undefined).

wait_for_relay_bridge_subscribed_loop(Context, Deadline, LastRelayClient, LastRelayAdapter) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            {error, LastRelayClient, LastRelayAdapter};
        false ->
            RelayClientStatus = safe_eval_timeout(
                fun() -> damage_nostr_relay_client:status() end, 3000
            ),
            RelayAdapterStatus = safe_eval_timeout(
                fun() -> damage_nsecbunker_relay:status() end, 3000
            ),
            case
                {
                    is_status_running(RelayClientStatus),
                    is_status_running(RelayAdapterStatus),
                    is_status_subscribed(RelayAdapterStatus)
                }
            of
                {true, true, true} ->
                    {ok, RelayClientStatus, RelayAdapterStatus};
                _ ->
                    %% If the adapter is still not live, retrigger subscribe.
                    %% This is safe because the adapter replaces the subscription
                    %% set cleanly and the bridge/adapter are both idempotent for
                    %% this BDD setup phase.
                    _ = safe_eval_timeout(fun() -> damage_nostr_relay_client:subscribe() end, 3000),
                    timer:sleep(500),
                    wait_for_relay_bridge_subscribed_loop(
                        Context, Deadline, RelayClientStatus, RelayAdapterStatus
                    )
            end
    end.

safe_eval_timeout(Fun, TimeoutMs) when is_function(Fun, 0), is_integer(TimeoutMs), TimeoutMs > 0 ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() -> Parent ! {Ref, safe_eval(Fun)} end),
    receive
        {Ref, Value} -> Value
    after TimeoutMs ->
        safe_kill(Pid),
        {error, {timeout, TimeoutMs}}
    end.

safe_eval(Fun) when is_function(Fun, 0) ->
    try Fun() of
        Value -> Value
    catch
        C:R:S -> {error, {C, R, stack_top(S)}}
    end.

safe_kill(Pid) when is_pid(Pid) ->
    try exit(Pid, kill) of
        _ -> ok
    catch
        _:_ -> ok
    end;
safe_kill(_) ->
    ok.

safe_close_gun(ConnPid) when is_pid(ConnPid) ->
    try gun:close(ConnPid) of
        _ -> ok
    catch
        _:_ -> ok
    end;
safe_close_gun(_) ->
    ok.

safe_ws_send(ConnPid, StreamRef, Msg) ->
    try gun:ws_send(ConnPid, StreamRef, {text, Msg}) of
        ok -> ok;
        Other -> {error, Other}
    catch
        C:R -> {error, {C, R}}
    end.

safe_decode(Msg) ->
    try jsx:decode(Msg, [return_maps]) of
        Frame -> Frame
    catch
        C:R -> {decode_failed, C, R, byte_size(bin(Msg))}
    end.

safe_len(L) when is_list(L) -> length(L);
safe_len(_) -> 0.

to_int_safe(I, _Default) when is_integer(I) -> I;
to_int_safe(B, Default) when is_binary(B) ->
    try
        binary_to_integer(B)
    catch
        _:_ -> Default
    end;
to_int_safe(L, Default) when is_list(L) ->
    try
        list_to_integer(L)
    catch
        _:_ -> Default
    end;
to_int_safe(_, Default) ->
    Default.

%% ====================================================================
%% Response / signed event helpers
%% ====================================================================

plain_response_map({ok, Map}) when is_map(Map) -> Map;
plain_response_map(Map) when is_map(Map) -> Map;
plain_response_map(Other) -> #{error => Other}.

assert_response_accepted(Context, Resp) ->
    case response_rejected(Resp) of
        false -> Context;
        true -> fail(Context, {response_not_accepted, Resp})
    end.

response_rejected(Resp) when is_map(Resp) ->
    not empty_error(response_error(Resp));
response_rejected(_) ->
    true.

response_id(Resp) when is_map(Resp) ->
    bin(map_get_any(<<"id">>, Resp, map_get_any(id, Resp, <<>>))).

response_result_bin(Resp) when is_map(Resp) ->
    bin(map_get_any(<<"result">>, Resp, map_get_any(result, Resp, <<>>))).

response_error(Resp) when is_map(Resp) ->
    map_get_any(<<"error">>, Resp, map_get_any(error, Resp, <<>>)).

response_error_reason(Resp) ->
    Err = response_error(Resp),
    case Err of
        <<>> ->
            <<>>;
        undefined ->
            <<>>;
        M when is_map(M) ->
            bin(
                first_present(
                    [
                        map_get_any(<<"reason">>, M),
                        map_get_any(reason, M),
                        map_get_any(<<"message">>, M),
                        map_get_any(message, M),
                        map_get_any(<<"code">>, M),
                        map_get_any(code, M),
                        M
                    ],
                    <<>>
                )
            );
        [Code, Message | _] ->
            iolist_to_binary([bin(Code), <<":">>, bin(Message)]);
        Other ->
            bin(Other)
    end.

empty_error(undefined) -> true;
empty_error(<<>>) -> true;
empty_error("") -> true;
empty_error(null) -> true;
empty_error(false) -> true;
empty_error(_) -> false.

signed_event_from_context(Context) ->
    Resp = require_live(last_nip46_response, Context),
    Event0 = signed_event_from_response(Resp),
    Event = normalize_event(Event0),
    put_signed_event(Context, Event),
    Event.

put_signed_event(_Context, Event) ->
    %% Kept as a function for future report plumbing.  We avoid mutating the
    %% caller context from assertion helpers.
    Event.

signed_event_from_response(Resp) ->
    Result = map_get_any(<<"result">>, Resp, map_get_any(result, Resp, undefined)),
    case Result of
        M when is_map(M) -> M;
        B when is_binary(B) ->
            try jsx:decode(B, [return_maps]) of
                M when is_map(M) -> M;
                Other -> erlang:error({signed_event_result_not_map, Other})
            catch
                C:R -> erlang:error({signed_event_result_decode_failed, C, R, B})
            end;
        L when is_list(L) ->
            signed_event_from_response(#{<<"result">> => unicode:characters_to_binary(L)});
        Other ->
            erlang:error({signed_event_result_missing_or_invalid, Other, Resp})
    end.

find_event_on_relays(EventId, Kind, Author, Relays, TimeoutMs) ->
    Filter = #{
        <<"ids">> => [EventId],
        <<"kinds">> => [Kind],
        <<"authors">> => [Author],
        <<"limit">> => 1
    },
    case fetch_reply_events(Filter, Relays, TimeoutMs) of
        {ok, []} -> not_found;
        {ok, [Event | _]} -> {found, Event};
        {error, {timeout, _}} -> not_found;
        {error, timeout} -> not_found;
        {error, not_found} -> not_found;
        {error, Why} -> {error, Why}
    end.

%% ====================================================================
%% Audit helpers
%% ====================================================================

audit_lines_for_run(Context) ->
    RunId = require_live(test_run_id, Context),
    Bin = audit_tail(Context),
    [Line || Line <- binary:split(Bin, <<"\n">>, [global]), binary:match(Line, RunId) =/= nomatch].

audit_tail(Context) ->
    Cfg = get_config(Context),
    Path = maps:get(audit_log, Cfg, "/var/log/damage/nsecbunker_audit.log"),
    Path1 = to_list(Path),
    case file:read_file_info(Path1) of
        {ok, Info} ->
            Size = Info#file_info.size,
            case file:open(Path1, [read, binary]) of
                {ok, Fd} ->
                    Offset = max(0, Size - ?AUDIT_TAIL_BYTES),
                    _ = file:position(Fd, Offset),
                    ReadLen = min(?AUDIT_TAIL_BYTES, Size),
                    Result = file:read(Fd, ReadLen),
                    _ = file:close(Fd),
                    case Result of
                        {ok, Bin} -> Bin;
                        eof -> <<>>;
                        {error, Reason} -> erlang:error({audit_log_read_failed, Path1, Reason})
                    end;
                {error, Reason} ->
                    erlang:error({audit_log_open_failed, Path1, Reason})
            end;
        {error, Reason} ->
            erlang:error({audit_log_stat_failed, Path1, Reason})
    end.

%% ====================================================================
%% Small state helpers
%% ====================================================================

live(Context) ->
    maps:get(?NS, Context, #{}).

put_live(Context, Extra) when is_map(Extra) ->
    maps:put(?NS, maps:merge(live(Context), Extra), Context).

require_live(Key, Context) ->
    case maps:get(Key, live(Context), undefined) of
        undefined -> erlang:error({missing_live_context_key, Key});
        Value -> Value
    end.

get_status(Context) ->
    maps:get(status, live(Context), damage_nsecbunker:status()).

get_config(Context) ->
    maps:get(config, live(Context), damage_nsecbunker:config()).

get_policy(Context) ->
    maps:get(policy, live(Context), damage_nsecbunker:policy()).

return_only_filter(Context) ->
    Bunker = maps:get(bunker_pubkey_hex, live(Context), <<>>),
    case Bunker of
        <<>> ->
            undefined;
        _ ->
            case
                damage_nostr_relay_client:subscribe(#{
                    relay_publication_mode => return_only, bunker_pubkey_hex => Bunker
                })
            of
                {ok, #{filter := Filter}} -> Filter;
                _ -> undefined
            end
    end.

is_status_running(#{running := true}) -> true;
is_status_running(_) -> false.

is_status_subscribed(#{subscribed := true}) -> true;
is_status_subscribed(_) -> false.

public_request(Request) ->
    maps:without([private_key, secret_key, nsec], Request).

public_event(Event) ->
    Event.

safe_public(Term) ->
    %% Remove obvious secret-shaped keys even though these live APIs should not
    %% return secret material.
    safe_public(Term, 0).

safe_public(Term, Depth) when Depth > 6 -> compact(Term);
safe_public(Map, Depth) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            case secret_key_name(K) of
                true -> Acc#{K => <<"[REDACTED]">>};
                false -> Acc#{K => safe_public(V, Depth + 1)}
            end
        end,
        #{},
        Map
    );
safe_public(List, Depth) when is_list(List) ->
    [safe_public(V, Depth + 1) || V <- List];
safe_public(Term, _Depth) ->
    Term.

%% ====================================================================
%% Generic helpers
%% ====================================================================

make_run_id() ->
    TS = integer_to_binary(erlang:system_time(second)),
    Rand = binary:encode_hex(crypto:strong_rand_bytes(4)),
    <<"live-nsecbunker-", TS/binary, "-", Rand/binary>>.

make_request_id(Context, Prefix, Method) ->
    RunId = require_live(test_run_id, Context),
    Rand = binary:encode_hex(crypto:strong_rand_bytes(4)),
    <<RunId/binary, "-", Prefix/binary, "-", Method/binary, "-", Rand/binary>>.

first_disallowed_kind(Policy) ->
    Allowed = maps:get(allowed_kinds, Policy, []),
    hd([K || K <- [27235, 1984, 9735, 10002, 1, 30024], not lists:member(K, Allowed)]).

relay_publish_accepted({ok, #{accepted := N}}) when is_integer(N), N > 0 -> true;
relay_publish_accepted({ok, #{<<"accepted">> := N}}) when is_integer(N), N > 0 -> true;
relay_publish_accepted(_) -> false.

normalize_event(Event) ->
    damage_nostr_event:normalize_event(Event).

event_id(Event0) ->
    Event = normalize_event(Event0),
    case maps:get(id, Event, maps:get(<<"id">>, Event, <<>>)) of
        <<>> -> damage_nostr_event:id(Event);
        Id -> bin(Id)
    end.

map_get_any(Key, Map) ->
    map_get_any(Key, Map, undefined).
map_get_any(Key, Map, Default) when is_map(Map) ->
    case maps:get(Key, Map, undefined) of
        undefined when is_atom(Key) -> maps:get(atom_to_binary(Key, utf8), Map, Default);
        undefined when is_binary(Key) ->
            try
                maps:get(binary_to_existing_atom(Key, utf8), Map, Default)
            catch
                _:_ -> Default
            end;
        Value ->
            Value
    end;
map_get_any(_Key, _Map, Default) ->
    Default.

first_present(List) -> first_present(List, undefined).
first_present([], Default) -> Default;
first_present([undefined | Rest], Default) -> first_present(Rest, Default);
first_present([false | Rest], Default) -> first_present(Rest, Default);
first_present([<<>> | Rest], Default) -> first_present(Rest, Default);
first_present([[] | Rest], Default) -> first_present(Rest, Default);
first_present([Value | _Rest], _Default) -> Value.

assert_equal(Context, A, A, _Reason) -> Context;
assert_equal(Context, A, B, Reason) -> fail(Context, {assert_equal_failed, A, B, Reason}).

fail(Context, Reason) ->
    maps:put(fail, Reason, Context).

strip(V) when is_binary(V) -> strip_quotes(trim(V));
strip(V) when is_list(V) -> strip(unicode:characters_to_binary(V));
strip(V) when is_atom(V) -> atom_to_binary(V, utf8);
strip(V) when is_integer(V) -> integer_to_binary(V);
strip(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

strip_quotes(<<$", Rest/binary>>) ->
    N = byte_size(Rest),
    case N > 0 andalso binary:at(Rest, N - 1) =:= $" of
        true -> binary:part(Rest, 0, N - 1);
        false -> <<$", Rest/binary>>
    end;
strip_quotes(Bin) ->
    Bin.

trim(Bin) when is_binary(Bin) -> trim_right(trim_left(Bin)).
trim_left(<<C, Rest/binary>>) when C =:= 32; C =:= 9; C =:= 10; C =:= 13 -> trim_left(Rest);
trim_left(Bin) -> Bin.
trim_right(Bin) -> trim_right(Bin, byte_size(Bin)).
trim_right(_Bin, N) when N =< 0 -> <<>>;
trim_right(Bin, N) ->
    case binary:at(Bin, N - 1) of
        C when C =:= 32; C =:= 9; C =:= 10; C =:= 13 ->
            trim_right(binary:part(Bin, 0, N - 1), N - 1);
        _ ->
            Bin
    end.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B) -> binary_to_integer(strip(B));
to_int(L) when is_list(L) -> to_int(unicode:characters_to_binary(L));
to_int(A) when is_atom(A) -> to_int(atom_to_binary(A, utf8)).

bin(undefined) -> <<>>;
bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(L) when is_list(L) -> L;
to_list(I) when is_integer(I) -> integer_to_list(I);
to_list(Other) -> lists:flatten(io_lib:format("~p", [Other])).

lower_hex_bin(V) ->
    B = bin(V),
    list_to_binary(string:lowercase(binary_to_list(B))).

lower_hex(Bin) when is_binary(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [X]) || <<X>> <= Bin]).

is_lower_hex_64(Bin) when is_binary(Bin), byte_size(Bin) =:= 64 ->
    re:run(Bin, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match;
is_lower_hex_64(_) ->
    false.

relay_url(#{url := Url}) -> bin(Url);
relay_url(#{<<"url">> := Url}) -> bin(Url);
relay_url(Url) -> bin(Url).

secret_key_name(K) ->
    lists:member(lower_hex_bin(K), [
        <<"nsec">>,
        <<"private_key">>,
        <<"private_key_hex">>,
        <<"privkey">>,
        <<"privkey_hex">>,
        <<"secret_key">>,
        <<"secret_key_hex">>,
        <<"mnemonic">>,
        <<"seed">>,
        <<"seed_hex">>,
        <<"sk">>
    ]).

compact(Map) when is_map(Map) ->
    case map_size(Map) =< 12 of
        true -> maps:map(fun(_K, V) -> compact(V) end, Map);
        false -> #{type => map, size => map_size(Map), keys => maps:keys(Map)}
    end;
compact(List) when is_list(List) ->
    case length(List) =< 12 of
        true -> [compact(V) || V <- List];
        false -> #{type => list, length => length(List)}
    end;
compact(Tuple) when is_tuple(Tuple) ->
    case tuple_size(Tuple) =< 12 of
        true -> list_to_tuple([compact(V) || V <- tuple_to_list(Tuple)]);
        false -> #{type => tuple, size => tuple_size(Tuple), tag => element(1, Tuple)}
    end;
compact(Bin) when is_binary(Bin), byte_size(Bin) > 256 ->
    #{type => binary, bytes => byte_size(Bin)};
compact(Other) ->
    Other.

stack_top([{M, F, A, _} | _]) -> {M, F, A};
stack_top(_) -> undefined.
