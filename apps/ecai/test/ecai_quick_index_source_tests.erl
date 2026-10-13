-module(ecai_quick_index_source_tests).
-include_lib("eunit/include/eunit.hrl").

cid_normalization_test() ->
    Cid = <<"QmYwAPJzv5CZsnAzt8auVZRnGi2p9o8wVZ8Bv2J9zJpQj5">>,
    ?assertEqual({ok, Cid}, ecai_quick_index_source:normalize_cid(Cid)),
    ?assertEqual({ok, Cid}, ecai_quick_index_source:normalize_cid(<<"ipfs://", Cid/binary>>)),
    ?assertEqual({ok, Cid}, ecai_quick_index_source:normalize_cid(<<"/ipfs/", Cid/binary>>)),
    ?assertEqual({error, invalid_ipfs_cid}, ecai_quick_index_source:normalize_cid(<<"not-a-cid">>)).

private_ipv4_rejected_test() ->
    ?assertNot(ecai_quick_index_source:public_address({127,0,0,1})),
    ?assertNot(ecai_quick_index_source:public_address({10,1,2,3})),
    ?assertNot(ecai_quick_index_source:public_address({169,254,1,1})),
    ?assertNot(ecai_quick_index_source:public_address({192,168,1,1})),
    ?assert(ecai_quick_index_source:public_address({8,8,8,8})).

private_ipv6_rejected_test() ->
    ?assertNot(ecai_quick_index_source:public_address({0,0,0,0,0,0,0,1})),
    ?assertNot(ecai_quick_index_source:public_address({16#fc00,0,0,0,0,0,0,1})),
    ?assertNot(ecai_quick_index_source:public_address({16#fe80,0,0,0,0,0,0,1})),
    ?assert(ecai_quick_index_source:public_address({16#2606,16#4700,16#4700,0,0,0,0,16#1111})).

local_hostnames_rejected_test() ->
    ?assertNot(ecai_quick_index_source:host_name_safe(<<"localhost">>)),
    ?assertNot(ecai_quick_index_source:host_name_safe(<<"metadata.internal">>)),
    ?assertNot(ecai_quick_index_source:host_name_safe(<<"printer.local">>)),
    ?assert(ecai_quick_index_source:host_name_safe(<<"example.com">>)).
