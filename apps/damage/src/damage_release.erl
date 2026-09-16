%%%-------------------------------------------------------------------
%%% damage_release.erl
%%% Build relx artifact names and IPFS download URLs
%%%-------------------------------------------------------------------
-module(damage_release).
-export([
    rel_name_vsn/0,
    artifact_candidates/0,
    ipfs_urls/1,
    ipfs_urls/2
]).

-define(DEFAULT_IPFS_GATEWAY, <<"https://ipfs.io/ipfs">>).

%% @doc Get the release name and version from the running node.
%% Falls back to {<<"damage">>, VsnFromApp} if release_handler is unavailable.
-spec rel_name_vsn() -> {binary(), binary()}.
rel_name_vsn() ->
    case catch release_handler:which_releases() of
        [{'EXIT', _} | _] ->
            fallback();
        List when is_list(List) ->
            case lists:dropwhile(fun({_, _, _, S}) -> S =/= current end, List) of
                [{Name, Vsn, _Desc, current} | _] ->
                    {list_to_binary(Name), list_to_binary(Vsn)};
                _ ->
                    fallback()
            end
    end.

fallback() ->
    AppName = <<"damage">>,
    VsnBin =
        case application:get_key(damage, vsn) of
            {ok, Vsn} -> list_to_binary(Vsn);
            _ -> <<"0.0.0">>
        end,
    {AppName, VsnBin}.

%% @doc Return common relx tarball path/name candidates (relative paths).
%% - <name>-<vsn>.tar.gz
%% - releases/<vsn>/<name>-<vsn>.tar.gz
%% - <name>-<vsn>-<arch>.tar.gz   (if you publish arch-tagged bundles)
-spec artifact_candidates() -> [binary()].
artifact_candidates() ->
    {Name, Vsn} = rel_name_vsn(),
    Arch = list_to_binary(erlang:system_info(system_architecture)),
    Base = <<Name/binary, "-", Vsn/binary>>,
    [
        <<Base/binary, ".tar.gz">>,
        <<"releases/", Vsn/binary, "/", Base/binary, ".tar.gz">>,
        <<Base/binary, "-", Arch/binary, ".tar.gz">>
    ].

%% @doc Build full IPFS URLs using default gateway.
-spec ipfs_urls(binary()) -> [binary()].
ipfs_urls(CID) ->
    ipfs_urls(CID, ?DEFAULT_IPFS_GATEWAY).

%% @doc Build full IPFS URLs using a custom gateway base like <<"https://ipfs.asyncmind.xyz/ipfs">>.
-spec ipfs_urls(binary(), binary()) -> [binary()].
ipfs_urls(CID, GatewayBase) ->
    [join3(GatewayBase, CID, Candidate) || Candidate <- artifact_candidates()].

%% ---- helpers ----
join3(Base, CID, Tail) ->
    %% Ensure exactly one "/" between segments
    B = trim_slash_right(Base),
    C = trim_slash(CID),
    T = trim_slash_left(Tail),
    <<B/binary, "/", C/binary, "/", T/binary>>.

%% Remove trailing slashes
trim_slash_right(Bin) when is_binary(Bin) ->
    case byte_size(Bin) of
        0 ->
            Bin;
        N ->
            case binary:at(Bin, N - 1) of
                $/ ->
                    %% Strip the last byte and recurse
                    trim_slash_right(binary:part(Bin, 0, N - 1));
                _ ->
                    Bin
            end
    end.

%% Remove leading slashes
trim_slash_left(Bin) when is_binary(Bin) ->
    case Bin of
        <<$/, Rest/binary>> -> trim_slash_left(Rest);
        _ -> Bin
    end.

%% Remove both leading and trailing slashes
trim_slash(Bin) when is_binary(Bin) ->
    trim_slash_left(trim_slash_right(Bin)).
