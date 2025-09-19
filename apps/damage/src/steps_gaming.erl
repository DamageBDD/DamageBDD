-module(steps_gaming).

-include_lib("kernel/include/logger.hrl").

-export([step/6]).

%% ------------------------------------------------------------------
%% Custom BDD steps (no bash heredocs) to optimize a Ryzen 7 5800X3D +
%% NVIDIA RTX 3090 setup on Arch Linux for peak gaming. Designed to be
%% used alongside steps_cmd.erl style of step matching.
%% ------------------------------------------------------------------

-define(DEFAULT_CWD, "/tmp").

%% Helpers ------------------------------------------------------------

-spec cwd(map()) -> file:filename_all().
cwd(Context) -> filename:absname(maps:get(cmd_cwd, Context, ?DEFAULT_CWD)).

-spec run(map(), iodata()) -> {ok, term()} | {error, term()}.
run(Context, Cmd) ->
    exec:run(Cmd, [sync, stderr, stdout, {cd, cwd(Context)}]).

-spec ok_or_fail(map(), {ok, term()} | {error, term()}, iodata()) -> map().
ok_or_fail(Context, {ok, _} = _Res, _Msg) -> Context;
ok_or_fail(Context, {error, Reason}, Msg) ->
    ?LOG_WARNING("~s failed: ~p", [Msg, Reason]),
    maps:put(fail, io_lib:format("~s failed: ~p", [Msg, Reason]), Context).

-spec write_file(map(), file:filename_all(), iodata()) -> map().
write_file(Context, Path, Data) ->
    ok = filelib:ensure_dir(Path),
    case file:write_file(Path, Data) of
        ok -> Context;
        {error, Reason} -> maps:put(fail, io_lib:format("write ~s: ~p", [Path, Reason]), Context)
    end.

%% ------------------------------------------------------------------
%% Step definitions
%% ------------------------------------------------------------------

%% Given I change directory to /path (delegated to steps_cmd normally)
%% We still support it here if needed.
step(_Cfg, Context, <<"Given">>, _N, ["I change directory to", Path], _Meta) ->
    maps:put(cmd_cwd, Path, Context);

%% Packages -----------------------------------------------------------
%% When I install core gaming packages
step(_Cfg, Context0, <<"When">>, _N, ["I install core gaming packages"], _Meta) ->
    Context1 = ok_or_fail(Context0, run(Context0, "sudo pacman -Syu --noconfirm"), "system update"),
    case maps:is_key(fail, Context1) of true -> Context1; false ->
        Context2 = ok_or_fail(Context1, run(Context1,
            "sudo pacman -S --needed --noconfirm nvidia nvidia-utils nvidia-settings lib32-nvidia-utils"),
            "install nvidia stack"),
        case maps:is_key(fail, Context2) of true -> Context2; false ->
            ok_or_fail(Context2, run(Context2,
                "sudo pacman -S --needed --noconfirm gamemode lib32-gamemode mangohud lib32-mangohud goverlay cpupower"),
                "install tools")
        end
    end;

%% Services -----------------------------------------------------------
%% When I enable gaming services
step(_Cfg, Context0, <<"When">>, _N, ["I enable gaming services"], _Meta) ->
    Context1 = ok_or_fail(Context0, run(Context0, "sudo systemctl enable --now gamemoded.service"), "enable gamemoded"),
    case maps:is_key(fail, Context1) of true -> Context1; false ->
        ok_or_fail(Context1, run(Context1, "sudo systemctl enable --now nvidia-persistenced.service"), "enable nvidia-persistenced")
    end;

%% CPU governor -------------------------------------------------------
%% When I set CPU governor to performance
step(_Cfg, Context0, <<"When">>, _N, ["I set CPU governor to", "performance"], _Meta) ->
    Context1 = ok_or_fail(Context0, run(Context0, "sudo systemctl enable --now cpupower.service"), "enable cpupower"),
    case maps:is_key(fail, Context1) of true -> Context1; false ->
        ok_or_fail(Context1, run(Context1, "sudo cpupower frequency-set -g performance"), "set governor")
    end;

%% NVIDIA power & clocks ---------------------------------------------
%% When I set NVIDIA persistence mode on
step(_Cfg, Context, <<"When">>, _N, ["I set NVIDIA persistence mode on"], _Meta) ->
    ok_or_fail(Context, run(Context, "sudo nvidia-smi -pm 1"), "nvidia persistence");

%% When I prefer maximum performance on the GPU
step(_Cfg, Context, <<"When">>, _N, ["I prefer maximum performance on the GPU"], _Meta) ->
    %% PowerMizerMode=1 => Prefer Maximum Performance
    ok_or_fail(Context, run(Context, "nvidia-settings -a [gpu:0]/GPUPowerMizerMode=1"), "nvidia powermizer");

