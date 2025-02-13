-module(kyc_server).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
%% API
-export([
    start_link/0,
    insert_kyc/2,
    get_kyc/1,
    delete_kyc/1,
    change_password/2,
    resolve_wallet/1,
    link_wallet/2,
    store_wallet_password/2,
    check_wallet_password/2,
    resolve_email/1,
    generate_auth_token/1,
    verify_auth_token/2
]).
-export([test/0]).

%% gen_server Callbacks
-export([init/1, handle_call/3, handle_cast/2]).

%% Riak Bucket Names
-define(KYC_BUCKET, <<"kyc_data">>).
-define(WALLET_BUCKET, <<"wallet_data">>).
-define(WALLET_REVERSE_BUCKET, <<"wallet_reverse_data">>).
-define(WALLET_PASSWORD_BUCKET, <<"wallet_passwords">>).
-define(AUTH_TOKEN_BUCKET, <<"auth_tokens">>).

%%% --- Riak Client Setup ---
init(_Args) ->
    {ok, {Host, Port}} = application:get_env(damage, riak),
    logger:info("initializing riak cluster ~p:~p", [Host, Port]),
    case
        riakc_pb_socket:start_link(
            Host,
            Port,
            [{keepalive, true}, {auto_reconnect, true}]
        )
    of
        {ok, Pid} ->
            logger:info("connected to riak node ~p ~p", [Host, Port]),
            {ok, #{riak_conn => Pid}};
        Error ->
            logger:info("Riak connection error ~p ~p ~p", [Host, Port, Error]),
            {error, Error}
    end.

%%% --- API Functions ---
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

insert_kyc(ID, KYCData) ->
    gen_server:call(?MODULE, {insert_kyc, ID, KYCData}).

get_kyc(ID) ->
    gen_server:call(?MODULE, {get_kyc, ID}).

delete_kyc(ID) ->
    gen_server:call(?MODULE, {delete_kyc, ID}).

change_password(Email, NewPassword) ->
    gen_server:call(?MODULE, {change_password, Email, NewPassword}).

resolve_wallet(Email) ->
    gen_server:call(?MODULE, {resolve_wallet, Email}).

resolve_email(Wallet) ->
    gen_server:call(?MODULE, {resolve_email, Wallet}).

link_wallet(Email, Wallet) ->
    gen_server:call(?MODULE, {link_wallet, Email, Wallet}).

store_wallet_password(Email, Password) ->
    gen_server:call(?MODULE, {store_wallet_password, Email, Password}).

check_wallet_password(Email, Password) ->
    gen_server:call(?MODULE, {check_wallet_password, Email, Password}).

generate_auth_token(Email) ->
    gen_server:call(?MODULE, {generate_auth_token, Email}).

verify_auth_token(Email, Token) ->
    gen_server:call(?MODULE, {verify_auth_token, Email, Token}).
%%% --- Generate Secure Auth Token ---
generate_secure_token() ->
    base64:encode(crypto:strong_rand_bytes(32)).

%%% --- Generic Conflict Resolution Function ---
resolve_conflict(Siblings) ->
    Sorted = lists:sort(
        fun(A, B) ->
            maps:get(timestamp, binary_to_term(damage_utils:decrypt(A)), 0) >
                maps:get(timestamp, binary_to_term(damage_utils:decrypt(B)), 0)
        end,
        Siblings
    ),
    case Sorted of
        [Latest | _] -> {ok, binary_to_term(damage_utils:decrypt(Latest))};
        _ -> {error, not_found}
    end.

%%% --- Handle Calls ---
handle_call({insert_kyc, ID, Data}, _From, #{riak_conn := Riak} = State) ->
    EncId = damage_utils:encrypt(ID),
    EncData = damage_utils:encrypt(term_to_binary(Data)),
    Obj = riakc_obj:new(?KYC_BUCKET, EncId, EncData),
    case riakc_pb_socket:put(Riak, Obj) of
        ok -> {reply, {ok, ID}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
%% Get KYC Data (Uses Conflict Resolution)
handle_call({get_kyc, ID}, _From, #{riak_conn := Riak} = State) ->
    EncId = damage_utils:encrypt(ID),
    case riakc_pb_socket:get(Riak, ?KYC_BUCKET, EncId) of
        {ok, Obj} ->
            Siblings = riakc_obj:get_values(Obj),
            case resolve_conflict(Siblings) of
                {ok, EncData} ->
                    ?LOG_INFO("Retrieved enc ~p", [EncData]),
                    {reply, {ok, EncData}, State};
                _ ->
                    {reply, {error, not_found}, State}
            end;
        {error, notfound} ->
            {reply, {error, not_found}, State}
    end;
%%% --- DELETE KYC & CLEAN UP ALL DATA ---
handle_call({delete_kyc, ID}, _From, #{riak_conn := Riak} = State) ->
    case riakc_pb_socket:get(Riak, ?KYC_BUCKET, ID) of
        {ok, Obj} ->
            %% Extract Email from KYC Data
            EncData = binary_to_term(riakc_obj:get_value(Obj)),
            case damage_utils:decrypt(EncData) of
                {ok, KYCData} ->
                    Email = maps:get(email, binary_to_term(KYCData), undefined),
                    case Email of
                        undefined ->
                            {reply, {error, email_not_found}, State};
                        _ ->
                            %% Lookup Wallet Address
                            case riakc_pb_socket:get(Riak, ?WALLET_BUCKET, Email) of
                                {ok, WalletObj} ->
                                    Wallet = riakc_obj:get_value(WalletObj);
                                {error, _} ->
                                    Wallet = undefined
                            end,

                            %% Delete All Associated Data
                            riakc_pb_socket:delete(Riak, ?KYC_BUCKET, ID),
                            riakc_pb_socket:delete(Riak, ?WALLET_BUCKET, Email),
                            riakc_pb_socket:delete(Riak, ?WALLET_PASSWORD_BUCKET, Email),

                            %% Delete Reverse Wallet Lookup if Wallet Exists
                            case Wallet of
                                undefined -> ok;
                                _ -> riakc_pb_socket:delete(Riak, ?WALLET_REVERSE_BUCKET, Wallet)
                            end,

                            {reply, ok, State}
                    end;
                {error, _} ->
                    {reply, {error, invalid_decryption}, State}
            end;
        {error, notfound} ->
            {reply, {error, not_found}, State}
    end;
handle_call({link_wallet, Email, Wallet}, _From, #{riak_conn := Riak} = State) ->
    EncEmail = damage_utils:encrypt(Email),
    EncWallet = damage_utils:encrypt(Wallet),
    %% Store Email -> Wallet
    WalletObj = riakc_obj:new(?WALLET_BUCKET, EncEmail, EncWallet),
    %% Store Wallet -> Email (Reverse Lookup)
    ReverseObj = riakc_obj:new(?WALLET_REVERSE_BUCKET, EncWallet, EncEmail),

    case {riakc_pb_socket:put(Riak, WalletObj), riakc_pb_socket:put(Riak, ReverseObj)} of
        {ok, ok} -> {reply, ok, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
%% Resolve Wallet (Uses Conflict Resolution)
handle_call({resolve_wallet, Email}, _From, #{riak_conn := Riak} = State) ->
    EncEmail = damage_utils:encrypt(Email),
    case riakc_pb_socket:get(Riak, ?WALLET_BUCKET, EncEmail) of
        {ok, Obj} ->
            Siblings = riakc_obj:get_values(Obj),
            case resolve_conflict(Siblings) of
                {ok, Wallet} -> {reply, {ok, Wallet}, State};
                _ -> {reply, {error, not_found}, State}
            end;
        {error, notfound} ->
            {reply, {error, not_found}, State}
    end;
handle_call({store_wallet_password, Email, Password}, _From, #{riak_conn := Riak} = State) ->
    EncPass = damage_utils:encrypt(Password),
    Obj = riakc_obj:new(?WALLET_PASSWORD_BUCKET, Email, term_to_binary(EncPass)),
    case riakc_pb_socket:put(Riak, Obj) of
        ok -> {reply, ok, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({check_wallet_password, Email, Password}, _From, #{riak_conn := Riak} = State) ->
    case riakc_pb_socket:get(Riak, ?WALLET_PASSWORD_BUCKET, Email) of
        {ok, Obj} ->
            EncPass = binary_to_term(riakc_obj:get_value(Obj)),
            case damage_utils:decrypt(EncPass) of
                Password -> {reply, {ok, valid}, State};
                _ -> {reply, {error, invalid_password}, State}
            end;
        {error, notfound} ->
            {reply, {error, not_found}, State}
    end;
%% Resolve Email (Uses Conflict Resolution)
handle_call({resolve_email, Wallet}, _From, #{riak_conn := Riak} = State) ->
    case riakc_pb_socket:get(Riak, ?WALLET_REVERSE_BUCKET, Wallet) of
        {ok, Obj} ->
            Siblings = riakc_obj:get_values(Obj),
            case resolve_conflict(Siblings) of
                {ok, Email} -> {reply, {ok, damage_utils:decrypt(Email)}, State};
                _ -> {reply, {error, not_found}, State}
            end;
        {error, notfound} ->
            {reply, {error, not_found}, State}
    end;
%% Generate & Store Auth Token
handle_call({generate_auth_token, Email}, _From, #{riak_conn := Riak} = State) ->
    Token = generate_secure_token(),
    Timestamp = date_util:now_to_seconds(os:timestamp()),
    AuthData = #{token => Token, timestamp => Timestamp},
    Obj = riakc_obj:new(?AUTH_TOKEN_BUCKET, Email, term_to_binary(AuthData)),

    case riakc_pb_socket:put(Riak, Obj) of
        ok -> {reply, {ok, Token}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
%% Verify Auth Token (Uses Conflict Resolution)
handle_call({verify_auth_token, Email, Token}, _From, #{riak_conn := Riak} = State) ->
    case riakc_pb_socket:get(Riak, ?AUTH_TOKEN_BUCKET, Email) of
        {ok, Obj} ->
            Siblings = riakc_obj:get_values(Obj),
            case resolve_conflict(Siblings) of
                {ok, StoredData} ->
                    StoredToken = maps:get(token, StoredData, <<"">>),
                    Timestamp = maps:get(timestamp, StoredData, 0),
                    CurrentTime = calendar:system_time(seconds),

                    if
                        CurrentTime - Timestamp > 86400 ->
                            {reply, {error, expired_token}, State};
                        Token =:= StoredToken ->
                            {reply, {ok, verified}, State};
                        true ->
                            {reply, {error, invalid_token}, State}
                    end;
                _ ->
                    {reply, {error, not_found}, State}
            end;
        {error, notfound} ->
            {reply, {error, not_found}, State}
    end.

handle_cast(Event, State) ->
    ?LOG_DEBUG("unhandled cast : ~p", [Event]),
    {noreply, State}.
test() ->
    ?LOG_INFO("Starting KYC Server Tests...~n"),

    %% Start the server
    case kyc_server:start_link() of
        {ok, _Pid} ->
            ok;
        {error, {already_started, _}} ->
            ok
    end,

    %% Test Data
    Email = <<"alice@example.com">>,
    Wallet = <<"bc1qwallet12345">>,
    KYC_ID = <<"user123">>,
    KYC_Data = #{email => Email, name => <<"Alice">>, dob => <<"2000-01-01">>},
    Password = <<"mysecurepassword">>,
    NewPassword = <<"mynewsecurepassword">>,

    %% Insert KYC Data
    ?LOG_INFO("Testing Insert KYC...~n"),
    {ok, _} = kyc_server:insert_kyc(KYC_ID, KYC_Data),

    %% Retrieve KYC Data
    ?LOG_INFO("Testing Get KYC...~n"),
    {ok, KYC_Data} = kyc_server:get_kyc(KYC_ID),
    ?LOG_INFO("Retrieved KYC: ~p~n", [KYC_Data]),

    %% Store Wallet Password
    ?LOG_INFO("Testing Store Wallet Password...~n"),
    ok = kyc_server:store_wallet_password(Email, Password),

    %% Check Wallet Password
    ?LOG_INFO("Testing Check Wallet Password (Valid)...~n"),
    {ok, valid} = kyc_server:check_wallet_password(Email, Password),

    ?LOG_INFO("Testing Check Wallet Password (Invalid)...~n"),
    {error, invalid_password} = kyc_server:check_wallet_password(Email, <<"wrongpassword">>),

    %% Link Wallet
    ?LOG_INFO("Testing Link Wallet...~n"),
    ok = kyc_server:link_wallet(Email, Wallet),

    %% Resolve Wallet from Email
    ?LOG_INFO("Testing Resolve Wallet from Email...~n"),
    {ok, Wallet} = kyc_server:resolve_wallet(Email),

    %% Resolve Email from Wallet
    ?LOG_INFO("Testing Resolve Email from Wallet...~n"),
    {ok, Email} = kyc_server:resolve_email(Wallet),

    %% Change Password
    ?LOG_INFO("Testing Change Password...~n"),
    ok = kyc_server:change_password(Email, NewPassword),

    %% Ensure Old Password is Invalid
    ?LOG_INFO("Testing Old Password is Invalid After Change...~n"),
    {error, invalid_password} = kyc_server:check_wallet_password(Email, Password),

    %% Ensure New Password is Valid
    ?LOG_INFO("Testing New Password is Valid...~n"),
    {ok, valid} = kyc_server:check_wallet_password(Email, NewPassword),

    %% Delete KYC (Must remove all related data)
    ?LOG_INFO("Testing Delete KYC...~n"),
    ok = kyc_server:delete_kyc(KYC_ID),

    %% Ensure KYC Data is Gone
    ?LOG_INFO("Testing Get KYC After Deletion...~n"),
    {error, not_found} = kyc_server:get_kyc(KYC_ID),

    %% Ensure Wallet Mapping is Gone
    ?LOG_INFO("Testing Resolve Wallet After KYC Deletion...~n"),
    {error, not_found} = kyc_server:resolve_wallet(Email),

    %% Ensure Reverse Wallet Lookup is Gone
    ?LOG_INFO("Testing Resolve Email After KYC Deletion...~n"),
    {error, not_found} = kyc_server:resolve_email(Wallet),

    %% Ensure Wallet Password is Gone
    ?LOG_INFO("Testing Check Wallet Password After KYC Deletion...~n"),
    {error, not_found} = kyc_server:check_wallet_password(Email, NewPassword),

    ?LOG_INFO("All Tests Passed!~n"),
    ok.
