%% Filesystem-level regressions for the catalogue. These use list/0 and get/1,
%% not just filelib:wildcard/1 or a hand-built AST. No verification is executed.
-module(damage_verification_catalog_tests).
-include_lib("eunit/include/eunit.hrl").

top_level_features_are_discovered_test() ->
    with_fixture(fun(Root, _Temp) ->
        SourceA = feature(<<"Alpha">>),
        SourceB = feature(<<"Beta">>),
        write_file(Root, "alpha.feature", SourceA),
        write_file(Root, "beta.feature", SourceB),
        {ok, Entries} = damage_verification_catalog:list(),
        ?assertEqual(2, length(Entries)),
        assert_entry("alpha.feature", SourceA, Entries),
        assert_entry("beta.feature", SourceB, Entries)
    end).

nested_features_keep_relative_ids_test() ->
    with_fixture(fun(Root, _Temp) ->
        Top = feature(<<"Top level">>),
        Nested = feature(<<"Nested">>),
        Deep = feature(<<"Deep">>),
        write_file(Root, "check.feature", Top),
        write_file(Root, "security/check.feature", Nested),
        write_file(Root, "network/policy/check.feature", Deep),
        {ok, Entries} = damage_verification_catalog:list(),
        ?assertEqual(3, length(Entries)),
        %% Equal basenames in different directories must not share an ID.
        assert_entry("check.feature", Top, Entries),
        assert_entry("security/check.feature", Nested, Entries),
        assert_entry("network/policy/check.feature", Deep, Entries)
    end).

binary_configured_root_test() ->
    with_fixture(fun(Root, _Temp) ->
        Source = feature(<<"Binary root">>),
        write_file(Root, "check.feature", Source),
        with_root(unicode:characters_to_binary(Root), fun() ->
            {ok, Entries} = damage_verification_catalog:list(),
            ?assertEqual(1, length(Entries)),
            assert_entry("check.feature", Source, Entries)
        end)
    end).

non_feature_files_are_ignored_test() ->
    with_fixture(fun(Root, _Temp) ->
        Source = feature(<<"Only a feature">>),
        write_file(Root, "check.feature", Source),
        write_file(Root, "README.txt", <<"Not a catalogue entry">>),
        write_file(Root, "notes/other.txt", <<"Also not a feature">>),
        {ok, Entries} = damage_verification_catalog:list(),
        ?assertEqual(1, length(Entries)),
        assert_entry("check.feature", Source, Entries)
    end).

invalid_feature_remains_visible_test() ->
    with_fixture(fun(Root, _Temp) ->
        Source = feature(<<"Valid neighbour">>),
        write_file(Root, "good.feature", Source),
        write_file(Root, "broken.feature", <<"This is not a Gherkin feature.\n">>),
        {ok, Entries} = damage_verification_catalog:list(),
        ?assertEqual(2, length(Entries)),
        assert_entry("good.feature", Source, Entries),
        Id = feature_id("broken.feature"),
        [Broken] = [E || E <- Entries, maps:get(id, E) =:= Id],
        ?assertEqual(false, maps:get(available, Broken)),
        ?assert(maps:is_key(error, Broken)),
        ?assertEqual({error, invalid_feature}, damage_verification_catalog:get(Id))
    end).

symlink_entries_are_not_followed_test_() ->
    case os:type() of
        {unix, _} -> [?_test(symlink_entries_are_not_followed())];
        _ -> []
    end.

symlink_entries_are_not_followed() ->
    with_fixture(fun(Root, Temp) ->
        Source = feature(<<"Approved file">>),
        Outside = filename:join(Temp, "outside"),
        write_file(Root, "check.feature", Source),
        write_file(Outside, "unapproved.feature", feature(<<"Outside">>)),
        ok = file:make_symlink(filename:join(Outside, "unapproved.feature"),
            filename:join(Root, "linked.feature")),
        ok = file:make_symlink(Outside, filename:join(Root, "linked-dir")),
        {ok, Entries} = damage_verification_catalog:list(),
        ?assertEqual(1, length(Entries)),
        assert_entry("check.feature", Source, Entries)
    end).

