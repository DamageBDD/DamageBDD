%%%-------------------------------------------------------------------
%%%  x11_time.erl
%%%  Tally foreground time by X11 window class/title using hlwm events
%%%-------------------------------------------------------------------
-module(x11_time).
-behaviour(gen_server).

-export([start_link/1, get_or_start/1, stop/0]).
-export([summary/0, summary/1, reset/0, now/0]).
-export([add_alias/2, clear_alias/1]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("kernel/include/logger.hrl").
-define(NAME, {n, l, {?MODULE, monitor}}).

-record(state, {
    % #{class:=binary(), title:=binary(), winid:=binary()}
    current = undefined,
    % monotonic time (second)
    last_ts = 0,
    % #{<<"Emacs">> => Seconds, ...}
    by_class = #{},
    % #{<<"Emacs — foo.erl">> => Seconds, ...}
    by_title = #{},
    by_qual = #{},           % #{<<"Class|Title">> => Seconds}
    % #{<<"code">> => [<<"Code">>, <<"codium">>], ...}
    aliases = #{}
}).

%%% ========= Public API =========

get_or_start(Context) ->
    case gproc:lookup_local_name(?NAME) of
        undefined -> start_link(Context);
        Pid -> {ok, Pid}
    end.

start_link(_Ctx) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end.

summary() -> gen_server:call(?MODULE, {summary, 0}).
summary(_SinceSecs) ->
    %% For future: windowed summaries; keeping arg to keep API stable.
    gen_server:call(?MODULE, {summary, 0}).

reset() -> gen_server:call(?MODULE, reset).

add_alias(Alias, Classes) when is_list(Classes) ->
    gen_server:call(?MODULE, {add_alias, to_bin(Alias), [to_bin(C) || C <- Classes]}).
clear_alias(Alias) -> gen_server:call(?MODULE, {clear_alias, to_bin(Alias)}).

now() -> erlang:monotonic_time(second).

%%% ========= gen_server =========

init([]) ->
    process_flag(trap_exit, true),
    gproc:reg(?NAME),
    {ok, #state{last_ts = now()}}.
handle_call({summary, _Since}, _From, S=#state{by_class=BC, by_title=BT, by_qual=BQ, aliases=Aliases}) ->
    {reply, #{by_class => expand_aliases(BC, Aliases),
              by_title => BT,
              by_qual  => BQ}, S};
handle_call({summary, _Since}, _From, S = #state{by_class = BC, by_title = BT, aliases = Aliases}) ->
    {reply, #{by_class => expand_aliases(BC, Aliases), by_title => BT}, S};
handle_call(reset, _From, S) ->
    {reply, ok, S#state{by_class = #{}, by_title = #{}, last_ts = now()}};
handle_call({add_alias, A, Cs}, _F, S = #state{aliases = Al}) ->
    {reply, ok, S#state{aliases = Al#{A => Cs}}};
handle_call({clear_alias, A}, _F, S = #state{aliases = Al}) ->
    {reply, ok, S#state{aliases = maps:remove(A, Al)}};
handle_call(_Any, _From, S) ->
    {reply, ok, S}.

handle_cast({hlwm_event, Evt}, S0) ->
    S1 = maybe_roll_time(S0),
    S2 =
        case Evt of
            #{type := <<"focus_changed">>, class := Class, title := Title} ->
                S1#state{
                    current = #{
                        class => Class, title => Title, winid => maps:get(winid, Evt, <<>>)
                    },
                    last_ts = now()
                };
            #{type := <<"focus_changed">>, title := Title} ->
                %% Fall back if class missing
                S1#state{
                    current = #{class => <<"unknown">>, title => Title, winid => <<>>},
                    last_ts = now()
                };
            #{type := <<"window_title_changed">>, title := Title} ->
                %% Update title for current window without changing class
                case S1#state.current of
                    #{class := C} = Cur ->
                        S1#state{current = Cur#{title := Title}, last_ts = now()};
                    _ ->
                        S1
                end;
            _ ->
                S1
        end,
    {noreply, S2};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Info, S) -> {noreply, S}.

terminate(Reason, _S) ->
    ?LOG_INFO("x11_time terminates ~p", [Reason]),
    ok.

code_change(_V, S, _E) -> {ok, S}.

%%% ========= Internals =========

maybe_roll_time(S=#state{current=undefined}) -> S;
maybe_roll_time(S=#state{current=#{class := C, title := T}, last_ts=Last,
                         by_class=BC0, by_title=BT0, by_qual=BQ0}) ->
    Now = now(),
    Delta = max(0, Now - Last),
    BC = maps:update_with(C, fun(V)->V+Delta end, Delta, BC0),
    BT = maps:update_with(T, fun(V)->V+Delta end, Delta, BT0),
    K  = <<C/binary, "|", T/binary>>,
    BQ = maps:update_with(K, fun(V)->V+Delta end, Delta, BQ0),
    S#state{by_class=BC, by_title=BT, by_qual=BQ, last_ts=Now}.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

expand_aliases(BC, Aliases) ->
    maps:fold(
        fun(Alias, Classes, Acc) ->
            Sum = lists:sum([maps:get(C, BC, 0) || C <- Classes]),
            case Sum of
                0 -> Acc;
                _ -> Acc#{Alias => Sum}
            end
        end,
        BC,
        Aliases
    ).
