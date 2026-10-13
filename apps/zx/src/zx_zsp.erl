%%% @doc
%%% ZX ZSP: The ZSP package interface
%%%
%%% ZSP files are project package files managed by Zomp and ZX. This module provides
%%% a common interface for interfacing with the contents of a ZSP file and a few helper
%%% functions.
%%% @end

-module(zx_zsp).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([new_meta/0,
         pack/2,
         unpack/1, blithely_unpack/1,
         extract/2, blithely_extract/2,
         verify/1, verify/2,
         meta/1, package_id/1,
         resign/2, resign/3]).

-export_type([meta/0]).

-include("zx_logger.hrl").


-type meta() :: #{package_id := undefined | zx:package_id(),
                  name       := string(),
                  desc       := string(),
                  author     := string(),
                  a_email    := string(),
                  copyright  := string(),
                  c_email    := string(),
                  license    := string(),
                  ws_url     := string(),
                  repo_url   := string(),
                  prefix     := string(),
                  tags       := [string()],
                  deps       := [zx:package_id()],
                  modules    := [string()],
                  type       := undefined | zx:package_type(),
                  key_name   := none | zx:key_name()}.


-spec new_meta() -> meta().

new_meta() ->
    #{package_id => undefined,
      name       => "",
      desc       => "",
      author     => "",
      a_email    => "",
      copyright  => "",
      c_email    => "",
      license    => "",
      ws_url     => "",
      repo_url   => "",
      prefix     => "",
      tags       => [],
      deps       => [],
      modules    => [],
      type       => undefined,
      key_name   => none,
      file_exts  => []}.


-spec pack(TargetDir, Key) -> Result
    when TargetDir :: file:filename(),
         Key       :: public_key:rsa_public_key(),
         Result    :: ok
                    | {error, file:posix()}.

pack(TargetDir, Key) ->
    case zx_lib:read_project_meta(TargetDir) of
        {ok, Meta} -> pack2(TargetDir, Key, Meta);
        Error      -> Error
    end.

pack2(TargetDir, Key, Meta) ->
    PackageID = maps:get(package_id, Meta),
    {ok, PackageString} = zx_lib:package_string(PackageID),
    ZspFile = PackageString ++ ".zsp",
    case filelib:is_regular(ZspFile) of
        false -> pack3(TargetDir, PackageID, Meta, Key, ZspFile);
        true  -> {error, eexists}
    end.

pack3(TargetDir, PackageID, Meta, {KeyName, Key}, ZspFile) ->
    Beams = filelib:wildcard("**/*.{beam,ez}", TargetDir),
    ToDelete = [filename:join(TargetDir, Beam) || Beam <- Beams],
    ok = lists:foreach(fun file:delete/1, ToDelete),
    ok = zx_lib:rm_rf(filename:join(TargetDir, "erl_crash.dump")),
    {ok, Everything} = file:list_dir(TargetDir),
    DotFiles = filelib:wildcard(".*", TargetDir),
    Targets = lists:subtract(Everything, DotFiles),
    {ok, CWD} = file:get_cwd(),
    ok = file:set_cwd(TargetDir),
    ok = zx_local:update_app_file(),
    Name = element(2, PackageID),
    AppFile = filename:join("ebin", Name ++ ".app"),
    {ok, [{application, _, AppData}]} = file:consult(AppFile),
    Modules = lists:map(fun atom_to_list/1, proplists:get_value(modules, AppData)),
    TarGzPath = filename:join(zx_lib:path(tmp), ZspFile ++ ".tgz"),
    ok = filelib:ensure_dir(TarGzPath),
    ok = erl_tar:create(TarGzPath, Targets, [compressed]),
    {ok, TgzBin} = file:read_file(TarGzPath),
    ok = file:delete(TarGzPath),
    MetaData = Meta#{key_name := KeyName, modules := Modules},
    MetaBin = term_to_binary(MetaData),
    MetaSize = byte_size(MetaBin),
    SignMe = <<MetaSize:24, MetaBin:MetaSize/binary, TgzBin/binary>>,
    Sig = zx_key:sign(SignMe, Key),
    SigSize = byte_size(Sig),
    ZspData = <<SigSize:24, Sig:SigSize/binary, SignMe/binary>>,
    ok = file:set_cwd(CWD),
    case file:write_file(ZspFile, ZspData) of
        ok    -> {ok, ZspFile};
        Error -> Error
    end.


-spec unpack(ZspFile) -> Outcome
    when ZspFile :: file:filename(),
         Outcome :: ok
                  | {error, Reason},
         Reason  :: bad_zsp
                  | bad_sig
                  | bad_key
                  | file:posix().

unpack(ZspFile) ->
    case file:read_file(ZspFile) of
        {ok, ZspBin} -> extract(ZspBin, cwd);
        Error        -> Error
    end.


-spec extract(ZspBin, Location) -> Outcome
    when ZspBin   :: binary(),
         Location :: cwd
                   | lib,
         Outcome  :: ok
                   | {error, Reason},
         Reason   :: bad_zsp
                   | bad_sig
                   | bad_key.

extract(ZspBin, Location) ->
    case verify(ZspBin) of
        ok    -> blithely_extract(ZspBin, Location);
        Error -> Error
    end.


-spec blithely_unpack(ZspFile) -> Outcome
    when ZspFile :: file:filename(),
         Outcome :: ok
                  | {error, Reason},
         Reason  :: bad_zsp
                  | file:posix().

blithely_unpack(ZspFile) ->
    case file:read_file(ZspFile) of
        {ok, ZspBin} -> blithely_extract(ZspBin, cwd);
        Error        -> Error
    end.


