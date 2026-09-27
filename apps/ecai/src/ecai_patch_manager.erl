-module(ecai_patch_manager).
-behaviour(gen_server).

-export([start_link/0, start_link/1, scan_now/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(APPS, [damage, ecai, erm]).
-define(DEFAULT_INTERVAL, 60000).

-record(state, {
    interval_ms = ?DEFAULT_INTERVAL,
    opts = #{},
    cycles = 0,
    queued = 0,
    last_run_at = undefined,
    last_error = undefined
}).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).
scan_now() -> gen_server:cast(?SERVER, scan_now).
status() -> gen_server:call(?SERVER, status).

init(Opts) ->
    Interval = maps:get(interval_ms, Opts,
        application:get_env(ecai, code_patch_scan_interval_ms, ?DEFAULT_INTERVAL)),
    erlang:send_after(10000, self(), scan),
    {ok, #state{interval_ms = Interval, opts = Opts}}.

handle_call(status, _From, State) ->
    {reply, #{cycles => State#state.cycles, queued => State#state.queued,
              last_run_at => State#state.last_run_at, last_error => State#state.last_error}, State};
handle_call(_Req, _From, State) -> {reply, {error, unsupported_call}, State}.

handle_cast(scan_now, State) ->
    self() ! scan,
    {noreply, State};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(scan, State0) ->
    case learning_ready(State0#state.opts) of
        false ->
            State1 = State0#state{
                cycles = State0#state.cycles + 1,
                last_run_at = now_iso8601(),
                last_error = learning_not_ready
            },
            erlang:send_after(State1#state.interval_ms, self(), scan),
            {noreply, State1};
        true ->
            {Queued, Errors} = lists:foldl(fun(App, {Q, E}) ->
                case catch ecai_vuln_monitor:app_findings(App) of
                    Reports when is_list(Reports) ->
                        {Q1, E1} = process_reports(App, Reports, State0#state.opts),
                        {Q + Q1, E1 ++ E};
                    {'EXIT', Reason} -> {Q, [{App, Reason} | E]};
                    {error, Reason} -> {Q, [{App, Reason} | E]};
                    Other -> {Q, [{App, {unexpected_findings_response, Other}} | E]}
                end
            end, {0, []}, ?APPS),
            State1 = State0#state{
                cycles = State0#state.cycles + 1,
                queued = State0#state.queued + Queued,
                last_run_at = now_iso8601(),
                last_error = case Errors of [] -> undefined; _ -> Errors end
            },
            erlang:send_after(State1#state.interval_ms, self(), scan),
            {noreply, State1}
    end;
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

learning_ready(Opts) ->
    Require = maps:get(require_global_learning, Opts,
        application:get_env(ecai, code_patch_require_global_learning, true)),
    case Require of
        false -> true;
        true -> ecai_learning_store:get_global_knowledge() =/= not_found
    end.

process_reports(App, Reports, Opts) ->
    lists:foldl(fun(Report, {Q, E}) ->
        ModuleBin = mget(<<"module">>, Report, <<>>),
        case existing_module_atom(ModuleBin) of
            {error, Reason} -> {Q, [Reason | E]};
            {ok, Module} ->
                Findings = mget(<<"findings">>, Report, []),
                process_findings(App, Module, Findings, Opts, Q, E)
        end
    end, {0, []}, Reports).

process_findings(_App, _Module, [], _Opts, Q, E) -> {Q, E};
process_findings(App, Module, [Finding | Rest], Opts, Q0, E0) ->
    {Q1, E1} = case patchable(Finding, Opts) of
        false -> {Q0, E0};
        true ->
            case ecai_learning_store:get_analysis(App, Module) of
                not_found ->
                    ecai_codebase_learner:module_changed(App, Module),
                    {Q0, E0};
                {ok, _} -> queue_if_new(App, Module, Finding, Opts, Q0, E0)
            end
    end,
    process_findings(App, Module, Rest, Opts, Q1, E1).

queue_if_new(App, Module, Finding, Opts, Q, E) ->
    Fp = finding_fingerprint(Module, Finding),
    Version = ecai_code_context:finding_version(App, Module, Finding),
    case ecai_learning_store:get_repair(Fp, Version) of
        {ok, _Existing} -> {Q, E};
        not_found ->
            Queued = #{
                status => queued,
                fingerprint => Fp,
                finding_version => Version,
                application => App,
                module => Module,
                finding => Finding,
                created_at => now_iso8601()
            },
            ok = ecai_learning_store:put_repair(Fp, Version, Queued),
            case ecai_patch_sup:propose(App, Module, Finding, Opts) of
                {ok, _Pid} -> {Q + 1, E};
                {ok, _Pid, _Info} -> {Q + 1, E};
                {error, Reason} ->
                    Failed = Queued#{status => failed_to_start, error => Reason},
                    ok = ecai_learning_store:put_repair(Fp, Version, Failed),
                    {Q, [{App, Module, Fp, Reason} | E]}
            end
    end.

finding_fingerprint(Module, Finding) ->
    case mget(<<"fingerprint">>, Finding, undefined) of
        Fp when is_binary(Fp), byte_size(Fp) > 0 -> Fp;
        _ ->
            Issue = to_binary(mget(<<"issue_key">>, Finding, <<"unknown">>)),
            Data = <<(atom_to_binary(Module, utf8))/binary, 0, Issue/binary>>,
            iolist_to_binary([io_lib:format("~2.16.0b", [B]) ||
                              <<B>> <= crypto:hash(sha256, Data)])
    end.

patchable(Finding, Opts) when is_map(Finding) ->
    Status = mget(<<"status">>, Finding, <<"open">>),
    Severity = mget(<<"severity">>, Finding, <<"info">>),
    IncludeInfo = maps:get(include_info, Opts,
        application:get_env(ecai, code_patch_include_info, false)),
    Status =/= <<"resolved">> andalso (IncludeInfo orelse Severity =/= <<"info">>);
patchable(_, _) -> false.

existing_module_atom(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    try {ok, binary_to_existing_atom(Bin, utf8)}
    catch error:badarg -> {error, {unknown_module, Bin}} end;
existing_module_atom(Other) -> {error, {invalid_module, Other}}.

mget(Key, Map, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                A -> maps:get(A, Map, Default)
            catch error:badarg -> Default end
    end;
mget(_Key, _Map, Default) -> Default.

now_iso8601() ->
    to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
