-module(damage_config).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("damage.hrl").

-export([get_default_config/1]).

-spec get_default_config(proplists:proplist() | map()) -> proplists:proplist().
get_default_config(ConfigIn0) ->
    C0 = normalize(ConfigIn0),

    %% --- load defaults from app env --------------------------------------
    DataDir0 = maps:get(data_dir, C0, application:get_env(damage, data_dir, "/var/lib/damage/")),
    ChromeDrv0 = maps:get(
        chromedriver, C0, application:get_env(damage, chromedriver, "chromedriver")
    ),

    %% --- required: public_key drives per-account isolation ----------------
    AeAccount0 = must_get(public_key, C0),

    %% --- normalize types for filename:join --------------------------------
    DataDir = to_str(DataDir0),
    AeAccount = to_str(AeAccount0),
    ChromeDrv = to_str(ChromeDrv0),

    %% --- run id & dirs ----------------------------------------------------
    RunId = maps:get(run_id, C0, gen_run_id()),
    AccountDir = filename:join(DataDir, AeAccount),
    RunDir = maps:get(run_dir, C0, filename:join(AccountDir, RunId)),
    ReportDir = filename:join([RunDir, <<"reports">>]),
    ArtifactsDir = filename:join([RunDir, <<"artifacts">>]),
    ok = damage_utils:ensure_dir(ReportDir),
    ok = damage_utils:ensure_dir(ArtifactsDir),

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
        run_id => RunId,
        run_dir => RunDir,
        reports_dir => ReportDir,
        artifacts_dir => ArtifactsDir,
        proxy => {socks5, "127.0.0.1", 9050}
    },

    %% --- merge everything: caller wins for scalars, keep our list merges ---
    %% Remove keys we already handled specially to avoid double-writing them.
    PassThrough = maps:without(
        [
            formatters,
            feature_dirs,
            chromedriver,
            concurrency,
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
