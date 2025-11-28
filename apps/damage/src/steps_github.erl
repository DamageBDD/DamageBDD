-module(steps_github).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([step/6]).

%%-----------------------------------------------------------------------------
%% Step interface
%%-----------------------------------------------------------------------------

-spec step(
    %% Config
    proplists:proplist(),
    %% Context
    map(),
    %% <<"Given">> | <<"When">> | <<"Then">> | <<"And">> | documentation
    binary(),
    %% Line number
    integer(),
    %% Tokenized step text
    [string() | binary()],
    %% Docstring / body (unused here)
    iodata()
) -> map().

%%-----------------------------------------------------------------------------
%% Step patterns
%%-----------------------------------------------------------------------------

%% GIVEN
-define(STEP_GITHUB_OAUTH, ["I use github oauth token", Token]).
-define(STEP_GITHUB_BASIC_AUTH, ["I use github username", User, "and password", Password]).
-define(STEP_GITHUB_REPO, ["I use github repo", Repo]).

%% WHEN
-define(STEP_GITHUB_LOAD_ISSUE, ["I load github issue", IssueStr]).
-define(STEP_GITHUB_SET_STATUS, [
    "I set github status for sha", Sha, "to", State, "with description", Desc, "and context", Ctx
]).

%% THEN
-define(STEP_GITHUB_ISSUE_STATE, ["the github issue state should be", ExpectedState]).
-define(STEP_GITHUB_COMBINED_STATUS, [
    "the github combined status for ref", Ref, "should be", ExpectedStatus
]).

%%-----------------------------------------------------------------------------
%% Documentation variants
%%-----------------------------------------------------------------------------

step(_Config, _Context, documentation, _N, ?STEP_GITHUB_OAUTH, _) ->
    "GIVEN: Configure GitHub OAuth token for subsequent GitHub steps";

step(_Config, _Context, documentation, _N, ?STEP_GITHUB_BASIC_AUTH, _) ->
    "GIVEN: Configure GitHub basic authentication (username & password)";

step(_Config, _Context, documentation, _N, ?STEP_GITHUB_REPO, _) ->
    "GIVEN: Select the GitHub repository in \"owner/repo\" format";

step(_Config, _Context, documentation, _N, ?STEP_GITHUB_LOAD_ISSUE, _) ->
    "WHEN: Load a GitHub issue by number and store it in the Context";

step(_Config, _Context, documentation, _N, ?STEP_GITHUB_SET_STATUS, _) ->
    "WHEN: Create a GitHub commit/PR status for the given SHA";

step(_Config, _Context, documentation, _N, ?STEP_GITHUB_ISSUE_STATE, _) ->
    "THEN: Assert that the previously loaded GitHub issue has the expected state (open/closed)";

step(_Config, _Context, documentation, _N, ?STEP_GITHUB_COMBINED_STATUS, _) ->
    "THEN: Assert the combined GitHub status for a ref / SHA (success, failure, etc.)";

%%-----------------------------------------------------------------------------
%% GIVEN: OAuth credentials
%%-----------------------------------------------------------------------------

step(_Config, Context, <<"Given">>, _N, ?STEP_GITHUB_OAUTH, _) ->
    ensure_egithub_started(),
    Token1 = string:trim(Token),
    Cred = egithub:oauth(list_to_binary(Token1)),
    maps:put(github_credentials, Cred ,Context);

%%-----------------------------------------------------------------------------
%% GIVEN: Basic auth credentials
%%-----------------------------------------------------------------------------

step(_Config, Context, <<"Given">>, _N, ?STEP_GITHUB_BASIC_AUTH, _) ->
    ensure_egithub_started(),
    User1 = string:trim(User),
    Pass1 = string:trim(Password),
    Cred = egithub:basic_auth(User1, Pass1),
    maps:put(github_credentials, Cred ,Context);


%%-----------------------------------------------------------------------------
%% GIVEN: Repository selection
%%-----------------------------------------------------------------------------

