-module(steps_utils).

-vsn("0.2.1").
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([step/6]).
-export([step_dry/6]).
-export([is_admin/1]).
-export([ensure_admin/1]).
-export([set_fail/2, set_fail/3]).
-export([parse_table/1]).
-export([parse_step_body/1]).
-export([
    ctx/1,
    run/2,
    run_ok/2
]).
-define(STEP_PRINT, ["I print", Variable]).
-define(STEP_PRINT_VAR, ["I print variable", Variable]).
-define(STEP_SET_VAR, ["I set the variable", Variable, "to", Value]).
-define(STEP_SET_JSON_VAR, ["I set the JSON variable", Variable]).
-define(STEP_SET_JSON_KEY_IN_VAR, [
    "I set JSON key", Key, "to", Value0, "in variable", Variable
]).
-define(STEP_WRITE_JSON_VAR_TO_FILE, [
    "I write JSON variable", Variable, "to file", Path
]).

step_dry(_Config, Context, _, _N, _, _) ->
    Spend = maps:get(step_spend, Context, 1 * math:pow(10, ?DAMAGE_DECIMALS)),
    maps:put(step_spend, Spend, Context).
step(_Config, Context, _, _N, ["I store an uuid in", Variable], _) ->
    maps:put(Variable, list_to_binary(uuid:to_string(uuid:uuid4())), Context);
%% Zero is a valid no-op. Keep explicit clauses so a tokenized string never
%% reaches timer:sleep/1 before normalization.
step(_Config, Context, _, _N, ["I wait", 0, "seconds"], _) ->
    Context;
step(_Config, Context, _, _N, ["I wait", 0.0, "seconds"], _) ->
    Context;
step(_Config, Context, _, _N, ["I wait", "0", "seconds"], _) ->
    Context;
step(_Config, Context, _, _N, ["I wait", <<"0">>, "seconds"], _) ->
    Context;
step(_Config, Context, _, _N, ["I wait", Seconds0, "seconds"], _) ->
    case wait_milliseconds(Seconds0) of
        {ok, 0} ->
            Context;
        {ok, Milliseconds} when is_integer(Milliseconds), Milliseconds > 0 ->
            timer:sleep(Milliseconds),
            Context;
        {error, Reason} ->
            set_fail(
                Context,
                "Invalid wait duration ~p seconds: ~p",
                [Seconds0, Reason]
            )
    end;
%%------------------------------------------------------------------------------
%% (Given/When/Then/And): Set an arbitrary variable in context
%%------------------------------------------------------------------------------
step(_Config, Context, _, _N, ?STEP_SET_VAR, _) ->
    maps:put(Variable, Value, Context);
step(
    _Config,
    Context,
    _,
    _N,
    ["I store the JSON at path", Path, "from", FromVar, "in", OutVar],
    _
) ->
    Json = maps:get(list_to_atom(FromVar), Context),
    case ejsonpath:q(Path, Json) of
        {[Value | _], _} ->
            maps:put(list_to_atom(OutVar), Value, Context);
        Other ->
            maps:put(
                fail,
                damage_utils:strf("JSON path ~p not found in ~p", [Path, Other]),
                Context
            )
    end;
%%------------------------------------------------------------------------------
%% (Given/When/Then/And): Set a variable from JSON docstring body
%% Example:
%%   When I set the JSON variable "meta"
%%   """
%%   {"name":"DamageBDD"}
%%   """
%%------------------------------------------------------------------------------
step(_Config, Context, _Keyword, _N, ?STEP_SET_JSON_VAR, Body) ->
    case catch jsx:decode(iolist_to_binary(Body), [return_maps]) of
        {'EXIT', _Reason} ->
            set_fail(
                Context,
                "Invalid JSON provided for variable ~p",
                [Variable]
            );
        Json when is_map(Json); is_list(Json) ->
            maps:put(Variable, Json, Context);
        Other ->
            set_fail(
                Context,
                "Unexpected JSON value for variable ~p: ~p",
                [Variable, Other]
            )
    end;
step(
    _Config,
    Context,
    _,
    _N,
    ["I store current time string in", Variable, "with format", Format],
    _
) ->
    {ok, DateString} = datestring:format(Format, calendar:universal_time()),
    maps:put(
        Variable,
        DateString,
        Context
    );
