-module(erm_pay).
-behaviour(gen_server).

-export([
    start_link/0,
    connect/1,
    disconnect/0,
    status/0,
    subscribe/0,
    unsubscribe/0,
    get_balance/0,
    pay_invoice/2,
    pay_invoice/3,
    pay_invoice_async/2,
    pay_invoice_async/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

connect(NwcUri) ->
    gen_server:call(?SERVER, {connect, to_bin(NwcUri)}).

disconnect() ->
    gen_server:call(?SERVER, disconnect).

status() ->
    gen_server:call(?SERVER, status).

subscribe() ->
    gen_server:call(?SERVER, {subscribe, self()}).

unsubscribe() ->
    gen_server:call(?SERVER, {unsubscribe, self()}).

get_balance() ->
    case gen_server:call(?SERVER, checkout) of
        {ok, Conn, _Policy} ->
            erm_pay_nwc:request(Conn, <<"get_balance">>, #{}, 30000);
        Error ->
            Error
    end.

pay_invoice(Invoice, Metadata) ->
    pay_invoice(Invoice, Metadata, #{}).

pay_invoice(Invoice0, Metadata0, Opts) ->
    Invoice = to_bin(Invoice0),
    Metadata = wire_term(Metadata0),
    case gen_server:call(?SERVER, checkout) of
        {ok, Conn, Policy} ->
            case allowed(Metadata, Policy) of
                ok ->
                    Result = do_pay(Conn, Invoice, Metadata, Opts),
                    gen_server:cast(?SERVER, {payment_finished, make_ref(), Result}),
                    Result;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

pay_invoice_async(Invoice, Metadata) ->
    pay_invoice_async(Invoice, Metadata, #{}).

pay_invoice_async(Invoice0, Metadata0, Opts) ->
    Invoice = to_bin(Invoice0),
    Metadata = wire_term(Metadata0),
    Ref = make_ref(),

    case gen_server:call(?SERVER, checkout) of
        {ok, Conn, Policy} ->
            case allowed(Metadata, Policy) of
                ok ->
                    gen_server:cast(?SERVER, {payment_started, Ref, Metadata}),
                    Parent = ?SERVER,
                    spawn(fun() ->
                        Result = do_pay(Conn, Invoice, Metadata, Opts),
                        gen_server:cast(Parent, {payment_finished, Ref, Result})
                    end),
                    {ok, Ref};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

init([]) ->
    Conn =
        case erm_pay_store:load_conn() of
            {ok, SavedConn} -> SavedConn;
            _ -> undefined
        end,

    Policy =
        #{
            max_auto_pay_msat => app_env(max_auto_pay_msat, 100000),
            require_amount_metadata => app_env(require_amount_metadata, false)
        },

    {ok, #{
        conn => Conn,
        policy => Policy,
        subs => []
    }}.

handle_call({connect, NwcUri}, _From, State) ->
    case validate_nwc_uri(NwcUri) of
        ok ->
            ok = erm_pay_store:save_conn(NwcUri),
            NewState = State#{conn => NwcUri},
            Event = #{type => nwc_connected, uri => redact_uri(NwcUri)},
            broadcast(Event, NewState),
            {reply, {ok, redact_uri(NwcUri)}, NewState};
        Error ->
            {reply, Error, State}
    end;
handle_call(disconnect, _From, State) ->
    ok = erm_pay_store:delete_conn(),
    NewState = State#{conn => undefined},
    broadcast(#{type => nwc_disconnected}, NewState),
    {reply, ok, NewState};
handle_call(status, _From, #{conn := undefined} = State) ->
    {reply, #{connected => false}, State};
handle_call(status, _From, #{conn := Conn, policy := Policy} = State) ->
    {reply,
        #{
            connected => true,
            uri => redact_uri(Conn),
            policy => Policy
        },
        State};
handle_call(checkout, _From, #{conn := undefined} = State) ->
    {reply, {error, not_connected}, State};
handle_call(checkout, _From, #{conn := Conn, policy := Policy} = State) ->
    {reply, {ok, Conn, Policy}, State};
handle_call({subscribe, Pid}, _From, #{subs := Subs} = State) ->
    NewSubs = add_pid(Pid, Subs),
    {reply, ok, State#{subs => NewSubs}};
handle_call({unsubscribe, Pid}, _From, #{subs := Subs} = State) ->
    NewSubs = remove_pid(Pid, Subs),
    {reply, ok, State#{subs => NewSubs}};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({payment_started, Ref, Metadata}, State) ->
    Event = #{
        type => payment_started,
        ref => Ref,
        metadata => Metadata
    },
    broadcast(Event, State),
    {noreply, State};
handle_cast({payment_finished, Ref, {ok, Result}}, State) ->
    Event = #{
        type => payment_paid,
        ref => Ref,
        result => Result
    },
    broadcast(Event, State),
    {noreply, State};
handle_cast({payment_finished, Ref, {error, Reason}}, State) ->
    Event = #{
        type => payment_failed,
        ref => Ref,
        reason => Reason
    },
    broadcast(Event, State),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

do_pay(Conn, Invoice, Metadata, Opts) ->
    Timeout = maps:get(timeout, Opts, 60000),
    Params =
        #{
            <<"invoice">> => Invoice,
            <<"metadata">> => Metadata
        },
    erm_pay_nwc:request(Conn, <<"pay_invoice">>, Params, Timeout).

allowed(Metadata, Policy) ->
    RequireAmount = maps:get(require_amount_metadata, Policy, false),
    MaxMsat = maps:get(max_auto_pay_msat, Policy, 100000),
    Amount = maps:get(<<"amount_msat">>, Metadata, undefined),

    case {RequireAmount, Amount} of
        {true, undefined} ->
            {error, #{code => missing_amount_msat}};
        _ when is_integer(Amount), Amount > MaxMsat ->
            {error, #{
                code => policy_limit_exceeded,
                amount_msat => Amount,
                max_auto_pay_msat => MaxMsat
            }};
        _ ->
            ok
    end.

validate_nwc_uri(<<"nostr+walletconnect://", _/binary>> = Uri) ->
    case {binary:match(Uri, <<"relay=">>), binary:match(Uri, <<"secret=">>)} of
        {nomatch, _} ->
            {error, missing_relay};
        {_, nomatch} ->
            {error, missing_secret};
        _ ->
            ok
    end;
validate_nwc_uri(_) ->
    {error, bad_nwc_uri}.

broadcast(Event, #{subs := Subs}) ->
    LiveSubs = live_pids(Subs, []),
    send_event(LiveSubs, {erm_pay, Event}),
    ok.

send_event([], _Event) ->
    ok;
send_event([Pid | Rest], Event) ->
    Pid ! Event,
    send_event(Rest, Event).

live_pids([], Acc) ->
    reverse(Acc);
live_pids([Pid | Rest], Acc) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> live_pids(Rest, [Pid | Acc]);
        false -> live_pids(Rest, Acc)
    end;
live_pids([_ | Rest], Acc) ->
    live_pids(Rest, Acc).

add_pid(Pid, Subs) ->
    case has_pid(Pid, Subs) of
        true -> Subs;
        false -> [Pid | Subs]
    end.

remove_pid(_Pid, []) ->
    [];
remove_pid(Pid, [Pid | Rest]) ->
    remove_pid(Pid, Rest);
remove_pid(Pid, [Other | Rest]) ->
    [Other | remove_pid(Pid, Rest)].

has_pid(_Pid, []) ->
    false;
has_pid(Pid, [Pid | _]) ->
    true;
has_pid(Pid, [_ | Rest]) ->
    has_pid(Pid, Rest).

reverse(List) ->
    reverse(List, []).

reverse([], Acc) ->
    Acc;
reverse([H | T], Acc) ->
    reverse(T, [H | Acc]).

to_bin(V) when is_binary(V) ->
    V;
to_bin(V) when is_list(V) ->
    unicode:characters_to_binary(V);
to_bin(V) when is_atom(V) ->
    atom_to_binary(V, utf8).

wire_term(Map) when is_map(Map) ->
    maps:from_list(wire_pairs(maps:to_list(Map)));
wire_term(List) when is_list(List) ->
    case io_lib:printable_unicode_list(List) of
        true -> unicode:characters_to_binary(List);
        false -> wire_list(List)
    end;
wire_term(Other) ->
    Other.

wire_pairs([]) ->
    [];
wire_pairs([{K, V} | Rest]) ->
    [{wire_key(K), wire_term(V)} | wire_pairs(Rest)].

wire_list([]) ->
    [];
wire_list([H | T]) ->
    [wire_term(H) | wire_list(T)].

wire_key(K) when is_binary(K) ->
    K;
wire_key(K) when is_atom(K) ->
    atom_to_binary(K, utf8);
wire_key(K) when is_list(K) ->
    unicode:characters_to_binary(K);
wire_key(K) ->
    K.

redact_uri(Uri0) ->
    Uri = to_bin(Uri0),
    case binary:split(Uri, <<"secret=">>) of
        [Before, After] ->
            Tail =
                case binary:split(After, <<"&">>) of
                    [_Secret, Rest] -> <<"&", Rest/binary>>;
                    [_Secret] -> <<>>
                end,
            <<Before/binary, "secret=***", Tail/binary>>;
        _ ->
            Uri
    end.

app_env(Key, Default) ->
    case application:get_env(erm_pay, Key) of
        {ok, V} -> V;
        undefined -> Default
    end.
