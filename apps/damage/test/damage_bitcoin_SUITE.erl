-module(damage_bitcoin_SUITE).

-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all]).

%-export([all/0, suite/0, step_get_request/1]).
-define(CONFIG,).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).

all() -> [{group, crypto}].

groups() -> [{crypto, [parallel], [test_bitcoin_wallet]}].

init_per_group(_Name, Config) ->
    application:ensure_all_started(gun),
    Config.

end_per_group(_Name, _) -> ok.

init_per_suite(Config) -> Config.

end_per_suite(Config) -> Config.

test_bitcoin_wallet(Config) ->
    {ok, WalletName} = datestring:format("YmdHMS", erlang:localtime()),
    WalletPath =
        filename:join(
            os:getenv("HOME"),
            ".bitcoin/wallets/damage_test" ++ WalletName ++ "/"
        ),
    #{} =
        steps_bitcoin:step(
            Config,
            #{},
            given_keyword,
            0,
            ["I have loaded a bitcoin wallet from path", WalletPath],
            <<"">>
        ),
    #{} =
        steps_bitcoin:step(
            Config,
            #{},
            given_keyword,
            0,
            ["I have loaded a bitcoin wallet from path", WalletPath],
            <<"">>
        ).
