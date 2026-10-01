%% Common record used by playlist & UI
-ifndef(ERM_PLAYLIST_HRL).
-define(ERM_PLAYLIST_HRL, true).

-record(track, {
    %% integer() — stable id derived from the media path
    id,
    path :: file:filename_all(),
    cid = undefined :: undefined | binary(),
    liked = false :: boolean(),

    %% Best-effort metadata used by playlist grouping/random selection.
    %% ffprobe tags are preferred; path-derived fallbacks are used when tags
    %% are absent so album/artist grouping remains useful for plain files.
    artist = undefined :: undefined | string(),
    album = undefined :: undefined | string(),
    genre = undefined :: undefined | string(),
    directory = undefined :: undefined | file:filename_all(),
    mtime = 0 :: integer()
}).

-endif.
