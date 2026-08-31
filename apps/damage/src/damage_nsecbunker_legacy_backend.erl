%%--------------------------------------------------------------------
%% Shared one-shot backend for the local/default secret provider.
%%
%% This module is the only owner of the historical local transport:
%%  * resolve the local passphrase;
%%  * construct the child environment;
%%  * open the one-shot C port;
%%  * enforce the operation timeout;
%%  * decode the backend response envelope.
%%
%% The AWS-managed path never calls this module.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_legacy_backend).

-include_lib("kernel/include/file.hrl").

-export([
    call/3,
    call_field/4,
    status/1
]).

-define(DEFAULT_TIMEOUT, 10000).

-spec call(map() | proplists:proplist(), map(), timeout()) ->
    {ok, term()} | {error, term()}.
call(Config0, Payload, Timeout0) when is_map(Payload) ->
    Config = damage_nsecbunker_config:normalize(Config0),
    Timeout = normalize_timeout(Timeout0, Config),
    case damage_nsecbunker_config:secret_provider(Config) of
        local ->
            call_local(Config, Payload, Timeout);
        Other ->
            {error, {
                local_backend_provider_mismatch,
                Other
            }}
    end;
call(_Config, _Payload, _Timeout) ->
    {error, invalid_crypto_backend_payload}.

-spec call_field(
    map() | proplists:proplist(),
    map(),
    atom() | binary(),
    timeout()
) -> {ok, term()} | {error, term()}.
call_field(Config, Payload, Field, Timeout) ->
    case call(Config, Payload, Timeout) of
        {ok, Result} when is_map(Result) ->
            case get_field(Field, Result) of
                undefined ->
                    {error, {
                        missing_backend_response_field,
                        Field
                    }};
                Value ->
                    {ok, Value}
            end;
        {ok, Other} ->
            {error, {
                bad_backend_response,
                Other
            }};
        {error, _} = Error ->
            Error
    end.

-spec status(map() | proplists:proplist()) -> map().
status(Config0) ->
    Config = damage_nsecbunker_config:normalize(Config0),
    case executable(Config) of
        {ok, Command} ->
            #{
                configured => true,
                executable => true,
                mode => local_secret,
                cmd => Command
            };
        {error, Reason} ->
            #{
                configured => false,
                executable => false,
                mode => local_secret,
                reason => Reason
            }
    end.

call_local(Config, Payload, Timeout) ->
    case executable(Config) of
        {ok, Command} ->
            case backend_environment(Config, Payload) of
                {ok, Environment} ->
                    call_port(
                        Command,
                        Payload,
                        Environment,
                        Timeout
                    );
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

backend_environment(Config, Payload) ->
    Base = dedupe_env(
        extra_backend_env(Config) ++ passthrough_env()
    ),
    case payload_vault_path(Payload) of
        undefined ->
            {ok, Base};
        Path ->
            case resolve_passphrase(Config) of
                {ok, Passphrase} ->
                    {ok,
                        dedupe_env([
                            {
                                "DAMAGE_NSECBUNKER_VAULT_PATH",
                                str(Path)
                            },
                            {
                                "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE",
                                str(Passphrase)
                            }
                            | Base
                        ])};
                {error, _} = Error ->
                    Error
            end
    end.

resolve_passphrase(Config) ->
    case
        maps:get(
            resolved_vault_passphrase,
            Config,
            undefined
        )
    of
        undefined ->
            damage_nsecbunker_local_secret_provider:fetch(Config);
        Passphrase ->
            normalize_passphrase(Passphrase)
    end.

normalize_passphrase(Passphrase) when
    is_binary(Passphrase),
    byte_size(Passphrase) > 0
->
    {ok, Passphrase};
normalize_passphrase(Passphrase) when
    is_list(Passphrase),
    Passphrase =/= []
->
    try unicode:characters_to_binary(Passphrase) of
        Binary when
            is_binary(Binary),
            byte_size(Binary) > 0
        ->
            {ok, Binary};
        _ ->
            {error, empty_local_vault_passphrase}
    catch
        _:_ ->
            {error, invalid_local_vault_passphrase}
    end;
