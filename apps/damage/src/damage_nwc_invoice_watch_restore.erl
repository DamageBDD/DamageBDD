-module(damage_nwc_invoice_watch_restore).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-define(RETRY_MS, 3000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:send_after(0, self(), restore),
    {ok, #{}}.

handle_info(restore, State) ->
    case damage_nwc_invoice_watch_sup:restore_open_invoices() of
        ok ->
            {noreply, State};
        {error, cln_not_started} ->
            erlang:send_after(?RETRY_MS, self(), restore),
            {noreply, State};
        {error, Why} ->
            ?LOG_WARNING("invoice restore retry after error: ~p", [Why]),
            erlang:send_after(?RETRY_MS, self(), restore),
            {noreply, State}
    end;
handle_info(_, State) ->
    {noreply, State}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
