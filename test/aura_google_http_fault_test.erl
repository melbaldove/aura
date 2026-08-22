-module(aura_google_http_fault_test).
-export([direct_get/3, direct_get_with_timeout/4]).

direct_get(Url, Bearer, Origin) ->
    aura_google_http_ffi:request_for_test(
      <<"GET">>, Url, Bearer, <<>>, <<>>, 1048576, 1, Origin).

direct_get_with_timeout(Url, Bearer, Origin, TimeoutMs) ->
    aura_google_http_ffi:request_for_test_with_timeout(
      <<"GET">>, Url, Bearer, <<>>, <<>>, 1048576, 1, Origin, TimeoutMs).
