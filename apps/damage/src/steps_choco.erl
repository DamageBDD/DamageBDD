-module(steps_choco).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6]).

%%% ======================
%%% Small helpers
%%% ======================
os_is_windows() ->
    case os:type() of
        {win32, nt} -> true;
        _ -> false
    end.

unquote(Bin) when is_binary(Bin) ->
    L = byte_size(Bin),
    case L >= 2 andalso binary:at(Bin, 0) =:= $" andalso binary:at(Bin, L-1) =:= $" of
        true -> binary:part(Bin, 1, L - 2);
        false -> Bin
    end.

ps(PS) ->
    %% Invoke PowerShell in a safe, non-interactive way.
    exec:run(
      ["powershell.exe","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-Command", PS],
      [sync, stdout, stderr]).

put_fail(Context, Fmt, Args) ->
    Msg = iolist_to_binary(io_lib:format(Fmt, Args)),
    maps:put(fail, Msg, Context).

store(Context, Key, Val) ->
    maps:put(Key, Val, Context).

get_stdout(Res) ->
    case Res of
        {ok, KVs} ->
            Std = [B || {stdout, B} <- KVs],
            iolist_to_binary(Std);
        _ -> <<>>
    end.

get_exit(Res) ->
    case Res of
        {ok, KVs} ->
            case lists:keyfind(exit_status, 1, KVs) of
                {exit_status, Code} -> Code;
                false -> 0
            end;
        {error, KVs} ->
            case lists:keyfind(exit_status, 1, KVs) of
                {exit_status, Code} -> Code;
                false -> 1
            end
    end.

trim(Bin) when is_binary(Bin) ->
    binary:trim(Bin, both, $\s).

%% Parse `choco list --local-only --exact PACKAGE --limit-output`
%% Returns {installed, VersionBin} | not_installed
parse_local_exact(Pkg0, OutBin) ->
    Pkg = unquote(Pkg0),
    Lines = [trim(L) || L <- binary:split(OutBin, <<"\n">>, [global])],
    WantPrefix = <<Pkg/binary, "|">>,
    PLen = byte_size(WantPrefix),
    case [L || L <- Lines, L =/= <<>>] of
        [] -> not_installed;
        [Line | _] ->
            case binary:match(Line, WantPrefix) of
                {0, _} ->
                    Ver = binary:part(Line, PLen, byte_size(Line) - PLen),
                    {installed, Ver};
                nomatch -> not_installed
            end
    end.

%% Simple semver-ish comparator supporting =, ==, >, >=, <, <=
splitv(V) ->
    [case catch binary_to_integer(P) of
         I when is_integer(I) -> {i,I};
         _ -> {s,P}
     end || P <- binary:split(V, <<".">>, [global])].

cmp_parts([], []) -> 0;
cmp_parts([A|As], []) ->
    case A of
        {i,0} -> cmp_parts(As, []);
        {s,<<>>} -> cmp_parts(As, []);
        _ -> 1
    end;
cmp_parts([], [B|Bs]) ->
    case B of
        {i,0} -> cmp_parts([], Bs);
        {s,<<>>} -> cmp_parts([], Bs);
        _ -> -1
    end;
cmp_parts([{i,A}|As], [{i,B}|Bs]) ->
    if A < B -> -1;
       A > B -> 1;
       true -> cmp_parts(As, Bs)
    end;
cmp_parts([{s,A}|As], [{s,B}|Bs]) ->
    if A < B -> -1;
       A > B -> 1;
       true -> cmp_parts(As, Bs)
    end;
cmp_parts([{i,_}|_]=A, [{s,_}|_]=B) -> cmp_parts(A, B);
cmp_parts([{s,_}|_]=A, [{i,_}|_]=B) -> cmp_parts(A, B).

ver_compare(Op, VInstalled, VExpected) ->
    IA = splitv(VInstalled),
    IB = splitv(VExpected),
    C = cmp_parts(IA, IB),
    case Op of
        <<"=">>  -> C =:= 0;
        <<"==">> -> C =:= 0;
        <<">">>  -> C =:= 1;
        <<">=">> -> (C =:= 1) orelse (C =:= 0);
        <<"<">>  -> C =:= -1;
        <<"<=">> -> (C =:= -1) orelse (C =:= 0);
        _        -> C =:= 0
    end.

ensure_windows(Context) ->
    case os_is_windows() of
        true -> {ok, Context};
        false -> {error, put_fail(Context, "Chocolatey steps require Windows.", [])}
    end.

ensure_choco(Context) ->
    case ensure_windows(Context) of
        {error, Ctx} -> {error, Ctx};
        {ok, _} ->
            Res = ps("Get-Command choco -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name"),
            case get_exit(Res) of
                0 ->
                    {ok, store(Context, choco_check, Res)};
                _ ->
                    InstallPS =
                        "$ProgressPreference='SilentlyContinue';" ++
                        "[System.Net.ServicePointManager]::SecurityProtocol = " ++
                        "[System.Net.ServicePointManager]::SecurityProtocol -bor 3072;" ++
                        "Set-ExecutionPolicy Bypass -Scope Process -Force;" ++
                        "iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))",
                    ResI = ps(InstallPS),
                    case get_exit(ResI) of
                        0 -> {ok, store(Context, choco_install, ResI)};
                        _ -> {error, put_fail(Context, "Failed to install Chocolatey: ~p", [ResI])}
                    end
            end
    end.

