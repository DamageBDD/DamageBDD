-module(throttling_middleware).

-behavior(cowboy_middleware).
-include_lib("kernel/include/logger.hrl").

-export([execute/2]).

execute(Req, Env) ->
    IP = damage_utils:get_ip(Req),

    %% Load whitelist from sys.config (e.g. {ip_whitelist, ["127.0.0.1"]})
    Whitelist =
        case application:get_env(throttle, ip_whitelist) of
            {ok, List} when is_list(List) -> List;
            _ -> []
        end,

    %% Skip throttle if IP is whitelisted
    case lists:member(IP, Whitelist) of
        true ->
            {ok, Req, Env};
        false ->
            case throttle:check(public_read, IP) of
                {limit_exceeded, _, _} ->
                    ?LOG_WARNING("IP ~p exceeded api limit", [IP]),
                    Req3 = cowboy_req:reply(429, Req),
                    {stop, Req3};
                _ ->
                    {ok, Req, Env}
            end
    end.
