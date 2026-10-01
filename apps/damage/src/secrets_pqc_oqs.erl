-module(secrets_pqc_oqs).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-export([keypair/1, encapsulate/2, decapsulate/3]).

-on_load(init/0).

-define(NIF_LIB, "priv/secrets_pqc_oqs_nif").
-define(NIF_LOAD_ERROR_KEY, {?MODULE, nif_load_error}).

init() ->
    SoName =
        case code:priv_dir(damage) of
            {error, bad_name} ->
                ?NIF_LIB;
            PrivDir ->
                filename:join(PrivDir, "secrets_pqc_oqs_nif")
        end,
    %% liboqs is optional in generic/test builds. Keep the Erlang module
    %% loadable when the shared object is absent so callers/tests can detect
    %% backend availability and skip or report a structured runtime error.
    case erlang:load_nif(SoName, 0) of
        ok ->
            _ = persistent_term:erase(?NIF_LOAD_ERROR_KEY),
            ok;
        {error, Reason} ->
            persistent_term:put(?NIF_LOAD_ERROR_KEY, Reason),
            ok
    end.

keypair(ml_kem_768) ->
    nif_keypair(ml_kem_768);
keypair(Kem) ->
    error({unsupported_kem, Kem}).

encapsulate(ml_kem_768, PublicKey) when is_binary(PublicKey) ->
    nif_encapsulate(ml_kem_768, PublicKey);
encapsulate(Kem, _PublicKey) ->
    error({unsupported_kem, Kem}).

decapsulate(ml_kem_768, Ciphertext, PrivateKey) when
    is_binary(Ciphertext), is_binary(PrivateKey)
->
    nif_decapsulate(ml_kem_768, Ciphertext, PrivateKey);
decapsulate(Kem, _Ciphertext, _PrivateKey) ->
    error({unsupported_kem, Kem}).

nif_keypair(_Kem) ->
    erlang:nif_error({pqc_nif_unavailable, nif_load_error()}).

nif_encapsulate(_Kem, _PublicKey) ->
    erlang:nif_error({pqc_nif_unavailable, nif_load_error()}).

nif_decapsulate(_Kem, _Ciphertext, _PrivateKey) ->
    erlang:nif_error({pqc_nif_unavailable, nif_load_error()}).

nif_load_error() ->
    persistent_term:get(?NIF_LOAD_ERROR_KEY, nif_not_loaded).