step(_Config, Context, <<"Given">>, _N, ?STEP_GITHUB_REPO, _) ->
    Repo1 = string:trim(Repo),
    maps:put(github_repo, Repo1,Context);

%%-----------------------------------------------------------------------------
%% WHEN: Load GitHub issue (GET issue)
%%-----------------------------------------------------------------------------

step(_Config, Context, <<"When">>, N, ?STEP_GITHUB_LOAD_ISSUE, _) ->
    ensure_egithub_started(),
    case get_cred_repo(Context) of
        {error, Msg, Ctx1} ->
            ?LOG_ERROR("GitHub issue load failed (line ~p): ~s", [N, Msg]),
            maps:put(fail, Msg, Ctx1);
        {ok, Cred, Repo1, Ctx1} ->
            case safe_list_to_integer(string:trim(IssueStr)) of
                {error, bad_integer} ->
                    Msg = io_lib:format(
                            "Invalid GitHub issue number: ~p", [IssueStr]),
                    ?LOG_ERROR("~s", [Msg]),
                    maps:put(fail, lists:flatten(Msg), Ctx1);
                {ok, IssueNo} ->
                    case egithub:issue(Cred, Repo1, IssueNo) of
                        {ok, IssueJson} ->
                            maps:put(github_issue, IssueJson, Ctx1);
                        Error ->
                            Msg = io_lib:format(
                                    "Error loading GitHub issue ~p in ~s: ~p",
                                    [IssueNo, Repo1, Error]),
                            ?LOG_ERROR("~s", [Msg]),
                            maps:put(fail, lists:flatten(Msg), Ctx1)
                    end
            end
    end;


%%-----------------------------------------------------------------------------
%% WHEN: Set commit / PR status (GitHub Status API)
%%
%%   When I set github status for sha "abc123" to "success"
%%   with description "DamageBDD tests" and context "damagebdd/ci"
%%-----------------------------------------------------------------------------

step(_Config, Context, <<"When">>, N, ?STEP_GITHUB_SET_STATUS, _) ->
    ensure_egithub_started(),
    case get_cred_repo(Context) of
        {error, Msg, Ctx1} ->
            ?LOG_ERROR("GitHub set status failed (line ~p): ~s", [N, Msg]),
            maps:put(fail, Msg, Ctx1);
        {ok, Cred, Repo1, Ctx1} ->
            Sha1   = string:trim(Sha),
            State1 = string:trim(State),
            Desc1  = string:trim(Desc),
            CtxStr = string:trim(Ctx),
            case egithub:create_status(Cred, Repo1, Sha1, State1, Desc1, CtxStr) of
                {ok, StatusJson} ->
                    maps:put(github_status, StatusJson, Ctx1);
                Error ->
                    Msg = io_lib:format(
                            "Error creating GitHub status for ~s@~s: ~p",
                            [Repo1, Sha1, Error]),
                    ?LOG_ERROR("~s", [Msg]),
                    maps:put(fail, lists:flatten(Msg), Ctx1)
            end
    end;

%%-----------------------------------------------------------------------------
%% THEN: Assert issue state (open / closed)
%%
%%   Then the github issue state should be "open"
%%-----------------------------------------------------------------------------

step(_Config, Context, <<"Then">>, _N, ?STEP_GITHUB_ISSUE_STATE, _) ->
    case maps:get(github_issue, Context, undefined) of
        undefined ->
            Msg = "No github_issue found in Context. Did you call 'When I load github issue ...'?",
            maps:put(fail, Msg, Context);
        IssueJson ->
            Expected1 = string:lowercase(string:trim(ExpectedState)),
            Actual0   = github_get_state(IssueJson),
            Actual1   = string:lowercase(Actual0),
            case Actual1 of
                Expected1 ->
                    Context;
                _ ->
                    Msg = io_lib:format(
                            "GitHub issue state mismatch. Expected ~s, got ~s",
                            [Expected1, Actual1]),
                    maps:put(fail, lists:flatten(Msg), Context)
            end
    end;

%%-----------------------------------------------------------------------------
%% THEN: Assert combined status for a ref / SHA
%%
%%   Then the github combined status for ref "abc123" should be "success"
%%-----------------------------------------------------------------------------

