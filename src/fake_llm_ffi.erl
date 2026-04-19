-module(fake_llm_ffi).
-export([stream_delta/2, stream_reasoning/1, stream_complete/4, stream_error/2]).

%% ---------------------------------------------------------------------------
%% fake_llm_ffi — helper for fake_llm.gleam to send raw tagged tuples
%% matching the production LLM streaming protocol (see aura_stream_ffi) to
%% a caller-supplied Pid. Gleam can't build bare tagged tuples for sends,
%% so we do it here.
%% ---------------------------------------------------------------------------

stream_delta(Pid, Text) ->
    Pid ! {stream_delta, Text},
    nil.

stream_reasoning(Pid) ->
    Pid ! stream_reasoning,
    nil.

stream_complete(Pid, Content, ToolCallsJson, PromptTokens) ->
    Pid ! {stream_complete, Content, ToolCallsJson, PromptTokens},
    nil.

stream_error(Pid, Reason) ->
    Pid ! {stream_error, Reason},
    nil.
