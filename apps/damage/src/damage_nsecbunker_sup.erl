%%--------------------------------------------------------------------
%% damage_nsecbunker_sup
%%
%% In-tree supervisor. The managed custody owner is optional and starts only
%% when the configured secret provider requires it. Non-managed nodes retain
%% the historical local-secret worker tree with no AWS process or startup call.
%%
%% Option B live relay wiring:
%% - damage_nsecbunker_relay owns live relay subscribe/publish sockets
%% - damage_nostr_relay_client bridges inbound relay events to damage_nsecbunker
%% - relay adapter must start before relay bridge because the bridge may
%%   autosubscribe during init.
%% In-tree supervisor. rest_for_one ensures a failed custody port causes the
%% bunker and relay-facing children to restart after a fresh AWS bootstrap.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_sup).
-behaviour(supervisor).

-export([start_link/0, child_spec/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
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
    Config = damage_nsecbunker_config:load(),
    Children =
        case maps:get(enabled, Config, false) of
            true -> enabled_children(Config);
            _ -> []
        end,
    Strategy =
        case damage_nsecbunker_config:managed_secret_owner(Config) of
            true -> rest_for_one;
            false -> one_for_one
        end,
    {ok, {{Strategy, 5, 10}, Children}}.

enabled_children(Config) ->
    Base0 = [worker(damage_nsecbunker_replay), worker(damage_nsecbunker_rate)],
    Base1 =
        case damage_nsecbunker_config:managed_secret_owner(Config) of
            true -> Base0 ++ [secure_owner(Config)];
            false -> Base0
        end,
    Base = Base1 ++ [worker(damage_nsecbunker)],
    case maps:get(relay_client_enabled, Config, false) of
        true ->
            Base ++
                [
                    worker(damage_nsecbunker_relay),
                    worker(damage_nostr_relay_client)
                ];
        _ ->
            Base
    end.

secure_owner(Config) ->
    #{
        id => damage_nsecbunker_secret_owner,
        start => {damage_nsecbunker_secret_owner, start_link, [Config]},
        restart => permanent,
        shutdown => 20000,
        type => worker,
        modules => [damage_nsecbunker_secret_owner]
    }.

worker(Module) ->
    #{
        id => Module,
        start => {Module, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [Module]
    }.
