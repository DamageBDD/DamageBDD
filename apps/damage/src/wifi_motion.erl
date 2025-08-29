%% file: wifi_motion.erl
%% usage:
%%   c(wifi_motion).
%%   {ok, Pid} = wifi_motion:start_link(#{iface => "wlan0", interval_ms => 500, alpha => 0.2, k_sigma => 3.0}).
%%   %% Subscribe your process to receive motion events:
%%   wifi_motion:subscribe().

-module(wifi_motion).
-behaviour(gen_server).

-export([start_link/1, stop/0, subscribe/0, unsubscribe/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_IFACE, "wlan0").
-define(DEFAULT_INTERVAL, 500).
-define(DEFAULT_ALPHA, 0.2).
-define(DEFAULT_KSIGMA, 3.0).

-record(client, {mu = undefined, var = 0.0}).
-record(state, {
    iface,
    interval,
    alpha,
    k_sigma,
    table = #{} ,        %% MAC() -> #client{}
    subs  = []           %% Pids to receive motion msgs
}).

%% API
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

stop() ->
    gen_server:call(?MODULE, stop).

subscribe() ->
    gen_server:call(?MODULE, {sub, self()}).

unsubscribe() ->
    gen_server:call(?MODULE, {unsub, self()}).

%% gen_server
init(Opts) ->
    Iface     = maps:get(iface, Opts, ?DEFAULT_IFACE),
    Interval  = maps:get(interval_ms, Opts, ?DEFAULT_INTERVAL),
    Alpha     = maps:get(alpha, Opts, ?DEFAULT_ALPHA),
    KSigma    = maps:get(k_sigma, Opts, ?DEFAULT_KSIGMA),
    erlang:send_after(Interval, self(), tick),
    {ok, #state{iface=Iface, interval=Interval, alpha=Alpha, k_sigma=KSigma}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call({sub, Pid}, _From, State=#state{subs=Subs}) ->
    {reply, ok, State#state{subs=lists:usort([Pid|Subs])}};
handle_call({unsub, Pid}, _From, State=#state{subs=Subs}) ->
    {reply, ok, State#state{subs=lists:delete(Pid, Subs)}};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(tick, State0=#state{interval=I}) ->
    {State1, Events} = sample_and_update(State0),
    %% broadcast motion events
    lists:foreach(fun(Ev) -> notify(State1#state.subs, Ev) end, Events),
    erlang:send_after(I, self(), tick),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

notify(Subs, Ev) ->
    lists:foreach(fun(P) -> P ! Ev end, Subs).

%% Core
sample_and_update(State=#state{iface=Iface, alpha=Alpha, k_sigma=KSigma, table=Tab0}) ->
    %% Get map of MAC()->Signal (dBm) from iw text
    Readings = read_signals(Iface),
    {Tab1, Events} =
        maps:fold(
          fun(Mac, X, {AccTab, AccEv}) ->
                  {Entry1, MaybeEv} = update_stat(maps:get(Mac, AccTab, #client{}), X, Alpha, KSigma, Mac),
                  {maps:put(Mac, Entry1, AccTab),
                   case MaybeEv of none -> AccEv; Ev -> [Ev|AccEv] end}
          end,
          {Tab0, []}, Readings),
    {State#state{table=Tab1}, lists:reverse(Events)}.

update_stat(Entry=#client{mu=undefined}, X, _Alpha, _KSigma, _Mac) ->
    {Entry#client{mu=X, var=1.0}, none};
update_stat(Entry=#client{mu=Mu0, var=Var0}, X, Alpha, KSigma, Mac) ->
    %% EWMA mean and EWMA variance update
    Mu1  = (1.0-Alpha)*Mu0 + Alpha*X,
    D    = X - Mu0,
    Var1 = (1.0-Alpha)*(Var0 + Alpha*D*D),
    Sigma = math:sqrt(max(Var1, 1.0)), %% avoid zero
    Deviation = abs(X - Mu1),
    Ev = case Deviation > KSigma*Sigma of
             true  -> {motion, #{mac=>Mac, rssi=>X, mu=>Mu1, sigma=>Sigma, at=>os:system_time(millisecond)}};
             false -> none
         end,
    {Entry#client{mu=Mu1, var=Var1}, Ev}.

%% --- Collect RSSI via `iw`
read_signals(Iface) ->
    Cmd = io_lib:format("iw dev ~s station dump", [Iface]),
    Txt = os:cmd(lists:flatten(Cmd)),
    parse_iw_station_dump(Txt).

%% Parse lines like:
%% Station aa:bb:cc:dd:ee:ff (on wlan0)
%%     signal:     -58 [-61, -58] dBm
parse_iw_station_dump(Txt) ->
    Lines = string:split(Txt, "\n", all),
    parse_lines(Lines, undefined, #{}).

parse_lines([], _CurMac, Acc) -> Acc;
parse_lines([L|Ls], CurMac, Acc) ->
    case re:run(L, "Station\\s+([0-9a-f:]{17})", [{capture, [1], list}, unicode, caseless]) of
        {match, [Mac]} ->
            parse_lines(Ls, Mac, Acc);
        nomatch ->
            case {CurMac, re:run(L, "signal:\\s*(-?\\d+)", [{capture, [1], list}, unicode])} of
                {undefined, _} ->
                    parse_lines(Ls, CurMac, Acc);
                {Mac2, {match, [SigStr]}} ->
                    {ok, Sig} = string:to_integer(SigStr),
                    parse_lines(Ls, CurMac, maps:put(Mac2, Sig, Acc));
                _ ->
                    parse_lines(Ls, CurMac, Acc)
            end
    end.
