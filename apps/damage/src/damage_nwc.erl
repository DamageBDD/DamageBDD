%% -------------------------------------------------------------------
%% damage_nwc.erl
%%
%% NIP-47 (Nostr Wallet Connect) client.
%%
%% Reuses:
%%   - damage_nostr:nip04_encrypt/3 + nip04_decrypt_content/3
%%   - damage_nostr:construct_event/5 + finalize_event/2
%%   - nostr_pool:publish/3 + nostr_pool:req_one/4
%%
%% Strategy:
%%   1) publish request event (kind 23194)
%%   2) query for response event (kind 23195) filtered by:
%%        authors=[wallet_pubkey], '#p'=[client_pubkey], '#e'=[request_event_id]
%% -------------------------------------------------------------------

-module(damage_nwc).
-author("Steven Joseph <steven@damagebdd.com>").

-copyright("Steven Joseph <steven@damagebdd.com>").

-license("Apache-2.0").
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    stop/1,

    get_info/1,
    get_balance/1,
    pay_invoice/2,
    pay_invoice/3,
    make_invoice/3,

    call/3,
    call/4
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-import(damage_utils, [to_bin/1]).

-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_FANOUT, 3).

-record(state, {
    nwc_uri,
    %% 64 hex, lowercase
    wallet_pubkey_hex,
    %% 64 hex, lowercase
    secret_hex,
    %% 32 bytes
    client_privkey,
    %% 64 hex, lowercase
    client_pubkey_hex,
    %% [binary()]
    relays = [],
    info_cache = undefined
}).

%% -------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------

start_link(NwcUri) ->
    gen_server:start_link(?MODULE, [NwcUri], []).

stop(Pid) ->
    gen_server:call(Pid, stop).

get_info(Pid) ->
    gen_server:call(Pid, get_info, ?DEFAULT_TIMEOUT).

get_balance(Pid) ->
    call(Pid, <<"get_balance">>, #{}).

pay_invoice(Pid, Invoice) ->
    pay_invoice(Pid, Invoice, undefined).

pay_invoice(Pid, Invoice, AmountMsats) ->
    P0 = #{invoice => to_bin(Invoice)},
    Params =
        case AmountMsats of
            undefined -> P0;
            null -> P0;
            <<>> -> P0;
            _ -> maps:put(amount, AmountMsats, P0)
        end,
    call(Pid, <<"pay_invoice">>, Params).

make_invoice(Pid, AmountMsats, Description) ->
    Params = #{amount => AmountMsats, description => to_bin(Description)},
    call(Pid, <<"make_invoice">>, Params).

call(Pid, Method, Params) ->
    call(Pid, Method, Params, ?DEFAULT_TIMEOUT).

call(Pid, Method, Params, Timeout) ->
    gen_server:call(Pid, {nwc_call, to_bin(Method), Params, Timeout}, Timeout + 2000).

%% -------------------------------------------------------------------
%% gen_server
%% -------------------------------------------------------------------

init([NwcUri0]) ->
    try
        Uri = parse_nwc_uri(NwcUri0),
        WalletPub = lower_hex_ascii64(maps:get(wallet_pubkey, Uri)),
        SecretHex = lower_hex_ascii64(maps:get(secret, Uri)),
        ClientPriv = hex_to_bin(SecretHex),
        {ok, ClientPubBin} = nostrlib_schnorr:new_publickey(ClientPriv),
        ClientPubHex = lower_hex(ClientPubBin),
        Relays0 = maps:get(relays, Uri, []),
        Relays = normalize_relays(Relays0),

        %% ensure pool up (best effort)
        _ = nostr_pool:ensure_started(#{relays => Relays}),

        {ok, #state{
            nwc_uri = to_bin(NwcUri0),
            wallet_pubkey_hex = WalletPub,
            secret_hex = SecretHex,
            client_privkey = ClientPriv,
            client_pubkey_hex = ClientPubHex,
            relays = Relays,
            info_cache = undefined
        }}
    catch
        C:R:S ->
            ?LOG_ERROR("damage_nwc init failed ~p:~p ~p", [C, R, S]),
            {stop, {init_failed, R}}
    end.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(get_info, _From, #state{info_cache = Info} = State) when is_map(Info) ->
    {reply, Info, State};
handle_call(get_info, _From, State = #state{wallet_pubkey_hex = WalletPub, relays = Relays}) ->
    %% NWC info is kind 13194 (replaceable) by wallet service pubkey
    Filter = #{kinds => [13194], authors => [WalletPub], limit => 1},
    Res = nostr_pool:req_one(Filter, Relays, 8000, ?DEFAULT_FANOUT),
    Reply =
        case Res of
            {ok, Event} ->
                Content = to_bin(maps:get(<<"content">>, Event, <<>>)),
                Caps = [C || C <- binary:split(Content, <<" ">>, [global]), C =/= <<>>],
                #{event => Event, capabilities => Caps};
            {error, Why} ->
                #{error => Why}
        end,
    {reply, Reply, State#state{info_cache = Reply}};
handle_call(
    {nwc_call, Method, Params, Timeout},
    _From,
    State = #state{
        wallet_pubkey_hex = WalletPub,
        client_privkey = Priv,
        client_pubkey_hex = ClientPub,
        relays = Relays
    }
) ->
    TS = erlang:system_time(seconds),

    %% NWC request JSON: {"method":"...","params":{...}}
    Plain = jsx:encode(#{
        method => Method,
        params => Params
    }),

    case damage_nostr:nip04_encrypt(Plain, Priv, WalletPub) of
        {ok, CipherB64, IvB64} ->
            %% NIP-04 content format: "<ciphertext_b64>?iv=<iv_b64>"
            Content = <<CipherB64/binary, "?iv=", IvB64/binary>>,
            Tags = [[<<"p">>, WalletPub]],

            Event0 = damage_nostr:construct_event(ClientPub, 23194, Content, TS, Tags),
            Event = damage_nostr:finalize_event(Event0, Priv),
            ReqId = maps:get(<<"id">>, Event),

            ok = nostr_pool:publish(Event, Relays, 2000),

            %% Wait for response kind 23195 addressed to us and referencing our request in an 'e' tag
            RespFilter = #{
                kinds => [23195],
                authors => [WalletPub],
                '#p' => [ClientPub],
                '#e' => [ReqId],
                since => TS - 10,
                limit => 1
            },

            RespRes = nostr_pool:req_one(RespFilter, Relays, Timeout, ?DEFAULT_FANOUT),

            Reply =
                case RespRes of
                    {ok, RespEvent} ->
                        handle_response_event(RespEvent, Priv, WalletPub);
                    {error, Why} ->
                        {error, #{
                            code => <<"TIMEOUT_OR_RELAY_ERROR">>,
                            message => to_bin(io_lib:format("~p", [Why]))
                        }}
                end,
            {reply, Reply, State};
        {error, Why} ->
            {reply,
                {error, #{
                    code => <<"ENCRYPT_FAILED">>, message => to_bin(io_lib:format("~p", [Why]))
                }},
                State}
    end;
