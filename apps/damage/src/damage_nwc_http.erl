-module(damage_nwc_http).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2, content_types_provided/2]).
-export([from_json/2, to_json/2, allowed_methods/2, is_authorized/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["NWC"]).

trails() ->
    [
        trails:trail(
            "/api/nwc/mint",
            damage_nwc_http,
            #{action => mint},
            #{
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Mint a Nostr Wallet Connect connection for authenticated user.",
                        produces => ["application/json"]
                    }
            }
        ),
        trails:trail(
            "/api/nwc/revoke",
            damage_nwc_http,
            #{action => revoke},
            #{
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Revoke an NWC connection.",
                        produces => ["application/json"]
                    }
            }
        ),
        trails:trail(
            "/api/nwc/ledger/balance",
            damage_nwc_http,
            #{action => ledger_balance},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/nwc/ledger/credit",
            damage_nwc_http,
            #{action => ledger_credit},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) -> {[<<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

%% --- Auth: reuse Damage token style (Bearer / cookie) similar to damage_http.erl ---
get_access_token(Req) ->
    case cowboy_req:header(?AUTH_HEADER, Req) of
        <<"Bearer ", Token/binary>> ->
            {oauth, Token};
        _ ->
            Cookies = cowboy_req:parse_cookies(Req),
            case lists:keyfind(<<"sessionid">>, 1, Cookies) of
                {<<"sessionid">>, Token} -> {oauth, Token};
                _ -> {error, missing}
            end
    end.

is_authorized(Req, State0) ->
    case get_access_token(Req) of
        {oauth, Token} ->
            case damage_accounts:validate_access_token(Token) of
                {AeAccount, Role} ->
                    {true, Req,
                        maps:merge(State0, #{
                            public_key => AeAccount, role => Role, access_token => Token
                        })};
                _ ->
                    {{false, ?AUTH_HEADER}, Req, State0}
            end;
        _ ->
            {{false, ?AUTH_HEADER}, Req, State0}
    end.

to_json(Req, State) ->
    Body = maps:get(resp_body, State, #{}),
    {jsx:encode(Body), Req, State}.

from_json(Req0, State = #{action := mint}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),

    %% Inputs:
    %%  relays: [string] (optional; default from config)
    %%  max_single_sat, max_total_sat (optional; defaults)
    DefaultRelays = nostr_pool:default_relays(#{}),
    Relays = maps:get(<<"relays">>, Json, DefaultRelays),
    MaxSingleSat = maps:get(<<"max_single_sat">>, Json, 10000),
    MaxTotalSat = maps:get(<<"max_total_sat">>, Json, 100000),
    ExpiresHeight = maps:get(<<"expires_height">>, Json, 0),

    %% Generate client secret (private key) and pubkey
    Secret = crypto:strong_rand_bytes(32),
    SecretHex = lower_hex_hex(Secret),
    {ok, ClientPubBin} = nostrlib_schnorr:new_publickey(Secret),
    ClientPubHex = lower_hex_hex(ClientPubBin),

    %% Register in ledger contract (admin call or contract admin set to this server account)
    %% Assumes config has nwc_ledger_contract_id and source path.
    {LedgerId, LedgerSrc} = nwc_ledger_cfg(),
    MaxSingleMsat = MaxSingleSat * 1000,
    MaxTotalMsat = MaxTotalSat * 1000,

    _ = damage_ae:contract_call(
        LedgerId,
        LedgerSrc,
        "register",
        [
            binary_to_list(ClientPubHex),
            integer_to_list(MaxSingleMsat),
            integer_to_list(MaxTotalMsat),
            integer_to_list(ExpiresHeight)
        ],
        #{}
    ),

    %% Build URI using THIS wallet service pubkey (server's pubkey)
    WalletPubHex = nwc_wallet_pubhex(),
    Relay = pick_first_relay(Relays),
    NwcUri =
        <<
            "nostr+walletconnect://",
            WalletPubHex/binary,
            "?relay=",
            Relay/binary,
            "&secret=",
            SecretHex/binary
        >>,

    Resp = #{
        status => <<"ok">>,
        client_pubkey => ClientPubHex,
        %% only show once
        secret_hex => SecretHex,
        nwc_uri => NwcUri,
        wallet_pubkey => WalletPubHex,
        relay => Relay
    },
    {true, Req, State#{resp_body => Resp}};
from_json(Req0, State = #{action := revoke}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),
    ClientPubHex = maps:get(<<"client_pubkey">>, Json),

    {LedgerId, LedgerSrc} = nwc_ledger_cfg(),
    _ = damage_ae:contract_call(
        LedgerId,
        LedgerSrc,
        "revoke",
        [binary_to_list(ClientPubHex)],
        #{}
    ),

    {true, Req, State#{
        resp_body => #{status => <<"ok">>, revoked => true, client_pubkey => ClientPubHex}
    }};
from_json(Req0, State = #{action := ledger_balance}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),
    ClientPubHex = maps:get(<<"client_pubkey">>, Json),

    {LedgerId, LedgerSrc} = nwc_ledger_cfg(),
    Res = damage_ae:contract_call_dry(
        LedgerId, LedgerSrc, "balance", [binary_to_list(ClientPubHex)], #{}
    ),
    %% adjust extraction based on your middleware response shape
    {true, Req, State#{
        resp_body => #{status => <<"ok">>, client_pubkey => ClientPubHex, result => Res}
    }};
from_json(Req0, State = #{action := ledger_credit, role := Role}) ->
    %% Restrict this endpoint however you like (admin-only recommended)
    case Role of
        <<"admin">> -> ok;
        _ -> throw({forbidden, not_admin})
    end,
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),
    ClientPubHex = maps:get(<<"client_pubkey">>, Json),
    AmountSat = maps:get(<<"amount_sat">>, Json, 0),
    Ref = maps:get(<<"ref">>, Json, <<"">>),
    Meta = maps:get(<<"meta">>, Json, <<"{}">>),

    AmountMsat = AmountSat * 1000,
    {LedgerId, LedgerSrc} = nwc_ledger_cfg(),
    _ = damage_ae:contract_call(
        LedgerId,
        LedgerSrc,
        "credit",
        [
            binary_to_list(ClientPubHex),
            integer_to_list(AmountMsat),
            binary_to_list(Ref),
            binary_to_list(Meta)
        ],
        #{}
    ),

    {true, Req, State#{resp_body => #{status => <<"ok">>, credited_sat => AmountSat}}}.

%% ---------------- helpers ----------------

lower_hex_hex(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

pick_first_relay([]) ->
    %% fallback to your default pool relay
    <<"wss://relay.damus.io">>;
pick_first_relay([R | _]) when is_binary(R) -> R;
pick_first_relay([R | _]) ->
    unicode:characters_to_binary(R).

%% You’ll wire these to your actual config system:
nwc_ledger_cfg() ->
    %% Example: use app env
    {ok, LedgerId} = application:get_env(damage, nwc_ledger_contract_id),
    {ok, LedgerSrc} = application:get_env(damage, nwc_ledger_contract_source),
    {LedgerId, LedgerSrc}.

nwc_wallet_pubhex() ->
    %% If you already have a configured wallet-service keypair in secrets:
    %% return wallet service pubkey hex (64).
    {Pub, _Priv} = secrets:nostr_wallet_keypair(),
    Pub.
