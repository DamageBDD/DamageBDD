#define _POSIX_C_SOURCE 200809L
#include <ctype.h>
#include <limits.h>
#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <openssl/ec.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/obj_mac.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VAULT_ITERATIONS 600000
#define SALT_LEN 16
#define IV_LEN 12
#define TAG_LEN 16
#define KEY_LEN 32
#define NIP44_MAX_PLAINTEXT 262144

struct vault {
  uint8_t priv[32];
  char pub[65];
  char npub[96];
};

static void cleanse(void *p, size_t n) {
  if (p && n)
    OPENSSL_cleanse(p, n);
}
static char *xstrndup(const char *s, size_t n) {
  char *p = malloc(n + 1);
  if (!p)
    return NULL;
  memcpy(p, s, n);
  p[n] = 0;
  return p;
}
static char *slurp_stdin(void) {
  size_t cap = 4096, len = 0;
  char *b = malloc(cap);
  if (!b)
    return NULL;
  for (;;) {
    int c = fgetc(stdin);
    if (c == EOF) {
      if (ferror(stdin)) {
        free(b);
        return NULL;
      }
      break;
    }
    if (len + 2 > cap) {
      cap *= 2;
      char *t = realloc(b, cap);
      if (!t) {
        free(b);
        return NULL;
      }
      b = t;
    }
    b[len++] = (char)c;
    if (c == '\n')
      break;
  }
  b[len] = 0;
  return b;
}
static char *slurp_file(const char *path, size_t *out_len) {
  FILE *f = fopen(path, "rb");
  if (!f)
    return NULL;
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  long sz = ftell(f);
  if (sz < 0) {
    fclose(f);
    return NULL;
  }
  rewind(f);
  char *b = malloc((size_t)sz + 1);
  if (!b) {
    fclose(f);
    return NULL;
  }
  size_t n = fread(b, 1, (size_t)sz, f);
  fclose(f);
  if (n != (size_t)sz) {
    free(b);
    return NULL;
  }
  b[n] = 0;
  if (out_len)
    *out_len = n;
  return b;
}
static bool write_file(const char *path, const char *data, size_t len) {
  FILE *f = fopen(path, "wb");
  if (!f)
    return false;
  size_t n = fwrite(data, 1, len, f);
  int rc = fclose(f);
  return n == len && rc == 0;
}

static char *json_escape(const char *s) {
  size_t n = strlen(s), cap = n * 6 + 1, j = 0;
  char *o = malloc(cap);
  if (!o)
    return NULL;
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    switch (c) {
    case '"':
      o[j++] = '\\';
      o[j++] = '"';
      break;
    case '\\':
      o[j++] = '\\';
      o[j++] = '\\';
      break;
    case '\n':
      o[j++] = '\\';
      o[j++] = 'n';
      break;
    case '\r':
      o[j++] = '\\';
      o[j++] = 'r';
      break;
    case '\t':
      o[j++] = '\\';
      o[j++] = 't';
      break;
    case '\b':
      o[j++] = '\\';
      o[j++] = 'b';
      break;
    case '\f':
      o[j++] = '\\';
      o[j++] = 'f';
      break;
    default:
      if (c < 32) {
        snprintf(o + j, cap - j, "\\u%04x", c);
        j += 6;
      } else
        o[j++] = (char)c;
    }
  }
  o[j] = 0;
  return o;
}
static void ok_obj(const char *obj) {
  printf("{\"ok\":true,\"result\":%s}\n", obj ? obj : "{}");
}
static void err_msg(const char *m) {
  char *e = json_escape(m ? m : "error");
  printf("{\"ok\":false,\"error\":\"%s\"}\n", e ? e : "oom");
  free(e);
}

static int hx(char c) {
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  return -1;
}
static bool hex_decode(const char *h, uint8_t *out, size_t n) {
  if (!h || strlen(h) != 2 * n)
    return false;
  for (size_t i = 0; i < n; i++) {
    int a = hx(h[2 * i]), b = hx(h[2 * i + 1]);
    if (a < 0 || b < 0)
      return false;
    out[i] = (uint8_t)((a << 4) | b);
  }
  return true;
}
static char *hex_encode(const uint8_t *d, size_t n) {
  static const char *hh = "0123456789abcdef";
  char *o = malloc(n * 2 + 1);
  if (!o)
    return NULL;
  for (size_t i = 0; i < n; i++) {
    o[2 * i] = hh[d[i] >> 4];
    o[2 * i + 1] = hh[d[i] & 15];
  }
  o[2 * n] = 0;
  return o;
}
static bool hex_len(const char *s, size_t bytes) {
  if (!s || strlen(s) != 2 * bytes)
    return false;
  for (size_t i = 0; i < 2 * bytes; i++)
    if (!isxdigit((unsigned char)s[i]))
      return false;
  return true;
}
static bool hex64(const char *s) { return hex_len(s, 32); }
static void strlower(char *s) {
  for (; s && *s; s++)
    *s = (char)tolower((unsigned char)*s);
}

static const char *find_key(const char *json, const char *key) {
  char pat[128];
  snprintf(pat, sizeof(pat), "\"%s\"", key);
  const char *p = json;
  while ((p = strstr(p, pat))) {
    p += strlen(pat);
    while (*p && isspace((unsigned char)*p))
      p++;
    if (*p == ':')
      return p + 1;
  }
  return NULL;
}
static const char *skip_ws(const char *p) {
  while (p && *p && isspace((unsigned char)*p))
    p++;
  return p;
}
static char *json_unescape_slice(const char *s, size_t n) {
  char *o = malloc(n + 1);
  if (!o)
    return NULL;
  size_t j = 0;
  for (size_t i = 0; i < n; i++) {
    char c = s[i];
    if (c != '\\') {
      o[j++] = c;
      continue;
    }
    if (++i >= n) {
      free(o);
      return NULL;
    }
    c = s[i];
    switch (c) {
    case '"':
      o[j++] = '"';
      break;
    case '\\':
      o[j++] = '\\';
      break;
    case '/':
      o[j++] = '/';
      break;
    case 'b':
      o[j++] = '\b';
      break;
    case 'f':
      o[j++] = '\f';
      break;
    case 'n':
      o[j++] = '\n';
      break;
    case 'r':
      o[j++] = '\r';
      break;
    case 't':
      o[j++] = '\t';
      break;
    case 'u':
      if (i + 4 < n) {
        o[j++] = '?';
        i += 4;
      } else {
        free(o);
        return NULL;
      }
      break;
    default:
      free(o);
      return NULL;
    }
  }
  o[j] = 0;
  return o;
}
static char *json_get_string(const char *json, const char *key) {
  const char *p = skip_ws(find_key(json, key));
  if (!p || *p != '"')
    return NULL;
  p++;
  const char *start = p;
  bool esc = false;
  while (*p) {
    if (esc) {
      esc = false;
      p++;
      continue;
    }
    if (*p == '\\') {
      esc = true;
      p++;
      continue;
    }
    if (*p == '"')
      return json_unescape_slice(start, (size_t)(p - start));
    p++;
  }
  return NULL;
}
static char *json_get_raw_value(const char *json, const char *key) {
  const char *p = skip_ws(find_key(json, key));
  if (!p)
    return NULL;
  const char *s = p;
  if (*p == '"') {
    p++;
    bool esc = false;
    while (*p) {
      if (esc) {
        esc = false;
        p++;
        continue;
      }
      if (*p == '\\') {
        esc = true;
        p++;
        continue;
      }
      if (*p == '"') {
        p++;
        return xstrndup(s, (size_t)(p - s));
      }
      p++;
    }
    return NULL;
  }
  if (*p == '{' || *p == '[') {
    char open = *p, close = (*p == '{' ? '}' : ']');
    int depth = 0;
    bool instr = false, esc = false;
    while (*p) {
      char c = *p;
      if (instr) {
        if (esc)
          esc = false;
        else if (c == '\\')
          esc = true;
        else if (c == '"')
          instr = false;
        p++;
        continue;
      }
      if (c == '"') {
        instr = true;
        p++;
        continue;
      }
      if (c == open)
        depth++;
      if (c == close) {
        depth--;
        if (depth == 0) {
          p++;
          return xstrndup(s, (size_t)(p - s));
        }
      }
      p++;
    }
    return NULL;
  }
  while (*p && *p != ',' && *p != '}' && *p != ']' &&
         !isspace((unsigned char)*p))
    p++;
  return xstrndup(s, (size_t)(p - s));
}
static char *json_get_object(const char *json, const char *key) {
  char *v = json_get_raw_value(json, key);
  if (!v || v[0] != '{') {
    free(v);
    return NULL;
  }
  return v;
}

