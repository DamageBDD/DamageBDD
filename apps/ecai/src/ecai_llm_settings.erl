%% Node-wide provider registry. Only ecai_code_admin_http exposes mutations.
%% No caller-selected Erlang terms, modules, HTTP headers or TLS options.
-module(ecai_llm_settings).
-compile({no_auto_import, [nodes/0]}).
-behaviour(gen_server).
-export([start_link/0, start_link/1, child_spec/0, status/0, update/2,
         probe/1, nodes/0, revision/0, route_chat/0, code_options/1, validate/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, format_status/1]).
-define(KEY, {?MODULE, active}).
-define(ROLES, [<<"learning">>, <<"audit">>, <<"patch">>, <<"synthesis">>, <<"chat">>, <<"bdd">>]).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).
child_spec() -> #{id => ?MODULE, start => {?MODULE, start_link, []}, restart => permanent,
                  shutdown => 5000, type => worker, modules => [?MODULE]}.
nodes() ->
    case persistent_term:get(?KEY, undefined) of
        #{managed := true, nodes := Ns} -> {ok, Ns};
        _ -> inherited
    end.
revision() -> maps:get(revision, persistent_term:get(?KEY, #{}), 0).
route_chat() -> maps:get(route_chat, persistent_term:get(?KEY, #{}), false).
%% Internal code consumers used to supply legacy default model/provider pins.
%% Once the dashboard owns routing, roles select the destination. Explicit
%% public API, evaluation and private-corpus destinations are not rewritten.
code_options(Opts) when is_map(Opts) ->
    case nodes() of
        {ok, _} -> maps:without([provider, model], Opts);
        inherited -> Opts
    end.
status() ->
    S = gen_server:call(?MODULE, status),
    S#{pool => pool_status(), damage_profiles => damage_profiles()}.
update(Body, Actor) -> gen_server:call(?MODULE, {update, Body, Actor}, infinity).
probe(Body) ->
    %% Networking happens outside the registry process, against a saved target.
    case gen_server:call(?MODULE, {probe_options, Body}) of
        {ok, Opts} ->
            Started = erlang:monotonic_time(millisecond),
            Result = try ecai_ollama_client:probe(Opts#{health_timeout => 10000,
                          connect_timeout => 5000, max_response_bytes => 1048576,
                          response_decode => json_binary})
                     catch _:_ -> {error, probe_failed} end,
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            case Result of
                {ok, #{models := Models}} ->
                    {ok, #{models => lists:sort(maps:keys(Models)), elapsed_ms => Elapsed,
                           generation_tested => false}};
                {error, Why} -> {error, safe_error(Why)}
            end;
        Error -> Error
    end.

init(Opts) ->
    %% Deployment config remains the trusted source for advanced options and
    %% allowed LAN endpoints. Never obtain those permissions from saved JSON.
    Base = ecai_ollama_pool:inherited_nodes(),
    File = maps:get(file, Opts, filename:join([ecai_paths:state_dir(), "llm-settings", "settings.json"])),
    case baseline(Base) of
        {ok, Initial} ->
            case load(File, Initial, Base) of
                {ok, Snap, Ns} ->
                    activate(Snap, Ns),
                    {ok, #{file => File, base => Base, snapshot => Snap, probes => #{}}};
                {error, Why} -> {stop, {llm_settings_unavailable, Why}}
            end;
        Error -> {stop, Error}
    end.
handle_call(status, _From, S) ->
    {reply, maps:get(snapshot, S), S};
handle_call({update, Body, Actor}, _From, S) ->
    %% Never include request bodies, credentials, vault errors or stack traces
    %% in logs, responses or gen_server crash formatting.
    case safe_update(Body, Actor, S) of
        {ok, New} -> {reply, {ok, New}, S#{snapshot => New}};
        {error, _} = Error -> {reply, Error, S}
    end;
handle_call({probe_options, Body}, _From, S) ->
    try
        exact(Body, [<<"revision">>, <<"id">>]),
        Snap = maps:get(snapshot, S),
        need(maps:get(<<"revision">>, Body) =:= maps:get(revision, Snap), stale_revision),
        Id = maps:get(<<"id">>, Body),
        Config = maps:get(config, Snap),
        [C] = [N || N <- maps:get(<<"connections">>, Config), maps:get(<<"id">>, N) =:= Id],
        Now = erlang:monotonic_time(millisecond), Ps = maps:get(probes, S),
        need(Now - maps:get(Id, Ps, Now - 2000) >= 1000, probe_rate_limited),
        Node = to_node(C, maps:get(base, S)),
        {ok, Normalized} = ecai_ollama_pool:validate_nodes([Node]),
        N = maps:get(Id, Normalized),
        Opts = maps:merge(maps:get(client_opts, N), maps:with([provider, host, port, transport, proxy], N)),
        {reply, {ok, Opts}, S#{probes => Ps#{Id => Now}}}
    catch
        throw:Why -> {reply, {error, Why}, S};
        _:_ -> {reply, {error, invalid_probe}, S}
    end;
handle_call(_, _From, S) -> {reply, {error, unsupported_operation}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.
format_status(Status) ->
    maps:map(fun
        (state, _) -> redacted;
        (message, _) -> redacted;
        (reason, _) -> redacted;
        (log, _) -> [];
        (_, V) -> V
    end, Status).

safe_update(Body, Actor, S) ->
    try
        exact(Body, [<<"revision">>, <<"config">>]),
        need(is_binary(Actor) andalso byte_size(Actor) > 0 andalso byte_size(Actor) =< 256, invalid_actor),
        Current = maps:get(snapshot, S),
        need(maps:get(<<"revision">>, Body) =:= maps:get(revision, Current), stale_revision),
        Config0 = maps:get(<<"config">>, Body), Base = maps:get(base, S),
        {ok, _} = check_validation(validate(Config0, Base)),
        validate_credential_changes(Config0, maps:get(config, Current)),
        need(whereis(ecai_ollama_pool) =/= undefined, inference_pool_unavailable),
        %% Unique references never overwrite a credential in use by an old lease.
        Config = store_credentials(Config0),
        {ok, Nodes} = check_validation(validate(Config, Base)),
        Revision = maps:get(revision, Current) + 1,
        New = #{revision => Revision, source => dashboard, config => Config,
                updated_at => timestamp(), updated_by => Actor},
        Commit = fun() ->
            case persist(maps:get(file, S), New) of
                ok -> activate(New, Nodes), ok;
                _ -> {error, persistence_failed}
            end
        end,
        Runtime = maps:get(<<"runtime">>, Config),
        case whereis(ecai_ollama_pool) of
            undefined -> throw(inference_pool_unavailable);
            _ ->
                case ecai_ollama_pool:reconfigure(Nodes, Runtime, Revision, Commit) of
                    ok -> {ok, New};
                    {error, _} -> {error, activation_failed}
                end
        end
    catch
        throw:Why when is_atom(Why) -> {error, Why};
        _:_ ->
            %% A server can die after a durable commit but before replying.
            %% Recover the acknowledged disk revision rather than reverting it.
            case load(maps:get(file, S), maps:get(snapshot, S), maps:get(base, S)) of
                {ok, Recovered, Ns} ->
                    Old = maps:get(revision, maps:get(snapshot, S)),
                    case maps:get(revision, Recovered) > Old of
                        true -> activate(Recovered, Ns), {ok, Recovered};
                        false -> {error, settings_update_failed}
                    end;
                _ -> {error, settings_update_failed}
            end
    end.
check_validation({error, Why}) -> throw(Why);
check_validation(Ok) -> Ok.

validate(C, Base) ->
    try
        exact(C, [<<"connections">>, <<"runtime">>, <<"remote_roles">>, <<"route_chat">>]),
        bool(maps:get(<<"route_chat">>, C)),
        RemoteRoles = roles(maps:get(<<"remote_roles">>, C)),
        Connections = maps:get(<<"connections">>, C),
        need(is_list(Connections) andalso length(Connections) =< 32, invalid_connections),
        Ids = [validate_connection(N, Base, RemoteRoles) || N <- Connections],
        need(length(lists:usort(Ids)) =:= length(Ids), duplicate_connection_id),
        R = maps:get(<<"runtime">>, C),
        exact(R, [<<"health_interval_ms">>, <<"health_timeout_ms">>, <<"failure_threshold">>,
                  <<"queue_timeout_ms">>, <<"cluster_attempts">>]),
        integer(maps:get(<<"health_interval_ms">>, R), 5000, 3600000),
        integer(maps:get(<<"health_timeout_ms">>, R), 1000, 30000),
        integer(maps:get(<<"failure_threshold">>, R), 1, 10),
        integer(maps:get(<<"queue_timeout_ms">>, R), 1000, 1800000),
        integer(maps:get(<<"cluster_attempts">>, R), 1, 5),
        Nodes = [to_node(N, Base) || N <- Connections],
        case ecai_ollama_pool:validate_nodes(Nodes) of
            {ok, _} -> {ok, Nodes};
            _ -> {error, invalid_model_nodes}
        end
    catch
        throw:Why when is_atom(Why) -> {error, Why};
        _:_ -> {error, invalid_settings}
    end.

validate_connection(C, Base, Remote) ->
    Allowed = [<<"id">>, <<"provider">>, <<"enabled">>, <<"host">>, <<"port">>, <<"transport">>,
        <<"default_model">>, <<"models">>, <<"roles">>, <<"weight">>, <<"max_inflight">>,
        <<"timeout_ms">>, <<"connect_timeout_ms">>, <<"max_output_tokens">>, <<"temperature">>,
        <<"auth_type">>, <<"credential_ref">>],
    need(is_map(C), invalid_connection),
    need(lists:sort(maps:keys(maps:remove(<<"api_key">>, C))) =:= lists:sort(Allowed), unexpected_connection_fields),
    Id = text(maps:get(<<"id">>, C), 128),
    %% Accept existing scheduler IDs (including host:port), but no slashes/control bytes.
    need(re:run(Id, <<"^[A-Za-z0-9_.:-]+$">>, [{capture, none}]) =:= match, invalid_connection_id),
    P = provider(maps:get(<<"provider">>, C)),
    Enabled = maps:get(<<"enabled">>, C), bool(Enabled),
    Host = text(maps:get(<<"host">>, C), 253),
    Port = maps:get(<<"port">>, C), integer(Port, 1, 65535),
    T = transport(maps:get(<<"transport">>, C)),
    need(endpoint_allowed(P, Host, Port, T, Base), endpoint_not_allowed),
    Rs = roles(maps:get(<<"roles">>, C)),
    need(not Enabled orelse is_local(P, Host) orelse lists:all(fun(X) -> lists:member(X, Remote) end, Rs),
         remote_role_not_allowed),
    Model = maps:get(<<"default_model">>, C),
    case {Enabled, Model} of {false, <<>>} -> ok; _ -> text(Model, 256) end,
    case maps:get(<<"models">>, C) of
        <<"all">> -> ok;
        Ms when is_list(Ms), length(Ms) > 0, length(Ms) =< 256 ->
            [text(M, 256) || M <- Ms],
            need(not Enabled orelse lists:member(Model, Ms), default_model_not_allowed);
        _ -> throw(invalid_models)
    end,
    integer(maps:get(<<"max_inflight">>, C), 1, 64),
    integer(maps:get(<<"weight">>, C), 1, 100),
    integer(maps:get(<<"timeout_ms">>, C), 1000, 1800000),
    integer(maps:get(<<"connect_timeout_ms">>, C), 100, 30000),
    nullable_integer(maps:get(<<"max_output_tokens">>, C), 1, 32768),
    Temp = maps:get(<<"temperature">>, C),
    MaxTemp = case P of anthropic -> 1; _ -> 2 end,
    need(Temp =:= null orelse (is_number(Temp) andalso Temp >= 0 andalso Temp =< MaxTemp), invalid_temperature),
    validate_auth(C, Base),
    case maps:get(<<"api_key">>, C, <<>>) of
        <<>> -> ok;
        Key -> text(Key, 8192), need(byte_size(Key) >= 10, invalid_api_key)
    end,
    Id.

validate_auth(C, Base) ->
    Ref = maps:get(<<"credential_ref">>, C),
    case maps:get(<<"auth_type">>, C) of
        <<"none">> ->
            need(maps:get(<<"provider">>, C) =:= <<"ollama">> orelse
                 maps:get(<<"api_key">>, C, <<>>) =/= <<>>, credential_required),
            need(Ref =:= <<>>, invalid_credential_reference);
        <<"environment">> ->
            text(Ref, 128), need(lists:member(Ref, allowed_envs(Base)), environment_reference_not_allowed);
        <<"inherited">> ->
            N = base_node(maps:get(<<"id">>, C), Base),
            need(N =/= undefined andalso same_endpoint(C, N), inherited_credential_endpoint_changed),
            need(Ref =:= <<>>, invalid_credential_reference);
        <<"vault">> ->
            text(Ref, 256),
            Prefix = <<"ecai-llm/", (maps:get(<<"id">>, C))/binary, "/">>,
            need(byte_size(Ref) =:= byte_size(Prefix) + 32 andalso
                 binary:part(Ref, 0, byte_size(Prefix)) =:= Prefix, invalid_credential_reference);
        _ -> throw(invalid_auth_type)
    end.

endpoint_allowed(openai, <<"api.openai.com">>, 443, tls, _) -> true;
endpoint_allowed(anthropic, <<"api.anthropic.com">>, 443, tls, _) -> true;
endpoint_allowed(ollama, Host, Port, Transport, Base) ->
    %% Loopback inference is available by default ONLY on the Ollama port.
    %% Additional LAN ports/hosts must be declared by the deployment operator.
    Local = is_local(ollama, Host) andalso Port =:= 11434,
    Cloud = Host =:= <<"ollama.com">> andalso Port =:= 443 andalso Transport =:= tls,
    NormalizedBase = case ecai_ollama_pool:validate_nodes(Base) of
        {ok, BaseNodes} -> maps:values(BaseNodes);
        _ -> []
    end,
    Declared = NormalizedBase ++ application:get_env(ecai, llm_settings_ollama_endpoints, []),
    Local orelse Cloud orelse lists:any(fun(N0) ->
        N = as_map(N0),
        maps:get(provider, N, ollama) =:= ollama andalso
        bin(maps:get(host, N, <<>>)) =:= Host andalso maps:get(port, N, 11434) =:= Port andalso
        maps:get(transport, N, tcp) =:= Transport
    end, Declared);
endpoint_allowed(P, Host, Port, Transport, Base) when P =:= openai; P =:= anthropic ->
    case ecai_ollama_pool:validate_nodes(Base) of
        {ok, Ns} -> lists:any(fun(N) ->
            maps:get(provider, N) =:= P andalso bin(maps:get(host, N)) =:= Host andalso
            maps:get(port, N) =:= Port andalso maps:get(transport, N) =:= Transport
        end, maps:values(Ns));
        _ -> false
    end;
endpoint_allowed(_, _, _, _, _) -> false.
is_local(ollama, H) -> lists:member(H, [<<"127.0.0.1">>, <<"::1">>, <<"localhost">>]);
is_local(_, _) -> false.

allowed_envs(Base) ->
    Builtin = [<<"OPENAI_API_KEY">>, <<"ANTHROPIC_API_KEY">>, <<"OLLAMA_API_KEY">>],
    Extra = [bin(E) || E <- application:get_env(ecai, llm_settings_allowed_envs, [])],
    Inherited = [bin(E) || N0 <- Base, N <- [as_map(N0)],
        E <- [maps:get(api_key_env, N, auth_env(maps:get(auth, N, none)))], E =/= undefined],
    lists:usort(Builtin ++ Extra ++ Inherited).
auth_env(#{type := bearer_env, env := E}) -> E;
auth_env({bearer_env, E}) -> E;
auth_env(_) -> undefined.

to_node(C, Base) ->
    Id = maps:get(<<"id">>, C), P = provider(maps:get(<<"provider">>, C)),
    Old = case base_node(Id, Base) of undefined -> #{}; N -> N end,
    %% Preserve advanced deployment settings only for an unchanged destination.
    Preserved = case same_endpoint(C, Old) of
        true -> Old;
        false -> #{}
    end,
    Auth = case maps:get(<<"auth_type">>, C) of
        <<"none">> -> none;
        <<"environment">> -> #{type => bearer_env, env => maps:get(<<"credential_ref">>, C)};
        <<"vault">> -> #{type => bearer_secret, scope => node, name => maps:get(<<"credential_ref">>, C)};
        <<"inherited">> -> inherited_auth(Old, P)
    end,
    Ms = case maps:get(<<"models">>, C) of <<"all">> -> all; M -> M end,
    N0 = maps:merge(Preserved, #{id => Id, provider => P, enabled => maps:get(<<"enabled">>, C),
        host => binary_to_list(maps:get(<<"host">>, C)), port => maps:get(<<"port">>, C),
        transport => transport(maps:get(<<"transport">>, C)), proxy => direct,
        roles => [role(R) || R <- maps:get(<<"roles">>, C)], models => Ms,
        default_model => maps:get(<<"default_model">>, C),
        weight => maps:get(<<"weight">>, C), max_inflight => maps:get(<<"max_inflight">>, C),
        timeout => maps:get(<<"timeout_ms">>, C), connect_timeout => maps:get(<<"connect_timeout_ms">>, C),
        auth => Auth, response_decode => json_binary, max_response_bytes => 8388608, store => false}),
    N1 = optional_option(temperature, maps:get(<<"temperature">>, C), N0),
    optional_option(max_output_tokens, maps:get(<<"max_output_tokens">>, C), N1).
optional_option(K, null, N) -> maps:remove(K, N);
optional_option(K, V, N) -> N#{K => V}.
inherited_auth(N, P) ->
    Default = case P of openai -> #{type => bearer_env, env => "OPENAI_API_KEY"};
        anthropic -> #{type => bearer_env, env => "ANTHROPIC_API_KEY"}; _ -> none end,
    case N of
        #{auth := A} -> A;
        #{api_key_env := E} -> #{type => bearer_env, env => E};
        #{api_key_file := F} -> #{type => bearer_file, path => F};
        #{api_key_secret := R} -> #{type => bearer_secret, scope => node, name => R};
        _ -> Default
    end.
base_node(Id, Base) ->
    %% Match the scheduler's canonical IDs, including autogenerated IDs.
    case ecai_ollama_pool:validate_nodes(Base) of
        {ok, Ns} ->
            case maps:find(Id, Ns) of
                {ok, N} ->
                    %% Reconstitute normalized client settings without health state.
                    maps:merge((maps:get(client_opts, N))#{model_digests => maps:get(configured_digests, N)}, maps:with(
                        [id, provider, host, port, transport, proxy, billing_sensitive,
                         roles, max_inflight, weight, default_model], N));
                _ -> undefined
            end;
        _ -> undefined
    end.
same_endpoint(_C, undefined) -> false;
same_endpoint(C, N) ->
    maps:get(<<"provider">>, C) =:= bin(maps:get(provider, N, undefined)) andalso
    maps:get(<<"host">>, C) =:= bin(maps:get(host, N, undefined)) andalso
    maps:get(<<"port">>, C) =:= maps:get(port, N, undefined) andalso
    maps:get(<<"transport">>, C) =:= bin(maps:get(transport, N, tcp)).

validate_credential_changes(New, Previous) ->
    OldConnections = maps:get(<<"connections">>, Previous),
    lists:foreach(fun(C) ->
        case {maps:get(<<"auth_type">>, C), maps:get(<<"api_key">>, C, <<>>)} of
            {<<"vault">>, <<>>} ->
                Ref = maps:get(<<"credential_ref">>, C),
                Matches = [O || O <- OldConnections, maps:get(<<"credential_ref">>, O) =:= Ref],
                Fields = [<<"id">>, <<"provider">>, <<"host">>, <<"port">>, <<"transport">>],
                need(lists:any(fun(O) -> maps:with(Fields, O) =:= maps:with(Fields, C) end, Matches),
                     credential_destination_changed);
            _ -> ok
        end
    end, maps:get(<<"connections">>, New)).

store_credentials(Config) ->
    Cs = [case maps:get(<<"api_key">>, C, <<>>) of
        <<>> -> maps:remove(<<"api_key">>, C);
        Key ->
            Ref = <<"ecai-llm/", (maps:get(<<"id">>, C))/binary, "/",
                    (binary:encode_hex(crypto:strong_rand_bytes(16)))/binary>>,
            Result = try secrets:encrypt_store(node, Ref, Key) of
                ok -> secrets:sync();
                _ -> error
            catch _:_ -> error end,
            need(Result =:= ok, credential_store_unavailable),
            (maps:remove(<<"api_key">>, C))#{<<"auth_type">> => <<"vault">>, <<"credential_ref">> => Ref}
    end || C <- maps:get(<<"connections">>, Config)],
    Config#{<<"connections">> => Cs}.

baseline(Base) ->
    case ecai_ollama_pool:validate_nodes(Base) of
        {ok, Ns} ->
            Cs = [public_connection(N) || {_Id, N} <- lists:sort(maps:to_list(Ns))],
            Remote = lists:usort(lists:append([maps:get(<<"roles">>, C) || C <- Cs,
                not is_local(provider(maps:get(<<"provider">>, C)), maps:get(<<"host">>, C))])),
            {ok, #{revision => 0, source => deployment, updated_at => null, updated_by => null,
                config => #{<<"connections">> => Cs, <<"runtime">> => runtime_defaults(),
                            <<"remote_roles">> => Remote, <<"route_chat">> => false}}};
        _ -> {error, invalid_deployment_nodes}
    end.
public_connection(N) ->
    O = maps:get(client_opts, N),
    Defaults = case maps:get(provider, N) of
        ollama -> ecai_ollama_client:defaults();
        openai -> #{timeout => application:get_env(ecai, code_openai_timeout_ms, 180000),
                    connect_timeout => application:get_env(ecai, code_openai_connect_timeout_ms, 5000)};
        _ -> #{timeout => 180000, connect_timeout => 5000}
    end,
    #{<<"id">> => maps:get(id, N), <<"provider">> => bin(maps:get(provider, N)),
      <<"enabled">> => maps:get(enabled, N, true), <<"host">> => bin(maps:get(host, N)),
      <<"port">> => maps:get(port, N), <<"transport">> => bin(maps:get(transport, N)),
      <<"default_model">> => maps:get(default_model, N),
      <<"models">> => case maps:get(configured_models, N) of all -> <<"all">>; Ms -> Ms end,
      <<"roles">> => [bin(R) || R <- maps:get(roles, N)],
      <<"weight">> => maps:get(weight, N), <<"max_inflight">> => maps:get(max_inflight, N),
      <<"timeout_ms">> => maps:get(timeout, O, maps:get(timeout, Defaults)),
      <<"connect_timeout_ms">> => maps:get(connect_timeout, O, maps:get(connect_timeout, Defaults)),
      <<"max_output_tokens">> => maps:get(max_output_tokens, O, null),
      <<"temperature">> => maps:get(temperature, O, null),
      <<"auth_type">> => <<"inherited">>, <<"credential_ref">> => <<>>}.
runtime_defaults() -> maps:from_list([{bin(K), application:get_env(ecai, Env,
        application:get_env(ecai, Legacy, Default))} || {K, Env, Legacy, Default} <- runtime_keys()]).
runtime_keys() ->
    [{health_interval_ms, code_model_health_interval_ms, code_ollama_health_interval_ms, 30000},
     {health_timeout_ms, code_model_health_timeout_ms, code_ollama_health_timeout_ms, 5000},
     {failure_threshold, code_model_failure_threshold, code_ollama_failure_threshold, 2},
     {queue_timeout_ms, code_model_queue_timeout_ms, code_ollama_queue_timeout_ms, 300000},
     {cluster_attempts, code_model_cluster_attempts, code_ollama_cluster_attempts, 3}].
activate(Snap, Nodes) ->
    C = maps:get(config, Snap), Managed = maps:get(revision, Snap) > 0,
    case Managed of
        true -> [application:set_env(ecai, E, maps:get(bin(K), maps:get(<<"runtime">>, C)))
                 || {K, E, _, _} <- runtime_keys()];
        false -> ok
    end,
    persistent_term:put(?KEY, #{managed => Managed, nodes => Nodes, revision => maps:get(revision, Snap),
                              route_chat => maps:get(<<"route_chat">>, C)}), ok.
