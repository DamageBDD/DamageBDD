%%% Offline tests only. Model fixtures are UNSIGNED and must never enter relays.
%%% Compile source with -DTEST for the narrow private-function test exports.
-module(erm_lens_resilience_tests).
-include_lib("eunit/include/eunit.hrl").

pub(N) -> erm_lens_nostr:hex(<<N:256>>).
photo(Id, Author, At) ->
    #{<<"id">> => pub(Id), <<"pubkey">> => pub(Author), <<"kind">> => 20,
      <<"created_at">> => At, <<"content">> => <<"caption">>,
      <<"sig">> => binary:copy(<<"0">>, 128),
      <<"tags">> => [[<<"imeta">>, <<"url https://example.com/a.png">>, <<"m image/png">>]]}.
state(Events, Config, Now) ->
    lists:foldl(fun(E, S) -> erm_lens_model:insert(E, Now, S) end,
                erm_lens_model:new(Config), Events).
prepared() ->
    #{fee_aettos => 1, request =>
      #{sender => <<"ak_sender">>, recipient => <<"ak_recipient">>, author => pub(1),
        network => <<"ae_uat">>, token => <<"ct_token">>, amount_base_units => 100,
        decimals => 8, symbol => <<"TEST">>, post_id => pub(2), request_id => pub(3),
        expires_at => erlang:system_time(second) + 60}}.
with_req(Key, Value) ->
    P = prepared(), R = maps:get(request, P), P#{request := R#{Key => Value}}.
ui_state() ->
    #{config => #{}, window => undefined, want_visible => false, closed => false,
      cards => [previous_card], photos => #{}, rows => [previous_post], page => 0,
      mode => popular, generation => 1, revision => 0, snapshot_loaded => false,
      gui_monitor => undefined, job => undefined, pending_tip => undefined,
      message => <<>>, ui_capabilities => #{}, last_ui_error => undefined,
      wallet_outcome_unknown => false}.

