%% Local, read-only Linux production baseline. No caller-selected targets,
%% filenames, callbacks, policy relaxations, secret retrieval or shell execution.
%% A self-check is not remote attestation and cannot prove the host is uncompromised.
-module(damage_node_security).
-license("Apache-2.0").
-include_lib("kernel/include/file.hrl").
-export([verify/2, inspect/0]).

-ifdef(TEST).
-export([parse_status/1, parse_core_limit/1, parse_tcp/2, decode_address/2,
         loopback/1, assess/1, private_file/2, disabled_setting/1,
         listener_result/1, write_report/2, bounded/2]).
-endif.

-define(MAX_READ, 1048576).
-define(MAX_FDS, 65536).
-define(TIMEOUT_MS, 10000).
-define(ARTIFACT, "node-security.json").

-spec verify(proplists:proplist(), map()) -> map().
verify(Config, Context) ->
    %% The module-level role on steps_verification is enforced by the runner;
    %% repeat the existing authoritative check for direct step calls as well.
    case is_admin(Context) of
        false -> Context#{fail => <<"Node administrator required">>};
        true ->
            %% Always measure afresh. In particular, never accept a report,
            %% pass flag, policy override or target supplied through context.
            Report = inspect(),
            C1 = Context#{node_security_report => Report},
            case write_report(Config, Report) of
                ok ->
                    case maps:get(passed, Report) of
                        true -> C1;
                        false -> C1#{fail => failure_message(Report)}
                    end;
                {error, _} ->
                    C1#{fail => <<"Node security evidence could not be written; "
                        "the check cannot pass. Inspect the trusted run directory.">>}
            end
    end.

is_admin(Context) ->
    try steps_utils:is_admin(Context) =:= true catch _:_ -> false end.

%% Safe shell diagnostic for a trusted operator. Does not write artifacts.
%% Only fixed IDs, statuses and remediation text leave the collector.
-spec inspect() -> map().
inspect() ->
    Checks = case os:type() of
        {unix, linux} ->
            case bounded(fun collect/0, ?TIMEOUT_MS) of
                {ok, Snapshot} -> assess(Snapshot);
                {error, timeout} -> [finding(collector, unknown, timeout,
                    <<"Local inspection exceeded its deadline; do not treat it as a pass.">>)];
                {error, _} -> [finding(collector, unknown, unavailable,
                    <<"Local inspection is unavailable; check the node runtime and procfs.">>)]
            end;
        _ -> [finding(platform, unknown, unsupported_platform,
            <<"This baseline requires Linux procfs; no checks were attested on this platform.">>)]
    end,
    #{schema_version => 1, policy => <<"linux-local-loopback-v1">>,
      scope => <<"running_node_local_observation">>,
      checked_at => erlang:system_time(second),
      passed => Checks =/= [] andalso lists:all(fun acceptable/1, Checks),
      checks => Checks}.

