%% Common record used by playlist & UI
-ifndef(ERM_PLAYLIST_HRL).
-define(ERM_PLAYLIST_HRL, true).

-record(track, {
    %% integer() — stable id
    id,
    path :: file:filename_all(),
    cid :: undefined | binary(),
    liked = false :: boolean()
}).

-endif.
