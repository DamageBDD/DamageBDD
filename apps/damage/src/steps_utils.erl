-module(steps_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([step/6]).
-export([step_dry/6]).
-export([is_admin/1]).
-export([parse_table/1]).
-export([parse_step_body/1]).

step_dry(_Config, Context, _, _N, _, _) ->
    Context.
step(_Config, Context, _, _N, ["I store an uuid in", Variable], _) ->
    maps:put(Variable, list_to_binary(uuid:to_string(uuid:uuid4())), Context);
step(_Config, Context, _, _N, ["I wait", Seconds, "seconds"], _) ->
    timer:sleep(Seconds),
    Context;
step(
    _Config,
    Context,
    _,
    _N,
    ["I store current time string in ", Variable, " with format ", Format],
    _
) ->
    maps:put(
        Variable,
        datestring:format(Format, calendar:universal_time()),
        Context
    );
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
    {ok, {admins, ServiceAdmins}} =
        application:get_env(damage_systemd, list_to_atom(Service)),
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
%% Ensure IPFS asset (optional)
step(_Config, Context, _Phase, _N, ["I ensure IPFS asset", Hash, "at", OutPath], _Body) ->
    case filelib:is_file(OutPath) of
        true ->
            Context;
        false ->
            damage_utils:ensure_dir(filename:dirname(OutPath) ++ "/"),
            case damage_ipfs:get(Hash, OutPath) of
                {error, Reason} ->
                    ?LOG_WARNING("ipfs failed to fetch ~s -> ~s error: ~p", [Hash, OutPath, Reason]),
                    damage_utils:fail(Context, Reason);
                {ok, Result} ->
                    ?LOG_DEBUG("ensure ipfs asset result ~p", [Result]),

                    maps:put(ipfs_result, Result, Context)
            end
    end;
%% Then file exists
step(_Config, Context, _Phase, _N, ["the file", Path, "should exist"], _Body) ->
    case filelib:is_file(Path) of
        true -> Context;
        false -> damage_utils:fail(Context, {missing_file, Path})
    end;
%% Then file exists (conditional on ipfs present)
step(
    _Config, Context, _Phase, _N, ["the file", Path, "should exist (if ipfs is installed)"], _Body
) ->
    case damage_utils:exists_cmd("ipfs") of
        % skip
        false ->
            Context;
        true ->
            case filelib:is_file(Path) of
                true -> Context;
                false -> damage_utils:fail(Context, {missing_file, Path})
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
                false -> damage_utils:fail(Context, {not_executable, Path})
            end
    end.

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
