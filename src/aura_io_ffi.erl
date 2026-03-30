-module(aura_io_ffi).
-export([get_line/1, get_password/1, set_permissions/2]).

get_line(Prompt) ->
    case io:get_line(Prompt) of
        eof -> {error, <<"eof">>};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))};
        Data -> {ok, string:trim(unicode:characters_to_binary(Data))}
    end.

get_password(Prompt) ->
    %% Note: echo suppression removed — causes crashes under gleam run.
    %% Credentials are visible during input. Acceptable for local-only use.
    get_line(Prompt).

set_permissions(Path, Mode) ->
    file:change_mode(binary_to_list(Path), Mode),
    nil.
