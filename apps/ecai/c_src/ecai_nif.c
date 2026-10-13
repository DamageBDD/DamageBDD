/*
 * ecai_nif.c
 *
 * Elliptic Curve AI (ECAI)
 * Deterministic hash-to-Curve25519 affine-point NIF.
 *
 * Hardened v1 improvements:
 *   - binary/iolist input instead of Latin-1 C strings
 *   - explicit domain separation
 *   - length-prefixing to avoid concatenation ambiguity
 *   - fixed GMP initialisation / cleanup on all paths
 *   - canonical even-y output
 *   - precomputed sqrt exponent/fixup per call
 *   - OpenSSL EVP SHA-512 API instead of deprecated SHA512_CTX calls
 *   - dirty CPU-bound NIF registration when supported by the Erlang runtime
 *   - structured {error, Reason} returns for bounded operational failures
 *
 * Copyright (c) 2025 Steven Joseph
 *
 * Author: Steven Joseph
 * Project: ECAI – Elliptic Curve Artificial Intelligence
 *
 * License: MIT License
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 * This is still a raw Curve25519 Montgomery affine-point construction using
 * try-and-increment. It is suitable as a deterministic ECAI coordinate/index
 * primitive, but it is not a replacement for a standards-track hash-to-curve
 * or Ristretto255 prime-order group API where adversarial cryptographic
 * protocol security is required.
 *
 * Build requires: OpenSSL, GMP, Erlang headers.
 * Example:
 *   cc -fPIC -shared -O2 -Wall -Wextra \
 *      -I"$(erl -noshell -eval 'io:format("~s/usr/include", [code:root_dir()]), halt().')" \
 *      -o ecai_nif.so ecai_nif.c -lgmp -lcrypto
 */

#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <openssl/evp.h>
#include <openssl/crypto.h>
#include <openssl/sha.h>
#include <gmp.h>
#include "erl_nif.h"

#define ECAI_MAX_INPUT_SIZE   (64U * 1024U)
#define ECAI_MAX_DOMAIN_SIZE  256U
#define ECAI_MAX_TRIES        4096U

static const char *ECAI_DEFAULT_DOMAIN = "ECAI-H2C-CURVE25519-AFFINE-V1:DEFAULT";
static const unsigned char ECAI_SEED_TAG[] = "ECAI-H2C-CURVE25519-AFFINE-V1:SEED";
static const unsigned char ECAI_CANDIDATE_TAG[] = "ECAI-H2C-CURVE25519-AFFINE-V1:CANDIDATE";

static const char *P_CURVE25519_HEX = "7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED";
static const unsigned long A_CURVE25519 = 486662UL;

typedef struct {
    mpz_t p;
    mpz_t sqrt_exp;    /* (p + 3) / 8 */
    mpz_t sqrt_fixup;  /* 2^((p - 1) / 4) mod p */
} ecai_curve_params_t;

// -----------------------------
// Erlang return helpers
// -----------------------------

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env,
                            enif_make_atom(env, "error"),
                            enif_make_atom(env, reason));
}

// -----------------------------
// Helpers: endian + byte handling
// -----------------------------

static void be32(uint32_t v, unsigned char out[4]) {
    out[0] = (unsigned char)((v >> 24) & 0xffU);
    out[1] = (unsigned char)((v >> 16) & 0xffU);
    out[2] = (unsigned char)((v >>  8) & 0xffU);
    out[3] = (unsigned char)((v >>  0) & 0xffU);
}

static void be64(uint64_t v, unsigned char out[8]) {
    out[0] = (unsigned char)((v >> 56) & 0xffU);
    out[1] = (unsigned char)((v >> 48) & 0xffU);
    out[2] = (unsigned char)((v >> 40) & 0xffU);
    out[3] = (unsigned char)((v >> 32) & 0xffU);
    out[4] = (unsigned char)((v >> 24) & 0xffU);
    out[5] = (unsigned char)((v >> 16) & 0xffU);
    out[6] = (unsigned char)((v >>  8) & 0xffU);
    out[7] = (unsigned char)((v >>  0) & 0xffU);
}

static int sha512_chunks(unsigned char out[SHA512_DIGEST_LENGTH],
                         const unsigned char *const chunks[],
                         const size_t lens[],
                         size_t n_chunks) {
    int ok = 0;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    unsigned int out_len = 0;

    if (ctx == NULL) return 0;

    if (EVP_DigestInit_ex(ctx, EVP_sha512(), NULL) != 1) goto done;

    for (size_t i = 0; i < n_chunks; i++) {
        if (lens[i] == 0) continue;
        if (chunks[i] == NULL) goto done;
        if (EVP_DigestUpdate(ctx, chunks[i], lens[i]) != 1) goto done;
    }

    if (EVP_DigestFinal_ex(ctx, out, &out_len) != 1) goto done;
    if (out_len != SHA512_DIGEST_LENGTH) goto done;

    ok = 1;

done:
    EVP_MD_CTX_free(ctx);
    return ok;
}

// Import 32 bytes as integer, treating input as big-endian.
static void mpz_import_be32(mpz_t out, const unsigned char in[32]) {
    mpz_import(out, 32, 1 /* most significant word first */, 1, 1 /* big endian */, 0, in);
}

