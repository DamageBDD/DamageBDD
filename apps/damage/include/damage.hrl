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
-define(DAMAGE_GAS_MULTIPLIER, 2).
-define(DAMAGE_GAS_PRICE_MULTIPLIER, 1).
-define(DAMAGE_FEE_MULTIPLIER, 4).
-define(DAMAGE_GAS_PERBYTE, 20).
-define(DAMAGE_BASE_GAS, 46000).

-record(damage_state, {
    formatters = [] :: [term()],
    test_state = [] :: term()
}).
-type damage_state() :: #damage_state{}.

-define(AE_TIMEOUT, 136000).
-define(AI_TIMEOUT, 36000).

-define(DAMAGE_TOKEN_CONTRACT,
    "ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk"
).
-define(EMAIL_REGISTRY_CONTRACT,
    % staging "ct_9arW6cnYKGoioHceaJ3v9rBWXpVXYP6VjKD19JEa5FosFGPBo"
    "ct_BJi1Lg4JmpPZqY5Pt1JB4PoRiTNphMvkuxTzCk2kNLimKMHvB"
).
-define(NPUB_REGISTRY_CONTRACT,
    "ct_qaySvWmzF848xUaHoCm1igJBFkNCgyecwefnyaBq22GLQWnc6"
).
-define(LIGHTNING_REGISTRY_CONTRACT,
    "ct_qaySvWmzF848xUaHoCm1igJBFkNCgyecwefnyaBq22GLQWnc6"
).

-define(CONTEXT_CONTRACT,
    % staging "ct_7rVLDU2eDG4ip7CKnX3Xzd43TnJ9BiYvGaWeEhtL6EVxfGAZQ"
    "ct_Mz99gAjHDHEGpTJktsjRUXjr2A4FQa38VV57K9qxrsNznpSnt"
).

-define(WEBHOOKS_CONTRACT,
    "ct_XDiXtNguPHqdFkR6q4AhtAWNnSMpvRsxuMVanNZM2EzR7yhZJ"
).

-define(SCHEDULES_CONTRACT,
    "ct_hCcHw4hNAkvbadmVrkCRQJxEqvx825hA4gL3gbf4Kh9hpRrwS"
).
-define(SWAP_OPTIONS_CONTRACT,
    "ct_2T1Zv7DnUgxWxCDWXe4i5649Tyx1uxBeBk7SUymUWpbpABiMhg"
).

-define(MARKETS_CONTRACT,
    "ct_2ZbBJQsgr4VwTQpumVQ8Dv4VXfCMVgvE5xLcZQRutJ7BZCDKgQ"
).
-define(JOB_REGISTRY_CONTRACT,
    "ct_JJGKrTpqtivJCfMGJZo9iWrmKTFyD47ipCiNLtdiqxtnQ3PKQ"
).
-define(NODE_REGISTRY_CONTRACT,
    "ct_KxoBnfbSvhy3c2384VMS2j99YKuqtUihAMSsk6TekjqnZeNEQ"
).
-define(LIGHTNING_SWAP_OPTION_CONTRACT, "ct_aWMwTaxGRxcjbb11NiVYVM4NHWmTAViteE5Gp2ayrrmrZi3ry").
-define(LIGHTNING_SWAP_REGISTRY_CONTRACT, "ct_2uwLnU149TP8wHDYUZx1KmKYbDCXoZCPwLU4RpJz3B4QR81UG5").

-define(AUTH_HEADER, <<"authorization">>).
