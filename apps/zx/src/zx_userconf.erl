%%% @doc
%%% ZX UserConf
%%%
%%% Handling user configuration data.
%%% @end

-module(zx_userconf).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([new/0, save/1, load/1, merge/2, merge/3, path/1]).

-type data() :: #{realm        := string(),
                  username     := string(),
                  realname     := string(),
                  contact_info := [zx:contact_info()],
                  keys         := [binary()]}.


new() ->
    #{realm        => "",
      username     => "",
      realname     => "",
      contact_info => "",
      keys         => []}.


-spec save(data()) -> ok | {error, file:posix()}.

save(Data = #{realm := Realm, username := UserName}) ->
    Path = path({Realm, UserName}),
    ok = filelib:ensure_dir(Path),
    Terms = maps:to_list(Data),
    zx_lib:write_terms(Path, Terms).


-spec load(UserID) -> Result
    when UserID :: zx:user_id(),
         Result :: {ok, zx:userconf()}
                 | {error, Reason},
         Reason :: bad_realm
                 | bad_user
                 | file:posix().

load(UserID = {Realm, _}) ->
    case zx_lib:realm_exists(Realm) of
        true  -> load2(UserID);
        false -> {error, bad_realm}
    end.

load2(UserID) ->
    case file:consult(path(UserID)) of
        {ok, Terms}     -> {ok, maps:from_list(Terms)};
        {error, enoent} -> {error, bad_user};
        Error           -> Error
    end.


-spec merge(New, Old) -> Merged
    when New    :: data(),
         Old    :: data(),
         Merged :: data().

merge(New, Old) ->
    merge(New, Old, []).


-spec merge(New, Old, Keys) -> Merged
    when New    :: data(),
         Old    :: data(),
         Keys   :: [zx:key_data()],
         Merged :: data().

merge(New, Old, KeyData) ->
    KeySet    = sets:from_list([element(1, K) || K <- KeyData]),
    NewKeySet = sets:from_list(maps:get(keys, New)),
    OldKeySet = sets:from_list(maps:get(keys, Old)),
    UltimateKeySet = sets:intersection([KeySet, NewKeySet, OldKeySet]),
    maps:put(keys, sets:to_list(UltimateKeySet), maps:merge(Old, New)).


-spec path(zx:user_id()) -> file:filename().

path({Realm, UserName}) ->
    filename:join(zx_lib:path(etc, Realm), UserName ++ ".user").
