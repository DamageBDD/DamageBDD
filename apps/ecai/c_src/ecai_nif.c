/*
 * ecai_nif.c
 *
 * Elliptic Curve AI (ECAI)
 * Deterministic Hash-to-Curve NIF for Curve25519
 *
 * Implements:
 *   - Deterministic SHA-512 seed derivation
 *   - Try-and-increment hash-to-curve construction
 *   - Valid Curve25519 point generation
 *   - Stable finite-field arithmetic using GMP
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
 */

// Replace hash_to_curve/1 with a deterministic “try-and-increment”
// hash-to-curve for Curve25519 (Montgomery form):
//
//   y^2 = x^3 + A*x^2 + x   (mod p),  A=486662
//   p = 2^255 - 19
//
// Algorithm:
//   seed = SHA512(text)
//   for counter = 0..MAX:
//     h = SHA512(seed || counter_be32)
//     x = (h[0..31] mod p)
//     rhs = x^3 + A*x^2 + x mod p
//     y = sqrt_mod_p(rhs) if exists
//     if exists: return {X_bin32_le, Y_bin32_le, Counter}
//
// Notes:
// - This yields an ACTUAL curve point (x,y) in F_p, not truncated ints.
// - Uses p ≡ 5 (mod 8) so we can do fast sqrt for Curve25519.
// - Returns 32-byte little-endian field elements (Curve25519 convention).
//
// Build requires: OpenSSL, GMP, Erlang headers.

#include <string.h>
#include <stdint.h>
#include <openssl/sha.h>
#include <gmp.h>
#include "erl_nif.h"

#define MAX_TEXT_SIZE 2048
#define MAX_TRIES 4096

static const char *P_CURVE25519_HEX = "7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED";
static const unsigned long A_CURVE25519 = 486662;

// -----------------------------
// Helpers: endian + GMP import/export
// -----------------------------

static void be32(uint32_t v, unsigned char out[4]) {
    out[0] = (unsigned char)((v >> 24) & 0xff);
    out[1] = (unsigned char)((v >> 16) & 0xff);
    out[2] = (unsigned char)((v >>  8) & 0xff);
    out[3] = (unsigned char)((v >>  0) & 0xff);
}

// Import 32 bytes as integer, treating input as big-endian.
static void mpz_import_be32(mpz_t out, const unsigned char in[32]) {
    mpz_import(out, 32, 1 /*most significant word first*/, 1, 1 /*big endian*/, 0, in);
}

// Export mpz to 32 bytes little-endian (Curve25519-style field encoding).
// Assumes 0 <= x < p fits in <= 32 bytes.
static void mpz_export_le32(unsigned char out[32], const mpz_t x) {
    memset(out, 0, 32);
    size_t count = 0;

    // Export as little-endian bytes.
    // order=-1 => least significant word first
    // endian=0 => native endian per word; but word size=1 so it's ok.
    unsigned char tmp[32];
    memset(tmp, 0, 32);

    mpz_export(tmp, &count, -1, 1, 0, 0, x);

    // mpz_export writes exactly 'count' bytes in tmp[0..count-1]
    // already little-endian because order=-1 with size=1.
    if (count > 32) count = 32;
    memcpy(out, tmp, count);

    // Clamp to 255 bits (optional safety; x mod p already).
    out[31] &= 0x7F;
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

    // x2 = x^2
    mpz_mul(x2, x, x);
    fp_mod(x2, x2, p);

    // x3 = x^3
    mpz_mul(x3, x2, x);
    fp_mod(x3, x3, p);

    // t = A*x^2
    mpz_mul_ui(t, x2, A_CURVE25519);
    fp_mod(t, t, p);

    // rhs = x^3 + A*x^2 + x
    mpz_add(rhs, x3, t);
    mpz_add(rhs, rhs, x);
    fp_mod(rhs, rhs, p);

    mpz_clears(x2, x3, t, NULL);
}

