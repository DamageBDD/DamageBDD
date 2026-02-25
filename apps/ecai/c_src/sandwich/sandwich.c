/*
 * sandwich.c
 *
 * "not even with sudo unless sandwich.c is present"
 *
 * A tiny deterministic "mint + retrieve" demo:
 *  - Mint sandwiches as verifiable tokens in an append-only ledger.
 *  - Retrieve them by deterministic lookup (no probabilistic AI, no guessing).
 *
 * Build:
 *   cc -O2 -Wall -Wextra -pedantic sandwich.c -o sandwich -lcrypto
 *
 * Examples:
 *   ./sandwich init
 *   ./sandwich mint --owner "npub1..." --name "BLT" --notes "extra mayo"
 *   ./sandwich mint --owner "npub1..." --name "Vegemite" --notes "be brave"
 *   ./sandwich query --owner "npub1..."
 *   ./sandwich query --name "BLT"
 *   ./sandwich query --id 1a2b3c
 *
 * Ledger format (one line per token):
 *   v1|token_id_hex|owner|name|notes|curve_point_hex
 *
 * NOTE:
 *   The "curve point" here is a structured placeholder (hash-derived compressed point bytes),
 *   not a full ECC implementation. Swap it for real hash-to-curve when you wire it into your
 *   actual ECAI primitives.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ctype.h>

#include <openssl/sha.h>

#define LEDGER_FILE "sandwich.ledger"
#define MAX_FIELD   4096

static void die(const char *msg) {
    fprintf(stderr, "fatal: %s\n", msg);
    exit(1);
}

static void hex_encode(const unsigned char *in, size_t inlen, char *out, size_t outlen) {
    static const char *hex = "0123456789abcdef";
    if (outlen < (inlen * 2 + 1)) die("hex_encode: output buffer too small");
    for (size_t i = 0; i < inlen; i++) {
        out[i*2]     = hex[(in[i] >> 4) & 0xF];
        out[i*2 + 1] = hex[in[i] & 0xF];
    }
    out[inlen*2] = '\0';
}

static int starts_with(const char *s, const char *prefix) {
    size_t a = strlen(s), b = strlen(prefix);
    if (b > a) return 0;
    return strncmp(s, prefix, b) == 0;
}

/*
 * Canonicalize fields so minting is deterministic:
 * - use separators unlikely to appear
 * - preserve user strings exactly (you can harden this if needed)
 */
static void compute_token_id(const char *owner, const char *name, const char *notes,
                             unsigned char out32[32]) {
    SHA256_CTX ctx;
    SHA256_Init(&ctx);

    // version tag helps future-proof the canonical form
    const char *v = "ECAI-SANDWICH:v1|";
    SHA256_Update(&ctx, v, strlen(v));

    SHA256_Update(&ctx, owner, strlen(owner));
    SHA256_Update(&ctx, "|", 1);
    SHA256_Update(&ctx, name, strlen(name));
    SHA256_Update(&ctx, "|", 1);
    SHA256_Update(&ctx, notes, strlen(notes));

    SHA256_Final(out32, &ctx);
}

/*
 * "Hash-to-curve" placeholder:
 * Produces a 33-byte "compressed point":
 *   [0] = 0x02 or 0x03 (parity-like bit)
 *   [1..32] = token_id (x-like bytes)
 *
 * In real ECAI, swap this for a standard hash-to-curve for your chosen curve
 * (e.g., RFC 9380 for short Weierstrass curves, or a proper ristretto/decaf mapping).
 */
static void token_id_to_point33(const unsigned char token_id32[32],
                                unsigned char out33[33]) {
    unsigned char parity = (token_id32[31] & 1) ? 0x03 : 0x02;
    out33[0] = parity;
    memcpy(out33 + 1, token_id32, 32);
}

/* Minimal argv parsing */
static const char* arg_value(int argc, char **argv, const char *key) {
    for (int i = 0; i < argc - 1; i++) {
        if (strcmp(argv[i], key) == 0) return argv[i+1];
    }
    return NULL;
}

static void cmd_init(void) {
    FILE *f = fopen(LEDGER_FILE, "a");
    if (!f) die("could not open ledger for append");
    fclose(f);
    printf("ok: %s ready\n", LEDGER_FILE);
}

