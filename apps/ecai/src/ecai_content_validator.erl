-module(ecai_content_validator).

-export([validate/2]).

validate(Pack, Evidence) when is_map(Pack), is_map(Evidence) ->
    Checks = [
        fun() -> required_binary(Pack, <<"title">>, 4, 180) end,
        fun() -> required_binary(Pack, <<"slug">>, 3, 160) end,
        fun() -> valid_slug(ecai_content_util:mget(<<"slug">>, Pack, <<>>)) end,
        fun() -> required_binary(Pack, <<"summary">>, 10, 1000) end,
        fun() -> required_binary(Pack, <<"article_markdown">>, 100, 120000) end,
        fun() -> no_html(ecai_content_util:mget(<<"article_markdown">>, Pack, <<>>)) end,
        fun() -> required_binary(Pack, <<"documentation_markdown">>, 80, 120000) end,
        fun() -> validate_linkedin(ecai_content_util:mget(<<"linkedin">>, Pack, #{})) end,
        fun() -> validate_image(ecai_content_util:mget(<<"image">>, Pack, #{})) end,
        fun() -> no_secret_markers(Pack) end,
        fun() -> validate_evidence_refs(Pack, Evidence) end
    ],
    run_checks(Checks);
validate(_, _) ->
    {error, invalid_content_or_evidence}.

run_checks([]) ->
    ok;
run_checks([Fun | Rest]) ->
    case Fun() of
        ok -> run_checks(Rest);
        {error, _} = Error -> Error
    end.

required_binary(Map, Key, Min, Max) ->
    V = ecai_content_util:mget(Key, Map, undefined),
    case is_binary(V) andalso byte_size(V) >= Min andalso byte_size(V) =< Max of
        true -> ok;
        false -> {error, {invalid_required_field, Key, byte_size_safe(V), Min, Max}}
    end.

valid_slug(Slug) when is_binary(Slug) ->
    case re:run(Slug, <<"^[a-z0-9]+(?:-[a-z0-9]+)*$">>, [{capture, none}]) of
        match -> ok;
        nomatch -> {error, {invalid_slug, Slug}}
    end;
valid_slug(Other) ->
    {error, {invalid_slug, Other}}.

no_html(Bin) when is_binary(Bin) ->
    case re:run(Bin, <<"<[A-Za-z][^>]*>">>, [{capture, none}]) of
        nomatch -> ok;
        match -> {error, article_html_not_allowed}
    end;
no_html(_) ->
    {error, article_markdown_not_binary}.

validate_linkedin(Map) when is_map(Map) ->
    case required_binary(Map, <<"commentary">>, 10, 3000) of
        ok -> required_binary(Map, <<"alt_text">>, 1, 120);
        Error -> Error
    end;
validate_linkedin(_) ->
    {error, invalid_linkedin_object}.

validate_image(Map) when is_map(Map) ->
    case required_binary(Map, <<"prompt">>, 20, 8000) of
        ok ->
            Width = int_field(Map, <<"width">>, 1200),
            Height = int_field(Map, <<"height">>, 627),
            case Width >= 256 andalso Width =< 4096 andalso Height >= 256 andalso Height =< 4096 of
                true -> ok;
                false -> {error, {invalid_image_dimensions, Width, Height}}
            end;
        Error ->
            Error
    end;
validate_image(_) ->
    {error, invalid_image_object}.

int_field(Map, Key, Default) ->
    case ecai_content_util:mget(Key, Map, Default) of
        I when is_integer(I) -> I;
        _ -> Default
    end.

no_secret_markers(Pack) ->
    Text = lower(jsx:encode(ecai_content_util:json_safe(Pack))),
    Forbidden = [
        <<"-----begin private key-----">>,
        <<"aws_secret_access_key">>,
        <<"damage_nsecbunker_vault_passphrase">>,
        <<"authorization: bearer ">>,
        <<"linkedin_access_token">>,
        <<"nsec1">>
    ],
    case [F || F <- Forbidden, binary:match(Text, F) =/= nomatch] of
        [] -> ok;
        Hits -> {error, {secret_marker_detected, Hits}}
    end.

validate_evidence_refs(Pack, Evidence) ->
    Known = known_modules(Evidence),
    Refs = ecai_content_util:mget(<<"evidence">>, Pack, []),
    case Refs of
        [] -> {error, missing_evidence_references};
        _ -> validate_refs(Refs, Known)
    end.

validate_refs([], _Known) ->
    ok;
validate_refs([Ref | Rest], Known) when is_map(Ref) ->
    Module = ecai_content_util:to_binary(ecai_content_util:mget(<<"module">>, Ref, <<>>)),
    case Module of
        <<>> ->
            validate_refs(Rest, Known);
        _ ->
            case maps:is_key(Module, Known) of
                true -> validate_refs(Rest, Known);
                false -> {error, {unknown_evidence_module, Module}}
            end
    end;
validate_refs([_ | Rest], Known) ->
    validate_refs(Rest, Known);
validate_refs(_, _Known) ->
    {error, invalid_evidence_list}.

known_modules(Evidence) ->
    Learning = maps:get(learning, Evidence, #{}),
    A = maps:get(analyses, Learning, []),
    K = maps:get(module_knowledge, Learning, []),
    lists:foldl(
        fun(Item, Acc) ->
            case Item of
                M when is_map(M) ->
                    Mod0 = ecai_content_util:mget(
                        module, M, ecai_content_util:mget(<<"module">>, M, undefined)
                    ),
                    case Mod0 of
                        undefined -> Acc;
                        _ -> Acc#{ecai_content_util:to_binary(Mod0) => true}
                    end;
                _ ->
                    Acc
            end
        end,
        #{},
        A ++ K
    ).

byte_size_safe(B) when is_binary(B) -> byte_size(B);
byte_size_safe(_) -> -1.

lower(Bin) -> unicode:characters_to_binary(string:lowercase(binary_to_list(Bin))).
