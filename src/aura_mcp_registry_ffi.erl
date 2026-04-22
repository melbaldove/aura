-module(aura_mcp_registry_ffi).
-export([make_name/1]).

%% ---------------------------------------------------------------------------
%% aura_mcp_registry_ffi — deterministic atom names for MCP client registry.
%%
%% The pool (aura/mcp/pool.gleam) maps the string name of each configured MCP
%% server onto a deterministic Erlang atom of the form `aura_mcp_<name>`.
%% That atom is the registered process name used by actor.named/2, so both the
%% client (when it starts and registers itself) and the pool's get_client/1
%% lookup resolve to the same atom from the server's string name.
%%
%% Deterministic (not randomised) because lookup is by user-supplied string.
%% The atom namespace is bounded: one atom per MCP server in the config, all
%% known at start-up. The warning in gleam/erlang/process about generating
%% names dynamically applies to unbounded generation — this is bounded by
%% configuration.
%%
%% Returns an atom. Gleam's process.Name(message) is an opaque wrapper over an
%% atom; this FFI's caller in pool.gleam types the return as Name so the rest
%% of the Gleam code can use actor.named/2 and process.named/1 directly.
%% ---------------------------------------------------------------------------

-spec make_name(binary()) -> atom().
make_name(Name) when is_binary(Name) ->
    binary_to_atom(<<"aura_mcp_", Name/binary>>, utf8).
