%%% Single-writer, append-only, fsync'ed tax journal with SHA256 hash chain.
%%% A verified full replay is required on startup; corruption fails closed.
-module(damage_tax_store).
-behaviour(gen_server).
-export([
    start_link/1,
    append/1,
    entries/0,
    head/0,
    verify/0,
    archive_evidence/1,
    evidence_exists/1
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(ZERO, <<"0000000000000000000000000000000000000000000000000000000000000000">>).
-define(MAX_EVIDENCE, 2097152).

start_link(Path) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Path, []).
append(Event) -> gen_server:call(?MODULE, {append, Event}, 30000).
entries() -> gen_server:call(?MODULE, entries, 30000).
head() -> gen_server:call(?MODULE, head).
verify() -> gen_server:call(?MODULE, verify, 60000).
archive_evidence(Bytes) -> gen_server:call(?MODULE, {archive, Bytes}, 30000).
evidence_exists(Sha) -> gen_server:call(?MODULE, {evidence_exists, Sha}).

init(Path0) ->
    Path = filename:absname(Path0),
    case ensure_private_path(Path) of
        ok ->
            case replay(Path) of
                {ok, Records, Seen, Last} ->
                    {ok, #{
                        path => Path,
                        records => Records,
                        seen => Seen,
                        head => Last,
                        count => length(Records)
                    }};
                ReplayError ->
                    {stop, {journal_verification_failed, ReplayError}}
            end;
        SetupError ->
            {stop, {tax_store_unavailable, SetupError}}
    end.

handle_call({append, Event}, _From, State) ->
    case damage_tax_event:validate(Event) of
        ok ->
            Id = maps:get(<<"id">>, Event),
            EventHash = damage_tax_canonical:commitment(Event),
            Seen = maps:get(seen, State),
            case maps:get(Id, Seen, undefined) of
                EventHash ->
                    {reply, {ok, duplicate}, State};
                undefined ->
                    Prev = maps:get(head, State),
                    Seq = maps:get(count, State) + 1,
                    Digest = record_hash(Prev, Seq, Event),
                    Entry = #{
                        <<"sequence">> => Seq,
                        <<"previous">> => Prev,
                        <<"sha256">> => Digest,
                        <<"event">> => Event
                    },
                    case append_line(maps:get(path, State), Entry) of
                        ok ->
                            {reply, {ok, Digest}, State#{
                                head => Digest,
                                count => Seq,
                                seen => maps:put(Id, EventHash, Seen),
                                records => [Entry | maps:get(records, State)]
                            }};
                        AppendError ->
                            {reply, AppendError, State}
                    end;
                _Different ->
                    {reply, {error, conflicting_tax_event}, State}
            end;
        ValidationError ->
            {reply, ValidationError, State}
    end;
handle_call(entries, _From, State) ->
    {reply, {ok, lists:reverse(maps:get(records, State))}, State};
handle_call(head, _From, State) ->
    {reply, {ok, maps:get(head, State)}, State};
handle_call(verify, _From, State) ->
    ExpectedHead = maps:get(head, State),
    Reply =
        case replay(maps:get(path, State)) of
            {ok, _Records, _Seen, ExpectedHead} -> ok;
            {ok, _, _, _} -> {error, journal_changed_outside_writer};
            Error -> Error
        end,
    {reply, Reply, State};
handle_call({archive, Bytes}, _From, State) when
    is_binary(Bytes),
    byte_size(Bytes) =< ?MAX_EVIDENCE
->
    {reply, save_evidence(maps:get(path, State), Bytes), State};
handle_call({archive, _}, _From, State) ->
    {reply, {error, invalid_evidence_size}, State};
handle_call({evidence_exists, Sha}, _From, State) ->
    {reply, evidence_check(maps:get(path, State), Sha), State};
handle_call(_, _From, State) ->
    {reply, {error, bad_call}, State}.

handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

record_hash(Prev, Seq, Event) ->
    damage_tax_canonical:sha256_hex([
        <<"damage-tax-journal-v1\n">>,
        Prev,
        <<"\n">>,
        integer_to_binary(Seq),
        <<"\n">>,
        damage_tax_canonical:encode(Event)
    ]).