// Export mpz to 32 bytes little-endian (Curve25519-style field encoding).
// Assumes 0 <= x < p fits in <= 32 bytes.
static void mpz_export_le32(unsigned char out[32], const mpz_t x) {
    memset(out, 0, 32);

    size_t count = 0;
    unsigned char tmp[32];
    memset(tmp, 0, sizeof(tmp));

    // order=-1 => least significant word first.
    // size=1 means endian is irrelevant inside each word.
    mpz_export(tmp, &count, -1, 1, 0, 0, x);

    if (count > 32) count = 32;
    memcpy(out, tmp, count);

    // Field elements modulo p=2^255-19 already fit under bit 255.
    // Keep the top bit clear for canonical 255-bit field encoding hygiene.
    out[31] &= 0x7FU;
}

// -----------------------------
// Field arithmetic mod p
// -----------------------------

static void fp_mod(mpz_t r, const mpz_t a, const mpz_t p) {
    mpz_mod(r, a, p);
    if (mpz_sgn(r) < 0) mpz_add(r, r, p);
}

// rhs = x^3 + A*x^2 + x (mod p)
static void curve25519_rhs(mpz_t rhs, const mpz_t x, const mpz_t p) {
    mpz_t x2, x3, t;
    mpz_inits(x2, x3, t, NULL);

    mpz_mul(x2, x, x);
    fp_mod(x2, x2, p);

    mpz_mul(x3, x2, x);
    fp_mod(x3, x3, p);

    mpz_mul_ui(t, x2, A_CURVE25519);
    fp_mod(t, t, p);

    mpz_add(rhs, x3, t);
    mpz_add(rhs, rhs, x);
    fp_mod(rhs, rhs, p);

    mpz_clears(x2, x3, t, NULL);
}

static int init_curve_params(ecai_curve_params_t *params) {
    mpz_t exp2, two;

    mpz_inits(params->p, params->sqrt_exp, params->sqrt_fixup, NULL);
    mpz_inits(exp2, two, NULL);

    if (mpz_set_str(params->p, P_CURVE25519_HEX, 16) != 0) {
        mpz_clears(exp2, two, NULL);
        mpz_clears(params->p, params->sqrt_exp, params->sqrt_fixup, NULL);
        return 0;
    }

    // sqrt_exp = (p + 3) / 8
    mpz_add_ui(params->sqrt_exp, params->p, 3);
    mpz_fdiv_q_ui(params->sqrt_exp, params->sqrt_exp, 8);

    // sqrt_fixup = 2^((p - 1) / 4) mod p
    mpz_sub_ui(exp2, params->p, 1);
    mpz_fdiv_q_ui(exp2, exp2, 4);
    mpz_set_ui(two, 2);
    mpz_powm(params->sqrt_fixup, two, exp2, params->p);

    mpz_clears(exp2, two, NULL);
    return 1;
}

static void clear_curve_params(ecai_curve_params_t *params) {
    mpz_clears(params->p, params->sqrt_exp, params->sqrt_fixup, NULL);
}

// sqrt mod p for p ≡ 5 (mod 8), with precomputed constants.
// Returns 1 if sqrt exists and sets y; else 0.
static int fp_sqrt_curve25519(mpz_t y, const mpz_t a, const ecai_curve_params_t *params) {
    mpz_t t, check;
    mpz_inits(t, check, NULL);

    // y = a^((p+3)/8) mod p
    mpz_powm(y, a, params->sqrt_exp, params->p);

    // check = y^2 mod p
    mpz_mul(check, y, y);
    fp_mod(check, check, params->p);

    if (mpz_cmp(check, a) != 0) {
        // y = y * 2^((p-1)/4) mod p
        mpz_mul(t, y, params->sqrt_fixup);
        fp_mod(y, t, params->p);

        mpz_mul(check, y, y);
        fp_mod(check, check, params->p);
        if (mpz_cmp(check, a) != 0) {
            mpz_clears(t, check, NULL);
            return 0;
        }
    }

    mpz_clears(t, check, NULL);
    return 1;
}

static void canonicalize_even_y(mpz_t y, const mpz_t p) {
    if (mpz_odd_p(y)) {
        mpz_sub(y, p, y);
    }
}

// -----------------------------
// Core implementation
// -----------------------------

