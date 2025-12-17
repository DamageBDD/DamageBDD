-module(steps_pkg).
-author("DamageBDD").
-include_lib("kernel/include/logger.hrl").

-export([step/6]).

%% =============================================================================
%% STEP DEFINITIONS (Gherkin)
%% -----------------------------------------------------------------------------
%% When I download file from "<URL>" to "<DEST>"
%% When I download file from "<URL>" to "<DEST>" as "<Var>"
%%
%% Then the checksum sha256 of "<PATH|$Var>" must be "<HEX>"
%% Then the checksum sha512 of "<PATH|$Var>" must be "<HEX>"
%%
%% Given I import gpg key from url "<URL>"
%% Given I import gpg key:
%% """
%% -----BEGIN PGP PUBLIC KEY BLOCK-----
%% ...
%% -----END PGP PUBLIC KEY BLOCK-----
%% """
%%
%% Then the signature at "<SIG_PATH|$Var>" verifies for "<FILE_PATH|$Var>"
%%
%% When I extract archive "<PATH|$Var>" to "<DEST_DIR>"
%% When I extract archive "<PATH|$Var>" to "<DEST_DIR>" with strip-components "<N>"
%% =============================================================================

%% 10 minutes for large downloads
-define(DEFAULT_TIMEOUT, 600000).
-define(DEFAULT_HEADERS, [
    {<<"user-agent">>, "damagebdd/1.0"},
    {<<"accept">>, "*/*"}
]).

%% ------------------------------- Steps ---------------------------------------

%% Download basic
step(_Cfg, Context, <<"When">>, _N, ["I download file from", Url, "to", Dest], _Body) ->
    true = steps_utils:is_admin(Context),
    do_download(Context, Url, Dest, download_path);
%% Download and store in a named variable
step(
    _Cfg,
    Context,
    <<"When">>,
    _N,
    ["I download file from", Url, "to", Dest, "as", Var],
    _Body
) ->
    true = steps_utils:is_admin(Context),
    do_download(Context, Url, Dest, list_to_atom(Var));
%% Checksum verification (sha256/sha512)
step(
    _Cfg,
    Context,
    <<"Then">>,
    _N,
    ["the checksum", AlgoStr, "of", PathOrVar, "must be", Hex],
    _Body
) ->
    true = steps_utils:is_admin(Context),
    Algo =
        case string:to_lower(AlgoStr) of
            "sha256" -> sha256;
            "sha512" -> sha512;
            Other -> throw({unsupported_checksum_algo, Other})
        end,
    File = resolve_path(Context, PathOrVar),
    case verify_checksum(File, Algo, Hex) of
        ok -> Context;
        {error, Reason} -> maps:put(fail, io_lib:format("Checksum failed: ~p", [Reason]), Context)
    end;
%% Import GPG key from URL
step(_Cfg, Context, <<"Given">>, _N, ["I import gpg key from url", Url], _Body) ->
    true = steps_utils:is_admin(Context),
    case import_gpg_key_from_url(Url) of
        ok -> Context;
        {error, E} -> maps:put(fail, io_lib:format("GPG import failed: ~p", [E]), Context)
    end;
%% Import GPG key from inline block
step(_Cfg, Context, <<"Given">>, _N, ["I import gpg key"], Body) ->
    true = steps_utils:is_admin(Context),
    case import_gpg_key_from_block(Body) of
        ok -> Context;
        {error, E} -> maps:put(fail, io_lib:format("GPG import failed: ~p", [E]), Context)
    end;
%% Signature verification
step(
    _Cfg,
    Context,
    <<"Then">>,
    _N,
    ["the signature at", SigPathOrVar, "verifies for", FilePathOrVar],
    _Body
) ->
    true = steps_utils:is_admin(Context),
    Sig = resolve_path(Context, SigPathOrVar),
    File = resolve_path(Context, FilePathOrVar),
    case verify_signature(Sig, File) of
        ok -> Context;
        {error, E} -> maps:put(fail, io_lib:format("Signature verify failed: ~p", [E]), Context)
    end;
%% Extract with optional strip-components
step(
    _Cfg,
    Context,
    <<"When">>,
    _N,
    ["I extract archive", PathOrVar, "to", Dest],
    _Body
) ->
    true = steps_utils:is_admin(Context),
    do_extract(Context, PathOrVar, Dest, 0);
step(
    _Cfg,
    Context,
    <<"When">>,
    _N,
    ["I extract archive", PathOrVar, "to", Dest, "with strip-components", NStr],
    _Body
) ->
    true = steps_utils:is_admin(Context),
    Strips = list_to_integer(NStr),
    do_extract(Context, PathOrVar, Dest, Strips).

%% ------------------------------ Implementation -------------------------------