step(
    Config,
    Context,
    K,
    N,
    ?STEP_PRINT_VAR,
    Body
) ->
    step(
        Config,
        Context,
        K,
        N,
        ?STEP_PRINT,
        Body
    );
step(
    Config,
    Context,
    K,
    N,
    ?STEP_PRINT,
    _
) ->
    PrintedValue = resolve_print_value(Variable, Context),
    formatter:format(
        Config,
        print,
        {K, N, ["print:"], list_to_binary(damage_utils:strf("~p", [PrintedValue])), Context,
            success}
    ),
    Context;
step(
    _Config,
    #{public_key := AeAccount} = Context,
    <<"Given">>,
    _N,
    ["I am an Admin"],
    _
) ->
    case is_admin(AeAccount) of
        true -> Context;
        Other -> maps:put(fail, Other, Context)
    end;
step(
    _Config,
    #{public_key := AeAccount} = Context,
    <<"Given">>,
    _N,
    ["I am a", Service, "Admin"],
    _
) ->
    {ok, Services} =
        application:get_env(damage, systemd),
    ServiceAdmins = proplists:get_value(Service, Services, []),
    case lists:member(AeAccount, ServiceAdmins) of
        true -> Context;
        Other -> maps:put(fail, Other, Context)
    end;
%% Group
step(_Config, Context, _Phase, _N, ["the system group", Group, "exists"], _Body) ->
    case damage_utils:has_group(Group) of
        true -> Context;
        false -> damage_utils:run_ok(damage_utils:ctx(Context), damage_utils:groupadd(Group))
    end;
%% User
step(_Config, Context, _Phase, _N, ["the system user", User, "exists in group", Group], _Body) ->
    case damage_utils:has_user(User) of
        true -> Context;
        false -> damage_utils:run_ok(damage_utils:ctx(Context), damage_utils:useradd(User, Group))
    end;
%% Directory
step(_Config, Context, _Phase, _N, ["the directory", Dir, "exists"], _Body) ->
    damage_utils:ensure_dir(Dir),
    Context;
%% Chown -R
step(_Config, Context, _Phase, _N, ["I chown recursively", Path, "to", OwnerGroup], _Body) ->
    damage_utils:run_ok(damage_utils:ctx(Context), damage_utils:chown_r(Path, OwnerGroup));
%% Ensure SSH host key
step(_Config, Context, _Phase, _N, ["I ensure an SSH host key at", KeyPath], _Body) ->
    case filelib:is_file(KeyPath) of
        true ->
            Context;
        false ->
            damage_utils:ensure_dir(filename:dirname(KeyPath) ++ "/"),
            damage_utils:run_ok(damage_utils:ctx(Context), damage_utils:ssh_keygen(KeyPath))
    end;
%% Then file exists
step(_Config, Context, _Phase, _N, ["the file", Path, "should exist"], _Body) ->
    case filelib:is_file(Path) of
        true -> Context;
        false -> damage_utils:fail(Context, {missing_file, Path})
    end;
%%------------------------------------------------------------------------------
%% Set one key in a JSON map variable
%% Example:
%%   When I set JSON key "file_ipfs" to "{{asset_hash}}" in variable "meta"
%%------------------------------------------------------------------------------
step(_Config, Context, _Keyword, _N, ?STEP_SET_JSON_KEY_IN_VAR, _) ->
    VarKey = to_bin(Variable),
    KeyBin = to_bin(Key),
    RenderedValue = render_string(Value0, Context),

    case maps:get(VarKey, Context, maps:get(Variable, Context, undefined)) of
        Json when is_map(Json) ->
            Context#{VarKey => Json#{KeyBin => RenderedValue}};
        undefined ->
            set_fail(Context, "JSON variable ~p is not set", [Variable]);
        Other ->
            set_fail(Context, "Variable ~p is not a JSON object: ~p", [Variable, Other])
    end;
