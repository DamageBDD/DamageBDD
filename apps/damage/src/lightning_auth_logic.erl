-module(lightning_auth_logic).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

%% API
-export([
    start_link/0,
    generate_ln_invoice/1,
    verify_ln_payment/1,
    generate_lnurl_auth_challenge/1,
    verify_lnurl_auth/2
]).
-export([verify_signature/3]).

%% gen_server Callbacks
-export([init/1, handle_call/3, handle_cast/2]).


%%% --- Lightning API Configuration ---
get_ln_node() ->
    % Replace with real LND/CLN node URL
    {ok, Host} = application:get_env(damage, cln_host),
    {ok, Port} = application:get_env(damage, cln_port),
    os:getenv("LIGHTNING_NODE", "http://" ++ Host ++ ":" ++ integer_to_list(Port)).

init([]) ->
    {ok, #{}}.

%%% --- API Functions ---
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

generate_ln_invoice(LnAddress) ->
    gen_server:call(?MODULE, {generate_ln_invoice, LnAddress}).

verify_ln_payment(LnAddress) ->
    gen_server:call(?MODULE, {verify_ln_payment, LnAddress}).

generate_lnurl_auth_challenge(LnAddress) ->
    gen_server:call(?MODULE, {generate_lnurl_auth_challenge, LnAddress}).

verify_lnurl_auth(LnAddress, Signature) ->
    gen_server:call(?MODULE, {verify_lnurl_auth, LnAddress, Signature}).

%%% --- Gun HTTP Client Request ---
gun_request(Method, URL, Body) ->
    % Adjust for external APIs
    {ok, ConnPid} = gun:open("localhost", 8080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:request(ConnPid, Method, URL, [], Body),
    receive
        {gun_response, ConnPid, StreamRef, fin, Status, Headers} ->
            {ok, Status, Headers, <<>>};
        {gun_data, ConnPid, StreamRef, fin, BodyData} ->
            {ok, jsx:decode(BodyData)}
    after 5000 ->
        {error, timeout}
    end.
%%% --- LNURL-Auth Signature Verification ---
verify_signature(LnAddress, Challenge, Signature) ->
    case extract_pubkey_from_lnaddress(LnAddress) of
        {ok, PubKey} ->
            verify_secp256k1_signature(PubKey, Challenge, Signature);
        {error, Reason} ->
            {error, Reason}
    end.

%%% --- Extract Public Key from LNURL ---
extract_pubkey_from_lnaddress(LnAddress) ->
    LNURLInfoURL = "https://" ++ binary_to_list(LnAddress) ++ "/.well-known/lnurlp",
    case gun_request(get, LNURLInfoURL, <<>>) of
        {ok, #{<<"metadata">> := Metadata}} ->
            case jsx:decode(Metadata) of
                #{<<"pubkey">> := PubKey} -> {ok, PubKey};
                _ -> {error, pubkey_not_found}
            end;
        _ ->
            {error, lnurl_fetch_failed}
    end.

%%% --- Verify Signature with Secp256k1 ---
verify_secp256k1_signature(PubKey, Challenge, Signature) ->
    case
        libsecp256k1:verify(
            hex_to_binary(Signature), hex_to_binary(Challenge), hex_to_binary(PubKey)
        )
    of
        true -> {ok, verified};
        false -> {error, invalid_signature}
    end.

%%% --- Helper: Convert Hex to Binary ---
hex_to_binary(Hex) ->
    binary:decode_hex(Hex).

%%% --- Handle Calls ---
register_auth_invoice(LnAddress, Invoice) ->
    ?LOG_DEBUG("Address ~p Invoice ~p", [LnAddress, Invoice]),
    {ok, Result} = damage_ae:contract_call("lnauth.aes", "register_auth_invoice", [LnAddress,Invoice]),
    {ok, Result}.
fetch_auth_invoice(LnAddress) ->
    ?LOG_DEBUG("Address ~p ", [LnAddress]),
    %TODO
    {ok, Result} = damage_ae:contract_call("lnauth.aes", "fetch_auth_invoice", [LnAddress]),
    {ok, Result}.
store_auth_challenge(LnAddress) ->
    Challenge = base64:encode(crypto:strong_rand_bytes(32)),
    Timestamp = calendar:system_time(seconds),
    ok = damage_ae:contract_call("lnauth.aes", "store_auth_challenge", [LnAddress, Challenge, Timestamp]),
    {ok, Challenge}.
fetch_auth_challenge(LnAddress) ->
    ?LOG_DEBUG("Address ~p ", [LnAddress]),
    %TODO
    {ok, Result} = damage_ae:contract_call("lnauth.aes", "fetch_auth_challenge", [LnAddress]),
    {ok, Result}.
    
    
%% Generate a Lightning Invoice for Lightning Address Authentication
handle_call({generate_ln_invoice, LnAddress}, _From,  State) ->
    % 1000 sats for authentication
    Amount = 1000,
    PaymentRequestURL = "https://" ++ binary_to_list(LnAddress) ++ "/.well-known/lnurlp",

    case gun_request(get, PaymentRequestURL, <<>>) of
        {ok, #{
            <<"callback">> := Callback, <<"minSendable">> := MinSend, <<"maxSendable">> := MaxSend
        }} when
            Amount * 1000 >= MinSend andalso Amount * 1000 =< MaxSend
        ->
            CallbackWithAmount = Callback ++ "?amount=" ++ integer_to_list(Amount * 1000),
            case gun_request(get, CallbackWithAmount, <<>>) of
                {ok, #{<<"pr">> := Invoice, <<"successAction">> := _}} ->
                    case
                        register_auth_invoice(
                            LnAddress,
                            Invoice
                        )
                    of
                        ok -> {reply, {ok, Invoice}, State};
                        {error, Reason} -> {reply, {error, Reason}, State}
                    end;
                _ ->
                    {reply, {error, invoice_fetch_failed}, State}
            end;
        _ ->
            {reply, {error, lnurl_fetch_failed}, State}
    end;
%% Verify Lightning Payment from Lightning Address
handle_call({verify_ln_payment, LnAddress}, _From, State) ->
    case fetch_auth_invoice(LnAddress) of
        {ok, Invoice} ->
            PaymentCheckURL = get_ln_node() ++ "/v1/invoice_status/" ++ binary_to_list(Invoice),

            case gun_request(get, PaymentCheckURL, <<>>) of
                {ok, #{<<"status">> := <<"paid">>}} ->
                    io:format("Payment confirmed for Lightning Address: ~s~n", [LnAddress]),
                    {reply, {ok, verified}, State};
                _ ->
                    {reply, {error, unpaid}, State}
            end;
        {error, notfound} ->
            {reply, {error, not_found}, State}
    end;
%% Generate LNURL-Auth Challenge
handle_call({generate_lnurl_auth_challenge, LnAddress}, _From, State) ->

    {reply, 
        store_auth_challenge(
            LnAddress
        ), State};
handle_call({verify_lnurl_auth, LnAddress, Signature}, _From, State) ->
    case fetch_auth_challenge(LnAddress) of
        {ok, {Challenge, Timestamp}} ->
            CurrentTime = calendar:system_time(seconds),

            if
                % Challenge expires after 10 minutes
                CurrentTime - Timestamp > 600 ->
                    {reply, {error, expired_challenge}, State};
                true ->
                    case verify_signature(LnAddress, Challenge, Signature) of
                        {ok, verified} -> {reply, {ok, verified}, State};
                        {error, Reason} -> {reply, {error, Reason}, State}
                    end
            end;
        {error, notfound} ->
            {reply, {error, not_found}, State}
    end.

handle_cast(Event, State) ->
    ?LOG_DEBUG("unhandled cast : ~p", [Event]),
    {noreply, State}.
