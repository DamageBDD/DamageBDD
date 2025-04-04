-define(PUBLISHED_FEATURES_BUCKET, {<<"Default">>, <<"PublishedFeatures">>}).
-define(RUNRECORDS_BUCKET, {<<"Default">>, <<"RunRecords">>}).
-define(CONTEXT_BUCKET, {<<"Default">>, <<"Contexts">>}).
-define(CHROMEDRIVER, "http://localhost:9515/").

% Accounts ---
-define(MAX_DAMAGE_INVOICE, 5000000).
-define(MIN_DAMAGE_INVOICE, 1000).
-define(INVOICE_BUCKET, {<<"Default">>, <<"Invoices">>}).
-define(USER_BUCKET, {<<"Default">>, <<"Users">>}).
-define(AEACCOUNT_BUCKET, {<<"Default">>, <<"AeAccounts">>}).
-define(CONFIRM_TOKEN_BUCKET, {<<"Default">>, <<"ConfirmTokens">>}).
-define(INVOICES_SINCE, 30).
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

-record(damage_state, {formatters = [], test_state = []}).

-define(AE_TIMEOUT, 136000).
-define(AI_TIMEOUT, 36000).

-define(DAMAGE_TOKEN_CONTRACT,
    "ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk"
).
-define(ACCOUNT_CONTRACT,
    "ct_vd3iN23kabz2qBX5JidDiaahVSQc1x1HRZDFDi4q54ATjsHo3"
).
-define(EMAIL_REGISTRY_CONTRACT,
    "ct_9arW6cnYKGoioHceaJ3v9rBWXpVXYP6VjKD19JEa5FosFGPBo"
).
-define(NPUB_REGISTRY_CONTRACT,
    "ct_qaySvWmzF848xUaHoCm1igJBFkNCgyecwefnyaBq22GLQWnc6"
).
-define(LIGHTNING_REGISTRY_CONTRACT,
    "ct_qaySvWmzF848xUaHoCm1igJBFkNCgyecwefnyaBq22GLQWnc6"
).

-define(CONTEXT_CONTRACT,
    "ct_7rVLDU2eDG4ip7CKnX3Xzd43TnJ9BiYvGaWeEhtL6EVxfGAZQ"
).

-define(WEBHOOKS_CONTRACT,
    "ct_f5LMGRP1p7Vdmp8Y5TXih8bXn8Sx8HLTFMm7gt4dLXDeeuGvS"
).

-define(SCHEDULES_CONTRACT,
    "ct_2ZbBJQsgr4VwTQpumVQ8Dv4VXfCMVgvE5xLcZQRutJ7BZCDKgQ"
).
