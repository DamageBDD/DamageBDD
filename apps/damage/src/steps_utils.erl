-module(steps_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([step/6]).
-export([is_admin/1]).
-export([parse_table/1]).
-export([parse_step_body/1]).

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
