%% A bounded single-node NIP-01/09/11/40/50 search relay.
%% DETS is authoritative; ECAI is a derived index rebuilt after restart.
-module(nosternity_relay).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").
-export([start_link/0, publish_event/1, subscribe/1, subscribe/3, unsubscribe/1,
         get_events/1, search/1, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
publish_event(E) -> gen_server:call(?MODULE,{publish,E},30000).
search(Fs) -> gen_server:call(?MODULE,{search,Fs},30000).
get_events(F) ->
    case search([F]) of
        {ok,#{results := Rs}} -> [maps:get(event,R) || R <- Rs];
        Error -> Error
    end.
%% Compatibility for in-process clients. Live messages use {nosternity_event,...}.
subscribe(F) -> subscribe(<<"internal">>,[F],make_ref()).
subscribe(Id,Fs,Generation) -> gen_server:call(?MODULE,{subscribe,Id,Fs,Generation},30000).
unsubscribe(Id) -> gen_server:call(?MODULE,{unsubscribe,Id}).
status() -> gen_server:call(?MODULE,status).

init([]) ->
    process_flag(trap_exit,true),
    File = application:get_env(nosternity,search_store_file,"data/nosternity/search.dets"),
    ok = filelib:ensure_dir(File),
    {ok,Db} = dets:open_file(nosternity_search_events,[{file,File},{type,set},{repair,true}]),
    S0 = #{db=>Db,events=>#{},addresses=>#{},deleted=>#{},cutoffs=>#{},
           subscribers=>#{},monitors=>#{},hydrated=>false,hydrate_worker=>undefined},
    %% Replay signed deletion requests first, including expired requests: their
    %% tombstones must survive expiry/restart and prevent delayed resurrection.
    Stored = dets:foldl(fun({_Id,E},A) ->
        case nosternity_filter:validate_event(E) of
            {ok,V} -> [V|A]; _ -> error(invalid_persisted_event)
        end end,[],Db),
    Sorted = lists:sort(fun(A,B) -> replay_key(A) < replay_key(B) end,Stored),
    S1 = lists:foldl(fun replay/2,S0,Sorted),
    Ctx = ecai_search:new(),
    maps:foreach(fun(_Id,E) -> index_add(Ctx,E) end,maps:get(events,S1)),
    %% Remove records left by a crash between durable write and cleanup.
    lists:foreach(fun(E) ->
        Id=maps:get(id,E),
        case maps:is_key(Id,maps:get(events,S1)) of
            true -> ok; false -> ok=dets:delete(Db,Id)
        end end,Stored),
    ok=dets:sync(Db),
    self() ! hydrate,
    {ok,S1#{ctx=>Ctx}}.

handle_call({publish,E0},_From,S) ->
    case nosternity_filter:validate_event(E0) of
        {ok,E} ->
            {Reply,S1}=publish(E,true,S), {reply,Reply,S1};
        {error,_} -> {reply,{error,invalid_event},S}
    end;
handle_call({search,Fs},_From,S) -> {reply,query(Fs,S),S};
handle_call({subscribe,Id,Fs,G},{Pid,_},S) ->
    Subs=maps:get(subscribers,S), Key={Pid,Id},
    Count=length([ok || {{P,_},_} <- maps:to_list(Subs), P=:=Pid]),
    Allowed=valid_id(Id) andalso is_reference(G) andalso
        (maps:is_key(Key,Subs) orelse
            (Count < nosternity_config:get(max_subscriptions) andalso
             map_size(Subs) < nosternity_config:get(max_total_subscriptions))),
    case Allowed of
        false -> {reply,{error,subscription_limit},S};
        true -> case query(Fs,S) of
            {ok,R} ->
                Mons=maps:get(monitors,S),
                Mons1=case maps:is_key(Pid,Mons) of
                    true -> Mons; false -> Mons#{Pid=>monitor(process,Pid)} end,
                S1=S#{subscribers=>Subs#{Key=>{G,Fs}},monitors=>Mons1},
                {reply,{ok,R},S1};
            Error -> {reply,Error,remove_subscription(Key,S)}
        end
    end;
handle_call({unsubscribe,Id},{Pid,_},S) -> {reply,ok,remove_subscription({Pid,Id},S)};
handle_call(status,_From,S) ->
    {reply,#{events=>map_size(maps:get(events,S)),index=>ecai_search:size(maps:get(ctx,S)),
             subscriptions=>map_size(maps:get(subscribers,S)),hydrated=>maps:get(hydrated,S),
             max_events=>max_events()},S};
handle_call(_,_,S) -> {reply,{error,invalid_request},S}.

handle_cast({publish,E0},S) ->
    case nosternity_filter:validate_event(E0) of
        {ok,E} -> {_Reply,S1}=publish(E,true,S),{noreply,S1};
        _ -> {noreply,S}
    end;
handle_cast(_,S) -> {noreply,S}.

%% Archive reads run outside the relay process so chain timeouts cannot block
%% Nostr REQ/EVENT or HTTP search. Import through the same validator/policies.
handle_info(hydrate,S=#{hydrate_worker:=undefined}) ->
    case application:get_env(nosternity,ae_event_store_rehydrate,true) of
        true ->
            Parent=self(),
            {Pid,Ref}=spawn_monitor(fun() -> hydrate_loop(Parent,0) end),
            {noreply,S#{hydrate_worker=>{Pid,Ref}}};
        _ -> {noreply,S#{hydrated=>true}}
    end;
handle_info({hydrate_batch,Pid,Events},S=#{hydrate_worker:={Pid,_}}) ->
    S1=lists:foldl(fun(E0,Acc) ->
        case nosternity_filter:validate_event(E0) of
            {ok,E} -> {_,Next}=publish(E,false,Acc),Next;
            _ -> Acc
        end end,S,Events),
    Pid ! hydrate_continue,
    {noreply,S1};
handle_info({hydrate_done,Pid},S=#{hydrate_worker:={Pid,_}}) ->
    {noreply,S#{hydrated=>true}};
handle_info({'DOWN',Ref,process,Pid,_},S=#{hydrate_worker:={Pid,Ref}}) ->
    case maps:get(hydrated,S) of
        true -> ok;
        false -> erlang:send_after(nosternity_config:get(ae_event_store_retry_ms),self(),hydrate)
    end,
    {noreply,S#{hydrate_worker=>undefined}};
handle_info({'DOWN',Ref,process,Pid,_},S) ->
    Mons=maps:get(monitors,S),
    case maps:get(Pid,Mons,undefined) of
        Ref -> {noreply,S#{monitors=>maps:remove(Pid,Mons),
            subscribers=>maps:filter(fun({P,_},_)->P=/=Pid end,maps:get(subscribers,S))}};
        _ -> {noreply,S}
    end;
handle_info(_,S) -> {noreply,S}.
terminate(_,S) ->
    maps:foreach(fun({Pid,Id},{G,_})->Pid ! {nosternity_closed,Id,G} end,maps:get(subscribers,S,#{})),
    case maps:get(hydrate_worker,S,undefined) of
        {Pid,_} -> exit(Pid,shutdown); _ -> ok end,
    dets:close(maps:get(db,S)),ok.
code_change(_,S,_) -> {ok,S}.

publish(E,Archive,S) ->
    Id=maps:get(id,E),
    case decision(E,S) of
        duplicate -> {ok,S};
        {error,R} -> {{error,R},S};
        ephemeral -> {ok,broadcast(E,S)};
        store ->
            %% Ack only after durable acceptance. Deletion request is durable
            %% before target removal; replay completes interrupted operations.
            Db=maps:get(db,S),ok=dets:insert(Db,{Id,E}),ok=dets:sync(Db),
            S0=apply_event(E,S),
            Before=maps:get(events,S),After=maps:get(events,S0),
            maps:foreach(fun(OldId,_) ->
                case maps:is_key(OldId,After) of
                    true -> ok;
                    false -> ok=dets:delete(Db,OldId),
                        ok=ecai_search:remove_record(maps:get(ctx,S),OldId)
                end end,Before),
            index_add(maps:get(ctx,S),E),
            ok=dets:sync(Db),
            case Archive of true -> nosternity_event_store:store(E); false -> ok end,
            {ok,broadcast(E,S0)}
    end.

decision(E,S) ->
    Id=maps:get(id,E),K=maps:get(kind,E),
    case maps:is_key(Id,maps:get(events,S)) of
        true -> duplicate;
        false ->
            case {nosternity_filter:expired(E),deleted(E,S),superseded(E,S)} of
                {true,_,_} -> {error,expired};
                {_,true,_} -> {error,deleted};
                {_,_,true} -> {error,superseded};
                _ when K >= 20000, K < 30000 -> ephemeral;
                _ -> case map_size(maps:get(events,apply_event(E,S))) > max_events() of
                    true -> {error,capacity}; false -> store end
            end
    end.
max_events() -> nosternity_config:get(search_max_events).

replay_key(E) -> {case maps:get(kind,E) of 5 -> 0; _ -> 1 end,
                  maps:get(created_at,E), maps:get(id,E)}.
replay(E,S) ->
    K=maps:get(kind,E),
    case (K>=20000 andalso K<30000) orelse deleted(E,S) orelse superseded(E,S) of
        true -> S;
        false -> apply_event(E,S)
    end.
apply_event(E,S) ->
    Id=maps:get(id,E),
    S1=case nosternity_filter:address(E) of
        undefined -> S;
        A ->
            Addrs=maps:get(addresses,S),
            OldId=maps:get(A,Addrs,undefined),
            S#{events=>maps:remove(OldId,maps:get(events,S)),addresses=>Addrs#{A=>Id}}
    end,
    S2=S1#{events=>(maps:get(events,S1))#{Id=>E}},
    case maps:get(kind,E) of
        5 -> apply_deletion(E,S2);
        _ -> S2
    end.
superseded(E,S) ->
    case maps:get(nosternity_filter:address(E),maps:get(addresses,S),undefined) of
        undefined -> false;
        OldId -> not nosternity_filter:newer(E,maps:get(OldId,maps:get(events,S)))
    end.
deleted(#{kind:=5},_) -> false;
deleted(E,S) ->
    maps:is_key({maps:get(id,E),maps:get(pubkey,E)},maps:get(deleted,S)) orelse
    maps:get(created_at,E) =< maps:get(nosternity_filter:address(E),maps:get(cutoffs,S),-1).
apply_deletion(#{pubkey:=P,created_at:=T,tags:=Tags},S) ->
    S1=lists:foldl(fun
        ([<<"e">>,Id|_],A) when byte_size(Id)=:=64 ->
            A#{deleted=>(maps:get(deleted,A))#{{Id,P}=>true}};
        ([<<"a">>,Addr|_],A) ->
            case binary:split(Addr,<<":">>,[global]) of
                [_K,P|_] ->
                    C=maps:get(cutoffs,A), A#{cutoffs=>C#{Addr=>max(T,maps:get(Addr,C,-1))}};
                _ -> A
            end;
        (_,A) -> A end,S,Tags),
    Events=maps:filter(fun(_,E)->not deleted(E,S1) end,maps:get(events,S1)),
    Addrs=maps:filter(fun(_,Id)->maps:is_key(Id,Events) end,maps:get(addresses,S1)),
    S1#{events=>Events,addresses=>Addrs}.
index_add(Ctx,E) ->
    case nosternity_filter:searchable(E) of
        true -> ok=ecai_search:add_record(Ctx,maps:get(id,E),nosternity_filter:record(E));
        false -> ok
    end.

query(Fs,S) ->
    case nosternity_filter:valid_filters(Fs) of
        {error,_}=Error -> Error;
        {ok,_} ->
            %% Each filter has its own ranked limit; OR union deduplicates ids.
            {Rs,_}=lists:foldl(fun(F,{Acc,Seen}) ->
                lists:foldl(fun(R,{A,D}) ->
                    Id=maps:get(id,maps:get(event,R)),
                    case maps:is_key(Id,D) of
                        true -> {A,D}; false -> {[R|A],D#{Id=>true}} end
                end,{Acc,Seen},query_filter(F,S))
            end,{[],#{}},Fs),
            {ok,#{results=>lists:reverse(Rs),total=>length(Rs)}}
    end.
query_filter(F,S) ->
    Limit=min(maps:get(<<"limit">>,F,nosternity_filter:default_limit()),nosternity_filter:max_limit()),
    case Limit of
        0 -> [];
        _ ->
            Candidates=candidates(F,S),
            Matches=[R || R=#{event:=E} <- Candidates,nosternity_filter:match(E,F)],
            Sorted=lists:sort(fun ranked_before/2,Matches),
            lists:sublist(Sorted,Limit)
    end.
candidates(F,S) ->
    Events=maps:get(events,S),
    case maps:find(<<"search">>,F) of
        {ok,Q} ->
            Text=nosternity_filter:search_text(Q),
            case ecai_tokenizer:tokens(Text) of
                [] -> [#{event=>E,score=>0} || E <- maps:values(Events),nosternity_filter:searchable(E)];
                _ ->
                    %% Retrieve all ECAI hits BEFORE NIP filters/limit. A fixed
                    %% top-k shortlist would lose valid authors/kinds/tag hits.
                    {Hits,_Headers}=ecai_search:search(maps:get(ctx,S),#{text=>Text,prefix=>false},max(1,map_size(Events))),
                    [#{event=>maps:get(Id,Events),score=>relevance(Text,maps:get(Id,Events),Score)} ||
                        #{doc_id:=Id,score:=Score} <- Hits,maps:is_key(Id,Events)]
            end;
        error -> [#{event=>E,score=>0} || E <- maps:values(Events)]
    end.
%% ECAI's directory scorer counts once per field. For free-text Nostr
%% queries, explicitly reward distinct query-term coverage first and retain
%% bounded ECAI rarity relevance within each coverage tier.
relevance(Text,E,Score) ->
    Query=lists:usort(ecai_tokenizer:tokens(Text)),
    Tokens=lists:usort(lists:sublist(ecai_tokenizer:tokens(maps:get(content,E)),256)),
    Coverage=length([T || T <- Query,lists:member(T,Tokens)]),
    Coverage + math:atan(Score)/math:pi() + 0.5.
ranked_before(#{event:=A,score:=X},#{event:=B,score:=Y}) ->
    {-X,-maps:get(created_at,A),maps:get(id,A)} <
    {-Y,-maps:get(created_at,B),maps:get(id,B)}.
valid_id(Id) when is_binary(Id),byte_size(Id)>0,byte_size(Id)=<256 ->
    case unicode:characters_to_list(Id) of L when is_list(L) -> length(L)=<64; _ -> false end;
valid_id(_) -> false.
remove_subscription(Key={Pid,_},S) ->
    Subs=maps:remove(Key,maps:get(subscribers,S)), Mons=maps:get(monitors,S),
    case lists:any(fun({P,_})->P=:=Pid end,maps:keys(Subs)) of
        true -> S#{subscribers=>Subs};
        false ->
            case maps:find(Pid,Mons) of {ok,R}->demonitor(R,[flush]); error->ok end,
            S#{subscribers=>Subs,monitors=>maps:remove(Pid,Mons)}
    end.
broadcast(E,S) ->
    QueueMax = nosternity_config:get(subscriber_queue_max),
    maps:fold(fun(Key={Pid,Id},{G,Fs},Acc) ->
        case lists:any(fun(F)->nosternity_filter:match(E,F) end,Fs) of
            false -> Acc;
            true -> case process_info(Pid,message_queue_len) of
                {message_queue_len,N} when N < QueueMax ->
                    Pid ! {nosternity_event,Id,G,E},Acc;
                _ -> Pid ! {nosternity_closed,Id,G},remove_subscription(Key,Acc)
            end
        end end,S,maps:get(subscribers,S)).

hydrate_loop(Parent,Offset) ->
    PageSize = nosternity_config:get(ae_event_store_hydrate_page_size),
    case nosternity_event_store:get_events(Offset,PageSize) of
        {ok,Events} when is_list(Events) ->
            Parent ! {hydrate_batch,self(),Events},
            receive hydrate_continue -> ok after 30000 -> exit(hydrate_timeout) end,
            case length(Events)<PageSize of
                true -> Parent ! {hydrate_done,self()};
                false -> hydrate_loop(Parent,Offset+length(Events)) end;
        {error,disabled} -> Parent ! {hydrate_done,self()};
        _ -> exit(hydrate_unavailable)
    end.