%%------------------------------------------------------------------------------
%% Write a JSON variable to a file (only under run_dir)
%% Example:
%%   When I write JSON variable "meta" to file "meta.json"
%%------------------------------------------------------------------------------
step(
    Config,
    Context,
    _Keyword,
    _N,
    ?STEP_WRITE_JSON_VAR_TO_FILE,
    _
) ->
    VarKey = to_bin(Variable),

    case lists:keyfind(run_dir, 1, Config) of
        false ->
            set_fail(Context, "run_dir not configured");
        {run_dir, RunDir0} ->
            RunDir = filename:absname(to_list(RunDir0)),
            RequestedPath = to_list(unquote_arg(Path)),

            case maps:get(VarKey, Context, maps:get(Variable, Context, undefined)) of
                Json when is_map(Json); is_list(Json) ->
                    case safe_write_path_under_run_dir(RunDir, RequestedPath) of
                        {ok, AbsFilePath} ->
                            ok = filelib:ensure_dir(AbsFilePath),
                            case file:write_file(AbsFilePath, jsx:encode(Json)) of
                                ok ->
                                    Context;
                                {error, Reason} ->
                                    set_fail(
                                        Context,
                                        "Failed writing JSON variable ~p to ~p: ~p",
                                        [Variable, RequestedPath, Reason]
                                    )
                            end;
                        {error, Why} ->
                            set_fail(
                                Context,
                                "Refusing to write outside run_dir: ~p (~p)",
                                [RequestedPath, Why]
                            )
                    end;
                undefined ->
                    set_fail(Context, "JSON variable ~p is not set", [Variable]);
                Other ->
                    set_fail(Context, "Variable ~p is not JSON-encodable: ~p", [Variable, Other])
            end
    end;
%% Then executable bit
step(
    _Config,
    Context,
    _Phase,
    _N,
    ["the executable", Path, "should be executable (if exists)"],
    _Body
) ->
    case filelib:is_file(Path) of
        % skip
        false ->
            Context;
        true ->
            case damage_utils:is_exec(Path) of
                true -> Context;
                false -> set_fail(Context, {not_executable, Path})
            end
    end.

is_admin(Context) when is_map(Context) ->
    is_admin(maps:get(public_key, Context, undefined));
is_admin(AeAccount) when is_binary(AeAccount) ->
    is_admin(binary_to_list(AeAccount));
is_admin(AeAccount) ->
    case application:get_env(damage, node_admins) of
        {ok, NodeAdmins} ->
            lists:member(AeAccount, NodeAdmins);
        Other ->
            ?LOG_ERROR("not node admin ~p <> ~p", [Other, AeAccount]),
            false
    end.
ensure_admin(Context) ->
    case is_admin(Context) of
        true ->
            ok;
        false ->
            throw(unauthorized)
    end.

parse_step_body(Text) ->
    case try_json_parse(Text) of
        {ok, JsonMap} -> JsonMap;
        error -> parse_table(Text)
    end.

try_json_parse(Text) ->
    try
        {ok, jsx:decode(Text, [return_maps])}
    catch
        _:_ -> error
    end.

parse_table(Text) ->
    Lines = string:split(string:trim(Text), "\n", all),
    ParsedLines = lists:filtermap(fun parse_line/1, Lines),
    maps:from_list(ParsedLines).

parse_line(Line) ->
    case string:trim(Line) of
        <<"|", Rest/binary>> ->
            Parts = lists:map(fun string:trim/1, string:split(Rest, "|", all)),
            case Parts of
                [Key, Value] -> {true, {binary_to_atom(Key, utf8), Value}};
                _ -> false
            end;
        _ ->
            false
    end.

set_fail(Context, Reason) ->
    maps:put(fail, Reason, Context).

set_fail(Ctx, Fmt, Args) ->
    maps:put(fail, damage_utils:strf(Fmt, Args), Ctx).
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

run_ok(Context, CmdIolist) ->
    case run(Context, CmdIolist) of
        ok -> Context;
        {error, R} -> steps_utils:set_fail(Context, R)
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
wait_milliseconds(Seconds) when is_integer(Seconds) ->
    wait_milliseconds_from_number(Seconds);
wait_milliseconds(Seconds) when is_float(Seconds) ->
    wait_milliseconds_from_number(Seconds);
wait_milliseconds(Seconds) when is_binary(Seconds) ->
    wait_milliseconds(binary_to_list(Seconds));
wait_milliseconds(Seconds) when is_list(Seconds) ->
    Text = string:trim(Seconds),
    case string:to_integer(Text) of
        {Value, []} ->
            wait_milliseconds_from_number(Value);
        _ ->
            case string:to_float(Text) of
                {Value, []} -> wait_milliseconds_from_number(Value);
                _ -> {error, invalid_number}
            end
    end;
wait_milliseconds(_Seconds) ->
    {error, invalid_type}.

wait_milliseconds_from_number(Seconds) when Seconds < 0 ->
    {error, negative_duration};
