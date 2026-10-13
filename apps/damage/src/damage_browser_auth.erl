%% Revocable, node-local browser sessions. Wallet proof never unlocks custody.
-module(damage_browser_auth).
-behaviour(gen_server).
-export([
    start_link/0,
    challenge/4,
    verify/4,
    issue/3,
    lookup/1,
    revoke/1,
    attempt/1,
    options/0,
    valid_address/1,
    challenge_message/5
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
challenge(Address, Origin, Binding, Peer) -> call({challenge, Address, Origin, Binding, Peer}).
verify(Id, Signature, Origin, Binding) -> call({verify, Id, Signature, Origin, Binding}).
issue(Address, Mode, Email) -> call({issue, Address, Mode, Email}).
lookup(Token) -> call({lookup, Token}).
revoke(Token) -> call({revoke, Token}).
attempt(Peer) -> call({attempt, Peer}).
call(Request) ->
    try
        gen_server:call(?MODULE, Request, 10000)
    catch
        exit:_ -> {error, auth_unavailable}
    end.

options() ->
    C = application:get_env(damage, browser_auth, []),
    #{
        challenge_ttl => positive(challenge_ttl_seconds, C, 180, 600),
        session_ttl => positive(session_ttl_seconds, C, 3600, 86400),
        max_sessions => positive(max_sessions, C, 10000, 100000),
        max_challenges => positive(max_challenges, C, 1000, 10000),
        attempts_per_minute => positive(attempts_per_minute, C, 20, 200),
        network_id => unicode:characters_to_binary(proplists:get_value(network_id, C, "ae_mainnet"))
    }.
positive(K, C, D, Max) ->
    case proplists:get_value(K, C, D) of
        V when is_integer(V), V > 0, V =< Max -> V;
        _ -> D
    end.

init([]) ->
    erlang:send_after(30000, self(), prune),
    {ok, #{challenges => #{}, sessions => #{}, attempts => #{}}}.
handle_call({attempt, Peer}, _From, State0) ->
    State = prune(State0),
    Attempts = maps:get(attempts, State),
    {Count, Until} = maps:get(Peer, Attempts, {0, now_ms() + 60000}),
    Max = maps:get(attempts_per_minute, options()),
    case Count < Max andalso (maps:is_key(Peer, Attempts) orelse map_size(Attempts) < 10000) of
        true -> {reply, ok, State#{attempts := Attempts#{Peer => {Count + 1, Until}}}};
        false -> {reply, {error, rate_limited}, State}
    end;
handle_call({challenge, Address, Origin, Binding, Peer}, _From, State0) ->
    State = prune(State0),
    Cs = maps:get(challenges, State),
    O = options(),
    PeerCount = length([ok || #{peer := P} <- maps:values(Cs), P =:= Peer]),
    case
        valid_address(Address) andalso valid_binding(Binding) andalso
            is_binary(Origin) andalso byte_size(Origin) > 0
    of
        false ->
            {reply, {error, invalid_challenge}, State};
        true when map_size(Cs) >= map_get(max_challenges, O); PeerCount >= 4 ->
            {reply, {error, rate_limited}, State};
        true ->
            Id = random_hex(),
            Expires = erlang:system_time(second) + maps:get(challenge_ttl, O),
            Message = challenge_message(Address, Origin, maps:get(network_id, O), Id, Expires),
            C = #{
                address => Address,
                origin => Origin,
                binding => digest(Binding),
                peer => Peer,
                message => Message,
                until => now_ms() + maps:get(challenge_ttl, O) * 1000
            },
            {reply,
                {ok, #{
                    challenge_id => Id,
                    message => Message,
                    address => Address,
                    network_id => maps:get(network_id, O),
                    expires_at => Expires
                }},
                State#{challenges := Cs#{Id => C}}}
    end;
handle_call({verify, Id, Signature, Origin, Binding}, _From, State0) ->
    State = prune(State0),
    Cs = maps:get(challenges, State),
    case maps:find(Id, Cs) of
        {ok, #{origin := Origin, binding := Hash, address := Address, message := Message}} when
            is_binary(Binding)
        ->
            case digest(Binding) =:= Hash of
                false ->
                    {reply, {error, invalid_challenge}, State};
                true ->
                    %% Atomic single-use consumption, even on a bad signature.
                    S1 = State#{challenges := maps:remove(Id, Cs)},
                    case valid_signature(Signature, Message, Address) of
                        true -> session_reply(Address, wallet, undefined, S1);
                        false -> {reply, {error, invalid_signature}, S1}
                    end
            end;
        _ ->
            {reply, {error, invalid_challenge}, State}
    end;
handle_call({issue, Address, Mode, Email}, _From, State) when Mode =:= custodial ->
    session_reply(Address, Mode, Email, prune(State));
handle_call({lookup, Token}, _From, State0) when is_binary(Token), byte_size(Token) =< 256 ->
    State = prune(State0),
    Reply =
        case maps:find(digest(Token), maps:get(sessions, State)) of
            {ok, Session} -> {ok, maps:without([until], Session)};
            error -> {error, invalid_session}
        end,
    {reply, Reply, State};
handle_call({revoke, Token}, _From, State) when is_binary(Token) ->
    {reply, ok, State#{sessions := maps:remove(digest(Token), maps:get(sessions, State))}};
handle_call(_, _, State) ->
    {reply, {error, bad_request}, State}.

session_reply(Address, Mode, Email, State) ->
    Ss = maps:get(sessions, State),
    O = options(),
    case valid_address(Address) andalso map_size(Ss) < maps:get(max_sessions, O) of
        false ->
            {reply, {error, session_unavailable}, State};
        true ->
            Token = <<"ds1.", (random_hex())/binary>>,
            Session = #{
                address => Address,
                mode => Mode,
                email => Email,
                expires_at => erlang:system_time(second) + maps:get(session_ttl, O),
                until => now_ms() + maps:get(session_ttl, O) * 1000
            },
            {reply, {ok, Token, maps:without([until], Session)}, State#{
                sessions := Ss#{digest(Token) => Session}
            }}
    end.
valid_binding(B) -> is_binary(B) andalso byte_size(B) >= 32 andalso byte_size(B) =< 128.
valid_address(<<"ak_", _/binary>> = A) when byte_size(A) < 100 ->
    try aeser_api_encoder:decode(A) of
        {account_pubkey, Pub} when byte_size(Pub) =:= 32 -> true;
        _ -> false
    catch
        _:_ -> false
    end;
valid_address(_) ->
    false.
valid_signature(Sig, Msg, Address) when is_binary(Sig), byte_size(Sig) =:= 128 ->
    case re:run(Sig, <<"^[0-9a-fA-F]{128}$">>, [{capture, none}]) of
        match ->
            try vanillae:verify_signature(Sig, Msg, Address) of
                {ok, true} -> true;
                _ -> false
            catch
                _:_ -> false
            end;
        nomatch ->
            false
    end;
valid_signature(_, _, _) ->
    false.
challenge_message(Address, Origin, Network, Id, Expires) ->
    iolist_to_binary([
        <<"Sign in to DamageBDD\n\nOrigin: ">>,
        Origin,
        <<"\nAccount: ">>,
        Address,
        <<"\nNetwork: ">>,
        Network,
        <<"\nNonce: ">>,
        Id,
        <<"\nExpires (Unix seconds): ">>,
        integer_to_binary(Expires),
        <<"\n\nThis proves wallet ownership for a browser session only.\n",
            "It does not authorise payments, token transfers, channels, or custody of your keys.">>
    ]).
random_hex() -> string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(32))).
digest(Bin) -> crypto:hash(sha256, Bin).
now_ms() -> erlang:monotonic_time(millisecond).
prune(State) ->
    Now = now_ms(),
    State#{
        challenges := maps:filter(
            fun(_, V) -> maps:get(until, V) > Now end, maps:get(challenges, State)
        ),
        sessions := maps:filter(
            fun(_, V) -> maps:get(until, V) > Now end, maps:get(sessions, State)
        ),
        attempts := maps:filter(fun(_, {_, Until}) -> Until > Now end, maps:get(attempts, State))
    }.
handle_info(prune, State) ->
    erlang:send_after(30000, self(), prune),
    {noreply, prune(State)};
handle_info(_, State) ->
    {noreply, State}.
handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.
