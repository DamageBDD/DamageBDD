%%% Theme publishing, content-addressed package selection, and licensing.
%%% Presentation is data-only. No untrusted CSS/HTML/SVG is ever executed.
-module(damage_theme).
-export([catalog/0, find/1, publish/1, import/1, reconcile/1, active/1,
         select/4, stylesheet/1, branding/1, is_app/1]).

-define(APPS, [<<"damage">>, <<"ecai">>, <<"nosternity">>, <<"erm">>, <<"bop">>]).
-define(DEFAULT, <<"damage-dark@1.0.0">>).

is_app(App) -> lists:member(App, ?APPS).

catalog() ->
    Builtins = [M#{<<"key">> => damage_theme_manifest:key(M),
                    <<"status">> => <<"available">>} || M <- damage_theme_manifest:builtin()],
    case damage_theme_store:list() of
        {ok, Entries} -> {ok, Builtins ++ Entries};
        Error -> Error
    end.

find(Key) when is_binary(Key) ->
    case [M || M <- damage_theme_manifest:builtin(), damage_theme_manifest:key(M) =:= Key] of
        [Builtin] -> {ok, Builtin#{<<"key">> => Key, <<"builtin">> => true}};
        [] -> damage_theme_store:get(Key)
    end;
find(_) -> not_found.

publish(Raw) ->
    case damage_theme_manifest:validate(Raw) of
        {ok, Manifest} ->
            Key = damage_theme_manifest:key(Manifest),
            case find(Key) of
                {ok, _} -> {error, theme_exists};
                not_found -> publish_valid(Manifest, Key);
                Error -> Error
            end;
        Error -> Error
    end.

publish_valid(M, Key) ->
    case damage_theme_nft:configured() of
        false -> {error, theme_nft_not_configured};
        true ->
            SHA = damage_theme_manifest:package_hash(M),
            case publish_ipfs(M, SHA) of
                {ok, CID} ->
                    Record = M#{<<"key">> => Key, <<"sha256">> => SHA,
                                <<"cid">> => CID, <<"status">> => <<"pending_registration">>,
                                <<"published_at">> => erlang:system_time(second)},
                    case damage_theme_store:put(Record) of
                        ok -> register_pending(Record);
                        Error -> Error
                    end;
                Error -> Error
            end
    end.

