-module(aura_gateway_bridge).
-export([spawn_bridge/1, ws_send/2, schedule_heartbeat/2]).

%% Spawn a bridge process that receives raw WS messages from the FFI
%% and sends typed GatewayMessage values to the Gleam actor subject.
spawn_bridge(Subject) ->
    spawn_link(fun() -> bridge_loop(Subject) end).

bridge_loop(Subject) ->
    receive
        {ws_text, Text} when is_binary(Text) ->
            %% Send WsText(text) to the Gleam subject
            %% Gleam Subject is {process, Pid, Tag}
            %% gleam_erlang_ffi:send sends {Tag, Value} to Pid
            send_to_subject(Subject, {ws_text, Text}),
            bridge_loop(Subject);
        ws_closed ->
            send_to_subject(Subject, ws_closed);
        {ws_error, Reason} ->
            send_to_subject(Subject, {ws_error, Reason})
    end.

%% Send a value to a Gleam process.Subject
%% A Subject in Gleam/Erlang is a tuple {subject, Pid, Tag}
%% Sending to it means sending {Tag, Value} to Pid
send_to_subject({subject, Pid, Tag}, Value) ->
    Pid ! {Tag, Value};
send_to_subject(Other, _Value) ->
    error_logger:error_msg("Unknown subject format: ~p~n", [Other]),
    ok.

%% Send a text frame through the WebSocket
ws_send(WsPid, Text) ->
    WsPid ! {ws_send, Text},
    nil.

%% Schedule a heartbeat by sending SendHeartbeat to a Subject after interval
schedule_heartbeat(IntervalMs, Subject) ->
    {subject, Pid, Tag} = Subject,
    erlang:send_after(IntervalMs, Pid, {Tag, send_heartbeat}),
    nil.