handle_call(Any, _From, State) ->
    {reply, {error, {unknown_call, Any}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% -------------------------------------------------------------------
%% Response decoding
%% -------------------------------------------------------------------

handle_response_event(RespEvent, Priv, WalletPub) ->
    Content = maps:get(<<"content">>, RespEvent, <<>>),
    case damage_nostr:nip04_decrypt_content(Content, Priv, WalletPub) of
        {ok, PlainJson} ->
            try jsx:decode(PlainJson, [return_maps]) of
                #{<<"error">> := null, <<"result">> := Result} ->
                    {ok, Result};
                #{<<"error">> := Err} when Err =/= null ->
                    {error, Err};
                Other ->
                    {ok, Other}
            catch
                _:E ->
                    {error, #{
                        code => <<"BAD_RESPONSE_JSON">>, message => to_bin(io_lib:format("~p", [E]))
                    }}
            end;
        {error, Why} ->
            {error, #{code => <<"DECRYPT_FAILED">>, message => to_bin(io_lib:format("~p", [Why]))}}
    end.

%% -------------------------------------------------------------------
%% URI parsing
%% -------------------------------------------------------------------

parse_nwc_uri(Uri0) ->
    Uri = to_bin(Uri0),
    <<"nostr+walletconnect://", Rest/binary>> = Uri,
    [WalletPubKeyBin, QueryBin] = binary:split(Rest, <<"?">>),
    Params = damage_nostr:parse_kv_query(QueryBin),
    #{
        wallet_pubkey => WalletPubKeyBin,
        secret => maps:get(<<"secret">>, Params),
        relays => maps:get(<<"relay">>, Params, [])
    }.

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------

hex_to_bin(Hex) ->
    binary:decode_hex(to_bin(Hex)).

lower_hex(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

lower_hex_ascii64(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(Bin))).

normalize_relays(Relays0) ->
    [to_bin(R) || R <- Relays0, R =/= <<>>].
