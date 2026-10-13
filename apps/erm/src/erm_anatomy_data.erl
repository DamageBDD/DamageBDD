%% Known-source datasets, persistent cache and FMA -> element mesh mapping.
%% Apache-2.0. No shell commands or external extraction tools at runtime.
-module(erm_anatomy_data).
-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/zip.hrl").
-export([
    ensure/2,
    sources/0,
    source/1,
    parse_elements/1,
    select/2,
    safe_entry/1,
    install/4,
    default_structures/0, default_structures/1,
    catalog/2,
    parse_atlas/1
]).
-define(BASE, "https://dbarchive.biosciencedbc.jp/data/bodyparts3d/LATEST/").
-define(CREDIT,
    "BodyParts3D, © The Database Center for Life Science licensed under CC Attribution 4.0 International"
).

sources() ->
    [bodyparts3d_partof, bodyparts3d_isa, openanatomy_brain, openanatomy_knee, openanatomy_abdomen].
source(bodyparts3d_partof) -> spec("partof", 100 * 1024 * 1024);
source(bodyparts3d_isa) -> spec("isa", 180 * 1024 * 1024);
source(openanatomy_brain) -> atlas_spec("brain-2017-01", "SPL/NAC Brain Atlas");
source(openanatomy_knee) -> atlas_spec("knee-2016-09", "SPL Knee Atlas");
source(openanatomy_abdomen) -> atlas_spec("abdomen-2016-09", "SPL Abdominal Atlas");
source(Other) -> error({unknown_anatomy_source, Other}).
spec(Prefix, Max) ->
    #{
        archive => ?BASE ++ Prefix ++ "_BP3D_4.0_obj_99.zip",
        elements => ?BASE ++ Prefix ++ "_element_parts.txt",
        max_bytes => Max,
        attribution => ?CREDIT,
        license_url => "https://dbarchive.biosciencedbc.jp/en/bodyparts3d/lic.html"
    }.
default_structures() ->
    [
        <<"stomach">>,
        <<"gallbladder">>,
        <<"right kidney">>,
        <<"left kidney">>,
        <<"urinary bladder">>
    ].

ensure(Opts, Progress) ->
    try
        Root = filename:absname(
            maps:get(
                data_dir,
                Opts,
                filename:join(filename:basedir(user_cache, "erm"), "anatomy")
            )
        ),
        case
            maps:get(manual_manifest, Opts, true) andalso
                filelib:is_regular(filename:join(Root, "manifest.config"))
        of
            true ->
                {ok, Root, #{
                    attribution => maps:get(attribution, Opts, "Local anatomy meshes"),
                    source => local
                }};
            false ->
                global:trans(
                    {{?MODULE, Root}, self()}, fun() -> prepare(Root, Opts, Progress) end, [node()]
                )
        end
    catch
        C:R -> {error, {C, R}}
    end.
prepare(Root, Opts, Progress) ->
    Source = maps:get(source, Opts, bodyparts3d_partof),
    case source(Source) of
        #{format := vtk_atlas} = Spec -> prepare_atlas(Root, Source, Spec, Opts, Progress);
        _ -> prepare_bodyparts(Root, Opts, Progress)
    end.
