%%--------------------------------------------------------------------
%% ecai_log_group.erl
%%
%% Groups log lines into multiline events.
%% Useful for stack traces, exception dumps, Erlang crash reports,
%% Python tracebacks, Java exceptions, etc.
%%--------------------------------------------------------------------
-module(ecai_log_group).

-export([
    new/0,
    feed_line/2,
    flush/1,
    group_lines/1
]).

-record(group, {
    %% #{first_ts => binary(), lines => [binary()], count => integer()}
    current = undefined,
    max_lines = 200
}).

new() ->
    #group{}.

%% Feed one line at a time.
%% Return:
%%   {none, NewState}
%%   {{emit, EventBin}, NewState}
feed_line(Line0, State = #group{current = undefined}) ->
    Line = strip_cr(Line0),
    case is_blank(Line) of
        true ->
            {none, State};
        false ->
            Cur = new_event(Line),
            {none, State#group{current = Cur}}
    end;
feed_line(Line0, State = #group{current = Cur0, max_lines = Max}) ->
    Line = strip_cr(Line0),
    Lines0 = maps:get(lines, Cur0),
    Count0 = maps:get(count, Cur0),

    case should_start_new_event(Line, Cur0) of
        true ->
            EventBin = event_to_binary(Cur0),
            Cur1 = new_event(Line),
            {{emit, EventBin}, State#group{current = Cur1}};
        false ->
            case Count0 >= Max of
                true ->
                    %% Force flush to avoid pathological growth
                    EventBin = event_to_binary(Cur0),
                    Cur1 = new_event(Line),
                    {{emit, EventBin}, State#group{current = Cur1}};
                false ->
                    Cur1 = Cur0#{
                        lines => [Line | Lines0],
                        count => Count0 + 1
                    },
                    {none, State#group{current = Cur1}}
            end
    end.

flush(State = #group{current = undefined}) ->
    {none, State};
flush(State = #group{current = Cur}) ->
    {{emit, event_to_binary(Cur)}, State#group{current = undefined}}.

%% Convenience for batch grouping
group_lines(Lines) ->
    group_lines(Lines, new(), []).

group_lines([], State, Acc) ->
    case flush(State) of
        {none, _} ->
            lists:reverse(Acc);
        {{emit, Event}, _} ->
            lists:reverse([Event | Acc])
    end;
group_lines([Line | Rest], State0, Acc0) ->
    case feed_line(Line, State0) of
        {none, State1} ->
            group_lines(Rest, State1, Acc0);
        {{emit, Event}, State1} ->
            group_lines(Rest, State1, [Event | Acc0])
    end.

new_event(Line) ->
    #{
        first_ts => maybe_extract_ts(Line),
        lines => [Line],
        count => 1
    }.

event_to_binary(Cur) ->
    iolist_to_binary(
        lists:join(<<"\n">>, lists:reverse(maps:get(lines, Cur)))
    ).

should_start_new_event(Line, Cur) ->
    case is_blank(Line) of
        true ->
            false;
        false ->
            case is_continuation_line(Line) of
                true ->
                    false;
                false ->
                    case current_looks_incomplete(Cur) of
                        true ->
                            false;
                        false ->
                            looks_like_new_log_entry(Line)
                    end
            end
    end.

%% Heuristics for multiline continuations
is_continuation_line(Line) ->
    begins_with_whitespace(Line) orelse
        begins_with(Line, <<"at ">>) orelse
        begins_with(Line, <<"... ">>) orelse
        begins_with(Line, <<"Caused by:">>) orelse
        begins_with(Line, <<"Traceback ">>) orelse
        begins_with(Line, <<"File \"">>) orelse
        begins_with(Line, <<"During handling of the above exception">>) orelse
        begins_with(Line, <<"Crash dump">>) orelse
        begins_with(Line, <<"init terminating in do_boot">>) orelse
        begins_with(Line, <<"    ">>) orelse
        begins_with(Line, <<"\t">>) orelse
        re_test(Line, <<"^[a-zA-Z0-9_./-]+:[0-9]+">>).

%% If current event already looks like a traceback, bias toward continuation
current_looks_incomplete(Cur) ->
    Bin = event_to_binary(Cur),
    binary:match(Bin, <<"Traceback">>) =/= nomatch orelse
        binary:match(Bin, <<"Exception">>) =/= nomatch orelse
        binary:match(Bin, <<"stacktrace">>) =/= nomatch orelse
        binary:match(Bin, <<"Stacktrace">>) =/= nomatch orelse
        binary:match(Bin, <<"Crash dump">>) =/= nomatch orelse
        binary:match(Bin, <<"panic:">>) =/= nomatch.

looks_like_new_log_entry(Line) ->
    re_test(Line, <<"^\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}">>) orelse
        re_test(Line, <<"^\\[[A-Z]+\\]">>) orelse
        re_test(Line, <<"^(DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\\b">>) orelse
        re_test(Line, <<"^[A-Z][a-z]{2} [ 0-9]{2} \\d{2}:\\d{2}:\\d{2}">>).

maybe_extract_ts(Line) ->
    case
        re:run(
            Line,
            <<"\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?">>,
            [{capture, first, binary}]
        )
    of
        {match, [Ts]} -> Ts;
        _ -> <<>>
    end.

strip_cr(Bin) when is_binary(Bin) ->
    binary:replace(Bin, <<"\r">>, <<>>, [global]);
strip_cr(List) when is_list(List) ->
    strip_cr(list_to_binary(List)).

is_blank(<<>>) -> true;
is_blank(Bin) -> re_test(Bin, <<"^\\s*$">>).

begins_with_whitespace(<<C, _/binary>>) when C =:= $\s; C =:= $\t ->
    true;
begins_with_whitespace(_) ->
    false.

begins_with(Bin, Prefix) when is_binary(Bin), is_binary(Prefix) ->
    PrefixSize = byte_size(Prefix),
    case Bin of
        <<Prefix:PrefixSize/binary, _/binary>> -> true;
        _ -> false
    end.

re_test(Bin, Pattern) ->
    case re:run(Bin, Pattern, [unicode]) of
        match -> true;
        nomatch -> false;
        _ -> false
    end.
