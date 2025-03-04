#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <gmp.h>
#include <openssl/sha.h>
#include "erl_nif.h"

// Define secp256k1 parameters
const char *P_STR = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F";

typedef struct {
    mpz_t x, y;
} ECPoint;

static ERL_NIF_TERM hash_to_point_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) {
        return enif_make_badarg(env);
    }

    char knowledge[256];
    if (!enif_get_string(env, argv[0], knowledge, sizeof(knowledge), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }

    unsigned char hash[SHA256_DIGEST_LENGTH];
    SHA256((unsigned char *)knowledge, strlen(knowledge), hash);

    mpz_t x;
    mpz_init(x);
    mpz_import(x, SHA256_DIGEST_LENGTH, 1, 1, 1, 0, hash);
    mpz_mod(x, x, P_STR);

    char x_str[65];
    gmp_sprintf(x_str, "%Zx", x);

    mpz_clear(x);

    return enif_make_string(env, x_str, ERL_NIF_LATIN1);
}

// Batch encoding
static ERL_NIF_TERM batch_hash_to_point_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1 || !enif_is_list(env, argv[0])) {
        return enif_make_badarg(env);
    }

    ERL_NIF_TERM head, tail = argv[0];
    ERL_NIF_TERM result_list = enif_make_list(env, 0);

    while (enif_get_list_cell(env, tail, &head, &tail)) {
        char message[256];
        if (enif_get_string(env, head, message, sizeof(message), ERL_NIF_LATIN1)) {
            ERL_NIF_TERM point = hash_to_point_nif(env, 1, &head);
            result_list = enif_make_list_cell(env, point, result_list);
        }
    }

    return result_list;
}

// Define NIF functions
static ErlNifFunc nif_funcs[] = {
    {"hash_to_point", 1, hash_to_point_nif},
    {"batch_hash_to_point", 1, batch_hash_to_point_nif}
};

// Load the NIF
ERL_NIF_INIT(ecai, nif_funcs, NULL, NULL, NULL, NULL)
