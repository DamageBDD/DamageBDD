-module(damage_mail_tests).
-include_lib("eunit/include/eunit.hrl").
header_injection_test() ->
    ?assertError({badmatch,false},damage_mail:header(<<"Customer\r\nBcc: unwanted@example.invalid">>)),
    ?assertError({badmatch,false},damage_mail:header(<<"zero",0,"byte">>)).
encoded_word_test() ->
    Unicode = unicode:characters_to_binary(lists:duplicate(100,16#03BB)),
    Words = binary:split(damage_mail:encoded_word(Unicode),<<" ">>,[global]),
    ?assert(lists:all(fun(W) -> byte_size(W) =< 75 end,Words)),
    Decoded = iolist_to_binary([begin
        <<"=?UTF-8?B?",Rest/binary>> = W,
        [Encoded,<<>>] = binary:split(Rest,<<"?=">>),
        Part = base64:decode(Encoded),
        ?assert(is_binary(unicode:characters_to_binary(Part))), Part
    end || W <- Words]),
    ?assertEqual(Unicode,Decoded).
text_mime_shape_test() ->
    ?assertMatch({<<"text">>,<<"plain">>,_,#{content_type_params := _,disposition := <<"inline">>},<<"hello">>},
        damage_mail:text_part(<<"plain">>,<<"hello">>)).
pdf_mime_roundtrip_test() ->
    PDF = <<"%PDF-1.4 DEMONSTRATION\r\n", 0, 127, 128, 255, "\r\n">>,
    Part = damage_mail:attachment({<<"TEST-1.pdf">>, <<"application/pdf">>, PDF}),
    %% encode/1 expects a complete message, not an isolated attachment.
    %% Message headers belong on the outer multipart, as in prepare/5.
    Headers = [
        {<<"From">>, <<"DamageBDD <billing@example.invalid>">>},
        {<<"To">>, <<"Customer <customer@example.invalid>">>},
        {<<"Subject">>, <<"Invoice attachment roundtrip">>},
        {<<"Date">>, <<"Fri, 09 Oct 2026 00:00:00 +0000">>},
        {<<"Message-ID">>, <<"<invoice-roundtrip@example.invalid>">>},
        {<<"MIME-Version">>, <<"1.0">>}
    ],
    Params = #{
        content_type_params => [{<<"boundary">>, <<"damage-invoice-test-boundary">>}],
        disposition => <<"inline">>,
        disposition_params => []
    },
    Message = {<<"multipart">>, <<"mixed">>, Headers, Params, [Part]},
    Encoded = mimemail:encode(Message),
    {<<"multipart">>, <<"mixed">>, DecodedHeaders, _, [DecodedPart]} =
        mimemail:decode(Encoded),
    ?assertEqual(
        <<"DamageBDD <billing@example.invalid>">>,
        mimemail:get_header_value(<<"From">>, DecodedHeaders)
    ),
    ?assertMatch({<<"application">>, <<"pdf">>, _, _, PDF}, DecodedPart),
    {_, _, PartHeaders, PartParams, _} = DecodedPart,
    ?assertEqual(undefined, mimemail:get_header_value(<<"From">>, PartHeaders)),
    ?assertEqual(<<"attachment">>, maps:get(disposition, PartParams)),
    ?assertEqual(
        <<"TEST-1.pdf">>,
        proplists:get_value(<<"filename">>, maps:get(disposition_params, PartParams))
    ),
    ?assertError(
        {badmatch, false},
        damage_mail:attachment({<<"../private.pdf">>, <<"application/pdf">>, PDF})
    ).
