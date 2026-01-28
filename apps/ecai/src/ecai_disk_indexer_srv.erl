%%--------------------------------------------------------------------
%% ecai_disk_indexer_srv.erl
%% Background disk segment writer (hybrid mode)
%%--------------------------------------------------------------------
-module(ecai_disk_indexer_srv).
-behaviour(gen_server).

-export([start_link/2, add_doc/3, flush/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-record(st, {
    base_dir,
    seg_no = 1,
    batch = #{},
    batch_docs = 0,
    max_docs = 50000
}).

start_link(BaseDir, MaxDocs) ->
    gen_server:start_link(
        {local, ?MODULE},
        ?MODULE,
        {BaseDir, MaxDocs},
        []
    ).

add_doc(Terms, DocInt, Rec) ->
    gen_server:cast(?MODULE, {add, Terms, DocInt, Rec}).

flush() ->
    gen_server:call(?MODULE, flush).

init({BaseDir, Max}) ->
    ok = filelib:ensure_dir(filename:join(BaseDir, "x")),
    {ok, #st{base_dir = BaseDir, max_docs = Max}}.

handle_cast(
    {add, Terms, DocInt, _Rec},
    S = #st{batch = B0, batch_docs = N0, max_docs = Max}
) ->
    B1 = lists:foldl(
        fun(T, Acc) ->
            maps:update_with(
                T,
                fun(L) -> [DocInt | L] end,
                [DocInt],
                Acc
            )
        end,
        B0,
        Terms
    ),
    N1 = N0 + 1,
    S1 = S#st{batch = B1, batch_docs = N1},
    if
        N1 >= Max -> {noreply, flush_state(S1)};
        true -> {noreply, S1}
    end.

handle_call(flush, _From, S) ->
    {reply, ok, flush_state(S)}.

flush_state(S = #st{batch_docs = 0}) ->
    S;
flush_state(S = #st{base_dir = Dir, seg_no = No, batch = B}) ->
    Name = io_lib:format("seg_~6..0B.ecs", [No]),
    ok = ecai_disk_segment:write(Dir, lists:flatten(Name), B),
    ok = ecai_disk_manifest:append_segment(
        Dir, filename:join(Dir, lists:flatten(Name))
    ),
    S#st{seg_no = No + 1, batch = #{}, batch_docs = 0}.
