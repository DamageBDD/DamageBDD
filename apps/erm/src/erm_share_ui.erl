%% Native gtkgs review UI. Rendering/selection stays in the Erlang boundary.
-module(erm_share_ui).
-behaviour(gen_server).
-export([show/0, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
show() ->
    case whereis(?MODULE) of
        P when is_pid(P) -> gen_server:call(P, show);
        undefined ->
            case erm_share:status() of
                {error, _} = E -> E;
                _ ->
                    case erm_sup:start_gtknode4() of
                        {ok, _} -> gen_server:start({local, ?MODULE}, ?MODULE, [], []);
                        E -> E
                    end
            end
    end.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
init([]) ->
    process_flag(sensitive, true),
    case gtknode4:await_ready(15000) of
        ok ->
            Tree = [{window, erm_share_window,
                [{title, "Share to ECAI"}, {width, 620}, {height, 620},
                 {wm_class, "erm_share"}, {wm_instance, "erm_share"}],
                [{frame, erm_share_root, [{orient, vertical}, {spacing, 10}, {expand, true}],
                  [{label, erm_share_heading, [{label, "Share to ECAI"}]},
                   {label, erm_share_hint, [{label, "Review incoming files and links before private indexing."}, {wrap, true}]},
                   {listbox, erm_share_list, [{items, []}, {expand, true}]},
                   {label, erm_share_detail, [{label, "No shares yet"}, {wrap, true}]},
                   {frame, erm_share_actions, [{orient, vertical}, {spacing, 6}],
                     [{button, erm_share_accept, [{label, "Index privately"}]},
                      {button, erm_share_reject, [{label, "Reject"}]},
                      {button, erm_share_forget, [{label, "Remove local inbox copy"}]},
                      {button, erm_share_refresh, [{label, "Refresh"}]}]},
                   {label, erm_share_result, [{label, ""}, {wrap, true}]}]}]}],
            {ok, [Window]} = gtkgs:create_tree(gtkgs:server(), Tree),
            ok = gtkgs:config(Window, {map, true}),
            self() ! refresh,
            {ok, #{window => Window, ids => [], rows => [], selected => undefined, timer => undefined}};
        E -> {stop, E}
    end.
handle_call(show, _, S) ->
    {reply, gtkgs:config(maps:get(window, S), {map, true}), S};
handle_call(_, _, S) -> {reply, {error, unsupported_request}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(refresh, S) ->
    Next = refresh(S),
    Timer = erlang:send_after(1500, self(), refresh),
    {noreply, Next#{timer := Timer}};
handle_info({gtkgs, erm_share_refresh, click, _, _}, S) -> {noreply, refresh(S)};
handle_info({gtkgs, erm_share_accept, click, _, _}, S) -> action(fun erm_share:accept/1, S);
handle_info({gtkgs, erm_share_reject, click, _, _}, S) -> action(fun erm_share:reject/1, S);
handle_info({gtkgs, erm_share_forget, click, _, _}, S) -> action(fun erm_share:forget/1, S);
handle_info({gtkgs, erm_share_list, _, _, _}, S) -> {noreply, detail(selected(S))};
handle_info({gtkgs, erm_share_window, destroy, _, _}, S) -> {stop, normal, S};
handle_info(_, S) -> {noreply, S}.
terminate(_, S) ->
    case maps:get(timer, S) of undefined -> ok; T -> erlang:cancel_timer(T) end,
    try gtkgs:destroy(maps:get(window, S)) catch _:_ -> ok end.
code_change(_, S, _) -> {ok, S}.

action(Fun, S) ->
    S1 = selected(S),
    Result = case maps:get(selected, S1) of undefined -> {error, select_a_share}; Id -> Fun(Id) end,
    _ = gtkgs:config(erm_share_result, {label, lists:flatten(io_lib:format("~p", [Result]))}),
    {noreply, refresh(S1)}.
selected(S) ->
    case gtkgs:read(erm_share_list, selected_index) of
        N when is_integer(N), N >= 0 ->
            Ids = maps:get(ids, S),
            case N < length(Ids) of true -> S#{selected := lists:nth(N + 1, Ids)}; false -> S end;
        _ -> S
    end.
refresh(S) ->
    case erm_share:items() of
        Rows when is_list(Rows) ->
            S1 = selected(S), Ids = [maps:get(id, I) || I <- Rows],
            case Rows =:= maps:get(rows, S) of
                true -> detail(S1);
                false ->
                    Labels = [unicode:characters_to_binary(io_lib:format("~ts — ~p (~B bytes)",
                        [maps:get(name, I), maps:get(state, I), maps:get(size, I)])) || I <- Rows],
                    OldId = maps:get(selected, S1),
                    N = index(OldId, Ids, 0),
                    _ = gtkgs:config(erm_share_list, [{items, Labels}, {selected_index, N}]),
                    detail(S1#{rows := Rows, ids := Ids,
                               selected := case N of -1 -> undefined; _ -> lists:nth(N+1, Ids) end})
            end;
        _ -> S
    end.
index(_, [], _) -> -1;
index(Id, [Id | _], N) -> N;
index(Id, [_ | T], N) -> index(Id, T, N+1).
detail(S) ->
    Match = [I || I <- maps:get(rows, S), maps:get(id, I) =:= maps:get(selected, S)],
    Text = case Match of
        [I] -> io_lib:format("Source: ~ts\nState: ~p\n~p", [maps:get(transport, I),
                                    maps:get(state, I), maps:get(error, I, undefined)]);
        [] -> "Select a share. Removing an inbox copy does not delete an indexed document."
    end,
    _ = gtkgs:config(erm_share_detail, {label, unicode:characters_to_binary(Text)}), S.
