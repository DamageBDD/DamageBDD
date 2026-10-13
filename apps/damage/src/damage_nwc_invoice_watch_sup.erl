-module(damage_nwc_invoice_watch_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    restore_open_invoices/0,
    init/1
]).

-include_lib("kernel/include/logger.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },

    Children = [
        #{
            id => damage_nwc_invoice_watch,
            start => {damage_nwc_invoice_watch, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [damage_nwc_invoice_watch]
        }
    ],

    {ok, {SupFlags, Children}}.

restore_open_invoices() ->
    case whereis(damage_nwc_invoice_watch) of
        undefined ->
            ?LOG_WARNING("invoice watch restore skipped: watcher not started"),
            {error, watcher_not_started};
        _Pid ->
            gen_server:call(damage_nwc_invoice_watch, restore_open_invoices, 30000)
    end.
