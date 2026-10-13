-module(ecai_code_context).

-export([
    for_vulnerability/3,
    for_vulnerability/4,
    finding_version/3
]).

-define(APPS, [damage, ecai, erm]).

for_vulnerability(App, Module, Finding) ->
    for_vulnerability(App, Module, Finding, #{}).

for_vulnerability(App, Module, Finding, Opts) ->
    case effective_analysis(App, Module, Finding) of
        {error, _} = Error ->
            Error;
        {ok, Analysis} ->
            Graph =
                case ecai_learning_store:get_graph(App) of
                    {ok, G} -> G;
                    not_found -> ecai_code_graph:build(ecai_learning_store:analyses(App))
                end,
            Depth = maps:get(depth, Opts, 1),
            MaxRelated = maps:get(max_related, Opts, 8),
            NeighbourPairs = ecai_code_graph:neighborhood(Graph, Module, Depth),
            Neighbours = [M || {M, _D} <- NeighbourPairs, M =/= Module],
            Cross = cross_application_relations(Module, Analysis),
            RelatedModules = lists:sublist(lists:usort(Neighbours ++ Cross), MaxRelated),
            Related = [related_module(M, Opts) || M <- RelatedModules],
            AppCard = value_or_empty(ecai_learning_store:get_app_knowledge(App)),
            GlobalCard = value_or_empty(ecai_learning_store:get_global_knowledge()),
            CurrentCard = value_or_empty(ecai_learning_store:get_module_knowledge(App, Module)),
            Repairs = analogous_repairs(Finding, maps:get(max_repairs, Opts, 5)),
            {ok, #{
                application => App,
                module => Module,
                finding => Finding,
                finding_version => finding_version_from(Analysis, Finding),
                source => maps:get(source, Analysis, <<>>),
                analysis => maps:without([source], Analysis),
                module_knowledge => CurrentCard,
                application_knowledge => AppCard,
                global_knowledge => GlobalCard,
                graph_neighborhood => NeighbourPairs,
                related_modules => Related,
                analogous_repairs => Repairs
            }}
    end.

