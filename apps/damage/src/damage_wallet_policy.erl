%% A wallet login is proof of identity, NOT authority to use a custodial key.
-module(damage_wallet_policy).
-export([allowed/3, capabilities/1, rejection/0]).

allowed(_Method, _Path, Mode) when Mode =/= wallet -> true;
allowed(<<"GET">>, Path, wallet) ->
    lists:member(trim(Path), [
        <<"/">>,
        <<"/accounts/session">>,
        <<"/accounts/balance">>,
        <<"/accounts/wallet">>,
        <<"/ai/bdd/catalog">>,
        <<"/version">>,
        <<"/ecai/auth/session">>,
        <<"/api/themes/order">>
    ]);
allowed(<<"POST">>, Path, wallet) ->
    lists:member(trim(Path), [
        <<"/ai/bdd/generate">>,
        <<"/ai/bdd/validate">>,
        <<"/ai/bdd/cancel">>,
        <<"/accounts/session/logout">>,
        <<"/accounts/logout">>,
        <<"/api/themes/buy/sats">>,
        <<"/api/themes/buy/damage">>,
        <<"/api/themes/order/settle">>
    ]);
allowed(_, _, wallet) ->
    false.
trim(<<"/">>) -> <<"/">>;
trim(Path) -> string:trim(Path, trailing, "/").

capabilities(wallet) ->
    #{
        author_features => true,
        generate_bdd => true,
        validate_bdd => true,
        read_balances => true,
        receive_tokens => true,
        execute => false,
        transfer => false,
        schedules => false,
        account_context => false,
        nwc => false,
        billing => false,
        reason =>
            <<"Wallet sign-in is available. Paid execution, transfers, schedules, account-context and NWC changes need a verified user-signing flow that is not yet available here. Use your wallet app for transfers; use a separate email account for managed execution.">>
    };
capabilities(_) ->
    %% These indicate the authentication path, not balance, entitlement or node readiness.
    #{
        author_features => true,
        generate_bdd => true,
        validate_bdd => true,
        read_balances => true,
        receive_tokens => true,
        execute => true,
        transfer => true,
        schedules => true,
        account_context => true,
        nwc => true,
        billing => true,
        reason => <<"Managed operations remain subject to balance, role and service checks.">>
    }.
rejection() ->
    #{
        status => <<"unavailable">>,
        error => <<"wallet_operation_unavailable">>,
        message => maps:get(reason, capabilities(wallet))
    }.
