%%% @doc
%%% ZX Auth
%%%
%%% This module is where all the AUTH type command code lives. AUTH commands are special
%%% because they do not involve the zx_daemon at all, though they do perform network
%%% operations.
%%%
%%% All AUTH procedures terminate the runtime once complete.
%%% @end

-module(zx_auth).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([list_users/1, list_packagers/1, list_maintainers/1,
         add_packager/2,   rem_packager/2,
         add_maintainer/2, rem_maintainer/2,
         list_pending/1, list_approved/1,
         submit/1, review/1, approve/1, reject/1, accept/1,
         add_package/1,
         keychain/1, list_user_keys/1,
         add_user/1]).

-include("zx_logger.hrl").



%%% Functions

list_users(Realm)               -> list_users(1, Realm).

list_packagers(PackageString)   -> list_users(2, PackageString).

list_maintainers(PackageString) -> list_users(3, PackageString).


-spec list_users(Command, Target) -> zx:outcome()
    when Command :: 1..3,
         Target  :: zx:realm() | zx:package().

list_users(Command, Target) ->
    case uu_package_request(Command, Target) of
        {ok, Users} -> lists:foreach(fun zx_lib:print_user/1, Users);
        Error       -> Error
    end.


add_packager(Package, User)   -> su_user_request(4, Package, User).

rem_packager(Package, User)   -> su_user_request(5, Package, User).

add_maintainer(Package, User) -> su_user_request(6, Package, User).

rem_maintainer(Package, User) -> su_user_request(7, Package, User).


-spec list_pending(PackageString :: string()) -> zx:outcome().
%% @private
%% List the versions of a package that are pending review. The package name is input by
%% the user as a string of the form "otpr-zomp" and the output is a list of full
%% package IDs, printed one per line to stdout (like "otpr-zomp-3.2.2").

list_pending(PackageString) ->
    Command = 8,
    case uu_package_request(Command, PackageString) of
        {ok, Versions} -> lists:foreach(fun print_version/1, Versions);
        Error          -> Error
    end.

print_version(Tuple) ->
    {ok, VersionString} = zx_lib:version_to_string(Tuple),
    io:format("~ts~n", [VersionString]).


-spec list_approved(zx:realm()) -> zx:outcome().
%% @private
%% List the package ids of all packages waiting in the resign queue for the given realm,
%% printed to stdout one per line.

list_approved(Realm) ->
    {ok, Realms} = zx_daemon:list(),
    case lists:member(Realm, Realms) of
        true  -> list_approved2(Realm);
        false -> {error, bad_realm}
    end.

list_approved2(Realm) ->
    Command = 9,
    case make_uu_request(Command, Realm) of
        {ok, PackageIDs} ->
            Print =
                fun({Name, Version}) ->
                    {ok, PackageString} = zx_lib:package_string({Realm, Name, Version}),
                    io:format("~ts~n", [PackageString])
                end,
            lists:foreach(Print, PackageIDs);
        Error ->
            Error
    end.


-spec submit(ZspPath :: file:filename()) -> zx:outcome().
%% @private
%% Submit a package to the appropriate "prime" server for the given realm.

submit(ZspPath) ->
    case file:read_file(ZspPath) of
        {ok, ZspBin} -> submit2(ZspBin);
        Error        -> Error
    end.

submit2(ZspBin) ->
    case zx_zsp:verify(ZspBin) of
        ok    -> submit3(ZspBin);
        Error -> Error
    end.

