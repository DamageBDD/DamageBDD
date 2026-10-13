%%% @doc
%%% ZX Library
%%%
%%% This module contains a set of common-use functions internal to the ZX project.
%%% These functions are subject to radical change, are not publicly documented and
%%% should NOT be used by other projects.
%%%
%%% The public interface to the externally useful parts of this library are maintained
%%% in the otpr-zxxl package.
%%% @end

-module(zx_lib).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([zomp_dir/0, find_zomp_dir/0,
         path/1, path/2, path/3, path/4, ppath/2,
         new_logpath/1,
         force_dir/1, mktemp_dir/1, random_string/0,
         list_realms/0, realm_exists/1,
         get_prime/1,
         read_project_meta/0, read_project_meta/1,
         write_project_meta/1, write_project_meta/2,
         write_terms/2, exec_shell/1,
         valid_lower0_9/1, valid_label/1, valid_version/1,
         string_to_version/1, version_to_string/1,
         package_id/1, package_string/1,
         zsp_name/1, zsp_path/1,
         print_user/1,
         find_latest_compatible/2, installed/1,
         realm_conf/1, load_realm_conf/1,
         build/0,
         rm_rf/1, rm/1,
         enqueue_unique/2,
         b_to_t/1, b_to_ts/1]).

-include("zx_logger.hrl").



%%% Functions

-spec zomp_dir() -> file:filename().
%% @doc
%% Return the path to the Zomp/ZX installation directory.

zomp_dir() ->
    case os:getenv("ZOMP_DIR") of
        false ->
            ZompDir = find_zomp_dir(),
            true = os:putenv("ZOMP_DIR", ZompDir),
            ZompDir;
        ZompDir ->
            ZompDir
    end.


-spec find_zomp_dir() -> file:filename().
%% @private
%% Check the host OS and return the absolute path to the zomp filesystem root.

find_zomp_dir() ->
    case os:type() of
        {unix, _} ->
            Home = os:getenv("HOME"),
            Dir = "zomp",
            filename:join(Home, Dir);
        {win32, _} ->
            Home = os:getenv("LOCALAPPDATA"),
            Dir = "zomp",
            filename:join(Home, Dir)
    end.


-spec path(zx:core_dir()) -> file:filename().
%% @private
%% Return the top-level path of the given type in the Zomp/ZX system.

path(etc) -> filename:join(zomp_dir(), "etc");
path(var) -> filename:join(zomp_dir(), "var");
path(tmp) -> filename:join(zomp_dir(), "tmp");
path(log) -> filename:join(zomp_dir(), "log");
path(key) -> filename:join(zomp_dir(), "key");
path(zsp) -> filename:join(zomp_dir(), "zsp");
path(lib) -> filename:join(zomp_dir(), "lib").


-spec path(zx:core_dir(), zx:realm()) -> file:filename().
%% @private
%% Return the realm-level path of the given type in the Zomp/ZX system.

path(Type, Realm) ->
    filename:join(path(Type), Realm).


-spec path(zx:core_dir(), zx:realm(), zx:name()) -> file:filename().
%% @private
%% Return the package-level path of the given type in the Zomp/ZX system.

path(Type, Realm, Name) ->
    filename:join([path(Type), Realm, Name]).


-spec path(zx:core_dir(), zx:realm(), zx:name(), zx:version()) -> file:filename().
%% @private
%% Return the version-specific level path of the given type in the Zomp/ZX system.

path(Type, Realm, Name, Version) ->
    {ok, VersionString} = version_to_string(Version),
    filename:join([path(Type), Realm, Name, VersionString]).


-spec ppath(zx:core_dir(), zx:package_id()) -> file:filename().
%% @private
%% An alias for path/3,4, but more convenient when needing a path from a closed
%% package_id().

ppath(Type, {Realm, Name, {z, z, z}}) ->
    path(Type, Realm, Name);
ppath(Type, {Realm, Name, Version}) ->
    path(Type, Realm, Name, Version);
ppath(Type, {Realm, Name}) ->
    path(Type, Realm, Name).


-spec new_logpath(zx:package_id()) -> file:filename().

