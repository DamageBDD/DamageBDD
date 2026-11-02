%% Logical DETS restore rehearsal. Opaque records are never decrypted/reported.
%% The source is not replaced or closed. This is a recorded logical snapshot,
%% not an assertion that concurrent application writes were transactionally frozen.
-module(damage_nsecbunker_handoff_recovery).
-include_lib("kernel/include/file.hrl").
-export([metadata/1, restore_snapshot/2]).
metadata(Dir) -> restore_snapshot(secrets:secrets_dets_path(), Dir).
restore_snapshot(Source, Dir) ->
    {ok,#file_info{type=regular,size=Bytes}} = file:read_link_info(Source),
    true = Bytes =< 67108864,
    {ok,Tab} = dets:open_file(Source,[{auto_save,5000}]),
    Ets = ets:new(bunker_handoff_snapshot,[private,set]),
    Target = filename:join(Dir,"metadata-restore.dets"),
    try
        true = dets:info(Tab,size) =< 10000,
        ok = dets:safe_fixtable(Tab,true),
        try Ets = dets:to_ets(Tab,Ets)
        after dets:safe_fixtable(Tab,false) end,
        [] = ets:lookup(Ets,nsecbunker_vault_passphrase),
        {ok,damage_bunker_handoff_metadata_restore} = dets:open_file(
            damage_bunker_handoff_metadata_restore,[{file,Target},{type,set},{repair,false}]),
        try
            ok = file:change_mode(Target,8#600),
            ok = dets:from_ets(damage_bunker_handoff_metadata_restore,Ets),
            ok = dets:sync(damage_bunker_handoff_metadata_restore)
        after dets:close(damage_bunker_handoff_metadata_restore) end,
        {ok,damage_bunker_handoff_metadata_restore} = dets:open_file(
            damage_bunker_handoff_metadata_restore,[{file,Target},{access,read},{repair,false}]),
        try
            Records = dets:foldl(fun(R,Acc)->[R|Acc] end,[],damage_bunker_handoff_metadata_restore),
            true = lists:sort(Records) =:= lists:sort(ets:tab2list(Ets)),
            [] = dets:lookup(damage_bunker_handoff_metadata_restore,nsecbunker_vault_passphrase),
            {ok,FileBytes} = file:read_file(Target),
            #{restored=>true,record_count=>length(Records),local_vault_entry_absent=>true,
                sha256=>list_to_binary(string:lowercase(binary_to_list(
                    binary:encode_hex(crypto:hash(sha256,FileBytes)))))}
        after dets:close(damage_bunker_handoff_metadata_restore) end
    after
        ets:delete(Ets),dets:close(Tab),file:delete(Target)
    end.
