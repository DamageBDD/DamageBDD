%%--------------------------------------------------------------------
%% Server-owned Wikimedia indexing presets.
%%
%% The browser submits only a preset id. Source coordinates, rolling
%% pageview windows, storage paths and indexing policy stay on the node.
%%--------------------------------------------------------------------
-module(ecai_wikimedia_presets).

-export([list/0, spec/2]).

-spec list() -> [map()].
list() ->
    [public(Preset) || Preset <- presets()].

-spec spec(binary() | list(), binary()) -> {ok, map()} | {error, term()}.
spec(PresetId0, Owner) when is_binary(Owner), byte_size(Owner) > 0 ->
    PresetId = to_binary(PresetId0),
    case find_preset(PresetId, presets()) of
        {ok, Preset} ->
            {ok, ecai_wikimedia_ops:genesis_spec(spec_overrides(Preset, Owner))};
        error ->
            {error, {unknown_wikimedia_preset, PresetId}}
    end;
spec(_PresetId, _Owner) ->
    {error, invalid_owner}.

presets() ->
    case application:get_env(ecai, wikimedia_index_presets) of
        {ok, Configured} when is_list(Configured), Configured =/= [] ->
            ensure_unique_ids([normalize_preset(Preset) || Preset <- Configured]);
        _ ->
            builtin_presets()
    end.

builtin_presets() ->
    [
        preset(
            <<"enwiki">>,
            <<"English Wikipedia">>,
            <<"English-language Wikipedia articles ranked by recent readership.">>,
            <<"enwiki">>,
            <<"en.wikipedia">>,
            <<"org.damagebdd.wikimedia.en">>
        ),
        preset(
            <<"simplewiki">>,
            <<"Simple English Wikipedia">>,
            <<"Smaller English corpus with simpler article language.">>,
            <<"simplewiki">>,
            <<"simple.wikipedia">>,
            <<"org.damagebdd.wikimedia.simple">>
        ),
        preset(
            <<"dewiki">>,
            <<"German Wikipedia">>,
            <<"German-language Wikipedia articles ranked by recent readership.">>,
            <<"dewiki">>,
            <<"de.wikipedia">>,
            <<"org.damagebdd.wikimedia.de">>
        ),
        preset(
            <<"frwiki">>,
            <<"French Wikipedia">>,
            <<"French-language Wikipedia articles ranked by recent readership.">>,
            <<"frwiki">>,
            <<"fr.wikipedia">>,
            <<"org.damagebdd.wikimedia.fr">>
        ),
        preset(
            <<"eswiki">>,
            <<"Spanish Wikipedia">>,
            <<"Spanish-language Wikipedia articles ranked by recent readership.">>,
            <<"eswiki">>,
            <<"es.wikipedia">>,
            <<"org.damagebdd.wikimedia.es">>
        )
    ].

preset(Id, Label, Description, Project, PageviewProject, Namespace) ->
    #{
        id => Id,
        label => Label,
        description => Description,
        project => Project,
        pageview_project => PageviewProject,
        namespace => Namespace
    }.

public(Preset) ->
    maps:with([id, label, description, project], Preset).

spec_overrides(Preset, Owner) ->
    Project = maps:get(project, Preset),
    Root = index_root(),
    #{
        owner => Owner,
        project => Project,
        pageview_project => maps:get(pageview_project, Preset),
        content_release => maps:get(content_release, Preset, <<"latest">>),
        pageview_months => maps:get(
            pageview_months,
            Preset,
            ecai_wikimedia_catalog:default_months(12)
        ),
        index_id => maps:get(index_id, Preset, <<"ecai-wikimedia-", Project/binary>>),
        namespace => maps:get(namespace, Preset),
        base_dir => maps:get(base_dir, Preset, join_binary(Root, Project)),
        limit => maps:get(limit, Preset, preset_limit()),
        minimum_active_months => maps:get(minimum_active_months, Preset, 6),
        priority => maps:get(priority, Preset, 100),
        keep_downloads => false,
        keep_intermediates => false,
        publish_activity_ipfs => maps:get(publish_activity_ipfs, Preset, false),
        publish_extracted_ipfs => false,
        publish_ipfs => maps:get(publish_ipfs, Preset, preset_publish_ipfs())
    }.

