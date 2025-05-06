-module(lightning_auth_logic).
-author("Steven Joseph <steven@damagebdd.com>").
-copyright("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-behaviour(gen_server).

%% API
-export([
    start_link/1,
    generate_ln_invoice/1,
    verify_ln_payment/1,
    generate_lnurl_auth_challenge/1,
    verify_lnurl_auth/3
]).
-export([generate_lnurl_auth/2]).
-export([gun_get/1]).

%% gen_server Callbacks
-export([init/1, handle_call/3, handle_cast/2]).
-define(DEFAULT_HTTP_TIMEOUT, 30000).

%%% --- Lightning API Configuration ---
get_ln_node() ->
    % Replace with real LND/CLN node URL
    {ok, Host} = application:get_env(damage, cln_host),
    {ok, Port} = application:get_env(damage, cln_port),
    os:getenv("LIGHTNING_NODE", "http://" ++ Host ++ ":" ++ integer_to_list(Port)).

init([]) ->
    {ok, #{}}.

%%% --- API Functions ---
start_link([]) -> gen_server:start_link(?MODULE, [], []).


generate_ln_invoice(LnAddress) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {generate_ln_invoice, LnAddress}, ?DEFAULT_HTTP_TIMEOUT)
        end
    ).

verify_ln_payment(LnAddress) ->
    gen_server:call(?MODULE, {verify_ln_payment, LnAddress}).

generate_lnurl_auth_challenge(LnAddress) ->
    gen_server:call(?MODULE, {generate_lnurl_auth_challenge, LnAddress}).

response_to_list({StatusCode, Headers, Body}) ->
    [{status_code, StatusCode}, {headers, Headers}, {body, Body}].
gun_await(ConnPid, StreamRef) ->
    case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
        {response, fin, Status, Headers} ->
            response_to_list({Status, Headers, <<"">>});
        {response, nofin, Status, Headers} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            response_to_list({Status, Headers, Body});
        Default ->
            ?LOG_DEBUG(damage_utils:strf("Gun request failed: ~p", [Default])),
            error
    end.

%%% --- Gun HTTP Client Request ---
gun_get(URL) ->
    %% Parse the URL
    URI = uri_string:parse(URL),

    Scheme = maps:get(scheme, URI, <<"https">>),
    Host = maps:get(host, URI),
    Port = maps:get(port, URI, default_port(Scheme)),
    Path = maps:get(path, URI, <<"/">>),

    Config = #{
               connect_timeout => ?DEFAULT_HTTP_TIMEOUT, 
               transport => transport(Scheme),
               tls_opts => [{verify, verify_none}]
              },
    %% Open connection
    {ok, ConnPid} = gun:open(Host, Port, Config),
    ?LOG_DEBUG("Auth Config ~p ~p", [{Host, Port},Config]),
    {ok, OpenResult} = gun:await_up(ConnPid),
    ?LOG_DEBUG("Auth Connection Opened ~p ~p ~p", [Config, OpenResult, Scheme]),

    %% Send request
    StreamRef = gun:get(ConnPid, Path, []),
    ?LOG_DEBUG("Auth Connection ~p ~p ~p", [{Host, Port}, Path, Scheme]),

    %% Receive response
    case gun_await(ConnPid, StreamRef) of
        [
            {status_code, 200},
            {headers, [
                {<<"server">>, _Server},
                {<<"date">>, _Date},
                {<<"content-type">>, _ContentType},
                {<<"content-length">>, _ContentLength},
                {<<"connection">>, _ConnectionType},
                {<<"allow">>, _AllowedMethods}
            ]},
            {body, Message}
        ] ->
            jsx:decode(Message, [return_maps, {labels, atom}]);
        Other ->
            ?LOG_DEBUG("Got other mesage ~p", [Other]),
            Other
    end.

%% Helper to determine default port
default_port("https") -> 443;
default_port(<<"https">>) -> 443;
default_port("http") -> 80;
default_port(<<"http">>) -> 80.

%% Helper to determine gun transport
transport(<<"https">>) -> tls;
transport("https") -> tls;
transport(_) -> tcp.


%% generate_lnurl_auth(Domain, Action) -> {K1Binary, LNURL_bech32}.
-spec generate_lnurl_auth(string(), string()) -> {binary(), string()}.
generate_lnurl_auth(Domain, Action) ->
    K1 = crypto:strong_rand_bytes(32),
    K1Hex = binary_to_hex(K1),
    BaseURL = io_lib:format("https://~s/lnurl-auth?tag=login&k1=~s&action=~s", [Domain, K1Hex, Action]),
    URL = iolist_to_binary(BaseURL),

    {ok, Base5} = bech32:convertbits(URL, 8, 5),
    {ok, Bech32} = bech32:encode("lnurl", Base5, [{format, bech32}]),
    {K1Hex, Bech32}.

binary_to_hex(Bin) ->
    << <<(hex_digit((B bsr 4) band 15)), (hex_digit(B band 15))>> || <<B>> <= Bin >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + (N - 10).


%%% --- LNURL-Auth Signature Verification ---


