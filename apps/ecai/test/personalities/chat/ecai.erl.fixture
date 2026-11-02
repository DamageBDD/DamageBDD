%% Isolated deterministic replacement for the native curve mapping dependency.
-module(ecai).
-export([hash_to_curve_point/1]).
hash_to_curve_point(Text) -> #{x => erlang:phash2(Text), y => 1}.
