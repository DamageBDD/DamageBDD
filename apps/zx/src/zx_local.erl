%%% @doc
%%% ZX Local
%%%
%%% This module defines procedures that affect the local host and terminate on
%%% completion.
%%% @end

-module(zx_local).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([initialize/0, set_version/1,
         list_realms/0, list_packages/1, list_versions/1, list_type/1,
         latest/1, describe/1, provides/1, search/1,
         list_sysops/1,
         set_dep/1, list_deps/0, list_deps/1, drop_dep/1, verup/1, package/1,
         update_meta/0, update_app_file/0,
         import_realm/1, drop_realm/1, logpath/2,
         set_timeout/1,
         add_mirror/0,  add_mirror/1,  add_mirror/2,
         drop_mirror/0, drop_mirror/1, drop_mirror/2,
         create_project/0, template_swp/0,
         grow_a_pair/0, grow_a_pair/2, drop_key/1,
         create_user/0, export_user/1, import_user/1,
         create_realm/0, export_realm/0, export_realm/1]).

-export([create_user/1, select_private_key/1]).

-include("zx_logger.hrl").


-record(user_data,
        {realm        = none :: none | zx:realm(),
         username     = none :: none | zx:user_name(),
         realname     = none :: none | string(),
         contact_info = none :: none | [zx:contact_info()],
         keys         = none :: none | [zx:key_name()]}).

-record(realm_init,
        {realm = none  :: none | zx:realm(),
         sysop = none  :: none | #user_data{},
         url   = ""    :: none | string(),
         addr  = none  :: none | string() | inet:ip_address(),
         port  = 11311 :: none | inet:port_number()}).

-record(project,
        {type      = none :: none | app | lib | cli | gui | escript,
         license   = none :: none | none | skip | string(),
         name      = none :: none | string(),
         desc      = none :: none | string(),
         repo_url  = none :: none | string(),
         ws_url    = none :: none | string(),
         id        = none :: none | zx:package_id() | zx:name(),
         prefix    = none :: none | zx:lower0_9(),
         appmod    = none :: none | zx:lower0_9(),
         module    = none :: none | zx:lower0_9(),
         author    = none :: none | string(),
         a_email   = none :: none | string(),
         copyright = none :: none | string(),
         c_email   = none :: none | string(),
         deps      = []   :: [zx:package_id()],
         tags      = []   :: [string()],
         file_exts = []   :: [string()]}).



%%% Functions

-spec initialize() -> zx:outcome().
%% @private
%% Initialize a project in the local directory based on user input.

