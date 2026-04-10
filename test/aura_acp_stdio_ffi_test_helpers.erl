-module(aura_acp_stdio_ffi_test_helpers).
-export([make_empty_map/0, make_single_map/2, make_session_new_params/1,
         make_prompt_params/2, make_string_list/0,
         string_contains/2, string_starts_with/2, string_ends_with/2]).

%% Construct Erlang maps for testing jsx_encode via Gleam.
%% Gleam's Map type doesn't map directly to Erlang maps with binary keys,
%% so we build them here to match what the FFI actually receives.

make_empty_map() -> #{}.

make_single_map(Key, Value) -> #{Key => Value}.

make_session_new_params(Cwd) ->
    #{<<"cwd">> => Cwd, <<"mcpServers">> => []}.

make_prompt_params(SessionId, Text) ->
    #{<<"sessionId">> => SessionId,
      <<"prompt">> => [#{<<"type">> => <<"text">>, <<"text">> => Text}]}.

make_string_list() -> [<<"a">>, <<"b">>, <<"c">>].

%% String helpers
string_contains(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        {_, _} -> true;
        nomatch -> false
    end.

string_starts_with(String, Prefix) ->
    PLen = byte_size(Prefix),
    case String of
        <<Prefix:PLen/binary, _/binary>> -> true;
        _ -> false
    end.

string_ends_with(String, Suffix) ->
    SLen = byte_size(Suffix),
    StrLen = byte_size(String),
    case StrLen >= SLen of
        true ->
            Tail = binary:part(String, StrLen - SLen, SLen),
            Tail =:= Suffix;
        false -> false
    end.
