%% Asynchronous task controls for DamageBDD. No step can approve its own plan.
-module(steps_agentic).
-license("Apache-2.0").
-export([step/6,step_dry/6]).

step(_C,_Ctx,documentation,_N,Parts,_) -> documentation(Parts);
step(C,Ctx,_K,_N,["I use agent template",Template],_) ->
    safe(Ctx,fun() ->
        {ok,_} = damage_agent_policy:template(owner(C,Ctx),b(Template)),
        set_ns(Ctx,(ns(Ctx))#{template => b(Template)})
    end);
step(C,Ctx,_K,N,["I start an agent task named",Name,"with objective"],Body) ->
    safe(Ctx,fun() ->
        Alias = b(Name), true = damage_agent_codec:text(Alias,80),
        NS = ns(Ctx), Tasks = maps:get(tasks,NS,#{}),
        true = not maps:is_key(Alias,Tasks),
        %% Stable within the same parent run/line; scheduling a new run creates a new task.
        Run = b(proplists:get_value(run_id,C,"interactive")),
        Key = damage_agent_codec:hash([owner(C,Ctx),Run,N,Alias]),
        Goal = b(Body),
        {ok,Task} = damage_agent:start(owner(C,Ctx),maps:get(template,NS),Goal,Key),
        Id = maps:get(id,Task),
        set_ns(Ctx,NS#{tasks => Tasks#{Alias => Id},last => task_summary(Task)})
    end);
step(C,Ctx,_K,_N,["I refresh agent task",Name],_) -> refresh(C,Ctx,Name);
step(C,Ctx,_K,_N,["I pause agent task",Name],_) -> command(C,Ctx,Name,<<"pause">>);
step(C,Ctx,_K,_N,["I resume agent task",Name],_) -> command(C,Ctx,Name,<<"resume">>);
step(C,Ctx,_K,_N,["I cancel agent task",Name],_) -> command(C,Ctx,Name,<<"cancel">>);
step(C,Ctx,_K,_N,["I await agent task",Name,"for",Seconds,"seconds"],_) ->
    safe(Ctx,fun() ->
        S = binary_to_integer(b(Seconds)), true = S >= 0 andalso S =< 60,
        await(C,Ctx,Name,erlang:monotonic_time(millisecond)+S*1000)
    end);
step(C,Ctx,_K,_N,["the agent task",Name,"should be",Expected],_) ->
    safe(Ctx,fun() ->
        {ok,J} = damage_agent:status(owner(C,Ctx),id(Ctx,Name)),
        true = b(maps:get(status,J)) =:= b(Expected),
        set_ns(Ctx,(ns(Ctx))#{last => task_summary(J)})
    end);
step(C,Ctx,_K,_N,["the agent task",Name,"should be accepted"],_) -> refresh(C,Ctx,Name);
step(C,Ctx,_K,_N,["the agent task",Name,"should have settled accounting"],_) ->
    safe(Ctx,fun() ->
        {ok,J} = damage_agent:status(owner(C,Ctx),id(Ctx,Name)),
        true = maps:get(status,maps:get(budget,J)) =:= complete,
        set_ns(Ctx,(ns(Ctx))#{last => task_summary(J)})
    end);
step(C,Ctx,_K,_N,["the agent task",Name,"should stay within its monetary budget"],_) ->
    safe(Ctx,fun() ->
        {ok,J} = damage_agent:status(owner(C,Ctx),id(Ctx,Name)),
        B = maps:get(budget,J), true = maps:get(mode,B) =:= aeternity,
        true = maps:get(spent_units,B) =< maps:get(max_cost_units,B),
        set_ns(Ctx,(ns(Ctx))#{last => task_summary(J)})
    end);
step(C,Ctx,_K,_N,["the agent task",Name,"should have learning evidence"],_) ->
    safe(Ctx,fun() ->
        {ok,Events} = damage_agent:events(owner(C,Ctx),id(Ctx,Name)),
        true = Events =/= [],
        %% Do not put private source/model artifacts into public parent-run reports.
        set_ns(Ctx,(ns(Ctx))#{evidence_head => maps:get(hash,lists:last(Events))})
    end).

step_dry(_C,Ctx,_K,_N,["I use agent template",_Template],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["I start an agent task named",_Name,"with objective"],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["I refresh agent task",_Name],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["I pause agent task",_Name],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["I resume agent task",_Name],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["I cancel agent task",_Name],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["I await agent task",_Name,"for",_Seconds,"seconds"],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["the agent task",_Name,"should be",_Expected],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["the agent task",_Name,"should be accepted"],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["the agent task",_Name,"should have learning evidence"],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["the agent task",_Name,"should have settled accounting"],_) -> Ctx;
step_dry(_C,Ctx,_K,_N,["the agent task",_Name,"should stay within its monetary budget"],_) -> Ctx.

b(X) -> damage_agent_codec:bin(X).
owner(C,Ctx) ->
    %% Authentication must pin public_key in server-owned Config. Never grant
    %% capabilities from a mutable user variable or a model-produced context.
    Raw = proplists:get_value(public_key,C),
    true = is_binary(Raw) orelse is_list(Raw),
    O = b(Raw),
    true = damage_agent_codec:text(O,200),
    true = O =:= b(maps:get(public_key,Ctx)), O.
ns(Ctx) -> maps:get(agentic,Ctx,#{}).
set_ns(Ctx,NS) -> Ctx#{agentic => NS}.
id(Ctx,Name) -> maps:get(b(Name),maps:get(tasks,ns(Ctx),#{})).
safe(Ctx,Fun) -> try Fun() catch _:_ -> Ctx#{fail => <<"Agent task operation failed; inspect the private task dashboard.">>} end.
refresh(C,Ctx,Name) -> safe(Ctx,fun() ->
    {ok,J} = damage_agent:status(owner(C,Ctx),id(Ctx,Name)),
    set_ns(Ctx,(ns(Ctx))#{last => task_summary(J)}) end).
command(C,Ctx,Name,Cmd) -> safe(Ctx,fun() ->
    {ok,J} = damage_agent:command(owner(C,Ctx),id(Ctx,Name),Cmd,<<>>),
    set_ns(Ctx,(ns(Ctx))#{last => task_summary(J)}) end).
await(C,Ctx,Name,Deadline) ->
    {ok,J} = damage_agent:status(owner(C,Ctx),id(Ctx,Name)),
    Status = maps:get(status,J),
    Stop = damage_agent_policy:terminal(Status) orelse
           lists:member(Status,[awaiting_approval,paused,interrupted,accounting_pending]) orelse
           erlang:monotonic_time(millisecond) >= Deadline,
    case Stop of
        true -> set_ns(Ctx,(ns(Ctx))#{last => task_summary(J)});
        false -> timer:sleep(min(250,max(1,Deadline-erlang:monotonic_time(millisecond)))),
                 await(C,Ctx,Name,Deadline)
    end.

task_summary(J) ->
    S = maps:with([id,status,iteration,deadline,reason,audit_head,execution_status],J),
    S#{budget => maps:with([mode,status,max_cost_units,spent_units,remaining_units],
                          maps:get(budget,J,#{}))}.

documentation(["I use agent template",_]) -> "Select an operator-approved agent task template";
documentation(["I start an agent task named",_,"with objective"]) -> "Start asynchronously; objective is the docstring";
documentation(["I refresh agent task",_]) -> "Read account-scoped task status";
documentation(["I pause agent task",_]) -> "Pause at the next safe boundary";
documentation(["I resume agent task",_]) -> "Resume without changing budgets or authorising uncertain effects";
documentation(["I cancel agent task",_]) -> "Cancel locally; external effects may need reconciliation";
documentation(["I await agent task",_,"for",_,"seconds"]) -> "Optional bounded join, at most 60 seconds";
documentation(["the agent task",_,"should be",_]) -> "Assert exact current task status";
documentation(["the agent task",_,"should be accepted"]) -> "Assert that the task exists, not that it succeeded";
documentation(["the agent task",_,"should have settled accounting"]) -> "Assert settlement and receipt inclusion, not task correctness";
documentation(["the agent task",_,"should stay within its monetary budget"]) -> "Assert integer invocation charges do not exceed the pinned ceiling";
documentation(["the agent task",_,"should have learning evidence"]) -> "Assert an audit trail exists; never publish private evidence in the parent context".