static void sha256_bytes(const uint8_t *d, size_t n, uint8_t out[32]) {
  unsigned int l = 0;
  EVP_Digest(d, n, out, &l, EVP_sha256(), NULL);
}
static void hmac_sha256(const uint8_t *key, size_t kl, const uint8_t *msg,
                        size_t ml, uint8_t out[32]) {
  unsigned int l = 0;
  HMAC(EVP_sha256(), key, (int)kl, msg, ml, out, &l);
}
static bool hkdf_extract(const uint8_t *salt, size_t sl, const uint8_t *ikm,
                         size_t il, uint8_t prk[32]) {
  hmac_sha256(salt, sl, ikm, il, prk);
  return true;
}
static bool hkdf_expand(const uint8_t prk[32], const uint8_t *info, size_t il,
                        uint8_t *out, size_t L) {
  uint8_t T[32];
  size_t tlen = 0, pos = 0;
  uint8_t ctr = 1;
  while (pos < L) {
    HMAC_CTX *ctx = HMAC_CTX_new();
    if (!ctx)
      return false;
    if (HMAC_Init_ex(ctx, prk, 32, EVP_sha256(), NULL) != 1) {
      HMAC_CTX_free(ctx);
      return false;
    }
    if (tlen)
      HMAC_Update(ctx, T, tlen);
    if (il)
      HMAC_Update(ctx, info, il);
    HMAC_Update(ctx, &ctr, 1);
    unsigned int olen = 0;
    HMAC_Final(ctx, T, &olen);
    HMAC_CTX_free(ctx);
    size_t take = (L - pos < olen) ? L - pos : olen;
    memcpy(out + pos, T, take);
    pos += take;
    tlen = olen;
    ctr++;
  }
  cleanse(T, 32);
  return true;
}
static void tagged_hash(const char *tag, const uint8_t *m, size_t ml,
                        uint8_t out[32]) {
  uint8_t th[32];
  unsigned int l = 0;
  sha256_bytes((const uint8_t *)tag, strlen(tag), th);
  EVP_MD_CTX *c = EVP_MD_CTX_new();
  if (!c) {
    memset(out, 0, 32);
    return;
  }
  EVP_DigestInit_ex(c, EVP_sha256(), NULL);
  EVP_DigestUpdate(c, th, 32);
  EVP_DigestUpdate(c, th, 32);
  EVP_DigestUpdate(c, m, ml);
  EVP_DigestFinal_ex(c, out, &l);
  EVP_MD_CTX_free(c);
}

/* bech32 npub */
static const char *B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
static uint32_t polymod(const uint8_t *v, size_t n) {
  uint32_t chk = 1;
  static const uint32_t g[5] = {0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd,
                                0x2a1462b3};
  for (size_t i = 0; i < n; i++) {
    uint8_t top = chk >> 25;
    chk = (chk & 0x1ffffff) << 5 ^ v[i];
    for (int j = 0; j < 5; j++)
      if ((top >> j) & 1)
        chk ^= g[j];
  }
  return chk;
}
static size_t hrp_expand(uint8_t *o) {
  const char *h = "npub";
  size_t j = 0;
  for (size_t i = 0; i < 4; i++)
    o[j++] = h[i] >> 5;
  o[j++] = 0;
  for (size_t i = 0; i < 4; i++)
    o[j++] = h[i] & 31;
  return j;
}
static size_t conv8to5(const uint8_t *in, size_t n, uint8_t *out) {
  uint32_t acc = 0;
  int bits = 0;
  size_t j = 0;
  for (size_t i = 0; i < n; i++) {
    acc = (acc << 8) | in[i];
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out[j++] = (acc >> bits) & 31;
    }
  }
  if (bits > 0)
    out[j++] = (acc << (5 - bits)) & 31;
  return j;
}
static char *npub_encode(const uint8_t pub[32]) {
  uint8_t data[64], vals[128], cs[6];
  size_t dl = conv8to5(pub, 32, data), vl = hrp_expand(vals);
  memcpy(vals + vl, data, dl);
  vl += dl;
  memset(vals + vl, 0, 6);
  uint32_t m = polymod(vals, vl + 6) ^ 1;
  for (int i = 0; i < 6; i++)
    cs[i] = (m >> (5 * (5 - i))) & 31;
  char *o = malloc(5 + dl + 6 + 1);
  if (!o)
    return NULL;
  memcpy(o, "npub1", 5);
  size_t j = 5;
  for (size_t i = 0; i < dl; i++)
    o[j++] = B32[data[i]];
  for (int i = 0; i < 6; i++)
    o[j++] = B32[cs[i]];
  o[j] = 0;
  return o;
}

