%%--------------------------------------------------------------------
%% damage_nsecbunker_sup
%%
%% In-tree supervisor for the Damage NIP-46 nsec bunker.
%% Add damage_nsecbunker_sup:child_spec() to the existing damage_sup.
%% This is deliberately not a separate OTP application.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_sup).

-behaviour(supervisor).

-export([start_link/0, child_spec/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => supervisor,
        modules => [?MODULE]
    }.

init([]) ->
    Config = damage_nsecbunker:config(),
    Children =
        case maps:get(enabled, Config, false) of
            true -> enabled_children(Config);
            _ -> []
        end,
    {ok, {{one_for_one, 5, 10}, Children}}.

enabled_children(Config) ->
    Base = [
        worker(damage_nsecbunker_replay),
        worker(damage_nsecbunker_rate),
        worker(damage_nsecbunker)
    ],
    case maps:get(relay_client_enabled, Config, false) of
        true -> Base ++ [worker(damage_nostr_relay_client)];
        _ -> Base
    end.

worker(Module) ->
    #{
        id => Module,
        start => {Module, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [Module]
    }.
