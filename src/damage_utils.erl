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
    setup_vanillae_deps/0,
    atom_to_binary_keys/1,
    binary_to_atom_keys/1,
    get_concurrency_level/1,
    get_ip/1,
    test_encrypt_decrypt/0,
    test_send_email/0,
    convert_context/1
  ]
).
-export([encrypt/2, encrypt/1, decrypt/2, decrypt/1]).

get_stepargs(Body) when is_list(Body) ->
  case lists:keytake(<<"\"\"\"">>, 1, Body) of
    {value, {<<"\"\"\"">>, Doc}, Body0} ->
      {
        damage_utils:binarystr_join(Body0, <<" ">>),
        damage_utils:binarystr_join(Doc)
      };

    _ -> {damage_utils:binarystr_join(Body, <<" ">>), <<"">>}
  end.


render_body_args(Body, Context) ->
  {Body0, Args} = get_stepargs(Body),
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
  {Body1, Args0}.


tokenize(Step) when is_binary(Step) -> tokenize(binary_to_list(Step));

tokenize(Step) ->
  Tokens = string:tokens(Step, "\""),
  [string:strip(X) || X <- Tokens].


binarystr_join(ListSep) -> binarystr_join(ListSep, <<"">>).

-spec binarystr_join([binary()], binary()) -> binary().
binarystr_join([], _Sep) -> <<>>;
binarystr_join([Part], _Sep) -> Part;

binarystr_join(List, Sep) ->
  lists:foldr(
    fun
      (A, B) ->
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
    fun
      ({Module, _, _}) ->
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


setup_vanillae_deps() ->
  true = code:add_path("_checkouts/vanillae/ebin"),
  true = code:add_path("_checkouts/vw/ebin"),
  Vanillae =
    "otpr-vanillae-" ++ lists:droplast(os:cmd("zx latest otpr-vanillae")),
  Deps = string:lexemes(os:cmd("zx list deps " ++ Vanillae), "\n"),
  ZX =
    "otpr-zx-"
    ++
    lists:nth(2, string:lexemes(lists:droplast(os:cmd("zx --version")), " ")),
  Packages = [ZX, Vanillae | Deps],
  ZompLib = filename:join(os:getenv("HOME"), "zomp/lib"),
  ?LOG_DEBUG("Packages paths ~p", [Packages]),
  Converted =
    [string:join(string:lexemes(Package, "-"), "/") || Package <- Packages],
  PackagePaths =
    [filename:join([ZompLib, PackagePath, "ebin"]) || PackagePath <- Converted],
  ?LOG_DEBUG("Code paths ~p", [PackagePaths]),
  ok = code:add_paths(PackagePaths).


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
      (Value) -> Value
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
  SmtpPassword = os:getenv("SMTP_PASSWORD"),
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
            content_type_params
            =>
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
  ).

%% Encrypt a information string

% https://medium.com/@brucifi/how-to-encrypt-with-aes-256-gcm-with-erlang-2a2aec13598d
encrypt(PlainText) when is_list(PlainText) ->
  encrypt(list_to_binary(PlainText));

encrypt(PlainText) when is_binary(PlainText) ->
  case os:getenv("KYC_SECRET_KEY") of
    false ->
      logger:info("KYC_SECRET_KEY environment variable not set."),
      exit(normal);

    KycKey -> encrypt(PlainText, KycKey)
  end.


encrypt(KYCInfo, Key) when is_binary(KYCInfo), is_list(Key) ->
  encrypt(KYCInfo, list_to_binary(Key));

encrypt(Data, Key) when is_binary(Data), is_binary(Key) ->
  <<Key0:32/binary, Nonce:16/binary>> = base64:decode(Key),
  {CipherText, Tag} =
    crypto:crypto_one_time_aead(aes_256_gcm, Key0, Nonce, Data, <<>>, true),
  <<Tag/binary, CipherText/binary>>.

%% Decrypt a information string

decrypt(Encrypted) when is_binary(Encrypted) ->
  case os:getenv("KYC_SECRET_KEY") of
    false ->
      logger:info("KYC_SECRET_KEY environment variable not set."),
      exit(normal);

    KycKey -> decrypt(Encrypted, list_to_binary(KycKey))
  end.


decrypt(Encrypted, Key) when is_binary(Encrypted), is_binary(Key) ->
  EncryptedData = Encrypted,
  <<Key0:32/binary, Nonce:16/binary>> = base64:decode(Key),
  AAD = <<"">>,
  <<Tag:16/binary, CipherText/binary>> = EncryptedData,
  crypto:crypto_one_time_aead(
    aes_256_gcm,
    Key0,
    Nonce,
    CipherText,
    AAD,
    Tag,
    false
  ).


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


test_encrypt_decrypt() ->
  Key = crypto:strong_rand_bytes(32),
  Nonce = crypto:strong_rand_bytes(16),
  KycKey0 = <<Key/binary, Nonce/binary>>,
  KycKey = base64:encode(KycKey0),
  KYCInfo = <<"Sensitive KYC Information">>,
  CipherText = encrypt(KYCInfo, KycKey),
  KYCInfo = decrypt(CipherText, KycKey).


test_send_email() ->
  ToEmail = {<<"DamageBdd Test">>, <<"test@damagebdd.com">>},
  Context =
    #{
      <<"first_name">> => <<"FirstName">>,
      <<"last_name">> => <<"Lastname">>,
      <<"password_reset_url">>
      =>
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


%test_simple_mail() ->
%  {ok, Socket} = ssl:connect("smtp.sendgrid.net", 465, [{active, false}], 1000),
%  recv(Socket),
%  send(Socket, "HELO localhost"),
%  send(Socket, "AUTH LOGIN"),
%  send(Socket, binary_to_list(base64:encode("apikey"))),
%  send(Socket, binary_to_list(base64:encode("QVEQzrbjS1GKUUkLXymcsg"))),
%  send(Socket, "MAIL FROM: <steven@damagebdd.com>"),
%  send(Socket, "RCPT TO: <melit.stevenjoseph@gmail.com>"),
%  send(Socket, "DATA"),
%  send_no_receive(Socket, "From: <steven@damagebdd.com>"),
%  send_no_receive(Socket, "To: <melit.stevenjoseph@gmail.com>"),
%  send_no_receive(Socket, "Date: Tue, 20 Jun 2012 20:34:43 +0000"),
%  send_no_receive(Socket, "Subject: Hi!"),
%  send_no_receive(Socket, ""),
%  send_no_receive(Socket, "This was sent from Erlang. So simple!"),
%  send_no_receive(Socket, ""),
%  send(Socket, "."),
%  send(Socket, "QUIT"),
%  ssl:close(Socket).