normalize_passphrase(_) ->
    {error, empty_local_vault_passphrase}.

call_port(Command, Payload, Environment, Timeout) ->
    Options = [
        binary,
        use_stdio,
        exit_status,
        stderr_to_stdout,
        eof,
        {env, Environment}
    ],
    try open_port({spawn_executable, Command}, Options) of
        Port ->
            try
                Json = jsx:encode(Payload),
                true = port_command(
                    Port,
                    <<Json/binary, "\n">>
                ),
                collect_port(
                    Port,
                    Timeout,
                    <<>>
                )
            catch
                Class:Reason ->
                    {error, {
                        crypto_backend_call_failed,
                        safe_exception(Class, Reason)
                    }}
            after
                safe_port_close(Port)
            end
    catch
        Class:Reason ->
            {error, {
                crypto_backend_open_failed,
                Class,
                safe_exception(Class, Reason)
            }}
    end.

collect_port(Port, Timeout, Acc) ->
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            collect_port(
                Port,
                Timeout,
                <<Acc/binary, Data/binary>>
            );
        {Port, eof} ->
            collect_port(Port, Timeout, Acc);
        {Port, {exit_status, 0}} ->
            decode_backend_response(Acc);
        {Port, {exit_status, Status}} ->
            {error, {
                crypto_backend_exit,
                Status,
                Acc
            }}
    after Timeout ->
        {error, crypto_backend_timeout}
    end.

decode_backend_response(Data0) ->
    Data = last_nonempty_line(Data0),
    try jsx:decode(Data, [return_maps]) of
        #{<<"ok">> := true, <<"result">> := Result} ->
            {ok, normalize_backend(Result)};
        #{<<"ok">> := false, <<"error">> := Error} ->
            {error, {
                crypto_backend_rejected,
                sanitize_backend_error(Error)
            }};
        #{ok := true, result := Result} ->
            {ok, normalize_backend(Result)};
        #{ok := false, error := Error} ->
            {error, {
                crypto_backend_rejected,
                sanitize_backend_error(Error)
            }};
        Map when is_map(Map) ->
            {ok, normalize_backend(Map)};
        _ ->
            {error, crypto_backend_bad_envelope}
    catch
        _:_ ->
            {error, invalid_crypto_backend_json}
    end.

last_nonempty_line(Data) ->
    Lines = binary:split(
        Data,
        <<"\n">>,
        [global]
    ),
    Nonempty = [
        Trimmed
     || Line <- Lines,
        Trimmed <- [trim(Line)],
        Trimmed =/= <<>>
    ],
    case lists:reverse(Nonempty) of
        [Last | _] ->
            Last;
        [] ->
            <<>>
    end.

trim(Binary) ->
    unicode:characters_to_binary(
        string:trim(binary_to_list(Binary))
    ).

payload_vault_path(Payload) ->
    case maps:get(<<"vault_path">>, Payload, undefined) of
        undefined ->
            maps:get(vault_path, Payload, undefined);
        Path ->
            Path
    end.