submit3(ZspBin) ->
    {ok, #{package_id := {Realm, Name, Version}, key_name := KeyName}}
        = zx_zsp:meta(ZspBin),
    UserName = select_auth(Realm),
    case zx_daemon:get_key(private, {Realm, KeyName}) of
        {ok, DKey} ->
            Payload = {Realm, UserName, KeyName, {Name, Version}},
            submit4(Payload, Realm, ZspBin, DKey);
        Error ->
            Message =
                "The private half of the key used to sign this package is not present "
                "on the local system.~n"
                "Import it and try again or do `zx resign ZspPath`.~n",
            ok = io:format(Message),
            Error
    end.

submit4(Payload, Realm, ZspBin, DKey) ->
    case connect(Realm) of
        {ok, Socket} -> submit5(Socket, Payload, ZspBin, DKey);
        Error        -> Error
    end.

submit5(Socket, Payload, ZspBin, DKey) ->
    Command = 10,
    Request = pack_and_sign(Command, Payload, DKey),
    ok = gen_tcp:send(Socket, <<"ZOMP AUTH 1:", Request/binary>>),
    case zx_net:tx(Socket, ZspBin) of
        ok              -> done(Socket);
        {error, Reason} -> done(Socket, Reason)
    end.


-spec review(PackageString :: string()) -> zx:outcome().

review(PackageString) ->
    case zx_lib:package_id(PackageString) of
        {ok, PackageID} -> review2(PackageID);
        Error           -> Error
    end.

review2(PackageID = {Realm, _, _}) ->
    case connect(Realm) of
        {ok, Socket} -> review3(PackageID, Socket);
        Error        -> Error
    end.

review3(PackageID, Socket) ->
    Command = 11,
    TermBin = term_to_binary(PackageID),
    Request = <<0:24, Command:8, TermBin/binary>>,
    ok = gen_tcp:send(Socket, <<"ZOMP AUTH 1:", Request/binary>>),
    receive
        {tcp, Socket, <<0:1, 0:7>>} -> review4(PackageID, Socket);
        {tcp, Socket, Bin}          -> done(Socket, Bin);
        {tcp_closed, Socket}        -> {error, tcp_closed}
        after 5000                  -> done(Socket, timeout)
    end.

review4(PackageID, Socket) ->
    case zx_net:rx(Socket) of
        {ok, ZspBin} ->
            ok = zx_net:disconnect(Socket),
            review5(PackageID, ZspBin);
        {error, Reason} ->
            done(Socket, Reason)
    end.

review5(PackageID, ZspBin) ->
    {ok, Requested} = zx_lib:package_string(PackageID),
    case zx_zsp:meta(ZspBin) of
        {ok, #{package_id := PackageID}} ->
            zx_zsp:extract(ZspBin, cwd);
        {ok, #{package_id := UnexpectedID}} ->
            {ok, Unexpected} = zx_lib:package_string(UnexpectedID),
            Message = "Requested ~ts, but inside was ~ts! Aborting.",
            ok = log(warning, Message, [Requested, Unexpected]),
            {error, "Wrong package received.", 29};
        Error ->
            Error
    end.


approve(Package) -> su_package_request(12, Package).

reject(Package)  -> su_package_request(13, Package).


-spec accept(ZspPath :: file:filename()) -> zx:outcome().

accept(ZspPath) ->
    case file:read_file(ZspPath) of
        {ok, ZspBin} -> accept2(ZspBin);
        Error        -> Error
    end.

accept2(ZspBin) ->
    case zx_zsp:meta(ZspBin) of
        {ok, Meta} -> accept3(ZspBin, Meta);
        error      -> {error, bad_package}
    end.

accept3(ZspBin, Meta = #{package_id := {Realm, _, _}}) ->
    case connect_auth(Realm) of
        {ok, AuthConn} -> accept4(ZspBin, Meta, AuthConn);
        Error          -> Error
    end.

accept4(ZspBin, Meta = #{key_name := KeyName}, AuthConn = {_, KeyName, Key, _, _}) ->
    case zx_zsp:verify(ZspBin, Key) of
        true ->
            accept5(ZspBin, Meta, AuthConn);
        false ->
            Message =
                "~nALERT!~n"
                "This package is not signed with the key it claims!~n"
                "Resign this package with `zx resign [ZspPath]` to fix the problem.~n",
            ok = io:format(Message),
            {error, bad_sig}
    end;
accept4(_, #{key_name := PackageKey}, {_, UserKey, _, _, _}) ->
    Message =
        "~nERROR: BAD KEY~n"
        "The package signature key and your auth key do not match.~n"
        "PackageKey: ~tp~n"
        "UserKey   : ~tp~n"
        "Resign this package with `zx resign [ZspPath]` or select the same key~n",
    ok = io:format(Message, [PackageKey, UserKey]),
    {error, bad_key}.

accept5(ZspBin,
        Meta = #{package_id := {_, Name, Version}, key_name := KeyName},
        {UserName, KeyName, Key, SSTag, Socket}) ->
    Command = 14,
    ReqMeta = {{Name, Version}, Meta, byte_size(ZspBin)},
    Message = {SSTag, UserName, KeyName, ReqMeta},
    Request = pack_and_sign(Command, Message, Key),
    ok = gen_tcp:send(Socket, <<0:8, Request/binary>>),
    ok = inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, <<0:8>>} -> accept6(ZspBin, Socket);
        {tcp, Socket, Bin}     -> done(Socket, Bin);
        {tcp_closed, Socket}   -> {error, tcp_closed}
        after 5000             -> done(Socket, timeout)
    end.

accept6(ZspBin, Socket) ->
    ok = zx_net:tx(Socket, ZspBin),
    done(Socket).


add_package(PackageString) ->
    case zx_lib:package_id(PackageString) of
        {ok, {R, N, {z, z, z}}} ->
            {ok, Realms} = zx_daemon:list(),
            case lists:member(R, Realms) of
                true  -> add_package2({R, N});
                false -> {error, bad_realm}
            end;
        {ok, _} ->
            {error, "Must not include a version number.", 1};
        Error ->
            Error
    end.

add_package2(Target) ->
    Realm = element(1, Target),
    case connect_auth(Realm) of
        {ok, AuthConn} -> add_package3(Target, AuthConn);
        Error          -> Error
    end.

add_package3(Target, {UserName, KeyName, Key, Tag, Socket}) ->
    Command = 15,
    Payload = {Tag, UserName, KeyName, Target},
    Request = pack_and_sign(Command, Payload, Key),
    ok = gen_tcp:send(Socket, <<0:8, Request/binary>>),
    done(Socket).


-spec add_user(file:filename()) -> zx:outcome().

add_user(ZPUF) ->
    case file:read_file(ZPUF) of
        {ok, Bin} -> add_user2(Bin);
        Error     -> Error
    end.

add_user2(Bin) ->
    case zx_lib:b_to_t(Bin) of
        {ok, {UserInfo, KeyData}} -> add_user3(UserInfo, KeyData);
        {ok, _}                   -> {error, "Malformed user file.", 1};
        error                     -> {error, "Bad user file.", 1}
    end.

add_user3(UserInfo, KeyData) ->
    Realm = proplists:get_value(realm, UserInfo),
    case prep_auth(Realm) of
        {ok, AuthData = {_, KeyName, Key}} ->
            UserData = {proplists:get_value(username, UserInfo),
                        proplists:get_value(realname, UserInfo),
                        proplists:get_value(contact_info, UserInfo),
                        [sign_and_sterilize(KeyName, Key, KD) || KD <- KeyData]},
            add_user4(Realm, UserData, AuthData);
        Error ->
            Error
    end.

add_user4(Realm, UserData, AuthData) ->
    case connect(Realm) of
        {ok, Socket} -> make_su_request3(16, Realm, UserData, AuthData, Socket);
        Error        -> Error
    end.


-spec list_user_keys(zx:user_id()) -> zx:outcome().

list_user_keys(UserID) -> make_uu_request(17, UserID).


keychain(KeyID) ->
    Command = 19,
    Realm = element(1, KeyID),
    case make_uu_request(Command, KeyID) of
        {ok, KeyData} -> keychain2(Realm, KeyData);
        Error         -> Error
    end.

keychain2(Realm, [{UserName, Key = {_, {{SigKeyName, Sig}, Bin}, none}} | Rest]) ->
    {ok, SigKey} = zx_daemon:get_key(public, {Realm, SigKeyName}),
    true = zx_key:verify(Bin, Sig, SigKey),
    ok = zx_daemon:register_key({Realm, UserName}, Key),
    keychain2(Realm, Rest);
keychain2(_, []) ->
    ok.


%%% Generic Request Forms

uu_package_request(Command, PackageString) ->
    case zx_lib:package_id(PackageString) of
        {ok, {Realm, Name, _}} -> make_uu_request(Command, {Realm, Name});
        Error                  -> Error
    end.


-spec make_uu_request(Command, Target) -> zx:outcome()
    when Command :: 1..3 | 8 | 9 | 11 | 17 | 22,
         Target  :: zx:realm() | zx:package() | zx:package_id() | zx:user_id().

make_uu_request(Command, Target) when is_tuple(Target) ->
    make_uu_request2(Command, element(1, Target), Target);
make_uu_request(Command, Target) when is_list(Target) ->
    make_uu_request2(Command, Target, Target).

make_uu_request2(Command, Realm, Target) ->
    case connect(Realm) of
        {ok, Socket} -> make_uu_request3(Command, Target, Socket);
        Error        -> Error
    end.

make_uu_request3(Command, Target, Socket) ->
    TermBin = term_to_binary(Target),
    Request = <<"ZOMP AUTH 1:", 0:24, Command:8, TermBin/binary>>,
    ok = gen_tcp:send(Socket, Request),
    done(Socket).


-spec su_user_request(Command, Package, User)-> zx:outcome()
    when Command :: 4..7,
         Package :: string(),
         User    :: zx:user_name().

su_user_request(Code, Package, User) ->
    case zx_lib:package_id(Package) of
        {ok, {Realm, Name, {z, z, z}}} -> make_su_request(Code, Realm, {Name, User});
        Error                          -> Error
    end.


-spec su_package_request(Code :: 11 | 12, Package :: string()) -> zx:outcome().

su_package_request(Code, Package) ->
    case zx_lib:package_id(Package) of
        {ok, {Realm, Name, Version}} -> make_su_request(Code, Realm, {Name, Version});
        Error                        -> Error
    end.


-spec make_su_request(Command, Realm, Data) -> zx:outcome()
    when Command :: 4..7 | 10 | 12 | 13 | 16 | 18,
         Realm   :: zx:realm(),
         Data    :: term().

make_su_request(Command, Realm, Data) ->
    case prep_auth(Realm) of
        {ok, AuthData} -> make_su_request2(Command, Realm, Data, AuthData);
        Error          -> Error
    end.

make_su_request2(Command, Realm, Data, AuthData) ->
    case connect(Realm) of
        {ok, Socket} -> make_su_request3(Command, Realm, Data, AuthData, Socket);
        Error        -> Error
    end.

make_su_request3(Command, Realm, Data, {Signatory, KeyName, Key}, Socket) ->
    Payload = {Realm, Signatory, KeyName, Data},
    Request = pack_and_sign(Command, Payload, Key),
    ok = gen_tcp:send(Socket, <<"ZOMP AUTH 1:", Request/binary>>),
    done(Socket).



%%% Utility Functions

-spec prep_auth(Realm) -> {User, KeyName, Key}
    when Realm   :: zx:realm(),
         User    :: zx:user_id(),
         KeyName :: zx:key_id(),
         Key     :: term().
%% @private
%% Loads the appropriate User, KeyID and reads in a registered key for use in
%% connect_auth/4.

prep_auth(Realm) ->
    UserName = select_auth(Realm),
    case zx_local:select_private_key({Realm, UserName}) of
        {ok, {KeyName, Key}} ->
            {ok, {UserName, KeyName, Key}};
        error ->
            ok = log(error, "No private key exists for user ~tp.", [UserName]),
            {error, no_key}
    end.


pack_and_sign(Command, Payload, Key) ->
    Bin = term_to_binary(Payload),
    Signed = <<Command:8, Bin/binary>>,
    Sig = zx_key:sign(Signed, Key),
    SSize = byte_size(Sig),
    <<SSize:24, Sig/binary, Signed/binary>>.


sign_and_sterilize(SigKeyName, SigKey, {Name, {_, Der}, _}) ->
    Sig = zx_key:sign(Der, SigKey),
    {Name, {{SigKeyName, Sig}, Der}, none}.



%%% Connectiness with prime

-spec select_auth(zx:realm()) -> zx:user_name().

select_auth(Realm) ->
    Pattern = filename:join(zx_lib:path(etc, Realm), "*.user"),
    LocalUsers = [filename:basename(UN, ".user") || UN <- filelib:wildcard(Pattern)],
    case LocalUsers of
        [] ->
            Message =
                "A user record is required to complete this action. Creating now...",
            ok = log(info, Message),
            zx_local:create_user(Realm);
        [UserName] ->
            UserName;
        UserNames ->
            Message = "Under what user's authority are you taking this action?~n",
            ok = io:format(Message),
            zx_tty:select_string(UserNames)
    end.


-spec connect_auth(Realm) -> Result
    when Realm    :: zx:realm(),
         Result   :: {ok, AuthConn}
                   | {error, Reason},
         AuthConn :: {UserName   :: zx:user_name(),
                      KeyName    :: zx:key_name(),
                      Key        :: term(),
                      SSTag      :: zx:ss_tag(),
                      Socket     :: gen_tcp:socket()},
         Reason   :: term().
%% @private
%% Connect to one of the servers in the realm constellation.

connect_auth(Realm) ->
    case zx_lib:load_realm_conf(Realm) of
    {ok, RealmConf} ->
        connect_auth2(Realm, RealmConf);
    Error ->
        ok = log(error, "Realm ~160tp is not configured.", [Realm]),
        Error
    end.

connect_auth2(Realm, RealmConf) ->
    case prep_auth(Realm) of
        {ok, UserData} -> connect_auth3(Realm, RealmConf, UserData);
        Error          -> Error
    end.

connect_auth3(Realm, RealmConf, UserData) ->
    {Host, Port} = maps:get(prime, RealmConf),
    Options = [{packet, 4}, {mode, binary}, {active, once}],
    case gen_tcp:connect(Host, Port, Options, 5000) of
        {ok, Socket} ->
            connect_auth4(Socket, Realm, UserData);
        Error = {error, E} ->
            ok = log(warning, "Connection problem: ~160tp", [E]),
            {error, Error}
    end.

connect_auth4(Socket, Realm, UD = {UserName, KeyName, Key}) ->
    Null = 0,
    Now = os:timestamp(),
    Payload = {Realm, Now, UserName, KeyName},
    NullRequest = pack_and_sign(Null, Payload, Key),
    ok = gen_tcp:send(Socket, <<"ZOMP AUTH 1:", NullRequest/binary>>),
    receive
        {tcp, Socket, <<0:8, Bin/binary>>} -> connect_auth5(Socket, UD, Bin);
        {tcp, Socket, Bin}                 -> done(Socket, Bin);
        {tcp_closed, Socket}               -> {error, tcp_closed}
        after 5000                         -> done(Socket, timeout)
    end.

connect_auth5(Socket, {UserName, KeyName, Key}, Bin) ->
    case zx_lib:b_to_ts(Bin) of
        {ok, Tag} -> {ok, {UserName, KeyName, Key, Tag, Socket}};
        error     -> done(Socket, bad_response)
    end.


connect(Realm) ->
    case zx_lib:load_realm_conf(Realm) of
        {ok, RealmConf} ->
            {Host, Port} = maps:get(prime, RealmConf),
            Options = [{packet, 4}, {mode, binary}, {nodelay, true}, {active, once}],
            gen_tcp:connect(Host, Port, Options, 5000);
        Error ->
            ok = log(error, "Realm ~160tp is not configured.", [Realm]),
            Error
    end.


done(Socket) ->
    ok = inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, <<0:1, 0:7>>} ->
            zx_net:disconnect(Socket);
        {tcp, Socket, <<0:1, 0:7, Bin/binary>>} ->
            ok = zx_net:disconnect(Socket),
            case zx_lib:b_to_ts(Bin) of
                error -> {error, bad_response};
                Term  -> Term
            end;
        {tcp, Socket, Bin} ->
            ok = zx_net:disconnect(Socket),
            {error, zx_net:err_in(Bin)};
        {tcp_closed, Socket} ->
            {error, tcp_closed}
        after 5000 ->
            done(Socket, timeout)
    end.


done(Socket, Reason) ->
    ok = zx_net:disconnect(Socket),
    case is_binary(Reason) of
        true  -> {error, zx_net:err_in(Reason)};
        false -> {error, Reason}
    end.