ensure_unique_ids(Presets) ->
    Ids = [maps:get(id, Preset) || Preset <- Presets],
    case length(Ids) =:= length(lists:usort(Ids)) of
        true -> Presets;
        false -> erlang:error(duplicate_wikimedia_index_preset_id)
    end.

find_preset(_Id, []) ->
    error;
find_preset(Id, [#{id := Id} = Preset | _]) ->
    {ok, Preset};
find_preset(Id, [_ | Rest]) ->
    find_preset(Id, Rest).

normalize_preset(Preset0) when is_map(Preset0) ->
    Id = required_token(id, field(id, Preset0)),
    Project = required_token(project, field(project, Preset0)),
    PageviewProject = required_token(pageview_project, field(pageview_project, Preset0)),
    Namespace = required_token(namespace, field(namespace, Preset0)),
    Label = required_binary(label, field(label, Preset0)),
    Description = optional_binary(field(description, Preset0, <<>>)),
    Base = #{
        id => Id,
        label => Label,
        description => Description,
        project => Project,
        pageview_project => PageviewProject,
        namespace => Namespace
    },
    copy_optional(
        Preset0,
        Base,
        [
            content_release,
            pageview_months,
            index_id,
            base_dir,
            limit,
            minimum_active_months,
            priority,
            publish_activity_ipfs,
            publish_ipfs
        ]
    );
normalize_preset(Other) ->
    erlang:error({invalid_wikimedia_index_preset, Other}).

copy_optional(_Source, Acc, []) ->
    Acc;
copy_optional(Source, Acc0, [Key | Rest]) ->
    Acc =
        case field(Key, Source, undefined) of
            undefined -> Acc0;
            Value -> Acc0#{Key => Value}
        end,
    copy_optional(Source, Acc, Rest).

field(Key, Map) ->
    field(Key, Map, undefined).

field(Key, Map, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Default)
    end.

required_binary(Name, Value) ->
    Bin = to_binary(Value),
    case byte_size(Bin) > 0 andalso byte_size(Bin) =< 512 of
        true -> Bin;
        false -> erlang:error({invalid_wikimedia_index_preset_field, Name})
    end.

optional_binary(undefined) -> <<>>;
optional_binary(Value) -> to_binary(Value).

required_token(Name, Value) ->
    Bin = required_binary(Name, Value),
    case re:run(Bin, <<"^[A-Za-z0-9._-]+$">>, [{capture, none}]) of
        match -> Bin;
        _ -> erlang:error({invalid_wikimedia_index_preset_token, Name})
    end.

index_root() ->
    env_binary(wikimedia_index_root, <<"/var/lib/damage/ecai/wikimedia">>).

preset_limit() ->
    env_int(wikimedia_preset_limit, env_int(wikimedia_genesis_limit, 250000)).

preset_publish_ipfs() ->
    case application:get_env(ecai, wikimedia_preset_publish_ipfs, false) of
        true -> true;
        _ -> false
    end.

join_binary(Parent, Child) ->
    unicode:characters_to_binary(
        filename:join(
            unicode:characters_to_list(Parent),
            unicode:characters_to_list(Child)
        )
    ).

env_int(Key, Default) ->
    case application:get_env(ecai, Key, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.

env_binary(Key, Default) ->
    case application:get_env(ecai, Key, Default) of
        Bin when is_binary(Bin), byte_size(Bin) > 0 -> Bin;
        List when is_list(List), List =/= [] -> unicode:characters_to_binary(List);
        _ -> Default
    end.

to_binary(undefined) -> erlang:error(badarg);
to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(List) when is_list(List) -> unicode:characters_to_binary(List);
to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(_Other) -> erlang:error(badarg).
