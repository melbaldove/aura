-module(aura_browser_ffi_test_helpers).
-export([run_with_fake_agent_browser/0]).

run_with_fake_agent_browser() ->
    OriginalPath = os:getenv("PATH"),
    TempDir = filename:join(
        "/tmp",
        "aura-browser-ffi-test-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    Executable = filename:join(TempDir, "agent-browser"),
    ok = file:make_dir(TempDir),
    ok = file:write_file(Executable, <<"#!/bin/sh\nprintf '%s' \"$*\"\n">>),
    ok = file:change_mode(Executable, 8#755),
    true = os:putenv("PATH", TempDir),
    try
        aura_browser_ffi:run(
            <<"ffi-test">>,
            <<>>,
            <<"snapshot">>,
            [<<"-c">>],
            1000
        )
    after
        true = os:putenv("PATH", OriginalPath),
        ok = file:delete(Executable),
        ok = file:del_dir(TempDir)
    end.
