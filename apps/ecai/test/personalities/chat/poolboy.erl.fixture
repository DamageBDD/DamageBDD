%% Isolated test double; never compile into the application release.
-module(poolboy).
-export([transaction/2]).
transaction(ecai_chat, F) -> F(persistent_term:get(ecai_chat_test_worker)).
