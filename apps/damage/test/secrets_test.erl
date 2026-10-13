%% The legacy SQLite example did not exercise the current secrets module.
%% Use the real encryption and DETS primitives in a disposable, isolated VM.
-module(secrets_test).
-include_lib("eunit/include/eunit.hrl").

%% Called only through peer:call/5; this module is built in the test directory.
-export([storage_checks/1, authentication_checks/0]).

secrets_storage_test_() ->
    {timeout, 45,
        {setup, fun setup/0, fun teardown/1, fun({Peer, Dir}) ->
            Path = filename:join(Dir, "secrets.dets"),
            {inorder, [
                {"encrypted DETS storage, reopen, and deletion",
                    {timeout, 15, fun() ->
                        ?assertEqual(
                            ok,
                            peer:call(
                                Peer, ?MODULE, storage_checks, [Path], 10000
                            )
                        )
                    end}},
                {"wrong keys and tampered envelopes are rejected",
                    {timeout, 15, fun() ->
                        ?assertEqual(
                            ok,
                            peer:call(
                                Peer, ?MODULE, authentication_checks, [], 10000
                            )
                        )
                    end}}
            ]}
        end}}.

setup() ->
    {ok, _} = application:ensure_all_started(crypto),
    Dir = temp_dir(16),
    try
        %% standard_io does not require distribution or an epmd listener.
        %% Do not pass a node name, boot configuration, or node credentials.
        {ok, Peer, _Node} = peer:start_link(#{
            connection => standard_io,
            args => ["+S", "2:2"],
            env => [
                {"DAMAGE_SECRET_KEY", ""},
                {"ERL_FLAGS", ""},
                {"ERL_AFLAGS", ""},
                {"ERL_ZFLAGS", ""}
            ],
            wait_boot => 15000
        }),
        try
            %% Rebar's code path can include archive/temporary entries that
            %% are not directories in a fresh peer. Keep its own OTP paths and
            %% add only the two project modules used by these primitive tests.
            ok = add_peer_module_path(Peer, secrets),
            ok = add_peer_module_path(Peer, ?MODULE),
            ok = peer:call(Peer, file, set_cwd, [Dir]),
            {ok, _} = peer:call(Peer, application, ensure_all_started, [crypto]),
            ok = peer:call(Peer, application, set_env, [
                damage, secrets_dets_file, filename:join(Dir, "secrets.dets")
            ]),
            {Peer, Dir}
        catch
            Class:Reason:Stack ->
                _ = peer:stop(Peer),
                erlang:raise(Class, Reason, Stack)
        end
    catch
        Class0:Reason0:Stack0 ->
            _ = clean_dir(Dir),
            erlang:raise(Class0, Reason0, Stack0)
    end.

%% Fail explicitly for a required module instead of copying or silently
%% filtering Rebar's entire path. No application or secrets server is started.
add_peer_module_path(Peer, Module) ->
    case code:which(Module) of
        Beam0 when is_list(Beam0) ->
            Beam = filename:absname(Beam0),
            case filelib:is_regular(Beam) of
                true ->
                    Dir = filename:dirname(Beam),
                    case peer:call(Peer, code, add_patha, [Dir]) of
                        true ->
                            case peer:call(Peer, code, ensure_loaded, [Module]) of
                                {module, Module} -> ok;
                                {error, Why} -> erlang:error({test_peer_module_load, Module, Why})
                            end;
                        {error, Why} ->
                            erlang:error({test_peer_code_path, Module, Dir, Why})
                    end;
                false ->
                    erlang:error({test_module_beam_not_file, Module, Beam})
            end;
        Location ->
            erlang:error({test_module_beam_unavailable, Module, Location})
    end.

teardown({Peer, Dir}) ->
    %% Stop the VM (and any remaining DETS owners) before deleting its file.
    try
        peer:stop(Peer)
    after
        ok = clean_dir(Dir)
    end.

storage_checks(Path) ->
    ?assertEqual(Path, secrets:secrets_dets_path()),
    %% These primitives derive a symmetric key from private key bytes; no
    %% signing identity or running secrets gen_server is required here.
    Key = crypto:strong_rand_bytes(64),
    Plain = <<"disposable secrets storage fixture">>,
    Name = <<"secrets-test-record">>,
    Envelope = secrets:encrypt_secret(Plain, Key),
    try
        ?assertEqual([], secrets:retrieve_secret(Name)),
        ?assertEqual(ok, secrets:store_secret(Name, Envelope)),
        ?assertEqual([{Name, Envelope}], secrets:retrieve_secret(Name)),
        ?assertEqual(Plain, secrets:decrypt_secret(Envelope, Key)),
        ok = dets:sync(Path),
        ok = close_table(Path, 16),
        ?assertEqual(undefined, dets:info(Path)),
        ?assert(filelib:is_regular(Path)),
        %% Read through the production API after the table has been closed.
        ?assertEqual([{Name, Envelope}], secrets:retrieve_secret(Name)),
        ?assertEqual(ok, secrets:delete_secret(Name)),
        ?assertEqual([], secrets:retrieve_secret(Name)),
        ok = close_table(Path, 16),
        ?assertEqual([], secrets:retrieve_secret(Name)),
        ok
    after
        ok = close_table(Path, 16)
    end.

authentication_checks() ->
    Key = crypto:strong_rand_bytes(64),
    Plain = <<"authenticated disposable payload">>,
    {IV, Cipher, Tag} = Envelope = secrets:encrypt_secret(Plain, Key),
    ?assertEqual(16, byte_size(IV)),
    ?assertEqual(16, byte_size(Tag)),
    ?assertEqual(Plain, secrets:decrypt_secret(Envelope, Key)),
    ?assertEqual(error, secrets:decrypt_secret(Envelope, flip_first_byte(Key))),
    ?assertEqual(
        error,
        secrets:decrypt_secret(
            {IV, flip_first_byte(Cipher), Tag}, Key
        )
    ),
    ?assertEqual(
        error,
        secrets:decrypt_secret(
            {IV, Cipher, flip_first_byte(Tag)}, Key
        )
    ),
    ok.

flip_first_byte(<<Byte, Rest/binary>>) ->
    <<(Byte bxor 1), Rest/binary>>.

close_table(Path, Attempts) when Attempts > 0 ->
    case dets:info(Path) of
        undefined ->
            ok;
        _ ->
            ok = dets:close(Path),
            close_table(Path, Attempts - 1)
    end;
close_table(Path, 0) ->
    case dets:info(Path) of
        undefined -> ok;
        _ -> erlang:error(test_dets_close_limit)
    end.

temp_dir(Attempts) when Attempts > 0 ->
    Root =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            "" -> "/tmp";
            Value -> Value
        end,
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))),
    Dir = filename:join(filename:absname(Root), "damage-secrets-test-" ++ Suffix),
    case file:make_dir(Dir) of
        ok ->
            case file:change_mode(Dir, 8#700) of
                ok ->
                    Dir;
                {error, Reason} ->
                    _ = file:del_dir(Dir),
                    erlang:error({test_directory_permissions, Reason})
            end;
        {error, eexist} ->
            temp_dir(Attempts - 1);
        {error, Reason} ->
            erlang:error({test_directory_create, Reason})
    end;
temp_dir(0) ->
    erlang:error(test_directory_collision_limit).

clean_dir(Dir) ->
    %% Only the file inside this fixture's exclusively-created directory.
    %% Never touch repository-local secrets.db, damage.dets, or a keystore.
    case file:delete(filename:join(Dir, "secrets.dets")) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Why} -> erlang:error({test_file_cleanup, Why})
    end,
    file:del_dir(Dir).
