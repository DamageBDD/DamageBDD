#include <stdio.h>
#include <string.h>
#include <math.h>
#include <gmp.h>
#include <openssl/sha.h>
#include "erl_nif.h"

#define MAX_TEXT_SIZE 2048
const char *P_CURVE25519 = "7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED";


#include <stdio.h>
#include <string.h>
#include <math.h>
#include <gmp.h>
#include "erl_nif.h"



// Map text to a Curve25519 elliptic curve point as a numerical scalar
static ERL_NIF_TERM hash_to_curve(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);

    char text[MAX_TEXT_SIZE];
    if (!enif_get_string(env, argv[0], text, sizeof(text), ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    
    unsigned char hash[SHA512_DIGEST_LENGTH];
    SHA512((unsigned char *)text, strlen(text), hash);

    mpz_t x, p;
    mpz_init(x);
    mpz_init_set_str(p, P_CURVE25519, 16);
    mpz_import(x, 32, 1, 1, 1, 0, hash);
    mpz_mod(x, x, p);

    char x_str[65];
    gmp_sprintf(x_str, "%Zx", x);

    int numeric_x = (int)(mpz_get_ui(x) % 2147483647);  // Ensure value fits in int
    int numeric_y = (int)(hash[0] << 8 | hash[1]);  // Approximate secondary hash

    mpz_clear(x);
    mpz_clear(p);

    return enif_make_tuple2(env, 
                                   enif_make_int(env, numeric_x),
                                   enif_make_int(env, numeric_y));
}

static ERL_NIF_TERM curve_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 2) return enif_make_badarg(env);

    int x1, y1, x2, y2;
    if (!enif_get_int(env, argv[0], &x1) ||
        !enif_get_int(env, argv[1], &y1) ||
        !enif_get_int(env, argv[2], &x2) ||
        !enif_get_int(env, argv[3], &y2)) {
        return enif_make_badarg(env);
    }

    mpz_t p, x1_mp, y1_mp, x2_mp, y2_mp, s, x3, y3, num, denom, denom_inv;
    mpz_init_set_str(p, P_CURVE25519, 16);
    mpz_inits(x1_mp, y1_mp, x2_mp, y2_mp, s, x3, y3, num, denom, denom_inv, NULL);

    mpz_set_ui(x1_mp, x1);
    mpz_set_ui(y1_mp, y1);
    mpz_set_ui(x2_mp, x2);
    mpz_set_ui(y2_mp, y2);

    if (mpz_cmp(x1_mp, x2_mp) == 0 && mpz_cmp(y1_mp, y2_mp) == 0) {
        // Point Doubling
        mpz_mul_ui(num, x1_mp, 3);
        mpz_add_ui(num, num, 486662);
        mpz_mul(num, num, x1_mp);

        mpz_mul_ui(denom, y1_mp, 2);
    } else {
        // Point Addition
        mpz_sub(num, y2_mp, y1_mp);
        mpz_sub(denom, x2_mp, x1_mp);
    }

    // Modular inverse for division
    if (mpz_invert(denom_inv, denom, p) == 0) {
        return enif_make_atom(env, "infinity");
    }

    // Compute slope
    mpz_mul(s, num, denom_inv);
    mpz_mod(s, s, p);

    // Compute new x3 and y3
    mpz_mul(x3, s, s);
    mpz_sub(x3, x3, x1_mp);
    mpz_sub(x3, x3, x2_mp);
    mpz_mod(x3, x3, p);

    mpz_sub(y3, x1_mp, x3);
    mpz_mul(y3, s, y3);
    mpz_sub(y3, y3, y1_mp);
    mpz_mod(y3, y3, p);

    int x3_int = mpz_get_ui(x3);
    int y3_int = mpz_get_ui(y3);

    mpz_clears(x1_mp, y1_mp, x2_mp, y2_mp, s, x3, y3, num, denom, denom_inv, NULL);
    mpz_clear(p);

    return enif_make_tuple2(env, enif_make_int(env, x3_int), enif_make_int(env, y3_int));
}




// Register NIF Functions
static ErlNifFunc nif_funcs[] = {
    {"hash_to_curve", 1, hash_to_curve},
    {"curve_add", 4, curve_add}
};

ERL_NIF_INIT(ecai, nif_funcs, NULL, NULL, NULL, NULL)
