-module(erm_anatomy_data_tests).
-include_lib("eunit/include/eunit.hrl").

mapping_test() ->
    Ps=erm_anatomy_data:parse_elements(mapping()),
    [Heart]=erm_anatomy_data:select(Ps,[<<"HEART">>]),
    ?assertEqual([<<"FJ1">>,<<"FJ2">>],maps:get(elements,Heart)),
    ?assertEqual([Heart],erm_anatomy_data:select(Ps,[<<"FMA1">>])),
    ?assertError({unknown_structure,<<"brain">>},erm_anatomy_data:select(Ps,[<<"brain">>])),
    ?assertError({badmatch,false},erm_anatomy_data:select(Ps,[<<"heart">>,<<"FMA1">>])).

paths_test() ->
    ?assert(erm_anatomy_data:safe_entry("partof/FJ1.obj")),
    [?assertNot(erm_anatomy_data:safe_entry(P)) || P <-
        ["../FJ1.obj","/tmp/FJ1.obj","a/../../b.obj","C:\\b.obj","a\\b.obj"]].

source_test() ->
    ?assertEqual([bodyparts3d_partof,bodyparts3d_isa,openanatomy_brain,openanatomy_knee,openanatomy_abdomen],erm_anatomy_data:sources()),
    ?assertError({unknown_anatomy_source,random},erm_anatomy_data:source(random)).

install_mapping_test() ->
    with_dir(fun(Dir)->
        Zip=archive(Dir),
        Parts=erm_anatomy_data:select(erm_anatomy_data:parse_elements(mapping()),[<<"heart">>]),
        [P]=erm_anatomy_data:install(Zip,Parts,Dir,fun(_)->ok end),
        ?assertEqual(["FJ1.obj","FJ2.obj"],maps:get(files,P)),
        ?assertEqual({ok,obj()},file:read_file(filename:join(Dir,"FJ1.obj"))),
        Missing=[#{id=><<"FMA9">>,name=><<"missing">>,elements=>[<<"FJ9">>]}],
        ?assertError({missing_mesh,<<"FJ9">>},erm_anatomy_data:install(Zip,Missing,Dir,fun(_)->ok end))
    end).

offline_cache_test() ->
    with_dir(fun(Dir)->
        Base=filename:join(Dir,"bodyparts3d_partof"),
        ok=file:make_dir(Base), Zip=archive(Base),
        ok=file:rename(Zip,filename:join(Base,"meshes.zip")),
        Meta=filename:join(Base,"elements.tsv"),
        ok=file:write_file(Meta,mapping()),
        hash_sidecar(Meta), hash_sidecar(filename:join(Base,"meshes.zip")),
        Opts=#{data_dir=>Dir,structures=>[<<"heart">>],auto_fetch=>false},
        {ok,Ready,Receipt}=erm_anatomy_data:ensure(Opts,fun(_)->ok end),
        ?assertEqual(bodyparts3d_partof,maps:get(source,Receipt)),
        ?assertMatch({ok,[[#{files:=["FJ1.obj","FJ2.obj"]}]]},file:consult(filename:join(Ready,"manifest.config"))),
        ?assertMatch({ok,Ready,_},erm_anatomy_data:ensure(Opts,fun(_)->ok end)),
        ok=file:write_file(filename:join(Base,"meshes.zip"),<<"corrupt">>),
        ?assertMatch({error,{error,{offline_cache_missing_or_invalid,_}}},
            erm_anatomy_data:ensure(Opts,fun(_)->ok end))
    end).

mapping() -> <<"concept id\tname\telement file id\r\nFMA1\theart\tFJ2\r\nFMA1\theart\tFJ1\nFMA1\theart\tFJ1\n">>.
obj() -> <<"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n">>.
archive(Dir) ->
    Zip=filename:join(Dir,"test.zip"),
    {ok,Zip}=zip:create(Zip,[{"nested/FJ1.obj",obj()},{"nested/FJ2.obj",obj()}]),Zip.
hash_sidecar(Path) ->
    {ok,B}=file:read_file(Path),
    Hex=lists:flatten([io_lib:format("~2.16.0b",[N]) || <<N>> <= crypto:hash(sha256,B)]),
    ok=file:write_file(Path++".sha256",Hex).
with_dir(F) ->
    Dir=filename:join("/tmp","erm-anatomy-test-"++os:getpid()++"-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Dir),
    try F(Dir) after file:del_dir_r(Dir) end.

atlas_mapping_test() ->
    Source=#{<<"@type">>=><<"DataSource">>,<<"@id">>=><<"#mesh">>,
             <<"source">>=><<"Data/Model_1_left_kidney.vtk">>},
    Part=#{<<"@type">>=><<"Structure">>,<<"@id">>=><<"#kidney">>,
           <<"annotation">>=>#{<<"name">>=><<"left kidney">>},
           <<"renderOption">>=>#{<<"color">>=><<"rgba(100,120,140,0.5)">>},
           <<"sourceSelector">>=>[#{<<"@type">>=>[<<"Selector">>,<<"GeometrySelector">>],
                                  <<"dataSource">>=><<"#mesh">>}]},
    [P]=erm_anatomy_data:parse_atlas(jsx:encode([Source,Part])),
    ?assertEqual({100,120,140},maps:get(color,P)),
    ?assertEqual([<<"Data/Model_1_left_kidney.vtk">>],maps:get(paths,P)),
    ?assertEqual([P],erm_anatomy_data:select([P],[<<"LEFT KIDNEY">>])),
    [begin
        Unsafe=Source#{<<"source">>=>Path},
        ?assertError({badmatch,false},erm_anatomy_data:parse_atlas(jsx:encode([Unsafe,Part])))
    end || Path <- [<<"../x.vtk">>,<<"/tmp/x.vtk">>,<<"Data/../../x.vtk">>,
                    <<"https://evil.example/x.vtk">>,<<"Data/x%2f.vtk">>]].
