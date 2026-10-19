%% Immutable, portable personality editions. Package bytes never enter the public catalogue.
-module(ecai_personality_catalog).
-compile({no_auto_import,[get/1]}).
-export([all/0, get/1, public/1, manifest/1, defaults/0]).

all() ->
    try
        Products = application:get_env(ecai, personality_catalog, defaults()),
        true = is_list(Products) andalso length(Products) =< 100,
        Loaded = [load(P) || P <- Products],
        Ids = [maps:get(id, P) || P <- Loaded],
        true = length(Ids) =:= length(lists:usort(Ids)),
        {ok, Loaded}
    catch _:_ -> {error, invalid_personality_catalog} end.

get(Id) ->
    case all() of
        {ok, Ps} -> case [P || P <- Ps, maps:get(id, P) =:= Id] of
            [P] -> {ok, P}; [] -> {error, not_found} end;
        Error -> Error
    end.

public(P) -> maps:with([id,name,tagline,description,version,price_sats,edition_limit,
                        traits,license,package_sha256,manifest_uri], P).

manifest(Id) ->
    case get(Id) of
        {ok, P} -> {ok, (maps:remove(manifest_uri,public(P)))#{schema => <<"ecai.personality.manifest.v1">>,
            package_format => <<"ecai.personality.v1">>,
            capabilities => <<"Portable instructions; model/tool access and inference sold separately.">>}};
        Error -> Error
    end.

load(P) when is_map(P) ->
    Id = maps:get(id,P),
    true = is_binary(Id) andalso byte_size(Id) > 0 andalso byte_size(Id) =< 64,
    match = re:run(Id, <<"^[a-z0-9][a-z0-9_-]*$">>, [{capture,none}]),
    true = lists:all(fun(K) -> V=maps:get(K,P), is_binary(V) andalso byte_size(V)>0
        andalso byte_size(V)=<8192 end, [name,tagline,description,version,license]),
    Price = maps:get(price_sats,P), Cap = maps:get(edition_limit,P),
    true = is_integer(Price) andalso Price > 0 andalso Price =< 100000000,
    true = is_integer(Cap) andalso Cap > 0 andalso Cap =< 1000000,
    Traits = maps:get(traits,P,[]),
    true = is_list(Traits) andalso length(Traits)=<16 andalso
        lists:all(fun(T)->is_binary(T) andalso byte_size(T)=<128 end,Traits),
    Dir = case application:get_env(ecai,personality_package_dir) of
        {ok,ConfiguredDir} -> ConfiguredDir;
        undefined -> filename:join(code:priv_dir(ecai),"personalities") end,
    File = maps:get(package_file,P,<<Id/binary,".json">>),
    true = filename:basename(File) =:= File,
    {ok, Info} = file:read_file_info(filename:join(Dir,File)),
    true = element(2,Info) =< 262144,
    {ok, Bytes} = file:read_file(filename:join(Dir,File)),
    #{<<"schema">> := <<"ecai.personality.v1">>, <<"id">> := Id,
      <<"version">> := Version, <<"system_prompt">> := Prompt} = jsx:decode(Bytes,[return_maps]),
    true = Version =:= maps:get(version,P),
    true = is_binary(Prompt) andalso byte_size(Prompt)>0,
    Uri = maps:get(manifest_uri,P,<<>>),
    true = is_binary(Uri) andalso byte_size(Uri)=<2048,
    P#{package_data=>Bytes, package_sha256=>hex(crypto:hash(sha256,Bytes)),traits=>Traits,
       manifest_uri=>Uri}.

hex(B) -> list_to_binary(lists:flatten([io_lib:format("~2.16.0b",[X]) || <<X>> <= B])).

defaults() -> [
    #{id=><<"mathematician">>,name=><<"The Mathematician">>,version=><<"1.0.0">>,
      tagline=><<"Explore a conjecture. Inspect every step.">>,
      description=><<"An exactness-first mathematical collaborator that separates conjectures from proofs and asks for replayable evidence.">>,
      traits=>[<<"Precise">>,<<"Curious">>,<<"Proof-aware">>],price_sats=>21000,edition_limit=>100,
      license=><<"Personal and commercial use of this edition. No exclusive rights; model access and inference are separate.">>},
    #{id=><<"skeptic">>,name=><<"The Skeptic">>,version=><<"1.0.0">>,
      tagline=><<"Turn a confident claim into a testable question.">>,
      description=><<"A constructive critic that identifies assumptions, requests sources and proposes falsifiable checks.">>,
      traits=>[<<"Direct">>,<<"Evidence-led">>,<<"Independent">>],price_sats=>21000,edition_limit=>100,
      license=><<"Personal and commercial use of this edition. No exclusive rights; model access and inference are separate.">>},
    #{id=><<"builder">>,name=><<"The Builder">>,version=><<"1.0.0">>,
      tagline=><<"Make the idea executable.">>,
      description=><<"A practical software collaborator that turns requirements into acceptance criteria, implementation steps and verifiable outcomes.">>,
      traits=>[<<"Practical">>,<<"Systematic">>,<<"Test-driven">>],price_sats=>21000,edition_limit=>100,
      license=><<"Personal and commercial use of this edition. No exclusive rights; model access and inference are separate.">>}
].