append_line(Path, Entry) ->
    case file:open(Path, [append, binary]) of
        {ok, Io} ->
            Result =
                case file:write(Io, [damage_tax_canonical:encode(Entry), <<"\n">>]) of
                    ok -> file:sync(Io);
                    WriteError -> WriteError
                end,
            Closed = file:close(Io),
            case {Result, Closed} of
                {ok, ok} ->
                    ok;
                {WriteFailure, _} when WriteFailure =/= ok ->
                    {error, {journal_write_failed, WriteFailure}};
                {_, CloseError} ->
                    {error, {journal_close_failed, CloseError}}
            end;
        OpenError ->
            {error, {journal_open_failed, OpenError}}
    end.

replay(Path) ->
    case file:open(Path, [read, binary]) of
        {ok, Io} ->
            Result = replay_lines(Io, 1, ?ZERO, #{}, []),
            _ = file:close(Io),
            Result;
        Error ->
            {error, {journal_open_failed, Error}}
    end.

replay_lines(Io, Seq, Prev, Seen, Acc) ->
    case file:read_line(Io) of
        eof ->
            {ok, Acc, Seen, Prev};
        {ok, Line} ->
            case Line of
                <<>> ->
                    {error, {truncated_tax_journal, Seq}};
                _ ->
                    case binary:last(Line) of
                        10 -> parse_line(Io, Line, Seq, Prev, Seen, Acc);
                        _ -> {error, {truncated_tax_journal, Seq}}
                    end
            end;
        Error ->
            {error, {journal_read_failed, Error}}
    end.

parse_line(Io, Line, Seq, Prev, Seen, Acc) ->
    try
        Entry = jsx:decode(Line, [return_maps]),
        #{
            <<"sequence">> := Seq,
            <<"previous">> := Prev,
            <<"sha256">> := SHA,
            <<"event">> := Event
        } = Entry,
        ok = damage_tax_event:validate(Event),
        SHA = record_hash(Prev, Seq, Event),
        Id = maps:get(<<"id">>, Event),
        false = maps:is_key(Id, Seen),
        EventHash = damage_tax_canonical:commitment(Event),
        replay_lines(Io, Seq + 1, SHA, maps:put(Id, EventHash, Seen), [Entry | Acc])
    catch
        _:_ -> {error, {tax_journal_integrity_failure, Seq}}
    end.

ensure_private_path(Path) ->
    case filelib:ensure_dir(Path) of
        ok ->
            case file:open(Path, [append, binary]) of
                {ok, Io} ->
                    R = file:change_mode(Path, 8#600),
                    _ = file:close(Io),
                    R;
                OpenError ->
                    OpenError
            end;
        DirError ->
            DirError
    end.

save_evidence(Path, Bytes) ->
    Sha = damage_tax_canonical:sha256_hex(Bytes),
    EvidencePath = evidence_path(Path, Sha),
    case filelib:ensure_dir(EvidencePath) of
        ok ->
            case file:change_mode(filename:dirname(EvidencePath), 8#700) of
                ok -> save_evidence_file(EvidencePath, Bytes, Sha);
                ModeError -> {error, {evidence_permission_failed, ModeError}}
            end;
        DirError ->
            {error, {evidence_directory_failed, DirError}}
    end.

save_evidence_file(Path, Bytes, Sha) ->
    case file:open(Path, [write, exclusive, binary]) of
        {ok, Io} ->
            Chmod = file:change_mode(Path, 8#600),
            R =
                case Chmod of
                    ok -> file:write(Io, Bytes);
                    ModeError -> ModeError
                end,
            R2 =
                case R of
                    ok -> file:sync(Io);
                    WriteError -> WriteError
                end,
            _ = file:close(Io),
            case R2 of
                ok -> {ok, Sha};
                SaveError -> {error, {evidence_write_failed, SaveError}}
            end;
        {error, eexist} ->
            case file:read_file(Path) of
                {ok, Existing} ->
                    case damage_tax_canonical:sha256_hex(Existing) of
                        Sha -> {ok, Sha};
                        _ -> {error, evidence_hash_collision_or_corruption}
                    end;
                ReadError ->
                    ReadError
            end;
        OpenError ->
            {error, {evidence_open_failed, OpenError}}
    end.

evidence_check(_Path, Sha) when not is_binary(Sha); byte_size(Sha) =/= 64 -> false;
evidence_check(Path, Sha) ->
    case file:read_file(evidence_path(Path, Sha)) of
        {ok, Bytes} -> damage_tax_canonical:sha256_hex(Bytes) =:= Sha;
        _ -> false
    end.

evidence_path(Journal, Sha) ->
    filename:join([filename:dirname(Journal), "evidence", binary_to_list(Sha) ++ ".json"]).
