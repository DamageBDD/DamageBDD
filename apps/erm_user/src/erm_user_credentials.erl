%% Credential material stays in a private user-owned file. The printed digest
%% is safe to transfer to the Damage administrator; the bearer never is.
-module(erm_user_credentials).
-include_lib("kernel/include/file.hrl").
-export([create/0, create/1, main/0]).
main() ->
    application:ensure_all_started(crypto),
    case create() of
        {ok, Digest} -> io:format("~s~n", [Digest]), halt(0);
        {error, Reason} -> io:format(standard_error, "Credential setup failed: ~p~n", [Reason]), halt(1)
    end.
create() -> create(erm_user_config:token_file()).
create(Path) ->
    case filename:pathtype(Path) of
        absolute -> create_absolute(Path);
        _ -> {error, relative_credential_path}
    end.
create_absolute(Path) ->
    Dir = filename:dirname(Path),
    case erm_user_config:private_directory(Dir) of
        ok ->
            case private_parent(Dir) of
                ok -> credential_in_private_parent(Path);
                Error -> Error
            end;
        _ -> {error, credential_directory_unavailable}
    end.
private_parent(Dir) ->
    case file:read_link_info(Dir) of
        {ok, #file_info{type = directory, uid = Owner}} ->
            case Owner =:= erm_user_config:uid() of
                true -> file:change_mode(Dir, 8#700);
                false -> {error, unsafe_credential_directory}
            end;
        _ -> {error, unsafe_credential_directory}
    end.
credential_in_private_parent(Path) ->
            case erm_user_config:trusted_file(Path, token) of
                ok -> digest_existing(Path);
                _ -> exclusive_create(Path)
            end.
exclusive_create(Path) ->
    %% chmod before writing prevents a permissive login umask from exposing
    %% credential bytes, even briefly. exclusive refuses existing symlinks.
    case file:open(Path, [write, exclusive, raw, binary]) of
        {ok, F} ->
            try
                ok = file:change_mode(Path, 8#600),
                Token = hex(crypto:strong_rand_bytes(32)),
                ok = file:write(F, <<Token/binary, "\n">>),
                ok = file:sync(F),
                {ok, hex(crypto:hash(sha256, Token))}
            catch _:_ -> {error, credential_creation_failed}
            after file:close(F) end;
        {error, eexist} -> {error, existing_credential_not_private};
        _ -> {error, credential_creation_failed}
    end.
digest_existing(Path) ->
    case erm_user_config:read_token(Path) of
        {ok, Token} -> {ok, hex(crypto:hash(sha256, Token))};
        Error -> Error
    end.
hex(B) -> list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [X]) || <<X>> <= B])).
