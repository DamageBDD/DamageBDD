# ZJ: The tiny JSON encoder/decoder.
This is a single-module library that encodes and decodes JSON.
The JSON definition followed is RFC-8259.


This library exposes four functions: `encode/1`, `decode/1`, `binary_encode/1`, `binary_decode/1`.

## `encode/1`
`encode/1` crashes on data that it cannot handle.
The kinds of data `encode/1` cannot handle are:
 - unaligned bitstrings
 - binaries that do not encode printable utf-8 strings
 - objects with illegal keys (values that do not convert to utf-8 strings)

`encode/1` does not accept magical values such as tagged tuple indicators
to distinguish between types (for example: lists-as-strings and lists-as-lists).
For the vast majority of encoding uses encode/1 is the right option. If you require
lists of integer values to *always* be encoded as arrays (not strings) and
are willing to convert all internal `io_list` data to binary UTF-8 strings before calling
an encoding function, then `binary_encode/1` is for you.

## `decode/1`
`decode/1` returns a success/fail tuple:
 - `{ok, Value}` on success
 - `{error, Partial, Remaining}` on failure
 - `{incomplete, Partial, Remaining}` from `unicode:characters_to_list/1` on illegal unicode

No annotated or magical JSON types are anticipated by this function. It is very unlikely
that any will be added in the future.

## `binary_encode/1`
Very similar to `encode/1` (including crashing on bad input values), except
for the following differences:
 - Returns a binary string
 - Interprets *all* binaries as UTF-8 strings
 - Interprets *all* lists as arrays of values (JSON `"foo"` -> Erlang `<<"foo">>`; JSON `[102, 111, 111]` -> Erlang `[102, 111, 111]`)

## `binary_decode/1`
Very similar to `decode/1`, except for the following differences:
 - All strings are returned as binaries (including map keys)
 - All arrays of integers are lists, whether or not they are valid UTF-8 sequences
 - The `Remaining` component of `{error, Partial, Remaining}` is a binary, not a string


# Examples (in the shell):
```
1> zj:encode(1492).
"1492"
2> zj:decode("1492").
{ok,1492}
3> zj:decode("14.242e-21").
{ok,1.4242e-20}
4> zj:encode([1, 2, 3, 4]).
"[1,2,3,4]"
5> zj:decode("[1, 2, 3, 4]").
{ok,[1,2,3,4]}
6> zj:encode("Hello").
"\"Hello\""
7> zj:encode(<<"Hello">>).
"\"Hello\""
8> zj:encode(some_atom).  
"\"some_atom\""
9> zj:encode(#{some => ["set", "of"], "data" => ["that you", <<"want encoded">>]}).
"{\"data\":[\"that you\",\"want encoded\"],\"some\":[\"set\",\"of\"]}"
10> zj:decode("{\"data\":[\"that you\",\"want encoded\"],\"some\":[\"set\",\"of\"]}").
{ok,#{"data" => ["that you","want encoded"],
      "some" => ["set","of"]}}
11> zj:decode("[\"A map with an illegal key\", {42:\"boom!\"}").
{error,["A map with an illegal key",#{}],"42:\"boom!\"}"}
12> zj:decode("An illegally unquoted string").
{error,[],"An illegally unquoted string"}
13> zj:decode("\"An illegal, lonely quote mark\" \"").        
{error,"An illegal, lonely quote mark","\""}
```

# Type Mapping
Types don't match well between Erlang and JSON. There are tradeoffs involved in any
mapping. Note that the mapping for the function `binary_encode/1` is slightly different
(and requires a little bit more work to use) but provides a completely unambiguous
way to generate lists of integer values VS unicode strings.

## `encode/1` (Erlang -> JSON)
```
Integer   -> Integer
Float     -> Float
Map       -> Object
List      -> Array
Tuple     -> Array
Binary    -> String
UTF-8     -> String
true      -> true
false     -> false
undefined -> null
Atom      -> String
PID       -> String
Port      -> String
Function  -> String
```

## `decode/1` (JSON -> Erlang)
```
Integer -> Integer
Float   -> Float
String  -> String
Object  -> Map
Array   -> List
true    -> true
false   -> false
null    -> undefined
```

## `binary_encode/1` (Erlang -> JSON)
```
Integer   -> Integer
Float     -> Float
Map       -> Object
List      -> Array
Tuple     -> Array
Binary    -> String
true      -> true
false     -> false
undefined -> null
Atom      -> String
PID       -> String
Port      -> String
Function  -> String
```

## `binary_decode/1` (JSON -> Erlang)
```
Integer -> Integer
Float   -> Float
String  -> Binary
Object  -> Map
Array   -> List
true    -> true
false   -> false
null    -> undefined
```


# Rationale
This library scratches a few itches of mine.

## Six needs
 - I need to be able to read really basic JSON (This means RFC-8259, not everything allowable as per the lolscript standard)
 - The data might contain complex utf-8 character constructions
 - Must work on Windows (client-side) with only zx + Erlang installed
 - Mochi is based on obsolete "tuple calls" in Erlang, and support finally died R21
 - String output needs to be actual strings
 - I like tiny, targeted projects where problems are *obvious*

## Six 'meh' factors
 - lolspeed is not a requirement
 - JSON objects are represented best as Erlang maps
 - The memory footprint of strings is not a concern
 - Most outrageous JSON "gotcha" cases don't apply to my data
 - Letting Erlang chomp large precision floats or accept bignums is OK
 - Strings nested in things has worked without magical type specifiers

On the note of strings, the function `binary_encode/1` was added specifically to provide
a way to disambiguate between lists and strings when encoding, but in the most common
use cases this is not necessary. The inverse, `binary_decode/1` serves two purposes that
are similarly not of paramount importance in most cases: reducing the memory footprint
of Erlang strings and (more importantly) disambiguating between JSON integer arrays and
strings (but srsly if you have no clue what data you're receiving, then...?).

# Contributing
If you find this library useful and would like to see a feature added, please contact
the author via email (see author line in source), IRC, or Erlang's Slack channel (ugh).

If you want to turn this into a 10k LoC project, consider using JSX (https://github.com/talentdeficit/jsx) instead.
