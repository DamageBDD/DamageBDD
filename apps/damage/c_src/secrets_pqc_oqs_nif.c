#include "erl_nif.h"
#include <string.h>
#include <oqs/oqs.h>

static ERL_NIF_TERM make_error(ErlNifEnv* env, const char* atom) {
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, atom));
}

static int get_kem_from_atom(ErlNifEnv* env, ERL_NIF_TERM term, const char** kem_name) {
    char atom[128];
    if (!enif_get_atom(env, term, atom, sizeof(atom), ERL_NIF_LATIN1)) {
        return 0;
    }

    if (strcmp(atom, "ml_kem_768") == 0) {
        *kem_name = OQS_KEM_alg_ml_kem_768;
        return 1;
    }

    return 0;
}

static ERL_NIF_TERM nif_keypair(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    const char* kem_name = NULL;
    OQS_KEM* kem = NULL;
    uint8_t *pub = NULL, *priv = NULL;
    ERL_NIF_TERM pub_term, priv_term, result;

    if (argc != 1) {
        return enif_make_badarg(env);
    }

    if (!get_kem_from_atom(env, argv[0], &kem_name)) {
        return make_error(env, "unsupported_kem");
    }

    kem = OQS_KEM_new(kem_name);
    if (kem == NULL) {
        return make_error(env, "kem_init_failed");
    }

    pub = enif_make_new_binary(env, kem->length_public_key, &pub_term);
    priv = enif_make_new_binary(env, kem->length_secret_key, &priv_term);

    if (pub == NULL || priv == NULL) {
        if (priv != NULL) {
            OQS_MEM_cleanse(priv, kem->length_secret_key);
        }
        OQS_KEM_free(kem);
        return make_error(env, "alloc_failed");
    }

    if (OQS_KEM_keypair(kem, pub, priv) != OQS_SUCCESS) {
        OQS_MEM_cleanse(priv, kem->length_secret_key);
        OQS_KEM_free(kem);
        return make_error(env, "keypair_failed");
    }

    if (!enif_make_map_from_arrays(
        env,
        (ERL_NIF_TERM[]) {
            enif_make_atom(env, "public_key"),
            enif_make_atom(env, "private_key")
        },
        (ERL_NIF_TERM[]) {
            pub_term,
            priv_term
        },
        2,
        &result
    )) {
        OQS_MEM_cleanse(priv, kem->length_secret_key);
        OQS_KEM_free(kem);
        return make_error(env, "map_failed");
    }

    OQS_KEM_free(kem);
    return result;
}

static ERL_NIF_TERM nif_encapsulate(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    const char* kem_name = NULL;
    OQS_KEM* kem = NULL;
    ErlNifBinary pubkey;
    uint8_t *ct = NULL, *ss = NULL;
    ERL_NIF_TERM ct_term, ss_term, result;

    if (argc != 2) {
        return enif_make_badarg(env);
    }

    if (!get_kem_from_atom(env, argv[0], &kem_name)) {
        return make_error(env, "unsupported_kem");
    }

    if (!enif_inspect_binary(env, argv[1], &pubkey)) {
        return enif_make_badarg(env);
    }

    kem = OQS_KEM_new(kem_name);
    if (kem == NULL) {
        return make_error(env, "kem_init_failed");
    }

    if (pubkey.size != kem->length_public_key) {
        OQS_KEM_free(kem);
        return make_error(env, "invalid_public_key_size");
    }

    ct = enif_make_new_binary(env, kem->length_ciphertext, &ct_term);
    ss = enif_make_new_binary(env, kem->length_shared_secret, &ss_term);

    if (ct == NULL || ss == NULL) {
        if (ss != NULL) {
            OQS_MEM_cleanse(ss, kem->length_shared_secret);
        }
        OQS_KEM_free(kem);
        return make_error(env, "alloc_failed");
    }

    if (OQS_KEM_encaps(kem, ct, ss, pubkey.data) != OQS_SUCCESS) {
        OQS_MEM_cleanse(ss, kem->length_shared_secret);
        OQS_KEM_free(kem);
        return make_error(env, "encapsulate_failed");
    }

    if (!enif_make_map_from_arrays(
        env,
        (ERL_NIF_TERM[]) {
            enif_make_atom(env, "ciphertext"),
            enif_make_atom(env, "shared_secret")
        },
        (ERL_NIF_TERM[]) {
            ct_term,
            ss_term
        },
        2,
        &result
    )) {
        OQS_MEM_cleanse(ss, kem->length_shared_secret);
        OQS_KEM_free(kem);
        return make_error(env, "map_failed");
    }

    OQS_KEM_free(kem);
    return result;
}

static ERL_NIF_TERM nif_decapsulate(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    const char* kem_name = NULL;
    OQS_KEM* kem = NULL;
    ErlNifBinary ciphertext, privkey;
    uint8_t *ss = NULL;
    ERL_NIF_TERM ss_term;

    if (argc != 3) {
        return enif_make_badarg(env);
    }

    if (!get_kem_from_atom(env, argv[0], &kem_name)) {
        return make_error(env, "unsupported_kem");
    }

    if (!enif_inspect_binary(env, argv[1], &ciphertext) ||
        !enif_inspect_binary(env, argv[2], &privkey)) {
        return enif_make_badarg(env);
    }

    kem = OQS_KEM_new(kem_name);
    if (kem == NULL) {
        return make_error(env, "kem_init_failed");
    }

    if (ciphertext.size != kem->length_ciphertext) {
        OQS_KEM_free(kem);
        return make_error(env, "invalid_ciphertext_size");
    }

    if (privkey.size != kem->length_secret_key) {
        OQS_KEM_free(kem);
        return make_error(env, "invalid_private_key_size");
    }

    ss = enif_make_new_binary(env, kem->length_shared_secret, &ss_term);
    if (ss == NULL) {
        OQS_KEM_free(kem);
        return make_error(env, "alloc_failed");
    }

    if (OQS_KEM_decaps(kem, ss, ciphertext.data, privkey.data) != OQS_SUCCESS) {
        OQS_MEM_cleanse(ss, kem->length_shared_secret);
        OQS_KEM_free(kem);
        return make_error(env, "decapsulate_failed");
    }

    OQS_KEM_free(kem);
    return ss_term;
}

static int nif_load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    (void)env;
    (void)priv_data;
    (void)load_info;
    OQS_init();
    /* liboqs state may be shared with other NIFs. Do not call OQS_destroy()
       from an unload callback while another consumer can still be active. */
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"nif_keypair", 1, nif_keypair, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_encapsulate", 2, nif_encapsulate, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_decapsulate", 3, nif_decapsulate, ERL_NIF_DIRTY_JOB_CPU_BOUND}
};

ERL_NIF_INIT(secrets_pqc_oqs, nif_funcs, nif_load, NULL, NULL, NULL)
