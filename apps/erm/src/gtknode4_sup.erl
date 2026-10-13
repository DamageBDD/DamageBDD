%%%-------------------------------------------------------------------
%%% @doc Root supervisor for the GTK4 C-node stack.
%%%
%%% The owned local/fake stack uses one_for_all because the controller,
%%% native process and logical registry are one UI session. If any member
%%% fails, retaining the others would leave pending calls, orphaned widgets or
%%% reusable native IDs. external_cnode mode uses rest_for_one because the
%%% external native process is deliberately outside this supervisor.
%%%-------------------------------------------------------------------
-module(gtknode4_sup).
-behaviour(supervisor).

-export([start_link/0, start_link/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    Config0 = application:get_env(erm, gtknode4, #{}),
    Config = maps:remove(enabled, options_map(Config0)),
    start_link(Config).

-spec start_link(map() | list()) -> supervisor:startlink_ret().
start_link(Opts0) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, options_map(Opts0)).

init(Opts) ->
    Mode = maps:get(mode, Opts, local_cnode),
    {ControllerOpts, PortChild} = transport_children(Mode, Opts),
    GsOpts0 = options_map(maps:get(gs, Opts, #{})),
    GsOpts =
        case Mode of
            fake -> maps:merge(#{test_mode => true}, GsOpts0);
            _ -> GsOpts0
        end,

    Controller = #{
        id => gtknode4,
        start => {gtknode4, start_link, [ControllerOpts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [gtknode4]
    },
    Gs = #{
        id => gtkgs,
        start => {gtkgs, start_link, [GsOpts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [gtkgs]
    },
    Children = [Controller] ++ PortChild ++ [Gs],
    SupFlags = #{
        strategy => supervisor_strategy(Mode),
        intensity => maps:get(restart_intensity, Opts, 5),
        period => maps:get(restart_period, Opts, 10)
    },
    {ok, {SupFlags, Children}}.

transport_children(fake, Opts) ->
    Backend = maps:get(backend, Opts, gtknode4_fake),
    BackendOpts0 = options_map(maps:get(backend_opts, Opts, #{})),
    GsOpts = options_map(maps:get(gs, Opts, #{})),
    BackendOpts = BackendOpts0#{test_mode => maps:get(test_mode, GsOpts, true)},
    {#{backend => Backend, backend_opts => BackendOpts}, []};
transport_children(external_cnode, Opts) ->
    ControllerOpts = options_map(maps:get(controller, Opts, #{})),
    {ControllerOpts, []};
transport_children(local_cnode, Opts) ->
    PortOpts0 = options_map(maps:get(port, Opts, #{})),
    CNode = configured_cnode_node(PortOpts0),
    CRegName = configured_atom(cnode_regname, PortOpts0, gtknode4),
    GsOpts = options_map(maps:get(gs, Opts, #{})),
    TestMode = maps:get(test_mode, PortOpts0, maps:get(test_mode, GsOpts, false)),
    PortOpts = PortOpts0#{
        cnode_node => CNode,
        cnode_regname => CRegName,
        test_mode => TestMode
    },
    ControllerOpts0 = options_map(maps:get(controller, Opts, #{})),
    ControllerOpts = ControllerOpts0#{
        endpoint => {CRegName, CNode},
        monitor_endpoint_on_start => false
    },
    Port = #{
        id => gtknode4_port,
        start => {gtknode4_port, start_link, [PortOpts]},
        restart => permanent,
        shutdown => maps:get(port_shutdown, Opts, 5000),
        type => worker,
        modules => [gtknode4_port]
    },
    {ControllerOpts, [Port]};
transport_children(Other, _Opts) ->
    error({unsupported_gtknode4_mode, Other}).

supervisor_strategy(external_cnode) -> rest_for_one;
supervisor_strategy(local_cnode) -> one_for_all;
supervisor_strategy(fake) -> one_for_all.

configured_cnode_node(PortOpts) ->
    case maps:get(cnode_node, PortOpts, undefined) of
        undefined ->
            Host = node_host(node()),
            list_to_atom("gtknode4@" ++ Host);
        Value when is_atom(Value) -> Value;
        Value when is_binary(Value) -> binary_to_atom(Value, utf8);
        Value when is_list(Value) -> list_to_atom(Value)
    end.

configured_atom(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Value when is_atom(Value) -> Value;
        Value when is_binary(Value) -> binary_to_atom(Value, utf8);
        Value when is_list(Value) -> list_to_atom(Value)
    end.

node_host(nonode@nohost) ->
    error({erlang_distribution_not_started, "start the VM with -sname or -name"});
node_host(Node) ->
    case string:split(atom_to_list(Node), "@", all) of
        [_Alive, Host] -> Host;
        _ -> error({bad_node_name, Node})
    end.

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List).
