%%%-------------------------------------------------------------------
%%% media_scan.erl — robust media discovery for MPV
%%%  - Recursively walks directories
%%%  - Uses ffprobe (if available) to accept *any* audio/video supported
%%%  - Falls back to broad extension list if ffprobe is not present
%%%-------------------------------------------------------------------
-module(media_scan).
-export([ensure_started/0, scan_and_index/1]).

ensure_started() -> ok.

scan_and_index(Root) ->
    Files = discover(Root),
    [playlist:add_file(F) || F <- Files],
    ok.

discover(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            Abs = [filename:join(Dir, E) || E <- Entries],
            lists:foldl(fun each/2, [], Abs);
        {error, _} ->
            []
    end.

each(Path, Acc) ->
    case filelib:is_dir(Path) of
        true ->
            discover(Path) ++ Acc;
        false ->
            case is_media(Path) of
                true -> [Path | Acc];
                false -> Acc
            end
    end.

%% ---------- Media checks ----------

is_media(Path0) ->
    Path = ensure_list(Path0),
    case os:find_executable("ffprobe") of
        false ->
            has_known_ext(Path);
        _ ->
            %% Accept if ffprobe reports either audio or video stream
            case probe_kind(Path) of
                audio ->
                    true;
                video ->
                    true;
                %% keep images out of the playlist
                image ->
                    false;
                unknown ->
                    %% Fallback to extension list as a safety net
                    has_known_ext(Path)
            end
    end.

probe_kind(Path) ->
    %% Try audio first
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
    %% ffprobe -select_streams a:0|v:0 -show_entries stream=codec_type -of csv=p=0 -- 'file'
    Cmd = io_lib:format(
        "ffprobe -v error -select_streams ~s -show_entries stream=codec_type -of csv=p=0 -- ~ts",
        [Sel, shell_quote(Path)]
    ),
    string:trim(os:cmd(lists:flatten(Cmd))).

%% ---------- Extension fallback ----------

has_known_ext(Path) ->
    Ext = string:lowercase(filename:extension(Path)),
    lists:member(Ext, known_exts()).

known_exts() ->
    %% Audio (wide net; ffmpeg/mpv friendly)
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
    %% Video (since the UI handles video too)
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

%% ---------- helpers ----------

ensure_list(B) when is_binary(B) -> binary_to_list(B);
ensure_list(L) when is_list(L) -> L.

shell_quote(Path) ->
    %% safe single-quote for POSIX shells: ' -> '\''.
    L = ensure_list(Path),
    [$', string:replace(L, "'", "'\\''", all), $'].
