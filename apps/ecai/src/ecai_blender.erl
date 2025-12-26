%%%-------------------------------------------------------------------
%%% ecai_blender: Erlang <-> Blender CLI + script-based renderer
%%%
%%% Features:
%%%   1. render/3,4     : render from existing .blend file
%%%   2. render_script/2,3,4 : generate Python script and render directly
%%%
%%% Example 1: render from .blend
%%%   {ok, _Pid} = ecai_blender:start_link(#{
%%%       blender_cmd => "/usr/bin/blender"
%%%   }).
%%%
%%%   ecai_blender:render("/path/scene.blend",
%%%                       "/tmp/output_####",
%%%                       #{}).
%%%
%%% Example 2: script-based render
%%%   PyBody = "
%%% import math
%%% # Add a monkey
%%% bpy.ops.mesh.primitive_monkey_add(location=(0,0,0))
%%% bpy.context.object.rotation_euler[2] = math.radians(45)
%%% ";
%%%
%%%   ecai_blender:render_script("/tmp/monkey.png", PyBody, #{
%%%       format => <<"PNG">>,
%%%       res_x  => 1024,
%%%       res_y  => 1024
%%%   }).
%%%
%%%-------------------------------------------------------------------
-module(ecai_blender).
-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

%% Public API
-export([
    start_link/0,
    start_link/1,

    %% existing .blend based
    render/3,
    render/4,

    %% script-based render
    render_script/2,
    render_script/3,
    render_script/4,
    %% high-level isogeny renders
    render_isogeny/3,
    render_isogeny/4,
    runway_walk/0,
    render_christmas_tree/2,
    render_christmas_tree/3,
    render_christmas_tree/4
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_BLENDER_CMD, "/usr/sbin/blender").
-define(BLENDER_SCRIPT_TEMPLATE, "blender_render_script.py.mustache").
-define(SPHERICAL_ISOGENY_TEMPLATE, "isogeny_spherical.py.mustache").
-define(RUNWAY_WALK_TEMPLATE, "runway_walk.py.mustache").
-define(CHRISTMAS_TREE_TEMPLATE, "christmas_tree.py.mustache").

-record(state, {
    blender_cmd = ?DEFAULT_BLENDER_CMD :: file:filename_all()
}).
%% Public test function
-export([test/0]).

%%%===================================================================
%%% Public API
%%%===================================================================

start_link() ->
    start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%%--------------------------------------------------------------------
%% Render from existing .blend (registered server)
%%--------------------------------------------------------------------
render(BlendFile, OutputPattern, Opts) ->
    gen_server:call(?MODULE, {render_blend, BlendFile, OutputPattern, Opts}, infinity).

%% Render from existing .blend (explicit Pid)
render(Pid, BlendFile, OutputPattern, Opts) ->
    gen_server:call(Pid, {render_blend, BlendFile, OutputPattern, Opts}, infinity).

%%--------------------------------------------------------------------
%% Script-based render: registered server, minimal options
%%   OutputPath : full path to output image (e.g. "/tmp/out.png")
%%   PyBody     : iolist()/string with Python body that builds scene
%%--------------------------------------------------------------------
render_script(OutputPath, PyBody) ->
    render_script(OutputPath, PyBody, #{}).

%% Script-based render with Opts
render_script(OutputPath, PyBody, Opts) ->
    gen_server:call(?MODULE, {render_script, OutputPath, PyBody, Opts}, infinity).

%% Script-based render using explicit Pid
render_script(Pid, OutputPath, PyBody, Opts) ->
    gen_server:call(Pid, {render_script, OutputPath, PyBody, Opts}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    BlenderCmd0 = maps:get(blender_cmd, Opts, ?DEFAULT_BLENDER_CMD),
    %% If you want to be stricter, you can do os:find_executable/1 here.
    {ok, #state{blender_cmd = BlenderCmd0}}.

handle_call({render_blend, BlendFile, OutputPattern, Opts}, _From, State) ->
    Cmd = State#state.blender_cmd,
    Args = build_blend_args(BlendFile, OutputPattern, Opts),
    Result = run_blender(Cmd, Args),
    {reply, Result, State};
handle_call({render_script, OutputPath, PyBody, Opts}, _From, State) ->
    %Cmd = State#state.blender_cmd,
    Result = run_script_render(?DEFAULT_BLENDER_CMD, OutputPath, PyBody, Opts),
    {reply, Result, State};
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal: existing .blend based rendering
%%%===================================================================

%% Build args: headless render from .blend
%%
%% Opts:
%%   - frame  :: integer() (default: 1)
%%   - format :: binary() | string() (default: "PNG")
%%   - extras :: [string()] extra Blender args
build_blend_args(BlendFile, OutputPattern, Opts) ->
    Frame = maps:get(frame, Opts, 1),
    Format0 = maps:get(format, Opts, <<"PNG">>),
    Extras = maps:get(extras, Opts, []),

    Format = to_string(Format0),

    [
        "-b",
        BlendFile,
        "-o",
        OutputPattern,
        "-F",
        Format,
        "-f",
        integer_to_list(Frame)
    ] ++ Extras.

%%%===================================================================
%%% Internal: script-based rendering
%%%===================================================================

%% High-level: write Python script to tmp, run Blender, collect output.
run_script_render(Cmd, OutputPath, PyBody, Opts) ->
    Script = build_render_script(PyBody, Opts),
    ScriptPath = temp_script_path(),
    ?LOG_DEBUG("run_script_render ~p ", [ScriptPath]),
    case file:write_file(ScriptPath, Script) of
        ok ->
            Args = [
                "-b",
                "-P",
                ScriptPath,
                "--",
                OutputPath
            ],
            run_blender(Cmd, Args);
        {error, Reason} ->
            {error, {write_script_failed, Reason}}
    end.

%% Build Python script from Mustache template via damage_utils.
%%
%% Template: ?BLENDER_SCRIPT_TEMPLATE
%% Context keys:
%%   - py_body : the user scene body (string/binary)
%%   - format  : file format string, e.g. "PNG"
%%   - res_x   : integer resolution X
%%   - res_y   : integer resolution Y
%%   - frame   : integer frame index
build_render_script(PyBody, Opts) ->
    Format0 = maps:get(format, Opts, <<"PNG">>),
    ResX = maps:get(res_x, Opts, 1024),
    ResY = maps:get(res_y, Opts, 1024),
    Frame = maps:get(frame, Opts, 1),
    AudioPath = maps:get(audio_path, Opts, <<"">>),

    Format = to_string(Format0),
    %% or <<"ecai_navy">>, <<"ecai_teal">>, etc.
    Theme = <<"bitcoin_war">>,
    %Theme = <<"ecai_teal">>,

    Context = #{
        py_body => damage_utils:to_bin(PyBody),
        format => Format,
        res_x => ResX,
        res_y => ResY,
        frame => Frame,
        theme => binary_to_list(Theme),
        audio_path => AudioPath
    },
    ?LOG_INFO("Render Blender ~p", [Context]),

    %% Assumes templates live under ecai:priv/templates/
    damage_utils:load_template(ecai, ?BLENDER_SCRIPT_TEMPLATE, Context).

temp_script_path() ->
    TmpDir =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Dir -> Dir
        end,
    Name = "ecai_blender_" ++ integer_to_list(abs(erlang:unique_integer())) ++ ".py",
    filename:join(TmpDir, Name).

%%%===================================================================
%%% Internal: process runner + output collection
%%%===================================================================

run_blender(Cmd, Args) ->
    Port = open_port(
        {spawn_executable, Cmd},
        [
            exit_status,
            use_stdio,
            stderr_to_stdout,
            hide,
            {args, Args}
        ]
    ),
    collect_output(Port, []).

collect_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, [Acc, Data]);
        {Port, {exit_status, Status}} ->
            {ok, Status, iolist_to_binary(Acc)}
    after 600000 ->
        port_close(Port),
        {error, timeout}
    end.

to_string(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
to_string(List) when is_list(List) ->
    List.

%%--------------------------------------------------------------------
%% High-level: render_isogeny/3,4
%%
%% Renders an "isogeny scene" (currently: spherical isogeny – sphere +
%% wobbling hoops + kernel collapse + title text) directly via a
%% generated Blender Python body.
%%
%%   Kind:
%%      - spherical  (default canonical spherical isogeny)
%%      - You can add more patterns later (e.g. 'spherical_basic',
%%        'kernel_only', etc.) inside build_isogeny_pybody/2.
%%
%%   OutputPath: "/tmp/spherical_isogeny.png"
%%   Opts: same shape as render_script/3 Opts (format, res_x, res_y, frame)
%%--------------------------------------------------------------------
-spec render_isogeny(
    OutputPath :: file:filename_all(),
    Kind :: atom(),
    Opts :: map()
) ->
    {ok, non_neg_integer(), binary()} | {error, term()}.

render_isogeny(OutputPath, Kind, Opts) ->
    PyBody = build_isogeny_pybody(Kind, Opts),
    render_script(OutputPath, PyBody, Opts).

-spec render_isogeny(
    Pid :: pid(),
    OutputPath :: file:filename_all(),
    Kind :: atom(),
    Opts :: map()
) ->
    {ok, non_neg_integer(), binary()} | {error, term()}.

render_isogeny(Pid, OutputPath, Kind, Opts) ->
    PyBody = build_isogeny_pybody(Kind, Opts),

    render_script(Pid, OutputPath, PyBody, Opts).
%%%===================================================================
%%% Internal: isogeny scene builders
%%%===================================================================

%% build_isogeny_pybody(Kind, Opts) -> Python source as iolist()
%%
%% Kind atoms are for future variants; currently we only implement
%% 'spherical', and any unknown Kind falls back to that.
build_isogeny_pybody(_Kind, _Opts) ->
    spherical_isogeny_pybody().

spherical_isogeny_pybody() ->
    %% Template is pure scene-body Python (no read_homefile(), no render settings).
    damage_utils:load_template(ecai, ?SPHERICAL_ISOGENY_TEMPLATE, #{}).
runway_walk() ->
    PrivDir =
        case code:priv_dir(ecai) of
            {error, enoent} ->
                %% Fallback: Locate priv relative to this module's .beam file
                EbinDir = filename:dirname(code:which(?MODULE)),
                filename:join(filename:dirname(EbinDir), "priv");
            Path ->
                Path
        end,
    ArmaturePath = list_to_binary(
        filename:join([PrivDir, "blendomatic", "canonical_rigify_human_v1.blend"])
    ),
    ParamsJson = jsx:encode(#{
        armature_filepath => ArmaturePath,
        armature_object_name => <<"rig">>,
        fps => 24,
        frame_start => 1,
        frame_end => 25,
        hip_sway_deg => 3.2,
        arm_swing_deg => 10.0,
        stride_m => 1.15
    }),
    PyBody0 = damage_utils:load_template(ecai, ?RUNWAY_WALK_TEMPLATE, #{}),
    PyBody = binary:replace(PyBody0, <<"__ECAI_PARAMS_JSON__">>, ParamsJson, [global]),
    ecai_blender:render_script("/tmp/runway.mp4", PyBody, #{res_x => 1080, res_y => 1920}).
%% Renders a procedural Christmas tree (lights + ornaments + star).
%% OutputPath can be .png or .mp4 (if you pass audio_path like your template expects).
render_christmas_tree(OutputPath, Opts) ->
    render_christmas_tree(OutputPath, christmas, Opts).

render_christmas_tree(OutputPath, _Kind, Opts) when is_map(Opts) ->
    PyBody = christmas_tree_pybody(Opts),
    render_script(OutputPath, PyBody, Opts).

render_christmas_tree(Pid, OutputPath, _Kind, Opts) when is_pid(Pid), is_map(Opts) ->
    PyBody = christmas_tree_pybody(Opts),
    render_script(Pid, OutputPath, PyBody, Opts).

christmas_tree_pybody(Opts) ->
    %% Tuneables (all optional)
    TreeH = maps:get(tree_h, Opts, 2.6),
    TreeR = maps:get(tree_r, Opts, 1.15),
    Seed = maps:get(seed, Opts, 42),
    Bloom = maps:get(bloom, Opts, true),

    damage_utils:load_template(
        ecai,
        ?CHRISTMAS_TREE_TEMPLATE,
        #{
            seed => Seed,
            bloom => Bloom,
            tree_h => TreeH,
            tree_r => TreeR
        }
    ).

%%%===================================================================
%%% Public Test
%%%===================================================================

%% Simple end-to-end render test
%% Creates: /tmp/ecai_test.png
test() ->
    Output = "/tmp/ecai_test.png",

    PyBody =
        "\n"
        "import math\n"
        "\n"
        "# Camera\n"
        "bpy.ops.object.camera_add(location=(0, -6, 2))\n"
        "cam = bpy.context.object\n"
        "cam.data.lens = 35\n"
        "cam.rotation_euler = (math.radians(75), 0, 0)\n"
        "\n"
        "# Light\n"
        "bpy.ops.object.light_add(type='AREA', location=(4, -4, 6))\n"
        "light = bpy.context.object\n"
        "light.data.energy = 1200\n"
        "\n"
        "# Suzanne monkey\n"
        "bpy.ops.mesh.primitive_monkey_add(location=(0,0,0))\n"
        "obj = bpy.context.object\n"
        "obj.rotation_euler[2] = math.radians(35)\n"
        "obj.scale = (1.2, 1.2, 1.2)\n"
        "\n"
        "# Material\n"
        "mat = bpy.data.materials.new(name='MonkeyMat')\n"
        "mat.use_nodes = True\n"
        "bsdf = mat.node_tree.nodes['Principled BSDF']\n"
        "bsdf.inputs['Base Color'].default_value = (0.2, 0.5, 1.0, 1.0)\n"
        "obj.data.materials.append(mat)\n"
        "\n"
        "bpy.context.scene.camera = cam\n",

    Opts = #{
        format => <<"PNG">>,
        res_x => 800,
        res_y => 800,
        frame => 1
    },

    _Res =
        case render_script(Output, PyBody, Opts) of
            {ok, 0, _BlenderOutput} ->
                io:format("Render complete: ~s~n", [Output]),
                {ok, Output};
            {ok, Status, Log} ->
                io:format("Blender exit status ~p~nLog: ~s~n", [Status, Log]),
                {error, {blender_exit_status, Status}};
            Error ->
                io:format("Render error: ~p~n", [Error]),
                Error
        end,
    %% Start
    %{ok, _Pid} = ecai_blender:start_link(#{blender_cmd => "/usr/bin/blender"}).

    %% Render one spherical isogeny frame
    Output0 = "/tmp/spherical_isogeny.png",
    Opts0 = #{
        format => <<"PNG">>,
        res_x => 1080,
        res_y => 1080,
        %% pick a nice mid-collapse frame
        frame => 180
    },

    case ecai_blender:render_isogeny(Output0, spherical, Opts0) of
        {ok, 0, BlenderOutput0} ->
            io:format("Render complete: ~s ~p~n", [Output0, BlenderOutput0]);
        {ok, Status0, Log0} ->
            io:format("Blender exit status ~p~nLog: ~s~n", [Status0, Log0]);
        Error0 ->
            io:format("Render error: ~p~n", [Error0]),
            Error0
    end,

    Output1 = "/tmp/spherical_isogeny.mp4",
    Opts1 = #{
        format => <<"PNG">>,
        res_x => 800,
        res_y => 800,
        audio_path => <<"/tmp/ecai_bitcoiner_iconic.wav">>,
        %% pick a nice mid-collapse frame
        frame => 1
    },

    case ecai_blender:render_isogeny(Output1, spherical, Opts1) of
        {ok, 0, BlenderOutput1} ->
            io:format("Render complete: ~s ~p~n", [Output1, BlenderOutput1]),
            {ok, Output1};
        {ok, Status1, Log1} ->
            io:format("Blender exit status ~p~nLog: ~s~n", [Status1, Log1]),
            {error, {blender_exit_status, Status1}};
        Error1 ->
            io:format("Render error: ~p~n", [Error1]),
            Error1
    end.