blithely_extract(ZspBin, cwd) ->
    {ok, Meta} = meta(ZspBin),
    PackageID = maps:get(package_id, Meta),
    {ok, PackageString} = zx_lib:package_string(PackageID),
    install(ZspBin, PackageString);
blithely_extract(ZspBin, lib) ->
    {ok, Meta} = meta(ZspBin),
    PackageID = maps:get(package_id, Meta),
    Path = zx_lib:ppath(lib, PackageID),
    install(ZspBin, Path).


install(<<SS:24, _:SS/binary, MS:24, _:MS/binary, TarGZ/binary>>, Path) ->
    ok = filelib:ensure_dir(Path),
    ok = zx_lib:rm_rf(Path),
    ok =
        case filelib:is_dir(Path) of
            true  -> ok;
            false -> file:make_dir(Path)
        end,
    erl_tar:extract({binary, TarGZ}, [{cwd, Path}, compressed]).


-spec verify(ZspBin) -> Outcome
    when ZspBin  :: binary(),
         Outcome :: ok
                  | {error, Reason},
         Reason  :: bad_zsp
                  | bad_sig
                  | bad_key.

verify(<<Size:24, Sig:Size/binary, Signed/binary>>) ->
    verify2(Sig, Signed);
verify(_) ->
    {error, bad_zsp}.

verify2(Sig, Signed = <<MetaSize:24, MetaBin:MetaSize/binary, _/binary>>) ->
    case zx_lib:b_to_ts(MetaBin) of
        {ok, #{package_id := {Realm, _, _}, key_name := SigKeyName}} ->
            SigKeyID = {Realm, SigKeyName},
            verify3(Sig, Signed, SigKeyID);
        error ->
            tell(info, "MetaBin: ~p", [MetaBin]),
            {error, bad_zsp}
    end;
verify2(_, _) ->
    {error, bad_zsp}.

verify3(Sig, Signed, SigKeyID) ->
    case zx_key:load(public, SigKeyID) of
        {ok, PubKey} ->
            verify4(Signed, Sig, PubKey);
        {error, Reason} ->
            Message = "zx_key:load(public, ~tp) failed with: ~tp",
            ok = log(warning, Message, [SigKeyID, Reason]),
            {error, bad_key}
    end.

verify4(Signed, Sig, PubKey) ->
    case zx_key:verify(Signed, Sig, PubKey) of
        true  -> ok;
        false -> {error, bad_sig}
    end.


-spec verify(ZspBin, PubKey) -> boolean()
    when ZspBin :: binary(),
         PubKey :: public_key:rsa_public_key().
        
verify(<<Size:24, Sig:Size/binary, Signed/binary>>, PubKey) ->
    zx_key:verify(Signed, Sig, PubKey).


-spec meta(binary()) -> {ok, meta()} | {error, bad_zsp}.

meta(<<SS:24, _:SS/binary, MS:24, MetaBin:MS/binary, _/binary>>) ->
    case zx_lib:b_to_ts(MetaBin) of
        {ok, Meta} -> {ok, Meta};
        _          -> {error, bad_zsp}
    end;
meta(_) ->
    {error, bad_zsp}.


-spec package_id(binary()) -> {ok, zx:package_id()} | {error, bad_zsp}.

package_id(Bin) ->
    case meta(Bin) of
        {ok, Meta} -> {ok, maps:get(package_id, Meta)};
        Error      -> Error
    end.


-spec resign(KeyID, ZspBin) -> Outcome
    when KeyID   :: zx:key_id(),
         ZspBin  :: binary(),
         Outcome :: {ok, binary()}
                  | {error, Reason},
         Reason  :: bad_zsp
                  | bad_realm
                  | no_key
                  | bad_key.

resign(KeyID = {Realm, KeyName},
       <<SS:24, _:SS/binary, MS:24, MetaBin:MS/binary, TarGZ/binary>>) ->
    case zx_daemon:get_key(private, KeyID) of
        {ok, Key} -> resign2(Realm, KeyName, Key, MetaBin, TarGZ);
        Error     -> Error
    end;
resign(_, _) ->
    {error, bad_zsp}.


-spec resign(KeyID, Key, ZspBin) -> Outcome
    when KeyID   :: zx:key_id(),
         Key     :: public_key:rsa_private_key(),
         ZspBin  :: binary(),
         Outcome :: {ok, binary()}
                  | {error, Reason},
         Reason  :: bad_zsp
                  | bad_realm
                  | no_key
                  | bad_key.

resign({Realm, KeyName}, 
       Key,
       <<SS:24, _:SS/binary, MS:24, MetaBin:MS/binary, TarGZ/binary>>) ->
    resign2(Realm, KeyName, Key, MetaBin, TarGZ);
resign(_, _, _) ->
    {error, bad_zsp}.

resign2(Realm, KeyName, Key, MetaBin, TarGZ) ->
    case zx_lib:b_to_ts(MetaBin) of
        {ok, Meta} -> resign3(Realm, KeyName, Key, Meta, TarGZ);
        error      -> {error, bad_zsp}
    end.

resign3(Realm, KeyName, Key, Meta = #{package_id := {_, Name, Version}}, TarGZ) ->
    NewMeta = Meta#{package_id := {Realm, Name, Version}, key_name := KeyName},
    MetaBin = term_to_binary(NewMeta),
    MetaSize = byte_size(MetaBin),
    SignMe = <<MetaSize:24, MetaBin:MetaSize/binary, TarGZ/binary>>,
    Sig = zx_key:sign(SignMe, Key),
    SigSize = byte_size(Sig),
    ZspBin = <<SigSize:24, Sig:SigSize/binary, SignMe/binary>>,
    {ok, ZspBin}.
