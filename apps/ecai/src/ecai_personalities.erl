%% Durable single-writer sales coordinator. All external work is bounded and asynchronous.
%% Persist intent before CLN/mint side effects; authoritative reads reconcile ambiguous replies.
-module(ecai_personalities).
-behaviour(gen_server).
-export([start_link/0, child_specs/0, catalogue/0, create_order/2, list_orders/1,
         get_order/2, reconcile/2, package/2, owned_personalities/1, resolve_personality/2]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
-define(TABLE,ecai_personality_orders).

start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
child_specs() -> [#{id=>?MODULE,start=>{?MODULE,start_link,[]},restart=>permanent,
    shutdown=>10000,type=>worker,modules=>[?MODULE]}].
catalogue() -> call(catalogue).
create_order(Owner,Body) -> call({create,Owner,Body}).
list_orders(Owner) -> call({list,Owner}).
get_order(Owner,Id) -> call({get,Owner,Id}).
reconcile(Owner,Id) -> call({reconcile,Owner,Id}).
package(Owner,Id) -> call({package,Owner,Id}).
%% Conversation entitlements follow the purchasing account, like package downloads.
%% A purchase reference pins the immutable edition, even after catalog changes.
owned_personalities(Owner) when is_binary(Owner),byte_size(Owner)>0 ->
    personality_call({owned_personalities,Owner});
