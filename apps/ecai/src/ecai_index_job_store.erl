%%--------------------------------------------------------------------
%% Durable DETS-backed state for the ECAI indexing control plane.
%%
%% One ecai_index_jobs_srv process owns this store. State transitions call
%% sync/1 before being acknowledged to operators. The index data itself remains
%% owned by the existing WAL/search/disk-index modules.
%%--------------------------------------------------------------------
-module(ecai_index_job_store).

-export([
    open/1,
    close/1,
    sync/1,
    next_sequence/1,
    put_job/2,
    put_job_event/3,
    create_job/5,
    get_job/2,
    list_jobs/1,
    put_idempotency/4,
    replace_idempotency/2,
    get_idempotency/3,
    put_event/3,
    events_after/4
]).

-record(store, {
    tab,
    path
}).

-define(TABLE, ecai_index_job_store_dets).
-define(NEXT_SEQUENCE_KEY, {meta, next_sequence}).

-spec open(file:filename_all() | undefined) -> {ok, #store{}} | {error, term()}.
open(BaseDir0) ->
    case normalize_base_dir(BaseDir0) of
        {ok, BaseDir} ->
            case ensure_store_dir(BaseDir) of
                ok ->
                    open_dets(BaseDir);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

open_dets(BaseDir) ->
    Path = filename:join(BaseDir, "index-jobs.dets"),
    case
        dets:open_file(?TABLE, [
            {file, Path},
            {type, set},
            {repair, false},
            {auto_save, 5000}
        ])
    of
        {ok, Tab} ->
            case ensure_meta(Tab) of
                ok ->
                    {ok, #store{tab = Tab, path = Path}};
                {error, _Reason} = Error ->
                    _ = dets:close(Tab),
                    Error
            end;
        {error, Reason} ->
            {error, {store_open_failed, Path, Reason}}
    end.

-spec close(#store{}) -> ok | {error, term()}.
close(#store{tab = Tab}) ->
    dets:close(Tab).

-spec sync(#store{}) -> ok | {error, term()}.
sync(#store{tab = Tab}) ->
    dets:sync(Tab).

-spec next_sequence(#store{}) -> {ok, pos_integer()} | {error, term()}.
next_sequence(#store{tab = Tab}) ->
    try dets:update_counter(Tab, ?NEXT_SEQUENCE_KEY, 1) of
        Sequence when is_integer(Sequence), Sequence > 0 -> {ok, Sequence}
    catch
        error:Reason -> {error, {sequence_update_failed, Reason}}
    end.

-spec put_job(#store{}, map()) -> ok | {error, term()}.
put_job(#store{tab = Tab}, #{id := JobId} = Job) when is_binary(JobId) ->
    dets:insert(Tab, {{job, JobId}, Job});
put_job(_Store, _Job) ->
    {error, badarg}.

-spec put_job_event(#store{}, map(), map()) -> ok | {error, term()}.
put_job_event(
    #store{tab = Tab},
    #{id := JobId} = Job,
    #{seq := Seq} = Event
) when is_binary(JobId), is_integer(Seq), Seq > 0 ->
    dets:insert(Tab, [
        {{job, JobId}, Job},
        {{event, JobId, Seq}, Event}
    ]);
put_job_event(_Store, _Job, _Event) ->
    {error, badarg}.

-spec create_job(#store{}, map(), map(), binary(), binary()) -> ok | {error, term()}.
create_job(
    #store{tab = Tab},
    #{id := JobId} = Job,
    #{seq := Seq} = Event,
    Owner,
    IdempotencyKey
) when
    is_binary(JobId),
    is_integer(Seq),
    Seq > 0,
    is_binary(Owner),
    is_binary(IdempotencyKey)
->
    Objects0 = [
        {{job, JobId}, Job},
        {{event, JobId, Seq}, Event}
    ],
    Objects =
        case IdempotencyKey of
            <<>> -> Objects0;
            _ -> [{{idempotency, Owner, IdempotencyKey}, JobId} | Objects0]
        end,
    dets:insert(Tab, Objects);
create_job(_Store, _Job, _Event, _Owner, _IdempotencyKey) ->
    {error, badarg}.

-spec get_job(#store{}, binary()) -> {ok, map()} | not_found | {error, term()}.
get_job(#store{tab = Tab}, JobId) when is_binary(JobId) ->
    case dets:lookup(Tab, {job, JobId}) of
        [{{job, JobId}, Job}] when is_map(Job) -> {ok, Job};
        [] -> not_found;
        Other -> {error, {invalid_job_record, Other}}
    end;
get_job(_Store, _JobId) ->
    {error, badarg}.

-spec list_jobs(#store{}) -> {ok, [map()]} | {error, term()}.
list_jobs(#store{tab = Tab}) ->
    try
        Jobs = dets:foldl(
            fun
                ({{job, _JobId}, Job}, Acc) when is_map(Job) -> [Job | Acc];
                (_Other, Acc) -> Acc
            end,
            [],
            Tab
        ),
        {ok, Jobs}
    catch
        Class:Reason -> {error, {store_fold_failed, Class, Reason}}
    end.

-spec put_idempotency(#store{}, binary(), binary(), binary()) -> ok | {error, term()}.
put_idempotency(#store{tab = Tab}, Owner, Key, JobId) when
    is_binary(Owner), is_binary(Key), is_binary(JobId)
->
    dets:insert(Tab, {{idempotency, Owner, Key}, JobId});
put_idempotency(_Store, _Owner, _Key, _JobId) ->
    {error, badarg}.

-spec replace_idempotency(#store{}, [{binary(), binary(), binary()}]) ->
    ok | {error, term()}.
replace_idempotency(#store{tab = Tab}, Entries) when is_list(Entries) ->
    case
        lists:all(
            fun({Owner, Key, JobId}) ->
                is_binary(Owner) andalso is_binary(Key) andalso is_binary(JobId)
            end,
            Entries
        )
    of
        true ->
            case
                dets:match_delete(
                    Tab,
                    {{idempotency, '_', '_'}, '_'}
                )
            of
                ok ->
                    Objects = [
                        {{idempotency, Owner, Key}, JobId}
                     || {Owner, Key, JobId} <- Entries,
                        Key =/= <<>>
                    ],
                    case Objects of
                        [] -> ok;
                        _ -> dets:insert(Tab, Objects)
                    end;
                {error, _Reason} = Error ->
                    Error
            end;
        false ->
            {error, badarg}
    end;
replace_idempotency(_Store, _Entries) ->
    {error, badarg}.

-spec get_idempotency(#store{}, binary(), binary()) ->
    {ok, binary()} | not_found | {error, term()}.
get_idempotency(#store{tab = Tab}, Owner, Key) when is_binary(Owner), is_binary(Key) ->
    case dets:lookup(Tab, {idempotency, Owner, Key}) of
        [{{idempotency, Owner, Key}, JobId}] when is_binary(JobId) -> {ok, JobId};
        [] -> not_found;
        Other -> {error, {invalid_idempotency_record, Other}}
    end;
get_idempotency(_Store, _Owner, _Key) ->
    {error, badarg}.

-spec put_event(#store{}, binary(), map()) -> ok | {error, term()}.
put_event(#store{tab = Tab}, JobId, #{seq := Seq} = Event) when
    is_binary(JobId), is_integer(Seq), Seq > 0
->
    dets:insert(Tab, {{event, JobId, Seq}, Event});
put_event(_Store, _JobId, _Event) ->
    {error, badarg}.

-spec events_after(#store{}, binary(), non_neg_integer(), pos_integer()) ->
    {ok, [map()]} | {error, term()}.
events_after(#store{tab = Tab}, JobId, AfterSeq, Limit) when
    is_binary(JobId),
    is_integer(AfterSeq),
    AfterSeq >= 0,
    is_integer(Limit),
    Limit > 0
->
    try
        Events0 = dets:foldl(
            fun
                ({{event, JobId0, Seq}, Event}, Acc) when
                    JobId0 =:= JobId,
                    Seq > AfterSeq,
                    is_map(Event)
                ->
                    [Event | Acc];
                (_Other, Acc) ->
                    Acc
            end,
            [],
            Tab
        ),
        Events1 = lists:sort(
            fun(A, B) -> maps:get(seq, A) < maps:get(seq, B) end,
            Events0
        ),
        {ok, lists:sublist(Events1, Limit)}
    catch
        Class:Reason -> {error, {event_read_failed, Class, Reason}}
    end;
events_after(_Store, _JobId, _AfterSeq, _Limit) ->
    {error, badarg}.

ensure_meta(Tab) ->
    case dets:lookup(Tab, ?NEXT_SEQUENCE_KEY) of
        [] -> dets:insert(Tab, {?NEXT_SEQUENCE_KEY, 0});
        [{?NEXT_SEQUENCE_KEY, Value}] when is_integer(Value), Value >= 0 -> ok;
        Other -> {error, {invalid_store_meta, Other}}
    end.

normalize_base_dir(undefined) ->
    default_base_dir();
normalize_base_dir(<<>>) ->
    default_base_dir();
normalize_base_dir([]) ->
    default_base_dir();
normalize_base_dir(BaseDir0) ->
    case legacy_default_base_dir(BaseDir0) of
        true ->
            default_base_dir();
        false ->
            normalize_explicit_base_dir(BaseDir0)
    end.

normalize_explicit_base_dir(BaseDir0) ->
    try
        BaseDir1 = path_list(BaseDir0),
        BaseDir2 = expand_home_path(BaseDir1),
        {ok, filename:absname(BaseDir2)}
    catch
        error:home_directory_unavailable ->
            {error, home_directory_unavailable};
        error:badarg ->
            {error, invalid_store_path};
        Class:Reason ->
            {error, {store_path_normalization_failed, Class, Reason}}
    end.

default_base_dir() ->
    try
        {ok, filename:join(ecai_paths:runtime_dir(), "index-jobs")}
    catch
        Class:Reason ->
            {error, {default_store_path_failed, Class, Reason}}
    end.

legacy_default_base_dir(BaseDir0) ->
    case path_list_or_undefined(BaseDir0) of
        "/var/lib/damage/ecai/index-jobs" -> true;
        "/var/lib/damage/ecai/index-jobs/" -> true;
        _ -> false
    end.

path_list_or_undefined(Bin) when is_binary(Bin) ->
    try unicode:characters_to_list(Bin) of
        List when is_list(List) -> List;
        _ -> undefined
    catch
        _:_ -> undefined
    end;
path_list_or_undefined(List) when is_list(List) ->
    List;
path_list_or_undefined(_) ->
    undefined.

ensure_store_dir(BaseDir) ->
    %% filelib:ensure_dir/1 treats its argument as a file path, so append a
    %% sentinel filename. This recursively creates the complete directory tree.
    Sentinel = filename:join(BaseDir, ".ecai-index-jobs"),
    case filelib:ensure_dir(Sentinel) of
        ok ->
            case filelib:is_dir(BaseDir) of
                true ->
                    ok;
                false ->
                    {error, {store_directory_not_created, BaseDir}}
            end;
        {error, Reason} ->
            {error, {store_directory_failed, BaseDir, Reason}}
    end.

path_list(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    case unicode:characters_to_list(Bin) of
        List when is_list(List), List =/= [] -> List;
        _Invalid -> erlang:error(badarg)
    end;
path_list(List) when is_list(List), List =/= [] ->
    List;
path_list(_Other) ->
    erlang:error(badarg).

expand_home_path("~") ->
    home_dir();
expand_home_path([$~, $/ | Rest]) ->
    filename:join(home_dir(), Rest);
expand_home_path(Path) ->
    Path.

home_dir() ->
    case os:getenv("HOME") of
        Home when is_list(Home), Home =/= "" ->
            Home;
        _ ->
            erlang:error(home_directory_unavailable)
    end.
