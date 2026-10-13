%%% @doc
%%% ZX Daemon
%%%
%%% Resident task daemon and runtime interface to Zomp.
%%%
%%% The daemon resides in the background once started and awaits query requests and
%%% subscriptions from other processes. The daemon is only capable of handling
%%% unprivileged ("leaf") actions and local operations.
%%%
%%%
%%% Discrete state and local abstract data types
%%%
%%% The daemon must keep track of requestors, subscribers, peers, and zx_conn processes
%%% by using monitors. Because these various types of clients are found in different
%%% structures the monitors are maintained in a data type called monitor_index(),
%%% shortened to "mx" throughout the module. This structure is treated as an abstract
%%% data type and is handled by a set of functions defined toward the end of the module
%%% as mx_*/N.
%%%
%%% Node connections (zx_conn processes) must also be tracked for status and realm
%%% availability. This is done using a type called conn_index(), shortened to "cx"
%%% throughout the module. conn_index() is treated as an abstract datatype throughout
%%% the module and is handled via a set of cx_*/N functions (after the mx_*/N section).
%%%
%%% Do NOT directly access data within these structures, use (or write) an accessor
%%% function that does what you want. Accessor functions MUST be pure with the
%%% exception of mx_add_monitor/3 and mx_del_monitor/3 that create and destroy
%%% monitors.
%%%
%%%
%%% Connection handling
%%%
%%% The daemon is structured as a service manager in a service -> worker structure.
%%% http://zxq9.com/archives/1311
%%% This allows it to abstract the servicing of tasks at a high level, making it
%%% unnecessary for other processes to talk directly to any zx_conn processes or care
%%% whether the current runtime is the host's zx proxy or a peer instance.
%%%
%%% It is in charge of the high-level task of servicing requested actions and returning
%%% responses to callers as well as mapping successful connections to configured realms
%%% and repairing failed connections to nodes that reduce availability of configured
%%% realms.
%%%
%%% When the zx_daemon is started it checks local configuration and cache files to
%%% determine what realms must be available and what cached Zomp nodes it is aware of.
%%% It populates the CX (conn_index(), mentioned above) with realm config and host
%%% cache data, and then initiates a connection attempt to each configured prime node
%%% and up to maxconn connection attempts to cached nodes for each realm as well.
%%% (See init_connections/0).
%%%
%%% Once connection attempts have been initiated the daemon waits in receive for
%%% either a connection report (success or failure) or an action request from
%%% elsewhere in the system.
%%%
%%% Connection status is relayed with report/1 and indicates to the daemon whether
%%% a connection has failed, been disconneocted, redirected, or succeeded. See the
%%% zx_conn internals for details. If a connection is successful then the zx_conn
%%% will relay the connected node's realm availability status to the daemon, and
%%% the daemon will match the node's provided realms with the configured realm list.
%%% Any realms that are not yet provided by another connection will be assigned to
%%% the reporting successful zx_conn. If no unserviced realms are provided by the
%%% node the zx_conn will be shut down but the host info will be cached for future
%%% use. Any realms that have an older serial than the serial currently known to
%%% zx will be disregarded (which may result in termination of the connection if it
%%% means there are no useful realms available on a given node).
%%%
%%% A failure can occur at any time. In the event a connected and assigned zx_conn
%%% has failed the target host will be dropped from the hosts cache, the zx_conn will
%%% terminate and a new one will be spawned in its place if there is a gap in
%%% configured realm coverage.
%%%
%%% Nodes may be too busy (their client slots full) to accept a new connection. In
%%% this case the node should give the zx_conn a redirect instruction during protocol
%%% negotiation. The zx_conn will report the redirect and host list to the daemon,
%%% and the daemon will add the hosts to the host cache and the redirecting host will
%%% be placed at the rear of the host cache unless it is the prime node for the target
%%% realm.
%%%
%%%
%%% Request queues
%%%
%%% Requests, reports and subscription updates are all either forwarded to affected
%%% processes or entered into a work queue. All such work requests are received as
%%% asynchronous messages and cause the work queue to first be updated, and then,
%%% as a separate step, the work queue is re-evaluated in its entirety. Any work that
%%% cannot be completed (due to a realm not being available, for example) is recycled
%%% to the queue. A connection report also triggers a queue re-evaluation, so there
%%% should not be cases where the work queue stalls on active requests.
%%%
%%% Requestors sending either download or realm query requests are given a reference
%%% (an integer, not an Erlang reference, as the message may cross node boundaries)
%%% to match on for receipt of their result messages or to be used to cancel the
%%% requested work (timeouts are handled by the caller, not by the daemon).
%%%
%%% A bit of state handling is required (queueing requests and storing the current
%%% action state), but this permits the system above the daemon to interact with it in
%%% a blocking way, establishing its own receive timeouts or implementing either an
%%% asynchronous or synchronous interface library atop zx_daemon interface function,
%%% but leaving zx_daemon and zx_conn alone to work asynchronously with one another.
%%%
%%%
%%% Race Avoidance
%%%
%%% Each runtime can only have one zx_daemon alive at a time, and each system can
%%% only have one zx_daemon directly performing actions at a time. This is to prevent
%%% problems where multiple zx instances are running at the same time using the same
%%% home directory and might clash with one another (overwriting each other's data,
%%% corrupting package or key files, etc.). OTP makes running a single registered
%%% process simple within a single runtime, but there is no  standard cross-platform
%%% method for ensuring a given process is the only one of its type in a given scope
%%% within a host system.
%%%
%%% When zx starts the daemon will attempt an exclusive write to a lock file called
%%% $ZOMP_DIR/john.locke using file:open(LockFile, [exclusive]), writing a system
%%% timestamp. If the write succeeds then the daemon knows it is the master for the
%%% system and will begin initiating connections as described above as well as open a
%%% local socket to listen for other zx instances which will need to proxy their own
%%% actions through the master. Once the socket is open, the lock file is updated with
%%% the local port number. If the write fails then the file is read and if a port
%%% number is indicated then the daemon connects to the master zx_daemon and proxies
%%% its requests through it. If no port number exists then the daemon waits 5 seconds,
%%% checks again, and if there is still no port number then it checks whether the
%%% timestamp is more than 5 seconds old or in the future. If the timestamp is more
%%% than 5 seconds old or in the future then the file is deleted and the process
%%% of master identification starts again.
%%%
%%% If a master daemon's runtime is shutting down it will designate its oldest peer
%%% daemon connection as the new master. At that point the new master will open a port
%%% and rewrite the lock file. Once written the old master will drop all its node
%%% connections and dequeue all current requests, then pass a local redirect message
%%% to the subordinate daemons telling them the new port to which they should connect.
%%%
%%% Even if there is considrable churn within a system from, for example, scripted
%%% initiation of several small utilities that have never been executed before, the
%%% longest-living daemon should always become the master. This is not the most
%%% efficient procedure, but it is the easiest to understand and debug across various
%%% platforms.
%%% @end

-module(zx_daemon).
-vsn("0.14.0").
-behavior(gen_server).
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([get_home/0, dir/1, dirv/1, meta/0, argv/0]).

-export([zomp_mode/0]).
-export([pass_meta/3,
         subscribe/1, unsubscribe/1,
         list/0, list/1, list/2, list/3, list_type/1, latest/1,
         describe/1, provides/2, list_deps/1, search/1,
         list_sysops/1,
         fetch/1, fetch/2, install/1, build/1,
         wait_result/1, wait_results/1]).
-export([register_key/2, get_key/2,  get_keybin/2,
         have_key/2, list_keys/2]).
-export([report/1, result/2, notify/2]).
-export([connect/0, disconnect/0]).
-export([conf/1, conf/2, hosts/0,
         add_mirror/1, drop_mirror/1,
         takeover/1, abdicate/1, drop_realm/1]).