static void cmd_mint(int argc, char **argv) {
    const char *owner = arg_value(argc, argv, "--owner");
    const char *name  = arg_value(argc, argv, "--name");
    const char *notes = arg_value(argc, argv, "--notes");
    if (!owner || !name) {
        die("mint requires --owner and --name (optional --notes)");
    }
    if (!notes) notes = "";

    unsigned char token_id32[32];
    compute_token_id(owner, name, notes, token_id32);

    unsigned char point33[33];
    token_id_to_point33(token_id32, point33);

    char token_hex[65];
    char point_hex[67];
    hex_encode(token_id32, 32, token_hex, sizeof(token_hex));
    hex_encode(point33, 33, point_hex, sizeof(point_hex));

    FILE *f = fopen(LEDGER_FILE, "a");
    if (!f) die("could not open ledger for append");

    // Append-only “mint”
    fprintf(f, "v1|%s|%s|%s|%s|%s\n", token_hex, owner, name, notes, point_hex);
    fclose(f);

    printf("minted:\n");
    printf("  token_id:     %s\n", token_hex);
    printf("  owner:        %s\n", owner);
    printf("  name:         %s\n", name);
    printf("  notes:        %s\n", notes);
    printf("  curve_point:  %s\n", point_hex);
}

static void print_token_line(const char *line) {
    // line is already a single record; print it nicely
    // v1|token|owner|name|notes|point
    char buf[MAX_FIELD];
    strncpy(buf, line, sizeof(buf)-1);
    buf[sizeof(buf)-1] = '\0';

    char *save = NULL;
    char *v = strtok_r(buf, "|", &save);
    char *token = strtok_r(NULL, "|", &save);
    char *owner = strtok_r(NULL, "|", &save);
    char *name  = strtok_r(NULL, "|", &save);
    char *notes = strtok_r(NULL, "|", &save);
    char *point = strtok_r(NULL, "|\n\r", &save);

    if (!v || !token || !owner || !name || !notes || !point) return;

    printf("- token_id:    %s\n", token);
    printf("  owner:       %s\n", owner);
    printf("  name:        %s\n", name);
    printf("  notes:       %s\n", notes);
    printf("  curve_point: %s\n", point);
}

static void cmd_query(int argc, char **argv) {
    const char *id_prefix = arg_value(argc, argv, "--id");
    const char *owner_q   = arg_value(argc, argv, "--owner");
    const char *name_q    = arg_value(argc, argv, "--name");

    if (!id_prefix && !owner_q && !name_q) {
        die("query requires one of: --id <hexprefix> | --owner <string> | --name <string>");
    }

    FILE *f = fopen(LEDGER_FILE, "r");
    if (!f) die("could not open ledger for read");

    char line[MAX_FIELD];
    int found = 0;

    while (fgets(line, sizeof(line), f)) {
        // Quick-and-dirty parse: look for token/owner/name fields
        // v1|token|owner|name|notes|point
        char tmp[MAX_FIELD];
        strncpy(tmp, line, sizeof(tmp)-1);
        tmp[sizeof(tmp)-1] = '\0';

        char *save = NULL;
        char *v = strtok_r(tmp, "|", &save);
        char *token = strtok_r(NULL, "|", &save);
        char *owner = strtok_r(NULL, "|", &save);
        char *name  = strtok_r(NULL, "|", &save);

        if (!v || !token || !owner || !name) continue;

        int ok = 1;
        if (id_prefix) ok = ok && starts_with(token, id_prefix);
        if (owner_q)   ok = ok && (strstr(owner, owner_q) != NULL);
        if (name_q)    ok = ok && (strstr(name, name_q) != NULL);

        if (ok) {
            if (!found) printf("results:\n");
            found = 1;
            print_token_line(line);
        }
    }

    fclose(f);
    if (!found) printf("no results\n");
}

static void usage(const char *prog) {
    printf("usage:\n");
    printf("  %s init\n", prog);
    printf("  %s mint  --owner <string> --name <string> [--notes <string>]\n", prog);
    printf("  %s query --id <hexprefix>\n", prog);
    printf("  %s query --owner <string>\n", prog);
    printf("  %s query --name <string>\n", prog);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }

    if (strcmp(argv[1], "init") == 0) {
        cmd_init();
        return 0;
    }

    if (strcmp(argv[1], "mint") == 0) {
        cmd_mint(argc, argv);
        return 0;
    }

    if (strcmp(argv[1], "query") == 0) {
        cmd_query(argc, argv);
        return 0;
    }

    usage(argv[0]);
    return 2;
}
