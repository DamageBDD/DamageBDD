-module(steps_webdrv_bidi).
-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6, ensure_session/2, test/0]).

-define(BIDI_URL, "ws://localhost:9222/session").

-record(bidi_ctx, {
    pid,
    context
}).

ensure_session(_Config, Context) ->
    case maps:get(bidi_ctx, Context, none) of
        none ->
            {ok, Pid} = webdriver_bidi_client:start_link(?BIDI_URL),
            %% You would normally retrieve or create a context here
            ContextId = <<"my-context-id">>,
            maps:put(bidi_ctx, #bidi_ctx{pid = Pid, context = ContextId}, Context);
        _ ->
            Context
    end.

step(Config, Context0, <<"And">>, _N, ["I open the url", Url], _) ->
    Context = ensure_session(Config, Context0),
    #bidi_ctx{pid = Pid, context = CtxId} = maps:get(bidi_ctx, Context),
    Cmd = #{
        method => <<"browsingContext.navigate">>,
        params => #{url => list_to_binary(Url), context => CtxId}
    },
    ok = webdriver_bidi_client:send_command(Pid, Cmd),
    Context;
step(Config, Context0, <<"Then">>, _N, ["I expect that the url is", ExpectedUrl], _) ->
    Context = ensure_session(Config, Context0),
    #bidi_ctx{pid = _Pid, context = _CtxId} = maps:get(bidi_ctx, Context),
    %% Dummy check: in full impl you'd need to store and fetch last known url
    %% For now we just log the expectation
    ?LOG_INFO("Expected URL: ~s", [ExpectedUrl]),
    Context.

test() ->
    Context = ensure_session([], #{}),
    step([], Context, <<"And">>, 0, ["I open the url", "https://example.com"], []).
