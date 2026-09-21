-module(damage_config).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("damage.hrl").

-export([get_default_config/1, state_dir/0, runs_dir/0, normalize_path/1, ensure_directory/1]).

-spec get_default_config(proplists:proplist() | map()) -> proplists:proplist().
get_default_config(ConfigIn0) ->
    C0 = normalize(ConfigIn0),

    %% --- load defaults from app env --------------------------------------
    %% Execution output is runtime state.  Keep it beneath the shared Damage
    %% state root instead of writing account/run directories directly under
    %% /var/lib/damage or the repository working directory.
    %%
    %% Precedence:
    %%   request/config data_dir        (per-run/internal compatibility override)
    %%   request/config runs_dir
    %%   damage.runs_dir
    %%   damage.state_dir/runtime/runs
    %%   damage.secrets_state_dir/runtime/runs (compatibility)
    %%   $XDG_STATE_HOME/damage/runtime/runs
    %%   $HOME/.local/state/damage/runtime/runs
    %%   /var/lib/damage/runtime/runs
    %%
    %% The old global damage.data_dir setting is intentionally not used as the
    %% runner root anymore.  It was too broad and commonly pointed at
    %% /var/lib/damage.  Use damage.runs_dir for an explicit execution override.
    DataDir0 = maps:get(data_dir, C0, maps:get(runs_dir, C0, runs_dir())),
    ChromeDrv0 = maps:get(
        chromedriver, C0, application:get_env(damage, chromedriver, "chromedriver")
    ),

    %% --- required: public_key drives per-account isolation ----------------
    AeAccount0 = must_get(public_key, C0),

    %% --- normalize types for filename:join --------------------------------
    DataDir = normalize_path(DataDir0),
    AeAccount = to_str(AeAccount0),
    ChromeDrv = to_str(ChromeDrv0),

    %% --- run id & dirs ----------------------------------------------------
    RunId = to_str(maps:get(run_id, C0, gen_run_id())),
    AccountDir = filename:join(DataDir, AeAccount),
    RunDir0 = maps:get(run_dir, C0, filename:join(AccountDir, RunId)),
    RunDir = normalize_path(RunDir0),
    ReportDir = filename:join(RunDir, "reports"),
    ArtifactsDir = filename:join(RunDir, "artifacts"),

    %% Create every level explicitly. filelib:ensure_dir/1 is recursive, but
    %% keeping the layout steps explicit makes failures identify the exact
    %% server-owned directory that could not be prepared.
    ok = ensure_directory(DataDir),
    ok = ensure_directory(AccountDir),
    ok = ensure_directory(RunDir),
    ok = ensure_directory(ReportDir),
    ok = ensure_directory(ArtifactsDir),

    %% --- built-in reports (durable on-disk) -------------------------------
    TextReport = filename:join([ReportDir, <<"{{process_id}}.plain.txt">>]),
    TextReportColor = filename:join([ReportDir, <<"{{process_id}}.color.txt">>]),
    HtmlReport = filename:join([ReportDir, <<"{{process_id}}.html">>]),
    DefaultInFormatters =
        [
            {text, #{output => TextReportColor, color => true}},
            {text, #{output => TextReport, color => false}},
            {html, #{output => HtmlReport}}
        ],

    %% --- user-provided knobs ----------------------------------------------
    Concurrency = max(1, maps:get(concurrency, C0, 1)),
    UserFmts = maps:get(formatters, C0, []),

    %% Append user formatters after built-ins, then dedupe (keep last)
    FinalFormatters = dedupe_tuples(UserFmts ++ DefaultInFormatters),

    %% --- base config we guarantee -----------------------------------------
    Base = #{
        formatters => FinalFormatters,
        chromedriver => ChromeDrv,
        concurrency => Concurrency,
        data_dir => DataDir,
        runs_dir => DataDir,
        run_id => RunId,
        run_dir => RunDir,
        reports_dir => ReportDir,
        artifacts_dir => ArtifactsDir,
        proxy => {socks5, "127.0.0.1", 9050},
        strict_no_catchall => application:get_env(damage, strict_no_catchall, true)
    },

    %% --- merge everything: caller wins for scalars, keep our list merges ---
    %% Remove keys we already handled specially to avoid double-writing them.
    PassThrough = maps:without(
        [
            formatters,
            feature_dirs,
            chromedriver,
            concurrency,
            data_dir,
            runs_dir,
            run_id,
            run_dir,
            reports_dir,
            artifacts_dir,
            proxy
        ],
        C0
    ),
    Final = maps:merge(Base, PassThrough),

    maps:to_list(Final).

%% ========================= helpers =================================

normalize(M) when is_map(M) -> M;
normalize(L) when is_list(L) -> maps:from_list(L).

must_get(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error -> erlang:error({missing_required_key, Key})
    end.
gen_run_id() ->
    {ok, B} = datestring:format(<<"YmdHMS">>, erlang:localtime()),
    to_str(B).

runs_dir() ->
    case application:get_env(damage, runs_dir) of
        {ok, Dir} when is_binary(Dir); is_list(Dir) ->
            normalize_path(Dir);
        _ ->
            filename:join([state_dir(), "runtime", "runs"])
    end.

state_dir() ->
    case application:get_env(damage, state_dir) of
        {ok, Dir} when is_binary(Dir); is_list(Dir) ->
            normalize_path(Dir);
        _ ->
            case application:get_env(damage, secrets_state_dir) of
                {ok, Dir} when is_binary(Dir); is_list(Dir) ->
                    normalize_path(Dir);
                _ ->
                    default_state_dir()
            end
    end.

default_state_dir() ->
    case os:getenv("XDG_STATE_HOME") of
        Xdg when is_list(Xdg), Xdg =/= "" ->
            case filename:pathtype(Xdg) of
                absolute ->
                    filename:join(Xdg, "damage");
                _ ->
                    home_state_dir()
            end;
        _ ->
            home_state_dir()
    end.

home_state_dir() ->
    case os:getenv("HOME") of
        Home when is_list(Home), Home =/= "" ->
            filename:join([Home, ".local", "state", "damage"]);
        _ ->
            "/var/lib/damage"
    end.

normalize_path(Path0) ->
    Path1 = to_str(Path0),
    Path2 = expand_home_path(Path1),
    filename:absname(Path2).

expand_home_path("~") ->
    require_home("~");
expand_home_path([$~, $/ | Rest] = Path) ->
    filename:join(require_home(Path), Rest);
expand_home_path(Path) ->
    Path.

require_home(Path) ->
    case os:getenv("HOME") of
        Home when is_list(Home), Home =/= "" ->
            Home;
        _ ->
            erlang:error({home_directory_unavailable, Path})
    end.

ensure_directory(Dir) ->
    case filelib:ensure_dir(filename:join(Dir, ".keep")) of
        ok ->
            ok;
        {error, Reason} ->
            erlang:error({run_directory_failed, Dir, Reason})
    end.

to_str(B) when is_binary(B) -> binary_to_list(B);
to_str(A) when is_atom(A) -> atom_to_list(A);
to_str(L) when is_list(L) -> L;
to_str(Other) -> lists:flatten(io_lib:format("~p", [Other])).

dedupe_tuples(Ts) ->
    %% Keep last occurrence of an identical tuple
    lists:reverse(
        lists:foldl(
            fun(T, Acc) ->
                case lists:member(T, Acc) of
                    true -> Acc;
                    false -> [T | Acc]
                end
            end,
            [],
            lists:reverse(Ts)
        )
    ).
