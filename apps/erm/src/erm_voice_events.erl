%% Local, bounded UI telemetry. Audio/embeddings never enter this bus.
-module(erm_voice_events).
-behaviour(gen_server).
-export([start_link/0, ensure_started/0, subscribe/0, unsubscribe/0, publish/3,
         snapshot/0, child_spec/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
child_spec() -> #{id => ?MODULE, start => {?MODULE, start_link, []},
                  restart => permanent, shutdown => 5000, type => worker}.
start_link() ->
    case gen_server:start_link({local, ?MODULE}, ?MODULE, [], []) of
        {error, {already_started, P}} -> link(P), {ok, P};
        R -> R
    end.
ensure_started() ->
    case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
        {error, {already_started, P}} -> {ok, P};
        R -> R
    end.
subscribe() -> gen_server:call(?MODULE, {subscribe, self()}).
unsubscribe() -> gen_server:call(?MODULE, {unsubscribe, self()}).
snapshot() -> gen_server:call(?MODULE, snapshot).
publish(Source, Channel, Data) when is_atom(Source), is_map(Data),
                                  (Channel =:= input orelse Channel =:= output orelse Channel =:= work) ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid ->
            case process_info(Pid, message_queue_len) of
                {message_queue_len, N} when N < 256 ->
                    gen_server:cast(Pid, {event, self(), Source, Channel, clean(Data)});
                _ -> ok
            end
    end;
publish(_,_,_) -> ok.
clean(Data) ->
    maps:fold(fun
        (phase, V, A) ->
            case lists:member(V,[idle,ready,listening,muted,processing,synthesizing,speaking,error,stopped]) of
                true -> A#{phase => V}; false -> A end;
        (level, V, A) when is_number(V), V >= 0, V =< 1 -> A#{level => V};
        (speech, V, A) when is_boolean(V) -> A#{speech => V};
        (text, V, A) when is_binary(V) -> A#{text => text(V)};
        (_,_,A) -> A
    end, #{}, Data).
text(B) ->
    case unicode:characters_to_list(B) of
        L when is_list(L) -> unicode:characters_to_binary(lists:sublist(L, 240));
        _ -> <<>>
    end.
init([]) -> {ok, #{seq => 0, states => #{}, subscribers => #{}, producers => #{}}}.
handle_call({subscribe, P}, _, S) ->
    Subs = maps:get(subscribers,S),
    Next = case maps:is_key(P,Subs) of true -> Subs; false -> Subs#{P => monitor(process,P)} end,
    {reply, {ok, maps:get(seq,S), maps:values(maps:get(states,S))}, S#{subscribers => Next}};
handle_call({unsubscribe,P}, _, S) ->
    Subs = maps:get(subscribers,S),
    case maps:find(P,Subs) of {ok,M} -> demonitor(M,[flush]); error -> ok end,
    {reply, ok, S#{subscribers => maps:remove(P,Subs)}};
handle_call(snapshot, _, S) -> {reply, maps:values(maps:get(states,S)), S};
handle_call(_,_,S) -> {reply,{error,badarg},S}.
handle_cast({event,P,Source,Channel,Data}, S) ->
    Producers=maps:get(producers,S),
    Key={P,Source,Channel}, States=maps:get(states,S),
    case (maps:is_key(P,Producers) orelse map_size(Producers) < 64) andalso
         (maps:is_key(Key,States) orelse map_size(States) < 256) of
        false -> {noreply,S};
        true ->
            Ps=case maps:is_key(P,Producers) of true -> Producers; false -> Producers#{P=>monitor(process,P)} end,
            Old=maps:get(Key,States,#{data=>#{}}),
            Now=erlang:monotonic_time(millisecond),
            TextAt=case maps:is_key(text,Data) of true->Now;false->maps:get(text_at,Old,Now) end,
            E=#{key=>Key, producer=>P, source=>Source, channel=>Channel,
                at=>Now, text_at=>TextAt, data=>maps:merge(maps:get(data,Old),Data)},
            {noreply, emit(E, S#{producers=>Ps, states=>States#{Key=>E}})}
    end;
handle_cast(_,S) -> {noreply,S}.
handle_info({'DOWN',_,process,P,_},S) ->
    States=maps:get(states,S),
    Dead=[E || E=#{producer:=Producer} <- maps:values(States),Producer=:=P],
    Next=lists:foldl(fun(E,A)->emit(E#{data=>#{phase=>stopped,level=>0}},A) end,S,Dead),
    {noreply,Next#{states=>maps:filter(fun(_,E)->maps:get(producer,E)=/=P end,States),
                  subscribers=>maps:remove(P,maps:get(subscribers,S)),
                  producers=>maps:remove(P,maps:get(producers,S))}};
handle_info(_,S) -> {noreply,S}.
emit(E,S) ->
    Seq=maps:get(seq,S)+1,
    maps:foreach(fun(P,_)->
        case process_info(P,message_queue_len) of
            {message_queue_len,N} when N < 64 -> P ! {erm_voice_event,Seq,E};
            _ -> ok
        end
    end,maps:get(subscribers,S)),
    S#{seq=>Seq}.
terminate(_,_) -> ok.
code_change(_,S,_) -> {ok,S}.
