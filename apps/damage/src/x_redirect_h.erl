%% x_redirect_h.erl
-module(x_redirect_h).
-behaviour(cowboy_handler).

-include_lib("kernel/include/logger.hrl").

-export([init/2]).

init(Req0, _Opts) ->
    %% Parse ?state=...&code=...
    #{state := State0, code := Code0} =
        cowboy_req:match_qs(
          [{state, [], undefined},
           {code,  [], undefined}],
          Req0),

    ?LOG_INFO("X OAuth redirect: state=~p code=~p", [State0, Code0]),

    Result = x_bridge:handle_oauth_redirect(State0, Code0),

    {Status, BodyBin} =
        case Result of
            ok ->
                {200, <<"X authorization successful. You can close this window.">>};
            {error, Reason} ->
                Msg = io_lib:format("X authorization failed: ~p", [Reason]),
                {400, iolist_to_binary(Msg)}
        end,

    Req1 = cowboy_req:reply(
             Status,
             #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
             BodyBin,
             Req0),
    {ok, Req1, _Opts}.
