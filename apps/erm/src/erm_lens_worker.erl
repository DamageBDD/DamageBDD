%%% Owned asynchronous jobs. A monitor alone does not tie a job to its caller.
%%% The guardian survives task exceptions, but kills the task if the owner dies
%%% (including kill and normal exits). Result messages identify the guardian.
-module(erm_lens_worker).
-export([start/2]).

-spec start(atom(), fun(() -> term())) -> {pid(), reference()}.
start(Tag, Fun) when is_atom(Tag), is_function(Fun, 0) ->
    Owner = self(),
    spawn_monitor(fun() -> guard(Owner, Tag, Fun) end).

guard(Owner, Tag, Fun) ->
    process_flag(trap_exit, true),
    OwnerMon = erlang:monitor(process, Owner),
    Guardian = self(),
    Task = spawn_link(fun() -> Guardian ! {complete, self(), Fun()} end),
    receive
        {complete, Task, Result} ->
            erlang:demonitor(OwnerMon, [flush]),
            Owner ! {Tag, self(), Result};
        {'DOWN', OwnerMon, process, Owner, _} ->
            exit(Task, kill);
        {'EXIT', Task, Reason} ->
            erlang:demonitor(OwnerMon, [flush]),
            exit({job_exit, Reason});
        {'EXIT', _From, Reason} ->
            exit(Task, kill),
            exit(Reason)
    end.
