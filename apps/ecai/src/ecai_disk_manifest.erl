%%--------------------------------------------------------------------
%% ecai_disk_manifest.erl
%% Maintains manifest of immutable disk index segments
%% Newest segment listed first
%%--------------------------------------------------------------------
-module(ecai_disk_manifest).
-export([load/1, append_segment/2, list_segments/1]).

manifest_path(BaseDir) ->
    filename:join(BaseDir, "manifest.term").

load(BaseDir) ->
    P = manifest_path(BaseDir),
    case file:read_file(P) of
        {ok, Bin} ->
            [
                binary_to_list(L)
             || L <- binary:split(Bin, <<"\n">>, [global]),
                L =/= <<>>
            ];
        _ ->
            []
    end.

list_segments(BaseDir) ->
    load(BaseDir).

append_segment(BaseDir, SegPath) ->
    P = manifest_path(BaseDir),
    Tmp = P ++ ".tmp",
    Old = load(BaseDir),
    New = [SegPath | Old],
    Bin = iolist_to_binary([[S, "\n"] || S <- New]),
    ok = file:write_file(Tmp, Bin),
    ok = file:rename(Tmp, P),
    ok.
