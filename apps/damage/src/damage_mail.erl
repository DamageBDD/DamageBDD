%% Reuses Damage's SMTP configuration, vault password and gen_smtp/MIME stack.
%% Preparing mail is separate from the side effect so an outbox can durably
%% record sending immediately before handing DATA to the SMTP library.
-module(damage_mail).
-license("Apache-2.0").
-export([prepare/5, send/1]).
-ifdef(TEST).
-export([header/1, encoded_word/1, text_part/2, attachment/1]).
-endif.

prepare({ToName0, To0}, Subject0, Text, Html, Options) ->
    try
        ToName = header(ToName0),
        To = address(To0),
        Subject = header(Subject0),
        {ok, Host0} = application:get_env(damage, smtp_host),
        Host = to_list(Host0),
        {ok, User} = application:get_env(damage, smtp_user),
        {ok, Hostname0} = application:get_env(damage, smtp_hostname),
        Hostname = header(Hostname0),
        {ok, Port} = application:get_env(damage, smtp_port),
        {ok, {FromName0, From0}} = application:get_env(damage, smtp_from),
        From = address(From0),
        FromName = header(FromName0),
        {ok, Password} = secrets:retrieve_decrypt(smtp_password),
        {module, gen_smtp_client} = code:ensure_loaded(gen_smtp_client),
        true = erlang:function_exported(gen_smtp_client, send_blocking, 2),
        MsgId = header(proplists:get_value(message_id, Options)),
        Headers = [
            {<<"From">>, mailbox(FromName, From)},
            {<<"To">>, mailbox(ToName, To)},
            {<<"Subject">>, encoded_word(Subject)},
            {<<"Date">>, date_header()},
            {<<"Message-ID">>, MsgId},
            {<<"MIME-Version">>, <<"1.0">>}
        ],
        Alternatives =
            {<<"multipart">>, <<"alternative">>, [], multipart_params(), [
                text_part(<<"plain">>, Text), text_part(<<"html">>, Html)
            ]},
        Attachments = [attachment(A) || A <- proplists:get_value(attachments, Options, [])],
        MIME =
            {<<"multipart">>, <<"mixed">>, Headers, multipart_params(), [
                Alternatives | Attachments
            ]},
        Envelope = {binary_to_list(From), [binary_to_list(To)], mimemail:encode(MIME)},
        TLS = [
            {versions, ['tlsv1.3', 'tlsv1.2']},
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {depth, 4},
            {server_name_indication, Host},
            {customize_hostname_check, [
                {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
            ]}
        ],
        SMTP = [
            {tls_options, TLS},
            {tls, always},
            {auth, always},
            {relay, Host},
            {port, Port},
            {hostname, binary_to_list(Hostname)},
            {username, User},
            {password, Password},
            {protocol, smtp},
            {retries, 0}
        ],
        {ok, {Envelope, SMTP}}
    catch
        _:_ -> {error, mail_configuration_or_encoding_failed}
    end.

send({Envelope, SMTP}) ->
    %% SMTP acceptance is not proof of mailbox delivery. Do not return or log
    %% raw receipts/errors: relay errors can contain recipient addresses.
    try gen_smtp_client:send_blocking(Envelope, SMTP) of
        Receipt when is_binary(Receipt), byte_size(Receipt) > 0 -> {ok, accepted};
        _ -> {error, smtp_outcome_unknown}
    catch
        _:_ -> {error, smtp_outcome_unknown}
    end.

multipart_params() ->
    #{
        content_type_params => [
            {<<"boundary">>,
                <<"damage-", (binary:encode_hex(crypto:strong_rand_bytes(18)))/binary>>}
        ],
        disposition => <<"inline">>,
        disposition_params => []
    }.
text_part(SubType, Body) ->
    {<<"text">>, SubType, [{<<"Content-Transfer-Encoding">>, <<"base64">>}],
        #{
            content_type_params => [{<<"charset">>, <<"utf-8">>}],
            disposition => <<"inline">>,
            disposition_params => []
        },
        Body}.
attachment({Name0, <<"application/pdf">>, PDF}) when is_binary(PDF), byte_size(PDF) =< 10485760 ->
    Name = header(Name0),
    true = re:run(Name, <<"^[A-Za-z0-9_.-]+\\.pdf$">>, [{capture, none}]) =:= match,
    {<<"application">>, <<"pdf">>, [{<<"Content-Transfer-Encoding">>, <<"base64">>}],
        #{
            content_type_params => [{<<"name">>, Name}],
            disposition => <<"attachment">>,
            disposition_params => [{<<"filename">>, Name}]
        },
        PDF}.
header(V) ->
    B = to_bin(V),
    true = byte_size(B) > 0 andalso byte_size(B) =< 512,
    true = re:run(B, <<"[\\r\\n\\x00]">>, [{capture, none}]) =:= nomatch,
    B.
address(V) ->
    B = header(V),
    true =
        re:run(B, <<"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,63}$">>, [
            {capture, none}
        ]) =:= match,
    B.
mailbox(Name, Email) -> <<(encoded_word(Name))/binary, " <", Email/binary, ">">>.
%% Keep RFC 2047 encoded words short without splitting UTF-8 code points.
encoded_word(B) ->
    Words = encoded_words(B, <<>>, []),
    iolist_to_binary(lists:join(<<" ">>, Words)).
encoded_words(<<>>, <<>>, Acc) ->
    lists:reverse(Acc);
encoded_words(<<>>, Current, Acc) ->
    lists:reverse([word(Current) | Acc]);
encoded_words(<<C/utf8, Rest/binary>>, Current, Acc) ->
    Next = <<Current/binary, C/utf8>>,
    case byte_size(Next) =< 42 of
        true -> encoded_words(Rest, Next, Acc);
        false -> encoded_words(Rest, <<C/utf8>>, [word(Current) | Acc])
    end.
word(B) -> <<"=?UTF-8?B?", (base64:encode(B))/binary, "?=">>.
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
date_header() ->
    {{Y, M, D} = Date, {H, Mi, S}} = calendar:universal_time(),
    Day = lists:nth(calendar:day_of_the_week(Date), [
        "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"
    ]),
    Month = lists:nth(M, [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]),
    iolist_to_binary(
        io_lib:format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B +0000", [
            Day, D, Month, Y, H, Mi, S
        ])
    ).
