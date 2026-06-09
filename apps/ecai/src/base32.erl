%% RFC 4648 Base32 encoder (no padding)
-module(base32).
-export([encode/1]).

-define(ALPHABET, <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567">>).

encode(Bin) when is_binary(Bin) ->
    encode_bits(Bin, 0, 0, []).

encode_bits(<<>>, 0, 0, Acc) ->
    list_to_binary(lists:reverse(Acc));
encode_bits(<<>>, Bits, Value, Acc) ->
    Index = (Value bsl (5 - Bits)) band 31,
    Char = binary:at(?ALPHABET, Index),
    encode_bits(<<>>, 0, 0, [Char | Acc]);
encode_bits(<<Byte, Rest/binary>>, Bits, Value, Acc) ->
    NewValue = (Value bsl 8) bor Byte,
    NewBits = Bits + 8,
    emit(NewValue, NewBits, Rest, Acc).

emit(Value, Bits, Rest, Acc) when Bits >= 5 ->
    Index = (Value bsr (Bits - 5)) band 31,
    Char = binary:at(?ALPHABET, Index),
    emit(Value, Bits - 5, Rest, [Char | Acc]);
emit(Value, Bits, Rest, Acc) ->
    encode_bits(Rest, Bits, Value, Acc).
