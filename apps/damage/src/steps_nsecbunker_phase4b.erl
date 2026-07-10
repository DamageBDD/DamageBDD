%%--------------------------------------------------------------------
%% DamageBDD steps for Phase 4B production DamageBDD node key ceremony.
%%
%% These steps exercise the production DamageBDD node key ceremony script and verify
%% that the generated report contains public identity material only.
%%--------------------------------------------------------------------
-module(steps_nsecbunker_phase4b).

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-export([step/6, step_dry/6]).

-define(NS, nsecbunker_phase4b).

-define(S_SCRIPT_EXISTS, ["the Phase 4B production key ceremony script exists"]).
-define(S_VAULT_CONFIGURED, ["the Phase 4B production vault path is configured"]).
-define(S_APPROVED, ["the Phase 4B production key ceremony is explicitly approved"]).
-define(S_RUN_CEREMONY, ["I run the Phase 4B production key ceremony"]).
-define(S_REPORT_EXISTS, ["the Phase 4B production key report MUST exist"]).
-define(S_REPORT_HEX_PUBKEY, [
    "the Phase 4B production key report MUST contain a", "64", "lowercase hex pubkey"
]).
-define(S_REPORT_HEX_PUBKEY_FLAT, [
    "the Phase 4B production key report MUST contain a 64 lowercase hex pubkey"
]).
-define(S_REPORT_NPUB, ["the Phase 4B production key report MUST contain an npub"]).
-define(S_REPORT_NO_SECRET, ["the Phase 4B production key report MUST NOT contain secret material"]).
-define(S_VAULT_EXISTS, ["the Phase 4B production vault MUST exist"]).
-define(S_VAULT_NOT_WORLD_READABLE, ["the Phase 4B production vault MUST NOT be world readable"]).

-spec step(proplists:proplist(), map(), binary() | documentation, integer(), [term()], term()) ->
    map().
-spec step_dry(proplists:proplist(), map(), binary() | documentation, integer(), [term()], term()) ->
    map().

step_dry(Config, Context, Keyword, LineNo, Body, Args) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

step(_Config, Context, _Keyword, _Line, ?S_SCRIPT_EXISTS, _Args) ->
    Script = script_path(),
    case executable_file(Script) of
        true -> put_ns(Context, (ns(Context))#{script => unicode:characters_to_binary(Script)});
        false -> error({phase4b_production_key_script_missing_or_not_executable, Script})
    end;
step(_Config, Context, _Keyword, _Line, ?S_VAULT_CONFIGURED, _Args) ->
    Root = repo_root(),
    Vault = env_or(
        "DAMAGE_NSECBUNKER_PROD_VAULT",
        filename:join([Root, ".damage-nsecbunker", "phase4b_damagebdd_node_production_bdd.vault"])
    ),
    ReportDir = env_or(
        "DAMAGE_NSECBUNKER_REPORT_DIR", filename:join([Root, "doc", "nsecbunker", "reports"])
    ),
    ok = filelib:ensure_dir(filename:join(filename:dirname(Vault), ".keep")),
    ok = filelib:ensure_dir(filename:join(ReportDir, ".keep")),
    put_ns(Context, (ns(Context))#{
        root => unicode:characters_to_binary(Root),
        vault_path => unicode:characters_to_binary(Vault),
        report_dir => unicode:characters_to_binary(ReportDir),
        json_report => unicode:characters_to_binary(
            filename:join(ReportDir, "PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.json")
        ),
        md_report => unicode:characters_to_binary(
            filename:join(ReportDir, "PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.md")
        )
    });
