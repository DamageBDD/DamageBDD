%% Single-writer, node-local durable checkpoints. DETS is not distributed consensus.
-module(damage_agent_store).
-behaviour(gen_server).
-license("Apache-2.0").
-export([start_link/0, create/1, save/3, get/2, all/0, list/1, events/2, bundle/2, verify/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3,format_status/1]).

start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
create(J) -> gen_server:call(?MODULE,{create,J},15000).
save(J,Kind,Data) -> gen_server:call(?MODULE,{save,J,Kind,Data},15000).
get(O,Id) -> gen_server:call(?MODULE,{get,O,Id}).
all() -> gen_server:call(?MODULE,all).
list(O) -> gen_server:call(?MODULE,{list,O}).
events(O,Id) -> gen_server:call(?MODULE,{events,O,Id}).
%% Snapshot and events must come from one store read, including during execution.
bundle(O,Id) -> gen_server:call(?MODULE,{bundle,O,Id}).

init([]) ->
    Dir = damage_agent_policy:env(state_dir,"data/agentic"),
    ok = filelib:ensure_dir(filename:join(Dir,"tasks.dets")),
    ok = file:change_mode(Dir,8#700),
    Path = filename:join(Dir,"tasks.dets"),
    {ok,Tab} = dets:open_file(?MODULE,[{file,Path},{type,set},{repair,true}]),
    ok = file:change_mode(Path,8#600),
    %% Refuse to continue from corrupt chains/snapshots; never silently reset them.
    ok = dets:foldl(fun({_Id,R},ok) -> verify(R) end,ok,Tab),
    {ok,Tab}.

handle_call({create,J},_From,Tab) ->
    O = maps:get(owner,J), Key = maps:get(request_id,J),
    Existing = dets:foldl(fun({_Id,#{task := T}},Acc) ->
        case {maps:get(owner,T),maps:get(request_id,T)} of
            {O,Key} -> T;
            _ -> Acc
        end
    end,none,Tab),
    case Existing of
        none ->
            Tasks = tasks(Tab),
            Unfinished = [T || T <- Tasks, not damage_agent_policy:terminal(maps:get(status,T))],
            OwnerCount = length([T || T <- Unfinished, maps:get(owner,T) =:= O]),
            case length(Tasks) < damage_agent_policy:env(max_saved_tasks,200) andalso
                 length(Unfinished) < damage_agent_policy:env(max_active_tasks,8) andalso
                 OwnerCount < damage_agent_policy:env(max_tasks_per_owner,2) of
                true -> {New,R} = record(J,created,#{},[]),
                        ok = put(Tab,New,R), {reply,{ok,New,new},Tab};
                false -> {reply,{error,task_quota_exceeded},Tab}
            end;
        T ->
            case maps:get(request_hash,T) =:= maps:get(request_hash,J) of
                true -> {reply,{ok,T,duplicate},Tab};
                false -> {reply,{error,idempotency_conflict},Tab}
            end
    end;
handle_call({save,J,Kind,Data},_From,Tab) ->
    Id = maps:get(id,J),
    case dets:lookup(Tab,Id) of
        [{Id,#{task := Old,events := Es}}] ->
            case maps:get(revision,J) =:= maps:get(revision,Old) andalso
                 maps:get(owner,J) =:= maps:get(owner,Old) of
                true -> {New,R} = record(J,Kind,Data,Es),
                        ok = put(Tab,New,R), {reply,{ok,New},Tab};
                false -> {reply,{error,stale_checkpoint},Tab}
            end;
        [] -> {reply,{error,not_found},Tab}
    end;
handle_call({get,O,Id},_From,Tab) ->
    {reply,owned(Tab,O,Id,task),Tab};
handle_call({events,O,Id},_From,Tab) ->
    {reply,owned(Tab,O,Id,events),Tab};
handle_call({bundle,O,Id},_From,Tab) ->
    {reply,owned(Tab,O,Id,bundle),Tab};
handle_call({list,O},_From,Tab) ->
    {reply,[T || T <- tasks(Tab),maps:get(owner,T) =:= O],Tab};
handle_call(all,_From,Tab) -> {reply,tasks(Tab),Tab};
handle_call(_,_From,Tab) -> {reply,{error,bad_request},Tab}.
handle_cast(_,Tab) -> {noreply,Tab}.
handle_info(_,Tab) -> {noreply,Tab}.
terminate(_,Tab) -> dets:close(Tab).
code_change(_,Tab,_) -> {ok,Tab}.

owned(Tab,O,Id,Field) ->
    case dets:lookup(Tab,Id) of
        [{Id,#{task := #{owner := O}} = R}] ->
            case Field of bundle -> {ok,R}; _ -> {ok,maps:get(Field,R)} end;
        _ -> {error,not_found}
    end.
tasks(Tab) -> dets:foldl(fun({_Id,#{task := T}},A) -> [T|A] end,[],Tab).
put(Tab,J,R) -> ok = dets:insert(Tab,{maps:get(id,J),R}), dets:sync(Tab).
record(J0,Kind,Data,Es) ->
    Seq = length(Es)+1,
    Prev = case Es of [] -> <<>>; _ -> maps:get(hash,lists:last(Es)) end,
    J = maps:remove(audit_head,J0#{revision => Seq,updated_at => erlang:system_time(second)}),
    E = #{schema => 1, sequence => Seq, previous => Prev, task_id => maps:get(id,J),
          time => erlang:system_time(second), kind => Kind, data => Data,
          snapshot_hash => damage_agent_codec:hash(J)},
    Hash = damage_agent_codec:hash(E),
    New = J#{audit_head => Hash},
    {New,#{task => New,events => Es++[E#{hash => Hash}]}}.

verify(#{task := J,events := Es}) when Es =/= [] ->
    {Head,Count} = lists:foldl(fun(E,{Prev,N}) ->
        Prev = maps:get(previous,E),
        N = maps:get(sequence,E),
        H = damage_agent_codec:hash(maps:remove(hash,E)),
        H = maps:get(hash,E),
        {H,N+1}
    end,{<<>>,1},Es),
    Head = maps:get(audit_head,J),
    true = Count-1 =:= maps:get(revision,J),
    HJ = damage_agent_codec:hash(maps:remove(audit_head,J)),
    HJ = maps:get(snapshot_hash,lists:last(Es)), ok.

format_status(Status) -> maps:map(fun(log,_) -> []; (_,_) -> redacted end,Status).