new_logpath(PackageID = {Realm, Name, _}) ->
    Dir = path(log, Realm, Name),
    ok = force_dir(Dir),
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    Format = "~4..0w~2..0w~2..0w_~2..0w~2..0w~2..0w",
    Timestamp = io_lib:format(Format, [Year, Month, Day, Hour, Minute, Second]),
    {ok, PackageString} = package_string(PackageID),
    FileName = string:join([Timestamp, PackageString, "log"], "."),
    filename:join(Dir, FileName).


-spec force_dir(Path) -> Result
    when Path :: file:filename(),
         Result :: ok
                 | {error, file:posix()}.
%% @private
%% Guarantee a directory path is created if it is possible to create or if it already
%% exists.

force_dir(Path) ->
    case filelib:is_dir(Path) of
        true  -> ok;
        false -> filelib:ensure_dir(filename:join(Path, "foo"))
    end.


-spec mktemp_dir(Package) -> Result
   when Package :: zx:package(),
        Result  :: {ok, TempDir   :: file:filename()}
                 | {error, Reason :: file:posix()}.

mktemp_dir({Realm, Name}) ->
    Rand = random_string(),
    TempDir = filename:join(path(tmp, Realm, Name), Rand),
    case force_dir(TempDir) of
        ok    -> {ok, TempDir};
        Error -> Error
    end.


-spec random_string() -> string().

random_string() ->
    integer_to_list(binary:decode_unsigned(crypto:strong_rand_bytes(8)), 36).


-spec list_realms() -> [zx:realm()].
%% @private
%% Check the filesystem for etc/[Realm Name]/realm.conf files.

list_realms() ->
    Pattern = filename:join([path(etc), "*", "realm.conf"]),
    [filename:basename(filename:dirname(C)) || C <- filelib:wildcard(Pattern)].


-spec realm_exists(zx:realm()) -> boolean().

realm_exists(Realm) ->
    lists:member(Realm, list_realms()).


-spec get_prime(Realm) -> Result
    when Realm  :: zx:realm(),
         Result :: {ok, zx:host()}
                 | {error, file:posix()}.
%% @private
%% Check the given Realm's config file for the current prime node and return it.

get_prime(Realm) ->
    case load_realm_conf(Realm) of
        {ok, RealmMeta} -> maps:find(prime, RealmMeta);
        Error           -> Error
    end.


-spec read_project_meta() -> Result
    when Result :: {ok, zx_zsp:meta()}
                 | {error, file:posix()}
                 | {error, file:posix(), non_neg_integer()}.
%% @private
%% @equiv read_meta(".")

read_project_meta() ->
    read_project_meta(".").


-spec read_project_meta(Dir) -> Result
    when Dir    :: file:filename(),
         Result :: {ok, zx_zsp:meta()}
                 | {error, file:posix()}
                 | {error, file:posix(), non_neg_integer()}.
