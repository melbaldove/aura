-module(aura_integrations_ffi).
-export([supervisor_name/0]).

-spec supervisor_name() -> atom().
supervisor_name() -> aura_integrations_sup.
