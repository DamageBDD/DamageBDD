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

-record(damage_state, {formatters = [], test_state = []}).

-define(AE_TIMEOUT, 36000).
-define(AI_TIMEOUT, 36000).
-define(DAMAGE_USER_WALLET_MINIMUM_BALANCE, 4000).
-define(AE_USER_WALLET_MINIMUM_BALANCE, 1000000000000000000).

-define(DAMAGE_TOKEN_CONTRACT,
    "ct_m3Cty31JxWHmJFMGuFCTpedDHuMLCit2Qup57qawmEWmcJnCk"
).
-define(ACCOUNT_CONTRACT,
    "ct_vd3iN23kabz2qBX5JidDiaahVSQc1x1HRZDFDi4q54ATjsHo3"
).
-define(KEYSTORE_CONTRACT,
    "ct_jcNfE8AKQkUMmqU9pLk9XR1LJfkkNx2ZK6bUtYLnTncpHGkED"
).
-define(EMAIL_REGISTRY_CONTRACT,
    "ct_2dSCSX9u87XZKwyU1rmxpV6a7FMN7CYg3satoWu3Qm5bJd9XVr"
).
-define(NPUB_REGISTRY_CONTRACT,
    "ct_qaySvWmzF848xUaHoCm1igJBFkNCgyecwefnyaBq22GLQWnc6"
).
-define(LIGHTNING_REGISTRY_CONTRACT,
    "ct_qaySvWmzF848xUaHoCm1igJBFkNCgyecwefnyaBq22GLQWnc6"
).