%%% --- Extract Public Key from LNURL ---
%extract_pubkey_from_lnaddress(LnAddress) ->
%    LNURLInfoURL = "https://" ++ binary_to_list(LnAddress) ++ "/.well-known/lnurlp",
%    case gun_get(LNURLInfoURL) of
%        {ok, #{<<"metadata">> := Metadata}} ->
%            case jsx:decode(Metadata) of
%                #{<<"pubkey">> := PubKey} -> {ok, PubKey};
%                _ -> {error, pubkey_not_found}
%            end;
%        _ ->
%            {error, lnurl_fetch_failed}
%    end.
pad32(Int) when is_integer(Int) ->
    Bin = binary:encode_unsigned(Int),
    pad32(Bin);
pad32(Bin) when is_binary(Bin) ->
    case byte_size(Bin) of
        32 -> Bin;
        N when N < 32 -> <<0:((32 - N) * 8), Bin/binary>>;
        _ -> error
    end.
%% decode_lnurl_signature/1
%% Takes a hex-encoded DER signature and returns a raw 64-byte {ok, RawSig} or {error, Reason}
decode_lnurl_signature(HexSig) when is_binary(HexSig) ->
    try
     {_, R, S} = public_key:der_decode('ECDSA-Sig-Value', binary:decode_hex(HexSig)),
    RPadded = pad32(R),
    SPadded = pad32(S),
    SigRaw = <<RPadded:32/binary, SPadded:32/binary>>,
        {ok, SigRaw}
    catch
        _:Reason -> {error, Reason}
    end.

der_sig_part(P = <<1:1, _/bitstring>>) -> <<0:8, P/binary>>;
der_sig_part(<<0, Rest/binary>>)       -> der_sig_part(Rest);
der_sig_part(P)                        -> P.
ecdsa_to_der_sig(<<R0:32/binary, S0:32/binary>>) ->
    {R1, S1} = {der_sig_part(R0), der_sig_part(S0)},
    {LR, LS} = {byte_size(R1), byte_size(S1)},
    <<16#30, (4 + LR + LS), 16#02, LR, R1/binary, 16#02, LS, S1/binary>>.
%%% --- Verify Signature with Secp256k1 ---
verify_lnurl_auth(K1Hex, SigHex, PubKeyHex) ->
        %% Decode hex strings to binary
         K1 = binary:decode_hex(K1Hex),
         PubKey = binary:decode_hex(PubKeyHex),
         {ok, SigRaw} = decode_lnurl_signature(SigHex),
 Sig = ecdsa_to_der_sig(SigRaw),

        %% Ensure correct sizes
        true = byte_size(K1) =:= 32,
        true = byte_size(PubKey) =:= 33,
        true = byte_size(SigRaw) =:= 64,

        %% Perform verification
                    ?LOG_INFO("verify_lnurl_auth verify (~p,~p,~p)", [K1, SigRaw, PubKey]),
                case crypto:verify(ecdsa, sha256, {digest, K1}, Sig, [PubKey, secp256k1]) of
            true -> {ok, verified, PubKey};
            false -> {error, invalid_signature}
        end.


%%% --- Helper: Convert Hex to Binary ---
%hex_to_binary(Hex) ->
%    binary:decode_hex(Hex).

%%% --- Handle Calls ---

call_payment_callback(CallbackUrl) ->
    ?LOG_DEBUG("call_payment_callback payment callback ~p", [CallbackUrl]),
    case gun_get(CallbackUrl) of
        #{pr := PaymentRequest} ->
                {ok, PaymentRequest};
        Error ->
            ?LOG_ERROR("Calling payment callback ~p", [Error]),
            {error, invoice_fetch_failed}
    end.
fetch_invoice(_LnAddress) ->
    ok.

%% Generate a Lightning Invoice for Lightning Address Authentication
handle_call({generate_ln_invoice, LnAddress}, _From, State) ->
    % 1000 sats for authentication
    Amount = 1000,
    Parts = binary:split(LnAddress, <<"@">>, [global]),
    PaymentRequestURL =
        case Parts of
            [User, Domain] ->
                "https://" ++ binary_to_list(Domain) ++ "/.well-known/lnurlp/" ++
                    binary_to_list(User);
            _ ->
                "https://" ++ binary_to_list(LnAddress) ++ "/.well-known/lnurlp/"
        end,
    ?LOG_DEBUG("generate Auth ~p ~p ", [LnAddress, PaymentRequestURL]),

    case gun_get(PaymentRequestURL) of
        #{
            tag := <<"payRequest">>,
            callback := Callback
        } = _PayCallbackResp ->
            CallbackWithAmount = binary_to_list(Callback) ++ "?amount=" ++ integer_to_list(Amount * 1000),
            {reply, call_payment_callback(CallbackWithAmount), State};
        #{
            <<"callback">> := Callback, <<"minSendable">> := MinSend, <<"maxSendable">> := MaxSend
        } when
            Amount * 1000 >= MinSend andalso Amount * 1000 =< MaxSend
        ->
            CallbackWithAmount = Callback ++ "?amount=" ++ integer_to_list(Amount * 1000),
            ?LOG_DEBUG("CallbackWithAmount LnAuth ~p ", [CallbackWithAmount]),
            {reply, call_payment_callback(CallbackWithAmount), State};
        Fail ->
            ?LOG_ERROR("CallbackWithAmount LnAuth failed ~p ", [Fail]),
            {reply, {error, lnurl_fetch_failed}, State}
    end;
%% Verify Lightning Payment from Lightning Address
handle_call({verify_ln_payment, LnAddress}, _From, State) ->
    case fetch_invoice(LnAddress) of
        {ok, Invoice} ->
            PaymentCheckURL = get_ln_node() ++ "/v1/invoice_status/" ++ binary_to_list(Invoice),

            case gun_get(PaymentCheckURL) of
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
handle_call({generate_lnurl_auth_challenge, _LnAddress}, _From, State) ->
    {reply,
        ok,
        State}.

handle_cast(Event, State) ->
    ?LOG_DEBUG("unhandled cast : ~p", [Event]),
    {noreply, State}.

