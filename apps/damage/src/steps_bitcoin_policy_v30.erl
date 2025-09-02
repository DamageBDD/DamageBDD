-module(steps_bitcoin_policy_v30).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export([step/6]).


%% single entry point—same signature as your dispatcher expects
step(Config, Context, KW, N, Phrase, Raw) ->
    case {KW, Phrase} of
        {<<"Given">>, ["I (re)start bitcoind with profile", ProfileStr]} ->
            restart_node(Config, Context, ProfileStr);

        {<<"When">>, ["I craft an OP_RETURN transaction of", BytesStr, "bytes"]} ->
            {Bytes, _} = string:to_integer(BytesStr),
            Hex = make_hex(Bytes),
            {Raw1, C1} = rpc(Config, Context, "createrawtransaction",
                             [[], [#{<<"data">> => Hex}]]),
            {Funded, C2} = rpc(Config, C1, "fundrawtransaction", [Raw1]),
            HexFunded    = maps:get(<<"hex">>, Funded, Funded),
            {Signed, C3} = rpc(Config, C2, "signrawtransactionwithwallet", [HexFunded]),
            C3#{opret_hex => Hex, opret_signed => Signed};

        {<<"And">>, ["I call testmempoolaccept on the crafted transaction"]} ->
            Signed = maps:get(opret_signed, Context),
            {ResList, C1} = rpc(Config, Context, "testmempoolaccept", [[Signed]]),
            C1#{test_accept_res => hd(ResList)};

        {<<"Then">>, ["mempool admission should be", <<"accepted">>]} ->
            ensure_allowed(Context, true), Context;
        {<<"Then">>, ["mempool admission should be", <<"rejected">>]} ->
            ensure_allowed(Context, false), Context;

        {<<"Then">>, ["prune must be enabled with target at least", <<"5">>, "GB"]} ->
            {#{<<"result">> := Info}, _} = rpc_raw(Config, Context, "getblockchaininfo", []),
            true = maps:get(<<"pruned">>, Info, false) orelse error(not_pruned),
            Context;

        {<<"And">>, ["txindex must be disabled"]} ->
            {#{<<"result">> := Idx}, _} = rpc_raw(Config, Context, "getindexinfo", []),
            case maps:is_key(<<"txindex">>, Idx) of
                true  -> error(txindex_enabled);
                false -> Context
            end;

        {<<"And">>, ["blocksonly may be enabled"]} ->
            Context;

        {<<"Given">>, ["a raw OP_RETURN hex payload", Hex]} ->
            Context#{sample_hex => Hex};
        {<<"When">>, ["the sanitizer processes the payload"]} ->
            Out = sanitizer:opreturn(maps:get(sample_hex, Context)),
            Context#{sanitized => Out};
        {<<"Then">>, ["the rendered output must NOT contain the raw payload"]} ->
            Hex = maps:get(sample_hex, Context),
            Out = maps:get(sanitized, Context),
            case binary:match(Out, Hex) of nomatch -> Context; _ -> error(hex_leaked) end;
        {<<"And">>, ["the rendered output must contain", <<"[redacted-op_return]">>]} ->
            Out = maps:get(sanitized, Context),
            case binary:match(Out, <<"[redacted-op_return]">>) of
                nomatch -> error(no_redaction_marker);
                _ -> Context
            end;

        _ -> error({unmatched_step, KW, Phrase, N, Raw})
    end.

%% --- helpers: delegate HTTP to your existing abstraction ---
rpc_json(Config, Context, Method, Params) ->
    Url     = maps:get(base_url, Context, "http://127.0.0.1:18443"),
    Id      = erlang:unique_integer(),
    BodyBin = jsx:encode(#{
        <<"jsonrpc">> => <<"1.0">>, <<"id">> => Id,
        <<"method">> => list_to_binary(Method), <<"params">> => Params}),
    Hdrs    = rpc_headers(Context),
    Ctx1    = steps_http:gun_post(Config, Context, Url, Hdrs, BodyBin),
    [{status_code, 200}, _H, {body, RespBody}] = maps:get(response, Ctx1),
    {jsx:decode(RespBody, [return_maps]), Ctx1}.

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
        _ -> Base
    end.

restart_node(Config, Context, ProfileStr) ->
    ok = damage_node_ctl:restart(bitcoind, ProfileStr),
    wait_rpc_up(Config, Context, 20).

wait_rpc_up(_Config, Context, 0) -> Context;
wait_rpc_up(Config, Context, N) ->
    try
        {_Res, C1} = rpc(Config, Context, "getblockchaininfo", []),
        C1
    catch _:_ ->
        timer:sleep(300), wait_rpc_up(Config, Context, N-1)
    end.

make_hex(N) when N >= 0 ->
    Bin = binary:copy(<<16#AA>>, N),
    << <<(io_lib:format("~2.16.0B", [B]))/binary>> || <<B>> <= Bin >>.

ensure_allowed(Context, Bool) ->
    Res = maps:get(test_accept_res, Context),
    case maps:get(<<"allowed">>, Res, false) of
        Bool -> ok;
        _    -> error({unexpected_result, Res})
    end.