%% @private
%% Read the `zomp.meta' file from the indicated directory, if possible.

read_project_meta(Dir) ->
    Path = filename:join(Dir, "zomp.meta"),
    case file:consult(Path) of
        {ok, Data} ->
            Meta = maps:merge(zx_zsp:new_meta(), maps:from_list(Data)),
            {ok, Meta};
        {error, enoent} ->
            {error, "No project zomp.meta file. Wrong directory? Not initialized?", 0};
        Error ->
            ok = log(error, "Read from zomp.meta failed with: ~tw", [Error]),
            Error
    end.


-spec write_project_meta(Meta) -> Result
    when Meta   :: zx_zsp:meta(),
         Result :: ok
                 | {error, Reason},
         Reason :: badarg
                 | terminated
                 | system_limit
                 | file:posix().
%% @private
%% @equiv write_meta(".")

write_project_meta(Meta) ->
    write_project_meta(".", Meta).


-spec write_project_meta(Dir, Meta) -> ok
    when Dir  :: file:filename(),
         Meta :: zx_zsp:meta().
%% @private
%% Write the contents of the provided meta structure (a map these days) as a list of
%% Erlang K/V terms.

write_project_meta(Dir, Meta) ->
    Path = filename:join(Dir, "zomp.meta"),
    Data = maps:to_list(maps:merge(zx_zsp:new_meta(), Meta)),
    write_terms(Path, Data).


-spec write_terms(Filename, Terms) -> Result
    when Filename :: file:filename(),
         Terms    :: [term()],
         Result   :: ok
                   | {error, Reason},
         Reason   :: badarg
                   | terminated
                   | system_limit
                   | file:posix().
%% @private
%% Provides functionality roughly inverse to file:consult/1.

write_terms(Filename, List) ->
    Format = fun(Term) -> io_lib:format("~tp.~n", [Term]) end,
    Text = lists:map(Format, List),
    file:write_file(Filename, Text).


-spec exec_shell(CMD) -> ok
    when CMD :: string().
%% @private
%% Print the output of an os:cmd/1 event only if there is any.

exec_shell(CMD) ->
    case os:cmd(CMD) of
        "" ->
            ok;
        Out ->
            Trimmed = string:trim(Out, trailing, "\r\n"),
            log(info, "os:cmd(~tw) -> ~ts", [CMD, Trimmed])
    end.


-spec valid_lower0_9(string()) -> boolean().
%% @private
%% Check whether a provided string is a valid lower0_9.

valid_lower0_9([Char | Rest]) when $a =< Char, Char =< $z ->
    valid_lower0_9(Rest, Char);
valid_lower0_9(_) ->
    false.


-spec valid_lower0_9(String, Last) -> boolean()
    when String :: string(),
         Last   :: char().

valid_lower0_9([$_ | _], $_) ->
    false;
valid_lower0_9([Char | Rest], _)
        when $a =< Char, Char =< $z;
             $0 =< Char, Char =< $9;
             Char == $_ ->
    valid_lower0_9(Rest, Char);
valid_lower0_9([], _) ->
    true;
valid_lower0_9(_, _) ->
    false.


-spec valid_label(string()) -> boolean().
%% @private
%% Check whether a provided string is a valid label.

valid_label([Char | Rest]) when $a =< Char, Char =< $z ->
    valid_label(Rest, Char);
valid_label(_) ->
    false.


-spec valid_label(String, Last) -> boolean()
    when String :: string(),
         Last   :: char().

valid_label([$. | _], $.) ->
    false;
valid_label([$_ | _], $_) ->
    false;
valid_label([$- | _], $-) ->
    false;
valid_label([Char | Rest], _)
        when $a =< Char, Char =< $z;
             $0 =< Char, Char =< $9;
             Char == $_; Char == $-;
             Char == $. ->
    valid_label(Rest, Char);
valid_label([], _) ->
    true;
valid_label(_, _) ->
    false.


-spec valid_version(zx:version()) -> boolean().

valid_version({z, z, z}) ->
    true;
valid_version({X, z, z})
        when is_integer(X), X >= 0 ->
    true;
valid_version({X, Y, z})
        when is_integer(X), X >= 0,
             is_integer(Y), Y >= 0 ->
    true;
valid_version({X, Y, Z})
        when is_integer(X), X >= 0,
             is_integer(Y), Y >= 0,
             is_integer(Z), Z >= 0 ->
    true;
valid_version(_) ->
    false.


-spec string_to_version(VersionString) -> Result
    when VersionString :: string(),
         Result        :: {ok, zx:version()}
                        | {error, invalid_version_string}.
%% @private
%% @equiv string_to_version(string(), "", {z, z, z})

string_to_version(String) ->
    string_to_version(String, "", {z, z, z}).


-spec string_to_version(String, Acc, Version) -> Result
    when String  :: string(),
         Acc     :: list(),
         Version :: zx:version(),
         Result  :: {ok, zx:version()}
                  | {error, invalid_version_string}.
%% @private
%% Accepts a full or partial version string of the form `X.Y.Z', `X.Y' or `X' and
%% returns a zomp-type version tuple or crashes on bad data.

string_to_version([Char | Rest], Acc, Version) when $0 =< Char andalso Char =< $9 ->
    string_to_version(Rest, [Char | Acc], Version);
string_to_version("", "", Version) ->
    {ok, Version};
string_to_version(_, "", _) ->
    {error, invalid_version_string};
string_to_version([$. | Rest], Acc, {z, z, z}) ->
    X = list_to_integer(lists:reverse(Acc)),
    string_to_version(Rest, "", {X, z, z});
string_to_version([$. | Rest], Acc, {X, z, z}) ->
    Y = list_to_integer(lists:reverse(Acc)),
    string_to_version(Rest, "", {X, Y, z});
string_to_version([], Acc, {z, z, z}) ->
    X = list_to_integer(lists:reverse(Acc)),
    {ok, {X, z, z}};
string_to_version([], Acc, {X, z, z}) ->
    Y = list_to_integer(lists:reverse(Acc)),
    {ok, {X, Y, z}};
string_to_version([], Acc, {X, Y, z}) ->
    Z = list_to_integer(lists:reverse(Acc)),
    {ok, {X, Y, Z}};
string_to_version(_, _, _) ->
    {error, invalid_version_string}.


-spec version_to_string(zx:version()) -> {ok, string()} | {error, invalid_version}.
%% @private
%% Inverse of string_to_version/3.

version_to_string({z, z, z}) ->
    {ok, ""};
version_to_string({X, z, z}) when is_integer(X) ->
    {ok, integer_to_list(X)};
version_to_string({X, Y, z}) when is_integer(X), is_integer(Y) ->
    DeepList = lists:join($., [integer_to_list(Element) || Element <- [X, Y]]),
    FlatString = lists:flatten(DeepList),
    {ok, FlatString};
version_to_string({X, Y, Z}) when is_integer(X), is_integer(Y), is_integer(Z) ->
    DeepList = lists:join($., [integer_to_list(Element) || Element <- [X, Y, Z]]),
    FlatString = lists:flatten(DeepList),
    {ok, FlatString};
version_to_string(_) ->
    {error, invalid_version}.


-spec package_id(string()) -> {ok, zx:package_id()} | {error, invalid_package_string}.
%% @private
%% Converts a proper package_string to a package_id().
%% This function takes into account missing version elements.
%% Examples:
%%   `{ok, {"foo", "bar", {1, 2, 3}}} = package_id("foo-bar-1.2.3")'
%%   `{ok, {"foo", "bar", {1, 2, z}}} = package_id("foo-bar-1.2")'
%%   `{ok, {"foo", "bar", {1, z, z}}} = package_id("foo-bar-1")'
%%   `{ok, {"foo", "bar", {z, z, z}}} = package_id("foo-bar")'
%%   `{error, invalid_package_string} = package_id("Bad-Input")'