/* secp256k1 / BIP340 */
static EC_GROUP *group_new(void) {
  EC_GROUP *g = EC_GROUP_new_by_curve_name(NID_secp256k1);
  if (g)
    EC_GROUP_set_asn1_flag(g, OPENSSL_EC_NAMED_CURVE);
  return g;
}
static bool bn32(const BIGNUM *b, uint8_t out[32]) {
  return BN_bn2binpad(b, out, 32) == 32;
}
static bool scalar_ok(const BIGNUM *d, const BIGNUM *n) {
  return !BN_is_zero(d) && !BN_is_negative(d) && BN_cmp(d, n) < 0;
}
static bool point_xy(const EC_GROUP *g, const EC_POINT *P, BIGNUM *x, BIGNUM *y,
                     BN_CTX *ctx) {
  return EC_POINT_get_affine_coordinates(g, P, x, y, ctx) == 1;
}
static bool lift_x(const uint8_t xbytes[32], EC_POINT *P, const EC_GROUP *g,
                   BN_CTX *ctx) {
  bool ok = false;
  BIGNUM *x = BN_bin2bn(xbytes, 32, NULL), *p = BN_new(), *a = BN_new(),
         *b = BN_new(), *y2 = BN_new(), *y = BN_new(), *e = BN_new(),
         *tmp = BN_new();
  if (!x || !p || !a || !b || !y2 || !y || !e || !tmp)
    goto done;
  if (!EC_GROUP_get_curve(g, p, a, b, ctx))
    goto done;
  if (BN_cmp(x, p) >= 0)
    goto done; /* y^2 = x^3 + 7 */
  if (!BN_mod_sqr(y2, x, p, ctx))
    goto done;
  if (!BN_mod_mul(y2, y2, x, p, ctx))
    goto done;
  if (!BN_mod_add(y2, y2, b, p, ctx))
    goto done;
  if (!BN_copy(e, p))
    goto done;
  if (!BN_add_word(e, 1))
    goto done;
  if (!BN_rshift(e, e, 2))
    goto done;
  if (!BN_mod_exp(y, y2, e, p, ctx))
    goto done;
  if (!BN_mod_sqr(tmp, y, p, ctx))
    goto done;
  if (BN_cmp(tmp, y2) != 0)
    goto done;
  if (BN_is_odd(y)) {
    if (!BN_sub(y, p, y))
      goto done;
  }
  if (!EC_POINT_set_affine_coordinates(g, P, x, y, ctx))
    goto done;
  ok = true;
done:
  BN_free(x);
  BN_free(p);
  BN_free(a);
  BN_free(b);
  BN_free(y2);
  BN_free(y);
  BN_free(e);
  BN_free(tmp);
  return ok;
}
static bool pub_from_priv_raw(const uint8_t priv[32], uint8_t pub[32],
                              bool *odd) {
  bool ok = false;
  BN_CTX *ctx = BN_CTX_new();
  EC_GROUP *g = group_new();
  EC_POINT *P = NULL;
  BIGNUM *d = NULL, *x = NULL, *y = NULL, *n = NULL;
  if (!ctx || !g)
    goto done;
  P = EC_POINT_new(g);
  d = BN_bin2bn(priv, 32, NULL);
  x = BN_new();
  y = BN_new();
  n = BN_new();
  if (!P || !d || !x || !y || !n)
    goto done;
  if (!EC_GROUP_get_order(g, n, ctx) || !scalar_ok(d, n))
    goto done;
  if (!EC_POINT_mul(g, P, d, NULL, NULL, ctx))
    goto done;
  if (!point_xy(g, P, x, y, ctx))
    goto done;
  if (!bn32(x, pub))
    goto done;
  if (odd)
    *odd = BN_is_odd(y);
  ok = true;
done:
  BN_clear_free(d);
  BN_free(x);
  BN_free(y);
  BN_free(n);
  EC_POINT_free(P);
  EC_GROUP_free(g);
  BN_CTX_free(ctx);
  return ok;
}
static bool normalize_priv(const uint8_t in[32], uint8_t out[32],
                           uint8_t pub[32]) {
  bool odd = false, ok = false;
  BN_CTX *ctx = BN_CTX_new();
  EC_GROUP *g = group_new();
  BIGNUM *d = BN_bin2bn(in, 32, NULL), *n = BN_new(), *adj = BN_new();
  if (!ctx || !g || !d || !n || !adj)
    goto done;
  if (!EC_GROUP_get_order(g, n, ctx) || !scalar_ok(d, n))
    goto done;
  if (!pub_from_priv_raw(in, pub, &odd))
    goto done;
  if (odd) {
    if (!BN_sub(adj, n, d) || !bn32(adj, out))
      goto done;
    if (!pub_from_priv_raw(out, pub, &odd) || odd)
      goto done;
  } else
    memcpy(out, in, 32);
  ok = true;
done:
  BN_clear_free(d);
  BN_free(n);
  BN_clear_free(adj);
  EC_GROUP_free(g);
  BN_CTX_free(ctx);
  return ok;
}
static bool keygen(uint8_t priv[32], uint8_t pub[32]) {
  uint8_t raw[32];
  for (int i = 0; i < 1024; i++) {
    if (RAND_bytes(raw, 32) != 1)
      return false;
    if (normalize_priv(raw, priv, pub)) {
      cleanse(raw, 32);
      return true;
    }
  }
  cleanse(raw, 32);
  return false;
}
static bool schnorr_sign_aux(const uint8_t secret[32], const uint8_t msg[32],
                             const uint8_t aux[32], uint8_t pub[32],
                             uint8_t sig[64]) {
  bool ok = false;
  uint8_t dbytes[32], pk[32], ah[32], t[32], nin[96], rand[32], rx[32], cin[96],
      ebytes[32];
  if (!normalize_priv(secret, dbytes, pk))
    return false;
  if (pub)
    memcpy(pub, pk, 32);
  tagged_hash("BIP0340/aux", aux, 32, ah);
  for (int i = 0; i < 32; i++)
    t[i] = dbytes[i] ^ ah[i];
  memcpy(nin, t, 32);
  memcpy(nin + 32, pk, 32);
  memcpy(nin + 64, msg, 32);
  tagged_hash("BIP0340/nonce", nin, 96, rand);
  BN_CTX *ctx = BN_CTX_new();
  EC_GROUP *g = group_new();
  EC_POINT *R = NULL;
  BIGNUM *n = NULL, *d = NULL, *k0 = NULL, *k = NULL, *x = NULL, *y = NULL,
         *e = NULL, *ed = NULL, *s = NULL;
  if (!ctx || !g)
    goto done;
  R = EC_POINT_new(g);
  n = BN_new();
  d = BN_bin2bn(dbytes, 32, NULL);
  k0 = BN_bin2bn(rand, 32, NULL);
  k = BN_new();
  x = BN_new();
  y = BN_new();
  e = BN_new();
  ed = BN_new();
  s = BN_new();
  if (!R || !n || !d || !k0 || !k || !x || !y || !e || !ed || !s)
    goto done;
  if (!EC_GROUP_get_order(g, n, ctx))
    goto done;
  BN_mod(k0, k0, n, ctx);
  if (BN_is_zero(k0))
    goto done;
  if (!EC_POINT_mul(g, R, k0, NULL, NULL, ctx))
    goto done;
  if (!point_xy(g, R, x, y, ctx))
    goto done;
  if (BN_is_odd(y)) {
    if (!BN_sub(k, n, k0))
      goto done;
  } else if (!BN_copy(k, k0))
    goto done;
  if (!bn32(x, rx))
    goto done;
  memcpy(cin, rx, 32);
  memcpy(cin + 32, pk, 32);
  memcpy(cin + 64, msg, 32);
  tagged_hash("BIP0340/challenge", cin, 96, ebytes);
  BN_bin2bn(ebytes, 32, e);
  BN_mod(e, e, n, ctx);
  if (!BN_mod_mul(ed, e, d, n, ctx))
    goto done;
  if (!BN_mod_add(s, k, ed, n, ctx))
    goto done;
  if (!bn32(s, sig + 32))
    goto done;
  memcpy(sig, rx, 32);
  ok = true;
done:
  BN_clear_free(d);
  BN_clear_free(k0);
  BN_clear_free(k);
  BN_free(x);
  BN_free(y);
  BN_free(e);
  BN_free(ed);
  BN_free(s);
  BN_free(n);
  EC_POINT_free(R);
  EC_GROUP_free(g);
  BN_CTX_free(ctx);
  cleanse(dbytes, 32);
  cleanse(ah, 32);
  cleanse(t, 32);
  cleanse(rand, 32);
  return ok;
}
static bool schnorr_sign_random(const uint8_t secret[32], const uint8_t msg[32],
                                uint8_t sig[64]) {
  uint8_t aux[32], pub[32];
  if (RAND_bytes(aux, 32) != 1)
    return false;
  return schnorr_sign_aux(secret, msg, aux, pub, sig);
}
static bool schnorr_verify(const uint8_t pub[32], const uint8_t msg[32],
                           const uint8_t sig[64]) {
  bool ok = false;
  BN_CTX *ctx = BN_CTX_new();
  EC_GROUP *g = group_new();
  EC_POINT *P = NULL, *R = NULL;
  BIGNUM *p = NULL, *n = NULL, *r = NULL, *s = NULL, *e = NULL, *ne = NULL,
         *x = NULL, *y = NULL;
  if (!ctx || !g)
    goto done;
  P = EC_POINT_new(g);
  R = EC_POINT_new(g);
  p = BN_new();
  n = BN_new();
  r = BN_bin2bn(sig, 32, NULL);
  s = BN_bin2bn(sig + 32, 32, NULL);
  e = BN_new();
  ne = BN_new();
  x = BN_new();
  y = BN_new();
  if (!P || !R || !p || !n || !r || !s || !e || !ne || !x || !y)
    goto done;
  if (!EC_GROUP_get_curve(g, p, NULL, NULL, ctx) ||
      !EC_GROUP_get_order(g, n, ctx))
    goto done;
  if (BN_cmp(r, p) >= 0 || BN_cmp(s, n) >= 0)
    goto done;
  if (!lift_x(pub, P, g, ctx))
    goto done;
  uint8_t cin[96], ebytes[32];
  memcpy(cin, sig, 32);
  memcpy(cin + 32, pub, 32);
  memcpy(cin + 64, msg, 32);
  tagged_hash("BIP0340/challenge", cin, 96, ebytes);
  BN_bin2bn(ebytes, 32, e);
  BN_mod(e, e, n, ctx);
  if (BN_is_zero(e))
    BN_zero(ne);
  else {
    if (!BN_sub(ne, n, e))
      goto done;
  }
  if (!EC_POINT_mul(g, R, s, P, ne, ctx))
    goto done;
  if (EC_POINT_is_at_infinity(g, R))
    goto done;
  if (!point_xy(g, R, x, y, ctx))
    goto done;
  if (BN_is_odd(y))
    goto done;
  uint8_t xb[32];
  if (!bn32(x, xb))
    goto done;
  ok = (memcmp(xb, sig, 32) == 0);
done:
  EC_POINT_free(P);
  EC_POINT_free(R);
  BN_free(p);
  BN_free(n);
  BN_free(r);
  BN_free(s);
  BN_free(e);
  BN_free(ne);
  BN_free(x);
  BN_free(y);
  EC_GROUP_free(g);
  BN_CTX_free(ctx);
  return ok;
}
static bool ecdh_xonly(const uint8_t priv[32], const uint8_t peer_pub[32],
                       uint8_t out[32]) {
  bool ok = false;
  BN_CTX *ctx = BN_CTX_new();
  EC_GROUP *g = group_new();
  EC_POINT *P = NULL, *S = NULL;
  BIGNUM *d = NULL, *x = NULL, *y = NULL, *n = NULL;
  if (!ctx || !g)
    goto done;
  P = EC_POINT_new(g);
  S = EC_POINT_new(g);
  d = BN_bin2bn(priv, 32, NULL);
  x = BN_new();
  y = BN_new();
  n = BN_new();
  if (!P || !S || !d || !x || !y || !n)
    goto done;
  if (!EC_GROUP_get_order(g, n, ctx) || !scalar_ok(d, n))
    goto done;
  if (!lift_x(peer_pub, P, g, ctx))
    goto done;
  if (!EC_POINT_mul(g, S, NULL, P, d, ctx))
    goto done;
  if (EC_POINT_is_at_infinity(g, S))
    goto done;
  if (!point_xy(g, S, x, y, ctx))
    goto done;
  ok = bn32(x, out);
done:
  BN_clear_free(d);
  BN_free(x);
  BN_free(y);
  BN_free(n);
  EC_POINT_free(P);
  EC_POINT_free(S);
  EC_GROUP_free(g);
  BN_CTX_free(ctx);
  return ok;
}

