-module(ecai_patch_sup).
-behaviour(supervisor).

-export([start_link/0, propose/3, propose/4]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() -> supervisor:start_link({local, ?SERVER}, ?MODULE, []).

propose(App, Module, Finding) -> propose(App, Module, Finding, #{}).

propose(App, Module, Finding, Opts) ->
    Id =
        case maps:get(worker_id, Opts, undefined) of
            {Fingerprint0, Version0} ->
                {ecai_patch_worker, Fingerprint0, Version0};
            undefined ->
                {ecai_patch_worker,
                 erlang:unique_integer([positive, monotonic])};
            Other ->
                {ecai_patch_worker, Other}
        end,
    {Fingerprint, Version} =
        repair_identity(App, Module, Finding, Opts),
    case ecai_repair_preflight:check(
             App, Module, Finding, Fingerprint, Version, Opts) of
        {allow, _Meta} ->
            Spec = #{
                id => Id,
                start => {ecai_patch_worker, start_link,
                          [#{app => App, module => Module,
                             finding => Finding, opts => Opts}]},
                restart => temporary,
                shutdown => 5000,
                type => worker,
                modules => [ecai_patch_worker]
            },
            supervisor:start_child(?SERVER, Spec);
        {blocked, Repair} ->
            {ok, blocked, Repair};
        {superseded, Repair} ->
            {ok, superseded, Repair}
    end.

repair_identity(App, Module, Finding, Opts) ->
    case maps:get(worker_id, Opts, undefined) of
        {Fingerprint, Version}
          when is_binary(Fingerprint), is_binary(Version) ->
            {Fingerprint, Version};
        _ ->
            {
                finding_fingerprint(Module, Finding),
                ecai_code_context:finding_version(
                    App, Module, Finding)
            }
    end.

finding_fingerprint(Module, Finding) ->
    case mget(<<"fingerprint">>, Finding, undefined) of
        Fp when is_binary(Fp), byte_size(Fp) > 0 ->
            Fp;
        _ ->
            Issue =
                to_binary(
                    mget(<<"issue_key">>, Finding, <<"unknown">>)
                ),
            Data =
                <<(atom_to_binary(Module, utf8))/binary,
                  0, Issue/binary>>,
            hex_sha256(Data)
    end.

mget(Key, Map, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            Value;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                AtomKey -> maps:get(AtomKey, Map, Default)
            catch
                error:badarg -> Default
            end
    end;
mget(_Key, _Map, Default) ->
    Default.

hex_sha256(Data) ->
    iolist_to_binary(
        [io_lib:format("~2.16.0b", [B])
         || <<B>> <= crypto:hash(sha256, Data)]
    ).

to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(List) when is_list(List) ->
    unicode:characters_to_binary(List);
to_binary(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8);
to_binary(Value) ->
    iolist_to_binary(io_lib:format("~p", [Value])).

init([]) -> {ok, {{one_for_one, 10, 10}, []}}.
