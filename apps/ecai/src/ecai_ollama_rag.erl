-module(ecai_ollama_rag).

-export([
    ask_qa/2,
    ask_bdd/2,
    retrieve_sources/3
]).

-define(OLLAMA_HOST, "localhost").
-define(OLLAMA_PORT, 11434).
-define(OLLAMA_MODEL, "qwen2.5-coder:14b").
-define(EMBED_MODEL, <<"nomic-embed-text">>).

-define(DEFAULT_CANDIDATE_POOL, 24).

ask_qa(BaseDir, Query0) ->
    Query = to_bin(Query0),
    Sources = retrieve_sources(BaseDir, Query, 8),
    Prompt = build_prompt(qa, Query, Sources),
    ollama_generate(Prompt, system_prompt(qa)).

ask_bdd(BaseDir, Query0) ->
    Query = to_bin(Query0),
    Sources = retrieve_sources(BaseDir, Query, 10),
    Prompt = build_prompt(bdd, Query, Sources),
    ollama_generate(Prompt, system_prompt(bdd)).

%%====================================================================
%% Retrieval
%%====================================================================

retrieve_sources(BaseDir, QueryBin, K) ->
    HotTab = ecai_hot_terms:new(20000),
    Terms = tokenize(QueryBin),

    %% 1) lexical shortlist
    Postings = [ecai_disk_search:term_postings(BaseDir, HotTab, T) || T <- Terms],
    Scores = score_docs(Postings),
    CandidateDocInts = top_k(Scores, ?DEFAULT_CANDIDATE_POOL),

    {ok, DocTab} = ecai_disk_docstore:open(BaseDir),
    Candidates = load_candidate_metas(DocTab, CandidateDocInts),
    ok = ecai_disk_docstore:close(DocTab),

    %% 2) semantic rerank with embeddings
    case rerank_by_embeddings(QueryBin, Candidates) of
        {ok, Ranked} ->
            lists:sublist(Ranked, min(K, length(Ranked)));
        {error, _} ->
            %% fallback to lexical order if embeddings unavailable
            lists:sublist(Candidates, min(K, length(Candidates)))
    end.

load_candidate_metas(DocTab, DocInts) ->
    [
        begin
            case ecai_disk_docstore:get(DocTab, DocInt) of
                {ok, M} ->
                    M#{docint => DocInt};
                not_found ->
                    #{
                        docint => DocInt,
                        cid => <<>>,
                        title => <<>>,
                        heading => <<>>,
                        text => <<>>
                    }
            end
        end
     || DocInt <- DocInts
    ].