/* RFC8439 ChaCha20 block/cipher with counter 0 */
#define ROTL32(v, n) ((uint32_t)(((v) << (n)) | ((v) >> (32 - (n)))))
static uint32_t load32le(const uint8_t *p) {
  return ((uint32_t)p[0]) | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}
static void store32le(uint8_t *p, uint32_t v) {
  p[0] = v & 255;
  p[1] = (v >> 8) & 255;
  p[2] = (v >> 16) & 255;
  p[3] = (v >> 24) & 255;
}
#define QR(a, b, c, d)                                                         \
  do {                                                                         \
    a += b;                                                                    \
    d ^= a;                                                                    \
    d = ROTL32(d, 16);                                                         \
    c += d;                                                                    \
    b ^= c;                                                                    \
    b = ROTL32(b, 12);                                                         \
    a += b;                                                                    \
    d ^= a;                                                                    \
    d = ROTL32(d, 8);                                                          \
    c += d;                                                                    \
    b ^= c;                                                                    \
    b = ROTL32(b, 7);                                                          \
  } while (0)
static void chacha20_block(const uint8_t key[32], uint32_t counter,
                           const uint8_t nonce[12], uint8_t out[64]) {
  static const uint8_t c[16] = "expand 32-byte k";
  uint32_t x[16], w[16];
  x[0] = load32le(c);
  x[1] = load32le(c + 4);
  x[2] = load32le(c + 8);
  x[3] = load32le(c + 12);
  for (int i = 0; i < 8; i++)
    x[4 + i] = load32le(key + 4 * i);
  x[12] = counter;
  x[13] = load32le(nonce);
  x[14] = load32le(nonce + 4);
  x[15] = load32le(nonce + 8);
  memcpy(w, x, sizeof(x));
  for (int i = 0; i < 10; i++) {
    QR(w[0], w[4], w[8], w[12]);
    QR(w[1], w[5], w[9], w[13]);
    QR(w[2], w[6], w[10], w[14]);
    QR(w[3], w[7], w[11], w[15]);
    QR(w[0], w[5], w[10], w[15]);
    QR(w[1], w[6], w[11], w[12]);
    QR(w[2], w[7], w[8], w[13]);
    QR(w[3], w[4], w[9], w[14]);
  }
  for (int i = 0; i < 16; i++)
    store32le(out + 4 * i, w[i] + x[i]);
}
static void chacha20_xor(const uint8_t key[32], const uint8_t nonce[12],
                         const uint8_t *in, uint8_t *out, size_t len) {
  uint8_t block[64];
  uint32_t ctr = 0;
  size_t pos = 0;
  while (pos < len) {
    chacha20_block(key, ctr++, nonce, block);
    size_t take = (len - pos < 64) ? len - pos : 64;
    for (size_t i = 0; i < take; i++)
      out[pos + i] = in[pos + i] ^ block[i];
    pos += take;
  }
  cleanse(block, 64);
}