reconcile(Key) ->
    case damage_theme_store:get(Key) of
        {ok, #{<<"status">> := <<"pending_registration">>} = Theme} -> register_pending(Theme);
        {ok, Theme} -> {ok, Theme};
        not_found -> {error, theme_not_found}
    end.

register_pending(Record) ->
    Key = maps:get(<<"key">>, Record),
    Cid = maps:get(<<"cid">>, Record),
    case damage_theme_nft:register(Record, Cid) of
        {ok, _} ->
            case damage_theme_nft:registered_matches(Key, Cid, maps:get(<<"sha256">>, Record)) of
                true -> finish_register(Record);
                _ -> {error, registration_needs_manual_reconciliation}
            end;
        {error, already_registered} ->
            %% An uncertain registration might have mined. Only auto-mark as
            %% complete after an explicit on-chain registration is observed.
            %% Contract registration is unique for this key.
            case damage_theme_nft:registered_matches(Key, Cid, maps:get(<<"sha256">>, Record)) of
                true -> finish_register(Record);
                _ -> {error, registration_needs_manual_reconciliation}
            end;
        Error -> Error
    end.
finish_register(Record) ->
    Key = maps:get(<<"key">>, Record),
    ok = damage_theme_store:update_theme(Key, #{<<"status">> => <<"available">>}),
    {ok, Record#{<<"status">> => <<"available">>}}.

publish_ipfs(Manifest, SHA) ->
    %% The bundle is deterministic and kept for re-pinning. Never accept a
    %% user-supplied path or extract archives (tar traversal/symlink issues).
    Root = filename:join([damage_config:state_dir(), "themes", "packages"]),
    Dir = filename:join(Root, binary_to_list(SHA)),
    ok = filelib:ensure_dir(filename:join(Dir, "theme.json")),
    ok = file:write_file(filename:join(Dir, "theme.json"), jsx:encode(Manifest)),
    ok = file:write_file(filename:join(Dir, "theme.css"),
                         damage_theme_manifest:css(<<"damage">>, Manifest)),
    Metadata = #{<<"name">> => maps:get(<<"name">>, Manifest),
                 <<"description">> => maps:get(<<"description">>, Manifest),
                 <<"schema">> => <<"damage-theme/v1">>,
                 <<"theme_key">> => damage_theme_manifest:key(Manifest),
                 <<"manifest_sha256">> => SHA,
                 <<"license">> => <<"AEX-141 NFT ownership">>},
    ok = file:write_file(filename:join(Dir, "metadata.json"), jsx:encode(Metadata)),
    case damage_ipfs:add({directory, Dir}) of
        Rows when is_list(Rows) ->
            case [CID || #{<<"Name">> := Name, <<"Hash">> := CID} <- Rows,
                         to_bin(Name) =:= to_bin(filename:basename(Dir))] of
                [CID | _] ->
                    case damage_ipfs:valid_cid(CID) of
                        true -> _ = damage_ipfs:pin_async(CID), {ok, CID};
                        _ -> {error, invalid_ipfs_cid}
                    end;
                [] -> {error, ipfs_package_root_missing}
            end;
        _ -> {error, ipfs_publication_failed}
    end.

%% Import an NFT package from any IPFS peer into the local install catalog.
%% The local Kubo API is used for bounded reads and on-chain NFT metadata must
%% match this exact content, so mutable URLs cannot masquerade as packages.
import(CID) when is_binary(CID) ->
    case damage_ipfs:valid_cid(CID) of
        true ->
            Path = <<CID/binary, "/theme.json">>,
            case damage_ipfs:cat_json(Path, [{max_bytes, 16384}]) of
                {ok, Raw} ->
                    case damage_theme_manifest:validate(Raw) of
                        {ok, Manifest} -> import_valid(CID, Manifest);
                        Error -> Error
                    end;
                _ -> {error, package_unavailable}
            end;
        _ -> {error, invalid_ipfs_cid}
    end;
import(_) -> {error, invalid_ipfs_cid}.

import_valid(CID, M) ->
    Key = damage_theme_manifest:key(M),
    SHA = damage_theme_manifest:package_hash(M),
    case find(Key) of
        {ok, _} -> {error, theme_exists};
        not_found ->
            case damage_theme_nft:registered_matches(Key, CID, SHA) of
                true ->
                    Record = M#{<<"key">> => Key, <<"sha256">> => SHA,
                        <<"cid">> => CID, <<"status">> => <<"available">>,
                        <<"imported_at">> => erlang:system_time(second)},
                    case damage_theme_store:put(Record) of
                        ok -> _ = damage_ipfs:pin_async(CID), {ok, Record};
                        Error -> Error
                    end;
                _ -> {error, nft_metadata_verification_failed}
            end
    end.

select(App, Key, Brand, Token) ->
    case {is_app(App), find(Key), damage_theme_manifest:validate_branding(Brand)} of
        {true, {ok, Theme}, SafeBrand} when is_map(SafeBrand) ->
            case lists:member(App, maps:get(<<"apps">>, Theme, ?APPS)) of
                false -> {error, theme_not_supported_by_app};
                true ->
                    case entitlement(Theme, Token) of
                        {ok, Licence} ->
                            ok = damage_theme_store:select(App, Key,
                                SafeBrand#{<<"license">> => Licence}),
                            {ok, #{app => App, key => Key}};
                        Error -> Error
                    end
            end;
        {false, _, _} -> {error, unknown_application};
        {_, not_found, _} -> {error, theme_not_found};
        _ -> {error, invalid_branding}
    end.

entitlement(#{<<"builtin">> := true}, _) -> {ok, #{}};
entitlement(#{<<"price_sats">> := 0, <<"price_damage">> := 0,
              <<"status">> := <<"available">>}, _) -> {ok, #{}};
entitlement(#{<<"status">> := <<"available">>, <<"key">> := Key},
            #{token_id := Id, owner := Owner}) ->
    case damage_theme_nft:owns(Id, Key, Owner) of
        true -> {ok, #{<<"token_id">> => Id, <<"owner">> => Owner}};
        _ -> {error, nft_ownership_not_verified}
    end;
entitlement(_, _) -> {error, nft_licence_required}.

active(App) ->
    case is_app(App) of
        false -> {error, unknown_application};
        true ->
            case damage_theme_store:selection(App) of
                {ok, #{<<"key">> := Key, <<"branding">> := Brand}} ->
                    case find(Key) of
                        {ok, Theme} ->
                            Licence = maps:get(<<"license">>, Brand, #{}),
                            case is_licensed(Theme, Licence) of
                                true -> {ok, Theme, maps:remove(<<"license">>, Brand)};
                                false -> default_theme()
                            end;
                        _ -> default_theme()
                    end;
                _ -> default_theme()
            end
    end.

is_licensed(#{<<"builtin">> := true}, _) -> true;
is_licensed(#{<<"status">> := <<"available">>, <<"price_sats">> := 0,
              <<"price_damage">> := 0}, _) -> true;
is_licensed(#{<<"status">> := <<"available">>, <<"key">> := Key},
            #{<<"token_id">> := Token, <<"owner">> := Owner}) ->
    damage_theme_nft:owns(Token, Key, Owner) =:= true;
is_licensed(_, _) -> false.

default_theme() ->
    [Default | _] = damage_theme_manifest:builtin(),
    {ok, Default, #{}}.

stylesheet(App) ->
    case active(App) of
        {ok, Theme, _Brand} -> {ok, damage_theme_manifest:css(App, Theme)};
        Error -> Error
    end.

branding(App) ->
    case active(App) of
        {ok, Theme, Override} ->
            Brand = maps:merge(maps:get(<<"branding">>, Theme, #{}), Override),
            Colors = maps:get(<<"tokens">>, Theme),
            Brand#{<<"accent">> => maps:get(<<"accent">>, Colors)};
        _ -> #{}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).
