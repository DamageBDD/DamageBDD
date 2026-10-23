%% Private verification lane: configured Gherkin + the existing HTTP step module.
%% Deliberately NOT the paid/public execute_data pipeline: no wallet, IPFS or
%% account-context expansion. Unsupported ASTs/steps fail closed, never pass.
-module(damage_agent_bdd).
-license("Apache-2.0").
-export([run/2]).

run(A,Ticket) ->
    try
        true = proplists:get_value(trusted_native,A,false),
        %% Arbitrary step modules require a separately reviewed adapter instead.
        Feature = proplists:get_value(feature,A),
        AST = case egherkin:parse(Feature) of {ok,Tree} -> Tree; Tree -> Tree end,
        {_L,_Tags,_Name,_Description,Background,Scenarios} = AST,
        true = is_list(Scenarios) andalso Scenarios =/= [],
        Bg = background(Background),
        Context0 = #{public_key => maps:get(owner,Ticket)},
        {Context,Results} = lists:foldl(fun({_N,_Title,_STags,Steps},{_Prior,Acc}) ->
            true = is_list(Steps) andalso Steps =/= [],
            true = lists:any(fun({_Line,K,_Body}) -> keyword(K) =:= <<"Then">> end,Steps),
            %% Each scenario gets a fresh context: no leaked auth/cookies between scenarios.
            {C,Rs,_} = lists:foldl(fun(Step,S) -> run_step(Step,S,proplists:get_value(effect,A,read)) end,
                                  {Context0,[],<<"Given">>},Bg++Steps),
            {C,Acc++Rs}
        end,{Context0,[]},Scenarios),
        true = Results =/= [],
        Projection = project(Context,proplists:get_value(observe_variables,A,[])),
        {ok,#{<<"observation">> => #{<<"status">> => <<"passed">>,<<"values">> => Projection},
              <<"evidence">> => #{<<"scope">> => <<"configured_http_bdd_assertions_only">>,
                <<"feature_sha256">> => string:lowercase(binary:encode_hex(crypto:hash(sha256,Feature))),
                <<"steps">> => Results,<<"assertions_passed">> =>
                    length([R || #{<<"keyword">> := <<"Then">>} = R <- Results])}}}
    catch _:_ -> {error,bdd_verification_failed} end.
background(undefined) -> [];
background([]) -> [];
background({_Name,Steps}) when is_list(Steps) -> Steps.
keyword(K) -> damage_agent_codec:bin(K).

run_step({N,K0,Body},{Context,Results,Previous},Effect) ->
    K = case keyword(K0) of <<"And">> -> Previous; <<"But">> -> Previous; V -> V end,
    true = lists:member(K,[<<"Given">>,<<"When">>,<<"Then">>]),
    {ok,{Parts,Args}} = damage_context:render_body_args(Body,Context),
    true = Parts =/= ["I do not want to verify server certificate"],
    true = Effect =/= read orelse read_only(Parts),
    %% Prevent a cosmetic Then (such as printing a response) from being a verifier.
    true = K =/= <<"Then">> orelse assertion(Parts),
    New = steps_http:step([],Context,K,N,Parts,Args),
    true = is_map(New) andalso not maps:is_key(fail,New) andalso
                           not maps:is_key(failing_step,New),
    R = #{<<"line">> => N,<<"keyword">> => K,<<"status">> => <<"passed">>},
    {New,Results++[R],K}.
assertion(["the response status must be",_]) -> true;
assertion(["the response must contain text",_]) -> true;
assertion(["the json at path",_,"must be",_]) -> true;
assertion(["the JSON should be"]) -> true;
assertion(_) -> false.

project(C,Names) ->
    true = length(Names) =< 16,
    maps:from_list([begin
        Key = damage_agent_codec:bin(N),
        V = projected_value(Key,C),
        true = damage_agent_codec:json_value(V,0),
        true = byte_size(damage_agent_codec:canonical(V)) =< 4096,
        {Key,V}
    end || N <- Names]).

projected_value(Key,C) ->
    case maps:find(Key,C) of
        {ok,V} -> V;
        error ->
            case maps:find(binary_to_list(Key),C) of
                {ok,V} -> V;
                error ->
                    %% Existing HTTP steps may store atoms; never allocate a new atom.
                    try maps:get(binary_to_existing_atom(Key,utf8),C,null)
                    catch error:badarg -> null end
            end
    end.

read_only([Phrase|_]) ->
    not lists:member(Phrase,["I make a POST request to","I make a PUT request to",
        "I make a PATCH request to","I make a DELETE request to","I make a TRACE request to",
        "I make a form POST request to","I make a CSRF POST request to"]);
read_only(_) -> false.
