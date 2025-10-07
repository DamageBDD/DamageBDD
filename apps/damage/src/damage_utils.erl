-module(damage_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export(
    [
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
        idhash_keys/1,
        json_decode/1,
        yaml_decode/1,
        is_valid_email/1,
        add_log_filter/1,
        ensure_dir/1,
        ensure_group/1,
        ensure_user/2,
        chown_r/2,
        ensure_ssh_host_key/1,
        exists_cmd/1,
        fail/2,
        ctx/1,
        run_ok/2,
        render/2,
        normalize_context/1,
        run/2
    ]
).
-export([yaml_encode/1, yaml_encode_to_file/2]).
-export([max_by/2]).
-export([normalize_email/1, denormalize_email/1]).

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

load_template(Template, Context) ->
    PrivDir = code:priv_dir(damage),
    FilePath = filename:join([PrivDir, "templates", Template]),
    {ok, TemplateBin} = file:read_file(FilePath),
    bbmustache:render(TemplateBin, normalize_context(Context)).

normalize_context(Context) when is_map(Context) ->
    maps:from_list([{key_to_string(K), V} || {K, V} <- maps:to_list(Context)]);
normalize_context(Context) when is_list(Context) ->
    maps:from_list([{key_to_string(K), V} || {K, V} <- Context]);
normalize_context({K, V}) ->
    maps:from_list([{key_to_string(K), V}]);
normalize_context(_) ->
    #{}.

key_to_string(K) when is_atom(K) ->
    atom_to_list(K);
key_to_string(K) when is_binary(K) ->
    binary_to_list(K);
key_to_string(K) when is_list(K) ->
    %% already a string
    K;
key_to_string(K) ->
    %% fallback to string
    io_lib:format("~p", [K]).

render(Template, Context) ->
    bbmustache:render(Template, normalize_context(Context)).

send_email({ToName, To}, Subject, TextBody, HtmlBody) ->
    {ok, SmtpHost} = application:get_env(damage, smtp_host),
    {ok, SmtpUser} = application:get_env(damage, smtp_user),
    {ok, SmtpHostname} = application:get_env(damage, smtp_hostname),
    {ok, SmtpPort} = application:get_env(damage, smtp_port),
    {ok, {FromName, From}} = application:get_env(damage, smtp_from),
    case secrets:retrieve_decrypt(smtp_password) of
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
                            TextBody
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
                            HtmlBody
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

json_decode(BinaryStr) when is_binary(BinaryStr) ->
    json_decode(binary_to_list(BinaryStr));
json_decode(String) ->
    %% First, we decode the binary string into a list of integers
    lists:foldl(
        fun(Str, Acc) -> lists:concat(string:replace(Acc, Str, "", all)) end,
        String,
        ["\"", ":", "\\/", "\\\\", "\\\"", "\\\""]
    ).
yaml_decode(BinaryStr) when is_binary(BinaryStr) ->
    yaml_decode(binary_to_list(BinaryStr));
yaml_decode(String) when is_list(String) ->
    try
        %% Parse YAML into Erlang terms
        Parsed = yamerl_constr:string(String),

        %% Sanitize the parsed structure
        {ok, [sanitize_yaml(Doc) || Doc <- Parsed]}
    catch
        _:Reason ->
            {error, Reason}
    end.

%% @doc Encode an Erlang term as a single-document YAML string (UTF-8 binary).
-spec yaml_encode(term()) -> binary().
yaml_encode(Data) ->
    %% yamerl returns an iolist; wrap Data in a list to emit one YAML document.
    BinIolist = yamerl:encode([Data]),
    iolist_to_binary(BinIolist).

%% @doc Encode and write YAML to a file. Returns ok | {error, Reason}.
-spec yaml_encode_to_file(file:filename(), term()) -> ok | {error, term()}.
yaml_encode_to_file(File, Data) ->
    Bin = yaml_encode(Data),
    file:write_file(File, Bin).

%% Recursive sanitization - remove unwanted keys or values
sanitize_yaml({Key, Value}) ->
    {sanitize_yaml(Key), sanitize_yaml(Value)};
sanitize_yaml([H | T]) ->
    [sanitize_yaml(H) | sanitize_yaml(T)];
sanitize_yaml(Map) when is_map(Map) ->
    maps:map(fun(_K, V) -> sanitize_yaml(V) end, Map);
sanitize_yaml(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([sanitize_yaml(E) || E <- tuple_to_list(Tuple)]);
sanitize_yaml(Value) ->
    case is_dangerous(Value) of
        true -> undefined;
        false -> Value
    end.

%% Define what you consider "dangerous" here
is_dangerous(Value) when is_list(Value) ->
    lists:any(fun(Needle) -> lists:member(Needle, Value) end, ["rm -rf", ":(){", "`", "$(", "eval"]);
is_dangerous(_) ->
    false.

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
    {ok, TestUserEmail} = application:get_env(damage, test_user),
    ToEmail = {<<"DamageBdd Test">>, list_to_binary(TestUserEmail)},
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
    {ok, _Pid} = damage_utils:send_email(
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

sudo_prefix() ->
    case string:trim(os:cmd("id -u")) of
        % root doesn't need sudo
        "0" -> "";
        _ -> "sudo "
    end.

run(Cmd) ->
    ?LOG_INFO("exec: ~s", [Cmd]),
    case exec:run(Cmd, [sync, stdout, stderr]) of
        {ok, _Pid, _Out} ->
            ok;
        {ok, _Out} ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("exec failed ~p for: ~s", [Reason, Cmd]),
            {error, Reason}
    end.

-record(ctx, {sudo = ""}).

ctx(Context) ->
    Sudo =
        case string:trim(os:cmd("id -u")) of
            "0" -> "";
            _ -> "sudo "
        end,
    Context#{
        exec_ctx => #ctx{sudo = Sudo}
    }.

ensure_dir(Dir) ->
    ok = filelib:ensure_dir(filename:join(Dir, ".keep")),
    ok.

exists_cmd(Cmd) ->
    case os:find_executable(Cmd) of
        false -> false;
        _ -> true
    end.

ensure_group(Group) ->
    case os:cmd("getent group " ++ Group) of
        "" ->
            run(sudo_prefix() ++ "groupadd --system " ++ Group);
        _ ->
            ok
    end.

ensure_user(User, Group) ->
    case os:cmd("getent passwd " ++ User) of
        "" ->
            ShellPath =
                case filelib:is_file("/usr/bin/nologin") of
                    true -> "/usr/bin/nologin";
                    false -> "/usr/sbin/nologin"
                end,
            Cmd = damage_utils:strf(
                "useradd --system --create-home --gid ~s --shell ~s --comment \"User for DamageBDD system service\" ~s",
                [Group, ShellPath, User]
            ),
            run(sudo_prefix() ++ Cmd);
        _ ->
            ok
    end.

chown_r(Path, OwnerGroup) ->
    %% chown recursively; best done via system chown
    run(sudo_prefix() ++ damage_utils:strf("chown -R ~s ~s", [OwnerGroup, Path])).

ensure_ssh_host_key(KeyPath) ->
    case filelib:is_file(KeyPath) of
        true ->
            ok;
        false ->
            ok = ensure_dir(filename:dirname(KeyPath) ++ "/"),
            run(damage_utils:strf("ssh-keygen -t rsa -f ~s -N '' -q", [KeyPath]))
    end.
run_ok(Context, CmdIolist) ->
    case run(Context, CmdIolist) of
        ok -> Context;
        {error, R} -> fail(Context, R)
    end.

run(Context, CmdIolist) when is_list(CmdIolist) ->
    run(Context, lists:flatten(CmdIolist));
run(Context, Cmd) when is_binary(Cmd) ->
    run(Context, binary_to_list(Cmd));
run(_Context = #{exec_ctx := #ctx{sudo = Sudo}}, Cmd) when is_list(Cmd) ->
    Full = Sudo ++ Cmd,
    ?LOG_INFO("exec: ~s", [Full]),
    case exec:run(Full, [sync, stdout, stderr]) of
        {ok, _Pid, _Out} ->
            ok;
        {ok, _Out} ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("exec failed ~p for: ~s", [Reason, Full]),
            {error, Reason}
    end.

fail(Context, Reason) ->
    ?LOG_ERROR("step failed ~p", [Reason]),
    maps:put(fail, Reason, Context).
