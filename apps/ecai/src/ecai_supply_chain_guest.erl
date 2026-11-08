%% Private ETS storage for bounded anonymous demo sessions. All calls run inside
%% ecai_supply_chain_srv; account identifiers and DETS are never used here.
-module(ecai_supply_chain_guest).
-export([new/1,admit/5,load/2,save/3,prune/1,is_guest/1,ttl_seconds/1]).

new(Options) ->
    #{sessions => ets:new(?MODULE,[set,private]),
      peers => ets:new(ecai_supply_chain_guest_peers,[set,private]),
      ttl_ms => maps:get(guest_ttl_ms,Options,1800000),
      max_sessions => maps:get(max_guests,Options,32),
      max_peers => maps:get(max_guest_peers,Options,1024),
      clock => maps:get(guest_clock,Options,fun() -> erlang:monotonic_time(millisecond) end)}.

ttl_seconds(G) -> max(1,maps:get(ttl_ms,G) div 1000).
is_guest({guest,Id}) when is_binary(Id),byte_size(Id)=:=32 -> true;
is_guest(_) -> false.

%% Token is server-generated, 256 random bits. Only its hash is stored. A missing
%% or expired token can be replaced only by a GET of the workspace root.
admit(G,Token,Peer,Create,Action) ->
    Now=now_ms(G),prune(G),
    %% Use the actual socket peer, not client-supplied forwarding headers.
    PeerKey=crypto:hash(sha256,term_to_binary(Peer)),
    rate_peer(G,PeerKey,Now,cost(Action)),
    case lookup_token(G,Token,Now) of
        {ok,Owner,Entry} ->
            E=charge(Entry,Now,40,2,cost(Action)),
            true=ets:insert(maps:get(sessions,G),{Owner,E#{touched := Now}}),
            {ok,Owner,Token};
        missing when Create ->
            Tab=maps:get(sessions,G),
            require(ets:info(Tab,size)<maps:get(max_sessions,G),guest_capacity),
            %% Session creation costs extra, even when callers drop their cookies.
            rate_peer(G,PeerKey,Now,10),
            NewToken=ecai_supply_chain_util:hex(crypto:strong_rand_bytes(32)),
            Owner={guest,crypto:hash(sha256,NewToken)},
            Entry=#{touched => Now,tokens => 40-cost(Action),refill_at => Now,workspace => undefined},
            true=ets:insert(Tab,{Owner,Entry}),
            {ok,Owner,NewToken};
        missing -> throw({supply_chain,guest_session_expired})
    end.

lookup_token(G,Token,Now) when is_binary(Token),byte_size(Token)=:=64 ->
    Owner={guest,crypto:hash(sha256,Token)},
    case ets:lookup(maps:get(sessions,G),Owner) of
        [{Owner,E}] -> case Now-maps:get(touched,E)<maps:get(ttl_ms,G) of
            true -> {ok,Owner,E};false -> missing end;
        [] -> missing
    end;
lookup_token(_,_,_) -> missing.

load(G,Owner) ->
    case ets:lookup(maps:get(sessions,G),Owner) of
        [{Owner,E}] ->
            require(now_ms(G)-maps:get(touched,E)<maps:get(ttl_ms,G),guest_session_expired),
            maps:get(workspace,E);
        [] -> throw({supply_chain,guest_session_expired})
    end.
save(G,Owner,W) ->
    %% Never resurrect an expired session, including from a late worker result.
    _=load(G,Owner),
    [{Owner,E}]=ets:lookup(maps:get(sessions,G),Owner),
    true=ets:insert(maps:get(sessions,G),{Owner,E#{workspace := W}}),ok.
prune(G) ->
    Now=now_ms(G),Cutoff=Now-maps:get(ttl_ms,G),
    lists:foreach(fun({Owner,E}) ->
        case maps:get(touched,E)=<Cutoff of true -> ets:delete(maps:get(sessions,G),Owner);false -> ok end
    end,ets:tab2list(maps:get(sessions,G))),
    lists:foreach(fun({Key,E}) ->
        case Now-maps:get(refill_at,E)>=60000 of true -> ets:delete(maps:get(peers,G),Key);false -> ok end
    end,ets:tab2list(maps:get(peers,G))),ok.
rate_peer(G,Key,Now,Cost) ->
    Tab=maps:get(peers,G),
    E=case ets:lookup(Tab,Key) of
        [{Key,Existing}] -> Existing;
        [] -> require(ets:info(Tab,size)<maps:get(max_peers,G),guest_rate_limited),
              #{tokens => 120,refill_at => Now}
    end,
    true=ets:insert(Tab,{Key,charge(E,Now,120,4,Cost)}),ok.
charge(E,Now,Max,PerSecond,Cost) ->
    Tokens=min(Max,maps:get(tokens,E)+max(0,Now-maps:get(refill_at,E))*PerSecond/1000),
    require(Tokens>=Cost,guest_rate_limited),
    E#{tokens := Tokens-Cost,refill_at := Now}.
cost(benchmark) -> 12;
cost(reset) -> 6;
cost(plan) -> 6;
cost(_) -> 1.
now_ms(G) -> (maps:get(clock,G))().
require(true,_) -> ok;
require(false,Why) -> throw({supply_chain,Why}).
