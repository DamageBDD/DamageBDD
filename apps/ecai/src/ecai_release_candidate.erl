-module(ecai_release_candidate).

-export([
    propose/0,
    propose/1,
    tags/0,
    tags/1,
    description/0,
    description/1
]).

-define(DEFAULT_TIMEOUT_MS, 30000).
-define(DEFAULT_INITIAL_VERSION, {0, 1, 0}).
-define(DEFAULT_TAG_LIMIT, 50).

propose() ->
    propose(#{}).

propose(Opts) when is_map(Opts) ->
    Repo = repo_root(Opts),
    with_repo_state(Repo, Opts, fun(State0) ->
        Semantic = semantic_tags(maps:get(tags, State0)),
        Branch = maps:get(branch, State0),
        case next_candidate(Branch, Semantic, Opts) of
            {error, _} = Error ->
                Error;
            {ok, Candidate} ->
                Base = comparison_base(Candidate, Semantic),
                State = State0#{
                    semantic_tags => Semantic,
                    candidate => Candidate,
                    base_tag => Base
                },
                case build_description(Repo, State, Opts) of
                    {ok, Description, Evidence} ->
                        {ok, proposal(State, Description, Evidence, Opts)};
                    {error, _} = Error ->
                        Error
                end
        end
    end).

tags() ->
    tags(#{}).

tags(Opts) when is_map(Opts) ->
    Repo = repo_root(Opts),
    with_repo_state(Repo, Opts, fun(State) ->
        {ok, #{
            branch => maps:get(branch, State),
            head => maps:get(head, State),
            tags_at_head => maps:get(tags_at_head, State),
            tags => maps:get(tags, State),
            semantic_tags => semantic_tags(maps:get(tags, State))
        }}
    end).

description() ->
    description(#{}).

description(Opts) when is_map(Opts) ->
    case propose(Opts) of
        {ok, #{description := Description}} -> {ok, Description};
        {error, _} = Error -> Error
    end.

with_repo_state(Repo, Opts, Fun) ->
    case repository_state(Repo, Opts) of
        {ok, State} -> Fun(State);
        {error, _} = Error -> Error
    end.

repository_state(Repo, Opts) ->
    case ecai_repair_git:head(Repo) of
        {error, _} = Error -> Error;
        {ok, Head} ->
            case ecai_repair_git:branch(Repo) of
                {error, _} = Error -> Error;
                {ok, Branch} ->
                    case git_lines(Repo, ["tag", "--merged", "HEAD", "--sort=-version:refname"], Opts) of
                        {error, _} = Error -> Error;
                        {ok, Tags} ->
                            case git_lines(Repo, ["tag", "--points-at", "HEAD", "--sort=-version:refname"], Opts) of
                                {error, _} = Error -> Error;
                                {ok, HeadTags} ->
                                    case git(Repo, ["status", "--porcelain=v1"], Opts) of
                                        {error, _} = Error -> Error;
                                        {ok, Status} ->
                                            case ensure_clean(Status, Opts) of
                                                ok ->
                                                    {ok, #{
                                                        repo_root => to_binary(Repo),
                                                        branch => Branch,
                                                        head => Head,
                                                        tags => Tags,
                                                        tags_at_head => HeadTags,
                                                        dirty => trim(Status) =/= <<>>
                                                    }};
                                                {error, _} = Error -> Error
                                            end
                                    end
                            end
                    end
            end
    end.

ensure_clean(Status, Opts) ->
    case {trim(Status), maps:get(allow_dirty, Opts, false)} of
        {<<>>, _} -> ok;
        {_, true} -> ok;
        {Dirty, false} -> {error, {dirty_worktree, Dirty}}
    end.

next_candidate(Branch, Semantic, Opts) ->
    Prefix = preferred_prefix(Semantic, Opts),
    case branch_version(Branch) of
        {ok, Core} -> candidate_for_core(Core, Prefix, Semantic, branch);
        not_found ->
            case highest_release_line(Semantic) of
                none ->
                    Core = maps:get(initial_version, Opts, ?DEFAULT_INITIAL_VERSION),
                    candidate_for_core(normalize_core(Core), Prefix, Semantic, initial);
                #{kind := rc, core := Core} ->
                    candidate_for_core(Core, Prefix, Semantic, existing_rc);
                #{kind := stable, core := {Major, Minor, Patch}} ->
                    candidate_for_core({Major, Minor, Patch + 1}, Prefix, Semantic, patch_bump)
            end
    end.

candidate_for_core(Core, Prefix, Semantic, Source) ->
    case stable_for_core(Core, Semantic) of
        true when Source =:= branch ->
            {error, {release_already_tagged, format_stable(Prefix, Core)}};
        _ ->
            Rc = highest_rc(Core, Semantic) + 1,
            {ok, #{
                kind => rc,
                core => Core,
                rc => Rc,
                prefix => Prefix,
                source => Source,
                tag => format_rc(Prefix, Core, Rc)
            }}
    end.

