-module(aura_imap_ffi).
-export([connect/3, send/2, recv/3, set_packet_mode/2, close/1, base64_encode/1, unique_tag/0]).

%% ---------------------------------------------------------------------------
%% aura_imap_ffi — thin wrapper around the Erlang `ssl` module for the IMAP
%% client. Constructing the `ssl:connect/4` options proplist (atom tuples,
%% `public_key:cacerts_get()`, SNI string) from Gleam would require a lot
%% of dynamic/atom shuffling; doing it here in a handful of lines of Erlang
%% keeps the Gleam side clean while still leaving parsing + state machine
%% in pure Gleam.
%%
%% Opaque Socket handle is opaque to Gleam (stored as a Dynamic). Callers
%% only pass it back into send/2, recv/3, close/1.
%% ---------------------------------------------------------------------------

%% connect(Host :: binary(), Port :: integer(), TimeoutMs :: integer())
%%   -> {ok, Socket} | {error, BinaryReason}
connect(Host, Port, TimeoutMs) ->
    %% ssl:start/0 is idempotent — returns ok or {error, {already_started, ssl}}.
    ssl:start(),
    HostStr = binary_to_list(Host),
    Opts = [
        {packet, line},
        binary,
        {active, false},
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, HostStr},
        {customize_hostname_check,
            [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    case ssl:connect(HostStr, Port, Opts, TimeoutMs) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% send(Socket, Data :: binary()) -> ok | {error, BinaryReason}
send(Socket, Data) ->
    case ssl:send(Socket, Data) of
        ok -> {ok, nil};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% recv(Socket, Len :: integer(), TimeoutMs :: integer())
%%   -> {ok, Binary} | {error, timeout} | {error, BinaryReason}
%% With {packet, line} the socket returns exactly one line at a time when
%% Len = 0. The `timeout` atom is returned verbatim so callers can pattern
%% match it; other errors are stringified.
recv(Socket, Len, TimeoutMs) ->
    case ssl:recv(Socket, Len, TimeoutMs) of
        {ok, Data} -> {ok, Data};
        {error, timeout} -> {error, <<"timeout">>};
        {error, closed} -> {error, <<"closed">>};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% set_packet_mode(Socket, <<"line">> | <<"raw">>) -> ok | {error, BinaryReason}
%% Body literals need raw reads, while the normal IMAP command loop uses line
%% packets. Switching modes locally keeps the Gleam parser simple for both.
set_packet_mode(Socket, Mode) ->
    Packet = case Mode of
        <<"raw">> -> raw;
        <<"line">> -> line;
        _ -> line
    end,
    case ssl:setopts(Socket, [{packet, Packet}]) of
        ok -> {ok, nil};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% close(Socket) -> nil
close(Socket) ->
    catch ssl:close(Socket),
    nil.

%% base64_encode(Binary) -> Binary
%% Exposed so the Gleam side doesn't need yet another @external for this.
base64_encode(Data) ->
    base64:encode(Data).

%% unique_tag/0 — monotonically increasing positive integer, used by the
%% Gleam side to build command tags (a1, a2, ...). Uses
%% erlang:unique_integer/1 with positive + monotonic modifiers. Per-VM
%% unique, so connections can share the sequence without collision.
unique_tag() ->
    erlang:unique_integer([positive, monotonic]).
