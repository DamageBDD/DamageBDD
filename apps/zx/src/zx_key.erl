%%% @doc
%%% ZX Key
%%%
%%% Abstraction module for dealing with keys.
%%%
%%%    "Ewwwww! Keys!"
%%%          -- Bertrand Russel
%%% @end

-module(zx_key).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([generate_rsa/1,
         save/3,     load/2,
         save_bin/3, load_bin/2,
         exists/2,
         sign/2,     verify/3]).

-include("zx_logger.hrl").
-include_lib("public_key/include/OTP-PUB-KEY.hrl").


-spec generate_rsa(Owner) -> Result
    when Owner  :: zx:realm() | zx:user_id(),
         Result :: {ok, zx:key_hash()}
                 | {error, keygen_fail}.
%% @private
%% Generate an RSA keypair and write them in der format to the current directory, using
%% filenames derived from Prefix.
%% NOTE: The current version of this command is likely to only work on a unix system.

generate_rsa(Owner) ->
    ok = tell("Generating keys. This can take several minutes. Please be patient..."),
    Key =
        #'RSAPrivateKey'{modulus        = Mod,
                         publicExponent = PE} =
            public_key:generate_key({rsa, 16384, 65537}),
    Pub =
        #'RSAPublicKey'{modulus        = Mod,
                        publicExponent = PE},
    TestMessage = <<"Some test data to sign.">>,
    Signature = public_key:sign(TestMessage, sha512, Key),
    case public_key:verify(TestMessage, sha512, Signature, Pub) of
        true ->
            KeyDER = public_key:der_encode('RSAPrivateKey', Key),
            PubDER = public_key:der_encode('RSAPublicKey', Pub),
            PubHash = crypto:hash(sha512, PubDER),
            KeyData = {PubHash, {none, PubDER}, {none, KeyDER}},
            ok = zx_daemon:register_key(Owner, KeyData),
            {ok, PubHash};
        false ->
            ok = tell(error, "Something has gone wrong."),
            {error, keygen_fail}
    end.


-spec save(Type, KeyID, Key) -> Result
    when Type   :: private | public,
         KeyID  :: zx:key_id(),
         Key    :: zx:key(),
         Result :: ok
                 | {error, file:posix()}.
%% @private
%% Encode a key to DER and store it as a file.

save(Type, KeyID, Key) ->
    KeyDER = public_key:der_encode(der_label(Type), Key),
    save_bin(Type, KeyID, KeyDER).


-spec load(Type, KeyID) -> Result
    when Type   :: private | public,
         KeyID  :: zx:key_id(),
         Result :: {ok, DecodedKey :: zx:key()}
                 | {error, file:posix()}.
%% @private
%% Load and decode a DER encoded key from file.

load(Type, KeyID) ->
    case load_bin(Type, KeyID) of
        {ok, KeyDER} -> {ok, public_key:der_decode(der_label(Type), KeyDER)};
        Error        -> Error
    end.


-spec save_bin(Type, KeyID, Bin) -> Result
    when Type   :: private | public,
         KeyID  :: zx:key_id(),
         Bin    :: binary(),
         Result :: ok
                 | {error, bad_realm | file:posix()}.
%% @private
%% Save a key's binary representation directly.

save_bin(Type, KeyID = {Realm, _}, Bin) ->
    case zx_lib:realm_exists(Realm) of
        true  -> save_bin2(Type, KeyID, Bin);
        false -> {error, bad_realm}
    end.

save_bin2(Type, KeyID, Bin) ->
    Path = path(Type, KeyID),
    ok = filelib:ensure_dir(Path),
    ok = log(info, "Saving ~p key to ~p.", [Type, Path]),
    file:write_file(Path, Bin).


-spec load_bin(Type, KeyID) -> Result
    when Type   :: private | public,
         KeyID  :: zx:key_id(),
         Result :: {ok, binary()}
                 | {error, bad_realm | no_key | no_pub | file:posix()}.
%% @private
%% Load a binary key's representation directly without decoding it.

load_bin(Type, KeyID = {Realm, _}) ->
    case zx_lib:realm_exists(Realm) of
        true  -> load_bin2(Type, KeyID);
        false -> {error, bad_realm}
    end.

load_bin2(Type, KeyID) ->
    Path = path(Type, KeyID),
    ok = log(info, "Loading ~p key from ~p.", [Type, Path]),
    case file:read_file(Path) of
        {ok, Bin} ->
            {ok, Bin};
        {error, enoent} ->
            Reason = case Type of private -> no_key; public -> no_pub end,
            {error, Reason};
        Error ->
            Error
    end.


-spec exists(Type, KeyID) -> boolean()
    when Type  :: private | public,
         KeyID :: zx:key_id().

exists(Type, KeyID) ->
    filelib:is_regular(path(Type, KeyID)).


-spec sign(Data, Key) -> Signature
    when Data      :: binary(),
         Key       :: public_key:rsa_private_key(),
         Signature :: boolean().

sign(Data, Key) ->
    public_key:sign(Data, sha512, Key).


-spec verify(Data, Signature, PubKey) -> boolean()
    when Data      :: binary(),
         Signature :: binary(),
         PubKey    :: public_key:rsa_public_key().
%% @private
%% Curry out the choice of algorithm. This will probably disappear in a few more
%% versions as the details of sha512 and RSA gradually give way to the Brave New World.

verify(Data, Signature, PubKey) ->
    public_key:verify(Data, sha512, Signature, PubKey).


der_label(private) -> 'RSAPrivateKey';
der_label(public)  -> 'RSAPublicKey'.


-spec path(public | private, zx:key_id()) -> file:filename().

path(Type, {Realm, KeyHash}) ->
    Name = name(Type, KeyHash),
    zx_lib:path(key, Realm, Name).


string(KeyHash) ->
    Size = byte_size(KeyHash) * 8,
    <<N:Size>> = KeyHash,
    integer_to_list(N, 36).


name(Type, KeyHash) ->
    String = string(KeyHash),
    case Type of
        public  -> String ++ ".pub.der";
        private -> String ++ ".key.der"
    end.