comparison_base(Candidate, Semantic) ->
    Core = maps:get(core, Candidate),
    Rc = maps:get(rc, Candidate),
    PriorRcs = [
        Tag
        || Tag = #{kind := rc, core := TagCore, rc := N} <- Semantic,
           TagCore =:= Core,
           N < Rc
    ],
    case sort_semantic(PriorRcs) of
        [Latest | _] -> maps:get(tag, Latest);
        [] ->
            Stable = [Tag || Tag = #{kind := stable} <- Semantic, core_lt(maps:get(core, Tag), Core)],
            case sort_semantic(Stable) of
                [LatestStable | _] -> maps:get(tag, LatestStable);
                [] -> undefined
            end
    end.

proposal(State, Description, Evidence, Opts) ->
    Candidate = maps:get(candidate, State),
    TagLimit = positive_int(maps:get(tag_limit, Opts, ?DEFAULT_TAG_LIMIT), ?DEFAULT_TAG_LIMIT),
    Tags = maps:get(tags, State),
    #{
        tag => maps:get(tag, Candidate),
        version => version_map(Candidate),
        proposal_source => maps:get(source, Candidate),
        branch => maps:get(branch, State),
        head => maps:get(head, State),
        base_tag => maps:get(base_tag, State),
        tags_at_head => maps:get(tags_at_head, State),
        current_tags => lists:sublist(Tags, TagLimit),
        current_tag_count => length(Tags),
        description => Description,
        evidence => Evidence
    }.

build_description(Repo, State, Opts) ->
    Base = maps:get(base_tag, State),
    Candidate = maps:get(candidate, State),
    case release_changes(Repo, Base, Opts) of
        {error, _} = Error -> Error;
        {ok, Changes} ->
            Learned = learned_changes(Repo, Changes, Opts),
            case Learned of
                {error, _} = Error -> Error;
                {ok, LearnedChanges} ->
                    case commit_log(Repo, Base, Opts) of
                        {error, _} = Error -> Error;
                        {ok, Commits} ->
                            SnapshotId = snapshot_id(Repo),
                            Evidence0 = #{
                                branch => maps:get(branch, State),
                                head => maps:get(head, State),
                                base_tag => Base,
                                tag => maps:get(tag, Candidate),
                                changed_files => Changes,
                                learned_changes => LearnedChanges,
                                commits => Commits,
                                snapshot_id => SnapshotId
                            },
                            EvidenceHash = sha256_hex(term_to_binary(Evidence0, [deterministic])),
                            Evidence = Evidence0#{evidence_sha256 => EvidenceHash},
                            {ok, format_description(Evidence), Evidence}
                    end
            end
    end.