package_id(String) ->
    case dash_split(String) of
        {ok, [Realm, Name, VersionString]} ->
            package_id(Realm, Name, VersionString);
        {ok, [A, B]} ->
            case valid_lower0_9(B) of
                true  -> package_id(A, B, "");
                false -> package_id("otpr", A, B)
            end;
        {ok, [Name]} ->
            package_id("otpr", Name, "");
        error ->
            {error, invalid_package_string}
    end.


-spec dash_split(string()) -> {ok, [string()]} | error.
%% @private
%% An explicit, strict token split that ensures invalid names with leading, trailing or
%% double dashes don't slip through (a problem discovered with using string:tokens/2
%% and string:lexemes/2.

dash_split(String) ->
    dash_split(String, "", []).


dash_split([$- | Rest], Acc, Elements) ->
    Element = lists:reverse(Acc),
    dash_split(Rest, "", [Element | Elements]);
dash_split([Char | Rest], Acc, Elements) ->
    dash_split(Rest, [Char | Acc], Elements);
dash_split("", Acc, Elements) ->
    Element = lists:reverse(Acc),
    {ok, lists:reverse([Element | Elements])};
dash_split(_, _, _) ->
    error.


-spec package_id(Realm, Name, VersionString) -> Result
    when Realm         :: zx:realm(),
         Name          :: zx:name(),
         VersionString :: string(),
         Result        :: {ok, zx:package_id()}
                        | {error, invalid_package_string}.

package_id(Realm, Name, VersionString) ->
    ValidRealm = valid_lower0_9(Realm),
    ValidName  = valid_lower0_9(Name),
    MaybeVersion = string_to_version(VersionString),
    case {ValidRealm, ValidName, MaybeVersion} of
        {true, true, {ok, Version}} -> {ok, {Realm, Name, Version}};
        _                           -> {error, invalid_package_string}
    end.


