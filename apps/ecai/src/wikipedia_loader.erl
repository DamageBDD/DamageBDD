-module(wikipedia_loader).
-behaviour(gen_server).
-behaviour(poolboy_worker).
-include_lib("kernel/include/logger.hrl").

-export([
    set_file/3,
    pause/1,
    resume/1,
    skip/1,
    break/1
]).
-export([
    start_link/1,
    init/1,
    handle_info/2,
    handle_call/3,
    handle_cast/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    io_device,
    jsx_state,
    paused = false,
    skip_next = false,
    rate_limit
}).

%%% API %%%

start_link([]) -> gen_server:start_link(?MODULE, [], []).

pause(Pid) -> gen_server:cast(Pid, pause).
resume(Pid) -> gen_server:cast(Pid, resume).
skip(Pid) -> gen_server:cast(Pid, skip).
break(Pid) -> gen_server:cast(Pid, break).

%%% Init %%%
init(_Args) ->
    {ok, #state{io_device = undefined, jsx_state = undefined, rate_limit = 0}}.

%%% Tick Handler %%%
handle_call(Request, From, State) ->
    ?LOG_INFO("wikipedia loader call: ~p ~p~n", [Request, From]),
    {reply, ok, State}.

handle_info(tick, State = #state{paused = true}) ->
    schedule_next(State#state.rate_limit),
    {noreply, State};
handle_info(tick, State0 = #state{io_device = IO, jsx_state = JSX0, skip_next = Skip}) ->
    case file:read(IO, 4096) of
        {ok, Chunk} ->
            case jsx:decode(Chunk, JSX0) of
                {ok, Terms, JSX1} ->
                    if
                        Skip ->
                            schedule_next(State0#state.rate_limit),
                            {noreply, State0#state{jsx_state = JSX1, skip_next = false}};
                        true ->
                            lists:foreach(fun handle_json/1, Terms),
                            schedule_next(State0#state.rate_limit),
                            {noreply, State0#state{jsx_state = JSX1}}
                    end;
                {incomplete, JSX1} ->
                    schedule_next(State0#state.rate_limit),
                    {noreply, State0#state{jsx_state = JSX1}}
            end;
        eof ->
            file:close(IO),
            io:format("JSON stream complete.~n"),
            {stop, normal, State0}
    end;
handle_info(_, State) ->
    {noreply, State}.

%%% Control Commands %%%
handle_cast({set_file, FilePath, RateLimit}, State) ->
    % Close previous file if open
    case State#state.io_device of
        undefined -> ok;
        IO -> file:close(IO)
    end,

    case file:open(FilePath, [read, binary, raw]) of
        {ok, IO2} ->
            JSX = jsx:decoder([{stream, true}]),
            schedule_next(RateLimit),
            {noreply, State#state{
                io_device = IO2,
                jsx_state = JSX,
                paused = false,
                skip_next = false,
                rate_limit = RateLimit
            }};
        {error, Reason} ->
            io:format("Failed to open file: ~p~n", [Reason]),
            {noreply, State}
    end;
handle_cast(pause, State) ->
    {noreply, State#state{paused = true}};
handle_cast(resume, State) ->
    {noreply, State#state{paused = false}};
handle_cast(skip, State) ->
    {noreply, State#state{skip_next = true}};
handle_cast(break, State = #state{io_device = IO}) ->
    file:close(IO),
    {stop, normal, State}.

%%% Internal %%%

schedule_next(Rate) ->
    erlang:send_after(Rate, self(), tick).

handle_json(Json) ->
    io:format("Got JSON object: ~p~n", [Json]).

terminate(_Reason, #state{io_device = IO}) ->
    file:close(IO),
    ok.

code_change(_, State, _) -> {ok, State}.
set_file(Pid, FilePath, RateLimit) ->
    gen_server:cast(Pid, {set_file, FilePath, RateLimit}).
