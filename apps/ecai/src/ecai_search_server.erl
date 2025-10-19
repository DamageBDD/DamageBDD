%%% ecai_search_server.erl
-module(ecai_search_server).
-behaviour(gen_server).

-export([start_link/0, get_ctx/0, init/1, handle_call/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_ctx() ->
    gen_server:call(?MODULE, get_ctx).

init([]) ->
    Ctx = ecai_search:new(),
    {ok, Ctx}.

handle_call(get_ctx, _From, Ctx) ->
    {reply, Ctx, Ctx}.
