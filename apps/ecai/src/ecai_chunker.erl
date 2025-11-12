%%%-------------------------------------------------------------------
%%% ecai_chunker.erl — async chunking job (mirrors ecai_indexer API)
%%%-------------------------------------------------------------------
-module(ecai_chunker).
-behaviour(gen_server).

-export([start/3, status/0, cancel/0]).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    job_id :: binary() | undefined,
    status :: idle | running | done | canceled | error,
    worker :: pid() | undefined,
    started_at :: integer() | undefined,
    ended_at :: integer() | undefined,
    %% #{in:=InPath, out:=OutDir, k:=ChunkSize}
    params :: map() | undefined,
    %% #{count:=N, paths:=[...]} | #{error:=Reason}
    result :: map() | undefined
}).

%% Public API ---------------------------------------------------------

start(InPath, OutDir, ChunkSize) when is_binary(InPath); is_list(InPath) ->
    ensure_started(),
    gen_server:call(
        ?MODULE, {start, #{in => to_bin(InPath), out => to_bin(OutDir), k => ChunkSize}}, 5000
    ).

status() ->
    ensure_started(),
    gen_server:call(?MODULE, status, 5000).

cancel() ->
    ensure_started(),
    gen_server:call(?MODULE, cancel, 5000).

%% Gen Server ---------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

init(#{} = _Args) ->
    {ok, #state{status = idle}}.

handle_call(status, _From, S0 = #state{}) ->
    {reply, state_to_map(S0), S0};
handle_call(cancel, _From, S0 = #state{status = running, worker = Pid}) when is_pid(Pid) ->
    _ = exit(Pid, kill),
    S1 = S0#state{status = canceled, ended_at = now_ms(), worker = undefined},
    {reply, #{ok => true, status => canceled, job_id => S1#state.job_id}, S1};
handle_call(cancel, _From, S0) ->
    {reply, #{ok => false, reason => not_running, status => S0#state.status}, S0};
handle_call(
    {start, _Params = #{in := _In, out := _Out, k := _K}}, _From, #state{status = running} = S0
) ->
    {reply, {error, busy}, S0};
handle_call({start, Params = #{in := In, out := Out, k := K}}, _From, S0) ->
    true = (is_integer(K) andalso K > 0),
    JobId = make_job_id(),
    Started = now_ms(),
    Parent = self(),
    Worker =
        spawn_link(fun() ->
            try
                Paths = ecai_yelp_loader:make_chunks_ndjson(In, Out, K),
                persistent_term:put(ecai_yelp_admin:get_k_chunks(), Paths),
                Parent ! {chunk_done, JobId, #{count => length(Paths), paths => Paths}}
            catch
                Class:Reason:Stack ->
                    ?LOG_ERROR("chunk job failed: ~p:~p ~p", [Class, Reason, Stack]),
                    Parent ! {chunk_error, JobId, {Class, Reason}}
            end
        end),
    S1 = S0#state{
        job_id = JobId,
        status = running,
        worker = Worker,
        started_at = Started,
        ended_at = undefined,
        params = Params,
        result = undefined
    },
    {reply, {ok, JobId}, S1}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({chunk_done, JobId, Result}, S0 = #state{job_id = JobId}) ->
    S1 = S0#state{
        status = done,
        ended_at = now_ms(),
        worker = undefined,
        result = Result
    },
    {noreply, S1};
handle_info({chunk_error, JobId, Reason}, S0 = #state{job_id = JobId}) ->
    S1 = S0#state{
        status = error,
        ended_at = now_ms(),
        worker = undefined,
        result = #{error => Reason}
    },
    {noreply, S1};
handle_info({'EXIT', Pid, _Why}, S0 = #state{worker = Pid, status = running}) ->
    %% If worker dies unexpectedly and we didn't mark done/error/canceled yet:
    S1 = S0#state{
        status = error, ended_at = now_ms(), worker = undefined, result = #{error => worker_exit}
    },
    {noreply, S1};
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

%% Helpers ------------------------------------------------------------

ensure_started() ->
    case whereis(?MODULE) of
        undefined -> start_link();
        _ -> ok
    end.

state_to_map(#state{
    job_id = J, status = St, started_at = A, ended_at = B, params = P, result = R
}) ->
    maps:put(
        result,
        R,
        #{
            job_id => J,
            status => St,
            started_at => A,
            ended_at => B,
            params => P
        }
    ).

make_job_id() ->
    Bin = crypto:strong_rand_bytes(12),
    list_to_binary([io_lib:format("~2.16.0B", [X]) || <<X:8>> <= Bin]).

now_ms() ->
    erlang:system_time(millisecond).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