static size_t floor_log2_size(size_t x) {
  size_t r = 0;
  while (x >>= 1)
    r++;
  return r;
}
static size_t calc_padded_len(size_t len) {
  if (len <= 32)
    return 32;
  size_t next = ((size_t)1) << (floor_log2_size(len - 1) + 1);
  size_t chunk = (next <= 256) ? 32 : next / 8;
  return chunk * (((len - 1) / chunk) + 1);
}
static bool nip44_pad(const uint8_t *plain, size_t len, uint8_t **out,
                      size_t *outlen) {
  if (len < 1 || len > NIP44_MAX_PLAINTEXT)
    return false;
  size_t padded = calc_padded_len(len);
  size_t prefix = (len >= 65536) ? 6 : 2;
  *outlen = prefix + padded;
  *out = calloc(1, *outlen);
  if (!*out)
    return false;
  if (prefix == 2) {
    (*out)[0] = (uint8_t)(len >> 8);
    (*out)[1] = (uint8_t)len;
  } else {
    (*out)[0] = 0;
    (*out)[1] = 0;
    (*out)[2] = (uint8_t)(len >> 24);
    (*out)[3] = (uint8_t)(len >> 16);
    (*out)[4] = (uint8_t)(len >> 8);
    (*out)[5] = (uint8_t)len;
  }
  memcpy(*out + prefix, plain, len);
  return true;
}
static bool nip44_unpad(const uint8_t *padded, size_t plen, uint8_t **out,
                        size_t *outlen) {
  if (plen < 34)
    return false;
  size_t len = 0, prefix = 2;
  uint16_t first = ((uint16_t)padded[0] << 8) | padded[1];
  if (first == 0) {
    if (plen < 6)
      return false;
    len = ((size_t)padded[2] << 24) | ((size_t)padded[3] << 16) |
          ((size_t)padded[4] << 8) | padded[5];
    prefix = 6;
    if (len < 65536)
      return false;
  } else
    len = first;
  if (len < 1 || len > NIP44_MAX_PLAINTEXT)
    return false;
  if (plen != prefix + calc_padded_len(len))
    return false;
  if (prefix + len > plen)
    return false;
  *out = malloc(len + 1);
  if (!*out)
    return false;
  memcpy(*out, padded + prefix, len);
  (*out)[len] = 0;
  *outlen = len;
  return true;
}
static bool nip44_conv_key(const uint8_t priv[32], const uint8_t peer_pub[32],
                           uint8_t conv[32]) {
  uint8_t shared[32];
  if (!ecdh_xonly(priv, peer_pub, shared))
    return false;
  hkdf_extract((const uint8_t *)"nip44-v2", 8, shared, 32, conv);
  cleanse(shared, 32);
  return true;
}
static bool nip44_msg_keys(const uint8_t conv[32], const uint8_t nonce[32],
                           uint8_t ck[32], uint8_t cn[12], uint8_t hk[32]) {
  uint8_t okm[76];
  if (!hkdf_expand(conv, nonce, 32, okm, 76))
    return false;
  memcpy(ck, okm, 32);
  memcpy(cn, okm + 32, 12);
  memcpy(hk, okm + 44, 32);
  cleanse(okm, 76);
  return true;
}
static char *b64e(const uint8_t *d, size_t n) {
  size_t cap = 4 * ((n + 2) / 3) + 1;
  char *o = malloc(cap);
  if (!o)
    return NULL;
  int l = EVP_EncodeBlock((unsigned char *)o, d, (int)n);
  o[l] = 0;
  return o;
}
static uint8_t *b64d(const char *s, size_t *out) {
  size_t n = strlen(s);
  uint8_t *o = malloc(n + 1);
  if (!o)
    return NULL;
  int l = EVP_DecodeBlock(o, (const unsigned char *)s, (int)n);
  if (l < 0) {
    free(o);
    return NULL;
  }
  while (n > 0 && s[n - 1] == '=') {
    l--;
    n--;
  }
  if (l < 0) {
    free(o);
    return NULL;
  }
  *out = (size_t)l;
  return o;
}
static bool nip44_encrypt_raw(const uint8_t priv[32],
                              const uint8_t peer_pub[32],
                              const uint8_t nonce[32], const char *plaintext,
                              char **payload, char **conv_hex) {
  uint8_t conv[32], ck[32], cn[12], hk[32], mac[32];
  uint8_t *padded = NULL, *cipher = NULL, *raw = NULL;
  size_t plen = 0, clen = 0;
  bool ok = false;
  if (!nip44_conv_key(priv, peer_pub, conv))
    goto done;
  if (conv_hex)
    *conv_hex = hex_encode(conv, 32);
  if (!nip44_msg_keys(conv, nonce, ck, cn, hk))
    goto done;
  if (!nip44_pad((const uint8_t *)plaintext, strlen(plaintext), &padded, &plen))
    goto done;
  cipher = malloc(plen);
  if (!cipher)
    goto done;
  chacha20_xor(ck, cn, padded, cipher, plen);
  uint8_t *aadmsg = malloc(32 + plen);
  if (!aadmsg)
    goto done;
  memcpy(aadmsg, nonce, 32);
  memcpy(aadmsg + 32, cipher, plen);
  hmac_sha256(hk, 32, aadmsg, 32 + plen, mac);
  free(aadmsg);
  clen = 1 + 32 + plen + 32;
  raw = malloc(clen);
  if (!raw)
    goto done;
  raw[0] = 2;
  memcpy(raw + 1, nonce, 32);
  memcpy(raw + 33, cipher, plen);
  memcpy(raw + 33 + plen, mac, 32);
  *payload = b64e(raw, clen);
  ok = (*payload != NULL);
done:
  cleanse(conv, 32);
  cleanse(ck, 32);
  cleanse(cn, 12);
  cleanse(hk, 32);
  cleanse(mac, 32);
  if (padded) {
    cleanse(padded, plen);
    free(padded);
  }
  if (cipher) {
    cleanse(cipher, plen);
    free(cipher);
  }
  if (raw) {
    cleanse(raw, clen);
    free(raw);
  }
  return ok;
}
static bool nip44_decrypt_raw(const uint8_t priv[32],
                              const uint8_t peer_pub[32], const char *payload,
                              char **plaintext, char **conv_hex) {
  if (!payload || payload[0] == '#')
    return false;
  size_t rawlen = 0;
  uint8_t *raw = b64d(payload, &rawlen);
  if (!raw || rawlen < 99) {
    free(raw);
    return false;
  }
  bool ok = false;
  if (raw[0] != 2)
    goto done;
  size_t clen = rawlen - 1 - 32 - 32;
  uint8_t *nonce = raw + 1, *cipher = raw + 33, *mac = raw + 33 + clen;
  uint8_t conv[32], ck[32], cn[12], hk[32], calc[32];
  if (!nip44_conv_key(priv, peer_pub, conv))
    goto done;
  if (conv_hex)
    *conv_hex = hex_encode(conv, 32);
  if (!nip44_msg_keys(conv, nonce, ck, cn, hk))
    goto done;
  uint8_t *aadmsg = malloc(32 + clen);
  if (!aadmsg)
    goto done;
  memcpy(aadmsg, nonce, 32);
  memcpy(aadmsg + 32, cipher, clen);
  hmac_sha256(hk, 32, aadmsg, 32 + clen, calc);
  free(aadmsg);
  if (CRYPTO_memcmp(calc, mac, 32) != 0)
    goto done;
  uint8_t *padded = malloc(clen);
  if (!padded)
    goto done;
  chacha20_xor(ck, cn, cipher, padded, clen);
  uint8_t *plain = NULL;
  size_t plen = 0;
  if (!nip44_unpad(padded, clen, &plain, &plen)) {
    cleanse(padded, clen);
    free(padded);
    goto done;
  }
  *plaintext = xstrndup((char *)plain, plen);
  cleanse(plain, plen);
  free(plain);
  cleanse(padded, clen);
  free(padded);
  ok = (*plaintext != NULL);
done:
  free(raw);
  return ok;
}