-spec package_string(zx:package_id()) -> {ok, string()} | {error, invalid_package_id}.
%% @private
%% Map an PackageID to a correct string representation.
%% This function takes into account missing version elements.
%% Examples:
%%   `{ok, "foo-bar-1.2.3"}      = package_string({"foo", "bar", {1, 2, 3}})'
%%   `{ok, "foo-bar-1.2"}        = package_string({"foo", "bar", {1, 2, z}})'
%%   `{ok, "foo-bar-1"}          = package_string({"foo", "bar", {1, z, z}})'
%%   `{ok, "foo-bar"}            = package_string({"foo", "bar", {z, z, z}})'
%%   `{error, invalid_package_id = package_string({"Bad", "Input"})'

package_string({Realm, Name, {z, z, z}}) ->
    ValidRealm = valid_lower0_9(Realm),
    ValidName  = valid_lower0_9(Name),
    case ValidRealm and ValidName of
        true ->
            PackageString = lists:flatten(lists:join($-, [Realm, Name])),
            {ok, PackageString};
        false ->
            {error, invalid_package_id}
    end;
package_string({Realm, Name, Version}) ->
    ValidRealm = valid_lower0_9(Realm),
    ValidName  = valid_lower0_9(Name),
    MaybeVersionString = version_to_string(Version),
    case {ValidRealm, ValidName, MaybeVersionString} of
        {true, true, {ok, VerString}} ->
            PackageString =  lists:flatten(lists:join($-, [Realm, Name, VerString])),
            {ok, PackageString};
        _ ->
            {error, invalid_package_id}
    end;
package_string({Realm, Name}) ->
    package_string({Realm, Name, {z, z, z}});
package_string(_) ->
    {error, invalid_package_id}.


-spec zsp_name(PackageID) -> ZspFileName
    when PackageID   :: zx:package_id(),
         ZspFileName :: file:filename().
%% @private
%% Map a PackageID to its correct .zsp package file name.

zsp_name(PackageID) ->
    {ok, PackageString} = package_string(PackageID),
    PackageString ++ ".zsp".


-spec zsp_path(zx:package_id()) -> file:filename().

zsp_path(PackageID = {Realm, _, _}) ->
    filename:join(path(zsp, Realm), zsp_name(PackageID)).


-spec print_user({zx:user_name(), zx:real_name(), [zx:contact_info()]}) -> ok.

print_user({UserName, RealName, ContactInfo}) ->
    case proplists:get_value("email", ContactInfo, none) of
        none  -> io:format("~ts (~ts)~n", [UserName, RealName]);
        Email -> io:format("~ts (~ts) <~ts>~n", [UserName, RealName, Email])
    end.


-spec find_latest_compatible(Version, Versions) -> Result
    when Version  :: zx:version(),
         Versions :: [zx:version()],
         Result   :: exact
                   | {ok, zx:version()}
                   | not_found.
%% @private
%% Find the latest compatible version from a list of versions. Returns the atom
%% `exact' in the case a full version is specified and it exists, the tuple
%% `{ok, Version}' in the case a compatible version was found against a partial
%% version tuple, and the atom `not_found' in the case no compatible version exists
%% in the list. Will fail with `not_found' if the input `Version' is not a valid
%% `zx:version()' tuple.

find_latest_compatible(Version, Versions) ->
    Descending = lists:reverse(lists:sort(Versions)),
    latest_compatible(Version, Descending).


latest_compatible(_, []) ->
    not_found;
latest_compatible({z, z, z}, Versions) ->
    {ok, hd(Versions)};
latest_compatible({X, z, z}, Versions) ->
    case lists:keyfind(X, 1, Versions) of
        false   -> not_found;
        Version -> {ok, Version}
    end;
latest_compatible({X, Y, z}, Versions) ->
    NotMatch = fun({Q, W, _}) -> not (Q == X andalso W == Y) end,
    case lists:dropwhile(NotMatch, Versions) of
        [] -> not_found;
        Vs -> {ok, hd(Vs)}
    end;
latest_compatible(Version, Versions) ->
    case lists:member(Version, Versions) of
        true  -> exact;
        false -> not_found
    end.


-spec installed(zx:package_id()) -> boolean().
%% @private
%% True to its name, tells whether a package's install directory is found.

installed(PackageID) ->
    filelib:is_dir(ppath(lib, PackageID)).


-spec realm_conf(Realm) -> Path
    when Realm :: string(),
         Path  :: file:filename().
%% @private
%% Given a realm name return the path to its conf file.

realm_conf(Realm) ->
    filename:join(path(etc, Realm), "realm.conf").


-spec load_realm_conf(Realm) -> Result
    when Realm     :: zx:realm(),
         Result    :: {ok, RealmConf}
                    | {error, Reason},
         RealmConf :: map(),
         Reason    :: bad_realm
                    | badarg
                    | terminated
                    | system_limit
                    | file:posix()
                    | {Line :: integer(), Mod :: module(), Cause :: term()}.
%% @private
%% Load the config for the given realm.

load_realm_conf(Realm) ->
    Path = realm_conf(Realm),
    case file:consult(Path) of
        {ok, C} ->
            {ok, maps:from_list(C)};
        {error, enoent} ->
            {error, bad_realm};
        Error ->
            ok = log(warning, "Loading realm conf ~ts failed with: ~tw", [Path, Error]),
            Error
    end.


-spec build() -> ok.
%% @private
%% Run any local `zxmake' script needed by the project for non-Erlang code (if present),
%% then add the local `ebin/' directory to the runtime search path, and finally build
%% the Erlang part of the project with make:all/0 according to the local `Emakefile'.