static ERL_NIF_TERM hash_to_curve_impl(ErlNifEnv *env,
                                        const unsigned char *domain,
                                        size_t domain_len,
                                        const unsigned char *input,
                                        size_t input_len) {
    if (domain_len == 0 || domain_len > ECAI_MAX_DOMAIN_SIZE) {
        return make_error(env, "invalid_domain_size");
    }

    if (input_len > ECAI_MAX_INPUT_SIZE) {
        return make_error(env, "input_too_large");
    }

    ERL_NIF_TERM result = make_error(env, "internal_error");
    ecai_curve_params_t params;
    int params_initialized = 0;

    mpz_t x, rhs, y;
    mpz_inits(x, rhs, y, NULL);

    if (!init_curve_params(&params)) goto cleanup;
    params_initialized = 1;

    unsigned char domain_len_be[4];
    unsigned char input_len_be[8];
    unsigned char seed[SHA512_DIGEST_LENGTH];

    be32((uint32_t)domain_len, domain_len_be);
    be64((uint64_t)input_len, input_len_be);

    // seed = SHA512(seed_tag || domain_len || domain || input_len || input)
    const unsigned char *seed_chunks[] = {
        ECAI_SEED_TAG,
        domain_len_be,
        domain,
        input_len_be,
        input
    };
    const size_t seed_lens[] = {
        sizeof(ECAI_SEED_TAG) - 1,
        sizeof(domain_len_be),
        domain_len,
        sizeof(input_len_be),
        input_len
    };

    if (!sha512_chunks(seed, seed_chunks, seed_lens, 5)) goto cleanup;

    unsigned char h[SHA512_DIGEST_LENGTH];
    unsigned char ctr_be[4];
    unsigned char x_be32[32];

    for (uint32_t ctr = 0; ctr < ECAI_MAX_TRIES; ctr++) {
        be32(ctr, ctr_be);

        // h = SHA512(candidate_tag || seed || counter_be32)
        const unsigned char *candidate_chunks[] = {
            ECAI_CANDIDATE_TAG,
            seed,
            ctr_be
        };
        const size_t candidate_lens[] = {
            sizeof(ECAI_CANDIDATE_TAG) - 1,
            sizeof(seed),
            sizeof(ctr_be)
        };

        if (!sha512_chunks(h, candidate_chunks, candidate_lens, 3)) goto cleanup;

        memcpy(x_be32, h, sizeof(x_be32));
        mpz_import_be32(x, x_be32);
        fp_mod(x, x, params.p);

        curve25519_rhs(rhs, x, params.p);

        if (fp_sqrt_curve25519(y, rhs, &params)) {
            canonicalize_even_y(y, params.p);

            unsigned char x_le32[32], y_le32[32];
            mpz_export_le32(x_le32, x);
            mpz_export_le32(y_le32, y);

            ERL_NIF_TERM xb, yb;
            unsigned char *xbp = enif_make_new_binary(env, sizeof(x_le32), &xb);
            unsigned char *ybp = enif_make_new_binary(env, sizeof(y_le32), &yb);

            if (xbp == NULL || ybp == NULL) goto cleanup;

            memcpy(xbp, x_le32, sizeof(x_le32));
            memcpy(ybp, y_le32, sizeof(y_le32));

            result = enif_make_tuple3(env, xb, yb, enif_make_uint(env, ctr));

            OPENSSL_cleanse(x_le32, sizeof(x_le32));
            OPENSSL_cleanse(y_le32, sizeof(y_le32));
            goto cleanup;
        }
    }

    result = make_error(env, "not_found");

cleanup:
    OPENSSL_cleanse(seed, sizeof(seed));
    OPENSSL_cleanse(h, sizeof(h));
    OPENSSL_cleanse(ctr_be, sizeof(ctr_be));
    OPENSSL_cleanse(x_be32, sizeof(x_be32));

    mpz_clears(x, rhs, y, NULL);

    if (params_initialized) {
        clear_curve_params(&params);
    }

    return result;
}

// -----------------------------
// NIF API
// -----------------------------

// hash_to_curve(InputIolist) -> {XBin32LE, YBin32LE, Counter} | {error, Reason}
static ERL_NIF_TERM hash_to_curve_1(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);

    ErlNifBinary input;
    if (!enif_inspect_iolist_as_binary(env, argv[0], &input)) {
        return enif_make_badarg(env);
    }

    return hash_to_curve_impl(env,
                              (const unsigned char *)ECAI_DEFAULT_DOMAIN,
                              strlen(ECAI_DEFAULT_DOMAIN),
                              input.data,
                              input.size);
}

// hash_to_curve(DomainIolist, InputIolist) -> {XBin32LE, YBin32LE, Counter} | {error, Reason}
static ERL_NIF_TERM hash_to_curve_2(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 2) return enif_make_badarg(env);

    ErlNifBinary domain;
    ErlNifBinary input;

    if (!enif_inspect_iolist_as_binary(env, argv[0], &domain)) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_iolist_as_binary(env, argv[1], &input)) {
        return enif_make_badarg(env);
    }

    return hash_to_curve_impl(env,
                              domain.data,
                              domain.size,
                              input.data,
                              input.size);
}

#ifdef ERL_NIF_DIRTY_JOB_CPU_BOUND
#define ECAI_NIF_ENTRY(Name, Arity, Func) {Name, Arity, Func, ERL_NIF_DIRTY_JOB_CPU_BOUND}
#else
#define ECAI_NIF_ENTRY(Name, Arity, Func) {Name, Arity, Func}
#endif

static ErlNifFunc nif_funcs[] = {
    ECAI_NIF_ENTRY("hash_to_curve", 1, hash_to_curve_1),
    ECAI_NIF_ENTRY("hash_to_curve", 2, hash_to_curve_2)
};

ERL_NIF_INIT(ecai, nif_funcs, NULL, NULL, NULL, NULL)
