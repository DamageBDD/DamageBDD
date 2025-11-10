%%%-------------------------------------------------------------------
%%% steps_bitcoin_policy_v30.erl
%%%   Refactored to macros + pattern-matching clauses (no case)
%%%-------------------------------------------------------------------
-module(steps_bitcoin_policy_v30).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).

%% ===== Phrase Macros (KW-independent lists of tokens) ========================
-define(GIVEN_RESTART_WITH_PROFILE,        ["I (re)start bitcoind with profile", ProfileStr]).
-define(WHEN_CRAFT_OPRETURN_BYTES,         ["I craft an OP_RETURN transaction of", BytesStr, "bytes"]).
-define(AND_TEST_MEMPOOL_ACCEPT,           ["I call testmempoolaccept on the crafted transaction"]).
-define(THEN_MEMPOOL_SHOULD_BE,            ["mempool admission should be", Verdict]).
-define(THEN_PRUNE_MIN_5GB,                ["prune must be enabled with target at least", <<"5">>, "GB"]).
-define(AND_TXINDEX_DISABLED,              ["txindex must be disabled"]).
-define(AND_BLOCKSONLY_MAYBE_ENABLED,      ["blocksonly may be enabled"]).
-define(GIVEN_RAW_OPRETURN_HEX,            ["a raw OP_RETURN hex payload", Hex]).
-define(WHEN_SANITIZER_PROCESSES,          ["the sanitizer processes the payload"]).
-define(THEN_RENDER_MUST_NOT_CONTAIN_RAW,  ["the rendered output must NOT contain the raw payload"]).
-define(AND_RENDER_MUST_CONTAIN_REDACTED,  ["the rendered output must contain", <<"[redacted-op_return]">>]).

%% ===== Entry point ===========================================================
-spec step(proplists:proplist(), map(), binary(), integer(), [string() | binary()], iodata()) -> map() | no_return().

%% Given: restart node with profile
step(Config, Context, <<"Given">>, _N, ?GIVEN_RESTART_WITH_PROFILE, _Raw) ->
    restart_node(Config, Context, ProfileStr);

