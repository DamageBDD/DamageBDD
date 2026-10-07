%% NIP-01 wire transport; /nostr also serves the NIP-11 information document.
-module(nosternity_websocket).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3,
         relay_info/0]).

init(Req, _Opts) ->
    Method=cowboy_req:method(Req),
    case {Method,cowboy_req:header(<<"upgrade">>,Req,<<>>)} of
        {<<"GET">>,<<"websocket">>} ->
            case nosternity_config:get(websocket_enabled) of
                true ->
                    {cowboy_websocket,Req,#{subscriptions=>#{},window=>0,count=>0},
                     #{max_frame_size=>65536,
                       idle_timeout=>nosternity_config:get(websocket_idle_timeout_ms)}};
                false -> {ok,cowboy_req:reply(403,cors(),<<"WebSocket relay disabled">>,Req),#{}}
            end;
        {<<"OPTIONS">>,_} ->
            {ok,cowboy_req:reply(204,cors(),<<>>,Req),#{}};
        {<<"GET">>,_} ->
            H=(cors())#{<<"content-type">>=><<"application/nostr+json">>},
            {ok,cowboy_req:reply(200,H,jsx:encode(relay_info()),Req),#{}};
        _ -> {ok,cowboy_req:reply(405,cors(),<<>>,Req),#{}}
    end.

relay_info() ->
    #{name=><<"Nosternity Search">>,
      description=><<"DamageBDD verified events with ECAI text search. Public text kinds 0, 1, 30023. Single-node bounded storage.">>,
      supported_nips=>[1,9,11,40,50],
      software=><<"https://github.com/DamageBDD/DamageBDD">>,version=><<"0.2.0">>,
      limitation=>#{max_message_length=>65536,
                    max_subscriptions=>nosternity_config:get(max_subscriptions),
                    max_limit=>nosternity_filter:max_limit(),
                    default_limit=>nosternity_filter:default_limit(),
                    max_subid_length=>64,max_event_tags=>256,max_content_length=>16384,
                    created_at_upper_limit=>300,auth_required=>false,
                    restricted_writes=>true,payment_required=>false}}.
cors() -> #{<<"access-control-allow-origin">>=><<"*">>,
            <<"access-control-allow-headers">>=><<"Accept, Content-Type">>,
            <<"access-control-allow-methods">>=><<"GET, OPTIONS">>}.

websocket_init(S) ->
    Ref=monitor(process,nosternity_relay),
    {ok,S#{relay_monitor=>Ref,window=>erlang:monotonic_time(millisecond)}}.
websocket_handle({text,Msg},S0) when byte_size(Msg)=<65536 ->
    {Allowed,S}=quota(S0),
    try jsx:decode(Msg,[return_maps]) of
        M -> case Allowed of true -> dispatch(M,S); false -> rate_limited(M,S) end
    catch
        error:badarg -> reply([<<"NOTICE">>,<<"invalid: malformed JSON">>],S);
        _:_ -> reply([<<"NOTICE">>,<<"error: relay unavailable">>],S)
    end;
websocket_handle({text,_},S) -> {reply,{close,1009,<<"message too large">>},S};
websocket_handle(_,S) -> {ok,S}.

quota(S) ->
    Now=erlang:monotonic_time(millisecond),
    {Window,N}=case Now-maps:get(window,S,Now) >=60000 of
        true -> {Now,1}; false -> {maps:get(window,S,Now),maps:get(count,S,0)+1} end,
    {N=<nosternity_config:get(websocket_messages_per_minute),S#{window=>Window,count=>N}}.

dispatch([<<"EVENT">>,E],S) ->
    Id=case E of #{<<"id">>:=B} when is_binary(B),byte_size(B)=<64 -> B; _ -> <<>> end,
    Result=try nosternity_relay:publish_event(E) catch _:_ -> {error,unavailable} end,
    case Result of
        ok -> reply([<<"OK">>,Id,true,<<>>],S);
        {error,R} -> reply([<<"OK">>,Id,false,event_error(R)],S)
    end;
dispatch([<<"REQ">>,Id|Fs],S) when is_binary(Id) ->
    G=make_ref(),Subs=maps:get(subscriptions,S),
    Result=try nosternity_relay:subscribe(Id,Fs,G) catch _:_ -> {error,unavailable} end,
    case Result of
        {ok,#{results:=Rs}} ->
            Frames=[frame([<<"EVENT">>,Id,nosternity_filter:wire(maps:get(event,R))]) || R<-Rs]
                ++[frame([<<"EOSE">>,Id])],
            {reply,Frames,S#{subscriptions=>Subs#{Id=>G}}};
        {error,R} ->
            %% A rejected replacement REQ closes the previous subscription too.
            safe_unsubscribe(Id),
            reply([<<"CLOSED">>,Id,request_error(R)],S#{subscriptions=>maps:remove(Id,Subs)})
    end;
dispatch([<<"CLOSE">>,Id],S) when is_binary(Id) ->
    safe_unsubscribe(Id),
    {ok,S#{subscriptions=>maps:remove(Id,maps:get(subscriptions,S))}};
dispatch(_,S) -> reply([<<"NOTICE">>,<<"invalid: expected EVENT, REQ or CLOSE">>],S).

rate_limited([<<"CLOSE">>,Id],S) -> dispatch([<<"CLOSE">>,Id],S);
rate_limited([<<"EVENT">>,E],S) ->
    Id=case E of #{<<"id">>:=B} when is_binary(B),byte_size(B)=<64 -> B; _ -> <<>> end,
    reply([<<"OK">>,Id,false,rate_limit_message()],S);
rate_limited([<<"REQ">>,Id|_],S) when is_binary(Id) ->
    safe_unsubscribe(Id),
    reply([<<"CLOSED">>,Id,rate_limit_message()],
          S#{subscriptions=>maps:remove(Id,maps:get(subscriptions,S))});
rate_limited(_,S) -> reply([<<"NOTICE">>,rate_limit_message()],S).

rate_limit_message() ->
    N = nosternity_config:get(websocket_messages_per_minute),
    <<"rate-limited: ", (integer_to_binary(N))/binary, " messages per minute">>.

event_error(invalid_event) -> <<"invalid: malformed event, id or signature">>;
event_error(expired) -> <<"invalid: event expired">>;
event_error(deleted) -> <<"blocked: event was deleted">>;
event_error(superseded) -> <<"invalid: older replaceable event">>;
event_error(capacity) -> <<"rate-limited: relay event capacity reached">>;
event_error(_) -> <<"error: relay unavailable">>.
request_error(subscription_limit) -> <<"restricted: invalid id or subscription limit reached">>;
request_error(invalid_filters) -> <<"invalid: malformed or unsupported filter">>;
request_error(_) -> <<"error: relay unavailable">>.

websocket_info({nosternity_event,Id,G,E},S) ->
    case maps:get(Id,maps:get(subscriptions,S),undefined)=:=G andalso
         not nosternity_filter:expired(E) of
        true -> reply([<<"EVENT">>,Id,nosternity_filter:wire(E)],S);
        false -> {ok,S}
    end;
websocket_info({nosternity_closed,Id,G},S) ->
    Subs=maps:get(subscriptions,S),
    case maps:get(Id,Subs,undefined)=:=G of
        true -> reply([<<"CLOSED">>,Id,<<"error: subscription ended; reconnect">>],
                      S#{subscriptions=>maps:remove(Id,Subs)});
        false -> {ok,S}
    end;
websocket_info({'DOWN',Ref,process,_,_},S=#{relay_monitor:=Ref}) ->
    {reply,{close,1012,<<"relay restarting">>},S};
websocket_info(_,S) -> {ok,S}.
terminate(_,_,_) -> ok. %% Relay monitors the connection process for cleanup.
safe_unsubscribe(Id) ->
    try nosternity_relay:unsubscribe(Id) catch _:_ -> ok end.
frame(M) -> {text,jsx:encode(M)}.
reply(M,S) -> {reply,frame(M),S}.