/* Vault */
static const char *passphrase(void) {
  const char *p = getenv("DAMAGE_NSECBUNKER_VAULT_PASSPHRASE");
  return (p && *p) ? p : NULL;
}
static bool derive(const char *pass, const uint8_t salt[SALT_LEN],
                   uint8_t key[KEY_LEN]) {
  return PKCS5_PBKDF2_HMAC(pass, (int)strlen(pass), salt, SALT_LEN,
                           VAULT_ITERATIONS, EVP_sha256(), KEY_LEN, key) == 1;
}
static bool gcm_enc(const uint8_t key[32], const uint8_t iv[12],
                    const uint8_t *pt, int pl, uint8_t **ct, int *cl,
                    uint8_t tag[16]) {
  EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
  if (!c)
    return false;
  bool ok = false;
  int l = 0;
  *ct = malloc((size_t)pl + 16);
  if (!*ct)
    goto done;
  if (EVP_EncryptInit_ex(c, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1)
    goto done;
  if (EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1)
    goto done;
  if (EVP_EncryptInit_ex(c, NULL, NULL, key, iv) != 1)
    goto done;
  if (EVP_EncryptUpdate(c, *ct, &l, pt, pl) != 1)
    goto done;
  *cl = l;
  if (EVP_EncryptFinal_ex(c, *ct + *cl, &l) != 1)
    goto done;
  *cl += l;
  if (EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_GCM_GET_TAG, 16, tag) != 1)
    goto done;
  ok = true;
done:
  if (!ok && *ct) {
    free(*ct);
    *ct = NULL;
  }
  EVP_CIPHER_CTX_free(c);
  return ok;
}
static bool gcm_dec(const uint8_t key[32], const uint8_t iv[12],
                    const uint8_t *ct, int cl, const uint8_t tag[16],
                    uint8_t **pt, int *pl) {
  EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
  if (!c)
    return false;
  bool ok = false;
  int l = 0;
  *pt = malloc((size_t)cl + 1);
  if (!*pt)
    goto done;
  if (EVP_DecryptInit_ex(c, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1)
    goto done;
  if (EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1)
    goto done;
  if (EVP_DecryptInit_ex(c, NULL, NULL, key, iv) != 1)
    goto done;
  if (EVP_DecryptUpdate(c, *pt, &l, ct, cl) != 1)
    goto done;
  *pl = l;
  if (EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_GCM_SET_TAG, 16, (void *)tag) != 1)
    goto done;
  if (EVP_DecryptFinal_ex(c, *pt + *pl, &l) != 1)
    goto done;
  *pl += l;
  (*pt)[*pl] = 0;
  ok = true;
done:
  if (!ok && *pt) {
    free(*pt);
    *pt = NULL;
  }
  EVP_CIPHER_CTX_free(c);
  return ok;
}
static bool save_vault(const char *path, struct vault *v) {
  const char *pass = passphrase();
  if (!pass) {
    err_msg("missing_DAMAGE_NSECBUNKER_VAULT_PASSPHRASE");
    return false;
  }
  char *priv = hex_encode(v->priv, 32);
  if (!priv)
    return false;
  char plain[512];
  snprintf(plain, sizeof(plain),
           "{\"privkey_hex\":\"%s\",\"pubkey_hex\":\"%s\",\"npub\":\"%s\"}",
           priv, v->pub, v->npub);
  cleanse(priv, strlen(priv));
  free(priv);
  uint8_t salt[SALT_LEN], iv[IV_LEN], key[KEY_LEN], tag[TAG_LEN], *ct = NULL;
  int cl = 0;
  if (RAND_bytes(salt, SALT_LEN) != 1 || RAND_bytes(iv, IV_LEN) != 1) {
    err_msg("vault_random_failed");
    return false;
  }
  if (!derive(pass, salt, key)) {
    err_msg("vault_kdf_failed");
    return false;
  }
  if (!gcm_enc(key, iv, (uint8_t *)plain, (int)strlen(plain), &ct, &cl, tag)) {
    err_msg("vault_encrypt_failed");
    return false;
  }
  char *sh = hex_encode(salt, SALT_LEN), *ih = hex_encode(iv, IV_LEN),
       *th = hex_encode(tag, TAG_LEN), *ch = hex_encode(ct, (size_t)cl);
  size_t cap = strlen(ch) + 512;
  char *out = malloc(cap);
  snprintf(out, cap,
           "{\"v\":2,\"backend\":\"damage-nsecbunker-crypto-c\",\"phase\":"
           "\"2c\",\"kdf\":\"pbkdf2-hmac-sha256\",\"iterations\":%d,\"cipher\":"
           "\"aes-256-gcm\",\"salt\":\"%s\",\"iv\":\"%s\",\"tag\":\"%s\","
           "\"ciphertext\":\"%s\"}\n",
           VAULT_ITERATIONS, sh, ih, th, ch);
  bool ok = write_file(path, out, strlen(out));
  if (!ok)
    err_msg("vault_write_failed");
  cleanse(key, KEY_LEN);
  cleanse(plain, strlen(plain));
  cleanse(ct, (size_t)cl);
  free(ct);
  free(sh);
  free(ih);
  free(th);
  free(ch);
  free(out);
  return ok;
}
static bool load_vault(const char *path, struct vault *v) {
  memset(v, 0, sizeof(*v));
  const char *pass = passphrase();
  if (!pass) {
    err_msg("missing_DAMAGE_NSECBUNKER_VAULT_PASSPHRASE");
    return false;
  }
  char *file = slurp_file(path, NULL);
  if (!file) {
    err_msg("vault_read_failed");
    return false;
  }
  char *sh = json_get_string(file, "salt"), *ih = json_get_string(file, "iv"),
       *th = json_get_string(file, "tag"),
       *ch = json_get_string(file, "ciphertext");
  if (!sh || !ih || !th || !ch) {
    err_msg("vault_missing_fields");
    goto fail;
  }
  size_t cl = strlen(ch) / 2;
  uint8_t salt[SALT_LEN], iv[IV_LEN], tag[TAG_LEN], key[KEY_LEN],
      *ct = malloc(cl), *pt = NULL;
  int pl = 0;
  if (!ct) {
    err_msg("oom");
    goto fail;
  }
  if (!hex_decode(sh, salt, SALT_LEN) || !hex_decode(ih, iv, IV_LEN) ||
      !hex_decode(th, tag, TAG_LEN) || !hex_decode(ch, ct, cl)) {
    err_msg("vault_hex_decode_failed");
    goto fail2;
  }
  if (!derive(pass, salt, key)) {
    err_msg("vault_kdf_failed");
    goto fail2;
  }
  if (!gcm_dec(key, iv, ct, (int)cl, tag, &pt, &pl)) {
    err_msg("vault_decrypt_failed");
    goto fail2;
  }
  char *priv = json_get_string((char *)pt, "privkey_hex"),
       *pub = json_get_string((char *)pt, "pubkey_hex"),
       *np = json_get_string((char *)pt, "npub");
  if (!priv || !pub || !np || !hex64(priv) || !hex64(pub)) {
    err_msg("vault_plaintext_invalid");
    free(priv);
    free(pub);
    free(np);
    goto fail3;
  }
  hex_decode(priv, v->priv, 32);
  snprintf(v->pub, sizeof(v->pub), "%s", pub);
  snprintf(v->npub, sizeof(v->npub), "%s", np);
  cleanse(priv, strlen(priv));
  free(priv);
  free(pub);
  free(np);
  cleanse(pt, (size_t)pl);
  free(pt);
  cleanse(key, KEY_LEN);
  cleanse(ct, cl);
  free(ct);
  free(sh);
  free(ih);
  free(th);
  free(ch);
  free(file);
  return true;
fail3:
  if (pt) {
    cleanse(pt, (size_t)pl);
    free(pt);
  }
fail2:
  cleanse(key, KEY_LEN);
  if (ct) {
    cleanse(ct, cl);
    free(ct);
  }
fail:
  free(sh);
  free(ih);
  free(th);
  free(ch);
  free(file);
  return false;
}

static char *vault_path(char *json) {
  char *p = json_get_string(json, "vault_path");
  if (p)
    return p;
  const char *e = getenv("DAMAGE_NSECBUNKER_VAULT_PATH");
  return (e && *e) ? xstrndup(e, strlen(e)) : NULL;
}
static bool plain_test_allowed(void) {
  const char *prod = getenv("DAMAGE_NSECBUNKER_PRODUCTION");
  if (prod && strcmp(prod, "1") == 0)
    return false;
  const char *test = getenv("DAMAGE_NSECBUNKER_TEST_MODE");
  const char *plain = getenv("DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44");
  return test && strcmp(test, "1") == 0 && plain && strcmp(plain, "1") == 0;
}

