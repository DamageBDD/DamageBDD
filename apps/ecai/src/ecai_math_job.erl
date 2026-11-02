%% Bounded local BEAM worker. This is not an OS security sandbox.
-module(ecai_math_job).
-export([run/2]).
-spec run(fun(() -> term()), pos_integer()) -> term().
run(Fun, Timeout) when is_function(Fun,0), is_integer(Timeout),
                       Timeout > 0, Timeout =< 60000 ->
    Parent = self(), Tag = make_ref(),
    {Pid,Mon} = spawn_opt(fun() ->
        Result = try Fun() catch
            error:Reason -> {error,Reason};
            throw:Reason -> {error,Reason};
            exit:Reason -> {error,{worker_exit,Reason}}
        end,
        Parent ! {Tag,self(),Result}
    end, [monitor,{max_heap_size,#{size=>4000000,kill=>true,error_logger=>false}}]),
    receive
        {Tag,Pid,Result} -> erlang:demonitor(Mon,[flush]), Result;
        {'DOWN',Mon,process,Pid,Reason} -> {error,{worker_exit,Reason}}
    after Timeout ->
        exit(Pid,kill),
        receive {'DOWN',Mon,process,Pid,_} -> ok end,
        receive {Tag,Pid,_} -> ok after 0 -> ok end,
        {error,timeout}
    end;
run(_,_) -> {error,invalid_timeout}.
