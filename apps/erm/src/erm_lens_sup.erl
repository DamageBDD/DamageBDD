%%%-------------------------------------------------------------------
%%% @doc Private supervision tree for ERM Lens.
%%%-------------------------------------------------------------------
-module(erm_lens_sup).
-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, start_link/1, init/1]).

start_link() ->
    C0 = application:get_env(erm, lens, #{}),
    ?LOG_WARNING(
        "erm_lens_sup:start_link/0 is a development convenience; prefer erm_lens:start/0 or erm_lens:show/0",
        []
    ),
    start_link(C0).

start_link(C0) ->
    case erm_lens_config:normalize(C0) of
        {ok, #{enabled := false}} -> {error, disabled};
        {ok, C} -> supervisor:start_link({local, ?MODULE}, ?MODULE, C);
        {error, _} = Error -> Error
    end.

init(C) when is_map(C) ->
    ?LOG_INFO(
        "Initializing ERM Lens workers relays=~p refresh_ms=~p load_images=~p",
        [
            length(maps:get(relays, C, [])),
            maps:get(refresh_ms, C, 60000),
            maps:get(load_images, C, true)
        ]
    ),
    Children = [
        child(erm_lens_feed, C),
        child(erm_lens_sync, C),
        child(erm_lens_media, C),
        child(erm_lens_ui, C)
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 30}, Children}};
init(Other) ->
    ?LOG_ERROR("Invalid ERM Lens supervisor configuration: ~p", [Other]),
    {stop, {bad_lens_config, Other}}.

child(M, C) ->
    #{
        id => M,
        start => {M, start_link, [C]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [M]
    }.
