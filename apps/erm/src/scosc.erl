%%% scosc.erl -- Erlang → SuperCollider OSC client
-module(scosc).
-compile([export_all, nowarn_export_all]).

-define(SC_HOST, {127, 0, 0, 1}).
-define(SC_PORT, 57110).

-record(sc, {sock, host = ?SC_HOST, port = ?SC_PORT}).

%%% =================
%%% Public API
%%% =================

connect() ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    Sc = #sc{sock = Sock},
    Sc.

close(#sc{sock = Sock}) -> gen_udp:close(Sock).

status(Sc) -> send(Sc, "/status", []).
% 1=enable server logging
dumpOSC(Sc, OnOff) -> send(Sc, "/dumpOSC", [OnOff]).

s_new(Sc, NodeId, AddAction, Target, Pairs) ->
    send(Sc, "/s_new", ["default", NodeId, AddAction, Target] ++ Pairs).

n_set(Sc, NodeId, Pairs) ->
    send(Sc, "/n_set", [NodeId] ++ Pairs).

n_free(Sc, NodeId) ->
    send(Sc, "/n_free", [NodeId]).

%%% quick sweep demo
demo() ->
    Sc = connect(),
    NodeId = 1000,
    ok = s_new(Sc, NodeId, 0, 1, ["freq", 220.0, "amp", 0.2]),
    sweep(Sc, NodeId, 220.0, 880.0, 40, 30),
    timer:sleep(300),
    n_free(Sc, NodeId),
    close(Sc),
    ok.

sweep(_Sc, _Node, _From, _To, 0, _Delay) ->
    ok;
sweep(Sc, Node, From, To, Steps, Delay) ->
    T = Steps - 1,
    Curr = From + (To - From) * (1 - (T / (Steps - 1))),
    n_set(Sc, Node, ["freq", Curr]),
    timer:sleep(Delay),
    sweep(Sc, Node, From, To, T, Delay).

%%% =================
%%% OSC encode/send
%%% =================

send(#sc{sock = Sock, host = Host, port = Port}, Addr, Args) ->
    Packet = osc_packet(Addr, Args),
    gen_udp:send(Sock, Host, Port, Packet).

osc_packet(Address, Args) ->
    AddrBin = osc_string(Address),
    {Tags, ArgsBin} = osc_args(Args),
    <<AddrBin/binary, Tags/binary, ArgsBin/binary>>.

osc_args(Args) ->
    TagsList = [$,] ++ [osc_tag(A) || A <- Args],
    Tags = osc_string(list_to_binary(TagsList)),
    {Tags, iolist_to_binary([osc_arg_bin(A) || A <- Args])}.

osc_tag(A) when is_integer(A) -> $i;
osc_tag(A) when is_float(A) -> $f;
osc_tag(A) when is_list(A) -> $s;
osc_tag(A) when is_binary(A) -> $s;
osc_tag({blob, _}) -> $b;
osc_tag(_) -> $N.

osc_arg_bin(A) when is_integer(A) ->
    <<A:32/big-signed>>;
osc_arg_bin(A) when is_float(A) ->
    <<(float32be(A))/binary>>;
osc_arg_bin(A) when is_list(A) ->
    osc_string(unicode:characters_to_binary(A));
osc_arg_bin(A) when is_binary(A) ->
    osc_string(A);
osc_arg_bin({blob, Bin}) when is_binary(Bin) ->
    Pad = pad4(byte_size(Bin)),
    Size = byte_size(Bin),
    <<Size:32/big, Bin/binary, 0:Pad/unit:8>>;
osc_arg_bin(_) ->
    <<>>.

osc_string(Bin) ->
    % +1 for nul
    Pad = pad4(byte_size(Bin) + 1),
    <<Bin/binary, 0, 0:Pad/unit:8>>.

pad4(Len) ->
    case Len band 3 of
        0 -> 0;
        R -> 4 - R
    end.

float32be(F) ->
    <<X:32/float>> = <<F:32/float>>,
    <<X:32/big>>.
