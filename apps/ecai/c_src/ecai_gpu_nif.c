// Build with nvcc (via port_compiler CC override). Pure C + CUDA runtime API.
#include "erl_nif.h"
#include <stdint.h>
#include <string.h>
#include <cuda_runtime.h>
#define NIL 0xFFFFFFFFu

typedef struct {
  unsigned next;           // index of next slab, or NIL
  unsigned count;          // number of docIds in data[]
  uint32_t data[];         // length = SLAB_SIZE
} Slab;

typedef struct {
  unsigned  num_terms;
  unsigned  slab_size;
  unsigned  max_slabs;
  unsigned  slab_top;      // atomic allocation pointer

  // per-term head/tail slab indices
  unsigned *heads;         // len = num_terms (NIL if empty)
  unsigned *tails;         // len = num_terms (NIL if empty)

  Slab    **slabs;         // array of pointers to Slab (len = max_slabs)
} DynIndex;
/* ---------------- Resource & Device Index ---------------- */

typedef struct {
  uint32_t *d_offsets;    // Unified memory: len = T+1
  uint32_t *d_postings;   // Unified memory: len = P
  uint32_t *d_df;         // Unified memory: len = T
  uint32_t  num_terms;
  uint32_t  num_postings;

  uint32_t *h_offsets;    // Host mirror of offsets (malloc/enif_alloc)
} DeviceIndex;

static ErlNifResourceType* RES_TYPE = NULL;

static void res_dtor(ErlNifEnv* env, void* obj) {
  DeviceIndex* di = (DeviceIndex*)obj;
  if (!di) return;
  if (di->d_offsets)  cudaFree(di->d_offsets);
  if (di->d_postings) cudaFree(di->d_postings);
  if (di->d_df)       cudaFree(di->d_df);
  if (di->h_offsets)  enif_free(di->h_offsets);
}

/* ---------------- Small helpers ---------------- */

static int map_get_bin(ErlNifEnv* env, ERL_NIF_TERM map, const char* key_atom, ErlNifBinary* out_bin) {
  ERL_NIF_TERM key = enif_make_atom(env, key_atom);
  ERL_NIF_TERM val;
  if (!enif_get_map_value(env, map, key, &val)) return 0;
  return enif_inspect_binary(env, val, out_bin);
}

static ERL_NIF_TERM make_error(ErlNifEnv* env, const char* atom) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, atom));
}

/* ---------------- NIF: load_compact(Map) -> {ok, Handle} | {error,_} ---------------- */

static ERL_NIF_TERM load_compact_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  if (argc != 1 || !enif_is_map(env, argv[0])) {
    return enif_make_badarg(env);
  }

  ErlNifBinary off_bin, post_bin, df_bin;
  if (!map_get_bin(env, argv[0], "offsets", &off_bin)) return enif_make_badarg(env);
  if (!map_get_bin(env, argv[0], "postings", &post_bin)) return enif_make_badarg(env);
  if (!map_get_bin(env, argv[0], "df", &df_bin)) return enif_make_badarg(env);

  if (off_bin.size < 8 || (off_bin.size % 4) != 0) return make_error(env, "bad_offsets");
  if ((post_bin.size % 4) != 0) return make_error(env, "bad_postings");
  if ((df_bin.size % 4) != 0) return make_error(env, "bad_df");

  uint32_t T = (uint32_t)(off_bin.size / 4 - 1);
  uint32_t P = (uint32_t)(post_bin.size / 4);
  uint32_t DF = (uint32_t)(df_bin.size / 4);
  if (DF != T) return make_error(env, "df_len_mismatch");

  DeviceIndex* di = (DeviceIndex*)enif_alloc_resource(RES_TYPE, sizeof(DeviceIndex));
  if (!di) return make_error(env, "alloc_resource_failed");
  memset(di, 0, sizeof(DeviceIndex));
  di->num_terms    = T;
  di->num_postings = P;

  cudaError_t err;

  /* CUDA Unified Memory allocations (CUDA 11/12+ signature) */
  err = cudaMallocManaged((void**)&di->d_offsets,
                          (size_t)((uint64_t)(T + 1) * sizeof(uint32_t)),
                          cudaMemAttachGlobal);
  if (err != cudaSuccess) { enif_release_resource(di); return make_error(env, "cuda_alloc_offsets"); }

  err = cudaMallocManaged((void**)&di->d_postings,
                          (size_t)((uint64_t)P * sizeof(uint32_t)),
                          cudaMemAttachGlobal);
  if (err != cudaSuccess) { res_dtor(env, di); enif_release_resource(di); return make_error(env, "cuda_alloc_postings"); }

  err = cudaMallocManaged((void**)&di->d_df,
                          (size_t)((uint64_t)T * sizeof(uint32_t)),
                          cudaMemAttachGlobal);
  if (err != cudaSuccess) { res_dtor(env, di); enif_release_resource(di); return make_error(env, "cuda_alloc_df"); }

  /* Copy from BEAM binaries into Unified Memory */
  memcpy(di->d_offsets,  off_bin.data,  off_bin.size);
  memcpy(di->d_postings, post_bin.data, post_bin.size);
  memcpy(di->d_df,       df_bin.data,   df_bin.size);

  /* Host mirror of offsets for quick range lookup without device access */
  di->h_offsets = (uint32_t*)enif_alloc(off_bin.size);
  if (!di->h_offsets) { res_dtor(env, di); enif_release_resource(di); return make_error(env, "host_alloc_offsets"); }
  memcpy(di->h_offsets, off_bin.data, off_bin.size);

  ERL_NIF_TERM handle = enif_make_resource(env, di);
  enif_release_resource(di);
  return enif_make_tuple2(env, enif_make_atom(env, "ok"), handle);
}

