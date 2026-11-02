%% Disposable Firecracker script jobs. Host policy belongs to the root-owned
%% launcher, not the feature/request. This node must remain unprivileged.
-module(damage_firecracker).
-behaviour(gen_server).
-license("Apache-2.0").
-export([start_link/0, run/2, run/3, submit/3, cancel/1, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
run(Profile, Script) -> run(Profile, Script, #{}).
run(Profile, Script, Options) ->
    %% Monitor the exact manager before submission; monitoring a replacement
    %% after a crash could otherwise wait forever for an old manager's result.
    case whereis(?MODULE) of
        undefined -> {error, disabled};
        Manager ->
            Ref = monitor(process, Manager),
            try gen_server:call(Manager, {submit, Profile, Script, Options}, 5000) of
                {ok, Id} ->
                    receive
                        {damage_firecracker, Id, Result} -> Result;
                        {'DOWN', Ref, process, Manager, _} -> {error, unavailable}
                    end;
                Error -> Error
            catch exit:_ -> {error, unavailable}
            after demonitor(Ref, [flush])
            end
    end.
submit(Profile, Script, Options) -> call({submit, Profile, Script, Options}).
cancel(Id) -> call({cancel, Id}).
status() -> call(status).
call(Request) ->
    try gen_server:call(?MODULE, Request, 5000)
    catch exit:{noproc, _} -> {error, disabled};
          exit:_ -> {error, unavailable}
    end.

init([]) ->
    process_flag(trap_exit, true),
    Raw = application:get_env(damage, firecracker, []),
    try
        Env = case Raw of M when is_map(M) -> M; L -> maps:from_list(L) end,
        case maps:get(enabled, Env, false) of
            false -> ignore;
            true ->
                Defaults = #{launcher => "/usr/bin/sudo",
                    launcher_args => ["-n", "--", "/usr/local/libexec/damage-firecracker-runner"],
                    profiles => [], max_jobs => 2, timeout_ms => 60000,
                    max_timeout_ms => 300000, max_script_bytes => 65536,
                    max_result_bytes => 2097152},
                C = maps:merge(Defaults, Env),
                true = filename:pathtype(maps:get(launcher, C)) =:= absolute,
                true = is_list(maps:get(launcher_args, C)),
                true = lists:all(fun is_list/1, maps:get(launcher_args, C)),
                true = lists:all(fun valid_profile/1, maps:get(profiles, C)),
                true = lists:all(fun(K) ->
                    N = maps:get(K, C), is_integer(N) andalso N > 0
                end, [max_jobs, timeout_ms, max_timeout_ms, max_script_bytes, max_result_bytes]),
                true = maps:get(max_jobs, C) =< 64,
                true = maps:get(max_script_bytes, C) =< 65536,
                true = maps:get(max_result_bytes, C) =< 4194304,
                true = maps:get(max_timeout_ms, C) =< 3600000,
                true = maps:get(timeout_ms, C) =< maps:get(max_timeout_ms, C),
                {ok, #{config => C, jobs => #{}}}
        end
    catch _:_ -> {stop, invalid_firecracker_config}
    end.

handle_call(status, _From, S = #{config := C, jobs := Jobs}) ->
    {reply, #{enabled => true, running => map_size(Jobs),
              max_jobs => maps:get(max_jobs, C), profiles => maps:get(profiles, C)}, S};
handle_call({submit, Profile, Script, Opts}, {Owner, _}, S = #{config := C, jobs := Jobs}) ->
    case validate_job(Profile, Script, Opts, C) of
        {ok, Request} when map_size(Jobs) < map_get(max_jobs, C) ->
            Id = binary:encode_hex(crypto:strong_rand_bytes(16)),
            Parent = self(),
            Pid = spawn_link(fun() -> job(Parent, Id, Request, C) end),
            Mon = monitor(process, Owner),
            Entry = #{owner => Owner, monitor => Mon, worker => Pid},
            {reply, {ok, Id}, S#{jobs => Jobs#{Id => Entry}}};
        {ok, _} -> {reply, {error, busy}, S};
        Error -> {reply, Error, S}
    end;
handle_call({cancel, Id}, {Owner, _}, S = #{jobs := Jobs}) ->
    case maps:find(Id, Jobs) of
        {ok, #{owner := Owner, worker := Pid}} ->
            Pid ! cancel, {reply, ok, S};
        {ok, _} -> {reply, {error, not_owner}, S};
        error -> {reply, {error, not_found}, S}
    end;
handle_call(_, _, S) -> {reply, {error, bad_request}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info({finished, Pid, Id, Result}, S = #{jobs := Jobs}) ->
    case maps:find(Id, Jobs) of
        {ok, #{worker := Pid, owner := Owner, monitor := Mon}} ->
            demonitor(Mon, [flush]),
            Owner ! {damage_firecracker, Id, Result},
            {noreply, S#{jobs => maps:remove(Id, Jobs)}};
        _ -> {noreply, S}
    end;
handle_info({'DOWN', Mon, process, _, _}, S = #{jobs := Jobs}) ->
    maps:foreach(fun(_, #{monitor := M, worker := P}) ->
        case M =:= Mon of true -> P ! cancel; false -> ok end
    end, Jobs),
    {noreply, S};
handle_info({'EXIT', Pid, Reason}, S = #{jobs := Jobs}) ->
    %% A worker sends finished before exiting. Unexpected exits also free slots.
    New = maps:filter(fun(Id, #{worker := P, owner := Owner, monitor := Mon}) ->
        case P =:= Pid of
            true -> demonitor(Mon, [flush]),
                    Owner ! {damage_firecracker, Id, {error, {worker_exit, Reason}}}, false;
            false -> true
        end
    end, Jobs),
    {noreply, S#{jobs => New}};
handle_info(_, S) -> {noreply, S}.
terminate(_, #{jobs := Jobs}) ->
    maps:foreach(fun(_, #{worker := P}) -> P ! cancel end, Jobs), ok.
code_change(_, S, _) -> {ok, S}.

valid_profile(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 64 ->
    re:run(B, <<"^[a-zA-Z0-9][a-zA-Z0-9_-]*$">>, [{capture, none}]) =:= match;
valid_profile(_) -> false.
validate_job(Profile, Script, Opts, C) ->
    try
        true = valid_profile(Profile),
        true = lists:member(Profile, maps:get(profiles, C)),
        true = is_binary(Script) andalso byte_size(Script) > 0,
        true = byte_size(Script) =< maps:get(max_script_bytes, C),
        true = binary:match(Script, <<0>>) =:= nomatch,
        true = is_map(Opts) andalso maps:without([timeout_ms], Opts) =:= #{},
        Timeout = maps:get(timeout_ms, Opts, maps:get(timeout_ms, C)),
        true = is_integer(Timeout) andalso Timeout >= 1000,
        true = Timeout =< maps:get(max_timeout_ms, C),
        {ok, #{version => 1, profile => Profile,
               script_b64 => base64:encode(Script), timeout_ms => Timeout}}
    catch _:_ -> {error, invalid_job}
    end.

job(Parent, Id, Request, C) ->
    process_flag(trap_exit, true),
    Result = try
        Port = open_port({spawn_executable, maps:get(launcher, C)},
            [binary, exit_status, use_stdio, stderr_to_stdout,
             {args, maps:get(launcher_args, C)}]),
        try
            true = port_command(Port, [jsx:encode(Request), <<"\n">>]),
            Deadline = erlang:monotonic_time(millisecond) + maps:get(timeout_ms, Request) + 20000,
            collect(Port, Parent, Deadline, maps:get(max_result_bytes, C), <<>>)
        after
            %% EOF is cancellation for the launcher; systemd bounds orphan life.
            try port_close(Port) catch error:badarg -> ok end
        end
    catch _:_ -> {error, launcher_failed}
    end,
    Parent ! {finished, self(), Id, Result}.

collect(Port, Parent, Deadline, Max, Acc) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Bin}} when byte_size(Acc) + byte_size(Bin) =< Max ->
            collect(Port, Parent, Deadline, Max, <<Acc/binary, Bin/binary>>);
        {Port, {data, _}} -> {error, response_too_large};
        {Port, {exit_status, 0}} -> decode_result(Acc);
        {Port, {exit_status, _}} -> {error, launcher_failed};
        {'EXIT', Port, _} -> {error, launcher_failed};
        {'EXIT', Parent, _} -> {error, cancelled};
        cancel -> {error, cancelled}
    after Remaining -> {error, timeout}
    end.

decode_result(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        #{<<"version">> := 1, <<"ok">> := true, <<"exit_code">> := N,
          <<"output_b64">> := Enc, <<"output_truncated">> := Truncated,
          <<"vm_id">> := VM, <<"profile">> := Profile,
          <<"kernel_sha256">> := KernelHash, <<"rootfs_sha256">> := RootHash} = R
          when is_integer(N), N >= 0, N =< 255, is_binary(Enc), is_boolean(Truncated) ->
            {ok, #{exit_code => N, output => base64:decode(Enc),
                   output_truncated => Truncated, vm_id => VM, profile => Profile,
                   kernel_sha256 => KernelHash, rootfs_sha256 => RootHash,
                   duration_ms => maps:get(<<"duration_ms">>, R, 0)}};
        #{<<"version">> := 1, <<"ok">> := false, <<"error">> := Error} when is_binary(Error) ->
            {error, {firecracker, Error}};
        _ -> {error, invalid_response}
    catch _:_ -> {error, invalid_response}
    end.
