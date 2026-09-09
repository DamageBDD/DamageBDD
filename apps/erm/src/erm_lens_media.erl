%%% Bounded decoder jobs; only validated normalized local PNG paths reach GTK.
-module(erm_lens_media).

-ifdef(TEST).
-export([decoder_reply/2, validate_result/3, read_port/3]).
-endif.
-behaviour(gen_server).
-include_lib("kernel/include/file.hrl").
-export([start_link/1, request/3, cancel_before/2, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(C) -> gen_server:start_link({local, ?MODULE}, ?MODULE, C, []).
request(Key, Image, ReplyTo) -> gen_server:cast(?MODULE, {request, Key, Image, ReplyTo}).
cancel_before(ReplyTo, Generation) -> gen_server:cast(?MODULE, {cancel_before, ReplyTo, Generation}).
status() -> gen_server:call(?MODULE, status, 3000).

init(C) ->
    process_flag(trap_exit, true),
    {ok, #{config => C, active => #{}, queue => queue:new()}}.
handle_call(status, _, S) ->
    {reply, #{active => map_size(maps:get(active, S)), queued => queue:len(maps:get(queue, S))}, S};
handle_call(_, _, S) -> {reply, {error, unsupported_call}, S}.

handle_cast({request, Key, Image, To}, S) when is_pid(To), node(To) =:= node() ->
    Q = maps:get(queue, S),
    case valid_image(Image) of
        false -> To ! {lens_media, Key, {error, invalid_image_request}}, {noreply, S};
        true ->
            case {duplicate(Key, To, S), queue:len(Q) >= 48} of
                {true, _} -> {noreply, S};
                {false, true} -> To ! {lens_media, Key, {error, media_queue_full}}, {noreply, S};
                {false, false} ->
                    Item = {Key, maps:with([url, sha256], Image), To},
                    {noreply, pump(S#{queue := queue:in(Item, Q)})}
            end
    end;
handle_cast({cancel_before, To, Gen}, S) when is_pid(To), is_integer(Gen) ->
    %% Drop obsolete queued pages, not active subprocesses. Killing a port owner
    %% is not a portable guarantee that the OS decoder has exited immediately.
    Keep = [Item || Item = {Key, _, Owner} <- queue:to_list(maps:get(queue, S)),
                   not (Owner =:= To andalso older(Key, Gen))],
    {noreply, S#{queue := queue:from_list(Keep)}};
handle_cast(_, S) -> {noreply, S}.

handle_info({media_result, Pid, Result}, S) ->
    complete(Pid, Result, S);
handle_info({media_timeout, Pid}, S) ->
    case maps:is_key(Pid, maps:get(active, S)) of
        true -> exit(Pid, kill), complete(Pid, {error, decoder_timeout}, S);
        false -> {noreply, S}
    end;
handle_info({'DOWN', Mon, process, Pid, _Reason}, S) ->
    case maps:get(Pid, maps:get(active, S), undefined) of
        #{mon := Mon} -> complete(Pid, {error, decoder_worker_exit}, S);
        _ -> {noreply, S}
    end;
handle_info(_, S) -> {noreply, S}.

complete(Pid, Result, S) ->
    case maps:take(Pid, maps:get(active, S)) of
        error -> {noreply, S};
        {#{mon := Mon, key := Key, to := To, timer := Timer}, Active} ->
            erlang:demonitor(Mon, [flush]),
            erlang:cancel_timer(Timer),
            To ! {lens_media, Key, Result},
            {noreply, pump(S#{active := Active})}
    end.

terminate(_, S) ->
    maps:foreach(fun(Pid, J) ->
        erlang:cancel_timer(maps:get(timer, J)),
        exit(Pid, shutdown)
    end, maps:get(active, S)),
    ok.
code_change(_, S, _) -> {ok, S}.

older({Generation, _, _}, Gen) when is_integer(Generation) -> Generation < Gen;
older(_, _) -> false.
duplicate(Key, To, S) ->
    lists:any(fun(J) -> maps:get(key, J) =:= Key andalso maps:get(to, J) =:= To end,
              maps:values(maps:get(active, S))) orelse
    lists:any(fun({K, _, P}) -> K =:= Key andalso P =:= To end,
              queue:to_list(maps:get(queue, S))).

valid_image(#{url := <<"https://", _/binary>> = Url} = Image) when byte_size(Url) =< 4096 ->
    Hash = maps:get(sha256, Image, <<>>),
    Hash =:= <<>> orelse erm_lens_nostr:is_hex(Hash, 64);
valid_image(_) -> false.

pump(S = #{active := A, queue := Q}) when map_size(A) < 3 ->
    case queue:out(Q) of
        {empty, _} -> S;
        {{value, {Key, Image, To}}, Rest} ->
            case is_process_alive(To) of
                false -> pump(S#{queue := Rest});
                true ->
                    C = maps:get(config, S),
                    {Pid, Mon} = erm_lens_worker:start(media_result, fun() -> decode(Image, C) end),
                    Timer = erlang:send_after(30000, self(), {media_timeout, Pid}),
                    pump(S#{queue := Rest, active := A#{Pid =>
                        #{key => Key, to => To, mon => Mon, timer => Timer}}})
            end
    end;
pump(S) -> S.

decode(Image, C) ->
    try
        Python = case os:find_executable("python3") of
            false -> error(python3_not_found);
            P -> P
        end,
        case filelib:is_regular(text(maps:get(media_script, C))) of
            true -> ok;
            false -> error(media_script_not_found)
        end,
        Hosts = lists:append([["--host", text(H)] || H <- maps:get(media_hosts, C, [])]),
        Args = [text(maps:get(media_script, C)), text(maps:get(url, Image)),
                "--cache", text(maps:get(cache_dir, C)),
                "--sha256", text(maps:get(sha256, Image, <<>>))] ++ Hosts,
        Port = open_port({spawn_executable, Python}, [binary, exit_status, use_stdio, {args, Args}]),
        try
            Result = read_port(Port, <<>>, erlang:monotonic_time(millisecond) + 28000),
            validate_result(Result, Image, C)
        after
            try port_close(Port) catch _:_ -> ok end
        end
    catch
        error:python3_not_found -> {error, python3_not_found};
        error:media_script_not_found -> {error, media_script_not_found};
        _:_ -> {error, media_decoder_failed}
    end.

read_port(Port, Data, End) ->
    Left = End - erlang:monotonic_time(millisecond),
    case Left =< 0 of
        true -> {error, decoder_timeout};
        false -> receive
            {Port, {data, More}} when byte_size(Data) + byte_size(More) =< 8192 ->
                read_port(Port, <<Data/binary, More/binary>>, End);
            {Port, {data, _}} -> {error, oversized_decoder_response};
            {Port, {exit_status, Status}} -> decoder_reply(Status, Data)
        after Left -> {error, decoder_timeout}
        end
    end.

decoder_reply(Status, Data) ->
    case {Status, erm_lens_codec:decode(Data)} of
        {0, {ok, #{<<"ok">> := File} = Reply}} when is_binary(File), map_size(Reply) =:= 1 ->
            {ok, File};
        {_, {ok, #{<<"error">> := Why} = Reply}} when is_binary(Why), map_size(Reply) =:= 1 ->
            {error, erm_lens_diagnostics:summary(Why)};
        {N, _} when N =/= 0 -> {error, {decoder_exit_status, N}};
        _ -> {error, invalid_decoder_response}
    end.

validate_result({ok, File}, Image, C) ->
    Url = maps:get(url, Image),
    Hash = maps:get(sha256, Image, <<>>),
    Key = erm_lens_nostr:hex(crypto:hash(sha256, <<Url/binary, 0, Hash/binary>>)),
    Root = filename:absname(text(maps:get(cache_dir, C))),
    Expected = filename:join(Root, binary_to_list(<<Key/binary, ".png">>)),
    Reported = text(File),
    case filename:pathtype(Reported) =:= absolute andalso
         filename:basename(Reported) =:= filename:basename(Expected) of
        false -> {error, unsafe_decoder_path};
        true ->
            %% Python returns a canonical path. Compare file identity rather
            %% than strings, so a legitimate symlink in a HOME ancestor works.
            %% Always give GTK OUR computed cache path, never an arbitrary path
            %% chosen by the decoder. Final-component symlinks are rejected.
            case {file:read_link_info(Root), file:read_link_info(Expected),
                  file:read_link_info(Reported)} of
                {{ok, #file_info{type = directory, uid = Owner}},
                 {ok, #file_info{type = regular, uid = Owner, inode = Inode,
                                 major_device = Dev, minor_device = Minor, size = Size}},
                 {ok, #file_info{type = regular, uid = Owner, inode = Inode,
                                 major_device = Dev, minor_device = Minor, size = Size}}}
                  when Size > 8, Size =< 8388608 ->
                    case png_header(Expected) of
                        true -> {ok, unicode:characters_to_binary(Expected)};
                        false -> {error, invalid_cached_png}
                    end;
                _ -> {error, unsafe_decoder_file}
            end
    end;

validate_result(Error, _, _) -> Error.

text(B) when is_binary(B) -> unicode:characters_to_list(B);
text(L) when is_list(L) -> L.

png_header(Path) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, Fd} ->
            try file:read(Fd, 8) =:= {ok, <<137, 80, 78, 71, 13, 10, 26, 10>>}
            after file:close(Fd) end;
        _ -> false
    end.