load(File, Initial, Base) ->
    case file:read_file(File) of
        {error, enoent} -> {ok, Initial, Base};
        {ok, Bytes} when byte_size(Bytes) =< 262144 ->
            try
                J = jsx:decode(Bytes, [return_maps]),
                Rev = maps:get(<<"revision">>, J), need(is_integer(Rev) andalso Rev > 0, invalid_revision),
                C = maps:get(<<"config">>, J),
                %% Credential values are never valid persisted configuration.
                need(lists:all(fun(N) -> not maps:is_key(<<"api_key">>, N) end,
                               maps:get(<<"connections">>, C)), invalid_saved_credentials),
                {ok, Ns} = validate(C, Base),
                {ok, #{revision => Rev, source => dashboard, config => C,
                       updated_at => maps:get(<<"updated_at">>, J, null),
                       updated_by => maps:get(<<"updated_by">>, J, null)}, Ns}
            catch _:_ -> {error, invalid_saved_settings} end;
        _ -> {error, unreadable_settings}
    end.
persist(File, Snap) ->
    Tmp = File ++ "." ++ integer_to_list(erlang:unique_integer([positive])) ++ ".tmp",
    try
        ok = filelib:ensure_dir(File),
        ok = file:change_mode(filename:dirname(File), 8#700),
        {ok, Io} = file:open(Tmp, [write, binary, raw, exclusive]),
        try
            ok = file:change_mode(Tmp, 8#600),
            ok = file:write(Io, jsx:encode(Snap)), ok = file:sync(Io)
        after file:close(Io) end,
        ok = file:rename(Tmp, File), ok
    catch _:_ -> {error, persistence_failed}
    after file:delete(Tmp) end.

pool_status() ->
    try gen_server:call(ecai_ollama_pool, status, 1000) of
        #{nodes := Ns} = P ->
            Fields = [id, provider, enabled, health, default_model, roles, inflight,
                      max_inflight, selections, latency_ema_ms, last_checked_at],
            #{available => true, revision => maps:get(config_revision, P, 0),
              nodes => [maps:with(Fields, N) || N <- Ns]}
    catch _:_ -> #{available => false} end.
damage_profiles() ->
    [#{name => bin(Name), shared_registry => proplists:get_value(backend, P) =:= damage_ai_ecai,
       role => bdd} || {Name, P} <- application:get_env(damage, ai_profiles, []), is_list(P)].