build() ->
    ZxMake = "zxmake",
    ok =
        case filelib:is_regular(ZxMake) of
            true ->
                Out = os:cmd(ZxMake),
                log(info, Out);
            false ->
                ok
        end,
    true = code:add_patha(filename:absname("ebin")),
    up_to_date = make:all(),
    ok.


-spec rm_rf(Target) -> Result
    when Target :: file:filename(),
         Result :: ok | {error, file:posix()}.
%% @private
%% Recursively remove files and directories. Equivalent to `rm -rf'.
%% Does not return an error on a nonexistant path.

rm_rf(Target) ->
    case filelib:is_dir(Target) of
        true ->
            Pattern = filename:join(Target, "**"),
            Contents = lists:reverse(lists:sort(filelib:wildcard(Pattern))),
            Targets = rm_filter(Contents),
            ok = lists:foreach(fun rm/1, Targets),
            case file:list_dir(Target) of
                {ok, []} -> file:del_dir(Target);
                _        -> ok
            end;
        false ->
            case filelib:is_regular(Target) of
                true  -> file:delete(Target);
                false -> ok
            end
    end.

rm_filter(Contents) ->
    P1 = path(lib, "otpr", "zx"),
    P2 = path(lib, "otpr", "zomp"),
    F1 = fun(C) -> not lists:prefix(P1, C) end,
    F2 = fun(C) -> not lists:prefix(P2, C) end,
    lists:filter(F2, lists:filter(F1, Contents)).


-spec rm(file:filename()) -> ok | {error, file:posix()}.
%% @private
%% An omnibus delete helper.

rm(Path) ->
    case filelib:is_dir(Path) of
        true  -> file:del_dir(Path);
        false -> file:delete(Path)
    end.


-spec enqueue_unique(term(), queue:queue()) -> queue:queue().

enqueue_unique(Term, Queue) ->
    case queue:member(Term, Queue) of
        true  -> Queue;
        false -> queue:in(Term, Queue)
    end.


-spec b_to_t(binary()) -> {ok, term()} | error.
%% @private
%% A wrapper for the binary_to_term/1 BIF to hide the try..catch mess in the places we
%% don't want to crash on funky input.

b_to_t(Binary) ->
    try
        Term = binary_to_term(Binary),
        {ok, Term}
    catch
        error:badarg -> error
    end.


-spec b_to_ts(binary()) -> {ok, term()} | error.
%% A wrapper for the binary_to_term/2 BIF to hide the try..catch mess in the places we
%% don't want to crash on funky input.

b_to_ts(Binary) ->
    try
        {ok, binary_to_term(Binary, [safe])}
    catch
        error:badarg -> error
    end.