acceptable(#{status := passed}) -> true;
acceptable(#{status := not_applicable}) -> true;
acceptable(_) -> false.

%% Link the collector to its caller, so a cancelled/killed execution cannot leave
%% it behind. All ordinary exceptions are caught inside the collector. Timeout
%% unlinks before killing and waits for DOWN, avoiding late mailbox messages.
bounded(Fun, Timeout) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_opt(fun() ->
        Reply = try {ok, Fun()} catch _:_ -> {error, unavailable} end,
        unlink(Parent),
        Parent ! {Ref, Reply}
    end, [link, monitor]),
    receive
        {Ref, Reply} ->
            unlink(Pid),
            erlang:demonitor(Mon, [flush]),
            Reply;
        {'DOWN', Mon, process, Pid, _} ->
            unlink(Pid),
            {error, unavailable}
    after Timeout ->
        unlink(Pid),
        exit(Pid, kill),
        %% A dirty NIF may delay termination. Never wait without a bound for
        %% cleanup after the observation deadline has already expired.
        receive {'DOWN', Mon, process, Pid, _} -> ok
        after 1000 -> erlang:demonitor(Mon, [flush]) end,
        receive {Ref, _} -> ok after 0 -> ok end,
        {error, timeout}
    end.

collect() ->
    Status = case read_bounded("/proc/self/status") of
        {ok, Bin} -> parse_status(Bin);
        _ -> #{}
    end,
    Uid = case maps:get(uid, Status, unavailable) of
        {ok, [_, _, _, FsUid]} -> {ok, FsUid};
        _ -> {error, unavailable}
    end,
    Net = try network() catch _:_ -> #{} end,
    Status#{
        core_limit => case read_bounded("/proc/self/limits") of
            {ok, Limits} -> parse_core_limit(Limits);
            _ -> {error, unavailable}
        end,
        core_collector => core_collector(),
        crash_suppressed => os:getenv("ERL_CRASH_DUMP_SECONDS") =:= "0" orelse
            os:getenv("ERL_CRASH_DUMP_BYTES") =:= "0",
        credential_environment_clear => lists:all(fun env_absent/1, [
            "DAMAGE_SECRET_KEY", "DAMAGE_NSECBUNKER_VAULT_PASSPHRASE",
            "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
            "GITHUB_TOKEN", "GH_TOKEN"
        ]),
        cookie_argument_clear => init:get_argument(setcookie) =:= error,
        keystore => storage_file(keystore_path, Uid),
        secrets_database => storage_file(secrets_dets_path, Uid),
        beam_tcp => maps:get(beam_tcp, Net, {unknown, unavailable}),
        epmd_tcp => maps:get(epmd_tcp, Net, {unknown, unavailable}),
        secure_cookie_setting => application:get_env(damage, cookie_secure, true),
        code_reload => disabled_setting(application:get_env(damage, code_reload)),
        operator_hotcode => disabled_setting(application:get_env(damage, operator_hotcode)),
        reload_process_absent => whereis(damage_reload) =:= undefined,
        legacy_sync_absent => not lists:keymember(sync, 1, application:which_applications())
    }.

core_collector() ->
    case read_bounded("/proc/sys/kernel/core_pattern") of
        {ok, Pattern} ->
            case string:trim(Pattern) of
                <<"|", _/binary>> -> {unknown, piped_collector_requires_independent_evidence};
                <<>> -> {unknown, unavailable};
                _ -> {passed, no_piped_core_collector}
            end;
        _ -> {unknown, unavailable}
    end.

env_absent(Name) ->
    case os:getenv(Name) of false -> true; "" -> true; _ -> false end.

%% Configuration is observed, never changed. Missing/ambiguous enable switches
%% are unknown rather than inferred as disabled. Only tuple/proplist config.
disabled_setting({ok, Options}) when is_list(Options) ->
    case lists:all(fun(X) -> is_tuple(X) andalso tuple_size(X) =:= 2 end, Options) of
        true ->
            case [V || {enabled, V} <- Options] of
                [false] -> {ok, true};
                [true] -> {ok, false};
                [dev] -> {ok, false};
                _ -> {error, unavailable}
            end;
        false -> {error, unavailable}
    end;
disabled_setting(_) -> {error, unavailable}.

assess(S) ->
    [
        rule(process_uid, maps:get(uid, S, unavailable),
            fun(Uids) -> length(Uids) =:= 4 andalso lists:all(fun(N) -> N > 0 end, Uids) end,
            root_identity, <<"Run the service under a dedicated non-root Unix account.">>),
        rule(process_capabilities, maps:get(caps, S, unavailable),
            fun(Caps) -> length(Caps) =:= 4 andalso lists:all(fun(N) -> N =:= 0 end, Caps) end,
            capabilities_present, <<"Drop effective, permitted, inheritable and ambient capabilities.">>),
        rule(no_new_privileges, maps:get(nnp, S, unavailable), fun(N) -> N =:= 1 end,
            not_enabled, <<"Apply NoNewPrivileges=yes (or equivalent) before starting the service.">>),
        rule(private_umask, maps:get(umask, S, unavailable),
            fun(N) -> (N band 8#077) =:= 8#077 end,
            broad_creation_permissions, <<"Start the service with UMask=0077 (or a stricter umask).">>),
        rule(core_file_size_limit, maps:get(core_limit, S, unavailable), fun(N) -> N =:= 0 end,
            core_limit_not_zero, <<"Set LimitCORE=0. Separately audit piped core collectors: this limit alone does not disable them.">>),
        result_rule(core_collector, maps:get(core_collector, S, {unknown, unavailable}),
            <<"A piped kernel core handler can bypass RLIMIT_CORE. Verify its effective disabled-storage policy separately; this baseline cannot attest that handler.">>),
        bool_rule(beam_crash_dump_setting, maps:get(crash_suppressed, S, unavailable),
            crash_dump_not_explicitly_disabled,
            <<"Set ERL_CRASH_DUMP_SECONDS=0 or ERL_CRASH_DUMP_BYTES=0 in the service environment.">>),
        bool_rule(credential_environment, maps:get(credential_environment_clear, S, unavailable),
            credential_variable_present,
            <<"Remove the checked password/cloud/release credentials from the service environment after secure bootstrap; rotate exposed values.">>),
        bool_rule(cookie_argument, maps:get(cookie_argument_clear, S, unavailable),
            setcookie_argument_present,
            <<"Use protected cookie-file provisioning rather than -setcookie, including in argument files.">>),
        result_rule(node_keystore, maps:get(keystore, S, {unknown, unavailable}), storage_hint()),
        result_rule(secrets_database, maps:get(secrets_database, S, {unknown, unavailable}), storage_hint()),
        result_rule(beam_tcp_listeners, maps:get(beam_tcp, S, {unknown, unavailable}),
            <<"For this local-only profile bind every BEAM TCP listener to loopback and use a same-host reverse proxy. This includes Erlang distribution.">>),
        result_rule(epmd_tcp_listener, maps:get(epmd_tcp, S, {unknown, unavailable}),
            <<"Bind EPMD to loopback or stop unused EPMD listeners. This is a network-namespace observation, not a firewall test.">>),
        bool_rule(secure_cookie_setting, maps:get(secure_cookie_setting, S, unavailable),
            secure_cookies_disabled,
            <<"Set damage.cookie_secure=true. Separately verify actual browser cookies and HTTPS at the public edge.">>),
        reload_rule(S)
    ].

storage_hint() ->
    <<"Use the secrets module's resolved storage paths. Require a nonempty regular file owned by the service UID, owner-read only or owner-read/write, one hard link, a private immediate parent and trusted non-writable ancestors; reject symlinks.">>.

reload_rule(S) ->
    Hint = <<"Explicitly set code_reload and operator_hotcode to [{enabled,false}] and stop the automatic reloader/legacy Sync process through the approved deployment procedure.">>,
    Values = [maps:get(code_reload, S, unavailable), maps:get(operator_hotcode, S, unavailable)],
    Running = maps:get(reload_process_absent, S, unavailable) =:= false orelse
        maps:get(legacy_sync_absent, S, unavailable) =:= false,
    case Running orelse lists:member({ok, false}, Values) of
        true -> finding(automatic_code_reload, failed, enabled, Hint);
        false ->
            case Values =:= [{ok, true}, {ok, true}] andalso
                maps:get(reload_process_absent, S, unavailable) =:= true andalso
                maps:get(legacy_sync_absent, S, unavailable) =:= true of
                true -> finding(automatic_code_reload, passed, disabled, Hint);
                false -> finding(automatic_code_reload, unknown, policy_not_explicit, Hint)
            end
    end.

rule(Id, {ok, Value}, Predicate, Failure, Hint) ->
    try Predicate(Value) of
        true -> finding(Id, passed, controls_satisfied, Hint);
        false -> finding(Id, failed, Failure, Hint)
    catch _:_ -> finding(Id, unknown, unavailable, Hint) end;
rule(Id, _, _, _, Hint) -> finding(Id, unknown, unavailable, Hint).

bool_rule(Id, Value, Failure, Hint) when is_boolean(Value) ->
    rule(Id, {ok, Value}, fun(V) -> V end, Failure, Hint);
bool_rule(Id, _, _, Hint) -> finding(Id, unknown, unavailable, Hint).

result_rule(Id, {Status, Reason}, Hint) when
    (Status =:= passed orelse Status =:= failed orelse Status =:= unknown orelse
        Status =:= not_applicable), is_atom(Reason) -> finding(Id, Status, Reason, Hint);
result_rule(Id, _, Hint) -> finding(Id, unknown, unavailable, Hint).

finding(Id, Status, Reason, Hint) ->
    #{id => Id, status => Status, reason => Reason, remediation => Hint}.

failure_message(#{checks := Checks}) ->
    Bad = [atom_to_binary(maps:get(id, C), utf8) || C <- Checks, not acceptable(C)],
    iolist_to_binary([<<"Node security baseline did not pass: ">>,
        lists:join(<<", ">>, Bad), <<". See node-security.json for redacted findings.">>]).

%% Read a bounded procfs payload without retaining arbitrary process data.
read_bounded(Path) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Io} ->
            try
                case file:read(Io, ?MAX_READ + 1) of
                    {ok, Bin} when byte_size(Bin) =< ?MAX_READ -> {ok, Bin};
                    eof -> {ok, <<>>};
                    _ -> {error, unavailable}
                end
            after file:close(Io) end;
        _ -> {error, unavailable}
    end.

parse_status(Bin) ->
    #{uid => status_numbers(Bin, <<"Uid">>, 10, 4),
      caps => combine_numbers([status_numbers(Bin, K, 16, 1) || K <-
          [<<"CapEff">>, <<"CapPrm">>, <<"CapInh">>, <<"CapAmb">>]]),
      nnp => one_number(status_numbers(Bin, <<"NoNewPrivs">>, 10, 1)),
      umask => one_number(status_numbers(Bin, <<"Umask">>, 8, 1))}.

status_numbers(Bin, Key, Base, Count) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    Values = [V || Line <- Lines, [K, V] <- [binary:split(Line, <<":">>)], K =:= Key],
    case Values of
        [Value] ->
            Tokens = words(Value),
            case length(Tokens) =:= Count of
                true -> parse_numbers(Tokens, Base);
                false -> {error, unavailable}
            end;
        _ -> {error, unavailable}
    end.

parse_numbers(Tokens, Base) ->
    try
        Pattern = case Base of 8 -> <<"^[0-7]{1,8}$">>;
            10 -> <<"^[0-9]{1,20}$">>; 16 -> <<"^[0-9A-Fa-f]{1,16}$">> end,
        true = lists:all(fun(T) -> re:run(T, Pattern, [{capture, none}]) =:= match end, Tokens),
        {ok, [binary_to_integer(T, Base) || T <- Tokens]}
    catch _:_ -> {error, unavailable} end.

combine_numbers(Values) ->
    case lists:all(fun(V) -> case V of {ok, [_]} -> true; _ -> false end end, Values) of
        true -> {ok, [N || {ok, [N]} <- Values]};
        false -> {error, unavailable}
    end.

one_number({ok, [N]}) -> {ok, N};
one_number(_) -> {error, unavailable}.

parse_core_limit(Bin) ->
    Values = [Rest || Line <- binary:split(Bin, <<"\n">>, [global]),
        [<<"Max">>, <<"core">>, <<"file">>, <<"size">> | Rest] <- [words(Line)]],
    case Values of
        [[<<"unlimited">>, _, <<"bytes">>]] -> {ok, unlimited};
        [[Soft, _, <<"bytes">>]] -> one_number(parse_numbers([Soft], 10));
        _ -> {error, unavailable}
    end.

words(Bin) -> re:split(string:trim(Bin), <<"[ \\t]+">>, [{return, binary}, trim]).

storage_file(Function, {ok, Uid}) ->
    try
        %% These are the existing, exported path resolvers, not secret getters.
        %% No guessed legacy filenames and no fallback to BDD-context paths.
        {module, secrets} = code:ensure_loaded(secrets),
        true = erlang:function_exported(secrets, Function, 0),
        private_file(apply(secrets, Function, []), Uid)
    catch _:_ -> {unknown, storage_path_unavailable} end;
storage_file(_, _) -> {unknown, process_identity_unavailable}.

private_file(Path0, Uid) when is_integer(Uid), Uid >= 0 ->
    try
        Path1 = case Path0 of
            B when is_binary(B), byte_size(B) > 0, byte_size(B) =< 4096 -> unicode:characters_to_list(B);
            L when is_list(L), length(L) > 0, length(L) =< 4096 -> L
        end,
        true = not lists:member(0, Path1),
        true = not lists:member("..", filename:split(Path1)),
        Path = filename:absname(Path1),
        Parent = filename:dirname(Path),
        case check_ancestors(Parent, Uid, true) of
            ok -> check_secret_file(file:read_link_info(Path), Uid);
            Other -> Other
        end
    catch _:_ -> {unknown, storage_path_unavailable} end;
private_file(_, _) -> {unknown, process_identity_unavailable}.

check_secret_file({ok, #file_info{type = regular, uid = Uid, mode = Mode,
        size = Size, links = 1}}, Uid) ->
    case Size > 0 andalso (Mode band 8#7177) =:= 0 andalso (Mode band 8#400) =/= 0 of
        true -> {passed, private_file};
        false -> {failed, file_permissions_or_empty}
    end;
check_secret_file({ok, #file_info{type = symlink}}, _) -> {failed, symlink_forbidden};
check_secret_file({ok, _}, _) -> {failed, file_type_owner_or_links};
check_secret_file({error, enoent}, _) -> {failed, required_file_missing};
check_secret_file(_, _) -> {unknown, file_metadata_unavailable}.

check_ancestors(Path, Uid, Immediate) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory, uid = Owner, mode = Mode}} ->
            TrustedOwner = Owner =:= Uid orelse Owner =:= 0,
            %% A root-owned sticky ancestor such as /tmp may contain a private
            %% owned subtree. The immediate parent must still be private.
            SafeWrites = (Mode band 8#022) =:= 0 orelse
                (not Immediate andalso Owner =:= 0 andalso (Mode band 8#1000) =/= 0),
            PrivateParent = not Immediate orelse (Mode band 8#077) =:= 0,
            case TrustedOwner andalso SafeWrites andalso PrivateParent of
                false -> {failed, unsafe_parent_directory};
                true ->
                    case filename:dirname(Path) of
                        Path -> ok;
                        Next -> check_ancestors(Next, Uid, false)
                    end
            end;
        {ok, #file_info{type = symlink}} -> {failed, symlink_forbidden};
        {ok, _} -> {failed, unsafe_parent_directory};
        _ -> {unknown, parent_metadata_unavailable}
    end.

%% Read actual socket tables and correlate listener inodes to this BEAM's FDs.
%% Configuration values alone do not prove what address is currently bound.
network() ->
    {ok, Before} = socket_inodes(),
    {ok, V4} = read_bounded("/proc/self/net/tcp"),
    {ok, V6} = read_bounded("/proc/self/net/tcp6"),
    {ok, L4} = parse_tcp(V4, inet),
    {ok, L6} = parse_tcp(V6, inet6),
    {ok, After} = socket_inodes(),
    Owned = maps:from_list([{I, true} || I <- Before ++ After]),
    Listeners = L4 ++ L6,
    Beam = [L || #{inode := I} = L <- Listeners, maps:is_key(I, Owned)],
    Epmd = case epmd_port() of
        {ok, Port} ->
            case [L || #{port := P} = L <- Listeners, P =:= Port] of
                [] -> {not_applicable, no_epmd_listener_observed};
                Es -> listener_result(Es)
            end;
        _ -> {unknown, epmd_port_unavailable}
    end,
    #{beam_tcp => listener_result(Beam), epmd_tcp => Epmd}.

socket_inodes() ->
    case file:list_dir("/proc/self/fd") of
        {ok, Fds} when length(Fds) =< ?MAX_FDS -> socket_inodes(Fds, []);
        _ -> {error, unavailable}
    end.
socket_inodes([], Acc) -> {ok, Acc};
socket_inodes([Fd | Rest], Acc) ->
    case file:read_link(filename:join("/proc/self/fd", Fd)) of
        {ok, "socket:[" ++ Tail} ->
            case re:run(Tail, "^([0-9]{1,20})\\]$", [{capture, [1], binary}]) of
                {match, [Digits]} -> socket_inodes(Rest, [binary_to_integer(Digits) | Acc]);
                _ -> {error, unavailable}
            end;
        {ok, _} -> socket_inodes(Rest, Acc);
        {error, enoent} -> socket_inodes(Rest, Acc); % FD closed during observation
        _ -> {error, unavailable}
    end.

epmd_port() ->
    case os:getenv("ERL_EPMD_PORT") of
        false -> {ok, 4369};
        Text ->
            case parse_numbers([list_to_binary(Text)], 10) of
                {ok, [N]} when N > 0, N =< 65535 -> {ok, N};
                _ -> {error, unavailable}
            end
    end.

parse_tcp(Bin, Family) ->
    try
        [Header | Lines] = [L || L <- binary:split(Bin, <<"\n">>, [global]), string:trim(L) =/= <<>>],
        true = binary:match(Header, <<"local_address">>) =/= nomatch,
        {ok, lists:append([tcp_line(words(L), Family) || L <- Lines])}
    catch _:_ -> {error, unavailable} end.

tcp_line(Fields, Family) when length(Fields) >= 10 ->
    State = lists:nth(4, Fields),
    true = re:run(State, <<"^[0-9A-Fa-f]{2}$">>, [{capture, none}]) =:= match,
    case binary_to_integer(State, 16) of
        16#0a ->
            [Address, PortHex] = binary:split(lists:nth(2, Fields), <<":">>),
            true = byte_size(PortHex) =:= 4,
            Port = binary_to_integer(PortHex, 16),
            true = Port > 0 andalso Port =< 65535,
            {ok, [Inode]} = parse_numbers([lists:nth(10, Fields)], 10),
            [#{address => decode_address(Address, Family), port => Port, inode => Inode}];
        _ -> []
    end.

%% procfs prints each IPv4/IPv6 32-bit word in the host's native byte order.
decode_address(Hex, inet) when byte_size(Hex) =:= 8 ->
    <<Word:32/native-unsigned-integer>> = binary:decode_hex(Hex),
    <<A, B, C, D>> = <<Word:32/big-unsigned-integer>>,
    {A, B, C, D};
decode_address(Hex, inet6) when byte_size(Hex) =:= 32 ->
    <<A:32/native-unsigned-integer, B:32/native-unsigned-integer,
      C:32/native-unsigned-integer, D:32/native-unsigned-integer>> = binary:decode_hex(Hex),
    <<W1:16, W2:16, W3:16, W4:16, W5:16, W6:16, W7:16, W8:16>> = <<A:32, B:32, C:32, D:32>>,
    {W1, W2, W3, W4, W5, W6, W7, W8}.

loopback({127, B, C, D}) -> octets([B, C, D]);
loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
loopback({0, 0, 0, 0, 0, 16#ffff, H, L}) when
    is_integer(H), is_integer(L), H >= 16#7f00, H =< 16#7fff, L >= 0, L =< 65535 -> true;
loopback(_) -> false.
octets(Ns) -> lists:all(fun(N) -> is_integer(N) andalso N >= 0 andalso N =< 255 end, Ns).

listener_result(Listeners) ->
    case lists:all(fun(#{address := Address}) -> loopback(Address) end, Listeners) of
        true -> {passed, no_nonloopback_listener_observed};
        false -> {failed, nonloopback_listener_present}
    end.

%% The directory is supplied by the trusted runner Config, not Context. Exclusive
%% creation refuses an existing file or symlink, and never truncates old evidence.
%% A failed write prevents a pass. Only the fixed redacted report is serialized.
write_report(Config, Report) ->
    try
        Dir0 = proplists:get_value(run_dir, Config),
        Dir = case Dir0 of B when is_binary(B), byte_size(B) > 0 -> unicode:characters_to_list(B);
            L when is_list(L), L =/= [] -> L end,
        {ok, #file_info{type = directory}} = file:read_link_info(Dir),
        Path = filename:join(Dir, ?ARTIFACT),
        Bytes = jsx:encode(Report),
        case file:open(Path, [write, binary, raw, exclusive]) of
            {ok, Io} ->
                try
                    ok = file:change_mode(Path, 8#600),
                    ok = file:write(Io, Bytes),
                    ok = file:sync(Io)
                after ok = file:close(Io) end;
            _ -> {error, evidence_write_failed}
        end
    catch _:_ -> {error, evidence_write_failed} end.
