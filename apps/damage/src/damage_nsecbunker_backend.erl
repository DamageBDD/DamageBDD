%% Backend handle owned exclusively by damage_nsecbunker_secret_owner.
-module(damage_nsecbunker_backend).

-callback open(map()) -> {ok, term()} | {error, term()}.
-callback unlock(term(), binary(), timeout()) -> {ok, map()} | {error, term()}.
-callback call(term(), map(), timeout(), pid()) -> {ok, map()} | {error, term()}.
-callback status(term()) -> map().
-callback close(term()) -> ok.