prepare_bodyparts(Root, Opts, Progress) ->
    Source = maps:get(source, Opts, bodyparts3d_partof),
    Spec = source(Source),
    Base = filename:join(Root, atom_to_list(Source)),
    ok = filelib:ensure_dir(filename:join(Base, "placeholder")),
    %% Only our incomplete download files are removed after a cancelled setup.
    [file:delete(P) || P <- filelib:wildcard(filename:join(Base, ".download-*"))],
    Network = maps:get(auto_fetch, Opts, true),
    Progress(#{stage => metadata, source => Source}),
    MetaPath = filename:join(Base, "elements.tsv"),
    MetaHash = cached(
        maps:get(elements, Spec), MetaPath, 2 * 1024 * 1024, undefined, Network, Opts, Progress
    ),
    {ok, Meta} = file:read_file(MetaPath),
    Parts = select(parse_elements(Meta), maps:get(structures, Opts, default_structures())),
    Progress(#{stage => archive, source => Source}),
    Archive = filename:join(Base, "meshes.zip"),
    ArchiveHash = cached(
        maps:get(archive, Spec),
        Archive,
        maps:get(max_bytes, Spec),
        maps:get(archive_sha256, Opts, undefined),
        Network,
        Opts,
        Progress
    ),
    %% A different selection or source revision gets its own generated manifest.
    Key = hex(crypto:hash(sha256, term_to_binary({Parts, MetaHash, ArchiveHash}))),
    Dest = filename:join(Base, Key),
    ok = filelib:ensure_dir(filename:join(Dest, "placeholder")),
    Progress(#{stage => extracting, structures => length(Parts)}),
    Manifest = install(Archive, Parts, Dest, Progress),
    Receipt = Spec#{
        source => Source,
        archive_sha256 => ArchiveHash,
        metadata_sha256 => MetaHash,
        prepared_at => calendar:universal_time()
    },
    atomic_term(filename:join(Dest, "source.config"), Receipt),
    atomic_write(
        filename:join(Dest, "ATTRIBUTION.txt"),
        unicode:characters_to_binary(
            [?CREDIT, "\n", maps:get(license_url, Spec), "\n"]
        )
    ),
    %% Publish manifest last; a failed extraction never makes a partial dataset usable.
    atomic_term(filename:join(Dest, "manifest.config"), Manifest),
    {ok, Dest, Receipt}.

cached(URL, Path, Limit, Pin, Network, Opts, Progress) ->
    case valid_cache(Path, Limit, Pin) of
        {ok, Hash} ->
            Progress(#{stage => cached, file => filename:basename(Path)}),
            Hash;
        false when Network =:= false -> error({offline_cache_missing_or_invalid, Path});
        false ->
            Tmp = filename:join(
                filename:dirname(Path),
                ".download-" ++ os:getpid() ++ "-" ++
                    integer_to_list(erlang:unique_integer([positive]))
            ),
            Spec0 = #{url => URL, max_bytes => Limit},
            Spec =
                case Pin of
                    undefined -> Spec0;
                    _ -> Spec0#{sha256 => Pin}
                end,
            try
                Hash = erm_anatomy_http:fetch(
                    Spec,
                    Tmp,
                    fun(N) ->
                        Progress(#{
                            stage => downloading, file => filename:basename(Path), bytes => N
                        })
                    end,
                    maps:get(download_timeout_ms, Opts, 120000)
                ),
                ok = file:rename(Tmp, Path),
                atomic_write(Path ++ ".sha256", Hash),
                Hash
            after
                file:delete(Tmp)
            end
    end.
valid_cache(Path, Limit, Pin) ->
    case {file:read_file_info(Path), file:read_file(Path ++ ".sha256")} of
        {{ok, #file_info{type = regular, size = N}}, {ok, Saved}} when N > 0, N =< Limit ->
            Hash = hash_file(Path),
            case list_to_binary(Hash) =:= Saved andalso (Pin =:= undefined orelse Pin =:= Hash) of
                true -> {ok, Hash};
                false -> false
            end;
        _ ->
            false
    end.
hash_file(Path) ->
    {ok, F} = file:open(Path, [read, binary, raw]),
    try
        hash_loop(F, crypto:hash_init(sha256))
    after
        file:close(F)
    end.
hash_loop(F, H) ->
    case file:read(F, 1048576) of
        {ok, B} -> hash_loop(F, crypto:hash_update(H, B));
        eof -> hex(crypto:hash_final(H));
        {error, R} -> error({cache_read, R})
    end.
hex(B) -> lists:flatten([io_lib:format("~2.16.0b", [N]) || <<N>> <= B]).

parse_elements(B) ->
    Rows = binary:split(B, <<"\n">>, [global]),
    Map = lists:foldl(
        fun(Line, Acc) ->
            case binary:split(string:trim(Line), <<"\t">>, [global]) of
                [<<"FMA", _/binary>> = ID, Name, Element] when Name =/= <<>>, Element =/= <<>> ->
                    true = safe_id(Element),
                    Old = maps:get(ID, Acc, #{id => ID, name => Name, elements => []}),
                    Acc#{ID => Old#{elements := [Element | maps:get(elements, Old)]}};
                [<<"concept id">> | _] ->
                    Acc;
                [<<>>] ->
                    Acc;
                _ ->
                    error(invalid_element_mapping)
            end
        end,
        #{},
        Rows
    ),
    true = map_size(Map) > 0,
    [
        P#{elements := lists:usort(maps:get(elements, P))}
     || {_ID, P} <- lists:sort(maps:to_list(Map))
    ].
select(Catalog, Requested) when is_list(Requested), Requested =/= [], length(Requested) =< 200 ->
    Parts = [
        begin
            Key = string:casefold(unicode:characters_to_binary(Q)),
            case
                [
                    P
                 || P <- Catalog,
                    string:casefold(maps:get(id, P)) =:= Key orelse
                        string:casefold(maps:get(name, P)) =:= Key
                ]
            of
                [P] -> P;
                [] -> error({unknown_structure, Q});
                _ -> error({ambiguous_structure, Q})
            end
        end
     || Q <- Requested
    ],
    true = length(Parts) =:= length(lists:usort([maps:get(id, P) || P <- Parts])),
    Parts;
select(_, _) ->
    error(invalid_structure_selection).
safe_id(B) -> re:run(B, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) =:= match.
safe_entry(Name) when is_list(Name) ->
    filename:pathtype(Name) =:= relative andalso
        not lists:any(fun(P) -> P =:= ".." end, filename:split(Name)) andalso
        not lists:member($\\, Name) andalso not lists:member($:, Name);
safe_entry(_) ->
    false.

install(Archive, Parts, Dest, Progress) ->
    {ok, Z} = zip:zip_open(Archive, [memory]),
    try
        {ok, Entries} = zip:zip_list_dir(Z),
        Index = lists:foldl(
            fun
                (#zip_file{name = N, info = #file_info{type = regular, size = Size}}, Acc) ->
                    case filename:extension(N) of
                        ".obj" ->
                            true = safe_entry(N),
                            true = Size > 0 andalso Size =< 16777216,
                            ID = list_to_binary(filename:basename(N, ".obj")),
                            true = safe_id(ID),
                            false = maps:is_key(ID, Acc),
                            Acc#{ID => N};
                        _ ->
                            Acc
                    end;
                (_, Acc) ->
                    Acc
            end,
            #{},
            Entries
        ),
        Elements = lists:usort(lists:append([maps:get(elements, P) || P <- Parts])),
        true = length(Elements) =< 4000,
        {_Bytes, _Count, Counts} = lists:foldl(
            fun(ID, {Bytes, Count, AccCounts}) ->
                N =
                    case maps:find(ID, Index) of
                        {ok, V} -> V;
                        error -> error({missing_mesh, ID})
                    end,
                {ok, {_, Data}} = zip:zip_get(N, Z),
                Total = Bytes + byte_size(Data),
                true = Total =< 256 * 1024 * 1024,
                %% Validate each OBJ before making it available to the viewer.
                {ok, Mesh} = erm_anatomy_mesh:parse(Data),
                atomic_write(filename:join(Dest, binary_to_list(ID) ++ ".obj"), Data),
                Progress(#{
                    stage => extracting, meshes => Count + 1, total_meshes => length(Elements)
                }),
                {Total, Count + 1, AccCounts#{ID => length(maps:get(triangles, Mesh))}}
            end,
            {0, 0, #{}},
            Elements
        ),
        Triangles = lists:sum([maps:get(ID, Counts) || P <- Parts, ID <- maps:get(elements, P)]),
        case Triangles =< 50000 of
            true -> ok;
            false -> error({scene_triangle_limit, Triangles, 50000})
        end,
        [
            #{
                id => maps:get(id, P),
                name => maps:get(name, P),
                files => [binary_to_list(ID) ++ ".obj" || ID <- maps:get(elements, P)],
                color => color(maps:get(name, P))
            }
         || P <- Parts
        ]
    after
        zip:zip_close(Z)
    end.
color(Name) ->
    case binary:match(Name, <<"lung">>) of
        nomatch -> {190, 100, 100};
        _ -> {210, 155, 175}
    end.
atomic_term(Path, Term) -> atomic_write(Path, io_lib:format("~tp.~n", [Term])).
atomic_write(Path, Data) ->
    Tmp = Path ++ ".tmp",
    ok = file:write_file(Tmp, unicode_data(Data), [sync]),
    ok = file:rename(Tmp, Path).
unicode_data(B) when is_binary(B) -> B;
unicode_data(L) -> unicode:characters_to_binary(L).

atlas_spec(Release, Title) ->
    Base = "https://www.openanatomy.org/atlases/nac/" ++ Release ++ "/",
    #{
        format => vtk_atlas,
        base => Base,
        elements => Base ++ "atlasStructure.json",
        up_axis => z,
        attribution => Title ++
            ", Surgical Planning Laboratory, Brigham and Women's Hospital; 3D Slicer License (Part B)",
        license_url => "https://www.openanatomy.org/atlas-pages/slicer-license.html"
    }.
default_structures(openanatomy_brain) ->
    [<<"left hippocampus">>, <<"right hippocampus">>, <<"left amygdala">>, <<"right amygdala">>];
default_structures(openanatomy_knee) ->
    [<<"anterior cruciate ligament">>, <<"posterior cruciate ligament">>];
default_structures(openanatomy_abdomen) ->
    [<<"left kidney">>, <<"right kidney">>, <<"gallbladder">>];
default_structures(_) ->
    default_structures().

%% Metadata-only catalogue lookup; never downloads meshes or patient volumes.
catalog(Source, Opts) ->
    try
        Spec = source(Source),
        Root = filename:absname(
            maps:get(
                data_dir,
                Opts,
                filename:join(filename:basedir(user_cache, "erm"), "anatomy")
            )
        ),
        global:trans(
            {{?MODULE, Root}, self()},
            fun() ->
                Base = filename:join(Root, atom_to_list(Source)),
                ok = filelib:ensure_dir(filename:join(Base, "placeholder")),
                Path = filename:join(Base, "elements.tsv"),
                _ = cached(
                    maps:get(elements, Spec),
                    Path,
                    2 * 1024 * 1024,
                    undefined,
                    maps:get(auto_fetch, Opts, true),
                    Opts,
                    fun(_) -> ok end
                ),
                {ok, B} = file:read_file(Path),
                Parts =
                    case maps:get(format, Spec, obj_archive) of
                        vtk_atlas -> parse_atlas(B);
                        _ -> parse_elements(B)
                    end,
                {ok, [maps:with([id, name], P) || P <- Parts]}
            end,
            [node()]
        )
    catch
        C:R -> {error, {C, R}}
    end.

parse_atlas(B) when byte_size(B) =< 2 * 1024 * 1024 ->
    Nodes = jsx:decode(B, [return_maps]),
    true = is_list(Nodes) andalso length(Nodes) =< 10000,
    Sources = maps:from_list([
        {maps:get(<<"@id">>, N), maps:get(<<"source">>, N, <<>>)}
     || N <- Nodes, maps:get(<<"@type">>, N, undefined) =:= <<"DataSource">>
    ]),
    Parts = [
        begin
            ID = maps:get(<<"@id">>, N),
            Name = maps:get(<<"name">>, maps:get(<<"annotation">>, N)),
            true = is_binary(ID) andalso is_binary(Name),
            Paths = lists:usort([
                maps:get(maps:get(<<"dataSource">>, Sel), Sources)
             || Sel <- maps:get(<<"sourceSelector">>, N, []),
                lists:member(<<"GeometrySelector">>, maps:get(<<"@type">>, Sel, []))
            ]),
            true = Paths =/= [] andalso length(Paths) =< 20,
            [true = safe_atlas_path(P) || P <- Paths],
            Color = atlas_color(
                maps:get(<<"color">>, maps:get(<<"renderOption">>, N, #{}), <<"rgb(175,190,205)">>)
            ),
            #{id => ID, name => Name, paths => Paths, color => Color}
        end
     || N <- Nodes,
        maps:get(<<"@type">>, N, undefined) =:= <<"Structure">>,
        lists:any(
            fun(Sel) -> lists:member(<<"GeometrySelector">>, maps:get(<<"@type">>, Sel, [])) end,
            maps:get(<<"sourceSelector">>, N, [])
        )
    ],
    true = Parts =/= [],
    true = length(Parts) =:= length(lists:usort([maps:get(id, P) || P <- Parts])),
    lists:sort(fun(A, C) -> maps:get(name, A) < maps:get(name, C) end, Parts).
safe_atlas_path(P) when is_binary(P) ->
    re:run(P, <<"^(Data|models)/[A-Za-z0-9_().-]+\\.vtk$">>, [{capture, none}]) =:= match andalso
        not lists:member(<<"..">>, binary:split(P, <<"/">>, [global]));
safe_atlas_path(_) ->
    false.
atlas_color(B) ->
    {match, Channels} = re:run(B, <<"^rgba?\\(([0-9]+),([0-9]+),([0-9]+)(?:,[0-9.]+)?\\)$">>, [
        {capture, [1, 2, 3], binary}
    ]),
    Values = [binary_to_integer(V) || V <- Channels],
    true = lists:all(fun(V) -> V >= 0 andalso V =< 255 end, Values),
    list_to_tuple(Values).

prepare_atlas(Root, Source, Spec, Opts, Progress) ->
    Base = filename:join(Root, atom_to_list(Source)),
    ok = filelib:ensure_dir(filename:join(Base, "placeholder")),
    [file:delete(P) || P <- filelib:wildcard(filename:join(Base, ".download-*"))],
    Network = maps:get(auto_fetch, Opts, true),
    Meta = filename:join(Base, "elements.tsv"),
    MetaHash = cached(
        maps:get(elements, Spec), Meta, 2 * 1024 * 1024, undefined, Network, Opts, Progress
    ),
    {ok, B} = file:read_file(Meta),
    Parts = select(parse_atlas(B), maps:get(structures, Opts, default_structures(Source))),
    %% Retain the complete upstream licence beside every prepared selection.
    License = filename:join(Base, "LICENSE.html"),
    LicenseHash = cached(
        maps:get(license_url, Spec), License, 1024 * 1024, undefined, Network, Opts, Progress
    ),
    Key = hex(crypto:hash(sha256, term_to_binary({Parts, MetaHash, LicenseHash}))),
    Dest = filename:join(Base, Key),
    ok = filelib:ensure_dir(filename:join(Dest, "placeholder")),
    {Manifest, Receipts, _} = lists:foldl(
        fun(P, {Ms, Rs, Triangles}) ->
            {Files, Hashes, Count} = lists:foldl(
                fun(Path, {Fs, Hs, N}) ->
                    File = hex(crypto:hash(sha256, Path)) ++ ".vtk",
                    Full = filename:join(Dest, File),
                    Url = maps:get(base, Spec) ++ binary_to_list(Path),
                    Hash = cached(Url, Full, 16 * 1024 * 1024, undefined, Network, Opts, Progress),
                    {ok, Mesh} = erm_anatomy_mesh:load(Full),
                    Added = length(maps:get(triangles, Mesh)),
                    case Triangles + N + Added =< 50000 of
                        true -> ok;
                        false -> error({triangle_budget_exceeded, Triangles + N + Added, 50000})
                    end,
                    {[File | Fs], [#{url => Url, sha256 => Hash} | Hs], N + Added}
                end,
                {[], [], 0},
                maps:get(paths, P)
            ),
            Progress(#{stage => extracting, meshes => length(Ms) + 1, total_meshes => length(Parts)}),
            {
                [maps:without([paths], P#{files => lists:reverse(Files)}) | Ms],
                Hashes ++ Rs,
                Triangles + Count
            }
        end,
        {[], [], 0},
        Parts
    ),
    {ok, LicenseBytes} = file:read_file(License),
    atomic_write(filename:join(Dest, "LICENSE.html"), LicenseBytes),
    Credit = maps:get(attribution, Spec),
    atomic_write(
        filename:join(Dest, "ATTRIBUTION.txt"),
        unicode:characters_to_binary(
            [
                Credit,
                "\n",
                maps:get(license_url, Spec),
                "\nSource meshes are unmodified; the viewer triangulates strips for rendering.\n"
            ]
        )
    ),
    Receipt = Spec#{source => Source, metadata_sha256 => MetaHash, files => Receipts},
    atomic_term(filename:join(Dest, "source.config"), Receipt),
    atomic_term(filename:join(Dest, "manifest.config"), lists:reverse(Manifest)),
    {ok, Dest, Receipt}.