-export([start_link/0, idle/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).


-export_type([id/0, result/0,
              realm_list/0, package_list/0, version_list/0, latest_result/0,
              fetch_result/0, key_result/0,
              sub_message/0]).


-include("zx_logger.hrl").



%%% Type Definitions

-record(s,
        {meta     = none        :: none | zx_zsp:meta(),
         home     = none        :: none | file:filename(),
         argv     = []          :: [string()],
         conf     = load_conf() :: conf(),
         id       = 0           :: id(),
         actions  = []          :: [request()],
         requests = maps:new()  :: requests(),
         dropped  = maps:new()  :: requests(),
         timer    = none        :: none | reference(),
         mx       = mx_new()    :: monitor_index(),
         cx       = offline     :: conn_index()}).

-record(conf,
        {realms      = zx_lib:list_realms() :: [zx:realm()],
         managed     = sets:new()           :: sets:set(zx:realm()),
         mirrors     = sets:new()           :: sets:set(zx:host()),
         timeout     = 5                    :: pos_integer(),
         retries     = 3                    :: non_neg_integer(),
         maxconn     = 5                    :: pos_integer(),
         status      = listen               :: listen | ignore,
         listen_port = 11311                :: inet:port_number(),
         public_port = 11311                :: inet:port_number(),
         node_max    = 16#10                :: pos_integer(),
         vamp_max    = 16#10                :: pos_integer(),
         leaf_max    = 16#100               :: pos_integer()}).

-record(cx,
        {realms   = #{}         :: #{zx:realm() := realm_meta()},
         conns    = []          :: [connection()],
         mirrors  = queue:new() :: queue:queue(zx:host()),
         hosts    = queue:new() :: queue:queue(zx:host())}).

-record(rmeta,
        {serial       = 0                          :: non_neg_integer(),
         prime        = {"zomp.tsuriai.jp", 11311} :: zx:host(),
         key          = none                       :: none | zx:key_name(),
         sysop        = none                       :: zx:user_name(),
         assigned     = none                       :: none | managed | pid(),
         available    = []                         :: [pid()]}).

-record(conn,
        {pid      = none :: none | pid(),
         realms   = []   :: [zx:realm()],
         requests = []   :: [id()],
         subs     = []   :: [{pid(), zx:package()}]}).


%% State Types
-type state()          :: #s{}.
-opaque id()           :: integer().
-type conf()           :: #conf{}.
-type request()        :: {subscribe,   pid(), zx:package()}
                        | {unsubscribe, pid(), zx:package()}
                        | {request,     pid(), id(), action()}.
-type requests()       :: #{id() := {pid(), action()}}.
-type monitor_index()  :: #{pid() := {reference(), category()}}.
-type conn_index()     :: #cx{} | zomp | proxied | offline.
-type realm_meta()     :: #rmeta{}.
-type connection()     :: #conn{}.
-type category()       :: {Reqs :: [id()], Subs :: [zx:package()]}
                        | attempt
                        | conn.
-type attribute()      :: realms   | managed     | mirrors
                        | timeout  | retries     | maxconn
                        | status   | listen_port | public_port
                        | node_max | vamp_max    | leaf_max.

%% Conn Communication
-type conn_report()    :: {connected, Realms :: [{zx:realm(), zx:serial()}]}
                        | {redirect, Hosts :: [zx:host()]}
                        | failed
                        | disconnected
                        | timeout.

%% Subscriber / Requestor Communication
% Incoming Request messages
% This form allows a bit of cheating with blind calls to `element(2, Request)'.
-type action()         :: list
                        | {list,        zx:realm()}
                        | {list,        zx:realm(), zx:name()}
                        | {list,        zx:realm(), zx:name(), zx:version()}
                        | {latest,      zx:realm(), zx:name()}
                        | {latest,      zx:realm(), zx:name(), zx:version()}
                        | {describe,    zx:realm(), zx:name()}
                        | {provides,    zx:realm(), string()}
                        | {search,      zx:realm(), string()}
                        | {list_deps,   zx:realm(), zx:name(), zx:version()}
                        | {list_sysops, zx:realm()}
                        | {pending,     zx:realm(), zx:name()}
                        | {approved,    zx:realm()}
                        | {fetch,       zx:realm(), zx:name(), zx:version(), [pid()]}
                        | {keychain,    zx:realm(), zx:key_name()}.

% Outgoing Result Messages
%
% Results are sent wrapped a triple:    {result, Ref, Result}
% where the result itself is a triple:  {Type, Identifier, Content}
%
% Subscription messages are a separate type below.

-type result()         :: {result,
                           RequestID :: id(),
                           Message   :: realm_list()
                                      | package_list()
                                      | version_list()
                                      | latest_result()
                                      | desc_result()
                                      | fetch_result()
                                      | key_result()}.

-type realm_list()     :: [zx:realm()].
-type package_list()   :: {ok, [zx:name()]}
                        | {error, bad_realm
                                | timeout}.
-type version_list()   :: {ok, [zx:version()]}
                        | {error, bad_realm
                                | bad_package
                                | timeout}.
-type latest_result()  :: {ok, zx:version()}
                        | {error, bad_realm
                                | bad_package
                                | bad_version
                                | timeout}.
-type desc_result()    :: {ok, zx:description()}
                        | {error, bad_realm
                                | bad_package
                                | bad_version
                                | timeout}.
-type fetch_result()   :: {hops, non_neg_integer()}
                        | {done, zx:package_id()}
                        | {error, bad_realm
                                | bad_package
                                | bad_version
                                | timeout}.
-type key_result()     :: done
                        | {error, bad_realm
                                | bad_key
                                | timeout}.


% Subscription Results
-type sub_message()    :: {z_sub,
                           zx:package(),
                           Message :: {update, zx:package_id()}
                                    | {error, bad_realm | bad_package}}.

%%% Public Interface


-spec get_home() -> file:filename().

get_home() ->
    gen_server:call(?MODULE, get_home).


-spec dir(zx:core_dir() | home) -> file:filename().

dir(home) ->
    get_home();
dir(Type) ->
    gen_server:call(?MODULE, {dir, Type}).


-spec dirv(zx:core_dir()) -> file:filename().

dirv(Type) ->
    gen_server:call(?MODULE, {dirv, Type}).


-spec meta() -> zx_zsp:meta().

meta() ->
    gen_server:call(?MODULE, meta).


-spec argv() -> [string()].

argv() ->
    gen_server:call(?MODULE, argv).


%%% Zomp Internal Interface

-spec zomp_mode() -> ok.

zomp_mode() ->
    gen_server:cast(?MODULE, zomp_mode).


%%% Requestor Interface

-spec pass_meta(Meta, Dir, ArgV) -> ok
    when Meta :: zx:package_meta(),
         Dir  :: file:filename(),
         ArgV :: [string()].
%% @private
%% Load the daemon with the primary running application's meta data and location within
%% the filesystem. This step allows running development code from any location in
%% the filesystem against installed dependencies without requiring any magical
%% references.

pass_meta(Meta, Dir, ArgV) ->
    gen_server:cast(?MODULE, {pass_meta, Meta, Dir, ArgV}).


-spec subscribe(Package) -> ok
    when Package :: zx:package().
%% @doc
%% Subscribe to update notifications for a for a package.
%% The caller will receive update notifications of type `sub_message()' as Erlang
%% messages whenever an update occurs.
%% Crashes the caller if the Realm or Name of the Package argument are illegal
%% `zx:lower0_9()' strings.

subscribe(Package = {Realm, Name}) ->
    true = zx_lib:valid_lower0_9(Realm),
    true = zx_lib:valid_lower0_9(Name),
    gen_server:cast(?MODULE, {subscribe, self(), Package}).


-spec unsubscribe(Package) -> ok
    when Package :: zx:package().
%% @doc
%% Instructs the daemon to unsubscribe if subscribed. Has no effect if not subscribed.
%% Crashes the caller if the Realm or Name of the Package argument are illegal
%% `lower0_9' strings.

unsubscribe(Package = {Realm, Name}) ->
    true = zx_lib:valid_lower0_9(Realm),
    true = zx_lib:valid_lower0_9(Name),
    gen_server:cast(?MODULE, {unsubscribe, self(), Package}).


-spec list() -> {ok, RequestID}
    when RequestID :: term().
%% @doc
%% This query does not actually require a round trip but is included for completeness
%% and convenience when stacking zx_daemon queries into a list for use with
%% wait_results/1.
%%
%% If you only need a list of configured realms and aren't performing a list of queries
%% use zx:list/0 instead.

list() ->
    request(list).


-spec list(Realm) -> {ok, RequestID}
    when Realm     :: zx:realm(),
         RequestID :: term().
%% @doc
%% Requests a list of packages provided by the given realm.
%% Returns a request ID which will be returned in a message with the result from an
%% upstream zomp node. Crashes the caller if Realm is an illegal string.
%%
%% Response messages are of the type `result()' where the third element is of the
%% type `package_list()'.

list(Realm) ->
    true = zx_lib:valid_lower0_9(Realm),
    request({list, Realm}).


-spec list(Realm, Name) -> {ok, RequestID}
    when Realm     :: zx:realm(),
         Name      :: zx:name(),
         RequestID :: term().
%% @doc
%% Requests a list of package versions.
%% Returns a request ID which will be returned in a message with the result from an
%% upstream zomp node. Crashes the if Realm or Name are illegal strings.
%%
%% Response messages are of the type `result()' where the third element is of the
%% type `version_list()'.

list(Realm, Name) ->
    true = zx_lib:valid_lower0_9(Realm),
    true = zx_lib:valid_lower0_9(Name),
    request({list, Realm, Name}).


-spec list(Realm, Name, Version) -> {ok, RequestID}
    when Realm     :: zx:realm(),
         Name      :: zx:name(),
         Version   :: zx:version(),
         RequestID :: term().
%% @doc
%% Request a list of package versions constrained by a partial version.
%% Returns a request ID which will be returned in a message with the result from an
%% upstream zomp node. Can be used to check for a specific version by testing for a
%% response of `{error, bad_version}' when a full version number is provided.
%% Crashes the caller on an illegal realm name, package name, or version tuple.
%%
%% Response messages are of the type `result()' where the third element is of the
%% type `list_result()'.

list(Realm, Name, Version) ->
    true = zx_lib:valid_lower0_9(Realm),
    true = zx_lib:valid_lower0_9(Name),
    true = zx_lib:valid_version(Version),
    request({list, Realm, Name, Version}).


-spec list_type(Target) -> {ok, RequestID}
    when Target    :: {zx:realm(), zx:package_type()},
         RequestID :: term().

list_type({Realm, Type}) ->
    true = zx_lib:valid_lower0_9(Realm),
    request({list_type, Realm, Type}).


-spec latest(Identifier) -> {ok, RequestID}
    when Identifier :: zx:package() | zx:package_id(),
         RequestID  :: integer().
%% @doc
%% Request the lastest version of a package within the provided version constraint.
%% If no version is provided then the latest version overall will be returned.
%% Returns a request ID which will be returned in a message with the result from an
%% upstream zomp node. Crashes the caller on an illegal realm name, package name or
%% version tuple.
%%
%% Response messages are of the type `result()' where the third element is of the
%% type `latest_result()'.

latest({Realm, Name}) ->
    true = zx_lib:valid_lower0_9(Realm),
    true = zx_lib:valid_lower0_9(Name),
    request({latest, Realm, Name, {z, z, z}});
latest({Realm, Name, Version}) ->
    true = zx_lib:valid_lower0_9(Realm),
    true = zx_lib:valid_lower0_9(Name),
    true = zx_lib:valid_version(Version),
    request({latest, Realm, Name, Version}).


-spec describe(PackageID) -> {ok, RequestID}
    when PackageID :: zx:package_id(),
         RequestID :: integer().

describe({Realm, Name}) ->
    request({describe, Realm, Name, {z, z, z}});
describe({Realm, Name, Version}) ->
    request({describe, Realm, Name, Version}).


-spec provides(Realm, Module) -> {ok, RequestID}
    when Realm     :: zx:realm(),
         Module    :: string(),
         RequestID :: integer().

provides(Realm, Module) ->
    request({provides, Realm, Module}).


-spec search(Target) -> {ok, RequestID}
    when Target    :: {zx:realm(), string()},
         RequestID :: integer().

search({Realm, String}) ->
    request({search, Realm, String}).


-spec list_deps(PackageID) -> {ok, RequestID}
    when PackageID :: zx:package_id(),
         RequestID :: integer().

list_deps({Realm, Name, Version}) ->
    request({list_deps, Realm, Name, Version}).


-spec list_sysops(Realm) -> {ok, RequestID}
    when Realm     :: zx:realm(),
         RequestID :: integer().

list_sysops(Realm) ->
    request({list_sysops, Realm}).


-spec fetch(PackageID) -> Result
    when PackageID :: zx:package_id(),
         Result    :: {ok, JobID :: id()}.
%% @doc
%% Install the specified package. This returns an id() that will be referenced
%% in a later response message.
%% @equiv fetch(PackageID, []).

fetch(PackageID) ->
    fetch(PackageID, []).


-spec fetch(PackageID, Watchers) -> Result
    when PackageID :: zx:package_id(),
         Watchers  :: [pid()],
         Result    :: {ok, JobID :: id()}.
%% @doc
%% Install the specified package. This returns an id() that will be referenced
%% in a later response message.

fetch(PackageID, Watchers) ->
    gen_server:call(?MODULE, {fetch, PackageID, Watchers}).


-spec install(Path :: file:filename()) -> zx:outcome().
%% @doc
%% Install a package from a local file.

install(Path) ->
    gen_server:call(?MODULE, {install, Path}).


-spec build(zx:package_id()) -> zx:outcome().

build(PackageID) ->
    gen_server:call(?MODULE, {build, PackageID}, infinity).


-spec wait_result(ID) -> Result
    when ID :: id(),
         Result :: {ok, term()}
                 | {error, Reason},
         Reason :: bad_realm
                 | bad_package
                 | bad_version
                 | timeout
                 | network
                 | {unexpected, Message :: string()}.

wait_result(ID) ->
    receive
        {result, ID, Result}        -> Result;
        Reason when is_atom(Reason) -> {error, Reason};
        Message                     -> {error, Message}
        after 60000                 -> {error, timeout}
    end.


-spec wait_results(IDs) -> Outcome
    when IDs        :: [id()],
         Outcome    :: {ok, [Result]}
                     | {error, Unexpected, [Result]}
                     | {error, Reason},
         Result     :: {id(), term()},
         Unexpected :: {unexpected, {result, id(), term()}},
         Reason     :: bad_realm
                     | bad_package
                     | bad_version
                     | timeout
                     | network
                     | {unexpected, Message :: string()}.
         
         
wait_results(IDs) ->
    wait_results(IDs, []).

wait_results([], Results) ->
    {ok, Results};
wait_results(IDs, Results) ->
    receive
        {result, ID, Result} ->
            case lists:member(ID, IDs) of
                true  -> wait_results(lists:delete(ID, IDs), [{ID, Result} | Results]);
                false -> {error, {unexpected, {result, ID, Result}}, Results}
            end;
        Message ->
            {error, {unexpected, Message}}
        after 60000 ->
            {error, timeout}
    end.


-spec add_mirror(zx:host()) -> ok.

add_mirror(Host) ->
    gen_server:cast(?MODULE, {add_mirror, Host}).


-spec drop_mirror(zx:host()) -> ok.

drop_mirror(Host) ->
    gen_server:cast(?MODULE, {drop_mirror, Host}).


-spec register_key(Owner, KeyData) -> ok
    when Owner   :: zx:realm() | zx:user_id(),
         KeyData :: zx:key_data().

register_key(Owner, KeyData) ->
    gen_server:call(?MODULE, {register_key, Owner, KeyData}).


-spec get_key(Type, KeyID) -> Result
    when Type   :: public | private,
         KeyID  :: zx:key_id(),
         Result :: {ok, public_key:rsa_public_key() | public_key:rsa_private_key()}
                 | {error, Reason},
         Reason :: bad_realm
                 | no_pub
                 | no_key
                 | bad_key.

get_key(Type, KeyID) ->
    gen_server:call(?MODULE, {get_key, Type, KeyID}).


-spec get_keybin(Type, KeyID) -> Result
    when Type   :: public | private,
         KeyID  :: zx:key_id(),
         Result :: {ok, binary()}
                 | {error, file:posix()}.

get_keybin(Type, KeyID) ->
    gen_server:call(?MODULE, {get_keybin, Type, KeyID}).


% TODO: This should be an external request to a Zomp node.
% FIXME: Determine how this should work.
%-spec find_keypair(KeyName) -> Result
%    when KeyName :: zx:key_name(),
%         Result  :: {ok, zx:key_id()}
%                  | error.
%
%find_keypair(KeyName) ->
%    gen_server:call(?MODULE, {find_keypair, KeyName}).


-spec have_key(Type, KeyID) -> boolean()
    when Type  :: public | private,
         KeyID :: zx:key_id().

have_key(Type, KeyID) ->
    gen_server:call(?MODULE, {have_key, Type, KeyID}).


-spec list_keys(Type, Owner) -> Result
    when Type   :: public | private,
         Owner  :: zx:realm() | zx:user_id(),
         Result :: {ok, [zx:key_hash()]}
                 | {error, bad_realm | bad_user}.

list_keys(Type, Owner) ->
    gen_server:call(?MODULE, {list_keys, Type, Owner}).


-spec takeover(Realm) -> Result
    when Realm  :: zx:realm(),
         Result :: ok | {error, unconfigured}.

takeover(Realm) ->
    gen_server:call(?MODULE, {takeover, Realm}).


-spec abdicate(Realm) -> ok
    when Realm :: zx:realm().

abdicate(Realm) ->
    gen_server:cast(?MODULE, {abdicate, Realm}).

-spec drop_realm(Realm) -> ok
    when Realm :: zx:realm().

drop_realm(Realm) ->
    gen_server:call(?MODULE, {drop_realm, Realm}).



%% Request Caster
-spec request(action()) -> {ok, RequestID}
    when RequestID :: integer().
%% @private
%% Private function to wrap the necessary bits up.

request(Action) ->
    gen_server:call(?MODULE, {request, Action}, 60000).



%%% Upstream Zomp connection interface

-spec report(Message) -> ok
    when Message :: conn_report().
%% @private
%% Should only be called by a zx_conn. This function is how a zx_conn reports its
%% current connection status and job results.

report(Message) ->
    gen_server:cast(?MODULE, {report, self(), Message}).


-spec result(id(), result()) -> ok.
%% @private
%% Return a tagged result back to the daemon to be forwarded to the original requestor.

result(ID, Result) ->
    gen_server:cast(?MODULE, {result, ID, Result}).


-spec notify(Package, Message) -> ok
    when Package :: zx:package(),
         Message :: term().
%% @private
%% Function called by a connection when a subscribed update arrives.

notify(Package, Message) ->
    gen_server:cast(?MODULE, {notify, self(), Package, Message}).



%%% Startup

-spec start_link() -> {ok, pid()} | {error, term()}.
%% @private
%% Startup function -- intended to be called by supervisor.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, none, []).


-spec init(none) -> {ok, state()}.

init(none) ->
    State = #s{},
    {ok, State}.


-spec connect() -> ok.

connect() ->
    gen_server:cast(?MODULE, connect).


-spec disconnect() -> ok.

disconnect() ->
    gen_server:cast(?MODULE, disconnect).


-spec hosts() -> {ok, [zx:host()]}.

hosts() ->
    gen_server:call(?MODULE, hosts).


-spec conf(attribute()) -> {ok, term()} | error.

conf(Attribute) ->
    gen_server:call(?MODULE, {conf, Attribute}).


-spec conf(Attribute, Value) -> ok | error
    when Attribute :: attribute(),
         Value     :: term().

conf(Attribute, Value) ->
    gen_server:call(?MODULE, {conf, Attribute, Value}).



%%% (pre) Shutdown

idle() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Daemon    -> gen_server:call(Daemon, idle)
    end.



%%% gen_server

%% @private
%% gen_server callback for OTP calls

handle_call(get_home, _, State = #s{home = Home}) ->
    {reply, Home, State};
handle_call({dir, Type}, _, State = #s{meta = Meta}) ->
    {Realm, Name, _} = maps:get(package_id, Meta),
    Result = zx_lib:ppath(Type, {Realm, Name}),
    {reply, Result, State};
handle_call({dirv, Type}, _, State = #s{meta = Meta}) ->
    PackageID = maps:get(package_id, Meta),
    Result = zx_lib:ppath(Type, PackageID),
    {reply, Result, State};
handle_call(meta, _, State = #s{meta = Meta}) ->
    {reply, Meta, State};
handle_call(argv, _, State = #s{argv = ArgV}) ->
    {reply, ArgV, State};
handle_call({request, list}, _, State = #s{cx = CX}) ->
    Realms = cx_realms(CX),
    {reply, {ok, Realms}, State};
handle_call({request, Action}, From, State = #s{id = ID}) ->
    NewID = ID + 1,
    _ = gen_server:reply(From, {ok, NewID}),
    Requestor = element(1, From),
    NextState = do_request(Requestor, Action, State#s{id = NewID}),
    NewState = eval_queue(NextState),
    {noreply, NewState};
handle_call({fetch, PackageID, Watchers}, From, State = #s{id = ID}) ->
    NewID = ID + 1,
    ok = gen_server:reply(From, {ok, NewID}),
    Requestor = element(1, From),
    NextState = do_fetch(PackageID, Watchers, Requestor, State#s{id = NewID}),
    NewState = eval_queue(NextState),
    {noreply, NewState};
handle_call({install, Path}, _, State) ->
    Result = do_import_zsp(Path),
    NewState = eval_queue(State),
    {reply, Result, NewState};
handle_call({build, PackageID}, _, State) ->
    Result = do_build(PackageID),
    NewState = eval_queue(State),
    {reply, Result, NewState};
handle_call({get_key, Type, KeyID}, _, State) ->
    Result = do_get_key(Type, KeyID),
    NewState = eval_queue(State),
    {reply, Result, NewState};
handle_call({get_keybin, Type, KeyID}, _, State) ->
    Result = do_get_keybin(Type, KeyID),
    NewState = eval_queue(State),
    {reply, Result, NewState};
handle_call({have_key, Type, KeyID}, _, State) ->
    Result = do_have_key(Type, KeyID),
    NewState = eval_queue(State),
    {reply, Result, NewState};
handle_call({list_keys, Type, Owner}, _, State) ->
    Result = do_list_keys(Type, Owner),
    NewState = eval_queue(State),
    {reply, Result, NewState};
handle_call({register_key, Owner, Data}, _, State) ->
    Result = do_register_key(Owner, Data),
    NewState = eval_queue(State),
    {reply, Result, NewState};
handle_call({takeover, Realm}, _, State = #s{conf = Conf}) ->
    {Result, NewConf} = do_takeover(Realm, Conf),
    NewState = eval_queue(State#s{conf = NewConf}),
    {reply, Result, NewState};
handle_call({drop_realm, Realm}, _, State) ->
    NextState = do_drop_realm(Realm, State),
    NewState = eval_queue(NextState),
    {reply, ok, NewState};
handle_call(hosts, _, State = #s{cx = CX}) ->
    Result = cx_mirrors(CX),
    {reply, Result, State};
handle_call({conf, Attribute}, _, State = #s{conf = Conf}) ->
    Result = get_conf(Attribute, Conf),
    {reply, Result, State};
handle_call({conf, Attribute, Value}, _, State = #s{conf = Conf}) ->
    {Result, NewConf} = set_conf(Attribute, Value, Conf),
    {reply, Result, State#s{conf = NewConf}};
handle_call(idle, _, State) ->
    ok = do_idle(State),
    {reply, ok, State};
handle_call(Unexpected, From, State) ->
    ok = log(warning, "Unexpected call ~160tp: ~160tp", [From, Unexpected]),
    {noreply, State}.


%% @private
%% gen_server callback for OTP casts

handle_cast({pass_meta, Meta, Dir, ArgV}, State) ->
    NewState = do_pass_meta(Meta, Dir, ArgV, State),
    {noreply, NewState};
handle_cast({subscribe, Pid, Package}, State) ->
    NextState = do_subscribe(Pid, Package, State),
    NewState = eval_queue(NextState),
    {noreply, NewState};
handle_cast({unsubscribe, Pid, Package}, State) ->
    NextState = do_unsubscribe(Pid, Package, State),
    NewState = eval_queue(NextState),
    {noreply, NewState};
handle_cast({report, Conn, Message}, State) ->
    NextState = do_report(Conn, Message, State),
    NewState = eval_queue(NextState),
    {noreply, NewState};
handle_cast({result, ID, Result}, State) ->
    NextState = do_result(ID, Result, State),
    NewState = eval_queue(NextState),
    {noreply, NewState};
handle_cast({notify, Conn, Package, Update}, State) ->
    ok = do_notify(Conn, Package, Update, State),
    NewState = eval_queue(State),
    {noreply, NewState};
handle_cast(connect, State) ->
    NewState = connect(State),
    {noreply, NewState};
handle_cast(disconnect, State) ->
    NewState = wipe_connections(State),
    {noreply, NewState};
handle_cast({add_mirror, Host}, State = #s{conf = Conf}) ->
    NewConf = do_add_mirror(Host, Conf),
    NewState = eval_queue(State#s{conf = NewConf}),
    {noreply, NewState};
handle_cast({drop_mirror, Host}, State = #s{conf = Conf}) ->
    NewConf = do_drop_mirror(Host, Conf),
    NewState = eval_queue(State#s{conf = NewConf}),
    {noreply, NewState};
handle_cast({abdicate, Realm}, State) ->
    NewState = do_abdicate(Realm, State),
    {noreply, NewState};
handle_cast(zomp_mode, State) ->
    NewState = become_zomp_node(State),
    {noreply, NewState};
handle_cast(Unexpected, State) ->
    ok = log(warning, "Unexpected cast: ~160tp", [Unexpected]),
    {noreply, State}.


%% @private
%% gen_sever callback for general Erlang message handling

handle_info(reconnect, State) ->
    NewState = ensure_connections(State),
    {noreply, NewState#s{timer = none}};
handle_info({'DOWN', Ref, process, Pid, Reason}, State) ->
    NewState = clear_monitor(Pid, Ref, Reason, State),
    {noreply, NewState};
handle_info(Unexpected, State) ->
    ok = log(warning, "Unexpected info: ~160tp", [Unexpected]),
    {noreply, State}.


%% @private
%% gen_server callback to handle state transformations necessary for hot
%% code updates. This template performs no transformation.

code_change(_, State, _) ->
    {ok, State}.


%% @private
%% gen_server callback to handle shutdown/cleanup tasks on receipt of a clean
%% termination request.

terminate(_, _) -> ok.


do_idle(#s{id = ID, cx = zomp}) ->
    ok = log(info, "Idling as zomp with ID: ~p.", [ID]),
    ok = retire(ID);
do_idle(#s{cx = offline}) ->
    ok = log(info, "Idling while offline."),
    ok;
do_idle(#s{cx = proxied}) ->
    ok = log(info, "Idling while proxied."),
    ok;
do_idle(#s{id = ID, cx = CX}) ->
    ok = log(info, "Idling as prime with ID: ~p.", [ID]),
    ok = retire(ID),
    cx_store_cache(CX).


retire(ID) ->
    case zx_peer_man:retire(ID) of
        ok   -> ok;
        halt -> remove_lockfile()
    end.


write_lockfile(Port) ->
    PortString = integer_to_binary(Port),
    LockFile = lockfile(),
    zx_lib:write_terms(LockFile, PortString).


remove_lockfile() ->
    zx_lib:rm_rf(lockfile()).


lockfile() ->
    filename:join(zx_lib:zomp_dir(), "john.locke").

%%% Doer Functions

-spec do_pass_meta(Meta, Home, ArgV, State) -> NewState
    when Meta     :: zx:package_meta(),
         Home     :: file:filename(),
         ArgV     :: [string()],
         State    :: state(),
         NewState :: state().

do_pass_meta(Meta, Home, ArgV, State) ->
    State#s{meta = Meta, home = Home, argv = ArgV}.


-spec do_subscribe(Pid, Package, State) -> NextState
    when Pid       :: pid(),
         Package   :: zx:package(),
         State     :: state(),
         NextState :: state().
%% @private
%% Enqueue a subscription request.

do_subscribe(Pid, Package, State = #s{actions = Actions, mx = MX}) ->
    NewActions = [{subscribe, Pid, Package} | Actions],
    NewMX = mx_add_monitor(Pid, {subscriber, Package}, MX),
    State#s{actions = NewActions, mx = NewMX}.


-spec do_unsubscribe(Pid, Package, State) -> NextState
    when Pid       :: pid(),
         Package   :: zx:package(),
         State     :: state(),
         NextState :: state().
%% @private
%% Clear or dequeue a subscription request.

do_unsubscribe(Pid, Package, State = #s{actions = Actions, mx = MX}) ->
    {ok, NewMX} = mx_del_monitor(Pid, {subscription, Package}, MX),
    NewActions = [{unsubscribe, Pid, Package} | Actions],
    State#s{actions = NewActions, mx = NewMX}.


-spec do_request(Requestor, Action, State) -> NextState
    when Requestor :: pid(),
         Action    :: action(),
         State     :: state(),
         NextState :: state().
%% @private
%% Enqueue requests and update relevant index.

do_request(Requestor, Action, State = #s{id = ID, cx = proxied}) ->
    Result = zx_proxy:request(Action),
    Requestor ! {result, ID, Result},
    State;
do_request(_, _, #s{cx = offline}) ->
    throw("Trying to perform request while offline. Impossible! I am ded.");
do_request(Requestor, Action, State = #s{id = ID, actions = Actions, mx = MX}) ->
    NewActions = [{request, Requestor, ID, Action} | Actions],
    NewMX = mx_add_monitor(Requestor, {requestor, ID}, MX),
    State#s{actions = NewActions, mx = NewMX}.


-spec do_report(Conn, Message, State) -> NewState
    when Conn     :: pid(),
         Message  :: conn_report(),
         State    :: state(),
         NewState :: state().
%% @private
%% Receive a report from a connection process, update the connection index and
%% possibly retry connections.

do_report(Conn, Report, State = #s{cx = zomp}) ->
    ok = log(warning, "Zomp mode: Discarding report ~tp ~200tp", [Conn, Report]),
    State;
do_report(Conn, Report, State = #s{cx = proxied}) ->
    ok = log(warning, "Proxied: Discarding report ~tp ~200tp", [Conn, Report]),
    State;
do_report(Conn, Report, State = #s{cx = offline}) ->
    ok = log(warning, "Offline: Discarding report ~tp ~200tp", [Conn, Report]),
    State;
do_report(Conn, {connected, Realms}, State = #s{mx = MX, cx = CX}) ->
    {NewMX, NewCX} =
        case cx_connected(Realms, Conn, CX) of
            {assigned, NextCX} ->
                NextMX = mx_upgrade_conn(Conn, MX),
                {NextMX, NextCX};
            {unassigned, NextCX} ->
                ScrubbedMX = mx_del_monitor(Conn, attempt, MX),
                ok = zx_conn:stop(Conn),
                {ScrubbedMX, NextCX}
        end,
    State#s{mx = NewMX, cx = NewCX};
do_report(Conn, {redirect, Targets}, State = #s{mx = MX, cx = CX}) ->
    NewMX = mx_del_monitor(Conn, attempt, MX),
    NewCX = cx_redirect(Targets, CX),
    ensure_connections(State#s{mx = NewMX, cx = NewCX});
do_report(Conn, failed, State = #s{mx = MX}) ->
    NewMX = mx_del_monitor(Conn, attempt, MX),
    ensure_connections(State#s{mx = NewMX});
do_report(Conn, disconnected, State) ->
    ok = log(info, "Connection ~160tp disconnected.", [Conn]),
    recover(Conn, State);
do_report(Conn, timeout, State) ->
    ok = log(warning, "Connection ~160tp timed out.", [Conn]),
    recover(Conn, State);
do_report(Conn,
          retired,
          State = #s{actions = Actions, requests = Requests, mx = MX, cx = CX}) ->
    case mx_drop_monitor(Conn, MX) of
        {attempt, NewMX} ->
            State#s{mx = NewMX};
        {conn, NewMX} ->
            {Pending, LostSubs, NewCX} = cx_disconnected(Conn, CX),
            ReSubs = [{subscribe, S, P} || {S, P} <- LostSubs],
            {Dequeued, NewRequests} = maps:fold(dequeue(Pending), {[], #{}}, Requests),
            NewActions = Dequeued ++ ReSubs ++ Actions,
            State#s{actions  = NewActions,
                    requests = NewRequests,
                    mx       = NewMX,
                    cx       = NewCX}
    end;
do_report(Conn, {serial_update, Realm, Serial}, State) ->
    ok = log(info, "Leaf: Received serial update from ~tp for realm ~ts: ~w", [Conn, Realm, Serial]),
    State;
do_report(Conn, Report, State) ->
    ok = log(warning, "Leaf: Discarding report ~tp ~200tp", [Conn, Report]),
    State.


-spec recover(Conn, State) -> NewState
    when Conn     :: pid(),
         State    :: state(),
         NewState :: state().

recover(Conn, State = #s{actions = Actions, requests = Requests, mx = MX, cx = CX}) ->
    NewMX = mx_del_monitor(Conn, conn, MX),
    {Pending, LostSubs, NewCX} = cx_disconnected(Conn, CX),
    ReSubs = [{subscribe, S, P} || {S, P} <- LostSubs],
    {Dequeued, NewRequests} = maps:fold(dequeue(Pending), {[], #{}}, Requests),
    NewActions = Dequeued ++ ReSubs ++ Actions,
    NewState = State#s{actions  = NewActions,
                       requests = NewRequests,
                       mx       = NewMX,
                       cx       = NewCX},
    ensure_connections(NewState).


-spec dequeue(Pending) -> fun((ID, V, {D, R}) -> {NewD, NewR})
    when Pending :: [id()],
         ID      :: id(),
         V       :: {pid(), action()},
         D       :: [request()],
         R       :: requests(),
         NewD    :: [request()],
         NewR    :: requests().
%% @private
%% Return a function that partitions the current Request map into two maps, one that
%% matches the closed `Pending' list of references and ones that don't.

dequeue(Pending) ->
    fun(ID, {Pid, Action}, {D, R}) ->
        case lists:member(ID, Pending) of
            true  -> {[{request, Pid, ID, Action} | D], R};
            false -> {D, maps:put(ID, {Pid, Action}, R)}
        end
    end.


-spec connect(State) -> NewState
    when State    :: state(),
         NewState :: state().
%% @private
%% Starting from a stateless condition, recruit and resolve all realm relevant data,
%% populate host caches, and initiate connections to required realms. On completion
%% return a populated MX and CX to the caller. Should only ever be called by init/1.
%% Returns an `ok' tuple to disambiguate it from pure functions *and* to leave an
%% obvious place to populate error returns in the future if desired.

connect(State = #s{cx = zomp}) ->
    State;
connect(State = #s{cx = offline}) ->
    LockFile = lockfile(),
    case file:read_file(LockFile) of
        {ok, PS} ->
            Port = binary_to_integer(string:trim(PS)),
            ok = log(info, "Connecting to local proxy."),
            proxy_connect(Port, State);
        {error, enoent} ->
            remote_connect(cx_load(State))
    end;
connect(State) ->
    remote_connect(State).


proxy_connect(Port, State) ->
    case zx_proxy:connect(Port) of
        ok    -> State#s{cx = proxied};
        error -> remote_connect(cx_load(State))
    end.


remote_connect(State = #s{cx = CX}) ->
    LockFile = lockfile(),
    {ok, Port} = zx_peer_man:listen(),
    PortString = integer_to_binary(Port),
    ok = file:write_file(LockFile, PortString),
    {ok, Hosts} = cx_mirrors(CX),
    init_connections(Hosts, State).


init_connections([Host | Hosts], State = #s{mx = MX}) ->
    {ok, Pid} = zx_conn:start(Host),
    NewMX = mx_add_monitor(Pid, attempt, MX),
    init_connections(Hosts, State#s{mx = NewMX});
init_connections([], State) ->
    State.


ensure_connections(State = #s{cx = zomp}) ->
    State;
ensure_connections(State = #s{cx = proxied}) ->
    State;
ensure_connections(State = #s{conf = Conf, mx = MX, cx = CX}) ->
    #conf{realms = Realms, managed = Managed} = Conf,
    Unmanaged = lists:subtract(Realms, sets:to_list(Managed)),
    case cx_check_service(Unmanaged, CX) of
        {ok, NewCX} ->
            State#s{cx = NewCX};
        {connect, wait, NewCX} ->
            ok = log(info, "Host list exhausted, retrying in 5 seconds."),
            Timer = erlang:send_after(5000, self(), reconnect),
            State#s{timer = Timer, cx = NewCX};
        {connect, Host, NewCX} ->
            {ok, Pid} = zx_conn:start(Host),
            NewMX = mx_add_monitor(Pid, attempt, MX),
            State#s{mx = NewMX, cx = NewCX}
    end.


-spec wipe_connections(state()) -> ok.

wipe_connections(State = #s{cx = proxied}) ->
    ok = log(warning, "Proxied: No connections to wipe."),
    State;
wipe_connections(State = #s{cx = offline}) ->
    ok = log(warning, "Offline: No connections to wipe."),
    State;
wipe_connections(State = #s{cx = zomp}) ->
    ok = log(warning, "Zomp: No connections to wipe."),
    State;
wipe_connections(State = #s{mx = MX, cx = CX}) ->
    Pids = cx_wipe(CX),
    Remove = fun(P, M) -> mx_del_monitor(P, conn, M) end,
    NewMX = lists:foldl(Remove, MX, Pids),
    State#s{mx = NewMX, cx = offline}.


-spec do_result(ID, Result, State) -> NewState
    when ID       :: id(),
         Result   :: result(),
         State    :: state(),
         NewState :: state().
%% @private
%% Receive the result of a sent request and route it back to the original requestor.

do_result(ID, Result, State = #s{requests = Requests, dropped = Dropped, mx = MX}) ->
    {NewDropped, NewRequests, NewMX} =
        case maps:take(ID, Requests) of
            {Request, Rest} when element(1, element(2, Request)) == fetch ->
                {NextMX, NextR} = handle_fetch_result(ID, Result, Request, Rest, MX),
                {Dropped, NextR, NextMX};
            {Request, Rest} ->
                Requestor = element(1, Request),
                Requestor ! {result, ID, Result},
                NextMX = mx_del_monitor(Requestor, {requestor, ID}, MX),
                {Dropped, Rest, NextMX};
            error ->
                NextDropped = handle_orphan_result(ID, Result, Dropped),
                {NextDropped, Requests, MX}
        end,
    State#s{requests = NewRequests, dropped = NewDropped, mx = NewMX}.


handle_fetch_result(ID, {done, Bin}, {Requestor, {fetch, R, N, V, _}}, Requests, MX) ->
    Result =
        case do_import_package(Bin) of
            ok ->
                Path = zx_lib:zsp_path({R, N, V}),
                ok = filelib:ensure_dir(Path),
                ok = file:write_file(Path, Bin),
                done;
            Error ->
                Error
        end,
    Requestor ! {result, ID, Result},
    NextMX = mx_del_monitor(Requestor, {requestor, ID}, MX),
    {NextMX, Requests};
handle_fetch_result(ID, Hops = {hops, _}, Request = {Requestor, _}, Requests, MX) ->
    Requestor ! {result, ID, Hops},
    {MX, maps:put(ID, Request, Requests)};
handle_fetch_result(ID, Outcome, {Requestor, _}, Requests, MX) ->
    Requestor ! {result, ID, Outcome},
    NextMX = mx_del_monitor(Requestor, {requestor, ID}, MX),
    {NextMX, Requests}.


-spec handle_orphan_result(ID, Result, Dropped) -> NewDropped
    when ID         :: id(),
         Result     :: result(),
         Dropped    :: requests(),
         NewDropped :: requests().
%% @private
%% Log request results if they have been orphaned by their original requestor.
%% Log a warning if the result is totally unknown.

handle_orphan_result(ID, Result, Dropped) ->
    case maps:take(ID, Dropped) of
        {Request, NewDropped} ->
            Message = "Received orphan result for ~160tp, ~160tp: ~160tp",
            ok = log(info, Message, [ID, Request, Result]),
            NewDropped;
        error ->
            Message = "Received untracked request result ~160tp: ~160tp",
            ok = log(warning, Message, [ID, Result]),
            Dropped
    end.


-spec do_notify(Conn, Channel, Message, State) -> ok
    when Conn    :: pid(),
         Channel :: term(),
         Message :: term(),
         State   :: state().
%% @private
%% Broadcast a subscription message to all subscribers of a channel.
%% At the moment the only possible sub channels are packages, but this will almost
%% certainly change in the future to include general realm update messages (new keys,
%% packages, user announcements, etc.) and whatever else becomes relevant as the
%% system evolves. The types here are deliberately a bit abstract to prevent future
%% type tracing with Dialyzer, since we know the functions calling this routine and
%% are already tightly typed.

do_notify(Conn, Channel, Message, #s{cx = CX}) ->
    Subscribers = cx_get_subscribers(Conn, Channel, CX),
    Notify = fun(P) -> P ! {z_sub, Channel, Message} end,
    lists:foreach(Notify, Subscribers).


-spec eval_queue(State) -> NewState
    when State    :: state(),
         NewState :: state().
%% @private
%% This is one of the two engines that drives everything, the other being do_report/3.
%% This function must iterate as far as it can into the request queue, adding response
%% entries to the pending response structure as it goes.

eval_queue(State = #s{cx = proxied}) ->
    State;
eval_queue(State = #s{actions = Actions}) ->
    InOrder = lists:reverse(Actions),
    eval_queue(InOrder, State#s{actions = []}).


-spec eval_queue(Actions, State) -> NewState
    when Actions  :: [action()],
         State    :: state(),
         NewState :: state().
%% @private
%% This is essentially a big, gnarly fold over the action list with State as the
%% accumulator. It repacks the State#s.actions list with whatever requests were not
%% able to be handled and updates State in whatever way necessary according to the
%% handled requests.

eval_queue([], State) ->
    State;
eval_queue(Actions, State = #s{cx = zomp}) ->
    local_dispatch(Actions, State);
eval_queue(Actions, State) ->
    remote_dispatch(Actions, State).


local_dispatch([], State) ->
    State;
local_dispatch([{request, Pid, ID, {fetch, R, N, V, _}} | Rest], State) ->
    Result =
        case zomp_realm_man:lookup(R) of
            {ok, RealmPID} -> local_fetch(RealmPID, {R, N, V});
            Error          -> Error
        end,
    Pid ! {result, ID, Result},
    local_dispatch(Rest, State);
local_dispatch([{request, Pid, ID, Message} | Rest], State) ->
    Realm = element(2, Message),
    Result =
        case zomp_realm_man:lookup(Realm) of
            {ok, RealmPid} ->
                Stripped = erlang:delete_element(2, Message),
                local_request(RealmPid, Stripped);
            Error ->
                Error
        end,
    Pid ! {result, ID, Result},
    local_dispatch(Rest, State);
local_dispatch([{subscribe, Pid, RP = {Realm, Package}} | Rest], State) ->
    case zomp_realm_man:lookup(Realm) of
        {ok, RealmP} ->
            {ok, Serial} = zomp_realm:subscribe(RealmP, Package),
            Pid ! {notify, subscribed, RP, Serial};
        Error ->
            Pid ! {notify, error, RP, Error}
    end,
    local_dispatch(Rest, State);
local_dispatch([{unsubscribe, Pid, {Realm, Package}} | Rest], State) ->
    ok =
        case zomp_realm_man:lookup(Realm) of
            {ok, RealmP} ->
                zomp_realm:unsubscribe(RealmP, Package);
            Error ->
                Message = "Unsubscribe ~tp from ~tp failed with ~tp",
                log(warning, Message, [Pid, {Realm, Package}, Error])
        end,
    local_dispatch(Rest, State).


local_request(R, {list})            -> zomp_realm:list(R);
local_request(R, {list, N})         -> zomp_realm:list(R, N);
local_request(R, {list, N, V})      -> zomp_realm:list(R, {N, V});
local_request(R, {latest, N})       -> zomp_realm:latest(R, N);
local_request(R, {latest, N, V})    -> zomp_realm:latest(R, {N, V});
local_request(R, {describe, N, V})  -> zomp_realm:describe(R, {N, V});
local_request(R, {provides, M})     -> zomp_realm:provides(R, M);
local_request(R, {search, S})       -> zomp_realm:search(R, S);
local_request(R, {list_deps, N, V}) -> zomp_realm:list_deps(R, {N, V});
local_request(R, {list_sysops})     -> zomp_realm:list_sysops(R);
local_request(R, {list_type, T})    -> zomp_realm:list_type(R, T).


local_fetch(RealmPID, PackageID = {_, N, V}) ->
    {ok, PackageString} = zx_lib:package_string(PackageID),
    ok = tell("Fetching ~s", [PackageString]),
    case zomp_realm:fetch(RealmPID, {N, V}) of
        {ok, Bin} -> do_import_package(Bin);
        upstream  -> local_fetch_upstream(PackageID, 0);
        Error     -> Error
    end.

local_fetch_upstream(PackageID, Tries) ->
    Realm = element(1, PackageID),
    case zomp_node_man:lookup(Realm) of
        {ok, NodePID} ->
            ok = tell("Found node connector at ~p", [NodePID]),
            ok = zomp_node:fetch(NodePID, PackageID),
            wait_hops(PackageID);
        wait ->
            wait_upstream_node(PackageID, Tries);
        error ->
            {error, bad_realm}
    end.

wait_hops(PackageID) ->
    receive
        {ok, PackageID, Bin} ->
            do_import_package(Bin);
        {hops, PackageID, Distance} ->
            ok = tell("Fetch in progress. Hops: ~w", [Distance]),
            wait_hops(PackageID)
        after 60000 ->
            {error, timeout}
    end.

wait_upstream_node(PackageID, Tries) when Tries < 10 ->
    _ = erlang:send_after(1000, self(), retry),
    receive retry -> local_fetch_upstream(PackageID, Tries + 1) end;
wait_upstream_node(_, _) ->
    {error, timeout}.


remote_dispatch([], State) ->
    State;
remote_dispatch([Action = {request, Pid, ID, Message} | Rest],
                State = #s{actions = Actions, requests = Requests, cx = CX}) ->
    {NewActions, NewRequests, NewCX} =
        case dispatch_request(Message, ID, CX) of
            {dispatched, NextCX} ->
                NextRequests = maps:put(ID, {Pid, Message}, Requests),
                {Actions, NextRequests, NextCX};
            wait ->
                NextActions = [Action | Actions],
                {NextActions, Requests, CX};
            Result ->
                Pid ! {result, ID, Result},
                {Actions, Requests, CX}
        end,
    NewState = State#s{actions = NewActions, requests = NewRequests, cx = NewCX},
    remote_dispatch(Rest, NewState);
remote_dispatch([Action = {subscribe, Pid, Package} | Rest],
           State = #s{actions = Actions, cx = CX}) ->
    {NewActions, NewCX} =
        case cx_add_sub(Pid, Package, CX) of
            {need_sub, Conn, NextCX} ->
                ok = zx_conn:subscribe(Conn, Package),
                {Actions, NextCX};
            {have_sub, NextCX} ->
                {Actions, NextCX};
            unassigned ->
                {[Action | Actions], CX};
            unconfigured ->
                Pid ! {z_sub, Package, {error, bad_realm}},
                {Actions, CX}
        end,
    remote_dispatch(Rest, State#s{actions = NewActions, cx = NewCX});
remote_dispatch([{unsubscribe, Pid, Package} | Rest], State = #s{cx = CX}) ->
    NewCX =
        case cx_del_sub(Pid, Package, CX) of
            {{drop_sub, ConnPid}, NextCX} ->
                ok = zx_conn:unsubscribe(ConnPid, Package),
                NextCX;
            {keep_sub, NextCX} ->
                NextCX;
            unassigned ->
                CX;
            unconfigured ->
                M = "Received 'unsubscribe' request for unconfigured realm: ~160tp",
                ok = log(warning, M, [Package]),
                CX
        end,
    remote_dispatch(Rest, State#s{cx = NewCX}).


-spec dispatch_request(Message, ID, CX) -> Result
    when Message  :: action(),
         ID       :: id(),
         CX       :: conn_index(),
         Result   :: {dispatched, NewCX}
                   | {result, Response}
                   | wait,
         NewCX    :: conn_index(),
         Response :: result().
%% @private
%% Routes a request to the correct realm connector, if it is available. If it is not
%% available but configured it will return `wait' indicating that the caller should
%% repack the request and attempt to re-evaluate it later. If the realm is not
%% configured at all, the process is short-circuited by forming an error response
%% directly.

dispatch_request(Message, ID, CX) ->
    Realm = element(2, Message),
    case cx_pre_send(Realm, ID, CX) of
        {ok, Conn, NewCX} ->
            ok = zx_conn:request(Conn, ID, Message),
            {dispatched, NewCX};
        unassigned ->
            wait;
        unconfigured ->
            {error, bad_realm}
    end.


-spec clear_monitor(Pid, Ref, Reason, State) -> NewState
    when Pid      :: pid(),
         Ref      :: reference(),
         Reason   :: term(),
         State    :: state(),
         NewState :: state().
%% @private
%% Deal with a crashed requestor, subscriber or connector.

clear_monitor(Pid,
              Ref,
              Reason,
              State = #s{actions  = Actions,
                         requests = Requests,
                         dropped  = Dropped,
                         mx       = MX,
                         cx       = CX}) ->
    case mx_drop_monitor(Pid, MX) of
        {attempt, NewMX} ->
            ensure_connections(State#s{mx = NewMX});
        {conn, NewMX} ->
            recover(Pid, State#s{mx = NewMX});
        {{Reqs, Subs}, NewMX} ->
            NewActions = drop_actions(Pid, Actions),
            {NewDropped, NewRequests} = drop_requests(Reqs, Dropped, Requests),
            NewCX = cx_clear_client(Pid, Reqs, Subs, CX),
            State#s{actions  = NewActions,
                    requests = NewRequests,
                    dropped  = NewDropped,
                    mx       = NewMX,
                    cx       = NewCX};
        unknown ->
            Unexpected = {'DOWN', Ref, process, Pid, Reason},
            ok = log(warning, "Unexpected info: ~160tp", [Unexpected]),
            State
    end.


-spec drop_actions(Requestor, Actions) -> NewActions
    when Requestor  :: pid(),
         Actions    :: [request()],
         NewActions :: [request()].

drop_actions(Pid, Actions) ->
    Clear =
        fun
            ({request, P, _, _})  -> P /= Pid;
            ({subscribe, P, _})   -> P /= Pid;
            ({unsubscribe, _, _}) -> false
        end,
    lists:filter(Clear, Actions).


-spec drop_requests(ReqIDs, Dropped, Requests) -> {NewDropped, NewRequests}
    when ReqIDs      :: [id()],
         Dropped     :: requests(),
         Requests    :: requests(),
         NewDropped  :: requests(),
         NewRequests :: requests().

drop_requests(ReqIDs, Dropped, Requests) ->
    Partition =
        fun(K, {Drop, Keep}) ->
            case maps:take(K, Keep) of
                {V, NewKeep} -> 
                    NewDrop = maps:put(K, V, Drop),
                    {NewDrop, NewKeep};
                error ->
                    {Drop, Keep}
            end
        end,
    lists:foldl(Partition, {Dropped, Requests}, ReqIDs).


-spec do_fetch(PackageID, Watchers, Requestor, State) -> NewState
    when PackageID :: zx:package_id(),
         Watchers  :: [pid()],
         Requestor :: pid(),
         State     :: state(),
         NewState  :: state().
%% @private
%% Provide a chance to bypass if the package is in cache.

do_fetch(PackageID, Watchers, Requestor, State = #s{id = ID}) ->
    {ok, PackageString} = zx_lib:package_string(PackageID),
    ok = log(info, "Fetching ~ts", [PackageString]),
    Path = zx_lib:zsp_path(PackageID),
    case file:read_file(Path) of
        {ok, Bin} ->
            ok = do_fetch2(Bin, Requestor, ID),
            State;
        {error, enoent} ->
            {Realm, Name, Version} = PackageID,
            Action = {fetch, Realm, Name, Version, Watchers},
            do_request(Requestor, Action, State);
        Error ->
            Requestor ! {result, ID, Error},
            State
    end.

do_fetch2(Bin, Requestor, ID) ->
    Result =
        case do_import_package(Bin) of
            ok    -> done;
            Error -> Error
        end,
    Requestor ! {result, ID, Result},
    ok.


-spec do_import_zsp(file:filename()) -> zx:outcome().
%% @private
%% Dealing with data from the (probably local) filesystem can fail in a bajillion ways
%% and spring memory leaks if one tries to get too clever. So I'm sidestepping all the
%% madness with a "try++" here by spawning a suicidal helper.

do_import_zsp(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> do_import_package(Bin);
        Error     -> Error
    end.


do_import_package(Bin) ->
    {Pid, Mon} = spawn_monitor(fun() -> import_package(Bin) end),
    receive
        {Pid, Outcome} ->
            true = demonitor(Mon, [flush]),
            Outcome;
        {'DOWN', Pid, process, Mon, Info} ->
            {error, Info}
        after 5000 ->
            {error, timeout}
    end.


-spec import_package(binary()) -> no_return().
%% @private
%% The happy path of .zsp installation.
%% Must not be executed by the zx_daemon directly.
%%
%% More generally, there are a few phases:
%% 1- Loading the binary to extract the PackageID
%% 2- Checking the signature
%% 3- Moving the file to the cache
%% 4- Wiping the destination directory
%% 5- Extracting the TarGz to the destination
%% Some combination of functions should make these steps happen in a way that isn't
%% totally ridiculous, OR the bullet should just be bitten an allow for the
%% redundant lines here and there in different package management functions.
%%
%% Use cases are:
%% - Install a missing package from upstream
%% - Install a missing package from the local cache
%% - Reinstall a package from the local cache
%% - Import a package to the cache from the local filesystem and install it
%%
%% The Correct Approach as determine by The Royal Me is that I'm going to accept the
%% redundant code in the short-term because the data format is already decided.
%% If a place to get more fancy with the phases becomes really obvious after writing
%% identicalish segements of functions a few places then I'll break things apart.

import_package(ZspBin) ->
    Result = zx_zsp:extract(ZspBin, lib),
    zx_daemon ! {self(), Result}.
    

-spec do_build(zx:package_id()) -> zx:outcome().
%% @private
%% Build a project from source.

do_build(PackageID) ->
    {Pid, Mon} = spawn_monitor(fun() -> make(PackageID) end),
    receive
        {Pid, Outcome} ->
            true = demonitor(Mon, [flush]),
            Outcome;
        {'DOWN', Pid, process, Mon, Info} ->
            {error, Info}
    end.


-spec make(zx:package_id()) -> no_return().
%% @private
%% Keep (the highly uncertain) build procedure separate from the zx_daemon, but
%% still sequentialized by it.

make(PackageID = {Realm, Name, _}) ->
    Dirs = [zx_lib:path(D, Realm, Name) || D <- [etc, var, tmp, log]],
    ok = lists:foreach(fun zx_lib:force_dir/1, Dirs),
    LibDir = zx_lib:ppath(lib, PackageID),
    ok = zx_lib:force_dir(LibDir),
    ok = file:set_cwd(LibDir),
    Result = zx_lib:build(),
    zx_daemon ! {self(), Result}.



%%% Config Functions

load_conf() ->
    Path = conf_path(),
    case file:consult(Path) of
        {ok, Settings} ->
            populate_conf(Settings);
        {error, Reason} ->
            ok = log(error, "Load ~160tp failed with: ~160tp", [Path, Reason]),
            Data = #conf{},
            ok = save_conf(Data),
            Data
    end.


populate_conf(Settings) ->
    Timeout =
        case proplists:get_value(timeout, Settings, 5) of
            TO when is_integer(TO) and TO > 0 -> TO;
            _                                 -> 5
        end,
    Retries =
        case proplists:get_value(retries, Settings, 3) of
            RT when is_integer(RT) and RT > 0 -> RT;
            _                                 -> 3
        end,
    MaxConn =
        case proplists:get_value(maxconn, Settings, 5) of
            MC when is_integer(MC) and MC > 0 -> MC;
            _                                 -> 5
        end,
    Managed =
        case proplists:get_value(managed, Settings, []) of
            MN when is_list(MN) -> sets:from_list(MN);
            _                   -> sets:new()
        end,
    Mirrors =
        case proplists:get_value(mirrors, Settings, []) of
            MR when is_list(MR) -> sets:from_list(MR);
            _                   -> sets:new()
        end,
    Status =
        case proplists:get_value(status, Settings, listen) of
            listen -> listen;
            ignore -> ignore;
            _      -> listen
        end,
    ListenPort =
        case proplists:get_value(listen_port, Settings, 11311) of
            LP when is_integer(LP) and (LP > 0) and (LP < 16#10000) -> LP;
            _                                                       -> 11311
        end,
    PublicPort =
        case proplists:get_value(listen_port, Settings, 11311) of
            PP when is_integer(PP) and (PP > 0) and (PP < 16#10000) -> PP;
            _                                                       -> 11311
        end,
    NodeMax =
        case proplists:get_value(node_max, Settings, 16#10) of
            NM when is_integer(NM) and (NM >= 0) -> NM;
            _                                    -> 16#10
        end,
    VampMax =
        case proplists:get_value(vamp_max, Settings, 16#10) of
            VM when is_integer(VM) and (VM >= 0) -> VM;
            _                                    -> 16#10
        end,
    LeafMax =
        case proplists:get_value(leaf_max, Settings, 16#100) of
            LM when is_integer(LM) and (LM >= 0) -> LM;
            _                                    -> 16#100
        end,
    #conf{timeout     = Timeout,
          retries     = Retries,
          maxconn     = MaxConn,
          managed     = Managed,
          mirrors     = Mirrors,
          status      = Status,
          listen_port = ListenPort,
          public_port = PublicPort,
          node_max    = NodeMax,
          vamp_max    = VampMax,
          leaf_max    = LeafMax}.


-spec save_conf(conf()) -> ok.
%% @doc
%% Save the current etc/sys.conf to disk.

save_conf(#conf{timeout     = Timeout,
                retries     = Retries,
                maxconn     = MaxConn,
                managed     = Managed,
                mirrors     = Mirrors,
                status      = Status,
                listen_port = ListenPort,
                public_port = PublicPort,
                node_max    = NodeMax,
                vamp_max    = VampMax,
                leaf_max    = LeafMax}) ->
    Terms =
        [{timeout,     Timeout},
         {retries,     Retries},
         {maxconn,     MaxConn},
         {managed,     sets:to_list(Managed)},
         {mirrors,     sets:to_list(Mirrors)},
         {status,      Status},
         {listen_port, ListenPort},
         {public_port, PublicPort},
         {node_max,    NodeMax},
         {vamp_max,    VampMax},
         {leaf_max,    LeafMax}],
    Path = conf_path(),
    ok = zx_lib:write_terms(Path, Terms),
    log(info, "Wrote etc/sys.conf").


-spec conf_path() -> file:filename().
%% @private
%% Return the path to $ZOMP_DIR/etc/sys.conf.

conf_path() ->
    filename:join(zx_lib:path(etc), "sys.conf").


-spec get_conf(attribute(), conf()) -> {ok, term()} | error.

get_conf(realms,      #conf{realms      = V}) -> {ok, V};
get_conf(managed,     #conf{managed     = V}) -> {ok, sets:to_list(V)};
get_conf(mirrors,     #conf{mirrors     = V}) -> {ok, sets:to_list(V)};
get_conf(timeout,     #conf{timeout     = V}) -> {ok, V};
get_conf(retries,     #conf{retries     = V}) -> {ok, V};
get_conf(maxconn,     #conf{maxconn     = V}) -> {ok, V};
get_conf(status,      #conf{status      = V}) -> {ok, V};
get_conf(listen_port, #conf{listen_port = V}) -> {ok, V};
get_conf(public_port, #conf{public_port = V}) -> {ok, V};
get_conf(node_max,    #conf{node_max    = V}) -> {ok, V};
get_conf(vamp_max,    #conf{vamp_max    = V}) -> {ok, V};
get_conf(leaf_max,    #conf{leaf_max    = V}) -> {ok, V};
get_conf(_, _)                                -> error.


-spec set_conf(Attribute, Value, Conf) -> Result
    when Attribute :: attribute(),
         Value     :: term(),
         Conf      :: conf(),
         Result    :: {ok, NewConf}
                    | {error, Conf},
         NewConf   :: conf().

set_conf(managed,     V, C) -> {ok,    C#conf{managed     = V}};
set_conf(mirrors,     V, C) -> {ok,    C#conf{mirrors     = V}};
set_conf(timeout,     V, C) -> {ok,    C#conf{timeout     = V}};
set_conf(retries,     V, C) -> {ok,    C#conf{retries     = V}};
set_conf(maxconn,     V, C) -> {ok,    C#conf{maxconn     = V}};
set_conf(status,      V, C) -> {ok,    C#conf{status      = V}};
set_conf(listen_port, V, C) -> {ok,    C#conf{listen_port = V}};
set_conf(public_port, V, C) -> {ok,    C#conf{public_port = V}};
set_conf(node_max,    V, C) -> {ok,    C#conf{node_max    = V}};
set_conf(vamp_max,    V, C) -> {ok,    C#conf{vamp_max    = V}};
set_conf(leaf_max,    V, C) -> {ok,    C#conf{leaf_max    = V}};
set_conf(_,           _, C) -> {error, C}.


-spec do_add_mirror(Host, Conf) -> NewConf
    when Host    :: zx:host(),
         Conf    :: conf(),
         NewConf :: conf().

do_add_mirror(Host, C = #conf{mirrors = Mirrors}) ->
    NewMirrors = sets:add_element(Host, Mirrors),
    NewC = C#conf{mirrors = NewMirrors},
    ok = save_conf(NewC),
    NewC.


-spec do_drop_mirror(Host, Conf) -> NewConf
    when Host    :: zx:host(),
         Conf    :: conf(),
         NewConf :: conf().

do_drop_mirror(Host, C = #conf{mirrors = Mirrors}) ->
    NewMirrors = sets:del_element(Host, Mirrors),
    NewC = C#conf{mirrors = NewMirrors},
    ok = save_conf(NewC),
    NewC.


-spec do_takeover(Realm, Conf) -> {Result, NewConf}
    when Realm   :: zx:realm(),
         Conf    :: conf(),
         Result  :: ok
                  | {error, unconfigured},
         NewConf:: conf().
%% @private
%% Assume responsibilities as the prime node for the given realm. Only works if
%% the realm exists, of course.

do_takeover(Realm, C = #conf{realms = Realms, managed = Managed}) ->
    case lists:member(Realm, Realms) of
        true ->
            NewManaged = sets:add_element(Realm, Managed),
            NewC = C#conf{managed = NewManaged},
            ok = save_conf(NewC),
            ok = log(info, "Managing realm: ~160tp", [Realm]),
            {ok, NewC};
        false ->
            ok = log(warning, "Cannot manage unconfigured realm: ~160tp", [Realm]),
            {{error, unconfigured}, C}
    end.


-spec do_abdicate(Realm, State) -> NewState
    when Realm    :: zx:realm(),
         State    :: state(),
         NewState :: state().

do_abdicate(Realm, State = #s{conf = C = #conf{managed = Managed}}) ->
    case sets:is_element(Realm, Managed) of
        true ->
            NewManaged = sets:del_element(Realm, Managed),
            NewC = C#conf{managed = NewManaged},
            ok = save_conf(NewC),
            ok = log(info, "No longer managing realm: ~160tp", [Realm]),
            State#s{conf = NewC};
        false ->
            State
    end.


%%% Key Functions

-spec do_register_key(Owner, KeyData) -> Result
    when Owner    :: zx:realm() | zx:user_id(),
         KeyData  :: zx:key_data(),
         Result   :: ok
                   | {error, Reason},
         Reason   :: bad_user
                   | bad_realm
                   | file:posix().

do_register_key(Owner = {Realm, UserName}, KeyData) ->
    case zx_userconf:load(Owner) of
        {ok, UC} ->
            do_register_key2(Realm, UC, KeyData);
        {error, bad_user} ->
            UC = zx_userconf:new(),
            NewUC = UC#{realm => Realm, username => UserName},
            do_register_key2(Realm, NewUC, KeyData);
        Error ->
            Error
    end.


do_register_key2(Realm, UC = #{keys := Keys}, KeyData = {KeyHash, _, _}) ->
    NewUC =
        case lists:member(KeyHash, Keys) of
            false -> UC#{keys => [KeyHash | Keys]};
            true  -> UC
        end,
    ok = zx_userconf:save(NewUC),
    do_register_key3(Realm, KeyData).

do_register_key3(Realm, {KeyHash, none, {_, Key}}) ->
    ok = zx_key:save_bin(private, {Realm, KeyHash}, Key),
    tell(info, "Imported record locally, including a PRIVATE key.");
do_register_key3(Realm, {KeyHash, {_, Pub}, none}) ->
    ok = zx_key:save_bin(public, {Realm, KeyHash}, Pub),
    tell(info, "Imported record locally, including a public key.");
do_register_key3(Realm, {KeyHash, {_, Pub}, {_, Key}}) ->
    ok = zx_key:save_bin(public, {Realm, KeyHash}, Pub),
    ok = zx_key:save_bin(private, {Realm, KeyHash}, Key),
    tell(info, "Imported record locally, including public and PRIVATE keys.");
do_register_key3(_, {_, none, none}) ->
    tell(info, "Imported record locally, but the record included NO keys.").


-spec do_get_key(Type, KeyID) -> Result
    when Type   :: public | private,
         KeyID  :: zx:key_id(),
         Result :: {ok, public_key:rsa_public_key() | public_key:rsa_private_key()}
                 | {error, Reason},
         Reason :: bad_realm
                 | no_pub
                 | no_key
                 | file:posix().

do_get_key(Type, KeyID) ->
    zx_key:load(Type, KeyID).


-spec do_get_keybin(Type, KeyID) -> Result
    when Type   :: public | private,
         KeyID  :: zx:key_id(),
         Result :: {ok, binary()}
                 | {error, bad_realm | no_key | no_pub | file:posix()}.

do_get_keybin(Type, KeyID) ->
    zx_key:load_bin(Type, KeyID).


-spec do_have_key(Type, KeyID) -> boolean()
    when Type  :: public | private,
         KeyID :: zx:key_id().

do_have_key(Type, KeyID) ->
    zx_key:exists(Type, KeyID).


-spec do_list_keys(Type, Owner) -> Result
    when Type   :: public | private,
         Owner  :: zx:realm() | zx:user_id(),
         Result :: {ok, [zx:key_hash()]}
                 | {error, bad_realm | bad_user}.

do_list_keys(Type, UserID = {Realm, _}) ->
    case zx_userconf:load(UserID) of
        {ok, #{keys := Keys}} -> do_list_keys2(Type, [{Realm, K} || K <- Keys]);
        Error                 -> Error
    end;
do_list_keys(Type, Realm) ->
    case zx_lib:load_realm_conf(Realm) of
        {ok, #{key := Key}} -> do_list_keys2(Type, [{Realm, Key}]);
        Error               -> Error
    end.

do_list_keys2(Type, KeyIDs) ->
    Exists = fun(ID) -> zx_key:exists(Type, ID) end,
    {ok, lists:filter(Exists, KeyIDs)}.


-spec do_drop_realm(Realm, State) -> NewState
    when Realm    :: zx:realm(),
         State    :: state(),
         NewState :: state().

do_drop_realm(Realm, State) ->
    Dirs = [etc, var, tmp, log, key, zsp, lib],
    RM = fun(D) -> ok = zx_lib:rm_rf(zx_lib:path(D, Realm)) end,
    ok = lists:foreach(RM, Dirs),
    do_abdicate(Realm, State).


-spec become_zomp_node(State) -> NewState
    when State    :: state(),
         NewState :: state().

become_zomp_node(State = #s{cx = zomp}) ->
    ok = log(warning, "Already set as zomp node."),
    State;
become_zomp_node(State = #s{cx = offline}) ->
    State#s{cx = zomp};
become_zomp_node(State = #s{cx = proxied}) ->
    {ok, Port} = zx_peer_man:listen(),
    ok = write_lockfile(Port),
    {ok, ID} = zx_proxy:youre_fired(),
    State#s{id = ID, cx = zomp};
become_zomp_node(State) ->
    NewState = wipe_connections(State),
    NewState#s{cx = zomp}.


%%% Monitor Index ADT Interface Functions

-spec mx_new() -> monitor_index().
%% @private
%% Returns a new, empty monitor index.

mx_new() ->
    maps:new().


-spec mx_add_monitor(Pid, Category, MX) -> NewMX
    when Pid      :: pid(),
         Category :: {requestor, id()}
                   | {subscriber, Sub :: tuple()}
                   | attempt,
         MX       :: monitor_index(),
         NewMX    :: monitor_index().
%% @private
%% Begin monitoring the given Pid, keeping track of its category.

mx_add_monitor(Pid, {subscriber, Sub}, MX) ->
    case maps:take(Pid, MX) of
        {{Ref, {Reqs, Subs}}, NextMX} ->
            maps:put(Pid, {Ref, {Reqs, [Sub | Subs]}}, NextMX);
        error ->
            Ref = monitor(process, Pid),
            maps:put(Pid, {Ref, {[], [Sub]}}, MX)
    end;
mx_add_monitor(Pid, {requestor, Req}, MX) ->
    case maps:take(Pid, MX) of
        {{Ref, {Reqs, Subs}}, NextMX} ->
            maps:put(Pid, {Ref, {[Req | Reqs], Subs}}, NextMX);
        error ->
            Ref = monitor(process, Pid),
            maps:put(Pid, {Ref, {[Req], []}}, MX)
    end;
mx_add_monitor(Pid, attempt, MX) ->
    false = maps:is_key(Pid, MX),
    Ref = monitor(process, Pid),
    maps:put(Pid, {Ref, attempt}, MX).


-spec mx_upgrade_conn(Pid, MX) -> NewMX
    when Pid    :: pid(),
         MX     :: monitor_index(),
         NewMX  :: monitor_index().
%% @private
%% Upgrade an `attempt' monitor to a `conn' monitor.

mx_upgrade_conn(Pid, MX) ->
    {{Ref, attempt}, NextMX} = maps:take(Pid, MX),
    maps:put(Pid, {Ref, conn}, NextMX).


-spec mx_del_monitor(Conn, Category, MX) -> NewMX
    when Conn        :: pid(),
         Category    :: attempt
                      | conn
                      | {requestor, id()}
                      | {subscriber, Sub :: tuple()},
         MX          :: monitor_index(),
         NewMX       :: monitor_index().
%% @private
%% Drop a monitor category, removing the entire monitor in the case only one category
%% exists. Returns a tuple including the remaining request references in the case of
%% a conn type.

mx_del_monitor(Pid, Category, MX) ->
    case maps:is_key(Pid, MX) of
        true  -> mx_del_monitor2(Pid, Category, MX);
        false -> MX
    end.

mx_del_monitor2(Pid, attempt, MX) ->
    {{Ref, attempt}, NewMX} = maps:take(Pid, MX),
    true = demonitor(Ref, [flush]),
    NewMX;
mx_del_monitor2(Pid, conn, MX) ->
    {{Ref, conn}, NewMX} = maps:take(Pid, MX),
    true = demonitor(Ref, [flush]),
    NewMX;
mx_del_monitor2(Pid, {requestor, Req}, MX) ->
    case maps:take(Pid, MX) of
        {{Ref, {[Req], []}}, NextMX} ->
            true = demonitor(Ref, [flush]),
            NextMX;
        {{Ref, {Reqs, Subs}}, NextMX} ->
            NewReqs = lists:delete(Req, Reqs),
            maps:put(Pid, {Ref, {NewReqs, Subs}}, NextMX)
    end;
mx_del_monitor2(Pid, {subscriber, Sub}, MX) ->
    case maps:take(Pid, MX) of
        {{Ref, {[], [Sub]}}, NextMX} ->
            true = demonitor(Ref, [flush]),
            NextMX;
        {{Ref, {Reqs, Subs}}, NextMX} ->
            NewSubs = lists:delete(Sub, Subs),
            maps:put(Pid, {Ref, {Reqs, NewSubs}}, NextMX)
    end.


-spec mx_drop_monitor(Pid, MX) -> Result
    when Pid    :: pid(),
         MX     :: monitor_index(),
         Result :: {Type, NewMX}
                 | error,
         Type   :: attempt
                 | conn
                 | {Reqs :: [id()], Subs :: [tuple()]},
         NewMX  :: monitor_index().

mx_drop_monitor(Pid, MX) ->
    case maps:take(Pid, MX) of
        {{Ref, Type}, NewMX} ->
            true = demonitor(Ref, [flush]),
            {Type, NewMX};
        error ->
            unknown
    end.



%%% Connection Index ADT Interface Functions
%%%
%%% Functions to manipulate the conn_index() data type are in this section. This
%%% data should be treated as abstract by functions outside of this section, as it is
%%% a deep structure and future requirements are likely to wind up causing it to
%%% change a little. For the same reason, these functions are all pure, independently
%%% testable, and have no side effects.
%%%
%%% Return values often carry some status information with them.


-spec cx_load(state()) -> state().
%% @private
%% Used to load a connection index populated with necessary realm configuration data
%% and cached mirror data, if such things can be found in the system, otherwise return
%% a blank connection index structure.

cx_load(State = #s{conf = Conf}) ->
    case cx_populate(Conf) of
        {ok, CX} ->
            State#s{cx = CX};
        {error, Reason} ->
            Message = "Realm data and host cache load failed with : ~160tp",
            ok = log(error, Message, [Reason]),
            ok = log(warning, "No realms configured."),
            State#s{cx = #cx{}}
    end.


-spec cx_populate(Conf) -> Result
    when Conf   :: conf(),
         Result :: {ok, conn_index()}
                 | {error, Reason},
         Reason :: no_realms
                 | file:posix().
%% @private
%% This procedure, relying zx_lib:zomp_dir() allows the system to load zomp data
%% from any arbitrary home for zomp. This has been included mostly to make testing of
%% Zomp and ZX easier, but incidentally opens the possibility that an arbitrary Zomp
%% home could be selected by an installer (especially on consumer systems like Windows
%% where any number of wild things might be going on in the user's filesystem).

cx_populate(#conf{realms = Realms, managed = Managed,  mirrors = Mirrors}) ->
    Populate = cx_populator(sets:to_list(Managed)),
    MirrorList = queue:from_list(sets:to_list(Mirrors)),
    {Records, Canonical} = lists:foldl(Populate, {[], MirrorList}, Realms),
    Hosts = cx_load_hosts_cache(),
    {ok, #cx{realms = maps:from_list(Records), mirrors = Canonical, hosts = Hosts}}.


-spec cx_populator(Managed) -> fun((Realm, CX) -> NewCX)
    when Managed :: [zx:realm()],
         Realm   :: zx:realm(),
         CX      :: [{zx:realm(), realm_meta()}],
         NewCX   :: [{zx:realm(), realm_meta()}].
%% @private
%% Pack an initially empty conn_index() with realm meta and host cache data.
%% Should not halt on a corrupted, missing, malformed, etc. realm file but will log
%% any loading errors.

cx_populator(Managed) ->
    fun(Realm, {Records, Hosts}) ->
        case {lists:member(Realm, Managed), zx_lib:load_realm_conf(Realm)} of
            {true, {ok, Meta}} ->
                Record = cx_load_realm_meta(Meta),
                {[{Realm, Record#rmeta{assigned = managed}} | Records], Hosts};
            {false, {ok, Meta}} ->
                Record = #rmeta{prime = Prime} = cx_load_realm_meta(Meta),
                {[{Realm, Record} | Records], queue:in(Prime, Hosts)};
            {false, {error, Reason}} ->
                Message = "Loading realm ~160tp failed with: ~160tp. Skipping...",
                ok = log(warning, Message, [Realm, Reason]),
                {Records, Hosts}
        end
    end.


-spec cx_load_realm_meta(Meta) -> Result
    when Meta    :: [{Key :: atom(), Value :: term()}],
         Result  :: {zx:realm(), realm_meta()}.
%% @private
%% This function MUST adhere to the realmfile definition found at.

cx_load_realm_meta(Meta) ->
    Realm = maps:get(realm, Meta),
    Basic =
        #rmeta{prime = maps:get(prime, Meta),
               sysop = maps:get(sysop, Meta),
               key   = maps:get(key,   Meta)},
    cx_load_realm_cache(Realm, Basic).


-spec cx_load_realm_cache(Realm, Basic) -> Complete
    when Realm    :: zx:realm(),
         Basic    :: realm_meta(),
         Complete :: realm_meta().

cx_load_realm_cache(Realm, Basic) ->
    CacheFile = cx_realm_cache(Realm),
    case file:consult(CacheFile) of
        {ok, Cache} ->
            Serial = proplists:get_value(serial, Cache),
            Basic#rmeta{serial = Serial};
        {error, enoent} ->
            Basic
    end.


cx_load_hosts_cache() ->
    case file:consult(cx_hosts_cache()) of
        {ok, Hosts}     -> queue:from_list(Hosts);
        {error, enoent} -> queue:new()
    end.


-spec cx_store_cache(CX) -> Result
    when CX     :: conn_index(),
         Result :: ok
                 | {error, file:posix()}.

cx_store_cache(#cx{realms = Realms, hosts = Hosts}) ->
    ok = lists:foreach(fun cx_write_cache/1, maps:to_list(Realms)),
    zx_lib:write_terms(cx_hosts_cache(), queue:to_list(Hosts)).


-spec cx_write_cache({zx:realm(), realm_meta()}) -> ok.

cx_write_cache({Realm, #rmeta{serial = Serial}}) ->
    CacheFile = cx_realm_cache(Realm),
    CacheMeta = [{serial, Serial}],
    ok = filelib:ensure_dir(CacheFile),
    zx_lib:write_terms(CacheFile, CacheMeta).


-spec cx_realm_cache(zx:realm()) -> file:filename().

cx_realm_cache(Realm) ->
    filename:join(zx_lib:path(var, Realm), "realm.cache").


cx_hosts_cache() ->
    filename:join(zx_lib:path(var), "hosts.cache").


-spec cx_realms(conn_index()) -> [zx:realm()].

cx_realms(#cx{realms = Realms}) ->
    maps:keys(Realms);
cx_realms(offline) ->
    zx_lib:list_realms();
cx_realms(zomp) ->
    zx_lib:list_realms();
cx_realms(proxied) ->
    {ok, Realms} = zx_proxy:request(list),
    Realms.


-spec cx_mirrors(CX) -> Result
    when CX     :: conn_index(),
         Result :: {ok, [zx:host()]}
                 | {error, offline | zomp | proxied}.

cx_mirrors(#cx{mirrors = Mirrors}) ->
    {ok, queue:to_list(Mirrors)};
cx_mirrors(Status) ->
    {error, Status}.


-spec cx_check_service(Realms, CX) -> Result
    when Realms :: [zx:realm()],
         CX     :: conn_index(),
         Result :: {ok, NewCX}
                 | {connect, Host, NewCX},
         NewCX  :: conn_index(),
         Host   :: zx:host().

cx_check_service([], CX) ->
    {ok, CX};
cx_check_service([Realm | Rest], CX = #cx{realms = Realms}) ->
    case maps:get(Realm, Realms) of
        #rmeta{assigned = none, available = []} ->
            {Host, NewCX} = cx_next_host(CX),
            {connect, Host, NewCX};
        R = #rmeta{assigned = none, available = [Conn | Conns]} ->
            NewR = R#rmeta{assigned = Conn, available = Conns},
            NewRealms = maps:put(Realm, NewR, Realms),
            cx_check_service(Rest, CX#cx{realms = NewRealms});
        #rmeta{} ->
            cx_check_service(Rest, CX)
    end.


cx_next_host(CX = #cx{mirrors = Mirrors, hosts = Hosts}) ->
    case queue:is_empty(Hosts) of
        true ->
            {wait, CX#cx{hosts = Mirrors}};
        false ->
            {{value, Host}, NewHosts} = queue:out(Hosts),
            {Host, CX#cx{hosts = NewHosts}}
    end.


-spec cx_connected(Available, Pid, CX) -> Result
    when Available  :: [{zx:realm(), zx:serial()}],
         Pid        :: pid(),
         CX         :: conn_index(),
         Result     :: {Assignment, NewCX},
         Assignment :: assigned | unassigned,
         NewCX      :: conn_index().

cx_connected(Available, Pid, CX) ->
    Realms = [element(1, R) || R <- Available],
    Conn = #conn{pid = Pid, realms = Realms},
    cx_connected(unassigned, Available, Conn, CX).


-spec cx_connected(A, Available, Conn, CX) -> {NewA, NewCX}
    when A         :: unassigned | assigned,
         Available :: [{zx:realm(), zx:serial()}],
         Conn      :: connection(),
         CX        :: conn_index(),
         NewA      :: unassigned | assigned,
         NewCX     :: conn_index().

cx_connected(A,
             [{Realm, Serial} | Rest],
             Conn = #conn{pid = Pid},
             CX = #cx{realms = Realms}) ->
    case maps:find(Realm, Realms) of
        {ok, Meta = #rmeta{serial = S, available = Available}} when S =< Serial -> 
            NewMeta = Meta#rmeta{serial = Serial, available = [Pid | Available]},
            {NewA, NewCX} = cx_connected(A, Realm, Conn, NewMeta, CX),
            cx_connected(NewA, Rest, Conn, NewCX);
        {ok, #rmeta{serial = S}} when S  > Serial -> 
            cx_connected(A, Rest, Conn, CX);
        error ->
            cx_connected(A, Rest, Conn, CX)
    end;
cx_connected(A, [], Conn, CX = #cx{conns = Conns}) ->
    {A, CX#cx{conns = [Conn | Conns]}}.


-spec cx_connected(A, Realm, Conn, Meta, CX) -> {NewA, NewCX}
    when A     :: unassigned | assigned,
         Realm :: zx:host(),
         Conn  :: connection(),
         Meta  :: realm_meta(),
         CX    :: conn_index(),
         NewA  :: unassigned | assigned,
         NewCX :: conn_index().
%% @private
%% This function matches on two elements:
%%  - Whether or not the realm is already assigned (and if so, set `A' to `assigned'
%%  - Whether the host node is the prime node (and if not, ensure it is a member of
%%    of the mirror queue).

cx_connected(_,
             Realm,
             #conn{pid = Pid},
             Meta = #rmeta{assigned = none},
             CX = #cx{realms = Realms}) ->
    NewMeta = Meta#rmeta{assigned = Pid},
    NewRealms = maps:put(Realm, NewMeta, Realms),
    NewCX = CX#cx{realms = NewRealms},
    {assigned, NewCX};
cx_connected(A, _, _, _, CX) ->
    {A, CX}.


-spec cx_redirect(Targets, CX) -> NewCX
    when Targets :: [{zx:host(), [zx:realm()]}],
         CX      :: conn_index(),
         NewCX   :: conn_index().

cx_redirect([{Host, Provided} | Rest], CX = #cx{hosts = Hosts}) ->
    NewHosts = zx_lib:enqueue_unique(Host, Hosts),
    HostString = zx_net:host_string(Host),
    ok = log(info, "Host ~ts provides: ~tp", [HostString, Provided]),
    cx_redirect(Rest, CX#cx{hosts = NewHosts});
cx_redirect([], CX) ->
    CX.


-spec cx_wipe(CX) -> Pids
    when CX   :: conn_index(),
         Pids :: [pid()].

cx_wipe(#cx{conns = Conns}) ->
    Pids = [P || #conn{pid = P} <- Conns],
    ok = lists:foreach(fun zx_conn:retire/1, Pids),
    Pids.


-spec cx_disconnected(Conn, CX) -> {Requests, Subs, NewCX}
    when Conn     :: pid(),
         CX       :: conn_index(),
         Requests :: [id()],
         Subs     :: [zx:package()],
         NewCX    :: conn_index().

cx_disconnected(Pid, CX = #cx{realms = Realms, conns = Conns}) ->
    {value, Conn, NewConns} = lists:keytake(Pid, #conn.pid, Conns),
    #conn{requests = Requests, subs = Subs} = Conn,
    NewRealms = cx_scrub_assigned(Pid, Realms),
    NewCX = CX#cx{realms = NewRealms, conns = NewConns},
    {Requests, Subs, NewCX}.


-spec cx_scrub_assigned(Pid, Realms) -> NewRealms
    when Pid       :: pid(),
         Realms    :: [realm_meta()],
         NewRealms :: [realm_meta()].
%% @private
%% This could have been performed as a set of two list operations (a partition and a
%% map), but to make the procedure perfectly clear it is written out explicitly.

cx_scrub_assigned(Pid, Realms) ->
    Scrub =
        fun
            (_, V = #rmeta{available = A, assigned = C}) when C == Pid ->
                V#rmeta{available = lists:delete(Pid, A), assigned = none};
            (_, V = #rmeta{available = A}) ->
                V#rmeta{available = lists:delete(Pid, A)}
        end,
    maps:map(Scrub, Realms).


-spec cx_resolve(Realm, CX) -> Result
    when Realm  :: zx:realm(),
         CX     :: conn_index(),
         Result :: {ok, Conn :: pid()}
                 | unassigned
                 | unconfigured.
%% @private
%% Check the registry of assigned realms and return the pid of the appropriate
%% connection, or an `unassigned' indication if the realm is not yet connected.

cx_resolve(Realm, #cx{realms = Realms}) ->
    case maps:find(Realm, Realms) of
        {ok, #rmeta{assigned = none}}    -> unassigned;
        {ok, #rmeta{assigned = managed}} -> managed;
        {ok, #rmeta{assigned = Conn}}    -> {ok, Conn};
        error                            -> unconfigured
    end.


-spec cx_pre_send(Realm, ID, CX) -> Result
    when Realm  :: zx:realm(),
         ID     :: id(),
         CX     :: conn_index(),
         Result :: {ok, pid(), NewCX :: conn_index()}
                 | unassigned
                 | unconfigured.
%% @private
%% Prepare a request to be sent by queueing it in the connection active request
%% reference list and returning the Pid of the connection handling the required realm
%% if it is available, otherwise return an atom indicating the status of the realm..

cx_pre_send(Realm, ID, CX = #cx{conns = Conns}) ->
    case cx_resolve(Realm, CX) of
        {ok, Pid} ->
            {value, Conn, NextConns} = lists:keytake(Pid, #conn.pid, Conns),
            #conn{requests = Requests} = Conn,
            NewRequests = [ID | Requests],
            NewConn = Conn#conn{requests = NewRequests},
            NewCX = CX#cx{conns = [NewConn | NextConns]},
            {ok, Pid, NewCX};
        Other ->
            Other
    end.


-spec cx_add_sub(Subscriber, Channel, CX) -> Result
    when Subscriber :: pid(),
         Channel    :: tuple(),
         CX         :: conn_index(),
         Result     :: {need_sub, Conn, NewCX}
                     | {have_sub, NewCX}
                     | unassigned
                     | unconfigured,
         Conn       :: pid(),
         NewCX      :: conn_index().
%% @private
%% Adds a subscription to the current list of subs, and returns a value indicating
%% whether the connection needs to be told to subscribe or not based on whether it
%% is already subscribed to that particular channel.

cx_add_sub(Subscriber, Channel, CX = #cx{conns = Conns}) ->
    Realm = element(1, Channel),
    case cx_resolve(Realm, CX) of
        {ok, Pid} ->
            {value, Conn, NewConns} = lists:keytake(Pid, #conn.pid, Conns),
            cx_maybe_new_sub(Conn, {Subscriber, Channel}, CX#cx{conns = NewConns});
        Other ->
            Other
    end.


-spec cx_maybe_new_sub(Conn, Sub, CX) -> Result
    when Conn    :: connection(),
         Sub     :: {pid(), tuple()},
         CX      :: conn_index(),
         Result  :: {need_sub, ConnPid, NewCX}
                  | {have_sub, NewCX},
         ConnPid :: pid(),
         NewCX   :: conn_index().

cx_maybe_new_sub(Conn = #conn{pid = ConnPid, subs = Subs},
                 Sub  = {_, Channel},
                 CX   = #cx{conns = Conns}) ->
    NewSubs = [Sub | Subs],
    NewConn = Conn#conn{subs = NewSubs},
    NewConns = [NewConn | Conns],
    NewCX = CX#cx{conns = NewConns},
    case lists:keymember(Channel, 2, Subs) of
        false -> {need_sub, ConnPid, NewCX};
        true  -> {have_sub, NewCX}
    end.


-spec cx_del_sub(Subscriber, Channel, CX) -> Result
    when Subscriber :: pid(),
         Channel    :: tuple(),
         CX         :: conn_index(),
         Result     :: {drop_sub, NewCX}
                     | {keep_sub, NewCX}
                     | unassigned
                     | unconfigured,
         NewCX      :: conn_index().
%% @private
%% Remove a subscription from the list of subs, and return a value indicating whether
%% the connection needs to be told to unsubscribe entirely.

cx_del_sub(Subscriber, Channel, CX = #cx{conns = Conns}) ->
    Realm = element(1, Channel),
    case cx_resolve(Realm, CX) of
        {ok, Pid} ->
            {value, Conn, NewConns} = lists:keytake(Pid, #conn.pid, Conns),
            cx_maybe_last_sub(Conn, {Subscriber, Channel}, CX#cx{conns = NewConns});
        Other ->
            Other
    end.


-spec cx_maybe_last_sub(Conn, Sub, CX) -> {Verdict, NewCX}
    when Conn    :: connection(),
         Sub     :: {pid(), term()},
         CX      :: conn_index(),
         Verdict :: {drop_sub, Conn :: pid()} | keep_sub,
         NewCX   :: conn_index().
%% @private
%% Tells us whether a sub is still valid for any clients. If a sub is unsubbed by all
%% then it needs to be unsubscribed at the upstream node.

cx_maybe_last_sub(Conn = #conn{pid = ConnPid, subs = Subs},
                  Sub  = {_, Channel},
                  CX   = #cx{conns = Conns}) ->
    NewSubs = lists:delete(Sub, Subs),
    NewConn = Conn#conn{subs = NewSubs},
    NewConns = [NewConn | Conns],
    NewCX = CX#cx{conns = NewConns},
    Verdict =
        case lists:keymember(Channel, 2, NewSubs) of
            false -> {drop_sub, ConnPid};
            true  -> keep_sub
        end,
    {Verdict, NewCX}.


-spec cx_get_subscribers(Conn, Channel, CX) -> Subscribers
    when Conn        :: pid(),
         Channel     :: term(),
         CX          :: conn_index(),
         Subscribers :: [pid()].

cx_get_subscribers(Conn, Channel, #cx{conns = Conns}) ->
    #conn{subs = Subs} = lists:keyfind(Conn, #conn.pid, Conns),
    lists:fold(registered_to(Channel), [], Subs).


-spec registered_to(Channel) -> fun(({P, C}, A) -> NewA)
    when Channel :: term(),
         P       :: pid(),
         C       :: term(),
         A       :: [pid()],
         NewA    :: [pid()].
%% @private
%% Matching function that closes over a given channel in a subscriber list.
%% This function exists mostly to make its parent function read nicely.

registered_to(Channel) ->
    fun({P, C}, A) ->
        case C == Channel of
            true  -> [P | A];
            false -> A
        end
    end.


-spec cx_clear_client(Pid, DeadReqs, DeadSubs, CX) -> NewCX
    when Pid      :: pid(),
         DeadReqs :: [id()],
         DeadSubs :: [term()],
         CX       :: conn_index(),
         NewCX    :: conn_index().

cx_clear_client(Pid, DeadReqs, DeadSubs, CX = #cx{conns = Conns}) ->
    DropSubs = [{Pid, Sub} || Sub <- DeadSubs],
    Clear =
        fun(C = #conn{requests = Requests, subs = Subs}) ->
            NewSubs = lists:subtract(Subs, DropSubs),
            NewRequests = lists:subtract(Requests, DeadReqs),
            C#conn{requests = NewRequests, subs = NewSubs}
        end,
    NewConns = lists:map(Clear, Conns),
    CX#cx{conns = NewConns};
cx_clear_client(_, _, _, Status) ->
    Status.