/* ---------------- NIF: get_postings(Handle, TermId) -> binary<uint32_le> ---------------- */

static ERL_NIF_TERM get_postings_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  DeviceIndex* di;
  unsigned term_id_u;

  if (argc != 2) return enif_make_badarg(env);
  if (!enif_get_resource(env, argv[0], RES_TYPE, (void**)&di)) return enif_make_badarg(env);
  if (!enif_get_uint(env, argv[1], &term_id_u)) return enif_make_badarg(env);
  if (term_id_u >= di->num_terms) return enif_make_binary(env, &(ErlNifBinary){0});

  uint32_t tid   = (uint32_t)term_id_u;
  uint32_t start = di->h_offsets[tid];
  uint32_t end   = di->h_offsets[tid + 1];
  if (end <= start) {
    ErlNifBinary out = {0};
    enif_alloc_binary(0, &out);
    return enif_make_binary(env, &out);
  }

  uint32_t count = end - start;
  const uint32_t* src = di->d_postings + start;

  /* Return a packed binary of little-endian uint32 docIds */
  ErlNifBinary out;
  if (!enif_alloc_binary((size_t)count * sizeof(uint32_t), &out)) {
    return make_error(env, "alloc_binary_failed");
  }
  memcpy(out.data, src, (size_t)count * sizeof(uint32_t));
  return enif_make_binary(env, &out);
}

// --------- helpers ----------
static __device__ __host__ inline unsigned atomic_inc_u32(unsigned* p) {
  #if defined(__CUDA_ARCH__)
    return atomicAdd(p, 1);
  #else
    unsigned v = *p; *p = v + 1; return v;
  #endif
}

// --------- Dynamic index resource ----------
typedef struct {
  DynIndex *ix;  // Unified memory
} DynHandle;

static ErlNifResourceType* RES_DYN = NULL;

static void dyn_dtor(ErlNifEnv* env, void* obj) {
  DynHandle *h = (DynHandle*)obj;
  if (!h || !h->ix) return;
  DynIndex* ix = h->ix;
  if (ix->slabs)   cudaFree(ix->slabs);
  if (ix->heads)   cudaFree(ix->heads);
  if (ix->tails)   cudaFree(ix->tails);
  for (unsigned i=0; i<ix->max_slabs; ++i) if (ix->slabs[i]) cudaFree(ix->slabs[i]);
  cudaFree(ix);
}

// new_dynamic(Terms, SlabSize, MaxSlabs) -> {ok, Handle}
static ERL_NIF_TERM new_dynamic_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  unsigned T, SL, MS;
  if (argc != 3 || !enif_get_uint(env, argv[0], &T) ||
      !enif_get_uint(env, argv[1], &SL) || !enif_get_uint(env, argv[2], &MS) ||
      T==0 || SL==0 || MS==0) return enif_make_badarg(env);

  DynHandle* h = enif_alloc_resource(RES_DYN, sizeof(DynHandle));
  memset(h, 0, sizeof(*h));

  cudaMallocManaged((void**)&h->ix, sizeof(DynIndex), cudaMemAttachGlobal);
  DynIndex* ix = h->ix;
  ix->num_terms = T; ix->slab_size = SL; ix->max_slabs = MS; ix->slab_top = 0;

  cudaMallocManaged((void**)&ix->heads, sizeof(unsigned)*T, cudaMemAttachGlobal);
  cudaMallocManaged((void**)&ix->tails, sizeof(unsigned)*T, cudaMemAttachGlobal);
  cudaMallocManaged((void**)&ix->slabs, sizeof(Slab*)*MS, cudaMemAttachGlobal);

  for (unsigned i=0;i<T;i++){ ix->heads[i]=NIL; ix->tails[i]=NIL; }
  for (unsigned i=0;i<MS;i++){ ix->slabs[i]=NULL; }

  ERL_NIF_TERM handle = enif_make_resource(env, h);
  enif_release_resource(h);
  return enif_make_tuple2(env, enif_make_atom(env,"ok"), handle);
}