do_download(Context0, Url0, Dest0, Var) ->
    Url = to_list(Url0),
    Dest = to_list(Dest0),
    ok = ensure_parent_dir(Dest),
    case gun_download_to_file(Url, Dest) of
        ok ->
            Context = maps:put(Var, Dest, Context0),
            maps:put(downloaded, Dest, Context);
        {error, E} ->
            maps:put(fail, io_lib:format("Download failed: ~p", [E]), Context0)
    end.

verify_checksum(File, Algo, ExpectHex0) ->
    ExpectHex = string:lowercase(to_list(ExpectHex0)),
    case file:read_file(File) of
        {ok, Bin} ->
            Hash =
                case Algo of
                    sha256 -> crypto:hash(sha256, Bin);
                    sha512 -> crypto:hash(sha512, Bin)
                end,
            Hex = lower_hex(Hash),
            case Hex =:= ExpectHex of
                true -> ok;
                false -> {error, {mismatch, #{expected => ExpectHex, got => Hex}}}
            end;
        Err ->
            {error, {read_failed, Err}}
    end.

import_gpg_key_from_url(Url0) ->
    Tmp = temp_file("gpgkey.asc"),
    case gun_download_to_file(to_list(Url0), Tmp) of
        ok -> gpg_import(Tmp);
        Err -> Err
    end.

import_gpg_key_from_block(BodyBin) when is_binary(BodyBin) ->
    Tmp = temp_file("gpgkey.asc"),
    ok = file:write_file(Tmp, BodyBin),
    gpg_import(Tmp).

verify_signature(SigPath, FilePath) ->
    Cmd = io_lib:format("gpg --batch --yes --verify ~s ~s", [quote(SigPath), quote(FilePath)]),
    run_exec_ok(Cmd, "gpg_verify").

gpg_import(File) ->
    Cmd = io_lib:format("gpg --batch --yes --import ~s", [quote(File)]),
    run_exec_ok(Cmd, "gpg_import").

do_extract(Context0, PathOrVar, Dest0, StripN) ->
    Archive = resolve_path(Context0, PathOrVar),
    Dest = to_list(Dest0),
    ok = ensure_dir(Dest),
    case extract(Archive, Dest, StripN) of
        ok ->
            maps:put(extracted_to, Dest, Context0);
        {error, E} ->
            maps:put(fail, io_lib:format("Extract failed: ~p", [E]), Context0)
    end.

%% ------------------------------ Extraction -----------------------------------

extract(File, Dest, StripN) ->
    case filename:extension(File) of
        ".zip" ->
            zip_extract(File, Dest, StripN);
        ".gz" ->
            %% .tar.gz or .tgz
            extract_tar(File, Dest, [compressed], StripN);
        ".xz" ->
            extract_tar(File, Dest, [compressed], StripN);
        ".tgz" ->
            extract_tar(File, Dest, [compressed], StripN);
        ".tar" ->
            extract_tar(File, Dest, [], StripN);
        _ ->
            %% try tar by magic header, else fail
            try
                extract_tar(File, Dest, [compressed], StripN)
            catch
                _:_ -> {error, unsupported_archive}
            end
    end.

extract_tar(File, Dest, TarOpts, StripN) ->
    %% erl_tar does not implement strip-components; emulate by expanding to temp
    case StripN > 0 of
        true ->
            Tmp = temp_dir("untar"),
            ok = erl_tar:extract(File, TarOpts ++ [{cwd, Tmp}]),
            ok = move_with_strip(Tmp, Dest, StripN),
            ok;
        false ->
            erl_tar:extract(File, TarOpts ++ [{cwd, Dest}])
    end.

zip_extract(File, Dest, StripN) ->
    case zip:extract(File, [memory]) of
        {ok, Entries} ->
            write_entries(Entries, Dest, StripN);
        Err ->
            Err
    end.

write_entries([], _Dest, _StripN) ->
    ok;
write_entries([{Name, Bin} | T], Dest, StripN) ->
    Rel = strip_components(to_list(Name), StripN),
    Path = filename:join(Dest, Rel),
    ok = ensure_parent_dir(Path),
    ok = file:write_file(Path, Bin),
    write_entries(T, Dest, StripN).

move_with_strip(SrcRoot, Dest, StripN) ->
    {ok, Files} = filelib:fold_files(
        SrcRoot,
        ".*",
        true,
        fun(F, Acc) -> [F | Acc] end,
        []
    ),
    lists:foreach(
        fun(F) ->
            Rel =
                filename:split(filename:absname(F)) --
                    filename:split(filename:absname(SrcRoot)),
            RelStr = filename:join(Rel),
            Stripped = strip_components(RelStr, StripN),
            Target = filename:join(Dest, Stripped),
            case filelib:is_dir(F) of
                % dirs handled by ensure_parent_dir
                true ->
                    ok;
                false ->
                    ok = ensure_parent_dir(Target),
                    ok = file:copy(F, Target)
            end
        end,
        Files
    ),
    ok.

strip_components(Path, N) when N =< 0 -> Path;
strip_components(Path, N) ->
    Segs = filename:split(Path),
    case length(Segs) > N of
        true -> filename:join(lists:nthtail(N, Segs));
        false -> filename:basename(Path)
    end.

%% ------------------------------- Download (gun) -------------------------------

gun_download_to_file(Url, DestPath) ->
    U0 = uri_string:parse(Url),

    %% scheme can be <<"https">> | "https" | undefined
    Scheme0 = maps:get(scheme, U0, undefined),
    Scheme =
        case Scheme0 of
            S when is_binary(S) -> binary_to_list(S);
            S when is_list(S) -> S;
            undefined -> "http"
        end,

    %% host may be binary/list; if missing, fail early
    Host0 = maps:get(host, U0, undefined),
    Host =
        case Host0 of
            B when is_binary(B) -> binary_to_list(B);
            L when is_list(L) -> L;
            undefined -> error({bad_url, missing_host})
        end,

    %% path may be undefined/empty
    Path0 = maps:get(path, U0, "/"),
    Path1 =
        case Path0 of
            undefined -> "/";
            <<>> -> "/";
            B0 when is_binary(B0) -> binary_to_list(B0);
            L0 when is_list(L0) -> L0
        end,

    %% include query if present
    Query0 = maps:get(query, U0, undefined),
    Path =
        case Query0 of
            undefined -> Path1;
            <<>> -> Path1;
            Q when is_binary(Q) -> Path1 ++ "?" ++ binary_to_list(Q);
            Q when is_list(Q) -> Path1 ++ "?" ++ Q
        end,

    %% ✅ PORT: if not provided, default based on scheme
    Port0 = maps:get(port, U0, undefined),
    Port =
        case Port0 of
            P when is_integer(P) -> P;
            undefined ->
                case string:to_lower(Scheme) of
                    "https" -> 443;
                    _ -> 80
                end
        end,

    Opts =
        case string:to_lower(Scheme) of
            "https" -> #{transport => tls, tls_opts => [{verify, verify_none}]};
            _ -> #{transport => tcp}
        end,

    {ok, Conn} = gun:open(Host, Port, maps:merge(Opts, #{connect_timeout => ?DEFAULT_TIMEOUT})),
    _ = gun:await_up(Conn),
    Ref = gun:get(Conn, Path, ?DEFAULT_HEADERS),

    case gun:await(Conn, Ref, ?DEFAULT_TIMEOUT) of
        {response, nofin, 200, _Headers} ->
            {ok, Io} = file:open(DestPath, [write, raw, binary]),
            Res = stream_body(Conn, Ref, Io),
            ok = file:close(Io),
            Res;
        {response, fin, 200, _Headers} ->
            file:write_file(DestPath, <<>>),
            ok;
        Other ->
            {error, {bad_response, Other}}
    end.

stream_body(Conn, Ref, Io) ->
    case gun:await_body(Conn, Ref) of
        {ok, Bin} ->
            file:write(Io, Bin),
            ok;
        {more, Bin} ->
            file:write(Io, Bin),
            stream_body(Conn, Ref, Io)
    end.

%% ------------------------------- Exec helpers --------------------------------

run_exec_ok(CmdIolist, Tag) ->
    Cmd = lists:flatten(CmdIolist),
    ?LOG_INFO("exec(~s): ~s", [Tag, Cmd]),
    case exec:run(Cmd, [sync, stdout, stderr, monitor]) of
        {ok, _Pid, _OSPid, 0, _Out} -> ok;
        {ok, _Pid, _OSPid, Code, Out} -> {error, {exit_code, Code, Out}};
        Err -> {error, Err}
    end.

%% ------------------------------- Utilities -----------------------------------

ensure_dir(Dir) ->
    filelib:ensure_dir(filename:join(Dir, "._x")),
    ok.

ensure_parent_dir(Path) ->
    filelib:ensure_dir(filename:join(filename:dirname(Path), "._x")),
    ok.

resolve_path(Context, Arg) ->
    case Arg of
        <<"$", _/binary>> ->
            maps:get(
                list_to_atom(binary_to_list(binary:part(Arg, 1, byte_size(Arg) - 1))), Context
            );
        [$$ | Var] ->
            maps:get(list_to_atom(Var), Context);
        _ ->
            to_list(Arg)
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(L) when is_list(L) -> L.

quote(S) ->
    [$", string:replace(to_list(S), "\"", "\\\"", all), $"].

temp_file(Suffix) ->
    Base = filename:join(
        os:getenv("TMPDIR") orelse "/tmp",
        "damagepkg_" ++ integer_to_list(erlang:unique_integer([monotonic]))
    ),
    Base ++ "_" ++ Suffix.

temp_dir(Pfx) ->
    Dir = filename:join(
        os:getenv("TMPDIR") orelse "/tmp",
        Pfx ++ "_" ++ integer_to_list(erlang:unique_integer([monotonic]))
    ),
    ok = file:make_dir(Dir),
    Dir.

lower_hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [X]) || <<X:8>> <= Bin]).
