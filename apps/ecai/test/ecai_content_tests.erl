-module(ecai_content_tests).

-include_lib("eunit/include/eunit.hrl").

valid_pack_test() ->
    Evidence = evidence(),
    Pack = valid_pack(),
    ?assertEqual(ok, ecai_content_validator:validate(Pack, Evidence)).

secret_marker_rejected_test() ->
    Pack0 = valid_pack(),
    Article0 = maps:get(<<"article_markdown">>, Pack0),
    Pack = Pack0#{<<"article_markdown">> => <<Article0/binary, "\n\nlinkedin_access_token=secret-value must not appear">>},
    ?assertMatch({error, {secret_marker_detected, _}},
                 ecai_content_validator:validate(Pack, evidence())).

unknown_module_evidence_rejected_test() ->
    Pack0 = valid_pack(),
    Pack = Pack0#{<<"evidence">> => [
        #{<<"application">> => <<"ecai">>, <<"module">> => <<"not_a_real_module">>}
    ]},
    ?assertMatch({error, {unknown_evidence_module, _}},
                 ecai_content_validator:validate(Pack, evidence())).

blossom_default_server_test() ->
    ?assertEqual("https://media.damagebdd.com", ecai_blossom_client:default_server()).

endpoint_test() ->
    {ok, Ep} = ecai_content_util:endpoint(<<"https://media.damagebdd.com/upload?x=1">>),
    ?assertEqual(<<"https">>, maps:get(scheme, Ep)),
    ?assertEqual(<<"media.damagebdd.com">>, maps:get(host, Ep)),
    ?assertEqual(443, maps:get(port, Ep)),
    ?assertEqual(<<"/upload?x=1">>, maps:get(path, Ep)).

undefined_to_binary_test() ->
    ?assertEqual(<<>>, ecai_content_util:to_binary(undefined)).

valid_pack() ->
    #{
        <<"schema_version">> => 1,
        <<"title">> => <<"Persistent code intelligence">>,
        <<"slug">> => <<"persistent-code-intelligence">>,
        <<"summary">> => <<"Grounded summary">>,
        <<"article_markdown">> => <<"# Article\n\nThis article is grounded in the persisted learned code state. It describes only the implementation facts represented by the supplied evidence and avoids unsupported claims.">>,
        <<"documentation_markdown">> => <<"# Operator documentation\n\nUse the operator API to inspect, generate, render, publish, retry, and resume deterministic publication jobs derived from learned code evidence.">>,
        <<"linkedin">> => #{
            <<"commentary">> => <<"A grounded implementation update.">>,
            <<"alt_text">> => <<"Architecture diagram for the ECAI content pipeline">>
        },
        <<"image">> => #{
            <<"prompt">> => <<"Clean technical architecture diagram">>,
            <<"negative_prompt">> => <<"illegible text">>,
            <<"width">> => 1200,
            <<"height">> => 627
        },
        <<"topics">> => [<<"ecai">>, <<"erlang">>],
        <<"evidence">> => [
            #{<<"application">> => <<"ecai">>, <<"module">> => <<"ecai_codebase_learner">>}
        ]
    }.

evidence() ->
    #{
        snapshot_id => <<"snapshot-1">>,
        learning => #{
            module_knowledge => [
                #{application => ecai, module => ecai_codebase_learner,
                  <<"source_sha256">> => <<"abc">>}
            ]
        }
    }.

nostr_long_form_event_test() ->
    Pack = valid_pack(),
    Media = #{url => <<"https://media.damagebdd.com/abc123.png">>},
    Event = ecai_nostr_content:build_event(Pack, Media),
    ?assertEqual(30023, maps:get(kind, Event)),
    Tags = maps:get(tags, Event),
    ?assert(lists:member([<<"d">>, <<"persistent-code-intelligence">>], Tags)),
    ?assert(lists:member([<<"title">>, <<"Persistent code intelligence">>], Tags)),
    ?assert(lists:member([<<"image">>, <<"https://media.damagebdd.com/abc123.png">>], Tags)).

html_article_rejected_test() ->
    Pack0 = valid_pack(),
    Article = <<"# Article\n\nThis article contains enough grounded explanatory material for validation, but then includes a raw HTML element which NIP-23 publication should reject. <div>bad</div>">>,
    Pack = Pack0#{<<"article_markdown">> => Article},
    ?assertEqual({error, article_html_not_allowed},
                 ecai_content_validator:validate(Pack, evidence())).