// append(Handle, Tid, DocInt) -> ok
static ERL_NIF_TERM append_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  DynHandle* h; unsigned tid; unsigned doc;
  if (argc!=3 || !enif_get_resource(env, argv[0], RES_DYN, (void**)&h) ||
      !enif_get_uint(env, argv[1], &tid) || !enif_get_uint(env, argv[2], &doc))
    return enif_make_badarg(env);
  DynIndex* ix = h->ix;
  if (tid >= ix->num_terms) return enif_make_badarg(env);

  unsigned tail = ix->tails[tid];
  Slab* s = (tail==NIL) ? NULL : ix->slabs[tail];

  if (!s || s->count >= ix->slab_size) {
    // allocate new slab
    unsigned idx = atomic_inc_u32(&ix->slab_top);
    if (idx >= ix->max_slabs) return enif_make_tuple2(env, enif_make_atom(env,"error"), enif_make_atom(env,"out_of_slabs"));
    cudaMallocManaged((void**)&ix->slabs[idx],
                      sizeof(Slab) + sizeof(uint32_t)*ix->slab_size,
                      cudaMemAttachGlobal);
    s = ix->slabs[idx];
    s->next = NIL; s->count = 0;
    if (tail==NIL) ix->heads[tid]=idx; else ix->slabs[tail]->next = idx;
    ix->tails[tid]=idx;
  }
  s->data[s->count++] = doc;
  return enif_make_atom(env, "ok");
}

// get_postings(Handle, Tid) -> binary
static ERL_NIF_TERM get_postings_dyn_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  DynHandle* h; unsigned tid;
  if (argc!=2 || !enif_get_resource(env, argv[0], RES_DYN, (void**)&h) ||
      !enif_get_uint(env, argv[1], &tid)) return enif_make_badarg(env);
  DynIndex* ix = h->ix; if (tid >= ix->num_terms) { ErlNifBinary b; enif_alloc_binary(0,&b); return enif_make_binary(env,&b); }

  // Count total
  unsigned total=0; unsigned cur = ix->heads[tid];
  while (cur!=NIL) { total += ix->slabs[cur]->count; cur = ix->slabs[cur]->next; }

  ErlNifBinary out; enif_alloc_binary((size_t)total * 4, &out);
  uint32_t* dst = (uint32_t*)out.data;
  cur = ix->heads[tid];
  while (cur!=NIL) {
    Slab* s = ix->slabs[cur];
    memcpy(dst, s->data, (size_t)s->count * 4);
    dst += s->count;
    cur = s->next;
  }
  return enif_make_binary(env, &out);
}

// free(Handle)
static ERL_NIF_TERM free_dyn_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  DynHandle* h; if (argc!=1 || !enif_get_resource(env, argv[0], RES_DYN, (void**)&h)) return enif_make_badarg(env);
  enif_keep_resource(h); dyn_dtor(env, h); enif_release_resource(h); return enif_make_atom(env,"ok");
}

/* ---------------- NIF: free(Handle) -> ok ---------------- */

static ERL_NIF_TERM free_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  DeviceIndex* di;
  if (argc != 1 || !enif_get_resource(env, argv[0], RES_TYPE, (void**)&di)) {
    return enif_make_badarg(env);
  }
  /* Run the destructor now */
  enif_keep_resource(di);
  res_dtor(env, di);
  enif_release_resource(di);
  return enif_make_atom(env, "ok");
}


/* ---------------- NIF init ---------------- */

static int nif_reload(ErlNifEnv* env, void** priv, ERL_NIF_TERM info) { return 0; }
static int nif_upgrade(ErlNifEnv* env, void** priv, void** old_priv, ERL_NIF_TERM info){ return 0; }
static void nif_unload(ErlNifEnv* env, void* priv) {}

static int nif_load(ErlNifEnv* env, void** priv, ERL_NIF_TERM info) {
  RES_TYPE = enif_open_resource_type(env,"ecai_gpu","ecai_gpu_resource",res_dtor,ERL_NIF_RT_CREATE|ERL_NIF_RT_TAKEOVER,NULL);
  RES_DYN  = enif_open_resource_type(env,"ecai_gpu","ecai_gpu_dynamic",dyn_dtor,ERL_NIF_RT_CREATE|ERL_NIF_RT_TAKEOVER,NULL);
  return (RES_TYPE && RES_DYN) ? 0 : -1;
}

static ErlNifFunc nif_funcs[] = {
  {"load_compact", 1, load_compact_nif, 0},
  {"get_postings", 2, get_postings_nif, 0},
  {"free",         1, free_nif, 0},
  {"new_dynamic",  3, new_dynamic_nif, 0},
  {"append",       3, append_nif, 0},
  {"get_postings_dyn", 2, get_postings_dyn_nif, 0},
  {"free_dynamic", 1, free_dyn_nif, 0}
};


ERL_NIF_INIT(ecai_gpu, nif_funcs, nif_load, nif_reload, nif_upgrade, nif_unload)