step(_Config, Context, <<"Then">>, N, ?STEP_GITHUB_COMBINED_STATUS, _) ->
    ensure_egithub_started(),
    case get_cred_repo(Context) of
        {error, Msg, Ctx1} ->
            ?LOG_ERROR("GitHub combined_status failed (line ~p): ~s", [N, Msg]),
            maps:put(fail, Msg, Ctx1);
        {ok, Cred, Repo1, Ctx1} ->
            Ref1 = string:trim(Ref),
            case egithub:combined_status(Cred, Repo1, Ref1) of
                {ok, StatusJson} ->
                    Actual0 = github_get_state(StatusJson),
                    Actual1 = string:lowercase(Actual0),
                    Expected1 = string:lowercase(string:trim(ExpectedStatus)),
                    case Actual1 of
                        Expected1 ->
                            %% Also stash last combined_status for later inspection
                            maps:put(github_combined_status,StatusJson, Ctx1);
                        _ ->
                            Msg = io_lib:format(
                                    "GitHub combined status mismatch for ~s@~s. "
                                    "Expected ~s, got ~s",
                                    [Repo1, Ref1, Expected1, Actual1]),
                            maps:put(fail, lists:flatten(Msg), Ctx1)
                    end;
                Error ->
                    Msg = io_lib:format(
                            "Error fetching GitHub combined status for ~s@~s: ~p",
                            [Repo1, Ref1, Error]),
                    ?LOG_ERROR("~s", [Msg]),
                    maps:put(fail, lists:flatten(Msg), Ctx1)
            end
    end.

%%-----------------------------------------------------------------------------
%% Internal helpers
%%-----------------------------------------------------------------------------

ensure_egithub_started() ->
    case application:ensure_all_started(egithub) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Failed to start egithub application: ~p", [Reason]),
            ok
    end.

%% Get credentials and repo from Context or return an error
get_cred_repo(Context) ->
    Cred = maps:get(github_credentials, Context, undefined),
    Repo = maps:get(github_repo, Context, undefined),
    case {Cred, Repo} of
        {undefined, _} ->
            {error,
                "GitHub credentials not configured. Use "
                "\"Given I use github oauth token \\\"...\\\"\" or "
                "\"Given I use github username \\\"...\\\" and password \\\"...\\\"\"", Context};
        {_, undefined} ->
            {error,
                "GitHub repository not configured. Use "
                "\"Given I use github repo \\\"owner/repo\\\"\"", Context};
        {C, R} ->
            {ok, C, R, Context}
    end.

%% Safe integer parsing
safe_list_to_integer(Str) ->
    try
        {ok, list_to_integer(Str)}
    catch
        error:badarg ->
            {error, bad_integer}
    end.

%% Extract a "state" field from GitHub JSON
%% Handles both maps and proplists reasonably.
github_get_state(Json) when is_map(Json) ->
    %% prefer <<"state">>, then 'state'
    case maps:get(<<"state">>, Json, undefined) of
        undefined ->
            case maps:get(state, Json, undefined) of
                undefined -> "";
                V when is_binary(V) -> binary_to_list(V);
                V when is_list(V) -> V;
                V -> io_lib:format("~p", [V])
            end;
        V when is_binary(V) ->
            binary_to_list(V);
        V when is_list(V) ->
            V;
        V ->
            io_lib:format("~p", [V])
    end;
github_get_state(Json) when is_list(Json) ->
    %% Assume proplist-ish
    case proplists:get_value(<<"state">>, Json, undefined) of
        undefined ->
            case proplists:get_value("state", Json, undefined) of
                undefined -> "";
                V when is_binary(V) -> binary_to_list(V);
                V when is_list(V) -> V;
                V -> io_lib:format("~p", [V])
            end;
        V when is_binary(V) ->
            binary_to_list(V);
        V when is_list(V) ->
            V;
        V ->
            io_lib:format("~p", [V])
    end;
github_get_state(Other) ->
    io_lib:format("~p", [Other]).
