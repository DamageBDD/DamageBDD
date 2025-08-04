-module(damage_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export(
    [
        render_body_args/2,
        tokenize/1,
        binarystr_join/1,
        binarystr_join/2,
        config/2,
        loaded_steps/0,
        lists_concat/2,
        strf/2,
        get_context_value/3,
        load_template/2,
        send_email/4,
        atom_to_binary_keys/1,
        binary_to_atom_keys/1,
        get_concurrency_level/1,
        get_ip/1,
        test_send_email/0,
        convert_context/1,
        idhash_keys/1,
        safe_json/1,
        is_valid_email/1,
        add_log_filter/1,
        get_stepargs/1
    ]
).
-export([max_by/2]).
-export([normalize_email/1, denormalize_email/1]).

get_stepargs(Body) when is_list(Body) ->
    case lists:keytake(<<"\"\"\"">>, 1, Body) of
        {value, {<<"\"\"\"">>, Doc}, Body0} ->
            {
                damage_utils:binarystr_join(Body0, <<" ">>),
                damage_utils:binarystr_join(Doc)
            };
        _ ->
            {damage_utils:binarystr_join(Body, <<" ">>), <<"">>}
    end.

render_body_args(Body, Context) ->
    {Body0, Args} = get_stepargs(Body),
    try
        Body1 =
            damage_utils:tokenize(
                mustache:render(
                    binary_to_list(Body0),
                    dict:from_list(maps:to_list(Context))
                )
            ),

        Args0 =
            list_to_binary(
                mustache:render(
                    binary_to_list(Args),
                    dict:from_list(maps:to_list(Context))
                )
            ),
        {ok, {Body1, Args0}}
    catch
        error:{unbound_var, Fail} ->
            {error, {Body0, Args}, {unbound_var, Fail}};
        error:Reason ->
            {error, {Body0, Args}, {render, Reason}};
        Other ->
            {error, {Body0, Args}, {unknown, Other}}
    end.

tokenize(Step) when is_binary(Step) -> tokenize(binary_to_list(Step));
tokenize(Step) ->
    Tokens = string:tokens(Step, "\""),
    [string:strip(X) || X <- Tokens].

binarystr_join(ListSep) -> binarystr_join(ListSep, <<"">>).

-spec binarystr_join([binary()], binary()) -> binary().
binarystr_join([], _Sep) ->
    <<>>;
binarystr_join([Part], _Sep) ->
    Part;
binarystr_join(List, Sep) ->
    lists:foldr(
        fun(A, B) ->
            if
                bit_size(B) > 0 -> <<A/binary, Sep/binary, B/binary>>;
                true -> A
            end
        end,
        <<>>,
        List
    ).

config(Config, Key) ->
    {Key, Value} = lists:keyfind(Key, 1, Config),
    Value.

loaded_steps() ->
    lists:filtermap(
        fun({Module, _, _}) ->
            case string:split(Module, "_", all) of
                ["steps", _, "SUITE"] -> false;
                ["steps", _] -> {true, Module};
                _ -> false
            end
        end,
        code:all_available()
    ).

strf(String, Args) -> lists:flatten(io_lib:format(String, Args)).

lists_concat(L, N) -> lists:flatten(string:join([[X] || X <- L], N)).

-spec get_context_value(atom(), map(), list()) -> any().
get_context_value(Key, Context, Config) ->
    case lists:keyfind(key, 1, Config) of
        {_, Default} -> maps:get(Key, Context, Default);
        false -> maps:get(Key, Context)
    end.

atom_to_binary_keys(Map) ->
    maps:from_list(
        lists:map(
            fun
                ({Key, Value}) when is_atom(Key) -> {atom_to_binary(Key), Value};
                (Value) -> Value
            end,
            maps:to_list(Map)
        )
    ).

binary_to_atom_keys(Map) ->
    maps:from_list(
        lists:map(
            fun
                ({Key, Value}) when is_binary(Key) -> {binary_to_atom(Key), Value};
                (Value) -> Value
            end,
            maps:to_list(Map)
        )
    ).

convert_context(Context) ->
    lists:map(
        fun
            ({Key, Value}) when is_binary(Key), is_binary(Value) ->
                {binary_to_atom(Key), binary_to_list(Value)};
            ({Key, Value}) when is_binary(Key) -> {binary_to_atom(Key), Value};
            ({Key, Value}) when is_binary(Value) -> {Key, binary_to_list(Value)};
            ({Key, Value}) when is_binary(Key), is_list(Value) ->
                {binary_to_atom(Key), Value};
            (Value) ->
                Value
        end,
        maps:to_list(Context)
    ).

load_template(Template, Context) ->
    PrivDir = code:priv_dir(damage),
    FilePath = filename:join([PrivDir, "templates", Template]),
    logger:info("Loading template from ~p", [FilePath]),
    {ok, TemplateBin} = file:read_file(FilePath),
    mustache:render(binary_to_list(TemplateBin), convert_context(Context)).

send_email({ToName, To}, Subject, TextBody, HtmlBody) ->
    {ok, SmtpHost} = application:get_env(damage, smtp_host),
    {ok, SmtpUser} = application:get_env(damage, smtp_user),
    {ok, SmtpHostname} = application:get_env(damage, smtp_hostname),
    {ok, SmtpPort} = application:get_env(damage, smtp_port),
    {ok, {FromName, From}} = application:get_env(damage, smtp_from),
    case secrets:retrieve_decrypt(smtp_pass) of
        {ok, SmtpPassword} ->
            %Body1 =
            %  "Subject: {{subject}}\r\nFrom: {{from_name}} <{{from}}>\r\nTo: {{to_name}} <{{to}}>\r\n\r\n{{body}}",
            %Body0 =
            %  mustache:render(
            %    Body1,
            %    convert_context(
            %      #{
            %        body => Body,
            %        subject => Subject,
            %        from => From,
            %        from_name => FromName,
            %        to => To,
            %        to_name => ToName
            %      }
            %    )
            %  ),
            FromNameBin = list_to_binary(FromName),
            FromBin = list_to_binary(From),
            %ToBin = list_to_binary(To),
            MultipartEmail =
                {
                    <<"multipart">>,
                    <<"alternative">>,
                    [
                        {<<"From">>, <<FromNameBin/binary, " <", FromBin/binary, ">">>},
                        {<<"To">>, <<ToName/binary, " <", To/binary, ">">>},
                        {<<"Subject">>, Subject},
                        {<<"MIME-Version">>, <<"1.0">>},
                        {
                            <<"Content-Type">>,
                            <<"multipart/alternative; boundary=---damagebdd-0001">>
                        }
                    ],
                    #{
                        content_type_params => [{<<"boundary">>, <<"---damagebdd-0001">>}],
                        disposition => <<"inline">>,
                        disposition_params => []
                    },
                    [
                        {
                            <<"text">>,
                            <<"plain">>,
                            [
                                {
                                    <<"Content-Type">>,
                                    <<"text/plain;charset=US-ASCII;format=flowed">>
                                },
                                {<<"Content-Transfer-Encoding">>, <<"quoted-printable">>}
                            ],
                            #{
                                content_type_params =>
                                    [{<<"charset">>, <<"US-ASCII">>}, {<<"format">>, <<"flowed">>}],
                                disposition => <<"inline">>,
                                disposition_params => []
                            },
                            list_to_binary(TextBody)
                        },
                        {
                            <<"text">>,
                            <<"html">>,
                            [
                                {<<"Content-Type">>, <<"text/html;charset=US-ASCII">>},
                                {<<"Content-Transfer-Encoding">>, <<"base64">>}
                            ],
                            #{
                                content_type_params => [{<<"charset">>, <<"US-ASCII">>}],
                                disposition => <<"inline">>,
                                disposition_params => []
                            },
                            list_to_binary(HtmlBody)
                        }
                    ]
                },
            Email = {From, [To], mimemail:encode(MultipartEmail)},
            %CaCerts = certifi:cacerts(),
            gen_smtp_client:send(
                Email,
                [
                    {
                        tls_options,
                        [
                            {versions, ['tlsv1.2']},
                            {verify, verify_none},
                            %,
                            {depth, 99}
                            %{cacerts, CaCerts}
                        ]
                    },
                    {tls, always},
                    {auth, always},
                    {relay, SmtpHost},
                    {port, SmtpPort},
                    {hostname, SmtpHostname},
                    {username, SmtpUser},
                    {password, SmtpPassword}
                    %,
                    %       {trace_fun, fun(Format, Args)-> logger:info(Format, Args) end}
                ]
            );
        Error ->
            ?LOG_ERROR("Failed to get email auth ~p", [Error]),
            error
    end.

