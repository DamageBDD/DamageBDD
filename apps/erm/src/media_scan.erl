%%%-------------------------------------------------------------------
%%% media_scan.erl — robust media discovery for MPV
%%%  - Expands ~/$HOME paths and converts local paths to absolute paths
%%%  - Recursively walks directories in deterministic order
%%%  - Accepts a broad MPV/ffmpeg extension set without probing every file
%%%  - Uses ffprobe for unknown extensions when available
%%%-------------------------------------------------------------------
-module(media_scan).

-export([
    ensure_started/0,
    scan_and_index/1,
    discover/1,
    discover/2,
    is_media/1,
    normalize_path/1
]).

ensure_started() -> ok.

%% Add a directory as a persistent playlist source. Let playlist own source
%% tracking and persistence instead of discovering a batch and losing the root.
scan_and_index(Root0) ->
    Root = normalize_path(Root0),
    playlist:add_files(Root, true).

discover(Root) ->
    discover(Root, true).

discover(Root0, Recurse) when Recurse =:= true; Recurse =:= false ->
    Root = normalize_path(Root0),
    case path_kind(Root) of
        directory ->
            discover_dir(Root, Recurse);
        file ->
            case is_media(Root) of
                true -> [Root];
                false -> []
            end;
        other ->
            []
    end.

discover_dir(Dir, Recurse) ->
    case file:list_dir(Dir) of
        {ok, Entries0} ->
            %% file:list_dir/1 order is filesystem-dependent. Stable sorting
            %% keeps initial playlist population deterministic.
            Entries = lists:sort(Entries0),
            Paths = [filename:join(Dir, Entry) || Entry <- Entries],
            lists:append([discover_entry(Path, Recurse) || Path <- Paths]);
        {error, _Reason} ->
            []
    end.

discover_entry(Path, Recurse) ->
    case path_kind(Path) of
        directory when Recurse =:= true ->
            discover_dir(Path, true);
        directory ->
            [];
        file ->
            case is_media(Path) of
                true -> [normalize_path(Path)];
                false -> []
            end;
        other ->
            []
    end.

%% ---------- Media checks ----------

is_media(Path0) ->
    Path = normalize_path(Path0),
    case is_image_ext(Path) of
        true ->
            false;
        false ->
            case has_known_ext(Path) of
                true ->
                    true;
                false ->
                    %% Avoid spawning ffprobe for every common media file. Probe only
                    %% unknown extensions so containers/codecs supported by MPV are not
                    %% silently omitted just because the extension list is incomplete.
                    case os:find_executable("ffprobe") of
                        false ->
                            false;
                        _ ->
                            case probe_kind(Path) of
                                audio -> true;
                                video -> true;
                                _ -> false
                            end
                    end
            end
    end.

probe_kind(Path) ->
    case run_probe(Path, "a:0") of
        "audio" ->
            audio;
        _ ->
            case run_probe(Path, "v:0") of
                "video" -> video;
                _ -> unknown
            end
    end.

run_probe(Path, Sel) ->
    Cmd = io_lib:format(
        "ffprobe -v error -select_streams ~s -show_entries stream=codec_type -of csv=p=0 -- ~ts",
        [Sel, shell_quote(Path)]
    ),
    string:trim(os:cmd(lists:flatten(Cmd))).

%% ---------- Extension fallback ----------

has_known_ext(Path) ->
    Ext = string:lowercase(filename:extension(Path)),
    lists:member(Ext, known_exts()).

is_image_ext(Path) ->
    Ext = string:lowercase(filename:extension(Path)),
    lists:member(Ext, [
        ".jpg",
        ".jpeg",
        ".png",
        ".gif",
        ".webp",
        ".bmp",
        ".tif",
        ".tiff",
        ".heic",
        ".heif",
        ".avif",
        ".svg"
    ]).

known_exts() ->
    Audio = [
        ".mp3",
        ".flac",
        ".wav",
        ".ogg",
        ".oga",
        ".opus",
        ".m4a",
        ".aac",
        ".ac3",
        ".eac3",
        ".dts",
        ".aiff",
        ".aif",
        ".aifc",
        ".alac",
        ".ape",
        ".wv",
        ".tta",
        ".spx",
        ".mp2",
        ".mpga",
        ".mka",
        ".caf",
        ".snd",
        ".amr",
        ".mid",
        ".midi",
        ".pcm",
        ".wma"
    ],
    Video = [
        ".mp4",
        ".m4v",
        ".mkv",
        ".webm",
        ".avi",
        ".mov",
        ".qt",
        ".wmv",
        ".flv",
        ".ts",
        ".m2ts",
        ".mts",
        ".vob",
        ".ogv",
        ".3gp",
        ".3g2",
        ".mpeg",
        ".mpg",
        ".mpe",
        ".mpv",
        ".rmvb",
        ".divx",
        ".asf",
        ".f4v",
        ".h264",
        ".hevc",
        ".y4m"
    ],
    Audio ++ Video.

%% ---------- Path helpers ----------

normalize_path(Bin) when is_binary(Bin) ->
    normalize_path(unicode:characters_to_list(Bin));
normalize_path(Path0) when is_list(Path0) ->
    Path = lists:flatten(Path0),
    case has_uri_scheme(Path) of
        true ->
            Path;
        false ->
            filename:absname(expand_user_path(Path))
    end;
normalize_path(Value) when is_atom(Value) ->
    normalize_path(atom_to_list(Value)).

expand_user_path(Path) ->
    case Path of
        "~" ->
            home_dir();
        [$~, $/ | Rest] ->
            filename:join(home_dir(), Rest);
        "$HOME" ->
            home_dir();
        [$$, $H, $O, $M, $E, $/ | Rest] ->
            filename:join(home_dir(), Rest);
        "${HOME}" ->
            home_dir();
        [$$, ${, $H, $O, $M, $E, $}, $/ | Rest] ->
            filename:join(home_dir(), Rest);
        _ ->
            Path
    end.

home_dir() ->
    case os:getenv("HOME") of
        false -> ".";
        "" -> ".";
        Home -> Home
    end.

has_uri_scheme(Path) when is_list(Path) ->
    case string:find(Path, "://") of
        nomatch -> false;
        _ -> true
    end.

path_kind(Path) ->
    case filelib:is_dir(Path) of
        true ->
            directory;
        false ->
            case filelib:is_file(Path) of
                true -> file;
                false -> other
            end
    end.

shell_quote(Path) ->
    L = normalize_path(Path),
    [$' | shell_quote_chars(L)] ++ [$'].

shell_quote_chars([]) -> [];
shell_quote_chars([$' | Rest]) -> [$', $\\, $', $' | shell_quote_chars(Rest)];
shell_quote_chars([Ch | Rest]) -> [Ch | shell_quote_chars(Rest)].
