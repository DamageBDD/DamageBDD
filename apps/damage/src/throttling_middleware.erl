-module(throttling_middleware).

-behavior(cowboy_middleware).
-include_lib("kernel/include/logger.hrl").

-export([execute/2]).

execute(Req, Env) ->
    IP = damage_utils:get_ip(Req),

    case throttle:check(public_read, IP) of
        {limit_exceeded, _, _} ->
            ?LOG_WARNING("IP ~p exceeded api limit", [IP]),
            Req3 = cowboy_req:reply(429, Req),
            {stop, Req3};
        _ ->
            {ok, Req, Env}
    end.