safe_error({Tag, Status}) when is_atom(Tag), is_integer(Status) ->
    #{code => Tag, http_status => Status};
safe_error({Tag, _, _}) when is_atom(Tag) -> Tag;
safe_error({Tag, _}) when is_atom(Tag) -> Tag;
safe_error(Tag) when is_atom(Tag) -> Tag;
safe_error(_) -> probe_failed.
exact(M, Keys) -> need(is_map(M) andalso lists:sort(maps:keys(M)) =:= lists:sort(Keys), unexpected_fields).
need(true, _) -> ok;
need(false, Why) -> throw(Why).
bool(V) -> need(V =:= true orelse V =:= false, boolean_required).
integer(V, Min, Max) -> need(is_integer(V) andalso V >= Min andalso V =< Max, integer_out_of_range).
nullable_integer(null, _, _) -> ok;
nullable_integer(V, Min, Max) -> integer(V, Min, Max).
text(V, Max) ->
    need(is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< Max, invalid_text),
    need(binary:match(V, [<<"\r">>, <<"\n">>, <<0>>]) =:= nomatch, invalid_text),
    need(unicode:characters_to_binary(V, utf8, utf8) =:= V, invalid_utf8), V.
roles(Rs) ->
    need(is_list(Rs) andalso length(Rs) =< length(?ROLES) andalso
         lists:all(fun(R) -> lists:member(R, ?ROLES) end, Rs), invalid_roles),
    need(length(lists:usort(Rs)) =:= length(Rs), duplicate_role), Rs.
role(<<"learning">>) -> learning;
role(<<"audit">>) -> audit;
role(<<"patch">>) -> patch;
role(<<"synthesis">>) -> synthesis;
role(<<"chat">>) -> chat;
role(<<"bdd">>) -> bdd.
provider(<<"ollama">>) -> ollama;
provider(<<"openai">>) -> openai;
provider(<<"anthropic">>) -> anthropic;
provider(_) -> throw(invalid_provider).
transport(<<"tcp">>) -> tcp;
transport(<<"tls">>) -> tls;
transport(_) -> throw(invalid_transport).
as_map(M) when is_map(M) -> M;
as_map(L) when is_list(L) -> maps:from_list(L).
bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> unicode:characters_to_binary(L).
timestamp() -> list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])).
