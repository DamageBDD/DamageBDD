%% Shared NFT-only fixtures. No live keys, chain or IPFS state is required.
-module(damage_release_test_support).
-export([cid/0, digest/0, answer/0, release_record/0, metadata/0,
         installed_release/0, some/1, token_metadata/0]).

cid() -> <<"QmXsQVyTPVPgzHxinfiaj7Vzf9SrWVkkGNAHNfdm8RtJXS">>.
digest() -> binary:copy(<<"a">>, 64).
answer() ->
    Cid = cid(),
    <<"42|v1.4.1|ubuntu-noble-amd64||ipfs://", Cid/binary, "|ipfs://", Cid/binary>>.
release_record() ->
    #{token_id => 42, release => <<"v1.4.1">>, platform => <<"ubuntu-noble-amd64">>,
      git_sha => <<>>, metadata_cid => cid(), asset_cid => cid()}.
metadata() ->
    #{<<"file_ipfs">> => cid(), <<"git_sha">> => <<>>,
      <<"installation">> => #{<<"schema_version">> => 1,
        <<"platform">> => <<"ubuntu-noble-amd64">>, <<"package_format">> => <<"deb">>,
        <<"architecture">> => <<"amd64">>, <<"asset_path">> => <<"damage.deb">>,
        <<"sha256">> => digest()}}.
installed_release() ->
    (release_record())#{schema_version => 2, network_id => <<"ae_mainnet">>,
        contract_id => <<"ct_test_fixture">>, metadata_verification => <<"local_kubo">>,
        asset_path => <<"damage.deb">>, sha256 => digest(),
        package_format => <<"deb">>, architecture => <<"amd64">>}.
some(Value) -> {variant, [0, 1], 1, {Value}}.
token_metadata() ->
    Cid = cid(),
    {variant, [1, 1], 1, {#{<<"release">> => <<"v1.4.1">>,
        <<"platform">> => <<"ubuntu-noble-amd64">>, <<"git_sha">> => <<>>,
        <<"url">> => <<"ipfs://", Cid/binary>>, <<"asset">> => <<"ipfs://", Cid/binary>>}}}.
