%% Revisioned node-admin inference policy. No arbitrary code, model weights,
%% remote URLs, credentials or tensor hooks are accepted by this control plane.
-module(ecai_model_internals).
-behaviour(gen_server).
-export([start_link/0, start_link/1, child_spec/0, status/0, update/2, preview/1,
         defaults/0, validate/1, capabilities/0, prepare/3, apply_policy/1,
         metadata/1, observe/1, repair_schema/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-define(KEY, {?MODULE, snapshot}).
-define(MAX_EVENTS, 32).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).
child_spec() -> #{id => ?MODULE, start => {?MODULE, start_link, []}, restart => permanent,
                  shutdown => 5000, type => worker, modules => [?MODULE]}.

%% JSON keys remain binaries; never intern user-supplied atoms.
defaults() ->
    #{<<"enabled">> => false, <<"roles">> => [<<"patch">>],
      <<"system_suffix">> => <<>>, <<"patch_json_schema">> => false,
      <<"ollama">> => #{<<"temperature">> => null, <<"top_p">> => null,
          <<"top_k">> => null, <<"min_p">> => null, <<"seed">> => null,
          <<"repeat_penalty">> => null, <<"num_ctx">> => null,
          <<"max_output_tokens">> => null},
      <<"openai">> => #{<<"temperature">> => null, <<"max_output_tokens">> => null}}.

status() ->
    Data = gen_server:call(?MODULE, status),
    Data#{capabilities => capabilities(), pool => pool_status()}.
update(Body, Actor) -> gen_server:call(?MODULE, {update, Body, Actor}, 10000).

init(Opts) ->
    File = maps:get(file, Opts, filename:join(ecai_paths:state_dir(), "code_model_internals.term")),
    case load(File) of
        {ok, Snapshot} ->
            persistent_term:put(?KEY, Snapshot),
            {ok, #{file => File, snapshot => Snapshot, observations => []}};
        {error, Reason} -> {stop, {model_internals_state_unavailable, Reason}}
    end.

handle_call(status, _From, State) ->
    S = maps:get(snapshot, State),
    {reply, S#{observations => maps:get(observations, State),
               observations_durable => false, service => ready}, State};
