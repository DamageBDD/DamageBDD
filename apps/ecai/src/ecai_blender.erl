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
    render_script/4
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

-define(DEFAULT_BLENDER_CMD, "blender").

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
    Cmd = State#state.blender_cmd,
    Result = run_script_render(Cmd, OutputPath, PyBody, Opts),
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

%% Build Python script:
%%
%% - Reads clean startup file
%% - Runs user PyBody
%% - Applies render settings from Opts
%% - Uses sys.argv[-1] as output_path
%% - Renders a still frame
build_render_script(PyBody, Opts) ->
    Format = to_string(maps:get(format, Opts, <<"PNG">>)),
    ResX = maps:get(res_x, Opts, 1024),
    ResY = maps:get(res_y, Opts, 1024),
    Frame = maps:get(frame, Opts, 1),

    [
        "import bpy\n",
        "import sys\n\n",
        "output_path = sys.argv[-1]\n\n",
        "# Reset to empty scene\n",
        "bpy.ops.wm.read_homefile(use_empty=True)\n\n",
        "# --- User scene body start ---\n",
        PyBody,
        "\n",
        "# --- User scene body end ---\n\n",
        "scene = bpy.context.scene\n",
        "scene.frame_set(",
        integer_to_list(Frame),
        ")\n",
        "scene.render.image_settings.file_format = '",
        Format,
        "'\n",
        "scene.render.filepath = output_path\n",
        "scene.render.resolution_x = ",
        integer_to_list(ResX),
        "\n",
        "scene.render.resolution_y = ",
        integer_to_list(ResY),
        "\n",
        "scene.render.resolution_percentage = 100\n\n",
        "bpy.ops.render.render(write_still=True)\n"
    ].

temp_script_path() ->
    TmpDir =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Dir -> Dir
        end,
    Name = "ecai_blender_" ++ integer_to_list(erlang:unique_integer()) ++ ".py",
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
    end.
