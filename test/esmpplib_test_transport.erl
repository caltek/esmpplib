-module(esmpplib_test_transport).

-export([send/2]).

send(Socket, Data) ->
    Socket ! {transport_send, Data},
    ok.