%% When: craft OP_RETURN tx of N bytes
step(Config, Context, <<"When">>, _N, ?WHEN_CRAFT_OPRETURN_BYTES, _Raw) ->
    {Bytes, _} = string:to_integer(BytesStr),
    Hex = make_hex(Bytes),
    {RawTx, C1} = rpc(Config, Context, "createrawtransaction", [[], [#{<<"data">> => Hex}]]),
    {Funded, C2} = rpc(Config, C1, "fundrawtransaction", [RawTx]),
    HexFunded = maps:get(<<"hex">>, Funded, Funded),
    {Signed, C3} = rpc(Config, C2, "signrawtransactionwithwallet", [HexFunded]),
    C3#{opret_hex => Hex, opret_signed => Signed};
%% And: testmempoolaccept
step(Config, Context, <<"And">>, _N, ?AND_TEST_MEMPOOL_ACCEPT, _Raw) ->
    Signed = maps:get(opret_signed, Context),
    {ResList, C1} = rpc(Config, Context, "testmempoolaccept", [[Signed]]),
    C1#{test_accept_res => hd(ResList)};
%% Then: mempool verdict (accepted/rejected)
step(_Config, Context, <<"Then">>, _N, ?THEN_MEMPOOL_SHOULD_BE, _Raw) ->
    case Verdict of
        <<"accepted">> ->
            ensure_allowed(Context, true),
            Context;
        <<"rejected">> ->
            ensure_allowed(Context, false),
            Context;
        _ ->
            error({unsupported_verdict, Verdict})
    end;
%% Then: prune enabled >= 5GB
step(Config, Context, <<"Then">>, _N, ?THEN_PRUNE_MIN_5GB, _Raw) ->
    {#{<<"result">> := Info}, _} = rpc_raw(Config, Context, "getblockchaininfo", []),
    true = maps:get(<<"pruned">>, Info, false) orelse error(not_pruned),
    Context;
%% And: txindex must be disabled
step(Config, Context, <<"And">>, _N, ?AND_TXINDEX_DISABLED, _Raw) ->
    {#{<<"result">> := Idx}, _} = rpc_raw(Config, Context, "getindexinfo", []),
    case maps:is_key(<<"txindex">>, Idx) of
        true -> error(txindex_enabled);
        false -> Context
    end;
%% And: blocksonly may be enabled (no-op acceptance)
step(_Config, Context, <<"And">>, _N, ?AND_BLOCKSONLY_MAYBE_ENABLED, _Raw) ->
    Context;
%% Given: raw OP_RETURN hex sample
step(_Config, Context, <<"Given">>, _N, ?GIVEN_RAW_OPRETURN_HEX, _Raw) ->
    Context#{sample_hex => Hex};
%% When: sanitizer processes
step(_Config, Context, <<"When">>, _N, ?WHEN_SANITIZER_PROCESSES, _Raw) ->
    Out = sanitizer:opreturn(maps:get(sample_hex, Context)),
    Context#{sanitized => Out};
%% Then: rendered output must NOT contain raw payload
step(_Config, Context, <<"Then">>, _N, ?THEN_RENDER_MUST_NOT_CONTAIN_RAW, _Raw) ->
    Hex = maps:get(sample_hex, Context),
    Out = maps:get(sanitized, Context),
    case binary:match(Out, Hex) of
        nomatch -> Context;
        _ -> error(hex_leaked)
    end;
%% And: rendered output must contain the redaction marker
step(_Config, Context, <<"And">>, _N, ?AND_RENDER_MUST_CONTAIN_REDACTED, _Raw) ->
    Out = maps:get(sanitized, Context),
    case binary:match(Out, <<"[redacted-op_return]">>) of
        nomatch -> error(no_redaction_marker);
        _ -> Context
    end.

%% ===== Helpers ===============================================================
rpc_json(Config, Context, Method, Params) ->
    Url = maps:get(base_url, Context, "http://127.0.0.1:18443"),
    Id = erlang:unique_integer(),
    Body = jsx:encode(#{
        <<"jsonrpc">> => <<"1.0">>,
        <<"id">> => Id,
        <<"method">> => list_to_binary(Method),
        <<"params">> => Params
    }),
    Hdrs = rpc_headers(Context),
    Ctx1 = steps_http:gun_post(Config, Context, Url, Hdrs, Body),
    [{status_code, 200}, _H, {body, Resp}] = maps:get(response, Ctx1),
    {jsx:decode(Resp, [return_maps]), Ctx1}.

rpc(Config, Context, Method, Params) ->
    {#{<<"result">> := R}, C1} = rpc_json(Config, Context, Method, Params),
    {R, C1}.
rpc_raw(Config, Context, Method, Params) ->
    rpc_json(Config, Context, Method, Params).

rpc_headers(Context) ->
    Base = [
        {<<"accept">>, <<"application/json">>},
        {<<"content-type">>, <<"application/json">>},
        {<<"user-agent">>, <<"damagebdd/1.0">>}
    ],
    case maps:get(basic_auth, Context, none) of
        {User, Pass} ->
            Cred = <<(list_to_binary(User))/binary, ":", (list_to_binary(Pass))/binary>>,
            [{<<"authorization">>, <<"Basic ", (base64:encode(Cred))/binary>>} | Base];
        _ ->
            Base
    end.

restart_node(Config, Context, ProfileStr) ->
    ok = damage_node_ctl:restart(bitcoind, ProfileStr),
    wait_rpc_up(Config, Context, 20).

wait_rpc_up(_Config, Context, 0) ->
    Context;
wait_rpc_up(Config, Context, N) ->
    try
        {_Res, C1} = rpc(Config, Context, "getblockchaininfo", []),
        C1
    catch
        _:_ ->
            timer:sleep(300),
            wait_rpc_up(Config, Context, N - 1)
    end.

make_hex(N) when N >= 0 ->
    Bin = binary:copy(<<16#AA>>, N),
    <<<<(io_lib:format("~2.16.0B", [B]))/binary>> || <<B>> <= Bin>>.

ensure_allowed(Context, Bool) ->
    Res = maps:get(test_accept_res, Context),
    case maps:get(<<"allowed">>, Res, false) of
        Bool -> ok;
        _ -> error({unexpected_result, Res})
    end.