/* Ops */
static bool op_health(void) {
  ok_obj(
      "{\"protocol\":\"damage-nsecbunker-crypto-v1\",\"backend\":\"damage-"
      "nsecbunker-crypto-c\",\"phase\":\"2c\",\"crypto\":\"openssl-secp256k1-"
      "bip340-nip44v2\",\"mode\":\"vector-hardened\",\"nip44\":\"v2\"}");
  return true;
}
static bool op_generate(char *json) {
  char *path = vault_path(json);
  if (!path) {
    err_msg("missing_vault_path");
    return false;
  }
  struct vault v;
  uint8_t pub[32];
  if (!keygen(v.priv, pub)) {
    free(path);
    err_msg("key_generation_failed");
    return false;
  }
  char *ph = hex_encode(pub, 32), *np = npub_encode(pub);
  snprintf(v.pub, sizeof(v.pub), "%s", ph);
  snprintf(v.npub, sizeof(v.npub), "%s", np);
  bool ok = save_vault(path, &v);
  if (ok)
    printf("{\"ok\":true,\"result\":{\"pubkey_hex\":\"%s\",\"npub\":\"%s\","
           "\"vault_written\":true}}\n",
           ph, np);
  cleanse(&v, sizeof(v));
  free(path);
  free(ph);
  free(np);
  return ok;
}
static bool op_public(char *json) {
  char *path = vault_path(json);
  if (!path) {
    err_msg("missing_vault_path");
    return false;
  }
  struct vault v;
  bool ok = load_vault(path, &v);
  if (ok)
    printf("{\"ok\":true,\"result\":{\"pubkey_hex\":\"%s\",\"npub\":\"%s\"}}\n",
           v.pub, v.npub);
  cleanse(&v, sizeof(v));
  free(path);
  return ok;
}
static bool op_npub(char *json) {
  char *p = json_get_string(json, "pubkey_hex");
  if (!hex64(p)) {
    free(p);
    err_msg("invalid_pubkey_hex");
    return false;
  }
  strlower(p);
  uint8_t pub[32];
  hex_decode(p, pub, 32);
  char *np = npub_encode(pub);
  printf("{\"ok\":true,\"result\":{\"npub\":\"%s\"}}\n", np);
  free(p);
  free(np);
  return true;
}
static bool serialize_event(char *event, const char *pub_override,
                            char **ser_out) {
  char *ep = json_get_string(event, "pubkey");
  const char *pub =
      (pub_override && *pub_override) ? pub_override : (ep ? ep : "");
  char *created = json_get_raw_value(event, "created_at"),
       *kind = json_get_raw_value(event, "kind"),
       *tags = json_get_raw_value(event, "tags"),
       *content = json_get_raw_value(event, "content");
  if (!created || !kind || !content) {
    free(ep);
    free(created);
    free(kind);
    free(tags);
    free(content);
    return false;
  }
  if (!tags)
    tags = xstrndup("[]", 2);
  size_t sl = strlen(pub) + strlen(created) + strlen(kind) + strlen(tags) +
              strlen(content) + 64;
  char *ser = malloc(sl);
  snprintf(ser, sl, "[0,\"%s\",%s,%s,%s,%s]", pub, created, kind, tags,
           content);
  *ser_out = ser;
  free(ep);
  free(created);
  free(kind);
  free(tags);
  free(content);
  return true;
}
static bool op_event_id(char *json) {
  char *event = json_get_object(json, "event"),
       *pub = json_get_string(json, "pubkey_hex"), *ser = NULL;
  if (!event) {
    free(pub);
    err_msg("missing_event");
    return false;
  }
  if (!serialize_event(event, pub, &ser)) {
    free(event);
    free(pub);
    err_msg("event_missing_required_fields");
    return false;
  }
  uint8_t id[32];
  sha256_bytes((uint8_t *)ser, strlen(ser), id);
  char *idh = hex_encode(id, 32), *esc = json_escape(ser);
  printf("{\"ok\":true,\"result\":{\"id\":\"%s\",\"serialization\":\"%s\"}}\n",
         idh, esc);
  free(event);
  free(pub);
  free(ser);
  free(idh);
  free(esc);
  return true;
}
static bool op_sign(char *json) {
  char *path = vault_path(json);
  char *event = json_get_object(json, "event");
  if (!path || !event) {
    free(path);
    free(event);
    err_msg("missing_vault_path_or_event");
    return false;
  }
  struct vault v;
  if (!load_vault(path, &v)) {
    free(path);
    free(event);
    return false;
  }
  char *ep = json_get_string(event, "pubkey");
  if (ep && *ep && strcmp(ep, v.pub) != 0) {
    free(ep);
    free(path);
    free(event);
    cleanse(&v, sizeof(v));
    err_msg("event_pubkey_mismatch");
    return false;
  }
  free(ep);
  char *ser = NULL;
  if (!serialize_event(event, v.pub, &ser)) {
    err_msg("event_missing_required_fields");
    free(path);
    free(event);
    cleanse(&v, sizeof(v));
    return false;
  }
  uint8_t id[32], sig[64];
  sha256_bytes((uint8_t *)ser, strlen(ser), id);
  if (!schnorr_sign_random(v.priv, id, sig)) {
    err_msg("schnorr_sign_failed");
    free(path);
    free(event);
    free(ser);
    cleanse(&v, sizeof(v));
    return false;
  }
  char *created = json_get_raw_value(event, "created_at"),
       *kind = json_get_raw_value(event, "kind"),
       *tags = json_get_raw_value(event, "tags"),
       *content = json_get_raw_value(event, "content");
  if (!tags)
    tags = xstrndup("[]", 2);
  char *idh = hex_encode(id, 32), *sigh = hex_encode(sig, 64);
  printf("{\"ok\":true,\"result\":{\"event\":{\"id\":\"%s\",\"pubkey\":\"%s\","
         "\"created_at\":%s,\"kind\":%s,\"tags\":%s,\"content\":%s,\"sig\":\"%"
         "s\"}}}\n",
         idh, v.pub, created, kind, tags, content, sigh);
  cleanse(sig, 64);
  free(idh);
  free(sigh);
  free(path);
  free(event);
  free(created);
  free(kind);
  free(tags);
  free(content);
  free(ser);
  cleanse(&v, sizeof(v));
  return true;
}
static bool op_schnorr_sign_vector(char *json) {
  char *sec = json_get_string(json, "secret_key_hex"),
       *msg = json_get_string(json, "message_hex"),
       *aux = json_get_string(json, "aux_rand_hex");
  if (!hex_len(sec, 32) || !hex_len(msg, 32) || !hex_len(aux, 32)) {
    free(sec);
    free(msg);
    free(aux);
    err_msg("invalid_schnorr_vector_input");
    return false;
  }
  uint8_t sk[32], m[32], a[32], pub[32], sig[64];
  hex_decode(sec, sk, 32);
  hex_decode(msg, m, 32);
  hex_decode(aux, a, 32);
  bool ok = schnorr_sign_aux(sk, m, a, pub, sig);
  if (!ok) {
    err_msg("schnorr_sign_vector_failed");
    goto done;
  }
  char *ph = hex_encode(pub, 32), *sh = hex_encode(sig, 64);
  printf("{\"ok\":true,\"result\":{\"pubkey_hex\":\"%s\",\"signature_hex\":\"%"
         "s\"}}\n",
         ph, sh);
  free(ph);
  free(sh);
done:
  cleanse(sk, 32);
  cleanse(a, 32);
  cleanse(sig, 64);
  free(sec);
  free(msg);
  free(aux);
  return ok;
}
static bool op_schnorr_verify(char *json) {
  char *pub = json_get_string(json, "pubkey_hex"),
       *msg = json_get_string(json, "message_hex"),
       *sig = json_get_string(json, "signature_hex");
  if (!hex_len(pub, 32) || !hex_len(msg, 32) || !hex_len(sig, 64)) {
    free(pub);
    free(msg);
    free(sig);
    err_msg("invalid_schnorr_verify_input");
    return false;
  }
  uint8_t p[32], m[32], s[64];
  hex_decode(pub, p, 32);
  hex_decode(msg, m, 32);
  hex_decode(sig, s, 64);
  bool valid = schnorr_verify(p, m, s);
  printf("{\"ok\":true,\"result\":{\"valid\":%s}}\n", valid ? "true" : "false");
  free(pub);
  free(msg);
  free(sig);
  return true;
}
static bool op_nip44_encrypt_vector(char *json) {
  char *sec = json_get_string(json, "secret_key_hex"),
       *peer = json_get_string(json, "peer_pubkey_hex"),
       *nonce = json_get_string(json, "nonce_hex"),
       *plain = json_get_string(json, "plaintext");
  if (!hex_len(sec, 32) || !hex_len(peer, 32) || !hex_len(nonce, 32) ||
      !plain) {
    free(sec);
    free(peer);
    free(nonce);
    free(plain);
    err_msg("invalid_nip44_vector_input");
    return false;
  }
  uint8_t sk[32], pk[32], n[32];
  hex_decode(sec, sk, 32);
  hex_decode(peer, pk, 32);
  hex_decode(nonce, n, 32);
  char *payload = NULL, *conv = NULL;
  bool ok = nip44_encrypt_raw(sk, pk, n, plain, &payload, &conv);
  if (ok) {
    char *esc = json_escape(payload);
    printf("{\"ok\":true,\"result\":{\"conversation_key\":\"%s\",\"payload\":"
           "\"%s\"}}\n",
           conv, esc);
    free(esc);
  } else
    err_msg("nip44_encrypt_vector_failed");
  cleanse(sk, 32);
  free(sec);
  free(peer);
  free(nonce);
  cleanse(plain, strlen(plain));
  free(plain);
  free(payload);
  free(conv);
  return ok;
}
static bool op_nip44_decrypt_vector(char *json) {
  char *sec = json_get_string(json, "secret_key_hex"),
       *peer = json_get_string(json, "peer_pubkey_hex"),
       *payload = json_get_string(json, "payload");
  if (!hex_len(sec, 32) || !hex_len(peer, 32) || !payload) {
    free(sec);
    free(peer);
    free(payload);
    err_msg("invalid_nip44_decrypt_vector_input");
    return false;
  }
  uint8_t sk[32], pk[32];
  hex_decode(sec, sk, 32);
  hex_decode(peer, pk, 32);
  char *plain = NULL, *conv = NULL;
  bool ok = nip44_decrypt_raw(sk, pk, payload, &plain, &conv);
  if (ok) {
    char *esc = json_escape(plain);
    printf("{\"ok\":true,\"result\":{\"conversation_key\":\"%s\",\"plaintext\":"
           "\"%s\"}}\n",
           conv, esc);
    free(esc);
  } else
    err_msg("nip44_decrypt_vector_failed");
  cleanse(sk, 32);
  free(sec);
  free(peer);
  free(payload);
  if (plain) {
    cleanse(plain, strlen(plain));
    free(plain);
  }
  free(conv);
  return ok;
}
static bool op_nip44_encrypt(char *json) {
  if (plain_test_allowed()) {
    char *p = json_get_string(json, "plaintext");
    if (!p) {
      err_msg("missing_plaintext");
      return false;
    }
    char *b = b64e((uint8_t *)p, strlen(p));
    printf("{\"ok\":true,\"result\":{\"ciphertext\":\"plain:%s\"}}\n", b);
    cleanse(p, strlen(p));
    free(p);
    free(b);
    return true;
  }
  char *path = vault_path(json),
       *client = json_get_string(json, "client_pubkey"),
       *plain = json_get_string(json, "plaintext");
  if (!path || !hex64(client) || !plain) {
    free(path);
    free(client);
    free(plain);
    err_msg("missing_vault_path_client_pubkey_or_plaintext");
    return false;
  }
  struct vault v;
  if (!load_vault(path, &v)) {
    free(path);
    free(client);
    free(plain);
    return false;
  }
  uint8_t peer[32], nonce[32];
  hex_decode(client, peer, 32);
  if (RAND_bytes(nonce, 32) != 1) {
    err_msg("nonce_random_failed");
    cleanse(&v, sizeof(v));
    free(path);
    free(client);
    free(plain);
    return false;
  }
  char *payload = NULL, *conv = NULL;
  bool ok = nip44_encrypt_raw(v.priv, peer, nonce, plain, &payload, &conv);
  if (ok) {
    char *esc = json_escape(payload);
    printf(
        "{\"ok\":true,\"result\":{\"ciphertext\":\"%s\",\"nip44\":\"v2\"}}\n",
        esc);
    free(esc);
  } else
    err_msg("nip44_encrypt_failed");
  cleanse(&v, sizeof(v));
  free(path);
  free(client);
  cleanse(plain, strlen(plain));
  free(plain);
  free(payload);
  free(conv);
  return ok;
}
static bool op_nip44_decrypt(char *json) {
  char *c = json_get_string(json, "ciphertext");
  if (plain_test_allowed() && c && strncmp(c, "plain:", 6) == 0) {
    size_t n = 0;
    uint8_t *p = b64d(c + 6, &n);
    if (!p) {
      free(c);
      err_msg("base64_decode_failed");
      return false;
    }
    char *tmp = xstrndup((char *)p, n), *esc = json_escape(tmp);
    printf("{\"ok\":true,\"result\":{\"plaintext\":\"%s\"}}\n", esc);
    cleanse(p, n);
    free(p);
    cleanse(tmp, n);
    free(tmp);
    free(esc);
    free(c);
    return true;
  }
  char *path = vault_path(json),
       *client = json_get_string(json, "client_pubkey");
  if (!path || !hex64(client) || !c) {
    free(path);
    free(client);
    free(c);
    err_msg("missing_vault_path_client_pubkey_or_ciphertext");
    return false;
  }
  struct vault v;
  if (!load_vault(path, &v)) {
    free(path);
    free(client);
    free(c);
    return false;
  }
  uint8_t peer[32];
  hex_decode(client, peer, 32);
  char *plain = NULL, *conv = NULL;
  bool ok = nip44_decrypt_raw(v.priv, peer, c, &plain, &conv);
  if (ok) {
    char *esc = json_escape(plain);
    printf("{\"ok\":true,\"result\":{\"plaintext\":\"%s\",\"nip44\":\"v2\"}}\n",
           esc);
    free(esc);
  } else
    err_msg("nip44_decrypt_failed");
  cleanse(&v, sizeof(v));
  free(path);
  free(client);
  free(c);
  if (plain) {
    cleanse(plain, strlen(plain));
    free(plain);
  }
  free(conv);
  return ok;
}
static bool op_plain_mode_status(void) {
  printf("{\"ok\":true,\"result\":{\"plain_allowed\":%s,\"production\":%s}}\n",
         plain_test_allowed() ? "true" : "false",
         (getenv("DAMAGE_NSECBUNKER_PRODUCTION") &&
          strcmp(getenv("DAMAGE_NSECBUNKER_PRODUCTION"), "1") == 0)
             ? "true"
             : "false");
  return true;
}

