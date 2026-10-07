%%%-------------------------------------------------------------------
%%% Local/NSS user discovery without shell pipelines.
%%%
%%% getent is invoked directly (no shell), so NSS/LDAP/systemd-homed backed
%%% accounts remain visible. Output is presentation data only; greetd/PAM is
%%% authoritative for authentication and account policy.
%%%-------------------------------------------------------------------
-module(erm_dm_users).

-export([list/0, lookup/1]).

-define(DEFAULT_TIMEOUT, 3000).

list() ->
    case run_getent() of
        {ok, Bin} ->
            Users0 = [parse_line(Line) || Line <- binary:split(Bin, <<"\n">>, [global]), Line =/= <<>>],
            Users = [U || {ok, U} <- Users0, visible(U)],
            {ok, lists:sort(fun by_name/2, Users)};
        Error -> Error
    end.

lookup(Name0) ->
    Name = to_bin(Name0),
    case list() of
        {ok, Users} ->
            case [U || U <- Users, maps:get(username, U) =:= Name] of
                [User | _] -> {ok, User};
                [] -> {error, unknown_user}
            end;
        Error -> Error
    end.

run_getent() ->
    case os:find_executable("getent") of
        false -> {error, getent_not_found};
        Exec -> collect_port(open_port({spawn_executable, Exec}, [binary, exit_status, stderr_to_stdout,
                                                                  {args, ["passwd"]}]), <<>>, ?DEFAULT_TIMEOUT)
    end.

collect_port(Port, Acc, Timeout) ->
    receive
        {Port, {data, Data}} -> collect_port(Port, <<Acc/binary, Data/binary>>, Timeout);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Status}} -> {error, {getent_failed, Status}}
    after Timeout ->
        catch port_close(Port),
        {error, getent_timeout}
    end.

parse_line(Line) ->
    case binary:split(Line, <<":">>, [global]) of
        [User, _Pass, UidB, GidB, Gecos, Home, Shell] ->
            try
                {ok, #{username => User,
                       display_name => display_name(Gecos, User),
                       uid => binary_to_integer(UidB),
                       gid => binary_to_integer(GidB),
                       home => Home,
                       shell => Shell}}
            catch _:_ -> {error, malformed_passwd_entry}
            end;
        _ -> {error, malformed_passwd_entry}
    end.

visible(User) ->
    UidMin = application:get_env(erm, dm_uid_min, 1000),
    Uid = maps:get(uid, User),
    Shell = maps:get(shell, User),
    Uid >= UidMin andalso
        not lists:member(Shell, [<<"/usr/bin/nologin">>, <<"/sbin/nologin">>, <<"/bin/false">>, <<"/usr/bin/false">>]).

display_name(<<>>, User) -> User;
display_name(Gecos, User) ->
    case binary:split(Gecos, <<",">>, []) of
        [<<>> | _] -> User;
        [Name | _] -> Name
    end.

by_name(A, B) -> maps:get(username, A) =< maps:get(username, B).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