config_defaults_test() ->
    ?assertMatch({ok, #{max_store_bytes := 67108864}}, erm_lens_config:normalize(#{})).
config_proplist_test() ->
    ?assertMatch({ok, #{enabled := false}}, erm_lens_config:normalize([{enabled, false}])).
config_malformed_proplist_test() ->
    ?assertMatch({error, {bad_lens_config, _}}, erm_lens_config:normalize([broken])).
config_bad_numeric_test() ->
    ?assertMatch({error, {bad_lens_config, refresh_ms}}, erm_lens_config:normalize(#{refresh_ms => infinity})).
config_bad_boolean_test() ->
    ?assertMatch({error, {bad_lens_config, enabled}}, erm_lens_config:normalize(#{enabled => yes})).
config_bad_relay_test() ->
    ?assertMatch({error, {bad_lens_config, relays}}, erm_lens_config:normalize(#{relays => [<<"wss://u:p@example.com">>]})).
config_bad_follow_keys_test() ->
    ?assertMatch({error, {bad_lens_config, following}}, erm_lens_config:normalize(#{following => [<<"not a key">>]})).
config_integer_fallback_test() ->
    ?assertEqual(6, erm_lens_config:integer(page_size, #{page_size => nope}, 6, 1, 12)).
start_rejects_invalid_config_test() ->
    ?assertMatch({error, {bad_lens_config, _}}, erm_lens:start(#{page_size => 0})).
standalone_respects_disabled_test() ->
    ?assertEqual({error, disabled}, erm_lens:start_standalone(#{enabled => false})).
show_respects_disabled_test() ->
    Old = application:get_env(erm, lens),
    try
        application:set_env(erm, lens, #{enabled => false}),
        ?assertEqual({error, disabled}, erm_lens:show())
    after
        case Old of
            undefined -> application:unset_env(erm, lens);
            {ok, C} -> application:set_env(erm, lens, C)
        end
    end.

improper_tag_is_rejected_test() ->
    E = photo(1, 2, 1000),
    ?assertEqual({error, invalid_event}, erm_lens_nostr:validate(E#{<<"tags">> := [[<<"x">> | bad_tail]]})).
tag_budget_rejected_test() ->
    E = photo(1, 2, 1000),
    Tags = lists:duplicate(20, [<<"x">>, binary:copy(<<"a">>, 8192)]),
    ?assertEqual({error, invalid_event}, erm_lens_nostr:validate(E#{<<"tags">> := Tags})).
large_timestamp_rejected_test() ->
    E = photo(1, 2, 1000),
    ?assertEqual({error, invalid_event}, erm_lens_nostr:validate(E#{<<"created_at">> := (1 bsl 1000)})).
invalid_utf8_rejected_test() ->
    E = photo(1, 2, 1000),
    ?assertEqual({error, invalid_event}, erm_lens_nostr:validate(E#{<<"content">> := <<255>>})).
unsigned_extension_stripped_test() ->
    E = photo(1, 2, 1000),
    S = state([E#{<<"unsigned_blob">> => binary:copy(<<"a">>, 1000000)}], #{}, 1000),
    Stored = maps:get(pub(1), maps:get(events, S)),
    ?assertEqual(E, Stored).
byte_budget_test() ->
    Events = [(photo(N, 2, 1000))#{<<"content">> := binary:copy(<<"a">>, 60000)} || N <- lists:seq(1, 10)],
    S = state(Events, #{max_store_bytes => 262144}, 1000),
    ?assert(maps:get(bytes, S) =< 262144),
    ?assert(erm_lens_model:size(S) < 10).
prune_without_new_events_test() ->
    S = state([photo(1, 2, 1000)], #{window_seconds => 10}, 1000),
    S1 = erm_lens_model:prune(1011, S),
    ?assertEqual(0, erm_lens_model:size(S1)),
    ?assertEqual(0, maps:get(bytes, S1)).
muted_ids_not_requested_test() ->
    S = state([photo(1, 2, 1000)], #{}, 1000),
    ?assertEqual([], erm_lens_model:ids(erm_lens_model:mute(pub(2), S), 1000)).
deleted_ids_not_requested_test() ->
    D = (photo(10, 2, 1000))#{<<"kind">> := 5, <<"tags">> := [[<<"e">>, pub(1)]]},
    S = state([photo(1, 2, 1000), D], #{}, 1000),
    ?assertEqual([], erm_lens_model:ids(S, 1000)).
expired_ids_not_requested_test() ->
    S = state([photo(1, 2, 1000)], #{window_seconds => 10}, 1000),
    ?assertEqual([], erm_lens_model:ids(S, 1011)).
non_feed_kinds_not_retained_test() ->
    E = (photo(1, 2, 1000))#{<<"kind">> := 30078},
    ?assertEqual(0, erm_lens_model:size(state([E], #{}, 1000))).
image_credentials_rejected_test() ->
    ?assertMatch({error, _}, erm_lens_nostr:picture(pub(1), <<"https://u:p@example.com/a.png">>,
        <<"image/png">>, <<>>, <<>>)).
image_bad_alt_rejected_test() ->
    ?assertMatch({error, _}, erm_lens_nostr:picture(pub(1), <<"https://example.com/a.png">>,
        <<"image/png">>, not_text, <<>>)).

feed_preferences_increment_revision_test() ->
    {ok, Pid} = erm_lens_feed:start_link(#{}),
    try
        Initial = erm_lens_feed:status(),
        ok = erm_lens_feed:follow(pub(1)),
        A = erm_lens_feed:status(),
        ok = erm_lens_feed:follow(pub(1)),
        B = erm_lens_feed:status(),
        ok = erm_lens_feed:mute(pub(2)),
        C = erm_lens_feed:status(),
        ?assertEqual(maps:get(revision, Initial) + 1, maps:get(revision, A)),
        ?assertEqual(maps:get(revision, A), maps:get(revision, B)),
        ?assertEqual(maps:get(revision, B) + 1, maps:get(revision, C)),
        ?assertEqual({error, invalid_pubkey}, erm_lens_feed:mute(<<"bad">>))
    after gen_server:stop(Pid) end.
feed_invalid_ingest_does_not_crash_test() ->
    {ok, Pid} = erm_lens_feed:start_link(#{}),
    try
        ?assertEqual({error, invalid_event}, erm_lens_feed:ingest(garbage)),
        ?assertEqual(1, maps:get(rejected, erm_lens_feed:status())),
        ?assert(is_process_alive(Pid))
    after gen_server:stop(Pid) end.

amount_trailing_newline_rejected_test() ->
    ?assertEqual({error, invalid_amount}, erm_lens_wallet:amount(<<"1\n">>, 8)).
format_fractional_decimals_rejected_test() ->
    ?assertError(invalid_amount_format, erm_lens_wallet:format_amount(10, 1.5)).
prepared_shape_test() -> ?assertEqual(ok, erm_lens_wallet:validate_prepared(prepared())).
prepared_atom_expiry_rejected_test() ->
    ?assertEqual({error, invalid_prepared_tip}, erm_lens_wallet:submit_tip(with_req(expires_at, infinity), #{network => <<"ae_uat">>})).
prepared_negative_amount_rejected_test() ->
    ?assertEqual({error, invalid_prepared_tip}, erm_lens_wallet:validate_prepared(with_req(amount_base_units, -1))).
prepared_float_amount_rejected_test() ->
    ?assertEqual({error, invalid_prepared_tip}, erm_lens_wallet:validate_prepared(with_req(amount_base_units, 1.5))).
prepared_float_decimals_rejected_test() ->
    ?assertEqual({error, invalid_prepared_tip}, erm_lens_wallet:validate_prepared(with_req(decimals, 1.5))).
prepared_symbol_controls_rejected_test() ->
    ?assertEqual({error, invalid_prepared_tip}, erm_lens_wallet:validate_prepared(with_req(symbol, <<"TEST\nSEND">>))).
prepared_missing_fields_rejected_test() ->
    ?assertEqual({error, invalid_prepared_tip}, erm_lens_wallet:validate_prepared(#{request => #{}, fee_aettos => 1})).
submit_malformed_term_rejected_test() ->
    ?assertEqual({error, invalid_prepared_tip}, erm_lens_wallet:submit_tip(not_a_map, #{network => <<"ae_uat">>})).
expired_preview_test() ->
    ?assertEqual({error, tip_preview_expired}, erm_lens_wallet:check_expiry(#{expires_at => erlang:system_time(second) - 1})).
unbounded_future_preview_test() ->
    ?assertEqual({error, tip_preview_expired}, erm_lens_wallet:check_expiry(#{expires_at => erlang:system_time(second) + 10000})).
invalid_adapter_configuration_test() ->
    ?assertEqual({error, invalid_wallet_adapter}, erm_lens_wallet:status(#{wallet_adapter => <<"not a module">>})).

owned_job_result_test() ->
    {Pid, Mon} = erm_lens_worker:start(test_job, fun() -> {ok, 42} end),
    receive {test_job, Pid, Result} -> ?assertEqual({ok, 42}, Result)
    after 2000 -> error(job_result_timeout) end,
    erlang:demonitor(Mon, [flush]).
owned_job_exception_isolated_test() ->
    {Pid, Mon} = erm_lens_worker:start(test_job, fun() -> error(test_fault) end),
    receive {'DOWN', Mon, process, Pid, Reason} -> ?assertMatch({job_exit, _}, Reason)
    after 2000 -> error(job_exception_timeout) end.
owner_killed_cleans_task_test() -> owner_dies(kill).
owner_normal_exit_cleans_task_test() -> owner_dies(normal).
owner_dies(Reason) ->
    Test = self(),
    Owner = spawn(fun() ->
        {Job, _} = erm_lens_worker:start(test_job, fun() ->
            Test ! {task_started, self()}, receive never -> ok end
        end),
        Test ! {job_started, Job},
        receive stop -> ok end
    end),
    Job = receive {job_started, J} -> J after 2000 -> error(no_job) end,
    Task = receive {task_started, T} -> T after 2000 -> error(no_task) end,
    TaskMon = erlang:monitor(process, Task),
    JobMon = erlang:monitor(process, Job),
    case Reason of kill -> exit(Owner, kill); normal -> Owner ! stop end,
    try
        receive {'DOWN', TaskMon, process, Task, _} -> ok after 2000 -> error(orphan_task) end,
        receive {'DOWN', JobMon, process, Job, _} -> ok after 2000 -> error(orphan_guardian) end
    after exit(Task, kill), exit(Job, kill), exit(Owner, kill) end.

relay_silent_timeout_is_failure_test() ->
    End = erlang:monotonic_time(millisecond) - 1,
    ?assertError({relay_query_timeout, 3, 1}, erm_lens_relay:collect(self(), make_ref(), <<"sub">>, [], 4, End, 3, 1)).
relay_cap_is_distinct_test() ->
    ?assertEqual({3, 1, cap}, erm_lens_relay:collect(self(), make_ref(), <<"sub">>, [], 0, 0, 3, 1)).
relay_oversized_ack_rejected_test() ->
    Pid = self(), Stream = make_ref(),
    self() ! {gun_ws, Pid, Stream, {text, binary:copy(<<"x">>, 262145)}},
    ?assertEqual({error, oversized_relay_frame}, erm_lens_relay:await_ok(Pid, Stream, pub(1), erlang:monotonic_time(millisecond) + 1000)).
relay_connection_wide_error_test() ->
    Pid = self(), Stream = make_ref(),
    self() ! {gun_error, Pid, closed},
    ?assertEqual({error, {relay_error, closed}}, erm_lens_relay:await_ok(Pid, Stream, pub(1), erlang:monotonic_time(millisecond) + 1000)).
relay_binary_ack_rejected_test() ->
    Pid = self(), Stream = make_ref(), self() ! {gun_ws, Pid, Stream, {binary, <<1>>}},
    ?assertEqual({error, unexpected_binary_frame}, erm_lens_relay:await_ok(Pid, Stream, pub(1), erlang:monotonic_time(millisecond) + 1000)).
backoff_jitter_is_bounded_test() ->
    Values = [erm_lens_sync:retry_delay(100, #{}) || _ <- lists:seq(1, 100)],
    ?assert(lists:all(fun(N) -> N > 0 andalso N =< 300000 end, Values)).
healthy_retry_does_not_use_zero_epoch_test() ->
    S = #{status => #{url => #{state => ok, next_retry_mono => 0}}},
    ?assertEqual(0, maps:get(retry_in_ms, maps:get(url, erm_lens_sync:status_snapshot(S)))).
connecting_retry_is_zero_test() ->
    S = #{status => #{url => #{state => connecting, next_retry_mono => erlang:monotonic_time(millisecond) + 5000}}},
    ?assertEqual(0, maps:get(retry_in_ms, maps:get(url, erm_lens_sync:status_snapshot(S)))).

nonzero_decoder_exit_cannot_succeed_test() ->
    {ok, Data} = erm_lens_codec:encode(#{<<"ok">> => <<"/tmp/arbitrary.png">>}),
    ?assertEqual({error, {decoder_exit_status, 1}}, erm_lens_media:decoder_reply(1, Data)).
decoder_ambiguous_envelope_rejected_test() ->
    {ok, Data} = erm_lens_codec:encode(#{<<"ok">> => <<"/tmp/x">>, <<"error">> => <<"x">>}),
    ?assertEqual({error, invalid_decoder_response}, erm_lens_media:decoder_reply(0, Data)).
decoder_path_escape_rejected_test() ->
    ?assertEqual({error, unsafe_decoder_path}, erm_lens_media:validate_result(
        {ok, <<"/etc/passwd">>}, #{url => <<"https://example.com/a.png">>}, #{cache_dir => "/tmp/lens-test"})).
decoder_expired_deadline_test() ->
    ?assertEqual({error, decoder_timeout}, erm_lens_media:read_port(make_ref(), <<>>, erlang:monotonic_time(millisecond) - 1)).

compact_diagnostic_always_bounded_test() ->
    Term = [{nested, lists:duplicate(10000, {payload, <<"abcdef">>})}],
    Result = erm_lens_ui:compact_term(Term),
    ?assert(is_binary(Result)), ?assert(byte_size(Result) =< 4800).
compact_diagnostic_utf8_test() ->
    Result = erm_lens_diagnostics:summary(binary:copy(<<"🙂"/utf8>>, 10000)),
    ?assert(is_list(unicode:characters_to_list(Result))).
stack_omits_arguments_test() ->
    ?assertEqual([{m, f, 1}], erm_lens_diagnostics:stack([{m, f, [<<"secret">>], []}])).
relay_log_label_redacts_query_test() ->
    Label = erm_lens_diagnostics:relay_label(<<"wss://example.com/private/path?token=supersecret">>),
    ?assertEqual(nomatch, binary:match(Label, <<"supersecret">>)),
    ?assertEqual(nomatch, binary:match(Label, <<"private">>)).
ui_status_is_cached_test() ->
    {reply, Status, _} = erm_lens_ui:handle_call(status, self(), ui_state()),
    ?assertEqual(true, maps:get(shown_is_cached, Status)),
    ?assertEqual(not_probed, maps:get(backend, Status)).
ui_feed_failure_preserves_cards_test() ->
    S = ui_state(), Result = erm_lens_ui:render(S),
    ?assertEqual(maps:get(cards, S), maps:get(cards, Result)).
ui_failed_navigation_preserves_page_test() ->
    S = ui_state(), Result = erm_lens_ui:action(next, S),
    ?assertEqual(0, maps:get(page, Result)),
    ?assertEqual(maps:get(cards, S), maps:get(cards, Result)).
ui_uncertainty_requires_explicit_ack_test() ->
    S = (ui_state())#{wallet_outcome_unknown := true},
    {reply, ok, S1} = erm_lens_ui:handle_call(acknowledge_wallet_check, self(), S),
    ?assertEqual(false, maps:get(wallet_outcome_unknown, S1)).
ui_busy_confirmation_preserves_intent_test() ->
    P = prepared(), Id = maps:get(request_id, maps:get(request, P)),
    S = (ui_state())#{job := #{pid => self()}, pending_tip := P},
    Result = erm_lens_ui:action({confirm_tip, Id}, S),
    ?assertEqual(P, maps:get(pending_tip, Result)).
