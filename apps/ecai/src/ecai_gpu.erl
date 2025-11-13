%% apps/ecai/src/ecai_gpu.erl
-module(ecai_gpu).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-on_load(init/0).

-export([init/0, load_compact/1, get_postings/2, free/1]).
-export([
    new_dynamic/3, append/3, get_postings_dyn/2, free_dynamic/1
]).
-include_lib("kernel/include/logger.hrl").
-nifs([
    load_compact/1,
    get_postings/2,
    free/1,
    new_dynamic/3,
    append/3,
    get_postings_dyn/2,
    free_dynamic/1
]).

init() ->
    PrivDir = code:priv_dir(ecai),
    NifPath = filename:join([PrivDir, "ecai_gpu"]),
    case erlang:load_nif(NifPath, 0) of
        ok ->
            ok;
        % allow running without GPU NIF present
        {error, _} ->
            ?LOG_WARNING("GPU acceleration for ecai indexing not enabled. ~p", [NifPath]),
            ok
    end.

load_compact(_Snap) -> erlang:nif_error(nif_not_loaded).
get_postings(_, _) -> erlang:nif_error(nif_not_loaded).
free(_) -> erlang:nif_error(nif_not_loaded).

new_dynamic(_, _, _) -> erlang:nif_error(nif_not_loaded).
append(_, _, _) -> erlang:nif_error(nif_not_loaded).
get_postings_dyn(_, _) -> erlang:nif_error(nif_not_loaded).
free_dynamic(_) -> erlang:nif_error(nif_not_loaded).