executable(Config) ->
    Command0 = first_defined(
        [crypto_backend_cmd, crypto_port_cmd],
        Config,
        undefined
    ),
    Command = path_string(Command0),
    case Command of
        "" ->
            {error, crypto_backend_not_configured};
        _ ->
            case file:read_file_info(Command) of
                {ok, #file_info{
                    type = regular,
                    mode = Mode
                }} when Mode band 8#111 =/= 0 ->
                    {ok, Command};
                {ok, #file_info{type = regular}} ->
                    {error, {
                        crypto_backend_not_executable,
                        Command
                    }};
                {ok, _} ->
                    {error, {
                        crypto_backend_not_regular_file,
                        Command
                    }};
                {error, Reason} ->
                    {error, {
                        crypto_backend_unavailable,
                        Command,
                        Reason
                    }}
            end
    end.

extra_backend_env(Config) ->
    Env0 = maps:get(
        backend_env,
        Config,
        maps:get(env, Config, [])
    ),
    [
        {Name, Value}
     || {Name, Value} <- Env0,
        not sensitive_backend_env(Name)
    ].

sensitive_backend_env(Name0) ->
    Name = env_name(Name0),
    lists:member(
        Name,
        [
            "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE",
            "DAMAGE_NSECBUNKER_VAULT_PATH"
        ]
    ).

passthrough_env() ->
    passthrough_env([
        "DAMAGE_NSECBUNKER_PRODUCTION",
        "DAMAGE_NSECBUNKER_TEST_MODE",
        "DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44"
    ]).

passthrough_env(Names) ->
    lists:foldl(
        fun(Name, Acc) ->
            case os:getenv(Name) of
                false ->
                    Acc;
                Value ->
                    [{Name, Value} | Acc]
            end
        end,
        [],
        Names
    ).

dedupe_env(Environment) ->
    maps:to_list(
        maps:from_list([
            {env_name(Name), Value}
         || {Name, Value} <- Environment
        ])
    ).

safe_port_close(Port) when is_port(Port) ->
    try erlang:port_close(Port) of
        _ ->
            ok
    catch
        _:_ ->
            ok
    end;
safe_port_close(_) ->
    ok.

normalize_timeout(infinity, _Config) ->
    infinity;
normalize_timeout(Timeout, _Config) when
    is_integer(Timeout),
    Timeout > 0
->
    Timeout;
normalize_timeout(_, Config) ->
    case
        maps:get(
            crypto_timeout_ms,
            Config,
            ?DEFAULT_TIMEOUT
        )
    of
        Value when is_integer(Value), Value > 0 ->
            Value;
        _ ->
            ?DEFAULT_TIMEOUT
    end.

sanitize_backend_error(Error) when
    is_atom(Error);
    is_binary(Error)
->
    Error;
sanitize_backend_error(#{<<"code">> := Code}) ->
    Code;
sanitize_backend_error(#{code := Code}) ->
    Code;
sanitize_backend_error(_) ->
    backend_operation_failed.

normalize_backend(Map) when is_map(Map) ->
    maps:from_list([
        {
            normalize_key(Key),
            normalize_backend(Value)
        }
     || {Key, Value} <- maps:to_list(Map)
    ]);
normalize_backend(List) when is_list(List) ->
    [normalize_backend(Value) || Value <- List];
normalize_backend(Other) ->
    Other.

normalize_key(Key) when is_binary(Key) ->
    try binary_to_existing_atom(Key, utf8) of
        Atom ->
            Atom
    catch
        _:_ ->
            Key
    end;
normalize_key(Key) ->
    Key.

get_field(Field, Map) ->
    case maps:get(Field, Map, undefined) of
        undefined when is_atom(Field) ->
            maps:get(
                atom_to_binary(Field, utf8),
                Map,
                undefined
            );
        undefined when is_binary(Field) ->
            try
                maps:get(
                    binary_to_existing_atom(Field, utf8),
                    Map,
                    undefined
                )
            catch
                _:_ ->
                    undefined
            end;
        Value ->
            Value
    end.

first_defined([], _Map, Default) ->
    Default;
first_defined([Key | Rest], Map, Default) ->
    case maps:get(Key, Map, undefined) of
        undefined ->
            first_defined(Rest, Map, Default);
        Value ->
            Value
    end.

path_string(Value) when is_binary(Value) ->
    binary_to_list(Value);
path_string(Value) when is_list(Value) ->
    Value;
path_string(_) ->
    "".

env_name(Name) when is_binary(Name) ->
    binary_to_list(Name);
env_name(Name) when is_atom(Name) ->
    atom_to_list(Name);
env_name(Name) when is_list(Name) ->
    Name.

str(Value) when is_binary(Value) ->
    binary_to_list(Value);
str(Value) when is_list(Value) ->
    Value;
str(Value) when is_atom(Value) ->
    atom_to_list(Value);
str(Value) when is_integer(Value) ->
    integer_to_list(Value);
str(Value) ->
    lists:flatten(io_lib:format("~p", [Value])).

safe_exception(_Class, Reason) when is_atom(Reason) ->
    Reason;
safe_exception(Class, _Reason) ->
    Class.