owned_personalities(_) -> {error,invalid_personality}.
%% The built-in personality remains usable without the sales service or a login.
resolve_personality(_Owner,<<"default">>) ->
    {ok,(default_personality())#{system_prompt=><<>>}};
resolve_personality(Owner,<<"purchase:",Id:64/binary>>) when is_binary(Owner),byte_size(Owner)>0 ->
    case re:run(Id,<<"^[0-9a-f]{64}$">>,[{capture,none}]) of
        match -> personality_call({resolve_personality,Owner,Id});
        _ -> {error,invalid_personality}
    end;
resolve_personality(_,_) -> {error,invalid_personality}.
personality_call(Request) ->
    case call(Request) of
        {error,service_unavailable} -> {error,personality_unavailable};
        {error,result_unknown_retry_same_key} -> {error,personality_unavailable};
        Result -> Result
    end.
call(C) -> try gen_server:call(?MODULE,C,10000)
    catch exit:{timeout,_} -> {error,result_unknown_retry_same_key};
          exit:_ -> {error,service_unavailable} end.

init([]) ->
    process_flag(trap_exit,true),
    Dir=case application:get_env(ecai,personality_store_dir) of
        {ok,ConfiguredDir}->ConfiguredDir;
        undefined->filename:join(ecai_paths:runtime_dir(),"personalities") end,
    ok=filelib:ensure_dir(filename:join(Dir,"orders.dets")),
    ok=file:change_mode(Dir,8#700),
    Path=filename:join(Dir,"orders.dets"),
    {ok,T}=dets:open_file(?TABLE,[{file,Path},{type,set},{repair,false}]),
    ok=file:change_mode(Path,8#600),
    self() ! tick,
    {ok,#{table=>T,workers=>#{}}}.

handle_call(catalogue,_From,S) ->
    R=case ecai_personality_catalog:all() of
        {ok,Ps} -> {ok,#{enabled=>true,checkout_enabled=>sales_enabled(),
            items=>[(ecai_personality_catalog:public(P))#{available=>available(P,S)} || P<-Ps]}};
        Error -> Error end,
    {reply,R,S};
handle_call({create,Owner,B},_From,S) ->
    case prepare_order(Owner,B,S) of
        {ok,O,new} ->
            ok=save(O,S),
            {reply,{ok,public(O)},schedule(O,S)};
        {ok,O,existing} -> {reply,{ok,public(O)},schedule(O,S)};
        Error -> {reply,Error,S}
    end;
handle_call({list,Owner},_From,S) ->
    Os=lists:sort(fun(A,B)->maps:get(created_at,A)>maps:get(created_at,B) end,
        [O || O<-orders(S),maps:get(owner,O)=:=Owner]),
    {reply,{ok,#{items=>[public(O) || O<-lists:sublist(Os,100)]}},S};
handle_call({get,Owner,Id},_From,S) ->
    {reply,with_order(Owner,Id,S,fun(O)->{ok,public(O)} end),S};
handle_call({reconcile,Owner,Id},_From,S) ->
    case owned(Owner,Id,S) of
        {ok,O} -> {reply,{ok,public(O)},schedule(O,S)};
        Error -> {reply,Error,S}
    end;
handle_call({package,Owner,Id},_From,S) ->
    R=with_order(Owner,Id,S,fun(O)->case maps:get(status,O) of
        minted -> {ok,#{filename=><<(maps:get(personality_id,O))/binary,"-",
            (maps:get(id,O))/binary,".json">>,content=>maps:get(package_data,O)}};
        _ -> {error,purchase_not_fulfilled}
    end end),
    {reply,R,S};
handle_call({owned_personalities,Owner},_From,S) ->
    Os=lists:sort(fun(A,B)->{maps:get(created_at,A),maps:get(id,A)}>
                              {maps:get(created_at,B),maps:get(id,B)} end,
        [O || O<-orders(S),maps:get(owner,O)=:=Owner,maps:get(status,O)=:=minted]),
    %% Never expose package instructions through the picker endpoint.
    Choices=[maps:remove(system_prompt,P) || O<-Os,{ok,P}<-[resolve_edition(O)]],
    {reply,{ok,#{items=>[default_personality()|Choices]}},S};
handle_call({resolve_personality,Owner,Id},_From,S) ->
    R=case owned(Owner,Id,S) of
        {ok,#{status:=minted}=O} -> resolve_edition(O);
        _ -> {error,personality_not_owned}
    end,
    {reply,R,S};
handle_call(_,_,S) -> {reply,{error,invalid_request},S}.
handle_cast(_,S) -> {noreply,S}.

handle_info(tick,S) ->
    erlang:send_after(2000,self(),tick),
    Os=lists:sort(fun(A,B)->maps:get(next_check_at,A,0)<maps:get(next_check_at,B,0) end,
                  [O || O<-orders(S),active(O),maps:get(next_check_at,O,0)=<now_s()]),
    {noreply,lists:foldl(fun schedule/2,S,Os)};
handle_info({sales_result,Id,Pid,Result},S) ->
    case maps:find(Id,maps:get(workers,S)) of
        {ok,#{pid:=Pid,ref:=Ref,timer:=Timer}} ->
            erlang:demonitor(Ref,[flush]), erlang:cancel_timer(Timer),
            S1=remove_worker(Id,S),
            case lookup(Id,S1) of
                {ok,O} ->
                    O1=apply_result(O,Result), ok=save(O1,S1),
                    {noreply,case Result of
                        invoice_ready->schedule(O1,S1);
                        _->case maps:get(status,O1) of paid->schedule(O1,S1); _->S1 end end};
                _ -> {noreply,S1}
            end;
        _ -> {noreply,S}
    end;
handle_info({sales_timeout,Id,Pid},S) ->
    case maps:find(Id,maps:get(workers,S)) of
        {ok,#{pid:=Pid}} -> exit(Pid,kill), {noreply,S};
        _ -> {noreply,S}
    end;
handle_info({'DOWN',Ref,process,_Pid,_Reason},S) ->
    case [Id || {Id,#{ref:=R}}<-maps:to_list(maps:get(workers,S)),R=:=Ref] of
        [Id] ->
            #{timer:=Timer}=maps:get(Id,maps:get(workers,S)),erlang:cancel_timer(Timer),
            case lookup(Id,S) of
                {ok,O}->ok=save(failed(O,backend_unavailable),S); _->ok end,
            {noreply,remove_worker(Id,S)};
        [] -> {noreply,S}
    end;
handle_info(_,S) -> {noreply,S}.
terminate(_,S) ->
    maps:foreach(fun(_,#{pid:=P,timer:=T})->erlang:cancel_timer(T),exit(P,kill) end,maps:get(workers,S)),
    dets:close(maps:get(table,S)),ok.
code_change(_,S,_) -> {ok,S}.

prepare_order(Owner,B,S) ->
    try
        require(is_binary(Owner) andalso byte_size(Owner)>0,authenticated_account_required),
        require(is_map(B),invalid_request),
        require(lists:sort(maps:keys(B)) =:= [<<"idempotency_key">>,<<"personality_id">>,<<"recipient">>],invalid_request),
        Key=maps:get(<<"idempotency_key">>,B), ProductId=maps:get(<<"personality_id">>,B),
        Recipient=maps:get(<<"recipient">>,B),
        require(is_binary(Key) andalso byte_size(Key)>=16 andalso byte_size(Key)=<128,invalid_idempotency_key),
        require(is_binary(ProductId) andalso is_binary(Recipient),invalid_request),
        Id=hex(crypto:hash(sha256,term_to_binary({ecai_personality_order_v1,Owner,Key}))),
        case lookup(Id,S) of
            {ok,O} ->
                require(maps:get(owner,O)=:=Owner andalso maps:get(personality_id,O)=:=ProductId
                    andalso maps:get(recipient,O)=:=Recipient,idempotency_conflict),
                {ok,O,existing};
            {error,not_found} ->
                require(sales_enabled(),sales_disabled),
                {ok,P}=expect(ecai_personality_catalog:get(ProductId)),
                require(valid_manifest(maps:get(manifest_uri,P)),manifest_not_configured),
                Nft=nft_backend(), Cln=lightning_backend(),
                ok=expect(Nft:validate_recipient(Recipient)),
                LightningConfig=application:get_env(ecai,personality_lightning,#{}),
                NftConfig=application:get_env(ecai,personality_nft,#{}),
                ok=expect(Cln:validate_config(LightningConfig)),
                ok=expect(Nft:validate_config(NftConfig)),
                require(available(P,S)>0,sold_out),
                Existing=orders(S),
                require(length([O || O<-Existing,maps:get(owner,O)=:=Owner])<1000,account_order_limit),
                require(length([O || O<-Existing,maps:get(owner,O)=:=Owner,unpaid(O)])<3,too_many_pending_orders),
                require(length([O || O<-Existing,active(O)])<1000,checkout_busy),
                Now=now_s(),
                require(length([O || O<-Existing,maps:get(owner,O)=:=Owner,
                    maps:get(created_at,O)>Now-3600])<20,rate_limited),
                O=(maps:with([name,version,price_sats,edition_limit,package_data,package_sha256,manifest_uri,license],P))#{
                    id=>Id,owner=>Owner,personality_id=>ProductId,recipient=>Recipient,
                    status=>invoice_pending,label=><<"ecai-personality-",Id/binary>>,
                    created_at=>Now,updated_at=>Now,next_check_at=>0,attempts=>0,
                    invoice_expiry_seconds=>900,
                    lightning_config=>LightningConfig,nft_config=>NftConfig},
                {ok,O,new}
        end
    catch throw:{sales_error,Why}->{error,Why}; _:_->{error,invalid_configuration} end.

schedule(O,S) ->
    Id=maps:get(id,O), W=maps:get(workers,S),
    case active(O) andalso not maps:is_key(Id,W) andalso map_size(W)<4
        andalso maps:get(next_check_at,O,0)=<now_s() of
        false -> S;
        true ->
            O1=case maps:get(status,O) of paid->O#{status=>mint_pending}; _->O end,
            ok=save(O1,S), Parent=self(), Cln=lightning_backend(), Nft=nft_backend(),
            {Pid,Ref}=spawn_opt(fun()->
                Result=try work(O1,Cln,Nft) catch _:_->{error,backend_unavailable} end,
                Parent ! {sales_result,Id,self(),Result}
            end,[link,monitor]),
            Timer=erlang:send_after(45000,self(),{sales_timeout,Id,Pid}),
            S#{workers=>W#{Id=>#{pid=>Pid,ref=>Ref,timer=>Timer}}}
    end.

work(#{status:=invoice_pending}=O,C,N) ->
    %% Recover issued invoices even if mint readiness changed since issuance.
    case C:lookup_invoice(O) of
        {error,invoice_not_found} ->
            case N:ready(O#{id=>maps:get(personality_id,O)}) of
                ok -> case maps:get(issuance_started,O,false) of
                    false->invoice_ready;
                    true->{invoice,C:ensure_invoice(O)} end;
                {error,E} -> issuance_error(O,E);
                _ -> issuance_error(O,nft_unavailable)
            end;
        R -> {invoice,R}
    end;
work(#{status:=pending}=O,C,_) -> {invoice,C:lookup_invoice(O)};
work(#{status:=mint_pending}=O,_,N) ->
    case N:lookup(O) of
        {ok,not_found} -> {mint,N:mint(O)};
        R -> {mint,R}
    end.

issuance_error(O,E) -> case maps:get(issuance_started,O,false) of
    false->{not_issued,E}; true->{error,E} end.

apply_result(O,invoice_ready) ->
    %% Durable issuance intent precedes the first possibly ambiguous CLN create RPC.
    O#{issuance_started=>true,next_check_at=>0,updated_at=>now_s()};
apply_result(O,{invoice,{ok,I}}) when is_map(I) ->
    try
        require(maps:get(label,I)=:=maps:get(label,O),invoice_mismatch),
        require(maps:get(amount_msat,I)=:=maps:get(price_sats,O)*1000,invoice_mismatch),
        Hash=maps:get(payment_hash,I), Bolt=maps:get(bolt11,I),
        require(is_binary(Hash) andalso byte_size(Hash)=:=64,invoice_mismatch),
        require(is_binary(Bolt) andalso byte_size(Bolt)>0 andalso byte_size(Bolt)=<8192,invoice_mismatch),
        require(maps:get(payment_hash,O,Hash)=:=Hash andalso maps:get(bolt11,O,Bolt)=:=Bolt,invoice_mismatch),
        Expires=maps:get(expires_at,I),require(is_integer(Expires) andalso Expires>0,invoice_mismatch),
        Status=case maps:get(status,I) of
            unpaid->pending; expired->expired;
            paid->require(maps:get(amount_received_msat,I,0)>=maps:get(price_sats,O)*1000,underpaid),paid;
            _->throw({sales_error,invalid_invoice_status}) end,
        Clean=maps:without([last_error],O),
        Next=case Status of paid->0; _->now_s()+5 end,
        Clean#{status=>Status,bolt11=>Bolt,payment_hash=>Hash,expires_at=>Expires,
            amount_received_msat=>maps:get(amount_received_msat,I,0),updated_at=>now_s(),next_check_at=>Next,attempts=>0}
    catch throw:{sales_error,E}->failed(O,E); _:_ ->failed(O,invalid_invoice_response) end;
apply_result(O,{mint,{ok,R}}) when is_map(R) ->
    case {maps:get(token_id,R,undefined),maps:get(contract_id,R,undefined)} of
        {Token,Contract} when is_integer(Token),Token>0,is_binary(Contract),byte_size(Contract)>3 ->
            Frozen=maps:get(contract_id,maps:get(nft_config,O),undefined),
            case Contract=:=Frozen of
                true -> maps:merge(maps:without([last_error],O),
                    (maps:with([token_id,contract_id,tx_hash],R))#{status=>minted,updated_at=>now_s(),next_check_at=>0});
                false -> failed(O,contract_mismatch)
            end;
        _ -> failed(O,invalid_mint_receipt)
    end;
apply_result(O,{mint,{pending,R}}) when is_map(R) ->
    maps:merge(O,(maps:with([tx_hash],R))#{status=>mint_pending,next_check_at=>now_s()+10,updated_at=>now_s()});
apply_result(O,{not_issued,E}) ->
    %% Only reached after a trusted lookup found no invoice and no creation call was made.
    (failed(O,E))#{status=>cancelled};
apply_result(O,{_,{error,E}}) -> failed(O,E);
apply_result(O,{error,E}) -> failed(O,E);
apply_result(O,_) -> failed(O,invalid_backend_response).

failed(O,E) ->
    Count=maps:get(attempts,O,0)+1,
    %% Only atom error codes are persisted/exposed, never provider responses or secrets.
    Safe=case is_atom(E) of true->E; false->backend_unavailable end,
    O#{last_error=>Safe,attempts=>Count,updated_at=>now_s(),
       next_check_at=>now_s()+min(300,5*(1 bsl min(Count,6)))}.
active(O) -> lists:member(maps:get(status,O),[invoice_pending,pending,paid,mint_pending]).
unpaid(O) -> lists:member(maps:get(status,O),[invoice_pending,pending]).
available(P,S) ->
    Used=length([O || O<-orders(S),maps:get(personality_id,O)=:=maps:get(id,P),
        maps:get(package_sha256,O)=:=maps:get(package_sha256,P),
        not lists:member(maps:get(status,O),[expired,cancelled])]),
    max(0,maps:get(edition_limit,P)-Used).
orders(S) -> dets:foldl(fun({_Id,O},Acc)->[O|Acc] end,[],maps:get(table,S)).
lookup(Id,S) -> case dets:lookup(maps:get(table,S),Id) of
    [{Id,O}]->{ok,O}; []->{error,not_found} end.
owned(Owner,Id,S) -> case lookup(Id,S) of
    {ok,#{owner:=Owner}=O}->{ok,O}; _->{error,not_found} end.
with_order(Owner,Id,S,F) -> case owned(Owner,Id,S) of {ok,O}->F(O); E->E end.
save(O,S) -> T=maps:get(table,S),ok=dets:insert(T,{maps:get(id,O),O}),ok=dets:sync(T).
remove_worker(Id,S) -> S#{workers=>maps:remove(Id,maps:get(workers,S))}.
public(O) -> maps:with([id,personality_id,name,version,recipient,price_sats,status,bolt11,
    expires_at,created_at,updated_at,token_id,contract_id,tx_hash,package_sha256,manifest_uri,
    license,last_error],O).
default_personality() -> #{ref=><<"default">>,personality_id=><<"default">>,
    name=><<"ECAI default">>,version=><<"built-in">>,package_sha256=><<>>}.
resolve_edition(O) ->
    try
        Bytes=maps:get(package_data,O),
        true=is_binary(Bytes) andalso byte_size(Bytes)>0 andalso byte_size(Bytes)=<262144,
        Digest=maps:get(package_sha256,O),
        true=hex(crypto:hash(sha256,Bytes))=:=Digest,
        Product=maps:get(personality_id,O), Version=maps:get(version,O),
        #{<<"schema">>:=<<"ecai.personality.v1">>,<<"id">>:=Product,
          <<"version">>:=Version,<<"system_prompt">>:=Prompt}=jsx:decode(Bytes,[return_maps]),
        true=is_binary(Prompt) andalso byte_size(Prompt)>0,
        {ok,#{ref=><<"purchase:",(maps:get(id,O))/binary>>,
            personality_id=>Product,name=>maps:get(name,O),version=>Version,
            package_sha256=>Digest,system_prompt=>Prompt}}
    catch _:_ -> {error,personality_unavailable} end.
sales_enabled() -> application:get_env(ecai,personality_sales_enabled,false)=:=true.
lightning_backend() -> application:get_env(ecai,personality_lightning_backend,ecai_personality_cln).
nft_backend() -> application:get_env(ecai,personality_nft_backend,ecai_personality_nft).
now_s() -> erlang:system_time(second).
hex(B) -> list_to_binary(lists:flatten([io_lib:format("~2.16.0b",[X]) || <<X>> <= B])).
valid_manifest(<<"ipfs://",Rest/binary>>) -> byte_size(Rest)>0;
valid_manifest(<<"https://",Rest/binary>>) -> byte_size(Rest)>0;
valid_manifest(_) -> false.
require(true,_) -> ok; require(false,E) -> throw({sales_error,E}).
expect({error,E}) -> throw({sales_error,E}); expect(V) -> V.
