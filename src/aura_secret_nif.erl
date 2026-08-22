-module(aura_secret_nif).
-on_load(init/0).
-export([create_exclusive_beneath/4, secure_read_beneath/4,
         remove_exact_beneath/4, replace_exact_beneath/5]).

init() ->
    BeamDir = filename:dirname(code:which(?MODULE)),
    Path = filename:join([BeamDir, "..", "priv", "aura_secret_nif"]),
    erlang:load_nif(Path, 0).

create_exclusive_beneath(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
secure_read_beneath(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
remove_exact_beneath(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
replace_exact_beneath(_, _, _, _, _) -> erlang:nif_error(nif_not_loaded).