rerank_by_embeddings(QueryBin, Candidates) ->
    QueryText = embedding_text_query(QueryBin),
    CandidateTexts = [embedding_text_doc(M) || M <- Candidates],

    case embed_many([QueryText | CandidateTexts]) of
        {ok, [QueryVec | DocVecs]} ->
            Scored =
                lists:zipwith(
                    fun(Meta, Vec) ->
                        Score = cosine_similarity(QueryVec, Vec),
                        {Score, Meta}
                    end,
                    Candidates,
                    DocVecs
                ),
            Sorted = lists:sort(fun({A, _}, {B, _}) -> A >= B end, Scored),
            {ok, [M#{semantic_score => S} || {S, M} <- Sorted]};
        {ok, _Unexpected} ->
            {error, bad_embedding_shape};
        {error, _} = Err ->
            Err
    end.

embedding_text_query(QueryBin) ->
    QueryBin.

embedding_text_doc(Meta) ->
    Title = maps:get(title, Meta, <<>>),
    Heading = maps:get(heading, Meta, <<>>),
    Text = maps:get(text, Meta, <<>>),
    iolist_to_binary([
        <<"title: ">>,
        Title,
        <<"\n">>,
        <<"heading: ">>,
        Heading,
        <<"\n">>,
        <<"content:\n">>,
        Text
    ]).

%%====================================================================
%% Lexical scoring
%%====================================================================

score_docs(PostingsLists) ->
    lists:foldl(
        fun(DocInt, Acc) ->
            maps:update_with(DocInt, fun(X) -> X + 1 end, 1, Acc)
        end,
        #{},
        lists:flatten(PostingsLists)
    ).

top_k(ScoresMap, K) ->
    Pairs = maps:to_list(ScoresMap),
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A >= B end, Pairs),
    [DocInt || {DocInt, _Score} <- lists:sublist(Sorted, min(K, length(Sorted)))].

%%====================================================================
%% Prompt building
%%====================================================================

build_prompt(_Mode, Query, Sources) ->
    SrcTxt =
        lists:flatten(
            [
                io_lib:format(
                    "[S~p] doc=~p cid=~s title=~s heading=~s sem=~p~n~s~n~n",
                    [
                        I,
                        maps:get(docint, S, 0),
                        maps:get(cid, S, <<>>),
                        maps:get(title, S, <<>>),
                        maps:get(heading, S, <<>>),
                        maps:get(semantic_score, S, undefined),
                        maps:get(text, S, <<>>)
                    ]
                )
             || {I, S} <- lists:zip(lists:seq(1, length(Sources)), Sources)
            ]
        ),
    list_to_binary(
        io_lib:format(
            "SOURCES:\n~s\nUSER QUESTION:\n~s\n",
            [SrcTxt, Query]
        )
    ).

system_prompt(qa) ->
    <<
        "You are the DamageBDD assistant.\n"
        "Rules:\n"
        "- Only answer using the SOURCES provided.\n"
        "- If something is not in sources, say: 'Not in sources.'\n"
        "- For factual claims, cite sources like [S1], [S2].\n"
        "- Be concise and high-signal.\n"
    >>;
system_prompt(bdd) ->
    <<
        "You are the DamageBDD assistant.\n"
        "Rules:\n"
        "- Only use information from SOURCES.\n"
        "- Output ONLY a valid Gherkin feature file.\n"
        "- Use ONLY the supported DamageBDD step patterns listed below. Do not invent steps.\n"
        "- If a required detail is missing from sources, add a comment line starting with '# TODO'.\n"
        "\nSUPPORTED STEPS:\n"
        "Given I am using server \"{{Server}}\":\n"
        "Given I set \"{{Header}}\" header to \"{{Value}}\":\n"
        "When I make a GET request to \"{{Path}}\":\n"
        "When I make a OPTIONS request to \"{{Path}}\":\n"
        "When I make a HEAD request to \"{{Path}}\":\n"
        "When I make a TRACE request to \"{{Path}}\":\n"
        "When I make a POST request to \"{{Path}}\":\n"
        "When I make a CSRF POST request to \"{{Path}}\":\n"
        "When I make a PATCH request to \"{{Path}}\":\n"
        "When I make a PUT request to \"{{Path}}\":\n"
        "When I make a DELETE request to \"{{Path}}\":\n"
        "Then the response must contain text \"{{Contains}}\":\n"
        "Then I print the response:\n"
        "Given I store cookies:\n"
        "Given I set base URL to \"{{URL}}\":\n"
        "And I set the variable \"{{Variable}}\" to \"{{Value}}\":\n"
        "And I do not want to verify server certificate:\n"
        "Then the JSON should be:\n"
        "Then the response status must be \"{{Status}}\":\n"
        "Then the yaml at path \"{{Path}}\" must be \"{{Expected}}\":\n"
        "Then the json at path \"{{Path}}\" must be \"{{Expected}}\":\n"
        "Then the response status must be one of \"{{Statuses}}\":\n"
        "Then the \"{{Header}}\" header should be \"{{Value}}\":\n"
        "Then I store the JSON at path \"{{Path}}\" in \"{{Variable}}\":\n"
        "Then the variable \"{{Variable}}\" should be equal to JSON \"{{Value}}\":\n"
        "Then the variable \"{{Variable}}\" should be equal to JSON:\n"
        "Then the JSON at path \"{{JsonPath}}\" should be:\n"
        "Then the json at path \"{{JsonPath}}\" must be:\n"
        "Then I set BasicAuth username to \"{{User}}\" and password to \"{{Password}}\":\n"
        "Then I use query OAuth with key=\"{{Key}}\" and secret=\"{{Secret}}\":\n"
        "Then I use header OAuth with key=\"{{Key}}\" and secret=\"{{Secret}}\":\n"
        "Given I store an uuid in \"{{Variable}}\":\n"
        "Given I wait \"{{Seconds}}\" seconds:\n"
        "Given I store current time string in \"{{Variable}}\" with format \"{{Format}}\":\n"
    >>.

%%====================================================================
%% Ollama generate
%%====================================================================

ollama_generate(Prompt, System) ->
    Body =
        jsx:encode(#{
            <<"model">> => to_bin(?OLLAMA_MODEL),
            <<"system">> => System,
            <<"prompt">> => Prompt,
            <<"stream">> => false
        }),

    case
        damage_gun:post(
            ?OLLAMA_HOST,
            ?OLLAMA_PORT,
            "/api/generate",
            [{<<"content-type">>, <<"application/json">>}],
            Body,
            #{
                timeout => 60000,
                connect_timeout => 5000,
                decode => json,
                proxy => direct,
                transport => tcp
            }
        )
    of
        {ok, #{status := Status, json := Json, body := RawBody}} when
            Status >= 200, Status < 300
        ->
            decode_generate_response(Json, RawBody);
        {ok, #{status := Status, json := Json, body := RawBody}} ->
            {error, {ollama_http_status, Status, ollama_error(Json, RawBody)}};
        {ok, #{status := Status, body := RawBody}} ->
            {error, {ollama_http_status, Status, RawBody}};
        {error, Reason} ->
            {error, {ollama_request_failed, Reason}}
    end.
decode_generate_response(Json, RawBody) when is_map(Json) ->
    case maps:get(response, Json, undefined) of
        Reply when is_binary(Reply) ->
            {ok, Reply};
        undefined ->
            case maps:get(<<"response">>, Json, undefined) of
                Reply when is_binary(Reply) ->
                    {ok, Reply};
                _ ->
                    {error, {missing_response, Json, RawBody}}
            end;
        Other ->
            {error, {bad_response_field, Other, Json}}
    end;
decode_generate_response(Json, RawBody) ->
    {error, {bad_generate_json, Json, RawBody}}.

ollama_error(Json, RawBody) when is_map(Json) ->
    case maps:get(error, Json, undefined) of
        undefined -> maps:get(<<"error">>, Json, RawBody);
        Err -> Err
    end;
ollama_error(_Json, RawBody) ->
    RawBody.

%%====================================================================
%% Ollama embeddings
%%====================================================================

embed_many(Texts) ->
    embed_many_loop(Texts, []).

embed_many_loop([], Acc) ->
    {ok, lists:reverse(Acc)};
embed_many_loop([Text | Rest], Acc) ->
    case ollama_embed(Text) of
        {ok, Vec} ->
            embed_many_loop(Rest, [Vec | Acc]);
        {error, _} = Err ->
            Err
    end.

ollama_embed(Text) ->
    Body =
        jsx:encode(#{
            <<"model">> => ?EMBED_MODEL,
            <<"input">> => Text
        }),

    case
        damage_gun:post(
            ?OLLAMA_HOST,
            ?OLLAMA_PORT,
            "/api/embeddings",
            [{<<"content-type">>, <<"application/json">>}],
            Body,
            #{
                timeout => 30000,
                connect_timeout => 5000,
                decode => json,
                proxy => direct,
                transport => tcp
            }
        )
    of
        {ok, #{status := Status, json := Json, body := RawBody}} when
            Status >= 200, Status < 300
        ->
            decode_embedding_json(Json, RawBody);
        {ok, #{status := Status, json := Json, body := RawBody}} ->
            {error, {embed_http_status, Status, ollama_error(Json, RawBody)}};
        {ok, #{status := Status, body := RawBody}} ->
            {error, {embed_http_status, Status, RawBody}};
        {error, Reason} ->
            {error, {embed_request_failed, Reason}}
    end.

decode_embedding_json(Json, RawBody) when is_map(Json) ->
    case maps:get(embedding, Json, undefined) of
        undefined ->
            case maps:get(embeddings, Json, undefined) of
                [Vec | _] ->
                    {ok, to_float_list(Vec)};
                _ ->
                    %% binary-label fallback, in case decode mode changes later
                    case maps:get(<<"embedding">>, Json, undefined) of
                        Vec when is_list(Vec) ->
                            {ok, to_float_list(Vec)};
                        _ ->
                            case maps:get(<<"embeddings">>, Json, undefined) of
                                [Vec0 | _] -> {ok, to_float_list(Vec0)};
                                _ -> {error, {missing_embedding, Json, RawBody}}
                            end
                    end
            end;
        Vec ->
            {ok, to_float_list(Vec)}
    end;
decode_embedding_json(Json, RawBody) ->
    {error, {bad_embedding_json, Json, RawBody}}.

to_float_list(List) when is_list(List) ->
    [to_float(V) || V <- List].

to_float(V) when is_float(V) -> V;
to_float(V) when is_integer(V) -> float(V);
to_float(V) -> erlang:binary_to_float(iolist_to_binary(io_lib:format("~p", [V]))).

cosine_similarity(A, B) ->
    {Dot, NA, NB} =
        lists:foldl(
            fun({X, Y}, {D, SA, SB}) ->
                {D + (X * Y), SA + (X * X), SB + (Y * Y)}
            end,
            {0.0, 0.0, 0.0},
            lists:zip(A, B)
        ),
    Eps = 1.0e-12,
    case (NA =< Eps) orelse (NB =< Eps) of
        true ->
            -1.0;
        false ->
            Dot / (math:sqrt(NA) * math:sqrt(NB))
    end.

%%====================================================================
%% Utilities
%%====================================================================

tokenize(Bin) when is_binary(Bin) ->
    Lower = string:lowercase(binary_to_list(Bin)),
    Raw = re:split(Lower, "[^a-z0-9_]+", [{return, list}, trim]),
    [list_to_binary(T) || T <- Raw, length(T) >= 3].

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I).