initialize() ->
    case filelib:is_file("zomp.meta") of
        false -> initialize(#project{});
        true  -> {error, "This project is already Zompified.", 17}
    end.

initialize(P = #project{type = none}) ->
    initialize(P#project{type = ask_project_type()});
initialize(P = #project{name = none}) ->
    initialize(P#project{name = ask_project_name()});
initialize(P = #project{type = escript}) ->
    ok = tell(warning, "escripts cannot be initialized."),
    initialize(P#project{type = ask_project_type()});
initialize(P = #project{type = lib, id = none}) ->
    initialize(P#project{id = ask_package_id()});
initialize(P = #project{id = none}) ->
    ID = {_, Name, _} = ask_package_id(),
    initialize(P#project{id = ID, appmod = Name});
initialize(P = #project{type = app, id = {_, Name, _}, prefix = none}) ->
    initialize(P#project{prefix = ask_prefix(Name)});
initialize(P = #project{type = web, id = {_, Name, _}, prefix = none}) ->
    initialize(P#project{prefix = ask_prefix(Name)});
initialize(P = #project{type = gui, id = {_, Name, _}, prefix = none}) ->
    initialize(P#project{prefix = ask_prefix(Name)});
initialize(P = #project{type = app, appmod = none}) ->
    initialize(P#project{appmod = ask_appmod()});
initialize(P = #project{type = web, appmod = none}) ->
    initialize(P#project{appmod = ask_appmod()});
initialize(P = #project{type = cli, appmod = none}) ->
    initialize(P#project{appmod = ask_appmod()});
initialize(P = #project{type = gui, appmod = none}) ->
    initialize(P#project{appmod = ask_appmod()});
initialize(P = #project{author = none, copyright = none}) ->
    {A, E} = ask_author(),
    initialize(P#project{author = A, a_email = E, copyright = A, c_email = E});
initialize(P = #project{author = none}) ->
    {Author, Email} = ask_author(),
    initialize(P#project{author = Author, a_email = Email});
initialize(P = #project{a_email = none}) ->
    initialize(P#project{a_email = ask_email_optional()});
initialize(P = #project{copyright = none}) ->
    {Holder, Email} = ask_copyright(),
    initialize(P#project{copyright = Holder, c_email = Email});
initialize(P = #project{c_email = none}) ->
    initialize(P#project{c_email = ask_email_optional()});
initialize(P = #project{license = none}) ->
    initialize(P#project{license = ask_license()});
initialize(P = #project{desc = none}) ->
    initialize(P#project{desc = ask_description()});
initialize(P = #project{repo_url = none}) ->
    initialize(P#project{repo_url = ask_url(repo)});
initialize(P = #project{ws_url = none}) ->
    initialize(P#project{ws_url = ask_url(website)});
initialize(P = #project{type      = lib,
                        license   = License,
                        name      = Name,
                        id        = ID,
                        prefix    = Prefix,
                        author    = Author,
                        a_email   = AEmail,
                        copyright = CR,
                        c_email   = CEmail,
                        repo_url  = RepoURL,
                        ws_url    = WebsiteURL,
                        desc      = Desc}) ->
    {ok, PS} = zx_lib:package_string(ID),
    Instructions =
        "~nLIBRARY DATA CONFIRMATION~n"
        "[ 1] Type                    : library~n"
        "[ 2] Project Name            : ~ts~n"
        "[ 3] Package ID              : ~ts~n"
        "[ 4] Author                  : ~ts~n"
        "[ 5] Author's Email          : ~ts~n"
        "[ 6] Copyright Holder        : ~ts~n"
        "[ 7] Copyright Holder's Email: ~ts~n"
        "[ 8] License                 : ~ts~n"
        "[ 9] Prefix                  : ~ts~n"
        "[10] Repo URL                : ~ts~n"
        "[11] Website URL             : ~ts~n"
        "[12] Description             : ~ts~n"
        "Press a number to select something to change, or [ENTER] to continue.~n",
    ok = io:format(Instructions,
                   [Name, PS,
                    Author, AEmail,
                    CR, CEmail,
                    License, Prefix,
                    RepoURL, WebsiteURL, Desc]),
    case zx_tty:get_input() of
        "1"  -> initialize(P#project{type      = none});
        "2"  -> initialize(P#project{name      = none});
        "3"  -> initialize(P#project{id        = none});
        "4"  -> initialize(P#project{author    = none});
        "5"  -> initialize(P#project{a_email   = none});
        "6"  -> initialize(P#project{copyright = none});
        "7"  -> initialize(P#project{c_email   = none});
        "8"  -> initialize(P#project{license   = none});
        "9"  -> initialize(P#project{prefix    = none});
        "10" -> initialize(P#project{repo_url  = none});
        "11" -> initialize(P#project{ws_url    = none});
        "12" -> initialize(P#project{desc      = none});
        ""   -> project_check(P, fun zompify/1, fun initialize/1);
        _    ->
            ok = zx_tty:derp(),
            initialize(P)
    end;
initialize(P = #project{type      = Type,
                        license   = License,
                        name      = Name,
                        id        = ID,
                        prefix    = Prefix,
                        appmod    = AppMod,
                        author    = Author,
                        a_email   = AEmail,
                        copyright = CR,
                        c_email   = CEmail,
                        repo_url  = RepoURL,
                        ws_url    = WebsiteURL,
                        desc      = Desc}) ->
    {ok, PS} = zx_lib:package_string(ID),
    TS =
        case Type of
            app -> "Erlang application";
            web -> "Web service";
            cli -> "CLI/terminal program";
            gui -> "GUI application"
        end,
    Instructions =
        "~nAPPLICATION DATA CONFIRMATION~n"
        "[ 1] Type                    : ~ts~n"
        "[ 2] Project Name            : ~ts~n"
        "[ 3] Package ID              : ~ts~n"
        "[ 4] Author                  : ~ts~n"
        "[ 5] Author's Email          : ~ts~n"
        "[ 6] Copyright Holder        : ~ts~n"
        "[ 7] Copyright Holder's Email: ~ts~n"
        "[ 8] License                 : ~ts~n"
        "[ 9] Prefix                  : ~ts~n"
        "[10] AppMod                  : ~ts~n"
        "[11] Repo URL                : ~ts~n"
        "[12] Website URL             : ~ts~n"
        "[13] Description             : ~ts~n"
        "Press a number to select something to change, or [ENTER] to continue.~n",
    ok = io:format(Instructions,
                   [TS, Name, PS,
                    Author, AEmail,
                    CR, CEmail,
                    License, Prefix, AppMod,
                    RepoURL, WebsiteURL, Desc]),
    case zx_tty:get_input() of
        "1"  -> initialize(P#project{type      = none});
        "2"  -> initialize(P#project{name      = none});
        "3"  -> initialize(P#project{id        = none});
        "4"  -> initialize(P#project{author    = none});
        "5"  -> initialize(P#project{a_email   = none});
        "6"  -> initialize(P#project{copyright = none});
        "7"  -> initialize(P#project{c_email   = none});
        "8"  -> initialize(P#project{license   = none});
        "9"  -> initialize(P#project{prefix    = none});
        "10" -> initialize(P#project{appmod    = none});
        "11" -> initialize(P#project{repo_url  = none});
        "12" -> initialize(P#project{ws_url    = none});
        "13" -> initialize(P#project{desc      = none});
        ""   -> project_check(P, fun zompify/1, fun initialize/1);
        _    ->
            ok = zx_tty:derp(),
            initialize(P)
    end.


project_check(P = #project{id = PackageID}, Continue, Retry) ->
    case package_exists(PackageID) of
        false ->
            Continue(P);
        true ->
            Message =
                "~nDHOH!~n"
                "Sadly this package already exists in the selected realm.~n"
                "What do?~n",
            ok = io:format(Message),
            Options = [{"Pick another name.",     1},
                       {"Continue anyway.",       2},
                       {"Abort and do it later.", 3}],
            case zx_tty:select(Options) of
                1 -> Retry(P#project{id = none});
                2 -> Continue(P);
                3 -> ok
            end;
        weather_permitting ->
            Message =
                "~n∑（｡･Д･｡）???~nHmmm...~n"
                "zx_daemon wasn't able to check whether this package already exists.~n"
                "(Network problem?)~n"
                "What do?~n",
            ok = io:format(Message),
            Options = [{"Continue anyway.",       1},
                       {"Check again.",           2},
                       {"Abort and do it later.", 3}],
            case zx_tty:select(Options) of
                1 -> Continue(P);
                2 -> Retry(P);
                3 -> ok
            end
    end.


zompify(P = #project{type      = Type,
                     name      = Name,
                     id        = ID,
                     desc      = Desc,
                     prefix    = Prefix,
                     license   = License,
                     author    = Author,
                     a_email   = AEmail,
                     copyright = CR,
                     c_email   = CEmail,
                     repo_url  = RepoURL,
                     ws_url    = WebsiteURL,
                     appmod    = AppModString,
                     module    = Module,
                     deps      = Deps}) ->
    ok = initialize_app_file(ID, AppModString, Type, Desc),
    Simple =
        #{type       => Type,
          package_id => ID,
          name       => Name,
          desc       => Desc,
          license    => License,
          author     => Author,
          a_email    => AEmail,
          copyright  => CR,
          c_email    => CEmail,
          repo_url   => RepoURL,
          ws_url     => WebsiteURL,
          deps       => Deps,
          prefix     => Prefix,
          tags       => []},
    Data =
        case Type of
            cli -> maps:put(mod, Module, Simple);
            web -> Simple#{type := app, deps => cowboy_deps()};
            _   -> Simple
        end,
    ok = zx_lib:write_project_meta(Data),
    ok = ensure_emakefile(),
    ok = ensure_license(P),
    ok = ensure_gitignore(),
    {ok, PackageString} = zx_lib:package_string(ID),
    tell("Project ~ts initialized.", [PackageString]).

cowboy_deps() ->
    Apps = [{"otpr", N} || N <- ["cowboy", "ranch", "cowlib"]],
    cowboy_deps(Apps).

cowboy_deps([App = {Realm, Name} | Apps]) ->
    {ok, Ref} = zx_daemon:latest(App),
    {ok, Ver} = zx_daemon:wait_result(Ref),
    [{Realm, Name, Ver} | cowboy_deps(Apps)];
cowboy_deps([]) ->
    [].


-spec ensure_emakefile() -> ok.

ensure_emakefile() ->
    case filelib:is_regular("Emakefile") of
        true ->
            ok;
        false ->
            Path = filename:join([os:getenv("ZX_DIR"), "templates", "Emakefile"]),
            {ok, _} = file:copy(Path, "Emakefile"),
            ok
    end.


-spec ensure_license(#project{}) -> ok.

ensure_license(#project{license = skip}) ->
    ok;
ensure_license(#project{name      = Name,
                        license   = License,
                        copyright = Holder,
                        c_email   = CEmail}) ->
    File =
        case License of
            "Apache-2.0"               -> "apache2.txt";
            "BSD-3-Clause-Attribution" -> "bsd3.txt";
            "BSD-2-Clause-FreeBSD"     -> "bsd2.txt";
            "GPL-3.0-only"             -> "gpl3.txt";
            "GPL-3.0-or-later"         -> "gpl3.txt";
            "LGPL-3.0-only"            -> "lgpl3.txt";
            "LGPL-3.0-or-later"        -> "lgpl3.txt";
            "MIT"                      -> "mit.txt";
            "ISC"                      -> "isc.txt";
            "MPL-2.0"                  -> "mpl2.txt";
            "CC0"                      -> "cc0.txt"
        end,
    {{Year, _, _}, _} = calendar:local_time(),
    Substitutions =
        [{"〘\*PROJECT NAME\*〙",     Name},
         {"〘\*YEAR\*〙",             integer_to_list(Year)},
         {"〘\*COPYRIGHT HOLDER\*〙", copyright_holder(Holder, CEmail)}],
    Path = filename:join([os:getenv("ZX_DIR"), "templates", "licenses", File]),
    {ok, Raw} = file:read_file(Path),
    UTF8 = unicode:characters_to_list(Raw, utf8),
    Cooked = substitute(UTF8, Substitutions),
    file:write_file("LICENSE", Cooked).


-spec ensure_gitignore() -> ok.

ensure_gitignore() ->
    case filelib:is_regular(".gitignore") of
        true ->
            ok;
        false ->
            Path = filename:join([os:getenv("ZX_DIR"), "templates", "gitignore"]),
            {ok, _} = file:copy(Path, ".gitignore"),
            ok
    end.


-spec update_source_vsn(zx:version()) -> ok.
%% @private
%% Use grep to tell us which files have a `-vsn' attribute and which don't.
%% Use sed to insert a line after `-module' in the files that don't have it,
%% and update the files that do.
%% This procedure is still halfway into "works for me" territory. It will take a bit
%% of survey data to know which platforms can't work with some form of something
%% in here by default (bash may need to be called explicitly, for example, or the
%% old backtick executor terms used, etc).

update_source_vsn(Version) ->
    {ok, VersionString} = zx_lib:version_to_string(Version),
    AddF = "sed -i 's/^-module(.*)\\.$/&\\n-vsn(\"~s\")./' $(grep -L '^-vsn(' src/*)",
    SubF = "sed -i 's/^-vsn(.*$/-vsn(\"~s\")./' $(grep -l '^-vsn(' src/*)",
    Add = lists:flatten(io_lib:format(AddF, [VersionString])),
    Sub = lists:flatten(io_lib:format(SubF, [VersionString])),
    _ = os:cmd(Add),
    _ = os:cmd(Sub),
    ok.


-spec update_app_vsn(zx:name(), zx:version()) -> ok.

update_app_vsn(Name, Version) ->
    {ok, VersionString} = zx_lib:version_to_string(Version),
    AppFile = filename:join("ebin", Name ++ ".app"),
    {ok, [{application, AppName, OldAppData}]} = file:consult(AppFile),
    NewAppData = lists:keystore(vsn, 1, OldAppData, {vsn, VersionString}),
    zx_lib:write_terms(AppFile, [{application, AppName, NewAppData}]).


-spec initialize_app_file(PackageID, AppMod, Type, Desc) -> ok
    when PackageID :: zx:package_id(),
         AppMod    :: module(),
         Type      :: app | cli | lib | gui,
         Desc      :: string().
%% @private
%% Update the app file or create it if it is missing.
%% TODO: If the app file is missing and an app/*.src exists, interpret that.

initialize_app_file({_, Name, Version}, AppMod, Type, Desc) ->
    {ok, VersionString} = zx_lib:version_to_string(Version),
    AppName = list_to_atom(Name),
    AppFile = filename:join("ebin", Name ++ ".app"),
    {application, AppName, RawAppData} =
        case filelib:is_regular(AppFile) of
            true ->
                {ok, [D]} = file:consult(AppFile),
                D;
            false ->
                {application,
                 AppName,
                 [{description,           Desc},
                  {registered,            []},
                  {included_applications, []},
                  {applications,          [stdlib, kernel]}]}
        end,
    Modules = list_modules(),
    Properties =
        case (Type == cli) or (Type == lib) of
            true ->
                [{vsn,     VersionString},
                 {modules, Modules}];
            false ->
                [{vsn,     VersionString},
                 {modules, Modules},
                 {mod,     {list_to_atom(AppMod), []}}]
        end,
    Store = fun(T, L) -> lists:keystore(element(1, T), 1, L, T) end,
    AppData = lists:foldl(Store, RawAppData, Properties),
    AppProfile = {application, AppName, AppData},
    ok = tell("Writing app file: ~ts", [AppFile]),
    zx_lib:write_terms(AppFile, [AppProfile]).


list_modules() -> list_modules(".").


-spec list_modules(BaseDir :: file:filename()) -> [module()].

list_modules(Dir) ->
    Target = filename:join(Dir, "**/*.erl"),
    [list_to_atom(filename:basename(F, ".erl")) || F <- filelib:wildcard(Target)].

-spec update_meta() -> zx:outcome().

update_meta() ->
    case zx_lib:read_project_meta() of
        {ok, Data} -> update_meta(Data);
        Error      -> Error
    end.

update_meta(Data = #{package_id := {_, Name, _}}) ->
    P = #project{name      = maps:get(name,      Data, Name),
                 author    = maps:get(author,    Data, ""),
                 a_email   = maps:get(a_email,   Data, ""),
                 copyright = maps:get(copyright, Data, ""),
                 c_email   = maps:get(c_email,   Data, ""),
                 repo_url  = maps:get(repo_url,  Data, ""),
                 ws_url    = maps:get(ws_url,    Data, ""),
                 desc      = maps:get(desc,      Data, ""),
                 tags      = sets:from_list(maps:get(tags,      Data, [])),
                 file_exts = sets:from_list(maps:get(file_exts, Data, []))},
    update_meta(Data, P).

update_meta(Data = #{type := gui},
            P = #project{name      = Name,
                         author    = Author,
                         a_email   = AEmail,
                         copyright = CR,
                         c_email   = CEmail,
                         repo_url  = RepoURL,
                         ws_url    = WebURL,
                         desc      = Desc,
                         tags      = Tags,
                         file_exts = Exts}) ->
    Instructions =
        "~nDESCRIPTION DATA~n"
        "[ 1] Project Name             : ~ts~n"
        "[ 2] Author                   : ~ts~n"
        "[ 3] Author's Email           : ~ts~n"
        "[ 4] Copyright Holder         : ~ts~n"
        "[ 5] Copyright Holder's Email : ~ts~n"
        "[ 6] Repo URL                 : ~ts~n"
        "[ 7] Website URL              : ~ts~n"
        "[ 8] Description              : ~ts~n"
        "[ 9] Search Tags              : ~tp~n"
        "[10] File associations        : ~tp~n"
        "Press a number to select something to change, or [ENTER] to continue.~n",
    ok = io:format(Instructions,
                   [Name,
                    Author, AEmail, CR, CEmail,
                    RepoURL, WebURL,
                    Desc, sets:to_list(Tags), sets:to_list(Exts)]),
    case zx_tty:get_input() of
        "1" ->
            update_meta(Data, P#project{name = ask_project_name()});
        "2" ->
            {A, E} = ask_author(),
            update_meta(Data, P#project{author = A, a_email = E});
        "3" ->
            update_meta(Data, P#project{a_email = ask_email_optional()});
        "4" ->
            {C, E} = ask_copyright(),
            update_meta(Data, P#project{copyright = C, c_email = E});
        "5" ->
            update_meta(Data, P#project{c_email = ask_email_optional()});
        "6" ->
            update_meta(Data, P#project{repo_url = ask_url(repo)});
        "7" ->
            update_meta(Data, P#project{ws_url = ask_url(website)});
        "8" ->
            update_meta(Data, P#project{desc = ask_description()});
        "9" ->
            update_meta(Data, P#project{tags = edit_tags(Tags)});
        "10" ->
            update_meta(Data, P#project{file_exts = edit_exts(Exts)});
        "" ->
            finalize_meta(Data, P);
        _ ->
            ok = zx_tty:derp(),
            update_meta(Data, P)
    end;
update_meta(Data,
            P = #project{name      = Name,
                         author    = Author,
                         a_email   = AEmail,
                         copyright = CR,
                         c_email   = CEmail,
                         repo_url  = RepoURL,
                         ws_url    = WebURL,
                         desc      = Desc,
                         tags      = Tags}) ->
    Instructions =
        "~nDESCRIPTION DATA~n"
        "[1] Project Name             : ~ts~n"
        "[2] Author                   : ~ts~n"
        "[3] Author's Email           : ~ts~n"
        "[4] Copyright Holder         : ~ts~n"
        "[5] Copyright Holder's Email : ~ts~n"
        "[6] Repo URL                 : ~ts~n"
        "[7] Website URL              : ~ts~n"
        "[8] Description              : ~ts~n"
        "[9] Search Tags              : ~tp~n"
        "Press a number to select something to change, or [ENTER] to continue.~n",
    ok = io:format(Instructions,
                   [Name,
                    Author, AEmail, CR, CEmail,
                    RepoURL, WebURL,
                    Desc, sets:to_list(Tags)]),
    case zx_tty:get_input() of
        "1" ->
            update_meta(Data, P#project{name = ask_project_name()});
        "2" ->
            {A, E} = ask_author(),
            update_meta(Data, P#project{author = A, a_email = E});
        "3" ->
            update_meta(Data, P#project{a_email = ask_email_optional()});
        "4" ->
            {C, E} = ask_copyright(),
            update_meta(Data, P#project{copyright = C, c_email = E});
        "5" ->
            update_meta(Data, P#project{c_email = ask_email_optional()});
        "6" ->
            update_meta(Data, P#project{repo_url = ask_url(repo)});
        "7" ->
            update_meta(Data, P#project{ws_url = ask_url(website)});
        "8" ->
            update_meta(Data, P#project{desc = ask_description()});
        "9" ->
            update_meta(Data, P#project{tags = edit_tags(Tags)});
        "" ->
            finalize_meta(Data, P);
        _ ->
            ok = zx_tty:derp(),
            update_meta(Data, P)
    end.

finalize_meta(Data = #{type := Type},
              #project{name      = Name,
                       author    = Author,
                       a_email   = AEmail,
                       copyright = CR,
                       c_email   = CEmail,
                       repo_url  = RepoURL,
                       ws_url    = WebURL,
                       desc      = Desc,
                       tags      = Tags,
                       file_exts = Exts}) ->
    Updated = Data#{name      => Name,
                    author    => Author,
                    a_email   => AEmail,
                    copyright => CR,
                    c_email   => CEmail,
                    repo_url  => RepoURL,
                    ws_url    => WebURL,
                    desc      => Desc,
                    tags      => sets:to_list(Tags),
                    file_exts => sets:to_list(Exts)},
    NewData =
        case Type == gui of
            true  -> Updated;
            false -> maps:remove(file_exts, Updated)
        end,
    ok = zx_lib:write_project_meta(NewData),
    update_app_file(NewData).


-spec update_app_file() -> zx:outcome().

update_app_file() ->
    case zx_lib:read_project_meta() of
        {ok, Meta} -> update_app_file(Meta);
        Error      -> Error
    end.

update_app_file(Meta) ->
    {_, Name, Version} = maps:get(package_id, Meta),
    Desc = maps:get(desc, Meta, ""),
    {ok, VersionString} = zx_lib:version_to_string(Version),
    AppName = list_to_atom(Name),
    AppFile = filename:join("ebin", Name ++ ".app"),
    {application, AppName, RawAppData} =
        case filelib:is_regular(AppFile) of
            true ->
                {ok, [D]} = file:consult(AppFile),
                D;
            false ->
                {application,
                 AppName,
                 [{registered,            []},
                  {included_applications, []},
                  {applications,          [stdlib, kernel]}]}
        end,
    Modules = list_modules(),
    Properties = [{description, Desc}, {vsn, VersionString}, {modules, Modules}],
    Store = fun(T, L) -> lists:keystore(element(1, T), 1, L, T) end,
    AppData = lists:foldl(Store, RawAppData, Properties),
    AppProfile = {application, AppName, AppData},
    ok = zx_lib:write_terms(AppFile, [AppProfile]),
    tell("Writing app file: ~ts", [AppFile]).


-spec set_version(VersionString) -> zx:outcome()
    when VersionString :: string().
%% @private
%% Convert a version string to a new version, sanitizing it in the process and returning
%% a reasonable error message on bad input.

set_version(VersionString) ->
    case zx_lib:string_to_version(VersionString) of
        {error, invalid_version_string} ->
            Message = "Invalid version string: ~ts",
            {error, Message, 22};
        {ok, {_, _, z}} ->
            Message = "'set version' arguments must be complete, ex: 1.2.3",
            {error, Message, 22};
        {ok, NewVersion} ->
            {ok, Meta} = zx_lib:read_project_meta(),
            {Realm, Name, OldVersion} = maps:get(package_id, Meta),
            update_version(Realm, Name, OldVersion, NewVersion, Meta)
    end.


-spec update_version(Realm, Name, OldVersion, NewVersion, OldMeta) -> ok
    when Realm      :: zx:realm(),
         Name       :: zx:name(),
         OldVersion :: zx:version(),
         NewVersion :: zx:version(),
         OldMeta    :: zx:package_meta().
%% @private
%% Update a project's `zomp.meta' file by either incrementing the indicated component,
%% or setting the version number to the one specified in VersionString.
%% This part of the procedure updates the meta and does the final write, if the write
%% turns out to be possible. If successful it will indicate to the user what was
%% changed.

update_version(Realm, Name, OldVersion, NewVersion, OldMeta) ->
    PackageID = {Realm, Name, NewVersion},
    NewMeta = maps:put(package_id, PackageID, OldMeta),
    case zx_lib:write_project_meta(NewMeta) of
        ok ->
            ok = update_source_vsn(NewVersion),
            ok = update_app_vsn(Name, NewVersion),
            {ok, OldVS} = zx_lib:version_to_string(OldVersion),
            {ok, NewVS} = zx_lib:version_to_string(NewVersion),
            tell("Version changed from ~s to ~s.", [OldVS, NewVS]);
        Error ->
            ok = tell(error, "Write to zomp.meta failed with: ~160tp", [Error]),
            Error
    end.


-spec list_realms() -> ok.
%% @private
%% List all currently configured realms.

list_realms() ->
    case zx_lib:list_realms() of
        []     -> tell(error, "Oh noes! No realms are configured!");
        Realms -> lists:foreach(fun(R) -> io:format("~ts~n", [R]) end, Realms)
    end.


-spec list_packages(zx:realm()) -> zx:outcome().
%% @private
%% Contact the indicated realm and query it for a list of registered packages and print
%% them to stdout.

list_packages(Realm) ->
    {ok, ID} = zx_daemon:list(Realm),
    case zx_daemon:wait_result(ID) of
        {ok, []}           -> tell(error, "No packages available.");
        {ok, Packages}     -> lists:foreach(print_package(Realm), Packages);
        {error, bad_realm} -> {error, "Unconfigured realm or bad realm name.", 22};
        {error, timeout}   -> {error, "Request timed out.", 62};
        {error, network}   -> {error, "Network problem connecting to realm.", 101}
    end.


-spec list_versions(PackageName :: string()) -> zx:outcome().
%% @private
%% List the available versions of the package indicated. The user enters a string-form
%% package name (such as "otpr-zomp") and the return values will be full package strings
%% of the form "otpr-zomp-1.2.3", one per line printed to stdout.

list_versions(PackageString) ->
    case zx_lib:package_id(PackageString) of
        {ok, PackageID}                 -> list_versions2(PackageID);
        {error, invalid_package_string} -> {error, "Invalid package name.", 22}
    end.


list_versions2({Realm, Name, Version}) ->
    {ok, ID} = zx_daemon:list(Realm, Name, Version),
    case zx_daemon:wait_result(ID) of
        {ok, []}             -> tell(error, "No versions available.");
        {ok, Versions}       -> lists:foreach(fun print_version/1, Versions);
        {error, bad_realm}   -> {error, "Bad realm name.", 22};
        {error, bad_package} -> {error, "Bad package name.", 22};
        {error, timeout}     -> {error, "Request timed out.", 62};
        {error, network}     -> {error, "Network problem connecting to realm.", 101}
    end.


-spec list_type(zx:package_type()) -> zx:outcome().

list_type(Type) ->
    Realms = zx_lib:list_realms(),
    MakeRequest =
        fun(Realm) ->
            {ok, ID} = zx_daemon:list_type({Realm, Type}),
            ID
        end,
    Index = [{MakeRequest(R), R} || R <- Realms],
    IDs = [element(1, I) || I <- Index],
    case zx_daemon:wait_results(IDs) of
        {ok, Results} ->
            Packages = scrub_errors(lists:sort(Index), lists:sort(Results), []),
            lists:foreach(fun print_packages/1, lists:sort(Packages));
        Error ->
            Error
    end.

scrub_errors([{ID, _} | Index], [{ID, {ok, PackageID}} | Results], Acc) ->
    scrub_errors(Index, Results, [PackageID | Acc]);
scrub_errors([{ID, Realm} | Index], [{ID, Error} | Results], Acc) ->
    ok = tell(warning, "Received weird result from realm ~tp: ~tp", [Realm, Error]),
    scrub_errors(Index, Results, Acc);
scrub_errors([], [], Acc) ->
    lists:append(Acc).


-spec latest(PackageString :: string()) -> zx:outcome().

latest(PackageString) ->
    case zx_lib:package_id(PackageString) of
        {ok, PackageID}                 -> latest2(PackageID);
        {error, invalid_package_string} -> {error, "Invalid package name.", 22}
    end.

latest2(PackageID) ->
    {ok, ID} = zx_daemon:latest(PackageID),
    case zx_daemon:wait_result(ID) of
        {ok, Version} -> print_version(Version);
        Error         -> Error
    end.


-spec describe(PackageString :: string()) -> zx:outcome().

describe(PackageString) ->
    case zx_lib:package_id(PackageString) of
        {ok, PackageID}                 -> describe2(PackageID);
        {error, invalid_package_string} -> {error, "Invalid package name.", 22}
    end.

describe2(PackageID) ->
    {ok, ID} = zx_daemon:describe(PackageID),
    case zx_daemon:wait_result(ID) of
        {ok, Description}    -> describe3(Description);
        {error, bad_realm}   -> {error, "Unconfigured realm or bad realm name.", 22};
        {error, bad_package} -> {error, "Bad package name.", 22};
        {error, bad_version} -> {error, "Bad version.", 22};
        {error, timeout}     -> {error, "Request timed out.", 62};
        {error, network}     -> {error, "Network problem connecting to realm.", 101}
    end.

describe3({description,
           PackageID, DName, Type, Desc, Author, AEmail, WebURL, RepoURL, Tags}) ->
    {ok, PackageString} = zx_lib:package_string(PackageID),
    AuthorString =
        case {Author, AEmail} of
            {"", ""} -> "";
            _        -> copyright_holder(Author, AEmail)
        end,
    Format =
        "Package : ~ts~n"
        "Name    : ~ts~n"
        "Type    : ~tp~n"
        "Desc    : ~ts~n"
        "Author  : ~ts~n"
        "Web     : ~ts~n"
        "Repo    : ~ts~n"
        "Tags    : ~tp~n",
    io:format(Format,
              [PackageString, DName, Type, Desc, AuthorString, WebURL, RepoURL, Tags]).


-spec provides(Module :: string()) -> zx:outcome().

provides(Module) ->
    Realms = zx_lib:list_realms(),
    MakeRequest =
        fun(Realm) ->
            {ok, ID} = zx_daemon:provides(Realm, Module),
            ID
        end,
    Index = [{MakeRequest(R), R} || R <- Realms],
    IDs = [element(1, I) || I <- Index],
    case zx_daemon:wait_results(IDs) of
        {ok, Results} -> print_multirealm(lists:sort(Index), lists:sort(Results));
        Error         -> Error
    end.


search(String) ->
    Realms = zx_lib:list_realms(),
    MakeRequest =
        fun(Realm) ->
            {ok, ID} = zx_daemon:search({Realm, String}),
            ID
        end,
    Index = [{MakeRequest(R), R} || R <- Realms],
    IDs = [element(1, I) || I <- Index],
    case zx_daemon:wait_results(IDs) of
        {ok, Results} -> search2(lists:sort(Index), lists:sort(Results));
        Error         -> Error
    end.

search2([{ID, Realm} | Index], [{ID, {ok, Packages}} | Results]) ->
    FormIDs = fun({Name, Versions}) -> [{Realm, Name, V} || V <- Versions] end,
    Print = fun(PackageIDs) -> lists:foreach(fun print_packages/1, PackageIDs) end,
    ok = lists:foreach(Print, lists:map(FormIDs, lists:sort(Packages))),
    search2(Index, Results);
search2([{ID, Realm} | Index], [{ID, Error} | Results]) ->
    ok = tell(warning, "Received weird result from ~p: ~p", [Realm, Error]),
    search2(Index, Results);
search2([], []) ->
    ok.


print_package(Realm) ->
    fun(Name) -> io:format("~ts-~ts~n", [Realm, Name]) end.


print_multirealm([{ID, Realm} | Index], [{ID, {ok, Packages}} | Results]) ->
    FormID = fun({Name, Version}) -> {Realm, Name, Version} end,
    ok = lists:foreach(fun print_packages/1, lists:map(FormID, lists:sort(Packages))),
    print_multirealm(Index, Results);
print_multirealm([{ID, Realm} | Index], [{ID, Error} | Results]) ->
    ok = tell(warning, "Received weird result from ~p: ~p", [Realm, Error]),
    print_multirealm(Index, Results);
print_multirealm([], []) ->
    ok.


print_packages(PackageID) ->
    {ok, PackageString} = zx_lib:package_string(PackageID),
    io:format("~ts~n", [PackageString]).


print_version(Version) ->
    {ok, String} = zx_lib:version_to_string(Version),
    io:format("~ts~n", [String]).


-spec list_sysops(zx:realm()) -> zx:outcome().

list_sysops(Realm) ->
    {ok, ID} = zx_daemon:list_sysops(Realm),
    case zx_daemon:wait_result(ID) of
        {ok, Sysops} -> lists:foreach(fun zx_lib:print_user/1, Sysops);
        Error        -> Error
    end.


-spec import_realm(Path) -> zx:outcome()
    when Path :: file:filename().
%% @private
%% Configure the system for a new realm by interpreting a .zrf file.
%% Also log the SHA512 of the .zrf for the user.

import_realm(Path) ->
    case file:read_file(Path) of
        {ok, Data} ->
            Digest = crypto:hash(sha512, Data),
            Text = integer_to_list(binary:decode_unsigned(Digest, big), 16),
            ok = tell("SHA-512 of ~ts: ~ts", [Path, Text]),
            import_realm2(Data);
        {error, enoent} ->
            {error, "Realm bundle (.zrf) does not exist.", 2};
        {error, eisdir} ->
            {error, "Path is a directory, not a .zrf file.", 21}
    end.


-spec import_realm2(Data) -> zx:outcome()
    when Data :: binary().

import_realm2(Data) ->
    case zx_lib:b_to_t(Data) of
        {ok, {RealmConf, PubBin}} ->
            Realm = maps:get(realm, RealmConf),
            ok = make_realm_dirs(Realm),
            ConfPath = zx_lib:realm_conf(Realm),
            ok = zx_lib:write_terms(ConfPath, maps:to_list(RealmConf)),
            KeyHash = maps:get(key, RealmConf),
            UserName = element(1, maps:get(sysop, RealmConf)),
            Sysop = {Realm, UserName},
            ok = zx_daemon:register_key(Sysop, {KeyHash, {none, PubBin}, none}),
            tell("Added realm ~ts.", [Realm]);
        error ->
            {error, "Invalid .zrf file.", 84}
    end.


-spec set_dep(PackageString :: string()) -> zx:outcome().
%% @private
%% Set a dependency in the current project. If the project currently has a dependency
%% on the same package then the version of that dependency is updated to reflect that
%% in the PackageString argument.

set_dep(PackageString) ->
    case zx_lib:package_id(PackageString) of
        {ok, {_, _, {_, _, z}}} ->
            Message =
                "Incomplete version tuple. Dependencies must be fully specified.",
            {error, Message, 22};
        {ok, PackageID} ->
            set_dep2(PackageID);
        {error, invalid_package_string} ->
            {error, "Invalid package string", 22}
    end.


-spec set_dep2(zx:package_id()) -> ok.

set_dep2(PackageID) ->
    {ok, Meta} = zx_lib:read_project_meta(),
    Deps = maps:get(deps, Meta),
    case lists:member(PackageID, Deps) of
        true  -> ok;
        false -> set_dep3(PackageID, Deps, Meta)
    end.


-spec set_dep3(PackageID, Deps, Meta) -> ok
    when PackageID :: zx:package_id(),
         Deps      :: [zx:package_id()],
         Meta      :: [term()].
%% @private
%% Given the PackageID, list of Deps and the current contents of the project Meta, add
%% or update Deps to include (or update) Deps to reflect a dependency on PackageID, if
%% such a dependency is not already present. Then write the project meta back to its
%% file and exit.

set_dep3(PackageID = {Realm, Name, NewVersion}, Deps, Meta) ->
    ExistingPackageIDs = fun({R, N, _}) -> {R, N} == {Realm, Name} end,
    NewDeps =
        case lists:partition(ExistingPackageIDs, Deps) of
            {[{Realm, Name, OldVersion}], Rest} ->
                Message = "Updating dep ~ts to ~ts",
                {ok, OldPS} = zx_lib:package_string({Realm, Name, OldVersion}),
                {ok, NewPS} = zx_lib:package_string({Realm, Name, NewVersion}),
                ok = tell(Message, [OldPS, NewPS]),
                [PackageID | Rest];
            {[], Deps} ->
                {ok, PackageString} = zx_lib:package_string(PackageID),
                ok = tell("Adding dep ~ts", [PackageString]),
                [PackageID | Deps]
        end,
    NewMeta = maps:put(deps, NewDeps, Meta),
    zx_lib:write_project_meta(NewMeta).


-spec list_deps() -> zx:outcome().
%% @private
%% List deps in the current (local) project directory.
%% This is very different from list_deps/1, which makes a remote query to a Zomp
%% realm to discover deps for potentially unknown or locally uncached packages.

list_deps() ->
    case zx_lib:read_project_meta() of
        {ok, Meta} ->
            Deps = maps:get(deps, Meta),
            Print =
                fun(P) ->
                    {ok, PackageString} = zx_lib:package_string(P),
                    io:format("~ts~n", [PackageString])
                end,
            lists:foreach(Print, Deps);
        Error ->
            Error
    end.


-spec list_deps(zx:package_id()) -> zx:outcome().
%% @private
%% List deps for the specified package. This quite often requires a query to a Zomp
%% realm over the network, but not if the referenced package happens to be cached
%% locally.

list_deps(PackageString) ->
    case zx_lib:package_id(PackageString) of
        {ok, {_, _, {_, _, z}}} ->
            {error, "Packages must be fully specified; no partial versions.", 22};
        {ok, PackageID} ->
            list_deps2(PackageID);
        {error, invalid_package_string} ->
            {error, "Invalid package string.", 22}
    end.

list_deps2(PackageID) ->
    {ok, ID} = zx_daemon:list_deps(PackageID),
    case zx_daemon:wait_result(ID) of
        {ok, Deps} -> lists:foreach(fun print_package_id/1, Deps);
        Error      -> Error
    end.

print_package_id(PackageID) ->
    {ok, PackageString} = zx_lib:package_string(PackageID),
    io:format("~ts~n", [PackageString]).


-spec drop_dep(PackageString :: string()) -> ok.

drop_dep(PackageString) ->
    case zx_lib:package_id(PackageString) of
        {ok, PackageID} ->
            drop_dep2(PackageID);
        {error, invalid_package_string} ->
            Message = "~tp is an invalid package string",
            tell(error, Message, [PackageString])
    end.

drop_dep2(PackageID) ->
    {ok, PackageString} = zx_lib:package_string(PackageID),
    Meta =
        case zx_lib:read_project_meta() of
            {ok, M} ->
                M;
            {error, enoent} ->
                ok = io:format("zomp.meta not found. Is this a project directory?~n"),
                init:stop(1)
        end,
    Deps = maps:get(deps, Meta),
    case lists:member(PackageID, Deps) of
        true ->
            NewDeps = lists:delete(PackageID, Deps),
            NewMeta = maps:put(deps, NewDeps, Meta),
            ok = zx_lib:write_project_meta(NewMeta),
            tell("~ts removed from dependencies.", [PackageString]);
        false ->
            io:format("~ts is not a dependency. Forget the version?~n", [PackageString])
    end.


-spec verup(Level) -> zx:outcome()
    when Level :: string().
%% @private
%% Convert input string arguments to acceptable atoms for use in update_version/1.

verup("major") -> version_up(major);
verup("minor") -> version_up(minor);
verup("patch") -> version_up(patch);
verup(_)       -> zx:usage_exit(22).


-spec version_up(Level) -> zx:outcome()
    when Level :: major
                | minor
                | patch.
%% @private
%% Update a project's `zomp.meta' file by either incrementing the indicated component,
%% or setting the version number to the one specified in VersionString.
%% This part of the procedure guards for the case when the zomp.meta file cannot be
%% read for some reason.

version_up(Arg) ->
    case zx_lib:read_project_meta() of
        {ok, Meta} ->
            PackageID = maps:get(package_id, Meta),
            version_up(Arg, PackageID, Meta);
        Error ->
            Error
    end.
    

-spec version_up(Level, PackageID, Meta) -> ok
    when Level     :: major
                    | minor
                    | patch
                    | zx:version(),
         PackageID :: zx:package_id(),
         Meta      :: [{atom(), term()}].
%% @private
%% Update a project's `zomp.meta' file by either incrementing the indicated component,
%% or setting the version number to the one specified in VersionString.
%% This part of the procedure does the actual update calculation, to include calling to
%% convert the VersionString (if it is passed) to a `version()' type and check its
%% validity (or halt if it is a bad string).

version_up(major, {Realm, Name, OldVersion = {Major, _, _}}, OldMeta) ->
    NewVersion = {Major + 1, 0, 0},
    update_version(Realm, Name, OldVersion, NewVersion, OldMeta);
version_up(minor, {Realm, Name, OldVersion = {Major, Minor, _}}, OldMeta) ->
    NewVersion = {Major, Minor + 1, 0},
    update_version(Realm, Name, OldVersion, NewVersion, OldMeta);
version_up(patch, {Realm, Name, OldVersion = {Major, Minor, Patch}}, OldMeta) ->
    NewVersion = {Major, Minor, Patch + 1},
    update_version(Realm, Name, OldVersion, NewVersion, OldMeta).


-spec package(TargetDir) -> no_return()
    when TargetDir :: file:filename().
%% @private
%% Turn a target project directory into a package, prompting the user for appropriate
%% key selection or generation actions along the way.

package(TargetDir) ->
    ok = tell("Packaging ~ts", [TargetDir]),
    case zx_lib:read_project_meta(TargetDir) of
        {ok, Meta} -> package2(TargetDir, Meta);
        Error      -> Error
    end.

package2(TargetDir, Meta) ->
    {Realm, _, _} = maps:get(package_id, Meta),
    UserName = select_user(Realm),
    case select_private_key({Realm, UserName}) of
        {ok, Key} -> package3(TargetDir, Key);
        error     -> {error, "User has no private keys on the local system.", 1}
    end.

package3(TargetDir, Key) ->
    case zx_zsp:pack(TargetDir, Key) of
        {ok, Path}       -> tell("Wrote archive ~ts", [Path]);
        {error, eexists} -> {error, "Package file already exists. Aborting", 17};
        Error            -> Error
    end.


-spec create_project() -> ok.
%% @private
%% Interact with the user to determine what kind of project they want, and template
%% it based on the outcome.

create_project() ->
    create(#project{}).

create(P = #project{type = none}) ->
    create(P#project{type = ask_project_type()});
create(P = #project{name = none}) ->
    create(P#project{name = ask_project_name()});
create(P = #project{type = escript, id = none}) ->
    create(P#project{id = ask_script_name()});
create(P = #project{type = lib, id = none}) ->
    ID = {_, Module, _} = ask_package_id(),
    create(P#project{id = ID, module = Module});
create(P = #project{id = none}) ->
    ID = {_, AppMod, _} = ask_package_id(),
    create(P#project{id = ID, appmod = AppMod});
create(P = #project{type = app, id = {_, Name, _}, prefix = none}) ->
    create(P#project{prefix = ask_prefix(Name)});
create(P = #project{type = web, id = {_, Name, _}, prefix = none}) ->
    create(P#project{prefix = ask_prefix(Name)});
create(P = #project{type = gui, id = {_, Name, _}, prefix = none}) ->
    create(P#project{prefix = ask_prefix(Name)});
create(P = #project{type = app, appmod = none}) ->
    create(P#project{appmod = ask_appmod()});
create(P = #project{type = web, appmod = none}) ->
    create(P#project{appmod = ask_appmod()});
create(P = #project{type = gui, appmod = none}) ->
    create(P#project{appmod = ask_appmod()});
create(P = #project{type = cli, module = none}) ->
    create(P#project{module = ask_module()});
create(P = #project{type = lib, module = none}) ->
    create(P#project{module = ask_module()});
create(P = #project{author = none, copyright = none}) ->
    {A, E} = ask_author(),
    create(P#project{author = A, a_email = E, copyright = A, c_email = E});
create(P = #project{author = none}) ->
    {Author, Email} = ask_author(),
    create(P#project{author = Author, a_email = Email});
create(P = #project{a_email = none}) ->
    create(P#project{a_email = ask_email_optional()});
create(P = #project{copyright = none}) ->
    {Holder, Email} = ask_copyright(),
    create(P#project{copyright = Holder, c_email = Email});
create(P = #project{c_email = none}) ->
    create(P#project{c_email = ask_email_optional()});
create(P = #project{license = none}) ->
    create(P#project{license = ask_license()});
create(P = #project{desc = none}) ->
    create(P#project{desc = ask_description()});
create(P = #project{repo_url = none}) ->
    create(P#project{repo_url = ask_url(repo)});
create(P = #project{ws_url = none}) ->
    create(P#project{ws_url = ask_url(website)});
create(P = #project{type      = lib,
                    license   = License,
                    name      = Name,
                    id        = ID,
                    prefix    = Prefix,
                    module    = Module,
                    author    = Author,
                    a_email   = AEmail,
                    copyright = CR,
                    c_email   = CEmail,
                    repo_url  = RepoURL,
                    ws_url    = WebsiteURL,
                    desc      = Desc}) ->
    {ok, PS} = zx_lib:package_string(ID),
    Instructions =
        "~nLIBRARY DATA CONFIRMATION~n"
        "[ 1] Type                    : library~n"
        "[ 2] Project Name            : ~ts~n"
        "[ 3] Package ID              : ~ts~n"
        "[ 4] Author                  : ~ts~n"
        "[ 5] Author's Email          : ~ts~n"
        "[ 6] Copyright Holder        : ~ts~n"
        "[ 7] Copyright Holder's Email: ~ts~n"
        "[ 8] License                 : ~ts~n"
        "[ 9] Prefix                  : ~ts~n"
        "[10] Module                  : ~ts~n"
        "[11] Repo URL                : ~ts~n"
        "[12] Website URL             : ~ts~n"
        "[13] Description             : ~ts~n"
        "Press a number to select something to change, or [ENTER] to continue.~n",
    ok = io:format(Instructions,
                   [Name, PS,
                    Author, AEmail,
                    CR, CEmail,
                    License, Prefix, Module,
                    RepoURL, WebsiteURL, Desc]),
    case zx_tty:get_input() of
        "1"  -> create(P#project{type      = none});
        "2"  -> create(P#project{name      = none});
        "3"  -> create(P#project{id        = none});
        "4"  -> create(P#project{author    = none});
        "5"  -> create(P#project{a_email   = none});
        "6"  -> create(P#project{copyright = none});
        "7"  -> create(P#project{c_email   = none});
        "8"  -> create(P#project{license   = none});
        "9"  -> create(P#project{prefix    = none});
        "10" -> create(P#project{module    = none});
        "11" -> create(P#project{repo_url  = none});
        "12" -> create(P#project{ws_url    = none});
        "13" -> create(P#project{desc      = none});
        ""   -> project_check(P, fun create_project/1, fun create/1);
        _    ->
            ok = zx_tty:derp(),
            create(P)
    end;
create(P = #project{type      = cli,
                    license   = License,
                    name      = Name,
                    id        = ID,
                    prefix    = Prefix,
                    module    = Module,
                    author    = Author,
                    a_email   = AEmail,
                    copyright = CR,
                    c_email   = CEmail,
                    repo_url  = RepoURL,
                    ws_url    = WebsiteURL,
                    desc      = Desc}) ->
    {ok, PS} = zx_lib:package_string(ID),
    Instructions =
        "~nCLI PROGRAM DATA CONFIRMATION~n"
        "[ 1] Type                    : CLI/terminal program~n"
        "[ 2] Project Name            : ~ts~n"
        "[ 3] Package ID              : ~ts~n"
        "[ 4] Author                  : ~ts~n"
        "[ 5] Author's Email          : ~ts~n"
        "[ 6] Copyright Holder        : ~ts~n"
        "[ 7] Copyright Holder's Email: ~ts~n"
        "[ 8] License                 : ~ts~n"
        "[ 9] Prefix                  : ~ts~n"
        "[10] Module                  : ~ts~n"
        "[11] Repo URL                : ~ts~n"
        "[12] Website URL             : ~ts~n"
        "[13] Description             : ~ts~n"
        "Press a number to select something to change, or [ENTER] to continue.~n",
    ok = io:format(Instructions,
                   [Name, PS,
                    Author, AEmail,
                    CR, CEmail,
                    License, Prefix, Module,
                    RepoURL, WebsiteURL, Desc]),
    case zx_tty:get_input() of
        "1"  -> create(P#project{type      = none});
        "2"  -> create(P#project{name      = none});
        "3"  -> create(P#project{id        = none});
        "4"  -> create(P#project{author    = none});
        "5"  -> create(P#project{a_email   = none});
        "6"  -> create(P#project{copyright = none});
        "7"  -> create(P#project{c_email   = none});
        "8"  -> create(P#project{license   = none});
        "9"  -> create(P#project{prefix    = none});
        "10" -> create(P#project{module    = none});
        "11" -> create(P#project{repo_url  = none});
        "12" -> create(P#project{ws_url    = none});
        "13" -> create(P#project{desc      = none});
        ""   -> project_check(P, fun create_project/1, fun create/1);
        _    ->
            ok = zx_tty:derp(),
            create(P)
    end;
create(P = #project{type      = escript,
                    license   = License,
                    name      = Name,
                    id        = ID,
                    author    = Author,
                    a_email   = AEmail,
                    copyright = CR,
                    c_email   = CEmail}) ->
    Instructions =
        "~nESCRIPT DATA CONFIRMATION~n"
        "[1] Type                    : escript~n"
        "[2] Project Name            : ~ts~n"
        "[3] Script                  : ~ts~n"
        "[4] Author                  : ~ts~n"
        "[5] Author's Email          : ~ts~n"
        "[6] Copyright Holder        : ~ts~n"
        "[7] Copyright Holder's Email: ~ts~n"
        "[8] License                 : ~ts~n"
        "Press a number to select something to change, or [ENTER] to continue.~n",
    ok = io:format(Instructions, [Name, ID, Author, AEmail, CR, CEmail, License]),
    case zx_tty:get_input() of
        "1" -> create(P#project{type      = none});
        "2" -> create(P#project{name      = none});
        "3" -> create(P#project{id        = none});
        "4" -> create(P#project{author    = none});
        "5" -> create(P#project{a_email   = none});
        "6" -> create(P#project{copyright = none});
        "7" -> create(P#project{c_email   = none});
        "8" -> create(P#project{license   = none});
        ""  -> create_project(P);
        _   ->
            ok = zx_tty:derp(),
            create(P)
    end;
create(P = #project{type      = Type,
                    license   = License,
                    name      = Name,
                    id        = ID,
                    prefix    = Prefix,
                    appmod    = AppMod,
                    author    = Author,
                    a_email   = AEmail,
                    copyright = CR,
                    c_email   = CEmail,
                    repo_url  = RepoURL,
                    ws_url    = WebsiteURL,
                    desc      = Desc}) ->
    {ok, PS} = zx_lib:package_string(ID),
    TS =
        case Type of
            app -> "Erlang application";
            web -> "Web service";
            gui -> "GUI application"
        end,
    Instructions =
        "~nAPPLICATION DATA CONFIRMATION~n"
        "[ 1] Type                    : ~ts~n"
        "[ 2] Project Name            : ~ts~n"
        "[ 3] Package ID              : ~ts~n"
        "[ 4] Author                  : ~ts~n"
        "[ 5] Author's Email          : ~ts~n"
        "[ 6] Copyright Holder        : ~ts~n"
        "[ 7] Copyright Holder's Email: ~ts~n"
        "[ 8] License                 : ~ts~n"
        "[ 9] Prefix                  : ~ts~n"
        "[10] AppMod                  : ~ts~n"
        "[11] Repo URL                : ~ts~n"
        "[12] Website URL             : ~ts~n"
        "[13] Description             : ~ts~n"
        "Press a number to select something to change, or [ENTER] to continue.~n",
    ok = io:format(Instructions,
                   [TS, Name, PS,
                    Author, AEmail,
                    CR, CEmail,
                    License, Prefix, AppMod,
                    RepoURL, WebsiteURL, Desc]),
    case zx_tty:get_input() of
        "1"  -> create(P#project{type      = none});
        "2"  -> create(P#project{name      = none});
        "3"  -> create(P#project{id        = none});
        "4"  -> create(P#project{author    = none});
        "5"  -> create(P#project{a_email   = none});
        "6"  -> create(P#project{copyright = none});
        "7"  -> create(P#project{c_email   = none});
        "8"  -> create(P#project{license   = none});
        "9"  -> create(P#project{prefix    = none});
        "10" -> create(P#project{appmod    = none});
        "11" -> create(P#project{repo_url  = none});
        "12" -> create(P#project{ws_url    = none});
        "13" -> create(P#project{desc      = none});
        ""   -> project_check(P, fun create_project/1, fun create/1);
        _    ->
            ok = zx_tty:derp(),
            create(P)
    end.


create_project(#project{type      = escript,
                        license   = Title,
                        name      = Name,
                        id        = File,
                        author    = Credit,
                        a_email   = AEmail,
                        copyright = Holder,
                        c_email   = CEmail}) ->
    Source = filename:join(os:getenv("ZX_DIR"), "templates/escript"),
    Substitutions =
        [{"〘\*PROJECT NAME\*〙", Name},
         {"〘\*SCRIPT\*〙",       script(File)},
         {"〘\*AUTHOR\*〙",       author(Credit, AEmail)},
         {"〘\*COPYRIGHT\*〙",    copyright(Holder, CEmail)},
         {"〘\*LICENSE\*〙",      license(Title)}],
    {ok, Raw} = file:read_file(Source),
    UTF8 = unicode:characters_to_list(Raw, utf8),
    Cooked = substitute(UTF8, Substitutions),
    ok = file:write_file(File, Cooked),
    Message =
        "Escript \"~ts\" written to ~ts.~n"
        "You may need to change the file mode to add \"execute\" permissions.~n",
    io:format(Message, [Name, File]);
create_project(P = #project{id = {_, Name, Version}}) ->
    case file:make_dir(Name) of
        ok ->
            ok = file:set_cwd(Name),
            {ok, VersionString} = zx_lib:version_to_string(Version),
            ok = munge_sources(P, VersionString),
            zompify(P);
        {error, Reason} ->
            Message = "Creating directory ~ts failed with ~tp. Aborting.",
            Info = io_lib:format(Message, [Name, Reason]),
            {error, Info, 1}
    end.


template_swp() ->
    case find_meta() of
        {ok, Meta} -> template_swp(Meta);
        Error      -> Error
    end.

template_swp(Meta) ->
    Prefix = maps:get(prefix, Meta),
    Modules = {_, _, _, Worker} = ask_service_name(Prefix),
    {_, Name, Version} = maps:get(package_id, Meta),
    {ok, VersionString} = zx_lib:version_to_string(Version),
    Credit = maps:get(author, Meta),
    AEmail = maps:get(a_email, Meta),
    Holder = maps:get(copyright, Meta),
    CEmail = maps:get(c_email, Meta),
    License = maps:get(license, Meta),
    Substitutions =
        [{"〘\*PROJECT NAME\*〙", maps:get(name, Meta)},
         {"〘\*SERVICE\*〙",      Worker},
         {"〘\*CAP SERVICE\*〙",  string:titlecase(Worker)},
         {"〘\*NAME\*〙",         Name},
         {"〘\*VERSION\*〙",      VersionString},
         {"〘\*PREFIX\*〙",       Prefix},
         {"〘\*AUTHOR\*〙",       author(Credit, AEmail)},
         {"〘\*COPYRIGHT\*〙",    copyright(Holder, CEmail)},
         {"〘\*LICENSE\*〙",      license(License)}],
    case template_filenames(Prefix, Modules) of
        {ok, Templates} -> template_swp(Templates, Substitutions);
        Error           -> Error
    end.

template_swp(Templates, Substitutions) ->
    TemplateDir = filename:join([os:getenv("ZX_DIR"), "templates", "swp"]),
    Transform =
        fun({Template, Destination}) ->
            TemplatePath = filename:join(TemplateDir, Template),
            {ok, Raw} = file:read_file(TemplatePath),
            UTF8 = unicode:characters_to_list(Raw, utf8),
            Cooked = substitute(UTF8, Substitutions),
            file:write_file(Destination, Cooked)
        end,
    lists:foreach(Transform, Templates).


template_filenames(Prefix, Modules) ->
    Ts = ["workers.erl", "worker_man.erl", "worker_sup.erl", "worker.erl"],
    Fs = [Prefix ++ "_" ++ S ++ ".erl" || S <- tuple_to_list(Modules)],
    case lists:any(fun filelib:is_file/1, Fs) of
        false ->
            {ok, lists:zip(Ts, Fs)};
        true ->
            Format =
                "The module files ~p would be created by this command.~n"
                "One or more of these names already exists in the current directory.~n"
                "Aborting.~n",
            ok = io:format(Format, [Fs]),
            {error, "File name conflict."}
    end.


find_meta() ->
    {ok, CWD} = file:get_cwd(),
    find_meta(CWD).

find_meta(Dir) ->
    case zx_lib:read_project_meta(Dir) of
        {ok, Meta}    -> {ok, Meta};
        {error, _, 2} -> dive_down(Dir);
        Error         -> Error
    end.

dive_down(Dir) ->
    case filename:dirname(Dir) of
        Dir ->
            {error, "No project zomp.meta file. Wrong directory? Not initialized?", 2};
        ParentDir ->
            find_meta(ParentDir)
    end.


munge_sources(#project{type      = lib,
                       id        = {_, Name, _},
                       name      = ProjectName,
                       license   = Title,
                       module    = Module,
                       author    = Credit,
                       a_email   = AEmail,
                       copyright = Holder,
                       c_email   = CEmail},
              VersionString) ->
    ok = file:make_dir("src"),
    ok = file:make_dir("ebin"),
    {ok, ProjectDir} = file:get_cwd(),
    Substitutions =
        [{"〘\*PROJECT NAME\*〙", ProjectName},
         {"〘\*NAME\*〙",         Name},
         {"〘\*MODULE\*〙",       Module},
         {"〘\*VERSION\*〙",      VersionString},
         {"〘\*AUTHOR\*〙",       author(Credit, AEmail)},
         {"〘\*COPYRIGHT\*〙",    copyright(Holder, CEmail)},
         {"〘\*LICENSE\*〙",      license(Title)}],
    TemplateDir = filename:join([os:getenv("ZX_DIR"), "templates", "boringlib"]),
    ok = file:set_cwd("src"),
    ModFile = Module ++ ".erl",
    {ok, RawMod} = file:read_file(filename:join(TemplateDir, "funfile.erl")),
    UTF8Mod = unicode:characters_to_list(RawMod, utf8),
    CookedMod = substitute(UTF8Mod, Substitutions),
    ok = file:write_file(ModFile, CookedMod),
    file:set_cwd(ProjectDir);
munge_sources(#project{type      = cli,
                       id        = {_, Name, _},
                       name      = ProjectName,
                       license   = Title,
                       module    = Module,
                       author    = Credit,
                       a_email   = AEmail,
                       copyright = Holder,
                       c_email   = CEmail},
              VersionString) ->
    ok = file:make_dir("src"),
    ok = file:make_dir("ebin"),
    {ok, ProjectDir} = file:get_cwd(),
    Substitutions =
        [{"〘\*PROJECT NAME\*〙", ProjectName},
         {"〘\*NAME\*〙",         Name},
         {"〘\*MODULE\*〙",       Module},
         {"〘\*VERSION\*〙",      VersionString},
         {"〘\*AUTHOR\*〙",       author(Credit, AEmail)},
         {"〘\*COPYRIGHT\*〙",    copyright(Holder, CEmail)},
         {"〘\*LICENSE\*〙",      license(Title)}],
    TemplateDir = filename:join([os:getenv("ZX_DIR"), "templates"]),
    ok = file:set_cwd("src"),
    ModFile = Module ++ ".erl",
    {ok, RawMod} = file:read_file(filename:join(TemplateDir, "simplecli.erl")),
    UTF8Mod = unicode:characters_to_list(RawMod, utf8),
    CookedMod = substitute(UTF8Mod, Substitutions),
    ok = file:write_file(ModFile, CookedMod),
    file:set_cwd(ProjectDir);
munge_sources(#project{type      = Type,
                       id        = {_, Name, _},
                       name      = ProjectName,
                       license   = License,
                       prefix    = Prefix,
                       appmod    = AppMod,
                       author    = Credit,
                       a_email   = AEmail,
                       copyright = Holder,
                       c_email   = CEmail},
              VersionString) ->
    ok = file:make_dir("src"),
    ok = file:make_dir("ebin"),
    {ok, ProjectDir} = file:get_cwd(),
    Substitutions =
        [{"〘\*PROJECT NAME\*〙", ProjectName},
         {"〘\*NAME\*〙",         Name},
         {"〘\*VERSION\*〙",      VersionString},
         {"〘\*PREFIX\*〙",       Prefix},
         {"〘\*APP MOD\*〙",      AppMod},
         {"〘\*AUTHOR\*〙",       author(Credit, AEmail)},
         {"〘\*COPYRIGHT\*〙",    copyright(Holder, CEmail)},
         {"〘\*LICENSE\*〙",      license(License)}],
    Template =
        case Type of
            app -> "example_server";
            web -> "cowboy_example";
            gui -> "hellowx"
        end,
    TemplateDir = filename:join([os:getenv("ZX_DIR"), "templates", Template]),
    ok = file:set_cwd("src"),
    AppModFile = AppMod ++ ".erl",
    {ok, RawAppMod} = file:read_file(filename:join(TemplateDir, "appmod.erl")),
    UTF8AppMod = unicode:characters_to_list(RawAppMod, utf8),
    CookedAppMod = substitute(UTF8AppMod, Substitutions),
    ok = file:write_file(AppModFile, CookedAppMod),
    {ok, ModuleTemplates} = file:list_dir(filename:join(TemplateDir, "src")),
    Manifest = [filename:join([TemplateDir, "src", T]) || T <- ModuleTemplates],
    ok = transform(Manifest, Prefix, Substitutions),
    file:set_cwd(ProjectDir).


transform([Template | Rest], Prefix, Substitutions) ->
    {ok, Raw} = file:read_file(Template),
    UTF8 = unicode:characters_to_list(Raw, utf8),
    Data = substitute(UTF8, Substitutions),
    Path = Prefix ++ filename:basename(Template),
    ok = file:write_file(Path, Data),
    transform(Rest, Prefix, Substitutions);
transform([], _, _) ->
    ok.


substitute(Raw, [{Pattern, Value} | Rest]) ->
    Cooking = string:replace(Raw, Pattern, Value, all),
    substitute(Cooking, Rest);
substitute(Cooked, []) ->
    unicode:characters_to_binary(Cooked, utf8).


license(skip)            -> "";
license("")              -> "";
license(Title)           -> "-license(\""++ Title ++ "\").".

script("")               -> "";
script(Name)             -> "-script(\"" ++ Name ++ "\").".

copyright("", "")        -> "";
copyright(Holder, "")    -> "-copyright(\"" ++ Holder ++ "\").";
copyright("", Email)     -> "-copyright(\"<" ++ Email ++ ">\").";
copyright(Holder, Email) -> "-copyright(\"" ++ Holder ++ " <" ++ Email ++ ">\").".

author("", "")           -> "";
author(Credit, "")       -> "-author(\"" ++ Credit ++ "\").";
author("", Email)        -> "-author(\"<" ++ Email ++ ">\").";
author(Credit, Email)    -> "-author(\"" ++ Credit ++ " <" ++ Email ++">\").".

copyright_holder("", "")        -> "[COPYRIGHT HOLDER]";
copyright_holder(Holder, "")    -> Holder;
copyright_holder("", Email)     -> "<" ++ Email ++ ">";
copyright_holder(Holder, Email) -> Holder ++ " <" ++ Email ++">".


-spec ask_project_type() -> app | lib | escript | no_return().
%% @private
%% Determine whether the user wants to create an app, a lib, or nothing.

ask_project_type() ->
    Instructions =
        "~nPROJECT TYPE~n"
        "Select a project type.~n"
        "Remember, an \"application\" in Erlang is anything that needs to be started "
        "to work, even if it acts in a supporting role.~n"
        "(Note that escripts cannot be packaged.)~n"
        "[1] Traditional Erlang service application~n"
        "[2] Cowboy-based web service~n"
        "[3] Library~n"
        "[4] End-user GUI application~n"
        "[5] End-user CLI application~n"
        "[6] Escript~n",
    ok = io:format(Instructions),
    case zx_tty:get_input() of
        "1" -> app;
        "2" -> web;
        "3" -> lib;
        "4" -> gui;
        "5" -> cli;
        "6" -> escript;
        _   ->
            ok = zx_tty:derp(),
            ask_project_type()
    end.


-spec ask_script_name() -> zx:lower0_9() | no_return().

ask_script_name() ->
    Instructions =
        "~nESCRIPT NAME~n"
        "Enter the name of your escript. This will be its callable filename.~n"
        "[a-z0-9_]*~n",
    case zx_tty:get_lower0_9(Instructions) of
        "" ->
            ok = io:format("The script has to be called something. Try again. ~n"),
            ask_script_name();
        Script ->
            Script
    end.


-spec ask_package_id() -> zx:package_id() | no_return().

ask_package_id() ->
    Instructions =
        "~nPACKAGE REALM~n"
        "Realms are how code is organized inside the Zomp repository system. "
        "They are analogous to repository sources for aptitude.~n"
        "The default realm is called \"otpr\" and is the main realm for FOSS code.~n"
        "It is also possible to create your own realm with the command "
        "`zx create realm` and host it directly with `zx run zomp`.~n"
        "Realms do not have to be publicly visible, and packages in one realm can "
        "depend on packages in any other.~n"
        "For more information on realm and package naming see "
        "http://zxq9.com/projects/zomp/zx_usage.en.html#identifiers~n"
        "Configured realms:~n",
    ok = io:format(Instructions),
    {ok, Realm} = pick_realm(),
    ask_package_id2(Realm).

ask_package_id2(Realm) ->
    Instructions =
        "~nPACKAGE NAME~n"
        "Your package needs to have a name. This will also be it's Erlang application "
        "or library main interface module name.~n"
        "Legal names are made from characters0 [a-z1-9_], and cannot start with a "
        "number or underscore.~n",
    PackageName = zx_tty:get_input(Instructions),
    case zx_lib:valid_lower0_9(PackageName) of
        true  -> ask_package_id3(Realm, PackageName);
        false -> ask_package_id2(Realm)
    end.

ask_package_id3(Realm, Name) ->
    Instructions =
        "~nVERSION~n"
        "You can set a package version here if desired. Unversioned packaged start at "
        "version 0.1.0 by default.~n"
        "Note that version numbers must be valid semver numbers.~n",
    case zx_tty:get_input(Instructions, [], "[0.1.0]") of
        ""     -> {Realm, Name, {0, 1, 0}};
        String ->
            case zx_lib:string_to_version(String) of
                {ok, {X, z, z}}                 -> {Realm, Name, {X, 0, 0}};
                {ok, {X, Y, z}}                 -> {Realm, Name, {X, Y, 0}};
                {ok, V}                         -> {Realm, Name, V};
                {error, invalid_version_string} -> 
                    Message = "Sorry, \"~tp\" is an invalid version. Try again.~n",
                    ok = io:format(Message, [String]),
                    ask_package_id3(Realm, Name)
            end
    end.


-spec ask_prefix(zx:name()) -> string().
%% @private
%% Get a valid module prefix to use as a namespace for new modules.

ask_prefix(Name) ->
    Default =
        case string:split(Name, "_", all) of
            Name  -> Name;
            Parts -> lists:map(fun erlang:hd/1, Parts)
        end,
    Instructions =
        "~nPICKING A PREFIX~n"
        "projects use a prefix with a trailing underscore as module namespaces.~n"
        "Names are usually either the project name (if it is short), or an "
        "abbreviation of the project name.~n"
        "For example, example_server uses the module prefix \"es\", so many files "
        "in the project are named things like \"es_client\".~n"
        "Enter the prefix you would like to use below (or enter for the generated "
        "default).~n",
    Prompt = io_lib:format("[\"~ts\"]", [Default]),
    case zx_tty:get_input(Instructions, [], Prompt) of
        "" ->
            Default;
        String ->
            case zx_lib:valid_lower0_9(String) of
                true ->
                    String;
                false ->
                    Message = "The string \"~ts\" isn't valid. Try \"[a-z0-9_]*\".~n",
                    ok = io:format(Message, [String]),
                    ask_prefix(Name)
            end
    end.


-spec ask_appmod() -> atom() | no_return().

ask_appmod() ->
    Instructions =
        "~nAPPLICATION MODULE~n"
        "Enter the name of your main/start interface module where the application "
        "callback start/2 has been defined.~n",
    zx_tty:get_lower0_9(Instructions).


-spec ask_module() -> atom() | no_return().

ask_module() ->
    Instructions =
        "~nINTERFACE MODULE~n"
        "Enter the name of the library's initial interface module.~n",
    zx_tty:get_lower0_9(Instructions).


-spec package_exists(zx:package_id()) -> boolean().
%% @private
%% TODO: Change this from a stub into a for-real check via zx_daemon.
%% Check the realm's upstream for the existence of a package that already has the same
%% name, or the name of any modules in src/ and report them to the user. Give the user
%% a chance to change their package's name or ignore the conflict, and report all module
%% naming conflicts.

package_exists({Realm, Package, _}) ->
    {ok, ID} = zx_daemon:list(Realm),
    case zx_daemon:wait_result(ID) of
        {ok, Packages} -> lists:member(Package, Packages);
        _              -> weather_permitting
    end.


-spec grow_a_pair() -> zx:outcome().
%% @private
%% Execute the key generation procedure for 16k RSA keys once and then terminate.

grow_a_pair() ->
    case pick_realm() of
        {ok, Realm}        -> grow_a_pair(Realm);
        {error, no_realms} -> {error, "No realms configured.", 61}
    end.

grow_a_pair(Realm) ->
    UserName = select_user(Realm),
    grow_a_pair(Realm, UserName).

grow_a_pair(Realm, UserName) ->
    case zx_key:generate_rsa(Realm) of
        {ok, KeyHash} ->
            UserID = {Realm, UserName},
            {ok, UserConf = #{keys := Keys}} =  zx_userconf:load(UserID),
            NewUserConf = UserConf#{keys => [KeyHash | Keys]},
            zx_userconf:save(NewUserConf);
        Error ->
            Error
    end.


-spec drop_key(zx:key_id()) -> ok.
%% @private
%% Given a KeyID, remove the related public and private keys from the keystore, if they
%% exist. If not, exit with a message that no keys were found, but do not return an
%% error exit value (this instruction is idempotent if used in shell scripts).

drop_key({Realm, KeyName}) ->
    Pattern = filename:join(zx_lib:path(key, Realm), KeyName ++ ".{key,pub}.der"),
    case filelib:wildcard(Pattern) of
        [] ->
            tell(warning, "Key ~ts/~ts not found", [Realm, KeyName]);
        Files ->
            ok = lists:foreach(fun file:delete/1, Files),
            tell(info, "Keyset ~ts/~ts removed", [Realm, KeyName])
    end.


-spec create_realm() -> ok.
%% @private
%% Prompt the user to input the information necessary to create a new zomp realm,
%% package the data appropriately for the server and deliver the final keys and
%% realm file to the user.

create_realm() ->
    ok = tell("WOOHOO! Making a new realm!"),
    create_realm(#realm_init{}).


create_realm(R = #realm_init{realm = none}) ->
    create_realm(R#realm_init{realm = ask_realm()});
create_realm(R = #realm_init{addr  = none}) ->
    create_realm(R#realm_init{addr = ask_addr()});
create_realm(R = #realm_init{port  = none}) ->
    create_realm(R#realm_init{port = ask_port()});
create_realm(R = #realm_init{url = none}) ->
    create_realm(R#realm_init{url = ask_url(realm)});
create_realm(R = #realm_init{realm = Realm, sysop = none}) ->
    create_realm(R#realm_init{sysop = create_sysop(#user_data{realm = Realm})});
create_realm(R = #realm_init{realm = Realm, addr = Addr, port = Port, url = URL}) ->
    Instructions =
        "~nREALM DATA CONFIRMATION~n"
        "That's everything! Please confirm these settings:~n"
        "[1] Realm Name  : ~ts~n"
        "[2] Host Address: ~ts~n"
        "[3] Port Number : ~w~n"
        "[4] URL         : ~ts~n"
        "Press a number to select something to change, or [ENTER] to continue.~n",
    ok = io:format(Instructions, [Realm, stringify_address(Addr), Port, URL]),
    case zx_tty:get_input() of
        "1" -> create_realm(R#realm_init{realm = none});
        "2" -> create_realm(R#realm_init{addr  = none});
        "3" -> create_realm(R#realm_init{port  = none});
        "4" -> create_realm(R#realm_init{url   = none});
        ""  ->
            store_realm(R);
        _   ->
            ok = zx_tty:derp(),
            create_realm(R)
    end.


store_realm(#realm_init{realm = Realm,
                        addr  = Addr,
                        port  = Port,
                        url   = URL,
                        sysop = U = #user_data{username     = UserName,
                                               realname     = RealName,
                                               contact_info = [ContactInfo]}}) ->
    ok = make_realm_dirs(Realm),
    RealmConfPath = filename:join(zx_lib:path(etc, Realm), "realm.conf"),
    ok = file:write_file(RealmConfPath, "Placeholder realm file."),
    {ok, KeyHash} = zx_key:generate_rsa({Realm, UserName}),
    NewU = U#user_data{keys = [KeyHash]},
    RealmConf =
        [{realm,     Realm},
         {prime,     {Addr, Port}},
         {sysop,     {UserName, RealName, ContactInfo}},
         {key,       KeyHash},
         {url,       URL},
         {timestamp, calendar:universal_time()}],
    ok = zx_lib:write_terms(RealmConfPath, RealmConf),
    ok = store_user(NewU),
    ok = export_realm(Realm),
    ok = export_user(zpuf, Realm, UserName),
    ZPUF = Realm ++ "-" ++ UserName ++ ".zpuf",
    ZRF = Realm ++ ".zrf",
    Message =
      "=============================================================================~n"
      "DONE!~n"
      "The realm ~ts has been created and is accessible from this system.~n"
      "~n"
      "Realm configuration file has been written to:  ~ts~n"
      "Sysop userfile has been written to:            ~ts~n"
      "~n"
      "-----------------------------------------------------------------------------~n"
      "NODE AND CLIENT CONFIGURATION~n"
      "~n"
      "PRIME NODE configuration requires three commands:~n"
      "1. Configure the realm:    `zx import realm ~ts`~n"
      "2. Add the sysop user:     `zx import user ~ts`~n"
      "3. Become the prime node:  `zx takeover ~ts`~n"
      "~n"
      "ZX CLIENT and ZOMP DISTRIBUTION NODE configuration requires one command:~n"
      "1. Configure the realm:    `zx import realm ~ts`~n"
      "~n"
      "How to distribute ~ts is up to you.~n"
      "=============================================================================~n",
    Substitutions = [Realm, ZRF, ZPUF, ZRF, ZPUF, Realm, ZRF, ZRF],
    io:format(Message, Substitutions).


-spec ask_realm() -> string().

ask_realm() ->
    Instructions =
        "~nNAMING~n"
        "Enter a name for your new realm.~n"
        "Names can contain only lower-case letters, numbers and the underscore.~n"
        "Names must begin with a lower-case letter.~n",
    Realm = zx_tty:get_lower0_9(Instructions),
    case realm_exists(Realm) of
        false ->
            Realm;
        true ->
            ok = io:format("That realm already exists. Be more original.~n"),
            ask_realm()
    end.


-spec ask_addr() -> string().

ask_addr() ->
    Message =
        "~nHOST ADDRESS~n"
        "Enter the hostname, IPv4 or IPv6 address of the realm's prime Zomp node.~n"
        "DO NOT INCLUDE A PORT NUMBER IN THIS STEP~n",
    ok = io:format(Message),
    case zx_tty:get_input() of
        ""    ->
            ok = io:format("You need to enter an address.~n"),
            ask_addr();
        String ->
            parse_maybe_address(String)
    end.


-spec parse_maybe_address(string()) -> inet:hostname() | inet:ip_address().

parse_maybe_address(String) ->
    case inet:parse_address(String) of
        {ok, Address}   -> Address;
        {error, einval} -> String
    end.


-spec stringify_address(inet:hostname() | inet:ip_address()) -> string().

stringify_address(Address) ->
    case inet:ntoa(Address) of
        {error, einval} -> Address;
        String          -> String
    end.


-spec ask_port() -> inet:port_number().

ask_port() ->
    Message =
        "~nPUBLIC PORT NUMBER~n"
        "Enter the publicly visible (external) port number at which this service "
        "should be available.~n"
        "(This might be different from the local port number if you are forwarding "
        "ports or have a complex network layout.)~n",
    ok = io:format(Message),
    prompt_port_number(11311).


-spec prompt_port_number(Current) -> Result
    when Current :: inet:port_number(),
         Result  :: inet:port_number().

prompt_port_number(Current) ->
    ok = io:format("A valid port is any number from 1 to 65535.~n"),
    case zx_tty:get_input("[~w]", [Current]) of
        "" ->
            Current;
        S ->
            try
                case list_to_integer(S) of
                    Port when 16#ffff >= Port, Port > 0 ->
                        Port;
                    Illegal ->
                        Whoops = "Whoops! ~w is out of bounds (1~65535). Try again.~n",
                        ok = io:format(Whoops, [Illegal]),
                        prompt_port_number(Current)
                end
            catch error:badarg ->
                ok = io:format("~160tp is not a port number. Try again...", [S]),
                prompt_port_number(Current)
            end
    end.


-spec ask_url(Type) -> string()
    when Type :: realm
               | website
               | repo.

ask_url(realm) ->
    Message =
        "~nREALM COMMUNITY URL~n"
        "Most public realms have a website, IRC channel, or similar location where its "
        "community (or customers) communicate. If you have such a URL enter it here.~n"
        "NOTE: No checking is performed on the input here. Confuse your users at "
        "your own peril!~n"
        "[ENTER] to leave blank.~n",
    zx_tty:get_input(Message);
ask_url(repo) ->
    Message =
        "~nPROJECT REPO URL~n"
        "Most projects have a hosted repo URL (gitlab, github, SF, self hosted, etc).~n" 
        "If you have such a URL enter it here.~n"
        "NOTE: No checking is performed on the input here. Confuse your users at "
        "your own peril!~n"
        "[ENTER] to leave blank.~n",
    zx_tty:get_input(Message);
ask_url(website) ->
    Message =
        "~nPROJECT WEBSITE URL~n"
        "Many project, particularly GUI applications, have a public website where "
        "documentation, user forums, etc. are hosted.~n"
        "If you have such a URL enter it here.~n"
        "NOTE: No checking is performed on the input here. Confuse your users at "
        "your own peril!~n"
        "[ENTER] to leave blank.~n",
    zx_tty:get_input(Message).


-spec create_sysop(InitUser) -> FullUser
    when InitUser :: #user_data{},
         FullUser :: #user_data{}.

create_sysop(U = #user_data{username = none}) ->
    UserName = ask_username(),
    create_sysop(U#user_data{username = UserName});
create_sysop(U = #user_data{realname = none}) ->
    create_sysop(U#user_data{realname = ask_realname()});
create_sysop(U = #user_data{contact_info = none}) ->
    create_sysop(U#user_data{contact_info = [{"email", ask_email()}]});
create_sysop(U = #user_data{username     = UserName,
                            realname     = RealName,
                            contact_info = [{"email", Email}]}) ->
    Instructions =
        "~nSYSOP DATA CONFIRMATION~n"
        "Please correct or confirm the sysop's data:~n"
        "[1] Username : ~ts~n"
        "[2] Real Name: ~ts~n"
        "[3] Email    : ~ts~n"
        "Press a number to select something to change, or [ENTER] to accept.~n",
    ok = io:format(Instructions, [UserName, RealName, Email]),
    case zx_tty:get_input() of
        "1" -> create_sysop(U#user_data{username     = none});
        "2" -> create_sysop(U#user_data{realname     = none});
        "3" -> create_sysop(U#user_data{contact_info = none});
        ""  -> U;
        _   ->
            ok = zx_tty:derp(),
            create_sysop(U)
    end.


-spec create_user() -> ok.

create_user() ->
    UserName = create_user2(#user_data{}),
    tell("User ~ts created.", [UserName]).


-spec create_user(zx:realm()) -> zx:user_name().

create_user(Realm) ->
    create_user2(#user_data{realm = Realm}).


-spec create_user2(#user_data{}) -> zx:user_name().

create_user2(U = #user_data{realm = none}) ->
    case pick_realm() of
        {ok, Realm}        -> create_user2(U#user_data{realm = Realm});
        {error, no_realms} -> {error, "No realms configured.", 1}
    end;
create_user2(U = #user_data{username = none}) ->
    UserName = ask_username(),
    create_user2(U#user_data{username = UserName});
create_user2(U = #user_data{realname = none}) ->
    create_user2(U#user_data{realname = ask_realname()});
create_user2(U = #user_data{contact_info = none}) ->
    create_user2(U#user_data{contact_info = [{"email", ask_email()}]});
create_user2(U = #user_data{realm        = Realm,
                            username     = UserName,
                            realname     = RealName,
                            contact_info = [{"email", Email}]}) ->
    Instructions =
        "~nUSER DATA CONFIRMATION~n"
        "Please correct or confirm the user's data:~n"
        "[1] Realm    : ~ts~n"
        "[2] Username : ~ts~n"
        "[3] Real Name: ~ts~n"
        "[4] Email    : ~ts~n"
        "Press a number to select something to change, or [ENTER] to accept.~n",
    ok = io:format(Instructions, [Realm, UserName, RealName, Email]),
    case zx_tty:get_input() of
        "1" -> create_user2(U#user_data{realm        = none});
        "2" -> create_user2(U#user_data{username     = none});
        "3" -> create_user2(U#user_data{realname     = none});
        "4" -> create_user2(U#user_data{contact_info = none});
        ""  ->
            {ok, KeyHash} = zx_key:generate_rsa({Realm, UserName}),
            ok = store_user(U#user_data{keys = [KeyHash]}),
            UserName;
        _   ->
            ok = zx_tty:derp(),
            create_user2(U)
    end.


-spec store_user(#user_data{}) -> ok.

store_user(#user_data{realm        = Realm,
                      username     = UserName,
                      realname     = RealName,
                      contact_info = ContactInfo,
                      keys         = [KeyHash]}) ->
    UC = zx_userconf:new(),
    NewUC =
        UC#{realm        := Realm,
            username     := UserName,
            realname     := RealName,
            contact_info := ContactInfo,
            keys         := [KeyHash]},
    zx_userconf:save(NewUC).


-spec export_user(Type) -> ok
    when Type :: zpuf | zduf.

export_user(Type) ->
    case pick_realm() of
        {ok, Realm}        -> export_user(Type, Realm);
        {error, no_realms} -> {error, "No realms configured.", 61}
    end.


export_user(Type, Realm) ->
    UserName = select_user(Realm),
    export_user(Type, Realm, UserName).


export_user(Type, Realm, UserName) ->
    {ok, UserConf} = zx_userconf:load({Realm, UserName}),
    Keys = maps:get(keys, UserConf),
    {Load, Ext, Message} = exporter(Type, Realm),
    KeyData = lists:foldl(Load, [], Keys),
    UserFile = Realm ++ "-" ++ UserName ++ Ext,
    UserData = maps:to_list(UserConf),
    Bin = term_to_binary({UserData, KeyData}),
    ok = file:write_file(UserFile, Bin),
    io:format(Message, [UserFile, Realm]).

exporter(zduf, Realm) ->
    Load =
        fun(KeyName, Acc) ->
            Key =
                case zx_daemon:get_keybin(private, {Realm, KeyName}) of
                    {ok, KDer} -> {none, KDer};
                    _          -> none
                end,
            Pub =
                case zx_daemon:get_keybin(public, {Realm, KeyName}) of
                    {ok, PDer} -> {none, PDer};
                    _          -> none
                end,
            [{KeyName, Pub, Key} | Acc]
        end,
    Ext = ".zduf",
    Message =
        "Wrote Zomp DANGEROUS user file to ~ts.~n"
        "WARNING: This file contains your PRIVATE KEYS and should NEVER be shared.~n"
        "Its only use is for the `import user [.zduf]` command!~n"
        "Importing the user will only work if you have first imported realm ~ts.~n",
    {Load, Ext, Message};
exporter(zpuf, Realm) ->
    Load =
        fun(KeyName, Acc) ->
            case zx_daemon:get_keybin(public, {Realm, KeyName}) of
                {ok, Der} ->
                    Public = {none, Der},
                    [{KeyName, Public, none} | Acc];
                _ ->
                    Acc
            end
        end,
    Ext = ".zpuf",
    Message =
        "Wrote Zomp public user file to ~ts.~n"
        "This file can be given to a sysop from ~ts and added to the realm.~n"
        "It ONLY contains PUBLIC KEY data.~n",
    {Load, Ext, Message}.


-spec import_user(file:filename()) -> zx:outcome().

import_user(Path) ->
    case file:read_file(Path) of
        {ok, Bin}       -> import_user2(Bin);
        {error, enoent} -> {error, "Bad path/missing file.", 2};
        {error, eacces} -> {error, "Can't read file: bad permissions.", 13};
        {error, eisdir} -> {error, "The path provided is a directory.", 21};
        Error           -> Error
    end.

import_user2(Bin) ->
    case zx_lib:b_to_t(Bin) of
        {ok, {NewUserData, []}} ->
            ok = tell("Note: This user file does not have any keys."),
            import_user3(NewUserData, []);
        {ok, {NewUserData, KeyData}} ->
            import_user3(NewUserData, KeyData);
        error ->
            {error, "Bad data. Is this really a legitimate .zduf or .zpuf?", 1}
    end.

import_user3(UserData, KeyData) ->
    UserConf = #{realm := Realm, username := UserName} = maps:from_list(UserData),
    UserID = {Realm, UserName},
    case zx_userconf:load(UserID) of
        {ok, OldUserConf} ->
            NewUserConf = zx_userconf:merge(UserConf, OldUserConf, KeyData),
            ok = zx_userconf:save(NewUserConf),
            import_user4(Realm, UserName, KeyData);
        {error, bad_user} ->
            ok = zx_userconf:save(UserConf),
            import_user4(Realm, UserName, KeyData);
        {error, bad_realm} ->
            ok = tell(error, "Realm ~tp is not configured.", [Realm]),
            {error, bad_realm};
        Error ->
            Error
    end.

import_user4(Realm, UserName, Keys) ->
    Register = fun(KeyData) -> zx_daemon:register_key({Realm, UserName}, KeyData) end,
    ok = lists:foreach(Register, Keys),
    tell(info, "Imported user ~ts to realm ~ts.", [UserName, Realm]).


-spec pick_realm() -> Result
    when Result :: {ok, zx:realm()}
                 | {error, no_realms}.

pick_realm() ->
    case zx_lib:list_realms() of
        [] ->
            ok = tell(warning, "No realms configured! Exiting..."),
            {error, no_realms};
        [Realm] ->
            ok = tell("Realm ~ts selected.", [Realm]),
            {ok, Realm};
        Realms ->
            ok = io:format("Select a realm:~n"),
            Realm = zx_tty:select_string(Realms),
            {ok, Realm}
    end.


-spec ask_service_name(Prefix) -> Modules
    when Prefix :: string(),
         Modules :: {Sup       :: string(),
                     Man       :: string(),
                     WorkerSup :: string(),
                     Worker    :: string()}.

ask_service_name(Prefix) ->
    Instructions =
        "~nSERVICE NAME~n"
        "Enter the name of the service.~n"
        "Must be a legal module name.~n",
    case zx_tty:get_input(Instructions) of
        "" ->
            ok = io:format("Please enter a service name."),
            ask_service_name(Prefix);
        String ->
            Name = unicode:characters_to_list(String, utf8),
            ask_service_name2(Prefix, Name)
    end.

ask_service_name2(Prefix, Name) ->
    case zx_lib:valid_lower0_9(Name) of
        true ->
            ask_service_name3(Prefix, Name);
        false ->
            Message = "Invalid characters. Try something in the range [:a-z0-9:].~n",
            ok = io:format(Message),
            ask_service_name(Prefix)
    end.

ask_service_name3(Prefix, Worker) ->
    Sup       = Worker ++ "s",
    Man       = Worker ++ "_man",
    WorkerSup = Worker ++ "_sup",
    Modules = [Sup, Man, WorkerSup, Worker],
    Prefixed = [Prefix ++ "_" ++ M || M <- Modules],
    {ok, Realms} = zx:list(),
    Combinations = [{R, M} || R <- Realms, M <- Prefixed],
    Query =
        fun({Realm, Module}) ->
            {ok, ID} = zx_daemon:provides(Realm, Module),
            {ID, Realm, Module}
        end,
    Pending = lists:map(Query, Combinations),
    {ok, Results} = zx_daemon:wait_results([ID || {ID, _, _} <- Pending]),
    case lists:all(fun({_, {ok, Ps}}) -> Ps == [] end, Results) of
        true ->
            list_to_tuple(Modules);
        false ->
            Trouble = match(Pending, Results, Prefixed),
            confirm_service_name(Prefix, Modules, Trouble)
    end.

match(Pending, Results, Modules) ->
    Index = maps:from_list([{M, []} || M <- Modules]),
    Merge =
        fun({ID, {ok, Conflicts}}, I) ->
            {value, {_, Realm, Module}} = lists:keysearch(ID, 1, Pending),
            maps:put(Module, [{Realm, Conflicts} | maps:get(Module, I)], I)
        end,
    lists:foldl(Merge, Index, Results).

confirm_service_name(Prefix, Modules, Trouble) ->
    ok = io:format("~nModule name conflicts! OH NOES!!!~n"),
    ok = lists:foreach(fun show_conflict/1, maps:to_list(Trouble)),
    Instructions =
        "~nDECISIONS DECISIONS!~n"
        "Do you want to use these names anyway?~n"
        "The name conflict won't be a problem unless you need to include any of "
        "the conflicting packages as a dependency (now or in the future).~n",
    case zx_tty:get_input(Instructions, [], "[Y/N]") of
        "Y" -> list_to_tuple(Modules);
        "y" -> list_to_tuple(Modules);
        _   -> ask_service_name(Prefix)
    end.

show_conflict({_, []}) ->
    ok;
show_conflict({Module, Packages}) ->
    Message = "The module name ~tp shows a conflict with the following packages:~n",
    ok = io:format(Message, [Module]),
    show_conflict2(Packages).

show_conflict2([{Realm, Packages} | Rest]) ->
    Show = fun({Name, Version}) -> show_package({Realm, Name, Version}) end,
    ok = lists:foreach(Show, Packages),
    show_conflict2(Rest);
show_conflict2([]) ->
    ok.

show_package(ID) ->
    {ok, PackageString} = zx_lib:package_string(ID),
    io:format("~ts~n", [PackageString]).


-spec ask_project_name() -> string().

ask_project_name() ->
    Instructions =
        "~nPROJECT NAME~n"
        "Enter the natural, readable name of your project.~n"
        "(Any valid UTF-8 printables are legal.)~n",
    case zx_tty:get_input(Instructions) of
        "" ->
            ok = io:format("Please enter a project name."),
            ask_project_name();
        String ->
            unicode:characters_to_list(String, utf8)
    end.


-spec ask_username() -> zx:user_name().

ask_username() ->
    Instructions =
        "~nUSERNAME~n"
        "Enter a username.~n"
        "Names can contain only lower-case letters, numbers and the underscore.~n"
        "Names must begin with a lower-case letter.~n",
    zx_tty:get_lower0_9(Instructions).


-spec ask_realname() -> string().

ask_realname() ->
    Instructions =
        "~nREAL NAME~n"
        "Enter the user's real name (or whatever name people recognize).~n"
        "(Any valid UTF-8 printables are legal.)~n",
    String = zx_tty:get_input(Instructions, [], "[ENTER] to leave blank"),
    unicode:characters_to_list(String, utf8).


-spec ask_author() -> {string(), string()}.

ask_author() ->
    Instructions =
        "~nAUTHOR'S NAME~n"
        "Enter the authors's real name (or whatever name people recognize).~n"
        "(Any valid UTF-8 printables are legal.)~n",
    String = zx_tty:get_input(Instructions, [], "[ENTER] to leave blank"),
    Author = unicode:characters_to_list(String, utf8),
    Email = ask_email_optional(),
    {Author, Email}.


-spec ask_copyright() -> {string(), string()}.

ask_copyright() ->
    Instructions =
        "~nCOPYRIGHT HOLDER'S NAME~n"
        "Enter the copyright's real name. This may be a person, company, group, etc.~n"
        "There are no rules for this one. Any valid UTF-8 printables are legal.~n"
        "This can also be left blank.~n",
    String = zx_tty:get_input(Instructions, [], "[ENTER] to leave blank"),
    Holder = unicode:characters_to_list(String, utf8),
    Email = ask_email_optional(),
    {Holder, Email}.


-spec ask_license() -> string().

ask_license() ->
    Message =
        "~nLICENSE SELECTION~n"
        "Note that many more FOSS license identifiers are available at "
        "https://spdx.org/licenses/~n",
    ok = io:format(Message),
    Options =
        [{"Apache License 2.0",                             "Apache-2.0"},
         {"BSD 3-Clause with Attribution",                  "BSD-3-Clause-Attribution"},
         {"BSD 2-Clause / FreeBSD",                         "BSD-2-Clause-FreeBSD"},
         {"GNU General Public License (GPL) v3.0 only",     "GPL-3.0-only"},
         {"GNU General Public License (GPL) v3.0 or later", "GPL-3.0-or-later"},
         {"GNU Library (LGPL) v3.0 only",                   "LGPL-3.0-only"},
         {"GNU Library (LGPL) v3.0 or later",               "LGPL-3.0-or-later"},
         {"MIT license",                                    "MIT"},
         {"ISC license",                                    "ISC"},
         {"Mozilla Public License 2.0",                     "MPL-2.0"},
         {"Public Domain/Creative Commons Zero notice",     "CC0"},
         {"[proprietary]",                                  proprietary},
         {"[skip and leave blank]",                         skip}],
    case zx_tty:select(Options) of
        skip ->
            skip;
        proprietary ->
            Notice =
                "~nNOTE ON PROPRIETARY USE~n"
                "It is recommended that you check with your legal department or "
                "advisor to determine whether your proprietary project is compatible "
                "with the GPL version of Zomp/ZX.~n"
                "If not (mostly when deploying client-side code that links to ZX or "
                "other GPL/dual-license libraries), Zomp/ZX should be dual-licensed.~n",
            ok = io:format(Notice),
            skip;
        License ->
            License
    end.



-spec ask_email() -> string().

ask_email() ->
    case zx_tty:get_input(email_instructions()) of
        "" ->
            ok = io:format("An email address is required.~n"),
            ask_email();
        String ->
            case check_email(String) of
                ok    -> String;
                error -> ask_email()
            end
    end.


-spec ask_email_optional() -> string().

ask_email_optional() ->
    case zx_tty:get_input(email_instructions(), [], "[ENTER] to leave blank") of
        "" ->
            "";
        String ->
            case check_email(String) of
                ok    -> String;
                error -> ask_email()
            end
    end.


-spec check_email(Address :: string()) -> ok | error.

check_email(Address) ->
    case string:lexemes(Address, "@") of
        [User, Host] ->
            ValidUser = io_lib:printable_latin1_list(User),
            ValidHost = io_lib:printable_latin1_list(Host),
            case {ValidUser, ValidHost} of
                {true, true} ->
                    ok;
                {false, true} ->
                    Message = "The user part of the email address seems invalid.~n",
                    ok = io:format(Message),
                    error;
                {true, false} ->
                    Message = "The host part of the email address seems invalid.~n",
                    ok = io:format(Message),
                    error;
                {false, false} ->
                    Message = "This email address is totally bonkers. Try again.~n",
                    ok = io:format(Message),
                    error
            end;
        _ ->
            ok = io:format("Don't get fresh. Try again. For real this time.~n"),
            error
    end.


email_instructions() ->
    "~nEMAIL~n"
    "Enter an email address.~n".


-spec ask_description() -> string().

ask_description() ->
    Instructions =
        "~nPROJECT DESCRIPTION~n"
        "Enter a short description of the project.~n"
        "This description will appear:~n"
        "- In the project's .app file~n"
        "- Be displayed when a user uses the `zx describe [project]` command~n"
        "- (GUIs) As the program summary if no project site summary can be found~n"
        "NOTE: You can change or update this description in subsequent versions.~n",
    String = zx_tty:get_input(Instructions, [], "[ENTER] to leave blank"),
    unicode:characters_to_list(String, utf8).


-spec edit_tags(Set) -> NewSet
    when Set    :: sets:set(string()),
         NewSet :: sets:set(string()).

edit_tags(Set) ->
    ok = io:format("CURRENT TAGS:~n~tp~n", [sets:to_list(Set)]),
    Options =
        [{"Add a tag",    1},
         {"Remove a tag", 2},
         {"Return",       3}],
    case zx_tty:select(Options) of
        1 ->
            New = string:casefold(zx_tty:get_input("~nEnter a new tag~n")),
            edit_tags(sets:add_element(New, Set));
        2 ->
            edit_tags(rem_item(Set));
        3 ->
            Set
    end.


-spec edit_exts(Set) -> NewSet
    when Set    :: sets:set(string()),
         NewSet :: sets:set(string()).

edit_exts(Set) ->
    ok = io:format("CURRENT ASSOCIATED FILE EXTENSIONS:~n~tp~n", [sets:to_list(Set)]),
    Options =
        [{"Add a tag",    1},
         {"Remove a tag", 2},
         {"Return",       3}],
    case zx_tty:select(Options) of
        1 ->
            New = dotify(string:lowercase(zx_tty:get_input("~nEnter a new tag~n"))),
            edit_tags(sets:add_element(New, Set));
        2 ->
            edit_tags(rem_item(Set));
        3 ->
            Set
    end.

dotify(S) ->
    Chars = lists:seq($a, $z) ++ lists:seq($0, $9),
    {_, T} = string:take(S, Chars, true),
    {H, _} = string:take(T, Chars, false),
    [$. | H].


rem_item(Set) ->
    ok = io:format("~nSelect an item to drop.~n"),
    Picked = zx_tty:select_string(sets:to_list(Set)),
    sets:del_element(Picked, Set).



-spec realm_exists(zx:realm()) -> boolean().
%% @private
%% Checks for remnants of a realm.

realm_exists(Realm) ->
    {ok, MRs} = zx_daemon:conf(managed),
    Managed = lists:member(Realm, MRs),
    Dirs = [zx_lib:path(D, Realm) || D <- [etc, var, tmp, log, key, zsp]],
    Check = fun(D) -> filelib:is_file(D) end,
    Found = lists:any(Check, Dirs),
    Managed or Found.


-spec make_realm_dirs(zx:realm()) -> ok.
%% @private
%% This is an unsafe operation. The caller must be sure realm_exists/1 returns false
%% or be certain some other way that the file:make_sure/1 calls will succeed.

make_realm_dirs(Realm) ->
    Dirs = [zx_lib:path(D, Realm) || D <- [etc, var, tmp, log, key, zsp, lib]],
    Make = fun(D) -> ok = zx_lib:force_dir(D) end,
    lists:foreach(Make, Dirs).


-spec export_realm() -> ok.

export_realm() ->
    {ok, Realm} = pick_realm(),
    export_realm(Realm).


-spec export_realm(zx:realm()) -> ok.

export_realm(Realm) ->
    {ok, RealmConf} = zx_lib:load_realm_conf(Realm),
    ok = tell("Realm found, creating realm file..."),
    KeyName = maps:get(key, RealmConf),
    {ok, PubDER} = zx_daemon:get_keybin(public, {Realm, KeyName}),
    Blob = term_to_binary({RealmConf, PubDER}),
    ZRF = Realm ++ ".zrf",
    ok = file:write_file(ZRF, Blob),
    tell("Realm conf file written to ~ts", [ZRF]).


-spec drop_realm(zx:realm()) -> ok.

drop_realm(Realm) ->
    case realm_exists(Realm) of
        true ->
            Message =
                "~nWARNING: Are you SURE you want to remove realm ~ts?~n"
                "(Only \"YES\" will confirm this action.)~n",
            ok = io:format(Message, [Realm]),
            case zx_tty:get_input() of
                "YES" ->
                    ok = zx_daemon:drop_realm(Realm),
                    tell("All traces of realm ~ts have been removed.", [Realm]);
                _ ->
                    tell("Aborting.")
            end;
        false ->
            tell("Could not find any trace of realm ~ts", [Realm])
    end.


-spec logpath(PackageString, Ago) -> zx:outcome()
    when PackageString :: string(),
         Ago           :: pos_integer().

logpath(PackageString, Ago) when Ago > 0 ->
    case zx_lib:package_id(PackageString) of
        {ok, PackageID} ->
            Path = zx_lib:ppath(log, PackageID),
            ok = zx_lib:force_dir(Path),
            {ok, Files} = file:list_dir(Path),
            Count = length(Files),
            case Ago =< Count of
                true ->
                    LogPath = lists:nth(Ago, lists:reverse(lists:sort(Files))),
                    io:format("~ts~n", [LogPath]);
                false ->
                    io:format("There are only ~w log files!~n", [Count])
            end;
        Error ->
            Error
    end;
logpath(_, Ago) when Ago < 1 ->
    Message = "I'm awesome, but even I can't remember the future. ~w runs ago...?~n",
    ok = io:format(Message, [Ago]).


-spec set_timeout(string()) -> zx:outcome().

set_timeout(String) ->
    case string:to_integer(String) of
        {Value, ""} when Value > 0 ->
            zx_daemon:conf(timeout, Value);
        _ ->
            {error, "Enter a positive integer. Common values are 3, 5 and 10.", 22}
    end.


-spec add_mirror() -> ok.

add_mirror() ->
    ok = tell("Adding a mirror to the local configuration..."),
    ok =
        case zx_daemon:conf(mirrors) of
            {ok, []} ->
                io:format("~nThere are NO MIRRORS currently.~n");
            {ok, Current} ->
                ok = io:format("~nCurrent mirrors:~n"),
                Print =
                    fun({A, P}) ->
                        S = stringify_address(A),
                        io:format("* ~s:~w~n", [S, P])
                    end,
                lists:foreach(Print, Current)
        end,
    Host = ask_addr(),
    Port = ask_port(),
    zx_daemon:add_mirror({Host, Port}).


-spec add_mirror(Address) -> zx:outcome()
    when Address :: string().

add_mirror(Address) ->
    add_mirror(Address, "11311").


-spec add_mirror(Address, PortString) -> zx:outcome()
    when Address    :: string(),
         PortString :: string().

add_mirror(Address, PortString) ->
    Host = parse_maybe_address(Address),
    try
        case list_to_integer(PortString) of
            Port when 16#ffff >= Port, Port > 0 ->
                zx_daemon:add_mirror({Host, Port});
            Illegal ->
                F = "Provided port number ~w is out of bound (1~65535).",
                Message = io_lib:format(F, [Illegal]),
                {error, Message}
        end
    catch error:badarg ->
        {error, "Provided port value is not a port number."}
    end.


-spec drop_mirror() -> ok.

drop_mirror() ->
    case zx_daemon:conf(mirrors) of
        {ok, []} ->
            io:format("No mirrors to drop!~n");
        {ok, Current} ->
            Optionize =
                fun(Host = {A, P}) ->
                    Label = io_lib:format("~s:~w", [stringify_address(A), P]),
                    {Label, Host}
                end,
            Options = lists:map(Optionize, Current),
            Selection = zx_tty:select(Options),
            zx_daemon:drop_mirror(Selection)
    end.


-spec drop_mirror(Address) -> zx:outcome()
    when Address :: string().

drop_mirror(Address) ->
    drop_mirror(Address, "11311").


-spec drop_mirror(Address, PortString) -> zx:outcome()
    when Address    :: string(),
         PortString :: string().

drop_mirror(Address, PortString) ->
    Host = parse_maybe_address(Address),
    try
        case list_to_integer(PortString) of
            Port when 16#ffff >= Port, Port > 0 ->
                zx_daemon:drop_mirror({Host, Port});
            Illegal ->
                F = "Provided port number ~w is out of bound (1~65535).",
                Message = io_lib:format(F, [Illegal]),
                {error, Message}
        end
    catch error:badarg ->
        {error, "Provided port value is not a port number."}
    end.


-spec select_user(zx:realm()) -> zx:user_name().

select_user(Realm) ->
    Pattern = filename:join(zx_lib:path(etc, Realm), "*.user"),
    LocalUsers = [filename:basename(UN, ".user") || UN <- filelib:wildcard(Pattern)],
    case LocalUsers of
        [] ->
            Message =
                "A user record is required to complete this action. Creating now...",
            ok = tell(Message),
            create_user(#user_data{realm = Realm});
        [UserName] ->
            UserName;
        UserNames ->
            zx_tty:select_string(UserNames)
    end.


-spec select_private_key(zx:user_id()) -> Result
    when Result :: {ok, {zx:key_name(), public_key:rsa_private_key()}}
                 | error.

select_private_key(UserID) ->
    {ok, #{keys := Keys}} = zx_userconf:load(UserID),
    Realm = element(1, UserID),
    select_private_key2(Realm, Keys).

select_private_key2(Realm, [KeyName | Rest]) ->
    case zx_daemon:get_key(private, {Realm, KeyName}) of
        {ok, Key} ->
            {ok, {KeyName, Key}};
        {error, Reason} ->
            ok = tell(warning, "zx_daemon:get_key/2 failed with: ~tp", [Reason]),
            select_private_key2(Realm, Rest)
    end;
select_private_key2(_, []) ->
    error.