effective_analysis(App, Module, Finding) ->
    Stored = ecai_learning_store:get_analysis(App, Module),
    case integration_source(Finding) of
        not_found ->
            case Stored of
                {ok, Analysis} -> {ok, Analysis};
                not_found -> {error, {analysis_not_found, App, Module}}
            end;
        {ok, SourcePath, Source} ->
            Base =
                case Stored of
                    {ok, Analysis0} ->
                        Analysis0;
                    not_found ->
                        #{
                            application => App,
                            module => Module,
                            remote_calls => [],
                            local_calls => [],
                            behaviours => [],
                            security_boundaries => [],
                            exports => [],
                            functions => [],
                            specs => [],
                            types => [],
                            records => [],
                            includes => [],
                            config_reads => [],
                            config_writes => [],
                            sends_messages => false,
                            uses_nif => false,
                            test_module => false
                        }
                end,
            Analysis1 = Base#{
                application => App,
                module => Module,
                source_kind => integration_workrepo,
                source_name => SourcePath,
                source => Source,
                source_sha256 => sha256_hex(Source)
            },
            AnalysisHash = sha256_hex(
                term_to_binary(maps:remove(source, Analysis1), [deterministic])
            ),
            {ok, Analysis1#{analysis_sha256 => AnalysisHash}}
    end.

integration_source(Finding) when is_map(Finding) ->
    Context = mget(<<"integration_context">>, Finding, #{}),
    case
        {
            mget(<<"target_source_path">>, Context, undefined),
            mget(<<"target_source">>, Context, undefined)
        }
    of
        {Path, Source} when is_binary(Path), is_binary(Source), byte_size(Source) > 0 ->
            {ok, Path, Source};
        {Path, Source} when is_list(Path), is_binary(Source), byte_size(Source) > 0 ->
            {ok, unicode:characters_to_binary(Path), Source};
        _ ->
            not_found
    end;
integration_source(_) ->
    not_found.

finding_version(App, Module, Finding) ->
    case ecai_learning_store:get_analysis(App, Module) of
        {ok, Analysis} -> finding_version_from(Analysis, Finding);
        not_found -> sha256_hex(term_to_binary(comparable_finding(Finding), [deterministic]))
    end.

finding_version_from(Analysis, Finding) ->
    SourceHash = maps:get(source_sha256, Analysis, <<>>),
    sha256_hex(term_to_binary({SourceHash, comparable_finding(Finding)}, [deterministic])).

related_module(Module, Opts) ->
    case find_analysis(Module) of
        not_found ->
            #{module => Module, unavailable => true};
        {ok, App, Analysis} ->
            MaxBytes = maps:get(max_related_source_bytes, Opts, 24000),
            Source = truncate(maps:get(source, Analysis, <<>>), MaxBytes),
            Card = value_or_empty(ecai_learning_store:get_module_knowledge(App, Module)),
            #{
                application => App,
                module => Module,
                analysis => maps:without([source], Analysis),
                knowledge => Card,
                source => Source
            }
    end.

find_analysis(Module) ->
    find_analysis(?APPS, Module).

find_analysis([], _Module) ->
    not_found;
find_analysis([App | Rest], Module) ->
    case ecai_learning_store:get_analysis(App, Module) of
        {ok, Analysis} -> {ok, App, Analysis};
        not_found -> find_analysis(Rest, Module)
    end.

cross_application_relations(Module, CurrentAnalysis) ->
    DirectTargets = [
        maps:get(module, Call)
     || Call <- maps:get(remote_calls, CurrentAnalysis, []),
        is_map(Call),
        maps:is_key(module, Call)
    ],
    All = [{App, A} || App <- ?APPS, A <- ecai_learning_store:analyses(App)],
    Known = maps:from_list([{maps:get(module, A), true} || {_App, A} <- All]),
    InternalTargets = [M || M <- DirectTargets, maps:is_key(M, Known)],
    Callers = [
        maps:get(module, A)
     || {_App, A} <- All,
        lists:any(
            fun(C) -> maps:get(module, C, undefined) =:= Module end,
            maps:get(remote_calls, A, [])
        )
    ],
    lists:usort(InternalTargets ++ Callers).

analogous_repairs(Finding, Max) ->
    Cwe = mget(<<"cwe">>, Finding, undefined),
    IssueKey = mget(<<"issue_key">>, Finding, undefined),
    Matches = [
        R
     || R <- ecai_learning_store:repairs(),
        repair_matches(R, Cwe, IssueKey)
    ],
    lists:sublist(Matches, Max).

repair_matches(Repair, Cwe, IssueKey) ->
    RFinding = maps:get(finding, Repair, #{}),
    RCwe = mget(<<"cwe">>, RFinding, undefined),
    RKey = mget(<<"issue_key">>, RFinding, undefined),
    ((Cwe =/= undefined) andalso (Cwe =:= RCwe)) orelse
        ((IssueKey =/= undefined) andalso (IssueKey =:= RKey)).

comparable_finding(Finding) when is_map(Finding) ->
    maps:without(
        [
            <<"status">>,
            <<"change">>,
            <<"first_seen">>,
            <<"last_seen">>,
            <<"resolved_at">>,
            <<"reopen_count">>,
            <<"proposed_patch">>,
            status,
            change,
            first_seen,
            last_seen,
            resolved_at,
            reopen_count,
            proposed_patch
        ],
        Finding
    );
comparable_finding(Other) ->
    Other.

value_or_empty({ok, Value}) -> Value;
value_or_empty(not_found) -> #{}.

truncate(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max -> Bin;
truncate(Bin, Max) when is_binary(Bin), Max > 0 ->
    <<Prefix:Max/binary, _/binary>> = Bin,
    <<Prefix/binary, "\n%% ... truncated by ecai_code_context ...\n">>;
truncate(Other, _Max) ->
    Other.

mget(Key, Map, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, V} ->
            V;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                A -> maps:get(A, Map, Default)
            catch
                error:badarg -> Default
            end
    end;
mget(_Key, _Map, Default) ->
    Default.

sha256_hex(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:hash(sha256, Bin)]).