get_concurrency_level(<<"sk_baby">>) -> 1;
get_concurrency_level(<<"sk_easy">>) -> 10;
get_concurrency_level(<<"sk_medium">>) -> 100;
get_concurrency_level(<<"sk_hard">>) -> 1000;
get_concurrency_level(<<"sk_nightmare">>) -> 10000;
get_concurrency_level(Other) when is_integer(Other) -> Other;
get_concurrency_level(Other) when is_binary(Other) -> binary_to_integer(Other).

get_ip(Req0) ->
    case cowboy_req:peer(Req0) of
        {{IP, _}, _} -> IP;
        {IP, _} -> IP
    end.

idhash(BinString) when is_binary(BinString) ->
    idhash(binary_to_list(BinString));
idhash(String) when is_list(String) -> crypto:hash(sha256, String).

idhash_keys(List) ->
    base64:encode(
        idhash(
            string:join(
                lists:map(
                    fun
                        (BinStr) when is_binary(BinStr) -> binary_to_list(BinStr);
                        (String) -> String
                    end,
                    List
                ),
                ""
            )
        ),
        #{padding => false, mode => urlsafe}
    ).

safe_json(BinaryStr) when is_binary(BinaryStr) ->
    safe_json(binary_to_list(BinaryStr));
safe_json(String) ->
    %% First, we decode the binary string into a list of integers
    lists:foldl(
        fun(Str, Acc) -> lists:concat(string:replace(Acc, Str, "", all)) end,
        String,
        ["\"", ":", "\\/", "\\\\", "\\\"", "\\\""]
    ).

