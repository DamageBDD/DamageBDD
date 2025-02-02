-module(steps_fail2ban_es).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("damage.hrl").

-export([step/6]).

step(
    Config,
    Context,
    KeyWord,
    _N,
    ["He configurado la lista de exclusión de IP a"],
    Body
) ->
    step(Config, Context, KeyWord, _N, ["I set the IP exclusion list to"], Body);
step(
    Config,
    Context,
    <<"Then">>,
    N,
    ["la IP debe ser prohibida por", BanTime, "segundos"],
    Body
) ->
    step(
        Config,
        Context,
        <<"Then">>,
        N,
        ["the IP must be banned for", BanTime, "seconds"],
        Body
    );
step(
    Config,
    Context,
    KeyWord,
    _N,
    [
        "la IP ha realizado más de",
        NumRequests,
        "solicitudes con estado",
        Status,
        "en los últimos",
        SinceSeconds,
        "segundos"
    ],
    Body
) ->
    step(
        Config,
        Context,
        KeyWord,
        _N,
        [
            "the IP has made more than",
            NumRequests,
            "requests with status",
            Status,
            "in the last",
            SinceSeconds,
            "seconds"
        ],
        Body
    ).
