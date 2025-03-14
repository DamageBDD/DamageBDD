-module(steps_ae).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("damage.hrl").

-export([step/6]).
-export([test_get_last_test_status/0]).

step(
    _Config,
    #{ae_account := AeAccount} = Context,
    _,
    _N,
    [
        "test case",
        FeatureHash,
        "status was",
        Status,
        "in the last",
        Hours,
        "hours"
    ],
    _
) ->
    case
        get_last_test_status(
            AeAccount,
            list_to_binary(FeatureHash),
            list_to_integer(Hours)
        )
    of
        Status ->
            Context;
        UnExpected ->
            Msg =
                damage_utils:strf(
                    "Unexpected status ~p expected ~p",
                    [UnExpected, Status]
                ),
            maps:put(fail, Msg, Context)
    end;
step(Config, Context, <<"And">>, _N, ["I am using ai ", AiProvider], Args) ->
    ?LOG_DEBUG("and config: ~p context: ~p  args: ~p", [Config, AiProvider, Args]),
    Context.

get_last_test_status(AeAccount, FeatureHash, Hours) ->
    ?LOG_DEBUG("Check balance ~p", [AeAccount]),
    DamageAEPid = damage_ae:get_wallet_proc(AeAccount),
    gen_server:call(
        DamageAEPid,
        {get_last_test_status, AeAccount, FeatureHash, Hours},
        ?AE_TIMEOUT
    ).

test_get_last_test_status() ->
    {ok, [NodeAdmin | _]} = application:get_env(damage, node_admins),
    %TestFeatureHash = <<"QmNPiDUFeGC6j35aBWNHSqgNLh5yXveLWoupzvrUwTWp4e">>,
    TestFeatureHash = <<"QmVZ3FApr4kwrnuPQVu3t1TQ2MSTz1L4PeFMymWqJ1TywF">>,
    Result = get_last_test_status(list_to_binary(NodeAdmin), TestFeatureHash, 36),
    ?LOG_INFO("Result ~p", [Result]).
