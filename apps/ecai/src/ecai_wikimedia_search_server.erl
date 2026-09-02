-module(ecai_wikimedia_search_server).
-behaviour(gen_server).

-export([start_link/0, search/2, status/0, activate_snapshot/2]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2,
    code_change/3
]).

-include_lib("kernel/include/logger.hrl").

-define(COPY_BLOCK_BYTES, 1048576).

-record(st, {
    ctx = undefined,
    snapshot_path = undefined,
    metadata = #{}
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

search(Query, Opts) when is_map(Opts) ->
    gen_server:call(?MODULE, {search, Query, Opts}, infinity).

status() ->
    gen_server:call(?MODULE, status).

activate_snapshot(Path, Metadata) when is_map(Metadata) ->
    gen_server:call(?MODULE, {activate_snapshot, Path, Metadata}, infinity).

init([]) ->
    {ok, #st{}, {continue, restore_active_snapshot}}.

handle_continue(restore_active_snapshot, State) ->
    {noreply, restore_active_snapshot(State)}.

handle_call({search, _Query, _Opts}, _From, State = #st{ctx = undefined}) ->
    {reply, {error, search_index_not_ready}, State};
handle_call({search, Query, Opts}, _From, State = #st{ctx = Ctx}) ->
    {reply, ecai_wikimedia_search:search(Ctx, Query, Opts), State};
handle_call(status, _From, State = #st{ctx = undefined}) ->
    {reply, #{ready => false, reason => search_index_not_ready}, State};
handle_call(status, _From, State = #st{ctx = Ctx, snapshot_path = Path, metadata = Metadata}) ->
    {reply,
        #{
            ready => true,
            size => ecai_search:size(Ctx),
            snapshot_path => Path,
            metadata => Metadata
        },
        State};
handle_call({activate_snapshot, Path0, Metadata}, _From, State) ->
    %% Install a private immutable copy first. The active pointer must never
    %% depend on a job work directory that can later be compacted or removed.
    case install_snapshot(Path0) of
        {ok, InstalledPath, SnapshotSha} ->
            case load_snapshot(InstalledPath) of
                {ok, NewCtx, Path} ->
                    Metadata1 = Metadata#{snapshot_sha256 => SnapshotSha},
                    case persist_active_snapshot(Path, Metadata1) of
                        ok ->
                            wipe_ctx(State#st.ctx),
                            {reply, ok, State#st{
                                ctx = NewCtx, snapshot_path = Path, metadata = Metadata1
                            }};
                        {error, Reason} ->
                            wipe_ctx(NewCtx),
                            {reply, {error, {active_snapshot_state_failed, Reason}}, State}
                    end;
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) ->
    wipe_ctx(State#st.ctx),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

restore_active_snapshot(State) ->
    case file:read_file(active_state_path()) of
        {ok, Bin} ->
            try binary_to_term(Bin, [safe]) of
                #{version := 1, snapshot_path := Path, metadata := Metadata} when
                    is_map(Metadata)
                ->
                    case load_snapshot(Path) of
                        {ok, Ctx, NormalizedPath} ->
                            State#st{
                                ctx = Ctx, snapshot_path = NormalizedPath, metadata = Metadata
                            };
                        {error, Reason} ->
                            ?LOG_WARNING(
                                "Unable to restore active Wikimedia search snapshot: ~p", [Reason]
                            ),
                            State
                    end;
                _ ->
                    State
            catch
                error:badarg -> State
            end;
        {error, enoent} ->
            State;
        {error, Reason} ->
            ?LOG_WARNING("Unable to read Wikimedia active-search state: ~p", [Reason]),
            State
    end.

install_snapshot(Path0) ->
    case normalize_path(Path0) of
        {ok, SourcePath} ->
            SnapshotDir = snapshot_dir(),
            ok = filelib:ensure_dir(filename:join(SnapshotDir, "x")),
            TempPath = filename:join(
                SnapshotDir,
                ".install-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])) ++
                    ".tmp"
            ),
            case copy_and_hash(SourcePath, TempPath) of
                {ok, Hash} ->
                    Sha = hex(Hash),
                    FinalPath = filename:join(SnapshotDir, binary_to_list(Sha) ++ ".etf"),
                    case filelib:is_regular(FinalPath) of
                        true ->
                            _ = file:delete(TempPath),
                            {ok, unicode:characters_to_binary(FinalPath), Sha};
                        false ->
                            case file:rename(TempPath, FinalPath) of
                                ok ->
                                    {ok, unicode:characters_to_binary(FinalPath), Sha};
                                {error, Reason} ->
                                    _ = file:delete(TempPath),
                                    {error, {snapshot_install_rename_failed, Reason}}
                            end
                    end;
                {error, Reason} ->
                    _ = file:delete(TempPath),
                    {error, Reason}
            end;
        {error, _Reason} = Error ->
            Error
    end.

copy_and_hash(SourcePath, TempPath) ->
    case file:open(SourcePath, [read, raw, binary]) of
        {ok, In} ->
            case file:open(TempPath, [write, raw, binary]) of
                {ok, Out} ->
                    try
                        Hash0 = crypto:hash_init(sha256),
                        case copy_and_hash_loop(In, Out, Hash0) of
                            {ok, Hash1} ->
                                case file:sync(Out) of
                                    ok -> {ok, crypto:hash_final(Hash1)};
                                    {error, Reason} -> {error, {snapshot_sync_failed, Reason}}
                                end;
                            {error, _Reason} = Error ->
                                Error
                        end
                    after
                        ok = file:close(Out),
                        ok = file:close(In)
                    end;
                {error, Reason} ->
                    ok = file:close(In),
                    {error, {snapshot_install_open_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {snapshot_source_open_failed, Reason}}
    end.

copy_and_hash_loop(In, Out, Hash0) ->
    case file:read(In, ?COPY_BLOCK_BYTES) of
        eof ->
            {ok, Hash0};
        {ok, Chunk} ->
            case file:write(Out, Chunk) of
                ok -> copy_and_hash_loop(In, Out, crypto:hash_update(Hash0, Chunk));
                {error, Reason} -> {error, {snapshot_install_write_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {snapshot_source_read_failed, Reason}}
    end.

load_snapshot(Path0) ->
    case normalize_path(Path0) of
        {ok, Path} ->
            Ctx0 = ecai_search:new(),
            try ecai_search:load(Ctx0, Path) of
                {ok, Ctx} ->
                    {ok, Ctx, unicode:characters_to_binary(Path)};
                {error, Reason} ->
                    wipe_ctx(Ctx0),
                    {error, {snapshot_load_failed, Reason}};
                Other ->
                    wipe_ctx(Ctx0),
                    {error, {unexpected_snapshot_load_result, Other}}
            catch
                Class:Reason:Stacktrace ->
                    wipe_ctx(Ctx0),
                    {error, {snapshot_load_failed, Class, Reason, Stacktrace}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

persist_active_snapshot(Path, Metadata) ->
    StatePath = active_state_path(),
    ok = filelib:ensure_dir(StatePath),
    atomic_write(
        StatePath, term_to_binary(#{version => 1, snapshot_path => Path, metadata => Metadata})
    ).

snapshot_dir() ->
    filename:join(filename:dirname(active_state_path()), "wikimedia-search-snapshots").

active_state_path() ->
    case
        application:get_env(
            ecai,
            wikimedia_active_search_state_path,
            "/var/lib/damage/ecai/state/wikimedia-active-search.etf"
        )
    of
        Bin when is_binary(Bin) -> unicode:characters_to_list(Bin);
        List when is_list(List), List =/= [] -> List;
        _ -> "/var/lib/damage/ecai/state/wikimedia-active-search.etf"
    end.

normalize_path(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    try
        {ok, unicode:characters_to_list(Bin)}
    catch
        _:_ -> {error, invalid_snapshot_path}
    end;
normalize_path(List) when is_list(List), List =/= [] -> {ok, List};
normalize_path(_) ->
    {error, invalid_snapshot_path}.

atomic_write(Path, Bytes) ->
    Tmp = Path ++ ".tmp",
    case file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            Result =
                try
                    ok = file:write(Fd, Bytes),
                    file:sync(Fd)
                after
                    ok = file:close(Fd)
                end,
            case Result of
                ok -> file:rename(Tmp, Path);
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

hex(Bin) when is_binary(Bin) ->
    <<<<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>> || <<Byte:8>> <= Bin>>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + (N - 10).

wipe_ctx(undefined) ->
    ok;
wipe_ctx(Ctx) ->
    try
        ecai_search:wipe(Ctx)
    catch
        _:_ -> ok
    end.
