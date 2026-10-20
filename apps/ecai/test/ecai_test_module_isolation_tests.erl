%% Normal EUnit tests must resolve production modules, not standalone doubles.
%% The standalone harnesses deliberately reuse module names, but their sources
%% have an .erl.fixture suffix and are compiled only in a temporary directory.
-module(ecai_test_module_isolation_tests).
-include_lib("eunit/include/eunit.hrl").

production_module_resolution_test_() ->
    [
        {atom_to_list(Module), fun() -> require_production_module(Module, Exports) end}
     || {Module, Exports} <- [
            {ecai_ollama_rag, [
                {retrieve_sources, 3}, {retrieve_sources_lexical, 3},
                {ask_qa, 2}, {ask_private, 4}
            ]},
            {ecai_chat, [{start_link, 1}, {store_message, 4}, {get_reply, 4}]},
            {ecai_personalities, [
                {start_link, 0}, {catalogue, 0}, {owned_personalities, 1},
                {resolve_personality, 2}
            ]}
        ]
    ].

require_production_module(Module, RequiredExports) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            Source = proplists:get_value(source, Module:module_info(compile), ""),
            Missing = RequiredExports -- Module:module_info(exports),
            TestSource = is_list(Source) andalso
                lists:member("test", filename:split(Source)),
            case {Missing, TestSource} of
                {[], false} -> ok;
                _ -> erlang:error({test_module_shadowed_or_stale, #{
                    module => Module,
                    loaded_from => code:which(Module),
                    compiled_from => Source,
                    missing_exports => Missing,
                    compiled_from_test_tree => TestSource,
                    remedy => isolate_fixtures_and_rebuild_test_profile
                }})
            end;
        {error, Reason} ->
            erlang:error({test_production_module_unavailable, #{
                module => Module, reason => Reason, resolved_from => code:which(Module)
            }})
    end.
