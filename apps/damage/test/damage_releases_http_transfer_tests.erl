-module(damage_releases_http_transfer_tests).
-include_lib("eunit/include/eunit.hrl").
-define(H, damage_releases_http).

req(Headers) -> #{headers => Headers, qs => <<>>}.

cookie_only_cannot_authorize_test() ->
    Req = req(#{<<"cookie">> => <<"sessionid=secret">>}),
    ?assertEqual({error, unauthorized, Req},
        ?H:authorize_transfer(Req, #{action => transfer},
            fun(_, _) -> error(auth_must_not_run) end)).

query_token_only_cannot_authorize_test() ->
    Req = (req(#{}))#{qs => <<"access_token=secret">>},
    ?assertEqual({error, unauthorized, Req},
        ?H:authorize_transfer(Req, #{}, fun(_, _) -> error(auth_must_not_run) end)).

query_token_with_bearer_rejected_test() ->
    Req = (req(#{<<"authorization">> => <<"Bearer valid">>}))#{qs => <<"access_token=other">>},
    ?assertEqual({error, invalid_request, Req},
        ?H:authorize_transfer(Req, #{}, fun(_, _) -> error(auth_must_not_run) end)).

malformed_headers_do_not_fall_back_test() ->
    lists:foreach(fun(Header) ->
        Req = req(#{<<"authorization">> => Header, <<"cookie">> => <<"sessionid=valid">>}),
        ?assertEqual({error, unauthorized, Req},
            ?H:authorize_transfer(Req, #{}, fun(_, _) -> error(auth_must_not_run) end))
    end, [<<"Bearer ">>, <<"Bearer null">>, <<"Bearer a b">>, <<"Basic abc">>,
          <<"Nostr abc">>, <<"Bearer abc, Bearer def">>]).

bearer_uses_fresh_transfer_auth_state_test() ->
    Req = req(#{<<"authorization">> => <<"Bearer token+/==">>}),
    Auth = fun(R, State) ->
        ?assertEqual(#{action => transfer}, State),
        {true, R#{authenticated => true}, #{public_key => <<"ak_real">>}}
    end,
    ?assertEqual({ok, Req#{authenticated => true}, #{public_key => <<"ak_real">>}},
        ?H:authorize_transfer(Req, #{action => tx, public_key => <<"ak_forged">>}, Auth)).

auth_exception_is_sanitized_test() ->
    Req = req(#{<<"authorization">> => <<"Bearer token">>}),
    ?assertEqual({error, auth_unavailable, Req},
        ?H:authorize_transfer(Req, #{}, fun(_, _) -> error({secret, binary:copy(<<1>>, 64)}) end)).

application_json_only_test() ->
    ?assertEqual(ok, ?H:transfer_content_type(req(#{<<"content-type">> => <<"application/json">>}))),
    ?assertEqual(ok, ?H:transfer_content_type(req(#{<<"content-type">> => <<"application/json; charset=utf-8">>}))),
    lists:foreach(fun(Headers) ->
        ?assertEqual({error, unsupported_media_type}, ?H:transfer_content_type(req(Headers)))
    end, [#{}, #{<<"content-type">> => <<"text/plain">>},
          #{<<"content-type">> => <<"application/x-www-form-urlencoded">>},
          #{<<"content-type">> => <<"application/json">>, <<"content-encoding">> => <<"gzip">>}]).

reader(Parts) ->
    fun(Req, Opts) ->
        Index = maps:get(part, Req, 0) + 1,
        ?assert(maps:get(timeout, Opts) > maps:get(period, Opts)),
        ?assert(maps:get(length, Opts) > 0),
        {Tag, Bytes} = lists:nth(Index, Parts),
        {Tag, Bytes, Req#{part => Index, read_opts => Opts}}
    end.

fragmented_body_is_not_too_large_test() ->
    {ok, Json, Req} = ?H:read_transfer_body(#{},
        reader([{more, <<"{\"to\":" >>}, {more, <<"\"ak_destination\"">>}, {ok, <<"}">>}]),
        fun() -> 0 end),
    ?assertEqual(#{<<"to">> => <<"ak_destination">>}, Json),
    ?assertEqual(3, maps:get(part, Req)).

oversized_final_chunk_test() ->
    ?assertMatch({error, payload_too_large, #{part := 1}},
        ?H:read_transfer_body(#{}, reader([{ok, binary:copy(<<" ">>, 4097)}]), fun() -> 0 end)).

oversized_more_chunk_test() ->
    ?assertMatch({error, payload_too_large, #{part := 1}},
        ?H:read_transfer_body(#{}, reader([{more, binary:copy(<<" ">>, 4097)}]), fun() -> 0 end)).

cumulative_size_limit_test() ->
    ?assertMatch({error, payload_too_large, #{part := 2}},
        ?H:read_transfer_body(#{},
            reader([{more, binary:copy(<<" ">>, 3000)}, {ok, binary:copy(<<" ">>, 1097)}]),
            fun() -> 0 end)).

exact_limit_and_empty_final_chunk_test() ->
    Json = <<"{\"to\":\"ak_destination\"}">>,
    Full = <<Json/binary, (binary:copy(<<" ">>, 4096-byte_size(Json)))/binary>>,
    {ok, _, Req} = ?H:read_transfer_body(#{},
        reader([{more, Full}, {ok, <<>>}]), fun() -> 0 end),
    ?assertEqual(1, maps:get(length, maps:get(read_opts, Req))).

read_exception_preserves_latest_request_test() ->
    Read = fun
        (#{part := 1}, _) -> exit({request_error, timeout, 'read timeout'});
        (Req, _) -> {more, <<"{">>, Req#{part => 1}}
    end,
    ?assertEqual({error, body_timeout, #{part => 1}},
        ?H:read_transfer_body(#{}, Read, fun() -> 0 end)).

single_deadline_does_not_restart_per_chunk_test() ->
    Ref = make_ref(),
    put(Ref, [0, 0, 1000, 4999, 5000]),
    Now = fun() -> [T | Rest] = get(Ref), put(Ref, Rest), T end,
    try
        ?assertMatch({error, body_timeout, #{part := 2}},
            ?H:read_transfer_body(#{}, reader([{more, <<"{">>}, {more, <<" ">>}]), Now)),
        ?assertEqual([], get(Ref))
    after erase(Ref) end.

non_object_and_invalid_json_test() ->
    lists:foreach(fun(Body) ->
        ?assertMatch({error, invalid_json, _},
            ?H:read_transfer_body(#{}, reader([{ok, Body}]), fun() -> 0 end))
    end, [<<>>, <<"{">>, <<"[]">>, <<"null">>, <<"42">>]).

sender_and_extra_body_fields_rejected_test() ->
    ?assertEqual({error, invalid_transfer_body},
        ?H:transfer_body(#{<<"to">> => <<"ak_recipient">>, <<"from">> => <<"ak_other">>})),
    ?assertEqual({error, invalid_transfer_body},
        ?H:transfer_body(#{<<"to">> => <<"ak_recipient">>, <<"private_key">> => <<"secret">>})),
    ?assertEqual({ok, <<"ak_recipient">>}, ?H:transfer_body(#{<<"to">> => <<"ak_recipient">>})).

canonical_token_id_test() ->
    ?assertEqual({ok, 42}, ?H:parse_token(<<"42">>)),
    lists:foreach(fun(Token) ->
        ?assertEqual({error, invalid_release_token}, ?H:parse_token(Token))
    end, [<<"0">>, <<"-1">>, <<"+1">>, <<"01">>, <<"1.0">>, <<"1 ">>, <<>>,
          binary:copy(<<"1">>, 40)]).

custodial_account_mismatch_never_signs_test() ->
    Lookup = fun(_) -> {<<"ak_other">>, ignored, binary:copy(<<1>>, 64)} end,
    Transfer = fun(_, _, _) -> error(must_not_sign) end,
    ?assertEqual({error, transfer_signing_unavailable},
        ?H:custodial_transfer(<<"ak_owner">>, <<"user">>, {42, <<"ak_to">>}, Lookup, Transfer)).

custodial_transfer_uses_authenticated_key_only_test() ->
    Lookup = fun(<<"user">>) -> {<<"ak_owner">>, ignored, binary:copy(<<1>>, 64)} end,
    Transfer = fun(KP, Token, To) ->
        ?assertEqual(#{public_key => <<"ak_owner">>, private_key => binary:copy(<<1>>, 64)}, KP),
        ?assertEqual({42, <<"ak_to">>}, {Token, To}),
        {ok, #{status => submitted, tx_hash => <<"th_known">>}}
    end,
    ?assertMatch({ok, #{status := submitted}},
        ?H:custodial_transfer(<<"ak_owner">>, <<"user">>, {42, <<"ak_to">>}, Lookup, Transfer)).

write_exception_is_not_signing_unavailable_test() ->
    Lookup = fun(_) -> {<<"ak_owner">>, ignored, binary:copy(<<1>>, 64)} end,
    ?assertEqual({error, transfer_outcome_unknown},
        ?H:custodial_transfer(<<"ak_owner">>, <<"user">>, {42, <<"ak_to">>}, Lookup,
            fun(_, _, _) -> exit(after_broadcast) end)).

outcomes_keep_hash_and_do_not_leak_internal_fields_test() ->
    lists:foreach(fun({State, ExpectedStatus}) ->
        Outcome = #{status => State, tx_hash => <<"th_known">>, private_key => binary:copy(<<1>>, 64)},
        {Status, Headers, Body, request} = ?H:executed_transfer_response(
            {ok, Outcome}, <<"ak_from">>, 42, <<"ak_to">>, request),
        ?assertEqual(ExpectedStatus, Status),
        ?assertEqual(<<"no-store">>, maps:get(<<"cache-control">>, Headers)),
        Decoded = jsx:decode(Body, [return_maps]),
        ?assertEqual(atom_to_binary(State, utf8), maps:get(<<"status">>, Decoded)),
        ?assertEqual(<<"th_known">>, maps:get(<<"tx_hash">>, Decoded)),
        ?assertEqual(nomatch, binary:match(Body, <<"private_key">>))
    end, [{confirmed, 200}, {submitted, 202}, {submission_unknown, 202}]).

mined_revert_returns_hash_and_conflict_test() ->
    Rejected = #{status => rejected, tx_hash => <<"th_known">>, reason => <<"RAW SECRET">>},
    {409, _, Body, request} = ?H:executed_transfer_response(
        {error, {release_transfer_rejected, Rejected}}, <<"ak_from">>, 42, <<"ak_to">>, request),
    ?assertEqual(<<"th_known">>, maps:get(<<"tx_hash">>, jsx:decode(Body, [return_maps]))),
    ?assertEqual(nomatch, binary:match(Body, <<"RAW SECRET">>)).

unknown_process_outcome_not_rejected_test() ->
    {503, _, Body, request} = ?H:executed_transfer_response(
        {error, transfer_outcome_unknown}, <<"ak_from">>, 42, <<"ak_to">>, request),
    ?assertEqual(<<"outcome_unknown">>, maps:get(<<"status">>, jsx:decode(Body, [return_maps]))).

unclassified_ok_is_not_reported_as_confirmed_test() ->
    ?assertMatch({503, _, _, _}, ?H:executed_transfer_response(
        {ok, #{}}, <<"ak_from">>, 42, <<"ak_to">>, request)).

short_custodial_key_never_reaches_transfer_test() ->
    ?assertEqual({error, transfer_signing_unavailable},
        ?H:custodial_transfer(<<"ak_owner">>, <<"user">>, {42, <<"ak_to">>},
            fun(_) -> {<<"ak_owner">>, ignored, <<0:256>>} end,
            fun(_, _, _) -> error(must_not_sign) end)).

empty_partial_chunks_do_not_invalidate_json_test() ->
    {ok, Json, Req} = ?H:read_transfer_body(#{},
        reader([{more, <<>>}, {more, <<>>}, {ok, <<"{\"to\":\"ak_destination\"}">>}]),
        fun() -> 0 end),
    ?assertEqual(#{<<"to">> => <<"ak_destination">>}, Json),
    ?assertEqual(3, maps:get(part, Req)).

nested_cowboy_read_timeout_preserves_request_test() ->
    Read = fun
        (#{part := 1}, _) -> exit({request_error, {timeout, read_body}, 'read timeout'});
        (Req, _) -> {more, <<"{">>, Req#{part => 1}}
    end,
    ?assertEqual({error, body_timeout, #{part => 1}},
        ?H:read_transfer_body(#{}, Read, fun() -> 0 end)).

node_rejection_is_202_with_safe_submission_details_test() ->
    Submission = #{stage => submission, status => node_rejected, http_status => 400,
                   error_code => <<"nonce_too_high">>, response => <<"SECRET">>,
                   reason => <<"SECRET">>, headers => [secret]},
    O = #{status => submission_unknown, tx_hash => <<"th_local">>, submission => Submission},
    {202, _, Body, request} = ?H:executed_transfer_response(
        {ok, O}, <<"ak_from">>, 42, <<"ak_to">>, request),
    Json = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"submission_unknown">>, maps:get(<<"status">>, Json)),
    ?assertEqual(<<"th_local">>, maps:get(<<"tx_hash">>, Json)),
    ?assertEqual(#{<<"stage">> => <<"submission">>, <<"status">> => <<"node_rejected">>,
                  <<"http_status">> => 400, <<"error_code">> => <<"nonce_too_high">>},
                 maps:get(<<"submission">>, Json)),
    ?assertEqual(nomatch, binary:match(Body, <<"SECRET">>)).

http_reallowlists_diagnostic_values_test() ->
    D = #{stage => submission, status => http_error, error_code => <<"PRIVATE_ERROR">>,
          http_status => <<"PRIVATE_STATUS">>, private_key => <<"SECRET">>},
    O = #{status => submission_unknown, tx_hash => <<"th_local">>, submission => D},
    {202, _, Body, request} = ?H:executed_transfer_response(
        {ok, O}, <<"ak_from">>, 42, <<"ak_to">>, request),
    Json = jsx:decode(Body, [return_maps]),
    ?assertEqual(#{<<"stage">> => <<"submission">>, <<"status">> => <<"http_error">>,
                  <<"error_code">> => <<"unknown_error">>}, maps:get(<<"submission">>, Json)),
    ?assertEqual(nomatch, binary:match(Body, <<"PRIVATE">>)),
    ?assertEqual(nomatch, binary:match(Body, <<"SECRET">>)).

confirmed_receipt_keeps_local_submission_diagnostic_test() ->
    O = #{status => confirmed, tx_hash => <<"th_local">>,
          submission => #{stage => submission, status => node_rejected,
                          error_code => <<"nonce_too_low">>, http_status => 400}},
    {200, _, Body, request} = ?H:executed_transfer_response(
        {ok, O}, <<"ak_from">>, 42, <<"ak_to">>, request),
    Json = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"confirmed">>, maps:get(<<"status">>, Json)),
    ?assertEqual(<<"node_rejected">>, maps:get(<<"status">>, maps:get(<<"submission">>, Json))).

malformed_submission_diagnostic_is_omitted_test_() ->
    [?_test(begin
        O = #{status => submitted, tx_hash => <<"th_local">>, submission => D},
        {202, _, Body, request} = ?H:executed_transfer_response(
            {ok, O}, <<"ak_from">>, 42, <<"ak_to">>, request),
        ?assertNot(maps:is_key(<<"submission">>, jsx:decode(Body, [return_maps])))
    end) || D <- [<<"SECRET">>, #{}, #{stage => private_key, status => node_rejected},
                   #{stage => submission, status => <<"PRIVATE">>}]].

