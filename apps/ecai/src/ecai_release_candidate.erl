-module(ecai_release_candidate).

-export([
    propose/0,
    propose/1,
    propose_release/0,
    propose_release/1,
    tags/0,
    tags/1,
    description/0,
    description/1,
    release_description/0,
    release_description/1,
    tag/1,
    tag/2,
    tag_release_candidate/0,
    tag_release_candidate/1,
    tag_release/0,
    tag_release/1
]).

-ifdef(TEST).
-export([create_annotated_tag/5, learning_status_ready/1]).
-endif.

-define(DEFAULT_TIMEOUT_MS, 30000).
-define(DEFAULT_INITIAL_VERSION, {0, 1, 0}).
-define(DEFAULT_TAG_LIMIT, 50).

propose() ->
    propose(#{}).

propose(Opts) when is_map(Opts) ->
    propose_kind(rc, Opts).

propose_release() ->
    propose_release(#{}).

propose_release(Opts) when is_map(Opts) ->
    propose_kind(stable, Opts).

propose_kind(Kind, Opts) ->
    Repo = repo_root(Opts),
    with_repo_state(Repo, Opts, fun(State0) ->
        Semantic = semantic_tags(maps:get(tags, State0)),
        Branch = maps:get(branch, State0),
        case next_version(Kind, Branch, Semantic, Opts) of
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
    proposal_description(propose(Opts)).

release_description() ->
    release_description(#{}).

release_description(Opts) when is_map(Opts) ->
    proposal_description(propose_release(Opts)).

proposal_description({ok, #{description := Description}}) ->
    {ok, Description};
proposal_description({error, _} = Error) ->
    Error.

tag_release_candidate() ->
    tag_release_candidate(#{}).

tag_release_candidate(Opts) when is_map(Opts) ->
    tag(rc, Opts).

tag_release() ->
    tag_release(#{}).

tag_release(Opts) when is_map(Opts) ->
    tag(stable, Opts).

tag(Kind) ->
    tag(Kind, #{}).

tag(Kind0, Opts) when is_map(Opts) ->
    case normalize_release_kind(Kind0) of
        {error, _} = Error ->
            Error;
        Kind ->
            case ensure_learning_quiescent(Opts) of
                ok -> tag_attempt(Kind, Opts, 0);
                {error, _} = Error -> Error
            end
    end.

tag_attempt(Kind, Opts, Attempt) ->
    ProposalResult =
        case Kind of
            rc -> propose(Opts);
            stable -> propose_release(Opts)
        end,
    case ProposalResult of
        {error, _} = Error ->
            Error;
        {ok, Proposal} ->
            case create_tag(Kind, Proposal, Opts) of
                {error, {learning_snapshot_evidence_mismatch, _}} = Error ->
                    RetryLimit = non_negative_int(maps:get(learning_snapshot_retry_count, Opts, 1), 1),
                    case Attempt < RetryLimit of
                        false -> Error;
                        true ->
                            case ensure_learning_quiescent(Opts) of
                                ok -> tag_attempt(Kind, Opts, Attempt + 1);
                                {error, _} = ReadyError -> ReadyError
                            end
                    end;
                Result ->
                    Result
            end
    end.

ensure_learning_quiescent(Opts) ->
    case {
        maps:get(require_learning_reference, Opts, true),
        maps:get(require_learning_quiescent, Opts, true)
    } of
        {false, _} ->
            ok;
        {_, false} ->
            ok;
        {true, true} ->
            try ecai_codebase_learner:status() of
                Status when is_map(Status) ->
                    case learning_status_ready(Status) of
                        true -> ok;
                        false -> {error, {learning_not_quiescent, Status}}
                    end;
                {error, Reason} ->
                    {error, {learning_status_unavailable, Reason}};
                Other ->
                    {error, {unexpected_learning_status, Other}}
            catch
                Class:Reason:Stack ->
                    {error, {learning_status_failed, Class, Reason, Stack}}
            end
    end.

learning_status_ready(Status) when is_map(Status) ->
    maps:get(phase, Status, undefined) =:= idle andalso
        maps:get(ready, Status, false) =:= true andalso
        maps:get(inflight_count, Status, 0) =:= 0 andalso
        maps:get(queued, Status, 0) =:= 0 andalso
        maps:get(refresh_requested, Status, false) =:= false;
learning_status_ready(_) ->
    false.

normalize_release_kind(rc) -> rc;
normalize_release_kind(release_candidate) -> rc;
normalize_release_kind(stable) -> stable;
normalize_release_kind(release) -> stable;
normalize_release_kind(Other) -> {error, {invalid_release_kind, Other}}.

create_tag(Kind, Proposal, Opts) ->
    Repo = repo_root(Opts),
    Tag = maps:get(tag, Proposal),
    Head = maps:get(head, Proposal),
    case resolve_target_commit(Repo, Opts) of
        {error, _} = Error ->
            Error;
        {ok, Target} when Target =/= Head ->
            {error, {learning_commit_mismatch, #{requested => Target, learned_head => Head}}};
        {ok, Target} ->
            case ensure_tag_available(Repo, Tag, Opts) of
                {error, _} = Error ->
                    Error;
                ok ->
                    case prepare_learning_reference(Repo, Proposal, Opts) of
                        {error, _} = Error ->
                            Error;
                        {ok, LearningReference0, Snapshot} ->
                            case persist_release_reference(
                                Repo, Kind, Proposal, LearningReference0, Snapshot, Opts
                            ) of
                                {error, _} = Error ->
                                    Error;
                                {ok, LearningReference} ->
                                    Annotation = format_tag_annotation(Proposal, LearningReference),
                                    case create_annotated_tag(
                                        Repo, Tag, Target, Annotation, Opts
                                    ) of
                                        {error, _} = Error ->
                                            Error;
                                        ok ->
                                            tag_result(
                                                Repo,
                                                Kind,
                                                Proposal,
                                                Target,
                                                Annotation,
                                                LearningReference,
                                                Opts
                                            )
                                    end
                            end
                    end
            end
    end.

resolve_target_commit(Repo, Opts) ->
    Ref = maps:get(commit, Opts, <<"HEAD">>),
    RefArg = binary_to_list(to_binary(Ref)) ++ "^{commit}",
    case git(Repo, ["rev-parse", "--verify", RefArg], Opts) of
        {ok, Commit0} -> {ok, trim(Commit0)};
        {error, _} = Error -> Error
    end.

ensure_tag_available(Repo, Tag, Opts) ->
    Ref = <<"refs/tags/", Tag/binary>>,
    case git(Repo, ["check-ref-format", Ref], Opts) of
        {error, _} ->
            {error, {invalid_tag_name, Tag}};
        {ok, _} ->
            case git_lines(Repo, ["tag", "--list"], Opts) of
                {ok, Tags} ->
                    case lists:member(Tag, Tags) of
                        true -> {error, {tag_already_exists, Tag}};
                        false -> ok
                    end;
                {error, _} = Error -> Error
            end
    end.

prepare_learning_reference(Repo, Proposal, Opts) ->
    Strict = maps:get(require_learning_reference, Opts, true),
    case load_learning_snapshot(Repo, Opts) of
        {ok, SnapshotPath, Snapshot} ->
            case ensure_snapshot_commit(Snapshot, maps:get(head, Proposal)) of
                ok ->
                    Evidence = maps:get(evidence, Proposal, #{}),
                    case ensure_evidence_in_snapshot(Snapshot, Evidence) of
                        ok ->
                            Reference = learning_reference(SnapshotPath, Snapshot, Evidence),
                            {ok, Reference, Snapshot};
                        {error, _} = Error when Strict ->
                            Error;
                        {error, Reason} ->
                            {ok, unavailable_learning_reference(Reason), undefined}
                    end;
                {error, _} = Error when Strict ->
                    Error;
                {error, Reason} ->
                    {ok, unavailable_learning_reference(Reason), undefined}
            end;
        {error, _} = Error when Strict ->
            Error;
        {error, Reason} ->
            {ok, unavailable_learning_reference(Reason), undefined}
    end.

load_learning_snapshot(Repo, Opts) ->
    SnapshotOpts = snapshot_opts(Repo, Opts),
    try
        case maps:get(write_learning_snapshot, Opts, true) of
            true ->
                case ecai_learning_snapshot:write(SnapshotOpts) of
                    {ok, Path, Snapshot} -> {ok, Path, Snapshot};
                    {error, _} = Error -> Error;
                    Other -> {error, {unexpected_learning_snapshot_result, Other}}
                end;
            false ->
                Snapshot = ecai_learning_snapshot:build(SnapshotOpts),
                {ok, undefined, Snapshot}
        end
    catch
        Class:Reason:Stack ->
            {error, {learning_snapshot_failed, Class, Reason, Stack}}
    end.

snapshot_opts(Repo, Opts) ->
    Base = #{repo_root => Repo},
    case maps:get(state_root, Opts, undefined) of
        undefined -> Base;
        StateRoot -> Base#{state_root => StateRoot}
    end.

ensure_snapshot_commit(Snapshot, Head) ->
    Git = maps:get(git, Snapshot, #{}),
    case maps:get(commit, Git, undefined) of
        Head -> ok;
        Other -> {error, {learning_snapshot_commit_mismatch, #{snapshot => Other, head => Head}}}
    end.

ensure_evidence_in_snapshot(Snapshot, Evidence) ->
    Learning = maps:get(learning, Snapshot, #{}),
    Analyses = maps:get(analyses, Learning, []),
    Cards = maps:get(module_knowledge, Learning, []),
    References = changed_module_references(maps:get(learned_changes, Evidence, [])),
    ensure_module_references(References, Analyses, Cards).

ensure_module_references([], _Analyses, _Cards) ->
    ok;
ensure_module_references([Ref | Rest], Analyses, Cards) ->
    case maps:get(source_sha256, Ref, undefined) of
        undefined ->
            ensure_module_references(Rest, Analyses, Cards);
        _ ->
            case module_reference_current(Ref, Analyses, Cards) of
                true -> ensure_module_references(Rest, Analyses, Cards);
                false ->
                    {error, {
                        learning_snapshot_evidence_mismatch,
                        module_reference_diagnostics(Ref, Analyses, Cards)
                    }}
            end
    end.

module_reference_current(Ref, Analyses, Cards) ->
    App = maps:get(application, Ref, undefined),
    Module = maps:get(module, Ref, undefined),
    AnalysisMatches = lists:any(
        fun(Analysis) ->
            maps:get(application, Analysis, undefined) =:= App andalso
                maps:get(module, Analysis, undefined) =:= Module andalso
                hashes_equal(
                    maps:get(source_sha256, Analysis, undefined),
                    maps:get(source_sha256, Ref, undefined)
                ) andalso
                hashes_equal(
                    maps:get(analysis_sha256, Analysis, undefined),
                    maps:get(analysis_sha256, Ref, undefined)
                )
        end,
        Analyses
    ),
    CardMatches = lists:any(
        fun(Card) ->
            maps:get(application, Card, undefined) =:= App andalso
                maps:get(module, Card, undefined) =:= Module andalso
                hashes_equal(
                    knowledge_card_digest(Card),
                    maps:get(knowledge_sha256, Ref, undefined)
                )
        end,
        Cards
    ),
    AnalysisMatches andalso CardMatches.

module_reference_diagnostics(Ref, Analyses, Cards) ->
    App = maps:get(application, Ref, undefined),
    Module = maps:get(module, Ref, undefined),
    SnapshotAnalyses = [
        maps:with([source_sha256, analysis_sha256], Analysis)
        || Analysis <- Analyses,
           maps:get(application, Analysis, undefined) =:= App,
           maps:get(module, Analysis, undefined) =:= Module
    ],
    SnapshotCards = [
        #{
            source_sha256 => mget(<<"source_sha256">>, Card, undefined),
            analysis_sha256 => mget(<<"analysis_sha256">>, Card, undefined),
            knowledge_sha256 => knowledge_card_digest(Card)
        }
        || Card <- Cards,
           maps:get(application, Card, undefined) =:= App,
           maps:get(module, Card, undefined) =:= Module
    ],
    Ref#{
        snapshot_analyses => SnapshotAnalyses,
        snapshot_knowledge => SnapshotCards
    }.

knowledge_card_digest(Card) when is_map(Card) ->
    deterministic_digest(maps:without([application, module], Card));
knowledge_card_digest(Other) ->
    deterministic_digest(Other).

learning_reference(SnapshotPath, Snapshot, Evidence) ->
    Learning = maps:get(learning, Snapshot, #{}),
    AppKnowledge = maps:get(app_knowledge, Learning, #{}),
    GlobalKnowledge = maps:get(global_knowledge, Learning, #{}),
    #{
        available => true,
        snapshot_id => maps:get(snapshot_id, Snapshot, undefined),
        snapshot_schema_version => maps:get(schema_version, Snapshot, undefined),
        snapshot_path => maybe_binary_path(SnapshotPath),
        snapshot_sha256 => deterministic_digest(Snapshot),
        learning_state_sha256 => deterministic_digest(Learning),
        global_knowledge_sha256 => deterministic_digest(GlobalKnowledge),
        application_knowledge_sha256 => maps:from_list([
            {App, deterministic_digest(maps:get(App, AppKnowledge, #{}))}
            || App <- [damage, ecai, erm]
        ]),
        relation_sets => maps:get(relation_sets, Learning, #{}),
        counts => learning_counts(Learning),
        changed_modules => changed_module_references(
            maps:get(learned_changes, Evidence, [])
        )
    }.

learning_counts(Learning) ->
    #{
        analyses => collection_size(maps:get(analyses, Learning, [])),
        module_knowledge => collection_size(maps:get(module_knowledge, Learning, [])),
        application_knowledge => collection_size(maps:get(app_knowledge, Learning, #{})),
        graphs => collection_size(maps:get(graphs, Learning, #{})),
        relation_sets => collection_size(maps:get(relation_sets, Learning, #{})),
        repairs => collection_size(maps:get(repairs, Learning, [])),
        log_incidents => collection_size(maps:get(log_incidents, Learning, []))
    }.

collection_size(Value) when is_list(Value) -> length(Value);
collection_size(Value) when is_map(Value) -> maps:size(Value);
collection_size(_) -> 0.

changed_module_references(Changes) ->
    [
        maps:with(
            [
                application,
                module,
                path,
                status,
                source_sha256,
                analysis_sha256,
                knowledge_sha256
            ],
            Change
        )
        || Change <- Changes
    ].

unavailable_learning_reference(Reason) ->
    #{
        available => false,
        error => to_binary(io_lib:format("~tp", [Reason]))
    }.

persist_release_reference(_Repo, _Kind, _Proposal, Reference, undefined, _Opts) ->
    {ok, Reference};
persist_release_reference(Repo, Kind, Proposal, Reference0, Snapshot, Opts) ->
    case maps:get(persist_release_reference, Opts, true) of
        false ->
            {ok, Reference0};
        true ->
            case ecai_code_paths:state_root(snapshot_opts(Repo, Opts)) of
                {error, _} = Error ->
                    Error;
                {ok, Root} ->
                    Tag = maps:get(tag, Proposal),
                    Name = "release-" ++ safe_tag_filename(Tag) ++ ".json",
                    Path = ecai_code_paths:log_file(Root, Name),
                    Payload = #{
                        schema => <<"ecai.release-learning-reference">>,
                        schema_version => 1,
                        release_kind => Kind,
                        tag => Tag,
                        commit => maps:get(head, Proposal),
                        base_tag => maps:get(base_tag, Proposal, undefined),
                        branch => maps:get(branch, Proposal),
                        evidence => maps:get(evidence, Proposal, #{}),
                        learning_reference => Reference0,
                        snapshot => Snapshot
                    },
                    Encoded = jsx:encode(json_safe(Payload)),
                    Tmp = Path ++ ".tmp",
                    case file:write_file(Tmp, Encoded) of
                        {error, Reason} ->
                            {error, {release_reference_write_failed, Path, Reason}};
                        ok ->
                            case file:rename(Tmp, Path) of
                                {error, Reason} ->
                                    _ = file:delete(Tmp),
                                    {error, {release_reference_rename_failed, Path, Reason}};
                                ok ->
                                    {ok, Reference0#{
                                        release_reference_path => to_binary(Path),
                                        release_reference_sha256 => sha256_hex(Encoded)
                                    }}
                            end
                    end
            end
    end.

safe_tag_filename(Tag0) ->
    Tag = binary_to_list(to_binary(Tag0)),
    [safe_filename_char(C) || C <- Tag].

safe_filename_char(C) when C >= $a, C =< $z -> C;
safe_filename_char(C) when C >= $A, C =< $Z -> C;
safe_filename_char(C) when C >= $0, C =< $9 -> C;
safe_filename_char($.) -> $.;
safe_filename_char($-) -> $-;
safe_filename_char($_) -> $_;
safe_filename_char(_) -> $_.

format_tag_annotation(Proposal, Reference) ->
    Description = maps:get(description, Proposal),
    Evidence = maps:get(evidence, Proposal, #{}),
    iolist_to_binary([
        Description,
        <<"\nECAI learning provenance\n">>,
        <<"ECAI-Release-Kind: ">>, release_kind_binary(maps:get(release_kind, Proposal)), <<"\n">>,
        <<"ECAI-Commit: ">>, maps:get(head, Proposal), <<"\n">>,
        <<"ECAI-Evidence-SHA256: ">>, printable(maps:get(evidence_sha256, Evidence, undefined)), <<"\n">>,
        learning_reference_lines(Reference)
    ]).

learning_reference_lines(#{available := false} = Reference) ->
    [
        <<"ECAI-Learning-Reference: unavailable\n">>,
        <<"ECAI-Learning-Error: ">>, maps:get(error, Reference, <<"unknown">>), <<"\n">>
    ];
learning_reference_lines(Reference) ->
    AppDigests = maps:get(application_knowledge_sha256, Reference, #{}),
    [
        <<"ECAI-Learning-Snapshot: ">>, printable(maps:get(snapshot_id, Reference, undefined)), <<"\n">>,
        <<"ECAI-Learning-Schema: ">>, printable(maps:get(snapshot_schema_version, Reference, undefined)), <<"\n">>,
        <<"ECAI-Learning-Snapshot-SHA256: ">>, printable(maps:get(snapshot_sha256, Reference, undefined)), <<"\n">>,
        <<"ECAI-Learning-State-SHA256: ">>, printable(maps:get(learning_state_sha256, Reference, undefined)), <<"\n">>,
        <<"ECAI-Global-Knowledge-SHA256: ">>, printable(maps:get(global_knowledge_sha256, Reference, undefined)), <<"\n">>,
        learning_counts_line(maps:get(counts, Reference, #{})),
        application_digest_lines(AppDigests),
        relation_reference_lines(maps:get(relation_sets, Reference, #{})),
        module_reference_lines(maps:get(changed_modules, Reference, [])),
        optional_reference_line(
            <<"ECAI-Learning-Snapshot-Path: ">>, maps:get(snapshot_path, Reference, undefined)
        ),
        optional_reference_line(
            <<"ECAI-Release-Reference: ">>, maps:get(release_reference_path, Reference, undefined)
        ),
        optional_reference_line(
            <<"ECAI-Release-Reference-SHA256: ">>,
            maps:get(release_reference_sha256, Reference, undefined)
        )
    ].

learning_counts_line(Counts) ->
    [
        <<"ECAI-Learning-Counts: analyses=">>, printable(maps:get(analyses, Counts, 0)),
        <<" module_knowledge=">>, printable(maps:get(module_knowledge, Counts, 0)),
        <<" application_knowledge=">>, printable(maps:get(application_knowledge, Counts, 0)),
        <<" graphs=">>, printable(maps:get(graphs, Counts, 0)),
        <<" relation_sets=">>, printable(maps:get(relation_sets, Counts, 0)),
        <<" repairs=">>, printable(maps:get(repairs, Counts, 0)),
        <<" log_incidents=">>, printable(maps:get(log_incidents, Counts, 0)), <<"\n">>
    ].

application_digest_lines(Digests) ->
    [
        [
            <<"ECAI-Application-Knowledge-">>, atom_to_binary(App, utf8), <<"-SHA256: ">>,
            printable(maps:get(App, Digests, undefined)), <<"\n">>
        ]
        || App <- [damage, ecai, erm]
    ].

relation_reference_lines(RelationSets) when is_map(RelationSets) ->
    [
        [
            <<"ECAI-Relation-Set: ">>, to_binary(Scope),
            <<" count=">>, printable(maps:get(count, Meta, 0)),
            <<" sha256=">>, printable(maps:get(key_digest_sha256, Meta, undefined)), <<"\n">>
        ]
        || {Scope, Meta} <- lists:sort(maps:to_list(RelationSets)),
           is_map(Meta)
    ];
relation_reference_lines(_) ->
    [].

module_reference_lines(References) ->
    [
        [
            <<"ECAI-Changed-Module: ">>, to_binary(maps:get(application, Ref, undefined)), <<":">>,
            module_binary(maps:get(module, Ref, undefined)),
            <<" source=">>, printable(maps:get(source_sha256, Ref, undefined)),
            <<" analysis=">>, printable(maps:get(analysis_sha256, Ref, undefined)),
            <<" knowledge=">>, printable(maps:get(knowledge_sha256, Ref, undefined)), <<"\n">>
        ]
        || Ref <- References
    ].

optional_reference_line(_Prefix, undefined) -> [];
optional_reference_line(Prefix, Value) -> [Prefix, printable(Value), <<"\n">>].

create_annotated_tag(Repo, Tag, Target, Annotation, Opts) ->
    TagMode =
        case maps:get(sign, Opts, false) of
            true -> "-s";
            false -> "-a"
        end,
    SigningArgs =
        case {maps:get(sign, Opts, false), maps:get(signing_key, Opts, undefined)} of
            {true, Key} when Key =/= undefined -> ["-u", to_binary(Key)];
            _ -> []
        end,
    case write_tag_message_file(Annotation, Opts) of
        {error, _} = Error ->
            Error;
        {ok, MessagePath} ->
            try
                Args =
                    ["tag", TagMode] ++ SigningArgs ++
                        ["-F", MessagePath, Tag, Target],
                case git(Repo, Args, Opts) of
                    {ok, _} -> ok;
                    {error, _} = Error -> Error
                end
            after
                _ = file:delete(MessagePath)
            end
    end.

write_tag_message_file(Annotation, Opts) ->
    Dir = tag_message_tmp_dir(Opts),
    Name = lists:flatten(
        io_lib:format(
            "ecai-release-tag-~B-~B.txt",
            [erlang:system_time(microsecond), erlang:unique_integer([positive, monotonic])]
        )
    ),
    Path = filename:join(Dir, Name),
    case filelib:ensure_dir(Path) of
        {error, Reason} ->
            {error, {tag_message_directory_failed, Dir, Reason}};
        ok ->
            case file:write_file(Path, Annotation, [binary]) of
                {error, Reason} ->
                    {error, {tag_message_write_failed, Path, Reason}};
                ok ->
                    _ = file:change_mode(Path, 8#600),
                    {ok, Path}
            end
    end.

tag_message_tmp_dir(Opts) ->
    case maps:get(tag_message_tmp_dir, Opts, undefined) of
        undefined ->
            case os:getenv("TMPDIR") of
                false -> "/tmp";
                "" -> "/tmp";
                Dir -> Dir
            end;
        Dir ->
            path_to_list(Dir)
    end.

tag_result(Repo, Kind, Proposal, Target, Annotation, Reference, Opts) ->
    Tag = maps:get(tag, Proposal),
    TagObjectRef = binary_to_list(Tag) ++ "^{tag}",
    case git(Repo, ["rev-parse", "--verify", TagObjectRef], Opts) of
        {error, _} = Error ->
            Error;
        {ok, TagObject0} ->
            TagObject = trim(TagObject0),
            {ok, Proposal#{
                created => true,
                release_kind => Kind,
                commit => Target,
                tag_object => TagObject,
                annotation_sha256 => sha256_hex(Annotation),
                learning_reference => Reference,
                push_refspec => <<"refs/tags/", Tag/binary>>
            }}
    end.

release_kind_binary(rc) -> <<"release_candidate">>;
release_kind_binary(stable) -> <<"release">>.

maybe_binary_path(undefined) -> undefined;
maybe_binary_path(Path) -> to_binary(Path).

deterministic_digest(Value) ->
    sha256_hex(term_to_binary(Value, [deterministic])).

json_safe(Map) when is_map(Map) ->
    maps:from_list([{json_key(K), json_safe(V)} || {K, V} <- maps:to_list(Map)]);
json_safe(List) when is_list(List) -> [json_safe(V) || V <- List];
json_safe(Tuple) when is_tuple(Tuple) -> [json_safe(V) || V <- tuple_to_list(Tuple)];
json_safe(undefined) -> null;
json_safe(true) -> true;
json_safe(false) -> false;
json_safe(null) -> null;
json_safe(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
json_safe(Bin) when is_binary(Bin) -> Bin;
json_safe(Number) when is_number(Number) -> Number;
json_safe(Other) -> to_binary(Other).

json_key(Key) when is_binary(Key) -> Key;
json_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
json_key(Key) when is_list(Key) -> unicode:characters_to_binary(Key);
json_key(Key) -> to_binary(Key).

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

next_version(rc, Branch, Semantic, Opts) ->
    next_candidate(Branch, Semantic, Opts);
next_version(stable, Branch, Semantic, Opts) ->
    next_release(Branch, Semantic, Opts).

next_candidate(Branch, Semantic, Opts) ->
    Prefix = preferred_prefix(Semantic, Opts),
    case requested_core(Opts) of
        {error, _} = Error ->
            Error;
        {ok, Core} ->
            candidate_for_core(Core, Prefix, Semantic, explicit);
        not_found ->
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
                            candidate_for_core(
                                {Major, Minor, Patch + 1}, Prefix, Semantic, patch_bump
                            )
                    end
            end
    end.

next_release(Branch, Semantic, Opts) ->
    Prefix = preferred_prefix(Semantic, Opts),
    case requested_core(Opts) of
        {error, _} = Error ->
            Error;
        {ok, Core} ->
            release_for_core(Core, Prefix, Semantic, explicit);
        not_found ->
            case branch_version(Branch) of
                {ok, Core} ->
                    release_for_core(Core, Prefix, Semantic, branch);
                not_found ->
                    case highest_release_line(Semantic) of
                        #{kind := rc, core := Core} ->
                            release_for_core(Core, Prefix, Semantic, existing_rc);
                        #{kind := stable, tag := Tag} ->
                            {error, {no_release_candidate_to_finalize, Tag}};
                        none ->
                            {error, no_release_candidate_to_finalize}
                    end
            end
    end.

candidate_for_core(Core, Prefix, Semantic, Source) ->
    case stable_for_core(Core, Semantic) of
        true ->
            {error, {release_already_tagged, format_stable(Prefix, Core)}};
        false ->
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

release_for_core(Core, Prefix, Semantic, Source) ->
    case stable_for_core(Core, Semantic) of
        true ->
            {error, {release_already_tagged, format_stable(Prefix, Core)}};
        false ->
            {ok, #{
                kind => stable,
                core => Core,
                prefix => Prefix,
                source => Source,
                tag => format_stable(Prefix, Core)
            }}
    end.

comparison_base(#{kind := rc} = Candidate, Semantic) ->
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
        [] -> latest_stable_before(Core, Semantic)
    end;
comparison_base(#{kind := stable, core := Core}, Semantic) ->
    SameCoreRcs = [
        Tag
        || Tag = #{kind := rc, core := TagCore} <- Semantic,
           TagCore =:= Core
    ],
    case sort_semantic(SameCoreRcs) of
        [LatestRc | _] -> maps:get(tag, LatestRc);
        [] -> latest_stable_before(Core, Semantic)
    end.

latest_stable_before(Core, Semantic) ->
    Stable = [
        Tag
        || Tag = #{kind := stable} <- Semantic,
           core_lt(maps:get(core, Tag), Core)
    ],
    case sort_semantic(Stable) of
        [LatestStable | _] -> maps:get(tag, LatestStable);
        [] -> undefined
    end.

requested_core(Opts) ->
    case maps:get(version, Opts, undefined) of
        undefined -> not_found;
        Version -> parse_core(Version)
    end.

parse_core({Major, Minor, Patch}) ->
    {ok, normalize_core({Major, Minor, Patch})};
parse_core(#{major := Major, minor := Minor, patch := Patch}) ->
    {ok, normalize_core({Major, Minor, Patch})};
parse_core(Version0) when is_binary(Version0); is_list(Version0) ->
    Version = to_binary(Version0),
    Pattern = <<"^v?([0-9]+)\\.([0-9]+)\\.([0-9]+)(?:-rc(?:[.-]?)[0-9]+)?$">>,
    case re:run(Version, Pattern, [{capture, all_but_first, binary}]) of
        {match, [Major, Minor, Patch]} -> {ok, ints(Major, Minor, Patch)};
        nomatch -> {error, {invalid_release_version, Version}}
    end;
parse_core(Other) ->
    {error, {invalid_release_version, Other}}.

proposal(State, Description, Evidence, Opts) ->
    Candidate = maps:get(candidate, State),
    TagLimit = positive_int(maps:get(tag_limit, Opts, ?DEFAULT_TAG_LIMIT), ?DEFAULT_TAG_LIMIT),
    Tags = maps:get(tags, State),
    #{
        tag => maps:get(tag, Candidate),
        release_kind => maps:get(kind, Candidate),
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
                                release_kind => maps:get(kind, Candidate),
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
                                source_sha256 => maps:get(source_sha256, Analysis, undefined),
                                analysis_sha256 => maps:get(analysis_sha256, Analysis, undefined),
                                knowledge_sha256 => knowledge_card_digest(Card),
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
    KindLabel = release_label(maps:get(release_kind, Evidence, rc)),
    iolist_to_binary([
        maps:get(tag, Evidence), <<" ">>, KindLabel, <<"\n\n">>,
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

version_map(#{kind := rc, core := {Major, Minor, Patch}, rc := Rc}) ->
    #{major => Major, minor => Minor, patch => Patch, rc => Rc};
version_map(#{kind := stable, core := {Major, Minor, Patch}}) ->
    #{major => Major, minor => Minor, patch => Patch}.

release_label(rc) -> <<"release candidate">>;
release_label(stable) -> <<"release">>.
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
git(Repo, Args, Opts) ->
    case ecai_repair_git:run(Repo, Args, command_timeout(Opts)) of
        {ok, _} = Ok ->
            Ok;
        {error, Reason} ->
            {error, {
                git_command_failed,
                #{
                    args => [to_binary(Arg) || Arg <- Args],
                    reason => Reason
                }
            }}
    end.
command_timeout(Opts) -> positive_int(maps:get(command_timeout_ms, Opts, application:get_env(ecai, code_patch_command_timeout_ms, ?DEFAULT_TIMEOUT_MS)), ?DEFAULT_TIMEOUT_MS).
positive_int(N, _Default) when is_integer(N), N > 0 -> N;
positive_int(_, Default) -> Default.
non_negative_int(N, _Default) when is_integer(N), N >= 0 -> N;
non_negative_int(_, Default) -> Default.
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
