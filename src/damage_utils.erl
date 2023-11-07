-module(damage_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

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
    send_email/3,
    setup_vanillae_deps/0,
    %test_simple_mail/0,
    test_send_email/0
  ]
).
-export([encrypt/3, decrypt/3]).

get_stepargs(Body) when is_list(Body) ->
  case lists:keytake(docstring, 1, Body) of
    {value, {docstring, Doc}, Body0} ->
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
  true = code:add_path("vanillae/ebin"),
  Vanillae =
    "otpr-vanillae-" ++ lists:droplast(os:cmd("zx latest otpr-vanillae")),
  Deps = string:lexemes(os:cmd("zx list deps " ++ Vanillae), "\n"),
  ZX =
    "otpr-zx-"
    ++
    lists:nth(2, string:lexemes(lists:droplast(os:cmd("zx --version")), " ")),
  Packages = [ZX, Vanillae | Deps],
  ZompLib = filename:join(os:getenv("HOME"), "zomp/lib"),
  Converted =
    [string:join(string:lexemes(Package, "-"), "/") || Package <- Packages],
  PackagePaths =
    [filename:join([ZompLib, PackagePath, "ebin"]) || PackagePath <- Converted],
  ok = code:add_paths(PackagePaths).


convert_context(Context) ->
  lists:map(
    fun
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


send_email({ToName, To}, Subject, Body) ->
  {ok, SmtpHost} = application:get_env(damage, smtp_host),
  {ok, SmtpUser} = application:get_env(damage, smtp_user),
  {ok, SmtpHostname} = application:get_env(damage, smtp_hostname),
  {ok, SmtpPort} = application:get_env(damage, smtp_port),
  {ok, {FromName, From}} = application:get_env(damage, smtp_from),
  SmtpPassword = os:getenv("SMTP_PASSWORD"),
  %{ok, PrivKey} = file:read_file("damage.private"),
  %DKIMOptions = [
  %    {s, <<"steven">>},
  %    {d, <<"damagebdd.com">>},
  %    {private_key, {pem_plain, PrivKey}}
  %%{private_key, {pem_encrypted, EncryptedPrivKey, "password"}}
  %],
  %SignedMailBody =
  %mimemail:encode({<<"text">>, <<"plain">>,
  %              [{<<"Subject">>, Subject},
  %               {<<"From">>, FromAddress},
  %               {<<"To">>, ToAddress}],
  %              #{},
  %              list_to_binary(Body0)},
  %              [{dkim, DKIMOptions}]),
  Body1 =
    "Subject: testing\r\nFrom: {{from_name}} <{{from}}>\r\nTo: {{to_name}} <{{to}}>\r\n\r\n{{body}}",
  Body0 =
    mustache:render(
      Body1,
      convert_context(
        #{
          body => Body,
          subject => Subject,
          from => From,
          from_name => FromName,
          to => To,
          to_name => ToName
        }
      )
    ),
  Email = {From, [To], Body0},
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

encrypt(KYCInfo, Key, IV) when is_binary(KYCInfo), is_binary(Key), is_binary(IV) ->
  {CipherText, _Tag} =
    crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, KYCInfo, <<>>, true),
  CipherText.

%% Decrypt a information string

decrypt(CipherText, Key, IV)
when is_binary(CipherText), is_binary(Key), is_binary(IV) ->
  {plain_text, _Tag} =
    crypto:crypto_one_time(aes_256_gcm, Key, IV, false, CipherText, 16),
  plain_text.

%%1> c(aes_example).

%{ok,aes_example}
%2> Key = crypto:strong_rand_bytes(32).
%<<22,221,47,24,142,97,108,228,190,157,250,115,154,56,
%  84,8,248,16,132,225,56,39,35,21,254,36,251,96,145,...>>
%3> IV = crypto:strong_rand_bytes(16).
%<<187,171,222,217,173,80,211,194,152,115,61,18,85,163,
%  76,8>>
%4> KYCInfo = <<"Sensitive KYC Information">>.
%<<"Sensitive KYC Information">>
%5> CipherText = aes_example:encrypt(KYCInfo, Key, IV).
%<<56,61,118,249,53,143,60,164,118,18,9,36,101,45,22,
%  255,198,58,145,58,79,53,239,105,176,148,96,191,143,...>>
%6> PlainText = aes_example:decrypt(CipherText, Key, IV).
%<<"Sensitive KYC Information">>
test_send_email() ->
  ToEmail = {"Steven Jose", "stevenjose@gmail.com"},
  Body =
    damage_utils:load_template(
      "signup_email.mustache",
      #{btc_refund_address => <<"test">>, btc_address => <<"test address">>}
    ),
  ?debugFmt("Email body ~p", [Body]),
  damage_utils:send_email(ToEmail, <<"DamageBDD Email Test">>, Body).


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