int main(void) {
  char *json = slurp_stdin();
  if (!json) {
    err_msg("stdin_read_failed");
    return 1;
  }
  char *op = json_get_string(json, "op");
  if (!op) {
    err_msg("missing_op");
    free(json);
    return 1;
  }
  bool ok = false;
  if (strcmp(op, "health") == 0)
    ok = op_health();
  else if (strcmp(op, "generate_identity") == 0)
    ok = op_generate(json);
  else if (strcmp(op, "get_public_key") == 0)
    ok = op_public(json);
  else if (strcmp(op, "npub") == 0)
    ok = op_npub(json);
  else if (strcmp(op, "event_id") == 0)
    ok = op_event_id(json);
  else if (strcmp(op, "sign_event") == 0)
    ok = op_sign(json);
  else if (strcmp(op, "schnorr_sign_vector") == 0)
    ok = op_schnorr_sign_vector(json);
  else if (strcmp(op, "schnorr_verify") == 0)
    ok = op_schnorr_verify(json);
  else if (strcmp(op, "nip44_encrypt_vector") == 0)
    ok = op_nip44_encrypt_vector(json);
  else if (strcmp(op, "nip44_decrypt_vector") == 0)
    ok = op_nip44_decrypt_vector(json);
  else if (strcmp(op, "nip44_encrypt") == 0)
    ok = op_nip44_encrypt(json);
  else if (strcmp(op, "nip44_decrypt") == 0)
    ok = op_nip44_decrypt(json);
  else if (strcmp(op, "plain_mode_status") == 0)
    ok = op_plain_mode_status();
  else {
    err_msg("unsupported_op");
    ok = false;
  }
  free(op);
  free(json);
  return ok ? 0 : 2;
}