handle_call({update, Body, Actor}, _From, State) ->
    case candidate(Body, Actor, maps:get(snapshot, State)) of
        {ok, New} ->
            case persist(maps:get(file, State), New) of
                ok ->
                    persistent_term:put(?KEY, New),
                    {reply, {ok, New}, State#{snapshot => New}};
                {error, _} -> {reply, {error, persistence_failed}, State}
            end;
        {error, _} = Error -> {reply, Error, State}
    end;
handle_call(_, _From, State) -> {reply, {error, unsupported_operation}, State}.
handle_cast({observation, Meta}, State) when is_map(Meta) ->
    %% Explicit allowlist excludes source, completions, hostnames and credentials.
    Safe0 = maps:with([role, provider, node_id, model, model_digest, wall_duration_ms,
                      eval_count, prompt_eval_count, cache_hit, model_internals], Meta),
    Safe = case maps:get(model_internals, Safe0, undefined) of
        M when is_map(M) -> Safe0#{model_internals => maps:with(
            [revision, config_sha256, applied, system_suffix_sha256], M)};
        _ -> maps:remove(model_internals, Safe0)
    end,
    Entry = Safe#{observed_at => timestamp()},
    {noreply, State#{observations => lists:sublist([Entry | maps:get(observations, State)], ?MAX_EVENTS)}};
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
%% Retain the last validated snapshot while the rest_for_one tree restarts.
%% A restarting worker must not temporarily bypass an enabled policy.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

candidate(#{<<"revision">> := Revision, <<"config">> := Config} = Body, Actor, Current)
  when map_size(Body) =:= 2, is_integer(Revision), Revision >= 0,
       is_binary(Actor), byte_size(Actor) > 0, byte_size(Actor) =< 256 ->
    case Revision =:= maps:get(revision, Current) of
        false -> {error, stale_revision};
        true ->
            case validate(Config) of
                ok ->
                    Next = Revision + 1, At = timestamp(), Hash = digest(Config),
                    Event = #{revision => Next, actor => Actor, at => At, config_sha256 => Hash},
                    {ok, #{schema_version => 1, revision => Next, updated_by => Actor,
                           updated_at => At, config_sha256 => Hash, config => Config,
                           changes => lists:sublist([Event | maps:get(changes, Current)], ?MAX_EVENTS)}};
                {error, _} = Error -> Error
            end
    end;
candidate(_, _, _) -> {error, invalid_update}.

validate(Config) when is_map(Config) ->
    try
        exact_keys(Config, maps:keys(defaults())),
        bool(maps:get(<<"enabled">>, Config)),
        bool(maps:get(<<"patch_json_schema">>, Config)),
        Roles = maps:get(<<"roles">>, Config),
        ensure(is_list(Roles) andalso length(Roles) > 0 andalso length(Roles) =< 4, invalid_roles),
        ensure(lists:usort(Roles) =:= lists:sort(Roles), duplicate_roles),
        ensure(lists:all(fun(R) -> lists:member(R, [<<"patch">>, <<"learning">>, <<"audit">>, <<"synthesis">>]) end, Roles), invalid_roles),
        Suffix = maps:get(<<"system_suffix">>, Config),
        ensure(is_binary(Suffix) andalso byte_size(Suffix) =< 2048, invalid_system_suffix),
        ensure(unicode:characters_to_binary(Suffix, utf8, utf8) =:= Suffix, invalid_utf8),
        O = maps:get(<<"ollama">>, Config), P = maps:get(<<"openai">>, Config),
        exact_keys(O, maps:keys(maps:get(<<"ollama">>, defaults()))),
        exact_keys(P, maps:keys(maps:get(<<"openai">>, defaults()))),
        number_option(O, <<"temperature">>, 0, 2), number_option(P, <<"temperature">>, 0, 2),
        number_option(O, <<"top_p">>, 0.001, 1), number_option(O, <<"min_p">>, 0, 1),
        number_option(O, <<"repeat_penalty">>, 0.1, 2),
        integer_option(O, <<"top_k">>, 1, 1000), integer_option(O, <<"seed">>, 0, 2147483647),
        integer_option(O, <<"num_ctx">>, 512, 131072),
        integer_option(O, <<"max_output_tokens">>, 1, 32768),
        integer_option(P, <<"max_output_tokens">>, 1, 32768),
        ok
    catch throw:Reason -> {error, Reason}; error:_ -> {error, invalid_config} end;
validate(_) -> {error, config_object_required}.
exact_keys(Map, Keys) when is_map(Map) ->
    ensure(lists:sort(maps:keys(Map)) =:= lists:sort(Keys), unknown_or_missing_fields);
exact_keys(_, _) -> throw(config_object_required).
bool(V) -> ensure(is_boolean(V), boolean_required).
ensure(true, _) -> ok;
ensure(false, Reason) -> throw(Reason).
number_option(Map, Key, Min, Max) ->
    V = maps:get(Key, Map),
    ensure(V =:= null orelse (is_number(V) andalso V >= Min andalso V =< Max), {out_of_range, Key}).
integer_option(Map, Key, Min, Max) ->
    V = maps:get(Key, Map),
    ensure(V =:= null orelse (is_integer(V) andalso V >= Min andalso V =< Max), {out_of_range, Key}).

%% Called once per pool request: retries keep this exact policy snapshot.
%% Public native chat/generate, evaluations and non-code roles are unaffected.
prepare(Kind, Role, Opts) ->
    Clean = maps:without([model_internals_snapshot, model_internals], Opts),
    S = case persistent_term:get(?KEY, undefined) of undefined -> fresh(); Value -> Value end,
    C = maps:get(config, S),
    case (Kind =:= json orelse Kind =:= text) andalso maps:get(<<"enabled">>, C)
         andalso lists:member(atom_to_binary(Role, utf8), maps:get(<<"roles">>, C)) of
        true -> Clean#{model_internals_snapshot => (maps:with([config, revision, config_sha256], S))#{kind => Kind, role => Role}};
        false -> Clean
    end.

%% Runs AFTER the pool resolves the destination. Policy cannot override model,
%% provider, credentials, endpoint, budget or the human publication gate.
apply_policy(#{model_internals_snapshot := S} = Opts) ->
    C = maps:get(config, S), Provider = maps:get(provider, Opts),
    case lists:member(Provider, [ollama, openai]) of
        false -> Opts;
        true ->
            Settings = maps:get(atom_to_binary(Provider, utf8), C),
            Pairs = [{option_key(K), V} || {K, V} <- maps:to_list(Settings), V =/= null],
            Tuned0 = maps:merge(Opts, maps:from_list(Pairs)),
            Suffix = maps:get(<<"system_suffix">>, C),
            Tuned1 = append_system(Tuned0, Suffix),
            Schema = Provider =:= ollama andalso maps:get(role, S) =:= patch
                     andalso maps:get(kind, S) =:= json andalso maps:get(<<"patch_json_schema">>, C),
            Tuned = case Schema of true -> Tuned1#{format => repair_schema()}; false -> Tuned1 end,
            Applied = lists:sort([K || {K, _} <- Pairs] ++
                [system_suffix || Suffix =/= <<>>] ++ [patch_json_schema || Schema]),
            Meta = #{revision => maps:get(revision, S), config_sha256 => maps:get(config_sha256, S),
                     applied => Applied, system_suffix_sha256 => digest(Suffix)},
            Tuned#{model_internals => Meta}
    end;
apply_policy(Opts) -> Opts.

option_key(<<"temperature">>) -> temperature;
option_key(<<"top_p">>) -> top_p;
option_key(<<"top_k">>) -> top_k;
option_key(<<"min_p">>) -> min_p;
option_key(<<"seed">>) -> seed;
option_key(<<"repeat_penalty">>) -> repeat_penalty;
option_key(<<"num_ctx">>) -> num_ctx;
option_key(<<"max_output_tokens">>) -> max_output_tokens.
append_system(Opts, <<>>) -> Opts;
append_system(Opts, Suffix) ->
    Base = maps:get(system, Opts, <<>>),
    Existing = case Base of undefined -> <<>>; _ -> unicode:characters_to_binary(Base) end,
    Opts#{system => <<Existing/binary, "\n\nECAI operator guidance:\n", Suffix/binary>>}.
metadata(Opts) -> maps:with([model_internals], Opts).
observe(#{role := Role} = Meta) ->
    case lists:member(Role, [patch, learning, synthesis, audit]) of
        true -> gen_server:cast(?MODULE, {observation, Meta});
        false -> ok
    end;
observe(_) -> ok.

%% Pure preview: no lease, HTTP request, inference, model load or spend.
preview(#{<<"config">> := C, <<"provider">> := Provider, <<"role">> := Role} = Body)
  when map_size(Body) =:= 3 ->
    case {validate(C), provider_atom(Provider), role_atom(Role)} of
        {ok, {ok, P}, {ok, R}} ->
            Active = maps:get(<<"enabled">>, C) andalso lists:member(Role, maps:get(<<"roles">>, C)),
            S = #{config => C, config_sha256 => digest(C), revision => 0, kind => json, role => R},
            Base = #{provider => P},
            Resolved = case Active of true -> apply_policy(Base#{model_internals_snapshot => S}); false -> Base end,
            {ok, #{active => Active, provider => P, role => R, config_sha256 => digest(C),
                   options => maps:without([model_internals_snapshot], Resolved),
                   notice => <<"Draft overrides only. Revision 0 is a preview, not a saved policy. No model was called; inherited node options are not displayed.">>}};
        {{error, _} = Error, _, _} -> Error;
        _ -> {error, unsupported_preview_target}
    end;
preview(_) -> {error, invalid_preview}.
provider_atom(<<"ollama">>) -> {ok, ollama};
provider_atom(<<"openai">>) -> {ok, openai};
provider_atom(_) -> error.
role_atom(<<"patch">>) -> {ok, patch};
role_atom(<<"learning">>) -> {ok, learning};
role_atom(<<"synthesis">>) -> {ok, synthesis};
role_atom(<<"audit">>) -> {ok, audit};
role_atom(_) -> error.

repair_schema() ->
    #{<<"type">> => <<"object">>, <<"additionalProperties">> => false,
      <<"required">> => [<<"summary">>, <<"security_property">>, <<"tests">>, <<"patch">>],
      <<"properties">> => #{<<"summary">> => #{<<"type">> => <<"string">>},
          <<"security_property">> => #{<<"type">> => <<"string">>},
          <<"tests">> => #{<<"type">> => <<"array">>, <<"items">> => #{<<"type">> => <<"string">>}},
          <<"patch">> => #{<<"type">> => <<"string">>}}}.

capabilities() ->
    [cap(system, <<"System guidance">>, wired, <<"Append bounded operator guidance to code requests; never execute retrieved instructions.">>),
     cap(sampling, <<"Sampling & token budgets">>, wired, <<"Ollama sampling overrides; OpenAI token limit and optional, model-dependent temperature. Empty values inherit node defaults.">>),
     cap(schema, <<"Constrained patch JSON">>, wired, <<"Fixed Ollama patch JSON schema. Shape constraints do not prove code correctness.">>),
     cap(provenance, <<"Policy provenance">>, wired, <<"Policy revision and SHA-256 fingerprint accompany inference metadata and durable repair attempts. A hash is not a signature or truth proof.">>),
     cap(logits, <<"Custom token logits">>, bridge_required, <<"Requires an isolated llama.cpp, vLLM or Transformers extension. No arbitrary processors are loaded here.">>),
     cap(activations, <<"Activation & attention hooks">>, bridge_required, <<"Requires a compatible open-model runtime and evaluated steering vectors; unavailable through this bridge.">>),
     cap(adapters, <<"LoRA & weight adapters">>, bridge_required, <<"No adapter loader is installed by this feature. Pin, review and evaluate model-compatible artifacts before a future runtime integration.">>),
     cap(cache, <<"KV cache & soft prompts">>, bridge_required, <<"No cache inspection, tenant-shared state or embedding injection is exposed by this control plane.">>)].
cap(Id, Title, State, Note) -> #{id => Id, title => Title, state => State, note => Note}.

pool_status() ->
    try gen_server:call(ecai_ollama_pool, status, 1000) of
        #{nodes := Nodes} ->
            Fields = [id, provider, roles, health, default_model, inflight, max_inflight, latency_ema_ms, last_checked_at],
            #{state => available, nodes => [maps:with(Fields, N) || N <- Nodes]};
        _ -> #{state => unavailable, nodes => []}
    catch exit:_ -> #{state => unavailable, nodes => []} end.

fresh() ->
    C = defaults(),
    #{schema_version => 1, revision => 0, config => C, config_sha256 => digest(C),
      updated_at => null, updated_by => null, changes => []}.
load(File) ->
    case file:read_file(File) of
        {error, enoent} -> {ok, fresh()};
        {ok, Bin} when byte_size(Bin) =< 262144 ->
            try binary_to_term(Bin, [safe]) of
                #{schema_version := 1, config := C, revision := R, changes := Events,
                  config_sha256 := Hash, updated_at := _, updated_by := _} = S
                  when is_integer(R), R >= 0, is_list(Events), length(Events) =< ?MAX_EVENTS ->
                    case validate(C) =:= ok andalso digest(C) =:= Hash of
                        true -> {ok, S}; false -> {error, invalid_state}
                    end;
                _ -> {error, invalid_state}
            catch _:_ -> {error, invalid_state} end;
        {ok, _} -> {error, state_too_large};
        {error, _} -> {error, state_unreadable}
    end.
persist(File, S) ->
    Temp = File ++ ".tmp." ++ integer_to_list(erlang:system_time(nanosecond))
           ++ "." ++ integer_to_list(erlang:unique_integer([positive])),
    case filelib:ensure_dir(File) of
        ok ->
            case file:open(Temp, [write, binary, raw, exclusive]) of
                {ok, Fd} ->
                    Written = try
                        ok = file:change_mode(Temp, 8#600),
                        ok = file:write(Fd, term_to_binary(S, [deterministic])),
                        file:sync(Fd)
                    catch _:_ -> {error, write_failed} end,
                    Closed = file:close(Fd),
                    Result = case {Written, Closed} of
                        {ok, ok} -> file:rename(Temp, File);
                        _ -> {error, write_failed}
                    end,
                    _ = file:delete(Temp), Result;
                {error, eexist} -> {error, stale_temporary_file};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.
digest(Term) ->
    Hash = crypto:hash(sha256, term_to_binary(Term, [deterministic])),
    << <<(hex(B bsr 4)), (hex(B band 15))>> || <<B>> <= Hash >>.
hex(N) when N < 10 -> $0 + N;
hex(N) -> $a + N - 10.
timestamp() -> list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}, {offset, "Z"}])).
