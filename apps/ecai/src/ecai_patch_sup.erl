-module(ecai_patch_sup).
-behaviour(supervisor).

-export([start_link/0, propose/3, propose/4]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() -> supervisor:start_link({local, ?SERVER}, ?MODULE, []).

propose(App, Module, Finding) -> propose(App, Module, Finding, #{}).

propose(App, Module, Finding, Opts0) ->
    Fingerprint = maps:get(fingerprint, Opts0, finding_fingerprint(Module, Finding)),
    Version = maps:get(
        finding_version,
        Opts0,
        ecai_code_context:finding_version(App, Module, Finding)
    ),
    Id = {ecai_patch_worker, Fingerprint, Version},
    Opts = maps:without([fingerprint, finding_version], Opts0),
    Args = #{
        app => App,
        module => Module,
        finding => Finding,
        fingerprint => Fingerprint,
        finding_version => Version,
        opts => Opts
    },
    Spec = #{
        id => Id,
        start => {ecai_patch_worker, start_link, [Args]},
        %% Survive worker crashes inside a running node; whole-node restarts are
        %% recovered by ecai_patch_manager from the durable repair records.
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [ecai_patch_worker]
    },
    start_or_reuse(Id, Spec).

start_or_reuse(Id, Spec) ->
    case supervisor:start_child(?SERVER, Spec) of
        {ok, Pid} -> {ok, Pid};
        {ok, Pid, Info} -> {ok, Pid, Info};
        {error, {already_started, Pid}} -> {ok, Pid, already_running};
        {error, already_present} ->
            case supervisor:restart_child(?SERVER, Id) of
                {ok, Pid} -> {ok, Pid, restarted};
                {ok, Pid, Info} -> {ok, Pid, Info};
                {error, running} ->
                    case child_pid(Id) of
                        undefined -> {error, {child_present_without_pid, Id}};
                        Pid -> {ok, Pid, already_running}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

child_pid(Id) ->
    case [Pid || {ChildId, Pid, _Type, _Modules} <- supervisor:which_children(?SERVER),
                 ChildId =:= Id, is_pid(Pid)] of
        [Pid | _] -> Pid;
        [] -> undefined
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

mget(Key, Map, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                A -> maps:get(A, Map, Default)
            catch error:badarg -> Default end
    end;
mget(_Key, _Map, Default) -> Default.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

init([]) -> {ok, {{one_for_one, 10, 10}, []}}.
