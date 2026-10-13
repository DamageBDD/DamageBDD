%%%-------------------------------------------------------------------
%%% Bounded asynchronous ECAI projector for DamageBDD analytics.
%%%
%%% ECAI search/relation/geometry work must never hold the analytics store or
%%% verification execution path. Requests are coalesced per report CID and one
%%% bounded projection runs at a time in this worker.
%%%-------------------------------------------------------------------
-module(damage_analytics_ecai_worker).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-behaviour(gen_server).

-export([start_link/0, project/3, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

project(ReportCid, Run, ProjectionHash) when
    is_binary(ReportCid), ReportCid =/= <<>>, is_map(Run), is_binary(ProjectionHash)
->
    case whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:cast(?SERVER, {project, ReportCid, Run, ProjectionHash})
    end;
project(_, _, _) ->
    ok.

status() ->
    case whereis(?SERVER) of
        undefined ->
            #{status => unavailable, pending => 0, running => false};
        _ ->
            try
                gen_server:call(?SERVER, status, 1000)
            catch
                _:_ -> #{status => unavailable, pending => 0, running => false}
            end
    end.

init([]) ->
    {ok, #{
        queue => queue:new(),
        queued => #{},
        pending => #{},
        running => false,
        completed => 0,
        failed => 0
    }}.

handle_call(status, _From, State) ->
    {reply,
        #{
            status => ok,
            pending => map_size(maps:get(pending, State, #{})),
            running => maps:get(running, State, false),
            completed => maps:get(completed, State, 0),
            failed => maps:get(failed, State, 0)
        },
        State};
handle_call(_Other, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast({project, ReportCid, Run, ProjectionHash}, State0) ->
    Pending0 = maps:get(pending, State0),
    Queued0 = maps:get(queued, State0),
    State1 = State0#{pending => Pending0#{ReportCid => {Run, ProjectionHash}}},
    State2 =
        case maps:is_key(ReportCid, Queued0) of
            true ->
                State1;
            false ->
                Queue1 = queue:in(ReportCid, maps:get(queue, State1)),
                State1#{queue => Queue1, queued => Queued0#{ReportCid => true}}
        end,
    {noreply, ensure_work(State2)};
handle_cast(_Other, State) ->
    {noreply, State}.

handle_info(work, State0) ->
    case queue:out(maps:get(queue, State0)) of
        {empty, _Queue} ->
            {noreply, State0#{running => false}};
        {{value, ReportCid}, Queue1} ->
            Pending0 = maps:get(pending, State0),
            Queued0 = maps:get(queued, State0),
            State1 = State0#{
                queue => Queue1,
                queued => maps:remove(ReportCid, Queued0),
                pending => maps:remove(ReportCid, Pending0)
            },
            State2 =
                case maps:get(ReportCid, Pending0, undefined) of
                    {Run, ProjectionHash} ->
                        Projection = damage_analytics_ecai:project_run(Run),
                        ok = damage_analytics_store:set_ecai_projection(
                            ReportCid, ProjectionHash, Projection
                        ),
                        case maps:get(status, Projection, unavailable) of
                            unavailable -> State1#{failed => maps:get(failed, State1, 0) + 1};
                            _ -> State1#{completed => maps:get(completed, State1, 0) + 1}
                        end;
                    undefined ->
                        State1
                end,
            case queue:is_empty(maps:get(queue, State2)) of
                true ->
                    {noreply, State2#{running => false}};
                false ->
                    self() ! work,
                    {noreply, State2#{running => true}}
            end
    end;
handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

ensure_work(#{running := true} = State) ->
    State;
ensure_work(State) ->
    self() ! work,
    State#{running => true}.
