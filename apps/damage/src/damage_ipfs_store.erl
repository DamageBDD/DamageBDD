%% Durable desired pin state + CID metadata. DETS is the authority; ETS indexes
%% are rebuilt on startup. Every acknowledged mutation has passed dets:sync/1.
-module(damage_ipfs_store).
-behaviour(gen_server).
-export([
    start_link/1,
    desire/2,
    lookup/1,
    next_pending/0,
    complete/3,
    page/2,
    requeue/2,
    put_metadata/2,
    get_metadata/1
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

start_link(C) -> gen_server:start_link({local, ?MODULE}, ?MODULE, C, []).
desire(Cid, Desired) when Desired =:= pinned; Desired =:= unpinned ->
    with_cid(Cid, fun(B) -> call({desire, B, Desired}) end).
lookup(Cid) -> with_cid(Cid, fun(B) -> call({lookup, B}) end).
next_pending() -> call(next_pending).
complete(Cid, Revision, Result) -> call({complete, Cid, Revision, Result}).
page(Cursor, Limit) when is_integer(Limit), Limit > 0, Limit =< 1000 -> call({page, Cursor, Limit}).
requeue(Cid, Revision) -> call({requeue, Cid, Revision}).
put_metadata(Cid, Metadata) when is_map(Metadata) ->
    with_cid(Cid, fun(B) ->
        case erlang:external_size(Metadata) =< 65536 of
            true -> call({metadata, B, Metadata});
            false -> {error, metadata_too_large}
        end
    end).
get_metadata(Cid) -> with_cid(Cid, fun(B) -> call({metadata, B}) end).
call(R) -> damage_ipfs_config:call(?MODULE, R, 10000).
with_cid(C, F) ->
    case damage_ipfs_config:cid(C) of
        {ok, B} -> F(B);
        E -> E
    end.

init(C) ->
    process_flag(trap_exit, true),
    Path = filename:join(maps:get(data_dir, C), "pin_intents.dets"),
    case filelib:ensure_dir(Path) of
        ok ->
            case dets:open_file(?MODULE, [{file, Path}, {type, set}, {auto_save, 5000}]) of
                {ok, Tab} ->
                    Pins = ets:new(ipfs_pins, [ordered_set, private]),
                    Due = ets:new(ipfs_due, [ordered_set, private]),
                    S = #{tab => Tab, pins => Pins, due => Due, config => C},
                    ok = dets:foldl(
                        fun
                            ({Cid, R = #{revision := _, desired := _, status := _}}, ok) when
                                is_binary(Cid)
                            ->
                                index(Cid, R, S),
                                ok;
                            ({{metadata, _}, M}, ok) when is_map(M) -> ok;
                            (_, _) ->
                                error(invalid_ipfs_store_record)
                        end,
                        ok,
                        Tab
                    ),
                    {ok, S};
                {error, Reason} ->
                    {stop, {ipfs_store_open_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {ipfs_store_directory_failed, Reason}}
    end.

handle_call({desire, Cid, Desired}, _, S = #{pins := Pins, tab := Tab, config := C}) ->
    Old = lookup_row(Cid, S),
    Full =
        ets:info(Pins, size) >= maps:get(max_intents, C) orelse
            dets:info(Tab, size) >= maps:get(max_intents, C) * 2,
    case Old =:= undefined andalso Full of
        true ->
            {reply, {error, intent_limit}, S};
        false ->
            Revision =
                case Old of
                    undefined -> 1;
                    _ -> maps:get(revision, Old) + 1
                end,
            R = #{
                desired => Desired,
                revision => Revision,
                status => pending,
                attempts => 0,
                next_at => damage_ipfs_config:now_ms(),
                last_error => undefined
            },
            persist(Cid, R, S),
            {reply, {ok, #{cid => Cid, revision => Revision, status => pending}}, S}
    end;
handle_call({lookup, Cid}, _, S) ->
    Reply =
        case lookup_row(Cid, S) of
            undefined -> {error, not_found};
            R -> {ok, R}
        end,
    {reply, Reply, S};
handle_call(next_pending, _, S = #{due := Due}) ->
    Now = damage_ipfs_config:now_ms(),
    Reply =
        case ets:first(Due) of
            {When, Cid} when When =< Now -> {ok, Cid, lookup_row(Cid, S)};
            _ -> empty
        end,
    {reply, Reply, S};
handle_call({complete, Cid, Rev, Result}, _, S = #{config := C}) ->
    case lookup_row(Cid, S) of
        #{revision := Rev} = R ->
            Now = damage_ipfs_config:now_ms(),
            R1 =
                case succeeded(Result) of
                    true ->
                        R#{
                            status => applied,
                            checked_at => Now,
                            last_error => undefined,
                            attempts => 0,
                            next_at => infinity
                        };
                    false ->
                        N = maps:get(attempts, R) + 1,
                        Max = maps:get(retry_max_ms, C),
                        Base = min(Max, maps:get(retry_base_ms, C) * (1 bsl min(N - 1, 16))),
                        Delay = min(Max, Base + rand:uniform(max(1, Base div 5))),
                        R#{
                            status => pending,
                            attempts => N,
                            next_at => Now + Delay,
                            last_error => safe_error(Result)
                        }
                end,
            persist(Cid, R1, S),
            {reply, ok, S};
        _ ->
            {reply, {error, stale_revision}, S}
    end;
handle_call({requeue, Cid, Rev}, _, S) ->
    case lookup_row(Cid, S) of
        #{revision := Rev, status := applied} = R ->
            persist(Cid, R#{status => pending, next_at => damage_ipfs_config:now_ms()}, S),
            {reply, ok, S};
        _ ->
            {reply, {error, stale_revision}, S}
    end;
handle_call({page, Cursor, Limit}, _, S = #{pins := Pins}) ->
    First =
        case Cursor of
            start -> ets:first(Pins);
            _ -> ets:next(Pins, Cursor)
        end,
    {Rows, Next} = take_page(First, Limit, Pins, [], Cursor),
    {reply, {ok, Rows, Next}, S};
handle_call({metadata, Cid, M}, _, S = #{tab := Tab, config := C}) ->
    Key = {metadata, Cid},
    case
        dets:lookup(Tab, Key) =:= [] andalso dets:info(Tab, size) >= maps:get(max_intents, C) * 2
    of
        true ->
            {reply, {error, metadata_limit}, S};
        false ->
            ok = dets:insert(Tab, {Key, M}),
            ok = dets:sync(Tab),
            {reply, ok, S}
    end;
handle_call({metadata, Cid}, _, S = #{tab := Tab}) ->
    R =
        case dets:lookup(Tab, {metadata, Cid}) of
            [{_, M}] -> {ok, M};
            [] -> {error, not_found}
        end,
    {reply, R, S};
handle_call(_, _, S) ->
    {reply, {error, unknown_request}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, #{tab := Tab}) ->
    dets:close(Tab),
    ok.
code_change(_, S, _) -> {ok, S}.

lookup_row(Cid, #{pins := Pins}) ->
    case ets:lookup(Pins, Cid) of
        [{_, R}] -> R;
        [] -> undefined
    end.
persist(Cid, R, S = #{tab := Tab, due := Due}) ->
    %% Fail closed on I/O errors. The caller sees a service error, never a
    %% successful receipt for an intent that was not durably acknowledged.
    ok = dets:insert(Tab, {Cid, R}),
    ok = dets:sync(Tab),
    case lookup_row(Cid, S) of
        #{status := pending, next_at := At} -> ets:delete(Due, {At, Cid});
        _ -> ok
    end,
    index(Cid, R, S).
index(Cid, R, #{pins := Pins, due := Due}) ->
    ets:insert(Pins, {Cid, R}),
    case R of
        #{status := pending, next_at := At, revision := Rev} -> ets:insert(Due, {{At, Cid}, Rev});
        _ -> ok
    end,
    ok.
take_page('$end_of_table', _, _, Acc, _) ->
    {lists:reverse(Acc), start};
take_page(_, 0, _, Acc, Last) ->
    {lists:reverse(Acc), Last};
take_page(Key, N, Tab, Acc, _) ->
    [{Key, R}] = ets:lookup(Tab, Key),
    take_page(ets:next(Tab, Key), N - 1, Tab, [{Key, R} | Acc], Key).
succeeded(ok) -> true;
succeeded({ok, _}) -> true;
succeeded(_) -> false.
safe_error(R) ->
    B = iolist_to_binary(io_lib:format("~0P", [R, 6])),
    binary:part(B, 0, min(byte_size(B), 1024)).
