%% Nonsecret operator policy for the automatic AWS subsystem.
-module(ecai_aws_setup_config).
-compile({no_auto_import, [get/0]}).
-export([get/0, public/1, allowed/1, ready/0, python/0, script/0, state_path/0, origin/0]).

get() ->
    #{<<"regions">> => application:get_env(ecai, aws_setup_regions,
          [<<"ap-southeast-2">>, <<"us-east-1">>, <<"eu-west-1">>]),
      <<"coordinator_role_arn">> => text(application:get_env(ecai, compute_aws_coordinator_role_arn, <<>>)),
      <<"worker_image">> => text(application:get_env(ecai, aws_setup_worker_image, <<>>)),
      <<"worker_command">> => application:get_env(ecai, aws_setup_worker_command, []),
      <<"probe_enabled">> => application:get_env(ecai, aws_setup_probe_enabled, false)}.

public(Owner) ->
    C = get(),
    #{<<"enabled">> => allowed(Owner), <<"ready">> => allowed(Owner) andalso ready() =:= ok,
      <<"blockers">> => blockers(), <<"regions">> => maps:get(<<"regions">>, C),
      <<"coordinator_role_arn">> => maps:get(<<"coordinator_role_arn">>, C),
      <<"worker_image">> => maps:get(<<"worker_image">>, C),
      <<"probe_enabled">> => maps:get(<<"probe_enabled">>, C),
      <<"credential_ttl_seconds">> => 900, <<"index_dispatch">> => <<"pending">>,
      <<"version">> => <<"automatic-aws-v1">>}.

allowed(Owner) ->
    application:get_env(ecai, aws_setup_enabled, false) =:= true andalso
    case application:get_env(ecai, aws_setup_accounts, []) of
        [] -> true;
        Accounts when is_list(Accounts) -> lists:member(Owner, Accounts);
        _ -> false
    end.
ready() -> case blockers() of [] -> ok; _ -> {error, node_setup_required} end.
blockers() ->
    C = get(),
    Checks = [
        {application:get_env(ecai, aws_setup_enabled, false) =:= true, <<"Automatic AWS setup is disabled by the node operator.">>},
        {match(maps:get(<<"coordinator_role_arn">>, C), <<"^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$">>), <<"Configure compute_aws_coordinator_role_arn and the node's matching AWS workload identity.">>},
        {match(maps:get(<<"worker_image">>, C), <<"^[A-Za-z0-9._/-]+@sha256:[a-f0-9]{64}$">>), <<"Configure a trusted digest-pinned aws_setup_worker_image.">>},
        {valid_command(maps:get(<<"worker_command">>, C)), <<"Configure the approved worker command as a list of binaries.">>},
        {valid_regions(maps:get(<<"regions">>, C)), <<"Configure an allowlist of supported commercial AWS regions.">>},
        {valid_origin(origin()), <<"Configure aws_setup_public_origin as the dashboard's HTTPS origin.">>},
        {python() =/= false, <<"Install Python 3 and the pinned boto3 requirements in the configured environment.">>}
    ],
    [Message || {false, Message} <- Checks].
valid_command(C) when is_list(C), length(C) > 0, length(C) =< 16 ->
    lists:all(fun(V) -> is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< 512 andalso binary:match(V, <<0>>) =:= nomatch end, C);
valid_command(_) -> false.
valid_regions(R) when is_list(R), R =/= [], length(R) =< 32 ->
    lists:all(fun(V) -> match(V, <<"^[a-z]{2}-[a-z]+-[0-9]$">>) andalso not match(V, <<"^cn-">>) end, R);
valid_regions(_) -> false.
valid_origin(O) ->
    try uri_string:parse(O) of
        #{scheme := <<"https">>, host := Host} = URI ->
            byte_size(Host) > 0 andalso not maps:is_key(userinfo, URI) andalso
            not maps:is_key(query, URI) andalso not maps:is_key(fragment, URI) andalso
            maps:get(path, URI, <<>>) =:= <<>>;
        _ -> false
    catch _:_ -> false end.
origin() -> text(application:get_env(ecai, aws_setup_public_origin, <<>>)).
python() ->
    case application:get_env(ecai, aws_setup_python, undefined) of
        undefined -> os:find_executable("python3");
        V -> case text(V) of <<"/", _/binary>> = B ->
                 case filelib:is_regular(binary_to_list(B)) of true -> binary_to_list(B); false -> false end;
                 _ -> false end
    end.
script() -> filename:join([code:priv_dir(ecai), "aws_setup", "bridge.py"]).
state_path() -> ecai_paths:normalize(application:get_env(ecai, aws_setup_state_path,
    filename:join(ecai_paths:index_state_dir(), "aws_setup.dets"))).
text(B) when is_binary(B) -> B;
text(L) when is_list(L) -> try unicode:characters_to_binary(L) catch _:_ -> <<>> end;
text(_) -> <<>>.
match(B, Pattern) when is_binary(B), byte_size(B) =< 2048 -> re:run(B, Pattern, [{capture, none}]) =:= match;
match(_, _) -> false.
