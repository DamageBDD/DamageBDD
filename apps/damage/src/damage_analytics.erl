%%%-------------------------------------------------------------------
%%% Dashboard analytics configuration.
%%%
%%% Verification evidence itself remains public/on-chain and is read through
%%% damage_run_history_http. This endpoint only supplies deployment-specific
%%% identifiers to the authenticated dashboard so the browser never needs a
%%% hard-coded contract or middleware origin.
%%%-------------------------------------------------------------------
-module(damage_analytics).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-export([trails/0, init/2, allowed_methods/2, content_types_provided/2, is_authorized/2, to_json/2]).

-include_lib("damage.hrl").

trails() ->
    [
        trails:trail(
            "/api/analytics/config",
            ?MODULE,
            #{action => config},
            #{get => #{tags => ["Analytics"],
                       description => "Deployment configuration for the authenticated analytics dashboard.",
                       produces => ["application/json"]}}
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.
allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.
content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.
is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

to_json(Req0, #{action := config} = State) ->
    Req = cowboy_req:set_resp_header(<<"cache-control">>, <<"private, max-age=30">>, Req0),
    Account = maps:get(public_key, State, <<>>),
    Body = #{
        status => <<"ok">>,
        account => damage_utils:to_bin(Account),
        node => node_account(),
        token_contract => damage_utils:to_bin(?DAMAGE_TOKEN_CONTRACT),
        window_days => 30,
        page_limit => 100,
        max_pages => 4
    },
    {jsx:encode(Body), Req, State}.

node_account() ->
    case application:get_env(damage, run_history_node_account, undefined) of
        Account when is_binary(Account), Account =/= <<>> -> Account;
        Account when is_list(Account), Account =/= [] -> unicode:characters_to_binary(Account);
        _ ->
            try secrets:node_keypair() of
                #{public_key := PublicKey} -> damage_utils:to_bin(PublicKey);
                _ -> <<>>
            catch
                _:_ -> <<>>
            end
    end.
