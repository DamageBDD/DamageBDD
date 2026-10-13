-define(PUBLISHED_FEATURES_BUCKET, {<<"Default">>, <<"PublishedFeatures">>}).
-define(RUNRECORDS_BUCKET, {<<"Default">>, <<"RunRecords">>}).
-define(CONTEXT_BUCKET, {<<"Default">>, <<"Contexts">>}).
-define(CHROMEDRIVER, "http://localhost:9515/").
-define(DEFAULT_HTTP_TIMEOUT, 60000).

% Accounts ---
-define(MAX_DAMAGE_INVOICE, 5000000).
-define(MIN_DAMAGE_INVOICE, 1000).
-define(DAMAGE_USER_WALLET_MINIMUM_BALANCE, 4000).
-define(AE_USER_WALLET_MINIMUM_BALANCE, 1000000000000000000).
-define(DAMAGE_INITIAL_HITS, 10000000000).
-define(AE_INITIAL_AETTOS, 100000).

% Ai ---
-define(DAMAGE_AI_FEE, 10).
-define(DEFAULT_TIMEOUT, 60000).

% Domains ---
-define(DOMAIN_TOKEN_BUCKET, {<<"Default">>, <<"DomainTokens">>}).

% Reporting ---
-define(RESULT_STATUS_PREFIX_SUCCESS, "9").
-define(RESULT_STATUS_PREFIX_FAIL, "7").
-define(DAMAGE_PRICE, 100).
-define(DAMAGE_DECIMALS, 8).
-define(AE_DECIMALS, 18).

% Infra Fees
% multipliers to pedal the fees and gas usage starting from the default of vanillae
-define(GAS_MULTIPLIER, 8).
-define(GAS_PRICE_MULTIPLIER, 16).
-define(FEE_MULTIPLIER, 10).
-define(CONTRACT_CALL_GAS_MULTIPLIER, 48).
-define(CONTRACT_CALL_GAS_FLOOR, 70000).
-define(CONTRACT_CALL_GAS_BUFFER_PCT, 20).

-record(damage_state, {
    formatters = [] :: [term()],
    test_state = [] :: term()
}).
-type damage_state() :: #damage_state{}.

-define(AE_TIMEOUT, 1360000).
-define(AI_TIMEOUT, 36000).

-define(DAMAGE_TOKEN_CONTRACT,
    "ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk"
).

-define(AUTH_HEADER, <<"authorization">>).
