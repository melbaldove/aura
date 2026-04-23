-module(aura_integrations_ffi).
-export([supervisor_name/0]).

%% ---------------------------------------------------------------------------
%% aura_integrations_ffi — fixed atom name for the integrations
%% factory_supervisor so tools can look it up at runtime via
%% factory_supervisor:get_by_name/1.
%%
%% One atom total (aura_integrations_sup). Gleam's process.Name(message) is
%% an opaque wrapper over an atom; callers type the return accordingly.
%% ---------------------------------------------------------------------------

-spec supervisor_name() -> atom().
supervisor_name() -> aura_integrations_sup.
