#include <stdio.h>
#include <string.h>
#include <math.h>
#include <gmp.h>
#include <openssl/sha.h>
#include "erl_nif.h"

#define MAX_ENTRIES 5000
#define MAX_TEXT_SIZE 2048

const char *P_CURVE25519 = "7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED";

typedef struct {
    char key[65];
    int x;  // X coordinate of curve hash
    int y;  // Approximate representation of secondary hash
    char value[256];  
} KnowledgeEntry;

static KnowledgeEntry knowledge_store[MAX_ENTRIES];
static int knowledge_size = 0;

// Compute Euclidean Distance between two curve-mapped knowledge representations
static double euclidean_distance(int x1, int y1, int x2, int y2) {
    return sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));
}

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

    return enif_make_tuple3(env, enif_make_atom(env, "ok"),
                                   enif_make_int(env, numeric_x),
                                   enif_make_int(env, numeric_y));
}

// Store Knowledge with X, Y curve representations
static ERL_NIF_TERM store_knowledge(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 2) return enif_make_badarg(env);

    char text[MAX_TEXT_SIZE], response[256];
    if (!enif_get_string(env, argv[0], text, sizeof(text), ERL_NIF_LATIN1) ||
        !enif_get_string(env, argv[1], response, sizeof(response), ERL_NIF_LATIN1))
        return enif_make_badarg(env);

    if (knowledge_size >= MAX_ENTRIES) return enif_make_atom(env, "store_full");

    ERL_NIF_TERM hashed_query = hash_to_curve(env, 1, &argv[0]);
    
    // Extract tuple values properly
    const ERL_NIF_TERM *tuple;
    int arity;
    int x, y;

    if (!enif_get_tuple(env, hashed_query, &arity, &tuple) || arity != 3 ||
        !enif_get_int(env, tuple[1], &x) || !enif_get_int(env, tuple[2], &y)) {
        return enif_make_badarg(env);
    }

    knowledge_store[knowledge_size].x = x;
    knowledge_store[knowledge_size].y = y;
    strncpy(knowledge_store[knowledge_size].value, response, sizeof(knowledge_store[knowledge_size].value) - 1);
    knowledge_store[knowledge_size].value[255] = '\0';  // Ensure null termination
    knowledge_size++;

    return enif_make_atom(env, "ok");
}

// Infer closest response using Euclidean Distance ranking
static ERL_NIF_TERM infer_knowledge(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 1) return enif_make_badarg(env);

    char query[MAX_TEXT_SIZE];
    if (!enif_get_string(env, argv[0], query, sizeof(query), ERL_NIF_LATIN1))
        return enif_make_badarg(env);

    ERL_NIF_TERM hashed_query = hash_to_curve(env, 1, &argv[0]);
    
    // Extract tuple values properly
    const ERL_NIF_TERM *tuple;
    int arity;
    int x, y;

    if (!enif_get_tuple(env, hashed_query, &arity, &tuple) || arity != 3 ||
        !enif_get_int(env, tuple[1], &x) || !enif_get_int(env, tuple[2], &y)) {
        return enif_make_badarg(env);
    }

    double best_distance = INFINITY;
    char best_match[256] = "No close matches found.";

    for (int i = 0; i < knowledge_size; i++) {
        double distance = euclidean_distance(x, y, knowledge_store[i].x, knowledge_store[i].y);
        if (distance < best_distance) {
            best_distance = distance;
            strncpy(best_match, knowledge_store[i].value, sizeof(best_match) - 1);
            best_match[255] = '\0';  // Ensure null termination
        }
    }

    return enif_make_string(env, best_match, ERL_NIF_LATIN1);
}

// Register NIF Functions
static ErlNifFunc nif_funcs[] = {
    {"hash_to_curve", 1, hash_to_curve},
    {"store_knowledge", 2, store_knowledge},
    {"infer_knowledge", 1, infer_knowledge}
};

ERL_NIF_INIT(ecai, nif_funcs, NULL, NULL, NULL, NULL)