release_changes(Repo, undefined, Opts) ->
    case git_lines(Repo, ["ls-tree", "-r", "--name-only", "HEAD"], Opts) of
        {ok, Paths} -> {ok, [#{status => <<"A">>, path => Path} || Path <- Paths]};
        {error, _} = Error -> Error
    end;
release_changes(Repo, Base, Opts) ->
    Range = binary_to_list(Base) ++ "..HEAD",
    case git_lines(Repo, ["diff", "--name-status", "--find-renames", Range, "--"], Opts) of
        {ok, Lines} -> {ok, [parse_change(Line) || Line <- Lines]};
        {error, _} = Error -> Error
    end.

parse_change(Line) ->
    case binary:split(Line, <<"\t">>, [global]) of
        [Status, Path] -> #{status => Status, path => Path};
        [Status, From, Path] -> #{status => Status, from => From, path => Path};
        _ -> #{status => <<"?">>, path => Line}
    end.

learned_changes(Repo, Changes, Opts) ->
    Relevant = [C || C <- Changes, source_identity(maps:get(path, C)) =/= error],
    collect_learned(Repo, Relevant, Opts, []).

collect_learned(_Repo, [], _Opts, Acc) ->
    {ok, lists:reverse(Acc)};
collect_learned(Repo, [Change | Rest], Opts, Acc) ->
    case learned_change(Repo, Change, Opts) of
        {ok, Item} -> collect_learned(Repo, Rest, Opts, [Item | Acc]);
        {skip, _} -> collect_learned(Repo, Rest, Opts, Acc);
        {error, _} = Error -> Error
    end.

learned_change(_Repo, #{status := <<"D", _/binary>>, path := Path}, _Opts) ->
    case source_identity(Path) of
        {ok, App, Module} ->
            {ok, #{application => App, module => Module, status => <<"D">>, path => Path, purpose => <<"module removed">>}};
        error -> {skip, non_ecai_source}
    end;
learned_change(Repo, #{status := Status, path := Path}, Opts) ->
    case source_identity(Path) of
        error -> {skip, non_ecai_source};
        {ok, App, Module} ->
            case find_analysis(App, Module, Path) of
                not_found -> maybe_missing_learning(App, Module, Path, Opts);
                {ok, ModuleKey, Analysis} ->
                    case ensure_analysis_at_head(Repo, Path, Analysis, Opts) of
                        ok ->
                            Card = value_or_empty(ecai_learning_store:get_module_knowledge(App, ModuleKey)),
                            {ok, #{
                                application => App,
                                module => ModuleKey,
                                status => Status,
                                path => Path,
                                purpose => mget(<<"purpose">>, Card, <<"learned module changed">>),
                                responsibilities => mget(<<"responsibilities">>, Card, [])
                            }};
                        {error, _} = Error -> Error
                    end
            end
    end.

maybe_missing_learning(App, Module, Path, Opts) ->
    case maps:get(require_fresh_learning, Opts, true) of
        true -> {error, {learning_not_found, App, Module, Path}};
        false -> {ok, #{application => App, module => Module, status => <<"?">>, path => Path, purpose => <<"learning unavailable">>}}
    end.

ensure_analysis_at_head(Repo, Path, Analysis, Opts) ->
    case maps:get(require_fresh_learning, Opts, true) of
        false -> ok;
        true ->
            Object = "HEAD:" ++ binary_to_list(Path),
            case git(Repo, ["show", Object], Opts) of
                {error, _} = Error -> Error;
                {ok, Source} ->
                    HeadHash = sha256_hex(Source),
                    LearnedHash = maps:get(source_sha256, Analysis, undefined),
                    case hashes_equal(HeadHash, LearnedHash) of
                        true -> ok;
                        false -> {error, {stale_code_learning, maps:get(application, Analysis, undefined), maps:get(module, Analysis, undefined), #{head => HeadHash, learned => LearnedHash}}}
                    end
            end
    end.

commit_log(Repo, Base, Opts) ->
    Range = case Base of undefined -> "HEAD"; _ -> binary_to_list(Base) ++ "..HEAD" end,
    Limit = positive_int(maps:get(commit_limit, Opts, 60), 60),
    Args = ["log", "--first-parent", "--max-count=" ++ integer_to_list(Limit), "--format=%H%x09%s", Range],
    case git_lines(Repo, Args, Opts) of
        {ok, Lines} -> {ok, [parse_commit(Line) || Line <- Lines]};
        {error, _} = Error -> Error
    end.

parse_commit(Line) ->
    case binary:match(Line, <<"\t">>) of
        {Pos, 1} -> #{hash => binary:part(Line, 0, Pos), subject => binary:part(Line, Pos + 1, byte_size(Line) - Pos - 1)};
        nomatch -> #{hash => <<>>, subject => Line}
    end.

format_description(Evidence) ->
    Base = case maps:get(base_tag, Evidence) of undefined -> <<"<initial repository state>">>; Value -> Value end,
    iolist_to_binary([
        maps:get(tag, Evidence), <<" release candidate\n\n">>,
        <<"Branch: ">>, maps:get(branch, Evidence), <<"\n">>,
        <<"Commit: ">>, maps:get(head, Evidence), <<"\n">>,
        <<"Compared with: ">>, Base, <<"\n">>,
        <<"ECAI snapshot: ">>, printable(maps:get(snapshot_id, Evidence)), <<"\n">>,
        <<"Evidence SHA-256: ">>, maps:get(evidence_sha256, Evidence), <<"\n\n">>,
        <<"Learned changes\n">>, learned_lines(maps:get(learned_changes, Evidence)),
        <<"\nCommit history\n">>, commit_lines(maps:get(commits, Evidence))
    ]).

learned_lines([]) -> <<"- No learned Erlang modules changed.\n">>;
learned_lines(Changes) ->
    [[<<"- ">>, status_name(maps:get(status, C)), <<" ">>, atom_to_binary(maps:get(application, C), utf8), <<":">>, module_binary(maps:get(module, C)), <<" — ">>, compact(maps:get(purpose, C, <<"changed">>)), <<"\n">>] || C <- Changes].

commit_lines([]) -> <<"- No commits after comparison base.\n">>;
commit_lines(Commits) ->
    [[<<"- ">>, short_hash(maps:get(hash, C)), <<" ">>, maps:get(subject, C), <<"\n">>] || C <- Commits].

semantic_tags(Tags) -> sort_semantic([Parsed || Tag <- Tags, Parsed <- parse_tag(Tag)]).

parse_tag(Tag) ->
    RcPattern = <<"^(v?)([0-9]+)\\.([0-9]+)\\.([0-9]+)-rc(?:[.-]?)([0-9]+)$">>,
    StablePattern = <<"^(v?)([0-9]+)\\.([0-9]+)\\.([0-9]+)$">>,
    case re:run(Tag, RcPattern, [{capture, all_but_first, binary}]) of
        {match, [Prefix, Major, Minor, Patch, Rc]} ->
            [#{tag => Tag, kind => rc, prefix => Prefix, core => ints(Major, Minor, Patch), rc => binary_to_integer(Rc)}];
        nomatch ->
            case re:run(Tag, StablePattern, [{capture, all_but_first, binary}]) of
                {match, [Prefix, Major, Minor, Patch]} ->
                    [#{tag => Tag, kind => stable, prefix => Prefix, core => ints(Major, Minor, Patch)}];
                nomatch -> []
            end
    end.

sort_semantic(Tags) ->
    lists:sort(fun(A, B) -> semantic_key(A) > semantic_key(B) end, Tags).

semantic_key(#{core := {Major, Minor, Patch}, kind := stable}) -> {Major, Minor, Patch, 2, 0};
semantic_key(#{core := {Major, Minor, Patch}, kind := rc, rc := Rc}) -> {Major, Minor, Patch, 1, Rc}.

highest_release_line([]) -> none;
highest_release_line([First | _]) -> First.

highest_rc(Core, Semantic) ->
    lists:foldl(fun
        (#{kind := rc, core := TagCore, rc := Rc}, Acc) when TagCore =:= Core -> erlang:max(Rc, Acc);
        (_, Acc) -> Acc
    end, 0, Semantic).

stable_for_core(Core, Semantic) ->
    lists:any(fun
        (#{kind := stable, core := TagCore}) -> TagCore =:= Core;
        (_) -> false
    end, Semantic).

preferred_prefix(Semantic, Opts) ->
    case maps:get(tag_prefix, Opts, undefined) of
        undefined ->
            case Semantic of [#{prefix := Prefix} | _] -> Prefix; [] -> <<"v">> end;
        Prefix -> to_binary(Prefix)
    end.

branch_version(Branch) ->
    Pattern = <<"(?:^|[/_-])(?:release|rc)[/_-](?:v)?([0-9]+)\\.([0-9]+)\\.([0-9]+)(?:$|[/_-])">>,
    case re:run(Branch, Pattern, [{capture, all_but_first, binary}, caseless]) of
        {match, [Major, Minor, Patch]} -> {ok, ints(Major, Minor, Patch)};
        nomatch -> not_found
    end.

source_identity(Path) ->
    Parts = filename:split(binary_to_list(Path)),
    case Parts of
        ["apps", App0, Dir | _] when Dir =:= "src"; Dir =:= "test"; Dir =:= "tests" ->
            case app_atom(App0) of
                undefined -> error;
                App ->
                    case filename:extension(binary_to_list(Path)) of
                        ".erl" ->
                            ModuleName = unicode:characters_to_binary(
                                filename:basename(binary_to_list(Path), ".erl")
                            ),
                            {ok, App, ModuleName};
                        _ -> error
                    end
            end;
        _ -> error
    end.

app_atom("damage") -> damage;
app_atom("ecai") -> ecai;
app_atom("erm") -> erm;
app_atom(_) -> undefined.

find_analysis(App, ModuleName, Path) ->
    case existing_module_atom(ModuleName) of
        {ok, Module} ->
            case ecai_learning_store:get_analysis(App, Module) of
                {ok, Analysis} -> {ok, Module, Analysis};
                not_found -> find_analysis_by_path(App, ModuleName, Path)
            end;
        error ->
            find_analysis_by_path(App, ModuleName, Path)
    end.

find_analysis_by_path(App, ModuleName, Path) ->
    Analyses = ecai_learning_store:analyses(App),
    case [
        {maps:get(module, Analysis, undefined), Analysis}
        || Analysis <- Analyses,
           module_matches(ModuleName, Path, Analysis)
    ] of
        [{Module, Analysis} | _] when is_atom(Module) -> {ok, Module, Analysis};
        _ -> not_found
    end.

module_matches(ModuleName, Path, Analysis) ->
    Module = maps:get(module, Analysis, undefined),
    SourceName = maps:get(source_name, Analysis, <<>>),
    ModuleMatch = is_atom(Module) andalso atom_to_binary(Module, utf8) =:= ModuleName,
    PathMatch = filename:basename(path_to_list(SourceName)) =:= filename:basename(binary_to_list(Path)),
    ModuleMatch andalso PathMatch.

existing_module_atom(Name) ->
    try binary_to_existing_atom(Name, utf8) of
        Module -> {ok, Module}
    catch
        error:badarg -> error
    end.

snapshot_id(Repo) ->
    try ecai_learning_snapshot:build(#{repo_root => Repo}) of
        #{snapshot_id := Id} -> Id;
        _ -> undefined
    catch _:_ -> undefined end.

version_map(#{core := {Major, Minor, Patch}, rc := Rc}) -> #{major => Major, minor => Minor, patch => Patch, rc => Rc}.
format_rc(Prefix, {Major, Minor, Patch}, Rc) -> iolist_to_binary([Prefix, integer_to_binary(Major), <<".">>, integer_to_binary(Minor), <<".">>, integer_to_binary(Patch), <<"-rc.">>, integer_to_binary(Rc)]).
format_stable(Prefix, {Major, Minor, Patch}) -> iolist_to_binary([Prefix, integer_to_binary(Major), <<".">>, integer_to_binary(Minor), <<".">>, integer_to_binary(Patch)]).
ints(A, B, C) -> {binary_to_integer(A), binary_to_integer(B), binary_to_integer(C)}.
normalize_core({A, B, C}) when is_integer(A), is_integer(B), is_integer(C), A >= 0, B >= 0, C >= 0 -> {A, B, C};
normalize_core(Other) -> erlang:error({invalid_initial_version, Other}).
core_lt({A1, B1, C1}, {A2, B2, C2}) -> {A1, B1, C1} < {A2, B2, C2}.

status_name(<<"A", _/binary>>) -> <<"ADD">>;
status_name(<<"M", _/binary>>) -> <<"CHANGE">>;
status_name(<<"D", _/binary>>) -> <<"REMOVE">>;
status_name(<<"R", _/binary>>) -> <<"RENAME">>;
status_name(Status) -> Status.

short_hash(Hash) when byte_size(Hash) > 12 -> binary:part(Hash, 0, 12);
short_hash(Hash) -> Hash.
compact(Bin) when is_binary(Bin) -> binary:replace(binary:replace(Bin, <<"\n">>, <<" ">>, [global]), <<"\r">>, <<" ">>, [global]);
compact(List) when is_list(List) -> iolist_to_binary(lists:join(<<"; ">>, lists:sublist([compact(V) || V <- List], 3)));
compact(Value) -> iolist_to_binary(io_lib:format("~tp", [Value])).

module_binary(Module) when is_atom(Module) -> atom_to_binary(Module, utf8);
module_binary(Module) when is_binary(Module) -> Module;
module_binary(Module) -> to_binary(Module).

value_or_empty({ok, Value}) -> Value;
value_or_empty(_) -> #{}.
mget(Key, Map, Default) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error ->
            try binary_to_existing_atom(Key, utf8) of Atom -> maps:get(Atom, Map, Default)
            catch error:badarg -> Default end
    end;
mget(_, _, Default) -> Default.

repo_root(Opts) -> filename:absname(path_to_list(maps:get(repo_root, Opts, application:get_env(ecai, code_repo_root, ".")))).
git_lines(Repo, Args, Opts) ->
    case git(Repo, Args, Opts) of
        {ok, Output} -> {ok, lines(Output)};
        {error, _} = Error -> Error
    end.
git(Repo, Args, Opts) -> ecai_repair_git:run(Repo, Args, command_timeout(Opts)).
command_timeout(Opts) -> positive_int(maps:get(command_timeout_ms, Opts, application:get_env(ecai, code_patch_command_timeout_ms, ?DEFAULT_TIMEOUT_MS)), ?DEFAULT_TIMEOUT_MS).
positive_int(N, _Default) when is_integer(N), N > 0 -> N;
positive_int(_, Default) -> Default.
lines(Bin) -> [Line || Part <- binary:split(Bin, <<"\n">>, [global]), Line <- [trim(Part)], Line =/= <<>>].
trim(Bin) -> unicode:characters_to_binary(string:trim(binary_to_list(Bin))).
sha256_hex(Bin) ->
    unicode:characters_to_binary(
        string:lowercase(binary_to_list(binary:encode_hex(crypto:hash(sha256, Bin))))
    ).
hashes_equal(A, B) when is_binary(A), is_binary(B) -> string:lowercase(binary_to_list(A)) =:= string:lowercase(binary_to_list(B));
hashes_equal(_, _) -> false.
printable(undefined) -> <<"unavailable">>;
printable(Value) -> to_binary(Value).
path_to_list(Value) when is_list(Value) -> Value;
path_to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value).
to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).