%% Verify PowerMizer mode
%% Then the NVIDIA PowerMizer mode should be 1
step(_Cfg, Context0, <<"Then">>, _N, ["the NVIDIA PowerMizer mode should be", WantStr], _Meta) ->
    case run(Context0, "nvidia-settings -q [gpu:0]/GPUPowerMizerMode -t") of
        {ok, #{stdout := Out}} ->
            Want = list_to_integer(WantStr),
            case string:trim(Out) of
                OutTrim when OutTrim =:= integer_to_list(Want) -> Context0;
                Other -> maps:put(fail, io_lib:format("PowerMizer mismatch: want ~p got ~s", [Want, Other]), Context0)
            end;
        Err -> ok_or_fail(Context0, Err, "query powermizer")
    end;

%% GameMode -----------------------------------------------------------
%% When I configure GameMode defaults
step(_Cfg, Context0, <<"When">>, _N, ["I configure GameMode defaults"], _Meta) ->
    Home = os:getenv("HOME", "/root"),
    IniPath = filename:join([Home, ".config", "gamemode.ini"]),
    Data =
        "[general]\n"
        "softrealtime=true\n"
        "desiredgov=performance\n"
        "iomem=auto\n"
        "[custom]\n"
        "start=renice -n -10 -p $$ || true\n"
        "end=renice -n 0 -p $$ || true\n",
    write_file(Context0, IniPath, Data);

%% MangoHUD -----------------------------------------------------------
%% When I configure MangoHUD frametime view
step(_Cfg, Context0, <<"When">>, _N, ["I configure MangoHUD frametime view"], _Meta) ->
    Home = os:getenv("HOME", "/root"),
    Dir = filename:join([Home, ".config", "MangoHud"]),
    Cfg = filename:join(Dir, "MangoHud.conf"),
    Data =
        "fps_limit=0\n"
        "present_latency=1\n"
        "gpu_stats=1\n"
        "cpu_stats=1\n"
        "vram=1\n"
        "ram=1\n"
        "frame_timing=1\n"
        "frametime=1\n"
        "gpu_temp=1\n"
        "cpu_temp=1\n"
        "io_read=1\n"
        "io_write=1\n"
        "output_folder=~/MangoHUD\n"
        "output=1\n",
    write_file(Context0, Cfg, Data);

%% KDE compositor toggle ---------------------------------------------
%% When I disable the compositor while gaming (KDE)
step(_Cfg, Context0, <<"When">>, _N, ["I disable the compositor while gaming (KDE)"], _Meta) ->
    Context1 = ok_or_fail(Context0,
        run(Context0, 'kwriteconfig5 --file kwinrc --group Compositing --key WindowsBlockCompositing true'),
        "kwinrc toggle"),
    case maps:is_key(fail, Context1) of true -> Context1; false ->
        ok_or_fail(Context1, run(Context1, "qdbus org.kde.KWin /KWin reconfigure"), "kwin reload")
    end;

%% User limits bump ---------------------------------------------------
%% When I raise user limits for gaming tools
step(_Cfg, Context0, <<"When">>, _N, ["I raise user limits for gaming tools"], _Meta) ->
    Home = os:getenv("HOME", "/root"),
    UserConf = filename:join([Home, ".config", "systemd", "user.conf"]),
    Data = "[Manager]\nDefaultLimitNOFILE=1048576\nDefaultLimitNPROC=131072\n",
    write_file(Context0, UserConf, Data);

%% Launch game --------------------------------------------------------
%% When I launch Insurgency Sandstorm with overlays
step(_Cfg, Context, <<"When">>, _N, ["I launch Insurgency Sandstorm with overlays"], _Meta) ->
    %% Steam appid 581320; Steam client will handle it if running.
    ok_or_fail(Context, run(Context, "gamemoderun mangohud steam -applaunch 581320"), "launch sandstorm");

%% Generic Then for service status checks -----------------------------
%% Then service gamemoded.service should be active
step(_Cfg, Context0, <<"Then">>, _N, ["service", Service, "should be", "active"], _Meta) ->
    case run(Context0, io_lib:format("systemctl is-active ~s", [Service])) of
        {ok, #{stdout := Out}} ->
            case string:trim(Out) of
                "active" -> Context0;
                Other -> maps:put(fail, io_lib:format("service ~s not active (~s)", [Service, Other]), Context0)
            end;
        Err -> ok_or_fail(Context0, Err, "systemctl is-active")
    end.
