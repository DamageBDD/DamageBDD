-module(damage_utils).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

-export(
  [
    render_body_args/2,
    tokenize/1,
    binarystr_join/1,
    binarystr_join/2,
    config/2,
    loaded_steps/0,
    lists_concat/2,
    strf/2,
    get_context_value/3,
    load_template/2,
    setup_vanillae_deps/0
  ]
).

get_stepargs(Body) when is_list(Body) ->
  case lists:keytake(docstring, 1, Body) of
    {value, {docstring, Doc}, Body0} ->
      {
        damage_utils:binarystr_join(Body0, <<" ">>),
        damage_utils:binarystr_join(Doc)
      };

    _ -> {damage_utils:binarystr_join(Body, <<" ">>), <<"">>}
  end.


render_body_args(Body, Context) ->
  {Body0, Args} = get_stepargs(Body),
  Body1 =
    damage_utils:tokenize(
      mustache:render(
        binary_to_list(Body0),
        dict:from_list(maps:to_list(Context))
      )
    ),
  Args0 =
    list_to_binary(
      mustache:render(
        binary_to_list(Args),
        dict:from_list(maps:to_list(Context))
      )
    ),
  {Body1, Args0}.


tokenize(Step) when is_binary(Step) -> tokenize(binary_to_list(Step));

tokenize(Step) ->
  Tokens = string:tokens(Step, "\""),
  [string:strip(X) || X <- Tokens].


binarystr_join(ListSep) -> binarystr_join(ListSep, <<"">>).

-spec binarystr_join([binary()], binary()) -> binary().
binarystr_join([], _Sep) -> <<>>;
binarystr_join([Part], _Sep) -> Part;

binarystr_join(List, Sep) ->
  lists:foldr(
    fun
      (A, B) ->
        if
          bit_size(B) > 0 -> <<A/binary, Sep/binary, B/binary>>;
          true -> A
        end
    end,
    <<>>,
    List
  ).


config(Config, Key) ->
  {Key, Value} = lists:keyfind(Key, 1, Config),
  Value.


loaded_steps() ->
  lists:filtermap(
    fun
      ({Module, _, _}) ->
        case string:split(Module, "_", all) of
          ["steps", _, "SUITE"] -> false;
          ["steps", _] -> {true, Module};
          _ -> false
        end
    end,
    code:all_available()
  ).


strf(String, Args) -> lists:flatten(io_lib:format(String, Args)).

lists_concat(L, N) -> lists:flatten(string:join([[X] || X <- L], N)).

-spec get_context_value(atom(), map(), list()) -> any().
get_context_value(Key, Context, Config) ->
  case lists:keyfind(key, 1, Config) of
    {_, Default} -> maps:get(Key, Context, Default);
    false -> maps:get(Key, Context)
  end.


setup_vanillae_deps() ->
  true = code:add_path("vanillae/ebin"),
  Vanillae =
    "otpr-vanillae-" ++ lists:droplast(os:cmd("zx latest otpr-vanillae")),
  Deps = string:lexemes(os:cmd("zx list deps " ++ Vanillae), "\n"),
  ZX =
    "otpr-zx-"
    ++
    lists:nth(2, string:lexemes(lists:droplast(os:cmd("zx --version")), " ")),
  Packages = [ZX, Vanillae | Deps],
  ZompLib = filename:join(os:getenv("HOME"), "zomp/lib"),
  Converted =
    [string:join(string:lexemes(Package, "-"), "/") || Package <- Packages],
  PackagePaths =
    [filename:join([ZompLib, PackagePath, "ebin"]) || PackagePath <- Converted],
  ok = code:add_paths(PackagePaths).


load_template(Template, Context) ->
  PrivDir = code:priv_dir(damage),
  FilePath = filename:join([PrivDir, "templates", Template]),
  logger:info("Loading template from ~p", [FilePath]),
  {ok, TemplateBin} = file:read_file(FilePath),
  mustache:render(binary_to_list(TemplateBin), Context).