wait_milliseconds_from_number(Seconds) ->
    Milliseconds = round(Seconds * 1000),
    case Milliseconds =< 16#FFFFFFFF of
        true -> {ok, Milliseconds};
        false -> {error, duration_too_large}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(Other) -> binary_to_list(to_bin(Other)).

render_string(Value0, Context) ->
    Value = to_bin(Value0),
    damage_utils:render(Value, Context).

resolve_print_value(Value0, Context) ->
    Value = to_bin(Value0),
    Rendered = damage_utils:render(Value, Context),
    case maps:find(Rendered, Context) of
        {ok, Exact} ->
            Exact;
        error ->
            case maps:find(binary_to_list(Rendered), Context) of
                {ok, Exact2} ->
                    Exact2;
                error ->
                    Rendered
            end
    end.

%% Resolve a target file path under RunDir and guarantee it cannot escape.
%% Suitable for writes, so the file itself may not exist yet.
safe_write_path_under_run_dir(RunDirAbs0, Path0) ->
    RunDirAbs = filename:absname(RunDirAbs0),
    Path = string:trim(Path0),

    case filename:pathtype(Path) of
        absolute ->
            {error, absolute_path_not_allowed};
        _ ->
            Joined = filename:join(RunDirAbs, Path),
            Abs = filename:absname(Joined),
            Parent0 = filename:dirname(Abs),

            case filelib:is_dir(Parent0) of
                true ->
                    case realpath(Parent0) of
                        {ok, RealParent} ->
                            FinalAbs = filename:join(RealParent, filename:basename(Abs)),
                            case is_within_dir(FinalAbs, RunDirAbs) of
                                true -> {ok, FinalAbs};
                                false -> {error, escaped_via_symlink_or_traversal}
                            end;
                        {error, R} ->
                            {error, {realpath_failed, R}}
                    end;
                false ->
                    case nearest_existing_dir(Parent0) of
                        {ok, ExistingParent, SuffixParts} ->
                            case realpath(ExistingParent) of
                                {ok, RealExistingParent} ->
                                    RealParent =
                                        lists:foldl(
                                            fun(Part, Acc) -> filename:join(Acc, Part) end,
                                            RealExistingParent,
                                            SuffixParts
                                        ),
                                    FinalAbs = filename:join(
                                        RealParent,
                                        filename:basename(Abs)
                                    ),
                                    case is_within_dir(FinalAbs, RunDirAbs) of
                                        true -> {ok, FinalAbs};
                                        false -> {error, escaped_via_symlink_or_traversal}
                                    end;
                                {error, R} ->
                                    {error, {realpath_failed, R}}
                            end;
                        {error, Why} ->
                            {error, Why}
                    end
            end
    end.

nearest_existing_dir(Path) ->
    nearest_existing_dir(filename:absname(Path), []).

nearest_existing_dir(Path, AccSuffix) ->
    case filelib:is_dir(Path) of
        true ->
            {ok, Path, lists:reverse(AccSuffix)};
        false ->
            Parent = filename:dirname(Path),
            Base = filename:basename(Path),
            case Parent =:= Path of
                true ->
                    {error, no_existing_parent_dir};
                false ->
                    nearest_existing_dir(Parent, [Base | AccSuffix])
            end
    end.

%% Returns true if PathAbs is inside DirAbs (or equal to it).
is_within_dir(PathAbs0, DirAbs0) ->
    PathAbs = filename:absname(PathAbs0),
    DirAbs = filename:absname(DirAbs0),
    DirWithSep =
        case lists:last(DirAbs) of
            $/ -> DirAbs;
            _ -> DirAbs ++ "/"
        end,
    (PathAbs =:= DirAbs) orelse lists:prefix(DirWithSep, PathAbs).

realpath(Path) ->
    try
        {ok, filelib:realpath(Path)}
    catch
        _:_ ->
            {ok, filename:absname(Path)}
    end.
unquote_arg(B) when is_binary(B) ->
    to_bin(unquote_arg(binary_to_list(B)));
unquote_arg(S) when is_list(S) ->
    S1 = string:trim(S),
    case {S1, lists:reverse(S1)} of
        {[$" | Rest], [$" | RevRest]} when Rest =/= [], RevRest =/= [] ->
            lists:reverse(tl(lists:reverse(Rest)));
        _ ->
            S1
    end.