empty_catalog_is_valid_test() ->
    with_fixture(fun(_Root, _Temp) ->
        ?assertEqual({ok, []}, damage_verification_catalog:list())
    end).

missing_catalog_is_an_error_test() ->
    with_fixture(fun(Root, _Temp) ->
        with_root(filename:join(Root, "missing"), fun() ->
            ?assertEqual({error, catalog_unavailable}, damage_verification_catalog:list())
        end)
    end).

oversized_feature_is_rejected_test() ->
    with_fixture(fun(Root, _Temp) ->
        write_file(Root, "too-large.feature", binary:copy(<<"x">>, 65537)),
        ?assertEqual({error, feature_too_large}, damage_verification_catalog:list())
    end).

depth_limit_is_preserved_test() ->
    with_fixture(fun(Root, _Temp) ->
        Rel = filename:join(["a", "b", "c", "d", "e", "f", "g", "check.feature"]),
        write_file(Root, Rel, feature(<<"Too deep">>)),
        ?assertEqual({error, catalog_depth}, damage_verification_catalog:list())
    end).

deployed_workflows_are_discovered_test() ->
    %% Exercise the actual three shipped features as well as temporary fixtures.
    %% The override is restored even if an assertion fails.
    Root = filename:join(code:priv_dir(damage), "features/verification"),
    with_root(Root, fun() ->
        {ok, Entries} = damage_verification_catalog:list(),
        ?assert(length(Entries) >= 3),
        lists:foreach(fun(Name) ->
            {ok, Source} = file:read_file(filename:join(Root, Name)),
            assert_entry(Name, Source, Entries)
        end, ["credential-containment.feature", "lightning-payment-policy.feature",
              "nostr-bunker.feature"])
    end).

assert_entry(Rel, Source, Entries) ->
    Id = feature_id(Rel),
    [Entry] = [E || E <- Entries, maps:get(id, E) =:= Id],
    ?assertEqual(true, maps:get(available, Entry)),
    ?assertEqual(Source, maps:get(source, Entry)),
    ?assertEqual(damage_verification_catalog:sha256(Source), maps:get(sha256, Entry)),
    %% Selection and execution resolve by this same relative-path ID.
    ?assertEqual({ok, Entry}, damage_verification_catalog:get(Id)).

feature_id(Rel) ->
    damage_verification_catalog:sha256(unicode:characters_to_binary(Rel)).

feature(Title) ->
    <<"Feature: ", Title/binary, "\n\n",
      "  Scenario: A catalogue fixture\n",
      "    Given I set the variable \"x\" to \"1\"\n">>.

write_file(Root, Rel, Source) ->
    Path = filename:join(Root, Rel),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Source).

with_fixture(Fun) ->
    Base = case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Dir -> Dir
    end,
    Suffix = integer_to_list(erlang:system_time(microsecond)) ++ "_" ++
        integer_to_list(erlang:unique_integer([positive, monotonic])),
    Temp = filename:absname(filename:join(Base, "damage_catalog_test_" ++ Suffix)),
    Root = filename:join(Temp, "catalog"),
    ok = filelib:ensure_dir(filename:join(Root, "placeholder")),
    try with_root(Root, fun() -> Fun(Root, Temp) end)
    after
        ok = file:del_dir_r(Temp)
    end.

with_root(Root, Fun) ->
    Previous = application:get_env(damage, verification_feature_dir),
    ok = application:set_env(damage, verification_feature_dir, Root),
    try Fun()
    after
        case Previous of
            undefined -> application:unset_env(damage, verification_feature_dir);
            {ok, Value} -> application:set_env(damage, verification_feature_dir, Value)
        end
    end.
