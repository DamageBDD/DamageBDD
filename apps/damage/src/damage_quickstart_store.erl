%% Copyright (c) DamageBDD. Licensed under Apache-2.0.
%% Supervised, serialized trial quotas and expiring bearer-link report storage.
-module(damage_quickstart_store).
-behaviour(gen_server).

-export([
    start_link/0,
    issue_session/1,
    reserve/2,
    release/1,
    store_report/1,
    get_report/1
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DAY, 86400).
-define(HOUR, 3600).
-define(MAX_PEER_PER_HOUR, 5).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

issue_session(PeerHash) -> gen_server:call(?MODULE, {issue_session, PeerHash}, 5000).
reserve(Session, PeerHash) -> gen_server:call(?MODULE, {reserve, Session, PeerHash}, 5000).
release(Lease) -> gen_server:call(?MODULE, {release, Lease}, 5000).
store_report(Report) -> gen_server:call(?MODULE, {store_report, Report}, 5000).
get_report(Id) -> gen_server:call(?MODULE, {get_report, Id}, 5000).

init([]) ->
    case application:get_env(damage, quickstart_enabled, false) of
        true ->
            Dir = application:get_env(damage, quickstart_state_dir, "logs/quickstart"),
            Filename = filename:join(Dir, "trial.dets"),
            case filelib:ensure_dir(Filename) of
                ok ->
                    case dets:open_file(?MODULE, [{file, Filename}, {type, set}]) of
                        {ok, Tab} ->
                            erlang:send_after(?HOUR * 1000, self(), sweep),
                            {ok, #{table => Tab, active => #{}}};
                        Error ->
                            {stop, {trial_store_open_failed, Error}}
                    end;
                Error ->
                    {stop, {trial_state_dir_unwritable, Error}}
            end;
        false ->
            {ok, #{table => disabled, active => #{}}}
    end.

handle_call(_Request, _From, #{table := disabled} = State) ->
    {reply, {error, not_enabled}, State};
handle_call({issue_session, PeerHash}, _From, #{table := Tab} = State) when
    is_binary(PeerHash), byte_size(PeerHash) =:= 64
->
    Now = erlang:system_time(second),
    Hour = Now div ?HOUR,
    MaxGenerations = application:get_env(damage, quickstart_max_generations_per_peer_hour, 10),
    Records = dets:lookup(Tab, {generated, PeerHash}),
    Count =
        case Records of
            [{{generated, PeerHash}, #{hour := Hour, count := N}}] -> N;
            _ -> 0
        end,
    case
        is_integer(MaxGenerations) andalso MaxGenerations > 0 andalso
            Count < MaxGenerations
    of
        true ->
            Session = lowercase_hex(crypto:strong_rand_bytes(24)),
            ok = dets:insert(
                Tab,
                {{generated, PeerHash}, #{
                    hour => Hour,
                    count => Count + 1,
                    expires_at => (Hour + 1) * ?HOUR
                }}
            ),
            ok = dets:insert(Tab, {{session, Session}, #{expires_at => Now + ?DAY, used => false}}),
            {reply, {ok, Session}, State};
        false ->
            {reply, {error, generation_rate_limited}, State}
    end;
handle_call(
    {reserve, Session, PeerHash},
    {Caller, _Tag},
    #{table := Tab, active := Active} = State
) ->
    Now = erlang:system_time(second),
    MaxActive = application:get_env(damage, quickstart_max_inflight, 4),
    Result =
        case maps:size(Active) >= MaxActive of
            true -> {error, busy};
            false -> reserve_quota(Tab, Session, PeerHash, Now)
        end,
    case Result of
        ok ->
            Monitor = erlang:monitor(process, Caller),
            Lease = make_ref(),
            {reply, {ok, Lease}, State#{active := Active#{Lease => Monitor}}};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({release, Lease}, _From, #{active := Active} = State) ->
    case maps:take(Lease, Active) of
        {Monitor, Rest} ->
            erlang:demonitor(Monitor, [flush]),
            {reply, ok, State#{active := Rest}};
        error ->
            {reply, ok, State}
    end;
handle_call({store_report, Report0}, _From, #{table := Tab} = State) when
    is_map(Report0)
->
    Now = erlang:system_time(second),
    Id = lowercase_hex(crypto:strong_rand_bytes(24)),
    Report = Report0#{id => Id, created_at => Now, expires_at => Now + ?DAY},
    ok = dets:insert(Tab, {{report, Id}, Report}),
    {reply, {ok, Id}, State};
handle_call({get_report, Id}, _From, #{table := Tab} = State) ->
    Now = erlang:system_time(second),
    Response =
        case dets:lookup(Tab, {report, Id}) of
            [{{report, Id}, #{expires_at := Expiry} = Report}] when Expiry > Now ->
                {ok, Report};
            _ ->
                {error, not_found}
        end,
    {reply, Response, State};
handle_call(_, _From, State) ->
    {reply, {error, bad_request}, State}.

reserve_quota(Tab, Session, PeerHash, Now) when
    is_binary(Session),
    is_binary(PeerHash),
    byte_size(Session) =:= 48,
    byte_size(PeerHash) =:= 64
->
    Hour = Now div ?HOUR,
    MaxPeer = application:get_env(
        damage,
        quickstart_max_peer_per_hour,
        ?MAX_PEER_PER_HOUR
    ),
    case {dets:lookup(Tab, {session, Session}), dets:lookup(Tab, {peer, PeerHash})} of
        {[{{session, Session}, #{used := false, expires_at := Expires}}], PeerRecords} when
            Expires > Now
        ->
            Count =
                case PeerRecords of
                    [{{peer, PeerHash}, #{hour := Hour, count := N}}] -> N;
                    _ -> 0
                end,
            case is_integer(MaxPeer) andalso MaxPeer > 0 andalso Count < MaxPeer of
                false ->
                    {error, rate_limited};
                true ->
                    %% Charge the attempt before opening an outbound connection.
                    ok = dets:insert(
                        Tab, {{session, Session}, #{used => true, expires_at => Expires}}
                    ),
                    ok = dets:insert(
                        Tab,
                        {{peer, PeerHash}, #{
                            hour => Hour,
                            count => Count + 1,
                            expires_at => (Hour + 1) * ?HOUR
                        }}
                    ),
                    ok
            end;
        _ ->
            {error, trial_already_used_or_expired}
    end;
reserve_quota(_, _, _, _) ->
    {error, bad_trial_session}.

handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, #{active := Active} = State) ->
    Rest = maps:filter(fun(_Lease, Ref) -> Ref =/= Monitor end, Active),
    {noreply, State#{active := Rest}};
handle_info(sweep, #{table := Tab} = State) ->
    Now = erlang:system_time(second),
    Expired = dets:foldl(
        fun
            ({Key, #{expires_at := E}}, Acc) when E =< Now -> [Key | Acc];
            (_, Acc) -> Acc
        end,
        [],
        Tab
    ),
    lists:foreach(fun(Key) -> ok = dets:delete(Tab, Key) end, Expired),
    erlang:send_after(?HOUR * 1000, self(), sweep),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

terminate(_, #{table := Tab}) when Tab =/= disabled ->
    dets:close(Tab),
    ok;
terminate(_, _) ->
    ok.
code_change(_, State, _) -> {ok, State}.

lowercase_hex(Bytes) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bytes)))).
