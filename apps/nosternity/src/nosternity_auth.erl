%% Durable account records; bounded, revocable node-local browser sessions.
%% A social identity never grants DamageBDD custody or payment authority.
-module(nosternity_auth).
-behaviour(gen_server).
-export([
    start_link/0,
    attempt/1,
    challenge/5,
    verify_nostr/5,
    verify_lightning/4,
    poll_lightning/3,
    damage/2,
    lookup/1,
    revoke/1,
    account/1,
    update/2,
    observe/3,
    metrics/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
attempt(Peer) -> call({attempt, Peer}).
challenge(Provider, Intent, Origin, Binding, Peer) ->
    call({challenge, Provider, Intent, Origin, Binding, Peer}).
verify_nostr(Id, Event, Payload, Origin, Binding) ->
    call({nostr, Id, Event, Payload, Origin, Binding}).
verify_lightning(Id, Signature, Key, Action) -> call({lightning, Id, Signature, Key, Action}).
poll_lightning(Id, Origin, Binding) -> call({poll, Id, Origin, Binding}).
damage(Address, Intent) -> call({damage, Address, Intent}).
lookup(Token) -> call({lookup, Token}).
revoke(Token) -> call({revoke, Token}).
account(Token) -> call({account, Token}).
update(Token, Prefs) -> call({update, Token, Prefs}).
observe(Kind, Elapsed, Hidden) -> gen_server:cast(?MODULE, {observe, Kind, Elapsed, Hidden}).
metrics() -> call(metrics).
call(Msg) ->
    try
        gen_server:call(?MODULE, Msg, 15000)
    catch
        exit:_ -> {error, auth_unavailable}
    end.

init([]) ->
    case nosternity_storage:open(auth_store_file, ?MODULE, false) of
        {ok, ?MODULE, _File} ->
            erlang:send_after(30000, self(), prune),
            {ok, #{
                challenges => #{},
                sessions => #{},
                attempts => #{},
                metrics => #{requests => 0, searches => 0, hidden => 0, duration_ms => 0},
                started_at => erlang:system_time(second)
            }};
        {error, Why} ->
            {stop, Why}
    end.

handle_call(Msg, From, State0) ->
    State = prune(State0),
    try
        handle(Msg, From, State)
    catch
        _:_ -> {reply, {error, auth_unavailable}, State}
    end.
handle({attempt, Peer}, _, S) ->
    A = maps:get(attempts, S),
    {N, Until} = maps:get(Peer, A, {0, now_ms() + 60000}),
    case
        N < nosternity_config:get(auth_attempts_per_minute) andalso
            (maps:is_key(Peer, A) orelse map_size(A) < 10000)
    of
        true -> {reply, ok, S#{attempts := A#{Peer => {N + 1, Until}}}};
        false -> {reply, {error, rate_limited}, S}
    end;
handle({challenge, Provider, Intent, Origin, Binding, Peer}, _, S) when
    (Provider =:= nostr orelse Provider =:= lightning),
    (Intent =:= <<"login">> orelse Intent =:= <<"signup">>),
    is_binary(Origin),
    is_binary(Binding),
    byte_size(Binding) =:= 64
->
    Cs = maps:get(challenges, S),
    PeerCount = length([ok || #{peer := P} <- maps:values(Cs), P =:= Peer]),
    case map_size(Cs) < nosternity_config:get(auth_max_challenges) andalso PeerCount < 4 of
        false ->
            {reply, {error, rate_limited}, S};
        true ->
            Id = random(),
            TTL = nosternity_config:get(auth_challenge_ttl_seconds),
            C = #{
                provider => Provider,
                intent => Intent,
                origin => Origin,
                binding => digest(Binding),
                peer => Peer,
                until => now_ms() + TTL * 1000
            },
            Public = #{challenge_id => Id, expires_at => erlang:system_time(second) + TTL},
            Response =
                case Provider of
                    nostr ->
                        Payload = jsx:encode(#{challenge_id => Id, intent => Intent}),
                        Public#{
                            payload => Payload,
                            event => #{
                                kind => 27235,
                                content => <<>>,
                                created_at => erlang:system_time(second),
                                tags => [
                                    [
                                        <<"u">>,
                                        <<Origin/binary, "/api/nosternity/auth/nostr/verify">>
                                    ],
                                    [<<"method">>, <<"POST">>],
                                    [
                                        <<"payload">>,
                                        nosternity_auth_proof:hex(crypto:hash(sha256, Payload))
                                    ]
                                ]
                            }
                        };
                    lightning ->
                        Action = ln_action(Intent),
                        URL =
                            <<Origin/binary,
                                "/api/nosternity/auth/lightning/callback?tag=login&k1=", Id/binary,
                                "&action=", Action/binary>>,
                        {ok, Words} = bech32:convertbits(URL, 8, 5),
                        {ok, Encoded} = bech32:encode("lnurl", Words, [{format, bech32}]),
                        Public#{lnurl => iolist_to_binary(Encoded), callback => URL}
                end,
            {reply, {ok, Response}, S#{challenges := Cs#{Id => C}}}
    end;
handle({nostr, Id, Event, Payload, Origin, Binding}, _, S) ->
    case bound_challenge(Id, nostr, Origin, Binding, S) of
        {ok, C} ->
            S1 = remove_challenge(Id, S),
            %% Single use even for an invalid signed proof. Catch errors after
            %% consumption locally so outer error handling cannot restore it.
            Proof =
                try
                    #{<<"challenge_id">> := Id, <<"intent">> := Intent} =
                        Obj = jsx:decode(Payload, [return_maps]),
                    2 = map_size(Obj),
                    Intent = maps:get(intent, C),
                    nosternity_auth_proof:nostr(
                        Event,
                        <<Origin/binary, "/api/nosternity/auth/nostr/verify">>,
                        Payload,
                        erlang:system_time(second)
                    )
                catch
                    _:_ -> {error, invalid_proof}
                end,
            case Proof of
                {ok, Pubkey} -> finish(nostr, Pubkey, maps:get(intent, C), S1);
                _ -> {reply, {error, invalid_proof}, S1}
            end;
        Error ->
            {reply, Error, S}
    end;
handle({lightning, Id, Sig, Key, Action}, _, S) ->
    Cs = maps:get(challenges, S),
    case maps:find(Id, Cs) of
        {ok, #{provider := lightning, intent := Intent} = C} ->
            case {maps:is_key(verified_key, C), Action =:= ln_action(Intent)} of
                {false, true} ->
                    case nosternity_auth_proof:lightning(Id, Sig, Key) of
                        {ok, VerifiedKey} ->
                            {reply, ok, S#{
                                challenges := Cs#{Id := C#{verified_key => VerifiedKey}}
                            }};
                        _ ->
                            {reply, {error, invalid_proof}, remove_challenge(Id, S)}
                    end;
                _ ->
                    {reply, {error, invalid_challenge}, S}
            end;
        _ ->
            {reply, {error, invalid_challenge}, S}
    end;
handle({poll, Id, Origin, Binding}, _, S) ->
    case bound_challenge(Id, lightning, Origin, Binding, S) of
        {ok, #{verified_key := Key, intent := Intent}} ->
            finish(lightning, Key, Intent, remove_challenge(Id, S));
        {ok, _} ->
            {reply, {ok, pending}, S};
        Error ->
            {reply, Error, S}
    end;
handle({damage, Address, Intent}, _, S) when
    is_binary(Address),
    byte_size(Address) < 100,
    (Intent =:= <<"login">> orelse Intent =:= <<"signup">>)
->
    %% Called only after the same-origin HTTP adapter resolves a live ds1 session.
    case damage_browser_auth:valid_address(Address) of
        true -> finish(damage, Address, Intent, S);
        false -> {reply, {error, invalid_proof}, S}
    end;
handle({lookup, Token}, _, S) ->
    {reply, session(Token, S), S};
handle({revoke, Token}, _, S) when is_binary(Token) ->
    {reply, ok, S#{sessions := maps:remove(digest(Token), maps:get(sessions, S))}};
handle({account, Token}, _, S) ->
    Result =
        case session(Token, S) of
            {ok, #{account_id := Id}} -> stored_account(Id);
            Error -> Error
        end,
    {reply, Result, S};
handle({update, Token, Prefs}, _, S) ->
    Result =
        case {session(Token, S), valid_preferences(Prefs)} of
            {{ok, #{account_id := Id}}, true} ->
                case stored_account(Id) of
                    {ok, A} -> save_account(Id, A#{preferences := Prefs});
                    Error -> Error
                end;
            {{error, _} = Error, _} ->
                Error;
            _ ->
                {error, invalid_preferences}
        end,
    {reply, Result, S};
handle(metrics, _, S) ->
    {reply,
        (maps:get(metrics, S))#{
            since => maps:get(started_at, S),
            scope => <<"dashboard requests on this node since restart">>
        },
        S};
handle(_, _, S) ->
    {reply, {error, invalid_request}, S}.

finish(Provider, Subject, Intent, S) ->
    try
        finish_checked(Provider, Subject, Intent, S)
    catch
        _:_ -> {reply, {error, account_store_unavailable}, S}
    end.
finish_checked(Provider, Subject, Intent, S) ->
    Id = nosternity_auth_proof:hex(
        crypto:hash(sha256, <<(atom_to_binary(Provider, utf8))/binary, ":", Subject/binary>>)
    ),
    Account =
        case {stored_account(Id), Intent} of
            %% idempotent signup only after proving this exact identity
            {{ok, A}, _} ->
                {ok, A};
            {{error, not_found}, <<"login">>} ->
                {error, account_not_found};
            {{error, not_found}, <<"signup">>} ->
                case
                    nosternity_config:get(auth_signup_enabled) andalso
                        dets:info(?MODULE, size) < nosternity_config:get(auth_max_accounts)
                of
                    true ->
                        save_account(Id, #{
                            account_id => Id,
                            provider => Provider,
                            subject => Subject,
                            created_at => erlang:system_time(second),
                            preferences => defaults()
                        });
                    false ->
                        {error, signup_unavailable}
                end;
            {Error, _} ->
                Error
        end,
    case Account of
        {ok, A1} -> issue(A1, S);
        Error1 -> {reply, Error1, S}
    end.
issue(A, S) ->
    Ss = maps:get(sessions, S),
    case map_size(Ss) < nosternity_config:get(auth_max_sessions) of
        false ->
            {reply, {error, session_capacity}, S};
        true ->
            Token = <<"ns1.", (random())/binary>>,
            TTL = nosternity_config:get(auth_session_ttl_seconds),
            Session = (maps:with([account_id, provider, subject], A))#{
                expires_at => erlang:system_time(second) + TTL, until => now_ms() + TTL * 1000
            },
            {reply, {ok, Token, maps:remove(until, Session)}, S#{
                sessions := Ss#{digest(Token) => Session}
            }}
    end.
session(<<"ns1.", _Tail:64/binary>> = Token, S) ->
    case maps:find(digest(Token), maps:get(sessions, S)) of
        {ok, Session} -> {ok, maps:remove(until, Session)};
        error -> {error, unauthorized}
    end;
session(_, _) ->
    {error, unauthorized}.
stored_account(Id) ->
    case dets:lookup(?MODULE, Id) of
        [{Id, A}] -> {ok, A};
        [] -> {error, not_found}
    end.
save_account(Id, A) ->
    case dets:insert(?MODULE, {Id, A}) of
        ok ->
            case dets:sync(?MODULE) of
                ok -> {ok, A};
                _ -> {error, account_store_unavailable}
            end;
        _ ->
            {error, account_store_unavailable}
    end.
bound_challenge(Id, Provider, Origin, Binding, S) when
    is_binary(Binding), byte_size(Binding) =:= 64
->
    Hash = digest(Binding),
    case maps:find(Id, maps:get(challenges, S)) of
        {ok, #{provider := Provider, origin := Origin, binding := Hash} = C} -> {ok, C};
        _ -> {error, invalid_challenge}
    end;
bound_challenge(_, _, _, _, _) ->
    {error, invalid_challenge}.
remove_challenge(Id, S) -> S#{challenges := maps:remove(Id, maps:get(challenges, S))}.
ln_action(<<"signup">>) -> <<"register">>;
ln_action(<<"login">>) -> <<"login">>.
defaults() ->
    #{
        <<"spam">> => true,
        <<"duplicates">> => true,
        <<"muted">> => [],
        <<"words">> => [],
        <<"bookmarks">> => []
    }.
valid_preferences(P) when is_map(P), map_size(P) =:= 5 ->
    try
        true = is_boolean(maps:get(<<"spam">>, P)),
        true = is_boolean(maps:get(<<"duplicates">>, P)),
        true = hex_list(maps:get(<<"muted">>, P), 200),
        true = hex_list(maps:get(<<"bookmarks">>, P), 100),
        Words = maps:get(<<"words">>, P),
        true = is_list(Words) andalso length(Words) =< 50,
        lists:all(
            fun(W) ->
                is_binary(W) andalso byte_size(W) > 0 andalso byte_size(W) =< 100 andalso
                    is_binary(unicode:characters_to_binary(W, utf8, utf8))
            end,
            Words
        )
    catch
        _:_ -> false
    end;
valid_preferences(_) ->
    false.
hex_list(L, Max) when is_list(L), length(L) =< Max ->
    lists:all(
        fun(V) ->
            is_binary(V) andalso byte_size(V) =:= 64 andalso
                re:run(V, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match
        end,
        L
    );
hex_list(_, _) ->
    false.
random() -> nosternity_auth_proof:hex(crypto:strong_rand_bytes(32)).
digest(B) -> crypto:hash(sha256, B).
now_ms() -> erlang:monotonic_time(millisecond).
prune(S) ->
    Now = now_ms(),
    S#{
        challenges := maps:filter(
            fun(_, V) -> maps:get(until, V) > Now end, maps:get(challenges, S)
        ),
        sessions := maps:filter(fun(_, V) -> maps:get(until, V) > Now end, maps:get(sessions, S)),
        attempts := maps:filter(fun(_, {_, U}) -> U > Now end, maps:get(attempts, S))
    }.
handle_cast({observe, Kind, Millis, Hidden}, S) when
    is_integer(Millis), Millis >= 0, is_integer(Hidden), Hidden >= 0
->
    M = maps:get(metrics, S),
    Search =
        case Kind of
            search -> 1;
            _ -> 0
        end,
    {noreply, S#{
        metrics := M#{
            requests := maps:get(requests, M) + 1,
            searches := maps:get(searches, M) + Search,
            hidden := maps:get(hidden, M) + Hidden,
            duration_ms := maps:get(duration_ms, M) + Millis
        }
    }};
handle_cast(_, S) ->
    {noreply, S}.
handle_info(prune, S) ->
    erlang:send_after(30000, self(), prune),
    {noreply, prune(S)};
handle_info(_, S) ->
    {noreply, S}.
terminate(_, _) -> dets:close(?MODULE).
code_change(_, S, _) -> {ok, S}.
