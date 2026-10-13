%% -*- erlang -*-
%% Layer 2: Words (compound nodes) for ECAI/SPOC/EKEF

-module(ecai_words).
-export([
    mint_word/2,
    mint_word/3,
    spoc_word_instance/2,
    spoc_word_length/2,
    spoc_word_composed_of/2,
    spoc_word_char_at/4,
    normalize_word/1,
    word_chars/1
]).

%% ---------------------------
%% Public API
%% ---------------------------

%% Default language: english
mint_word(KeyPair, Word) ->
    mint_word(KeyPair, Word, <<"english language">>).

%% Mint all Layer-2 facts for a word:
%%  - "word is instance of word in <lang>"
%%  - "word has length N in <lang>"
%%  - "word composed_of [c1,c2,...,cn] in <lang>"
%%  - "word has character <ci> at position i; language=<lang>"
mint_word(KeyPair, Word0, Lang0) ->
    Word = normalize_word(Word0),
    Lang = to_bin(Lang0),

    %% 1) Instance-of word
    ok = call_mint(KeyPair, spoc_word_instance(Word, Lang)),
    %% 2) Length
    ok = call_mint(KeyPair, spoc_word_length(Word, Lang)),
    %% 3) Composition list
    ok = call_mint(KeyPair, spoc_word_composed_of(Word, Lang)),
    %% 4) Per-position character facts
    Chars = word_chars(Word),
    lists:foreach(
        fun({Idx, C}) ->
            ok = call_mint(KeyPair, spoc_word_char_at(Word, Idx, C, Lang))
        end,
        index_chars(Chars)
    ),
    ok.

%% ---------------------------
%% SPOC builders
%% ---------------------------

%% "cat" is instance of word in english language
spoc_word_instance(WordBin, LangBin) ->
    #{
        subject => WordBin,
        predicate => "is instance of",
        object => "word",
        context => LangBin
    }.

%% "cat" has length 3 in english language
spoc_word_length(WordBin, LangBin) ->
    #{
        subject => WordBin,
        predicate => "has length",
        object => integer_to_binary(length(word_chars(WordBin))),
        context => LangBin
    }.

%% "cat" composed_of ["c","a","t"] in english language
%% NOTE: EKEF/VRLP supports nested lists; object is a list of binaries
spoc_word_composed_of(WordBin, LangBin) ->
    #{
        subject => WordBin,
        predicate => "composed_of",
        object => word_chars(WordBin),
        context => LangBin
    }.

%% "cat" has character "c" at position 1 ; language=<Lang>
%% We keep 'position' in the context to keep object purely the character.
spoc_word_char_at(WordBin, Pos, CharBin, LangBin) ->
    #{
        subject => WordBin,
        predicate => "has character",
        object => CharBin,
        context => iolist_to_binary([
            "position=",
            integer_to_binary(Pos),
            "; language=",
            LangBin
        ])
    }.

%% ---------------------------
%% Helpers
%% ---------------------------

normalize_word(Word0) ->
    %% Canonicalize to lower-case + trimmed; adjust to taste
    Word1 = to_bin(Word0),
    Word2 = unicode:characters_to_binary(string:trim(string:lower(binary_to_list(Word1)))),
    Word2.

word_chars(WordBin) ->
    %% Produce list of one-char binaries in UTF-8
    [<<C/utf8>> || C <- unicode:characters_to_list(WordBin)].

index_chars(CharBins) ->
    %% 1-based indexing to match letter ordinals layer
    lists:zip(lists:seq(1, length(CharBins)), CharBins).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(C) when is_integer(C) -> <<C>>.

%% Small adapter to your mint_knowledge/2
call_mint(KeyPair, KnowledgeMap) ->
    case ecai:mint_knowledge(KeyPair, KnowledgeMap) of
        {ok, _Tx} -> ok;
        ok -> ok;
        Other -> error({mint_failed, Other})
    end.