% Finds the maximum element in List using CompareFun as the comparison function
max_by([H | T], CompareFun) ->
    lists:foldl(
        fun(Elem, Max) ->
            case CompareFun(Elem, Max) of
                true ->
                    % Elem is "greater" than Max
                    Elem;
                false ->
                    % Max remains
                    Max
            end
        end,
        H,
        T
    );
max_by([], _) ->
    undefined.

%% Normalize an email address for file system storage

normalize_email(Email) when is_list(Email) ->
    String = lists:map(fun replace_char/1, Email),
    lists:flatten(String).

%% Denormalize a stored file name back to an email address

denormalize_email(FileName) when is_list(FileName) ->
    String = lists:map(fun reverse_replace_char/1, FileName),
    lists:flatten(String).

%% Replace problematic characters

replace_char(Char) ->
    case Char of
        '@' -> "-at-";
        '.' -> "-dot-";
        '/' -> "-slash-";
        '\\' -> "-backslash-";
        _ -> Char
    end.

%% Reverse the replacements

reverse_replace_char(Char) ->
    case Char of
        $- ->
            % Starting point to check combinations
            "-";
        _ ->
            Char
    end.

test_send_email() ->
    ToEmail = {<<"DamageBdd Test">>, <<"test@damagebdd.com">>},
    Context =
        #{
            <<"first_name">> => <<"FirstName">>,
            <<"last_name">> => <<"Lastname">>,
            <<"password_reset_url">> =>
                <<"https://github.com/jagguli/DamageBDD/blob/master/LICENSE">>
        },
    TextBody = damage_utils:load_template("signup_email.txt.mustache", Context),
    HtmlBody = damage_utils:load_template("signup_email.html.mustache", Context),
    ?LOG_DEBUG("Email body ~p~n htmlBody: ~p", [TextBody, HtmlBody]),
    damage_utils:send_email(
        ToEmail,
        <<"DamageBDD Email Test">>,
        TextBody,
        HtmlBody
    ).
is_valid_email(Email) when is_binary(Email) ->
    is_valid_email(binary_to_list(Email));
is_valid_email(Email) when is_list(Email) ->
    Regex = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$",
    case re:run(Email, Regex, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.
add_log_filter(Module) ->
    Filter = {
        fun(#{meta := Meta} = Event, _Args) ->
            ?LOG_ERROR("event ~p", [Event]),
            case maps:get(module, Meta, undefined) of
                Module -> stop;
                _ -> ignore
            end
        end,
        #{}
    },

    logger:add_primary_filter(no_tls_logs, Filter).
