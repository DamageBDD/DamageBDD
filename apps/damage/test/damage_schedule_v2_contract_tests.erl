-module(damage_schedule_v2_contract_tests).

-include_lib("eunit/include/eunit.hrl").

schedule_contract_source_is_packaged_test() ->
    Source = damage_schedule_v2_contract:contract_source(),
    ?assert(filelib:is_file(Source)),
    ?assertEqual(
        filename:absname(damage_ae:contract_path(damage, "contracts/schedule_v2.aes")),
        filename:absname(Source)
    ).
