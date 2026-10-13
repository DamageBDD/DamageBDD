%%--------------------------------------------------------------------
%% Persistent packet-4 transport for the production C custody backend.
%% The vault path is bound during INIT and every operation is correlated by
%% a 16-byte request id. Timeout or caller death closes the port.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_port).

-behaviour(damage_nsecbunker_backend).
-include_lib("kernel/include/file.hrl").

-export([open/1, unlock/3, call/4, status/1, close/1]).

-define(INIT_REQUEST, 0).
-define(UNLOCK_REQUEST, 1).
-define(OP_REQUEST, 2).
-define(INIT_RESPONSE, 16#80).
-define(UNLOCK_RESPONSE, 16#81).
-define(OP_RESPONSE, 16#82).
-define(REQUEST_ID_BYTES, 16).
-define(MAX_SECRET_BYTES, 65536).
-define(MAX_FRAME_BYTES, 4 * 1024 * 1024).

-spec open(term()) -> {ok, port()} | {error, term()}.
open(Config0) ->
    Config = damage_nsecbunker_config:normalize(Config0),
    Cmd = to_list(maps:get(crypto_backend_cmd, Config, undefined)),
    VaultPath = to_binary(maps:get(vault_path, Config, undefined)),
    VaultMode = normalize_vault_mode(maps:get(vault_mode, Config, open_existing)),
    Timeout = positive_integer(maps:get(crypto_init_timeout_ms, Config, 5000), 5000),
    case
        {
            valid_executable_path(Cmd),
            valid_vault_path(VaultPath),
            VaultMode,
            damage_nsecbunker_config:production(Config)
        }
    of
        {true, true, Mode, true} when
            Mode =:= open_existing; Mode =:= create_if_missing
        ->
            open_initialized_port(Cmd, VaultPath, Mode, Timeout);
        {false, _, _, _} ->
            {error, invalid_crypto_backend_executable};
        {_, false, _, _} ->
            {error, invalid_vault_path};
        {_, _, invalid, _} ->
            {error, invalid_vault_mode};
        {_, _, _, false} ->
            {error, persistent_backend_requires_production_mode}
    end.

open_initialized_port(Cmd, VaultPath, VaultMode, Timeout) ->
    Options = [
        binary,
        use_stdio,
        exit_status,
        {packet, 4},
        {args, ["--framed"]},
        {env, scrub_child_environment()}
    ],
    try open_port({spawn_executable, Cmd}, Options) of
        Port when is_port(Port) ->
            Init = #{
                <<"protocol">> => <<"damage-nsecbunker-port-v2">>,
                <<"vault_path">> => VaultPath,
                <<"vault_mode">> => atom_to_binary(VaultMode, utf8),
                <<"production">> => true
            },
            case send_init(Port, Init, Timeout) of
                ok ->
                    {ok, Port};
                {error, _} = Error ->
                    close(Port),
                    Error
            end
    catch
        Class:Reason ->
            {error, {crypto_backend_open_failed, Class, safe_reason(Reason)}}
    end.

-spec unlock(port(), binary(), timeout()) -> {ok, map()} | {error, term()}.
unlock(Port, Passphrase, Timeout) when
    is_port(Port),
    is_binary(Passphrase),
    byte_size(Passphrase) > 0,
    byte_size(Passphrase) =< ?MAX_SECRET_BYTES
->
    case roundtrip(Port, <<?UNLOCK_REQUEST, Passphrase/binary>>, Timeout) of
        {ok, <<?UNLOCK_RESPONSE, 0>>} ->
            {ok, #{}};
        {ok, <<?UNLOCK_RESPONSE, 0, Metadata/binary>>} ->
            decode_object(Metadata);
        {ok, <<?UNLOCK_RESPONSE, 1, Code/binary>>} ->
            {error, {vault_unlock_failed, safe_code(Code)}};
        {ok, _} ->
            close(Port),
            {error, invalid_unlock_response};
        {error, _} = Error ->
            Error
    end;
unlock(_, _, _) ->
    {error, invalid_vault_passphrase}.

-spec call(port(), map(), timeout(), pid()) -> {ok, map()} | {error, term()}.
call(Port, Payload, Timeout, CallerPid) when
    is_port(Port), is_map(Payload), is_pid(CallerPid)
->
    case forbidden_payload_key(Payload) of
        none -> encode_and_call(Port, Payload, Timeout, CallerPid);
        Key -> {error, {forbidden_crypto_backend_payload_key, Key}}
    end;
call(_, _, _, _) ->
    {error, invalid_crypto_backend_call}.

encode_and_call(Port, Payload, Timeout, CallerPid) ->
    try iolist_to_binary(jsx:encode(Payload)) of
        Json when byte_size(Json) =< ?MAX_FRAME_BYTES ->
            RequestId = crypto:strong_rand_bytes(?REQUEST_ID_BYTES),
            Frame = <<?OP_REQUEST, RequestId/binary, Json/binary>>,
            case roundtrip_with_caller(Port, Frame, Timeout, CallerPid) of
                {ok, <<?OP_RESPONSE, 0, ReplyId:?REQUEST_ID_BYTES/binary, Response/binary>>} when
                    ReplyId =:= RequestId,
                    byte_size(Response) =< ?MAX_FRAME_BYTES
                ->
                    decode_operation_response(Port, Response);
                {ok, <<?OP_RESPONSE, 1, ReplyId:?REQUEST_ID_BYTES/binary, Code/binary>>} when
                    ReplyId =:= RequestId
                ->
                    {error, {crypto_backend_rejected_operation, safe_code(Code)}};
                {ok, <<?OP_RESPONSE, _Status, _ReplyId:?REQUEST_ID_BYTES/binary, _/binary>>} ->
                    close(Port),
                    {error, crypto_backend_request_id_mismatch};
                {ok, _} ->
                    close(Port),
                    {error, invalid_crypto_backend_response};
                {error, _} = Error ->
                    Error
            end
    catch
        _:_ -> {error, invalid_crypto_backend_payload}
    end.

-spec status(port()) -> map().
status(Port) when is_port(Port) ->
    case erlang:port_info(Port, connected) of
        {connected, _} -> #{connected => true, protocol => framed_stdio_v2};
        undefined -> #{connected => false, protocol => framed_stdio_v2}
    end;
status(_) ->
    #{connected => false, protocol => framed_stdio_v2}.

-spec close(term()) -> ok.
close(Port) when is_port(Port) ->
    try erlang:port_close(Port) of
        _ -> ok
    catch
        _:_ -> ok
    end;
close(_) ->
    ok.

send_init(Port, Init, Timeout) ->
    try iolist_to_binary(jsx:encode(Init)) of
        Json ->
            case roundtrip(Port, <<?INIT_REQUEST, Json/binary>>, Timeout) of
                {ok, <<?INIT_RESPONSE, 0>>} ->
                    ok;
                {ok, <<?INIT_RESPONSE, 1, Code/binary>>} ->
                    {error, {crypto_backend_init_failed, safe_code(Code)}};
                {ok, _} ->
                    {error, invalid_crypto_backend_init_response};
                {error, _} = Error ->
                    Error
            end
    catch
        _:_ -> {error, invalid_crypto_backend_init_payload}
    end.

roundtrip(Port, Frame, Timeout) ->
    case erlang:port_command(Port, Frame) of
        true ->
            receive
                {Port, {data, Reply}} when is_binary(Reply) -> {ok, Reply};
                {Port, {exit_status, Status}} -> {error, {crypto_backend_exit, Status}};
                {'EXIT', Port, Reason} -> {error, {crypto_backend_exit, safe_reason(Reason)}}
            after normalize_timeout(Timeout) ->
                close(Port),
                {error, crypto_backend_timeout}
            end;
        false ->
            close(Port),
            {error, crypto_backend_closed}
    end.

roundtrip_with_caller(Port, Frame, Timeout, CallerPid) ->
    MonitorRef = erlang:monitor(process, CallerPid),
    Result =
        case erlang:port_command(Port, Frame) of
            true ->
                receive
                    {Port, {data, Reply}} when is_binary(Reply) -> {ok, Reply};
                    {Port, {exit_status, Status}} ->
                        {error, {crypto_backend_exit, Status}};
                    {'EXIT', Port, Reason} ->
                        {error, {crypto_backend_exit, safe_reason(Reason)}};
                    {'DOWN', MonitorRef, process, CallerPid, _Reason} ->
                        close(Port),
                        {error, crypto_backend_caller_gone}
                after normalize_timeout(Timeout) ->
                    close(Port),
                    {error, crypto_backend_timeout}
                end;
            false ->
                close(Port),
                {error, crypto_backend_closed}
        end,
    erlang:demonitor(MonitorRef, [flush]),
    Result.

decode_operation_response(Port, Response) ->
    case decode_backend_envelope(Response) of
        {error, crypto_backend_bad_envelope} = Error ->
            close(Port),
            Error;
        {error, crypto_backend_response_not_object} = Error ->
            close(Port),
            Error;
        {error, crypto_backend_invalid_json} = Error ->
            close(Port),
            Error;
        Result ->
            Result
    end.

decode_backend_envelope(Json) ->
    case decode_object(Json) of
        {ok, #{<<"ok">> := true, <<"result">> := Result}} when is_map(Result) ->
            {ok, Result};
        {ok, #{<<"ok">> := true, <<"result">> := Result}} ->
            {ok, #{<<"value">> => Result}};
        {ok, #{<<"ok">> := false, <<"error">> := Error}} ->
            {error, {crypto_backend_not_ok, safe_error_value(Error)}};
        {ok, _} ->
            {error, crypto_backend_bad_envelope};
        {error, _} = Error ->
            Error
    end.

decode_object(<<>>) ->
    {ok, #{}};
decode_object(Json) ->
    try jsx:decode(Json, [return_maps]) of
        Value when is_map(Value) -> {ok, Value};
        _ -> {error, crypto_backend_response_not_object}
    catch
        _:_ -> {error, crypto_backend_invalid_json}
    end.

forbidden_payload_key(Payload) ->
    Forbidden = [
        vault_path,
        <<"vault_path">>,
        passphrase,
        <<"passphrase">>,
        vault_passphrase,
        <<"vault_passphrase">>,
        secret_value,
        <<"secret_value">>
    ],
    case [Key || Key <- Forbidden, maps:is_key(Key, Payload)] of
        [Key | _] -> Key;
        [] -> none
    end.

valid_executable_path(Path) when is_list(Path), Path =/= [] ->
    case {filename:pathtype(Path), file:read_file_info(Path)} of
        {absolute, {ok, #file_info{type = regular, mode = Mode}}} ->
            (Mode band 8#111) =/= 0;
        _ ->
            false
    end;
valid_executable_path(_) ->
    false.

valid_vault_path(Path) when is_binary(Path), byte_size(Path) > 0 ->
    filename:pathtype(binary_to_list(Path)) =:= absolute;
valid_vault_path(_) ->
    false.

normalize_vault_mode(open_existing) -> open_existing;
normalize_vault_mode(create_if_missing) -> create_if_missing;
normalize_vault_mode(<<"open_existing">>) -> open_existing;
normalize_vault_mode(<<"create_if_missing">>) -> create_if_missing;
normalize_vault_mode("open_existing") -> open_existing;
normalize_vault_mode("create_if_missing") -> create_if_missing;
normalize_vault_mode(_) -> invalid.

scrub_child_environment() ->
    [
        {Name, false}
     || Name <- [
            "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE",
            "DAMAGE_NSECBUNKER_VAULT_PATH",
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_SESSION_TOKEN",
            "AWS_SECURITY_TOKEN",
            "AWS_PROFILE",
            "AWS_DEFAULT_PROFILE",
            "AWS_SHARED_CREDENTIALS_FILE",
            "AWS_CONFIG_FILE",
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
            "AWS_CONTAINER_CREDENTIALS_FULL_URI",
            "AWS_WEB_IDENTITY_TOKEN_FILE",
            "AWS_ROLE_ARN",
            "AWS_EC2_METADATA_SERVICE_ENDPOINT",
            "AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE",
            "AWS_EC2_METADATA_DISABLED"
        ]
    ].

safe_code(Code) when is_binary(Code), byte_size(Code) =< 128 ->
    case is_safe_code(Code) of
        true -> Code;
        false -> backend_error
    end;
safe_code(_) ->
    backend_error.

safe_error_value(Value) when is_binary(Value) -> safe_code(Value);
safe_error_value(Value) when is_atom(Value) -> Value;
safe_error_value(_) -> backend_error.

is_safe_code(<<>>) ->
    true;
is_safe_code(<<C, Rest/binary>>) when
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $_ orelse C =:= $- orelse C =:= $.
->
    is_safe_code(Rest);
is_safe_code(_) ->
    false.

positive_integer(Value, _) when is_integer(Value), Value > 0 -> Value;
positive_integer(_, Default) -> Default.
normalize_timeout(infinity) -> infinity;
normalize_timeout(Value) when is_integer(Value), Value > 0 -> Value;
normalize_timeout(_) -> 10000.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(_) -> <<>>.
to_list(Value) when is_list(Value) -> Value;
to_list(Value) when is_binary(Value) -> binary_to_list(Value);
to_list(_) -> undefined.

safe_reason(Reason) when is_atom(Reason) -> Reason;
safe_reason(_) -> backend_failure.