step(_Config, Context, _Keyword, _Line, ?S_APPROVED, _Args) ->
    put_ns(Context, (ns(Context))#{approved => true});
step(_Config, Context0, _Keyword, _Line, ?S_RUN_CEREMONY, _Args) ->
    Context = ensure_phase4b_defaults(Context0),
    Script = binary_to_list(maps:get(script, ns(Context))),
    Root = binary_to_list(maps:get(root, ns(Context))),
    Cmd = "cd " ++ shell_quote(Root) ++ " && " ++ shell_quote(Script),
    Env = phase4b_env(Context),
    Output = run_shell(Cmd, Env, 120000),
    put_ns(Context, (ns(Context))#{last_output => Output});
step(_Config, Context0, _Keyword, _Line, ?S_REPORT_EXISTS, _Args) ->
    Context = ensure_phase4b_defaults(Context0),
    Json = binary_to_list(maps:get(json_report, ns(Context))),
    Md = binary_to_list(maps:get(md_report, ns(Context))),
    case filelib:is_regular(Json) andalso filelib:is_regular(Md) of
        true -> Context;
        false -> error({phase4b_production_key_report_missing, #{json => Json, md => Md}})
    end;
step(_Config, Context0, _Keyword, _Line, ?S_REPORT_HEX_PUBKEY, _Args) ->
    assert_report_pubkey(ensure_phase4b_defaults(Context0));
step(_Config, Context0, _Keyword, _Line, ?S_REPORT_HEX_PUBKEY_FLAT, _Args) ->
    assert_report_pubkey(ensure_phase4b_defaults(Context0));
step(_Config, Context0, _Keyword, _Line, ?S_REPORT_NPUB, _Args) ->
    Context = ensure_phase4b_defaults(Context0),
    JsonMap = read_json_report(Context),
    Npub = get_report_field(<<"npub">>, npub, JsonMap),
    case is_binary(Npub) andalso is_npub(Npub) of
        true -> Context;
        false -> error({phase4b_invalid_npub, Npub})
    end;
step(_Config, Context0, _Keyword, _Line, ?S_REPORT_NO_SECRET, _Args) ->
    Context = ensure_phase4b_defaults(Context0),
    JsonMap = read_json_report(Context),
    Md = read_file(maps:get(md_report, ns(Context))),
    case secret_leak(JsonMap) of
        false -> ok;
        Leak -> error({phase4b_json_report_secret_material_leaked, Leak})
    end,
    case secret_value(Md) of
        false -> Context;
        true -> error({phase4b_markdown_report_secret_material_leaked, <<"[REDACTED]">>})
    end;
step(_Config, Context0, _Keyword, _Line, ?S_VAULT_EXISTS, _Args) ->
    Context = ensure_phase4b_defaults(Context0),
    Vault = binary_to_list(maps:get(vault_path, ns(Context))),
    case filelib:is_regular(Vault) of
        true -> Context;
        false -> error({phase4b_production_vault_missing, Vault})
    end;
step(_Config, Context0, _Keyword, _Line, ?S_VAULT_NOT_WORLD_READABLE, _Args) ->
    Context = ensure_phase4b_defaults(Context0),
    Vault = binary_to_list(maps:get(vault_path, ns(Context))),
    case file:read_file_info(Vault) of
        {ok, Info} ->
            Mode = Info#file_info.mode,
            case (Mode band 8#004) =:= 0 of
                true -> Context;
                false -> error({phase4b_production_vault_world_readable, Vault, Mode})
            end;
        {error, Reason} ->
            error({phase4b_production_vault_stat_failed, Vault, Reason})
    end.

assert_report_pubkey(Context) ->
    JsonMap = read_json_report(Context),
    Pubkey = get_report_field(<<"pubkey_hex">>, pubkey_hex, JsonMap),
    case is_binary(Pubkey) andalso is_lower_hex_64(Pubkey) of
        true -> Context;
        false -> error({phase4b_invalid_pubkey_hex, Pubkey})
    end.

ensure_phase4b_defaults(Context0) ->
    Context1 =
        case maps:is_key(script, ns(Context0)) of
            true ->
                Context0;
            false ->
                Script = script_path(),
                put_ns(Context0, (ns(Context0))#{script => unicode:characters_to_binary(Script)})
        end,
    case maps:is_key(vault_path, ns(Context1)) of
        true ->
            Context1;
        false ->
            Root = repo_root(),
            Vault = env_or(
                "DAMAGE_NSECBUNKER_PROD_VAULT",
                filename:join([
                    Root, ".damage-nsecbunker", "phase4b_damagebdd_node_production_bdd.vault"
                ])
            ),
            ReportDir = env_or(
                "DAMAGE_NSECBUNKER_REPORT_DIR",
                filename:join([Root, "doc", "nsecbunker", "reports"])
            ),
            put_ns(Context1, (ns(Context1))#{
                root => unicode:characters_to_binary(Root),
                vault_path => unicode:characters_to_binary(Vault),
                report_dir => unicode:characters_to_binary(ReportDir),
                json_report => unicode:characters_to_binary(
                    filename:join(ReportDir, "PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.json")
                ),
                md_report => unicode:characters_to_binary(
                    filename:join(ReportDir, "PHASE4B_DAMAGEBDD_NODE_PRODUCTION_KEY.md")
                )
            })
    end.

phase4b_env(Context) ->
    Root = binary_to_list(maps:get(root, ns(Context))),
    Vault = binary_to_list(maps:get(vault_path, ns(Context))),
    ReportDir = binary_to_list(maps:get(report_dir, ns(Context))),
    Passphrase = env_or("DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", "phase4b-bdd-production-passphrase"),
    Backend = env_or(
        "DAMAGE_NSECBUNKER_CRYPTO_CMD",
        default_crypto_backend(Root)
    ),
    [
        {"DAMAGE_ROOT", Root},
        {"DAMAGE_NSECBUNKER_PROD_VAULT", Vault},
        {"DAMAGE_NSECBUNKER_VAULT_PASSPHRASE", Passphrase},
        {"DAMAGE_NSECBUNKER_REPORT_DIR", ReportDir},
        {"DAMAGE_NSECBUNKER_CRYPTO_CMD", Backend},
        {"RESET_PROD_VAULT", env_or("RESET_PROD_VAULT", "")},
        {"DAMAGE_NSECBUNKER_PRODUCTION_CEREMONY_APPROVED",
            "I_UNDERSTAND_THIS_CREATES_A_PRODUCTION_DAMAGEBDD_NODE_KEY"}
    ].

run_shell(Cmd, Env, TimeoutMs) ->
    Port = open_port({spawn_executable, "/bin/sh"}, [
        binary,
        exit_status,
        stderr_to_stdout,
        {args, ["-c", Cmd]},
        {env, Env}
    ]),
    collect_port(Port, TimeoutMs, <<>>).

collect_port(Port, TimeoutMs, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, TimeoutMs, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            Acc;
        {Port, {exit_status, Status}} ->
            error({phase4b_production_key_ceremony_failed, Status, Acc})
    after TimeoutMs ->
        _ = erlang:port_close(Port),
        error({phase4b_production_key_ceremony_timeout, TimeoutMs, Acc})
    end.

read_json_report(Context) ->
    Path = maps:get(json_report, ns(Context)),
    Bin = read_file(Path),
    try jsx:decode(Bin, [return_maps]) of
        Map when is_map(Map) -> Map;
        Other -> error({phase4b_json_report_not_object, Other})
    catch
        Class:Reason -> error({phase4b_json_report_decode_failed, Class, Reason, Path})
    end.

read_file(Path0) when is_binary(Path0) ->
    read_file(binary_to_list(Path0));
read_file(Path) when is_list(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, Reason} -> error({phase4b_report_read_failed, Path, Reason})
    end.

get_report_field(BinKey, AtomKey, Map) when is_map(Map) ->
    case maps:get(BinKey, Map, maps:get(AtomKey, Map, undefined)) of
        undefined -> error({phase4b_report_missing_field, BinKey, Map});
        Value when is_list(Value) -> unicode:characters_to_binary(Value);
        Value -> Value
    end.

script_path() ->
    case configured_script_path() of
        undefined -> default_script_path();
        Path -> abs_script_path(Path)
    end.

configured_script_path() ->
    case application:get_env(damage, nsecbunker) of
        {ok, Config} ->
            first_defined([
                config_get(phase4b_production_key_script, Config),
                config_get(production_key_script, Config),
                config_get(key_ceremony_script, Config),
                config_get(ceremony_script_path, Config)
            ]);
        undefined ->
            undefined
    end.

config_get(Key, Config) when is_map(Config) ->
    maps:get(Key, Config, maps:get(atom_to_binary(Key, utf8), Config, undefined));
config_get(Key, Config) when is_list(Config) ->
    case proplists:get_value(Key, Config, undefined) of
        undefined -> proplists:get_value(atom_to_list(Key), Config, undefined);
        Value -> Value
    end;
config_get(_Key, _Config) ->
    undefined.

first_defined([]) ->
    undefined;
first_defined([undefined | Rest]) ->
    first_defined(Rest);
first_defined([false | Rest]) ->
    first_defined(Rest);
first_defined([<<>> | Rest]) ->
    first_defined(Rest);
first_defined([[] | Rest]) ->
    first_defined(Rest);
first_defined([Value | _Rest]) ->
    Value.

default_script_path() ->
    Root = repo_root(),
    filename:absname(
        filename:join([Root, "scripts", "nsecbunker", "phase4b_create_production_damagebdd_node_key.sh"])
    ).

default_crypto_backend(Root) ->
    ReleaseBackend = "/opt/damage/bin/damage-nsecbunker-crypto-c",
    case executable_file(ReleaseBackend) of
        true ->
            ReleaseBackend;
        false ->
            filename:join([
                Root, "priv", "crypto", "damage-nsecbunker-crypto-c", "damage-nsecbunker-crypto-c"
            ])
    end.

abs_script_path(Path0) when is_binary(Path0) ->
    abs_script_path(binary_to_list(Path0));
abs_script_path(Path0) when is_atom(Path0) ->
    abs_script_path(atom_to_list(Path0));
abs_script_path(Path0) when is_list(Path0) ->
    Path = filename:flatten(Path0),
    case filename:pathtype(Path) of
        absolute -> filename:absname(Path);
        _ -> filename:absname(filename:join(repo_root(), Path))
    end.
repo_root() ->
    case os:getenv("DAMAGE_ROOT") of
        false ->
            {ok, Cwd} = file:get_cwd(),
            Cwd;
        Root ->
            Root
    end.

env_or(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Value -> Value
    end.

executable_file(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} ->
            Mode = Info#file_info.mode,
            (Mode band 8#111) =/= 0;
        _ ->
            false
    end.

is_lower_hex_64(Bin) ->
    case re:run(Bin, <<"^[0-9a-f]{64}$">>, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.

is_npub(Bin) ->
    case re:run(Bin, <<"^npub1[02-9ac-hj-np-z]+$">>, [caseless, {capture, none}]) of
        match -> true;
        nomatch -> false
    end.

shell_quote(Str) when is_list(Str) ->
    "'" ++ lists:flatten([quote_char(C) || C <- Str]) ++ "'";
shell_quote(Bin) when is_binary(Bin) ->
    shell_quote(binary_to_list(Bin)).

quote_char($') -> "'\\''";
quote_char(C) -> [C].

ns(Context) -> maps:get(?NS, Context, #{}).
put_ns(Context, NS) -> maps:put(?NS, NS, Context).

secret_leak(Term) -> secret_leak(Term, []).

secret_leak(Map, Path) when is_map(Map) ->
    secret_leak_pairs(maps:to_list(Map), Path);
secret_leak(List, Path) when is_list(List) ->
    secret_leak_list(List, Path, 0);
secret_leak(Bin, Path) when is_binary(Bin) ->
    case secret_value(Bin) of
        true -> {secret_value, lists:reverse(Path), <<"[REDACTED]">>};
        false -> false
    end;
secret_leak(_Other, _Path) ->
    false.

secret_leak_pairs([], _Path) ->
    false;
secret_leak_pairs([{K, V} | Rest], Path) ->
    case secret_key_name(K) of
        true ->
            {secret_key, lists:reverse([K | Path]), <<"[REDACTED]">>};
        false ->
            case secret_leak(V, [K | Path]) of
                false -> secret_leak_pairs(Rest, Path);
                Leak -> Leak
            end
    end.

secret_leak_list([], _Path, _N) ->
    false;
secret_leak_list([H | T], Path, N) ->
    case secret_leak(H, [N | Path]) of
        false -> secret_leak_list(T, Path, N + 1);
        Leak -> Leak
    end.

secret_key_name(K) ->
    lists:member(key_bin(K), [
        <<"nsec">>,
        <<"private_key">>,
        <<"private_key_hex">>,
        <<"privkey">>,
        <<"privkey_hex">>,
        <<"secret_key">>,
        <<"secret_key_hex">>,
        <<"mnemonic">>,
        <<"seed">>,
        <<"seed_hex">>,
        <<"sk">>
    ]).

secret_value(Bin) ->
    Patterns = <<"(nsec1[02-9ac-hj-np-z]+|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----)">>,
    case re:run(Bin, Patterns, [caseless, {capture, none}]) of
        match -> true;
        nomatch -> false
    end.

key_bin(K) when is_binary(K) ->
    list_to_binary(string:lowercase(binary_to_list(K)));
key_bin(K) when is_atom(K) ->
    key_bin(atom_to_binary(K, utf8));
key_bin(K) when is_integer(K) ->
    integer_to_binary(K);
key_bin(K) ->
    key_bin(unicode:characters_to_binary(io_lib:format("~p", [K]))).