run_choco(Context, Cmd) ->
    case ensure_choco(Context) of
        {error, Ctx} -> {error, Ctx};
        {ok, Ctx} ->
            PS = io_lib:format("choco ~s", [Cmd]),
            Res = ps(lists:flatten(PS)),
            {ok, store(Ctx, choco_result, Res)}
    end.

allowed(Context) ->
    maps:get(choco_allowed, Context, []).

is_allowed(Pkg0, Context) ->
    Pkg = unquote(Pkg0),
    lists:member(Pkg, allowed(Context)).

%%% ======================
%%% Step dispatcher
%%% ======================

%% Ensure Choco exists
step(_Config, Context, <<"Given">>, _N, ["Chocolatey is available"], _) ->
    case ensure_choco(Context) of
        {ok, Ctx} -> Ctx;
        {error, Ctx} -> Ctx
    end;

%% Whitelist (safety)
step(_Config, Context, <<"Given">>, _N, ["I allow chocolatey packages", CSV0], _) ->
    CSV = unquote(CSV0),
    Pkgs = [binary:trim(P, both, $\s) || P <- binary:split(CSV, <<",">>, [global])],
    store(Context, choco_allowed, Pkgs);

%% Install/Upgrade/Uninstall
step(_Config, Context, <<"When">>, _N, ["I choco install", Pkg], _) ->
    case is_allowed(Pkg, Context) of
        true  ->
            {ok, C1} = run_choco(Context, io_lib:format(
                "install ~s -y --no-progress --limit-output", [binary_to_list(unquote(Pkg))])),
            C1;
        false -> put_fail(Context, "Package ~p is not whitelisted. Add it via 'I allow chocolatey packages'.", [Pkg])
    end;

step(_Config, Context, <<"When">>, _N, ["I choco upgrade", Pkg], _) ->
    case is_allowed(Pkg, Context) of
        true  ->
            {ok, C1} = run_choco(Context, io_lib:format(
                "upgrade ~s -y --no-progress --limit-output", [binary_to_list(unquote(Pkg))])),
            C1;
        false -> put_fail(Context, "Package ~p is not whitelisted.", [Pkg])
    end;

step(_Config, Context, <<"When">>, _N, ["I choco uninstall", Pkg], _) ->
    case is_allowed(Pkg, Context) of
        true  ->
            {ok, C1} = run_choco(Context, io_lib:format(
                "uninstall ~s -y --no-progress", [binary_to_list(unquote(Pkg))])),
            C1;
        false -> put_fail(Context, "Package ~p is not whitelisted.", [Pkg])
    end;

%% Assertions
step(_Config, Context, <<"Then">>, _N, ["the choco package", Pkg, "should be installed"], _) ->
    case run_choco(Context, io_lib:format(
            "list --local-only --exact ~s --limit-output", [binary_to_list(unquote(Pkg))])) of
        {error, Ctx} -> Ctx;
        {ok, Ctx} ->
            Out = get_stdout(maps:get(choco_result, Ctx)),
            case parse_local_exact(Pkg, Out) of
                {installed, _V} -> Ctx;
                not_installed ->
                    put_fail(Ctx, "Package ~p is not installed. Output: ~p", [Pkg, Out])
            end
    end;

step(_Config, Context, <<"Then">>, _N, ["the choco package", Pkg, "version should be", Want0], _) ->
    Want = trim(unquote(Want0)),
    case run_choco(Context, io_lib:format(
            "list --local-only --exact ~s --limit-output", [binary_to_list(unquote(Pkg))])) of
        {error, Ctx} -> Ctx;
        {ok, Ctx} ->
            Out = get_stdout(maps:get(choco_result, Ctx)),
            case parse_local_exact(Pkg, Out) of
                {installed, V} ->
                    %% ---- FIXED: no guards, no binary:at/2 in 'if' ----
                    {Op, Target} =
                        case Want of
                            <<$>, $=, Rest/binary>> -> {<<">=">>, Rest};
                            <<$>,       Rest/binary>> -> {<<">">>,  Rest};
                            <<$<, $=, Rest/binary>> -> {<<"<=">>, Rest};
                            <<$<,       Rest/binary>> -> {<<"<">>,  Rest};
                            <<$=,       Rest/binary>> -> {<<"=">>,  Rest};
                            _                        -> {<<"=">>,  Want}
                        end,
                    case ver_compare(Op, V, Target) of
                        true  -> Ctx;
                        false ->
                            put_fail(Ctx,
                                     "Version check failed: ~s ~s (installed ~s)",
                                     [binary_to_list(unquote(Pkg)), binary_to_list(Want), binary_to_list(V)])
                    end;
                not_installed ->
                    put_fail(Ctx, "Package ~p is not installed. Output: ~p", [Pkg, Out])
            end
    end;
%% Exit status check
step(_Config, Context, <<"Then">>, _N, ["the last choco exit status must be", Status0], _) ->
    Want =
        case Status0 of
            <<>> -> 0;
            _ when is_binary(Status0) ->
                list_to_integer(binary_to_list(Status0));
            _ -> Status0
        end,
    Code = get_exit(maps:get(choco_result, Context, {ok, []})),
    case Code =:= Want of
        true -> Context;
        false -> put_fail(Context, "Expected exit ~p, got ~p", [Want, Code])
    end;

%% Compatibility no-op
step(_Config, _Context, <<"Given">>, _N, ["I am the node named", _Node], _) ->
    ok;

%% Fallback
step(_Config, Context, _Tense, _N, _Words, _Meta) ->
    Context.