// -----------------------------
// sqrt mod p for p ≡ 5 (mod 8) (Curve25519 prime)
// From standard Curve25519 sqrt algorithm:
//   Let p = 2^255 - 19, so p % 8 = 5.
//   Compute y = a^((p+3)/8) mod p.
//   If y^2 != a, set y = y * 2^((p-1)/4) mod p.
//   If y^2 == a, sqrt exists.
//
// Returns 1 if sqrt exists and sets y; else 0.
static int fp_sqrt_curve25519(mpz_t y, const mpz_t a, const mpz_t p) {
    mpz_t exp1, exp2, t, check, two, pow_const;
    mpz_inits(exp1, exp2, t, check, two, pow_const, NULL);

    // exp1 = (p + 3) / 8
    mpz_add_ui(exp1, p, 3);
    mpz_fdiv_q_ui(exp1, exp1, 8);

    // y = a^exp1 mod p
    mpz_powm(y, a, exp1, p);

    // check = y^2 mod p
    mpz_mul(check, y, y);
    fp_mod(check, check, p);

    if (mpz_cmp(check, a) != 0) {
        // pow_const = 2^((p-1)/4) mod p
        // exp2 = (p - 1) / 4
        mpz_sub_ui(exp2, p, 1);
        mpz_fdiv_q_ui(exp2, exp2, 4);

        mpz_set_ui(two, 2);
        mpz_powm(pow_const, two, exp2, p);

        // y = y * pow_const mod p
        mpz_mul(t, y, pow_const);
        fp_mod(y, t, p);

        // re-check
        mpz_mul(check, y, y);
        fp_mod(check, check, p);
        if (mpz_cmp(check, a) != 0) {
            mpz_clears(exp1, exp2, t, check, two, pow_const, NULL);
            return 0;
        }
    }

    mpz_clears(exp1, exp2, t, check, two, pow_const, NULL);
    return 1;
}

// -----------------------------
// New NIF: hash_to_curve/1
// Returns {X_bin32, Y_bin32, Counter}
// -----------------------------

static ERL_NIF_TERM hash_to_curve(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);

    char text[MAX_TEXT_SIZE];
    if (!enif_get_string(env, argv[0], text, sizeof(text), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }

    // p = 2^255 - 19
    mpz_t p, seed_mp, x, rhs, y;
    mpz_inits(p, seed_mp, x, rhs, y, NULL);
    mpz_init_set_str(p, P_CURVE25519_HEX, 16);

    // seed = SHA512(text)
    unsigned char seed[SHA512_DIGEST_LENGTH];
    SHA512((unsigned char *)text, strlen(text), seed);

    unsigned char h[SHA512_DIGEST_LENGTH];
    unsigned char ctr_be[4];
    unsigned char x_be32[32];

    for (uint32_t ctr = 0; ctr < MAX_TRIES; ctr++) {
        // h = SHA512(seed || counter_be32)
        SHA512_CTX ctx;
        SHA512_Init(&ctx);
        SHA512_Update(&ctx, seed, sizeof(seed));
        be32(ctr, ctr_be);
        SHA512_Update(&ctx, ctr_be, sizeof(ctr_be));
        SHA512_Final(h, &ctx);

        // x candidate from first 32 bytes (big-endian), then mod p
        memcpy(x_be32, h, 32);
        mpz_import_be32(x, x_be32);
        fp_mod(x, x, p);

        // rhs = x^3 + A*x^2 + x mod p
        curve25519_rhs(rhs, x, p);

        // attempt sqrt
        if (fp_sqrt_curve25519(y, rhs, p)) {
            // Return x,y as 32-byte little-endian binaries + counter
            unsigned char x_le32[32], y_le32[32];
            mpz_export_le32(x_le32, x);
            mpz_export_le32(y_le32, y);

            ERL_NIF_TERM xb, yb;
            unsigned char *xbp = enif_make_new_binary(env, 32, &xb);
            unsigned char *ybp = enif_make_new_binary(env, 32, &yb);
            memcpy(xbp, x_le32, 32);
            memcpy(ybp, y_le32, 32);

            mpz_clears(p, seed_mp, x, rhs, y, NULL);
            return enif_make_tuple3(env, xb, yb, enif_make_uint(env, ctr));
        }
    }

    mpz_clears(p, seed_mp, x, rhs, y, NULL);
    return enif_make_atom(env, "not_found");
}

// Register NIF Functions
static ErlNifFunc nif_funcs[] = {
    {"hash_to_curve", 1, hash_to_curve}
};

ERL_NIF_INIT(ecai, nif_funcs, NULL, NULL, NULL, NULL)

