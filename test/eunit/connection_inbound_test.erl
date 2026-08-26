-module(connection_inbound_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("smpp_parser/src/smpp_globals.hrl").

-behaviour(esmpplib_connection).

-export([
    on_delivery_report/8,
    on_mo_message/6
]).

abbreviated_delivery_report_test() ->
    Message = <<"id:100003200301260826144944571931 submit date:2608261449 done date:2608261449 stat:DELIVRD err:000 text:?????? ???">>,
    Body = inbound_body([{esm_class, ?ESM_CLASS_TYPE_MC_DELIVERY_RECEIPT}, {short_message, Message}]),
    handle_pdu(?COMMAND_ID_DELIVER_SM, 1, Body),
    assert_deliver_sm_response(1),
    assert_delivery_report(<<"100003200301260826144944571931">>, <<"6279">>, <<"251912646315">>, <<"DELIVRD">>, 0),
    assert_no_mo_message().

full_delivery_report_test() ->
    Message = <<"id:message-1 sub:001 dlvrd:001 submit date:2608261449 done date:2608261450 stat:DELIVRD err:000 text:">>,
    Body = inbound_body([{esm_class, 0}, {short_message, Message}]),
    handle_pdu(?COMMAND_ID_DELIVER_SM, 2, Body),
    assert_deliver_sm_response(2),
    assert_delivery_report(<<"message-1">>, <<"6279">>, <<"251912646315">>, <<"DELIVRD">>, 0),
    assert_no_mo_message().

message_payload_precedence_test() ->
    Message = <<"id:payload-id submitdate:2608261449 donedate:2608261450 stat:DELIVRD err:000">>,
    Body = inbound_body([{esm_class, 0}, {short_message, <<"not a receipt">>}, {message_payload, Message}]),
    handle_pdu(?COMMAND_ID_DELIVER_SM, 3, Body),
    assert_deliver_sm_response(3),
    assert_delivery_report(<<"payload-id">>, <<"6279">>, <<"251912646315">>, <<"DELIVRD">>, 0),
    assert_no_mo_message().

tlv_delivery_report_test() ->
    Body = inbound_body([
        {esm_class, 0},
        {short_message, <<>>},
        {receipted_message_id, <<"tlv-id">>},
        {message_state, ?MESSAGE_STATE_DELIVERED}
    ]),
    handle_pdu(?COMMAND_ID_DELIVER_SM, 7, Body),
    assert_deliver_sm_response(7),
    receive
        {delivery_report, <<"tlv-id">>, <<"6279">>, <<"251912646315">>, null, null, <<"DELIVRD">>, 0, dlr_args} ->
            ok
    after 100 ->
        ?assert(false)
    end,
    assert_no_mo_message().

malformed_marked_delivery_report_test() ->
    Body = inbound_body([{esm_class, ?ESM_CLASS_TYPE_MC_DELIVERY_RECEIPT}, {short_message, <<"invalid receipt">>}]),
    handle_pdu(?COMMAND_ID_DELIVER_SM, 4, Body),
    assert_deliver_sm_response(4),
    assert_no_callback().

normal_deliver_sm_test() ->
    Body = inbound_body([{esm_class, 0}, {short_message, <<"Hello there">>}]),
    handle_pdu(?COMMAND_ID_DELIVER_SM, 5, Body),
    assert_deliver_sm_response(5),
    receive
        {mo_message, undefined, <<"251912646315">>, <<"6279">>, <<"Hello there">>, 0, mo_args} ->
            ok
    after 100 ->
        ?assert(false)
    end,
    assert_no_delivery_report().

data_sm_delivery_report_test() ->
    Message = <<"id:100002200101260826140638052001 sub:001 dlvrd:001 submit date:2608261406 done date:2608261406 stat:DELIVRD err:000 text:">>,
    Body = inbound_body([{esm_class, ?ESM_CLASS_TYPE_MC_DELIVERY_RECEIPT}, {message_payload, Message}]),
    {ok, Packed} = smpp_operation:pack({?COMMAND_ID_DATA_SM, ?ESME_ROK, 1966520471, Body}),
    esmpplib_connection:test_process_incoming(Packed, callback_options()),
    receive
        {transport_send, Response} ->
            ?assertMatch(
                {ok, {?COMMAND_ID_DATA_SM_RESP, ?ESME_ROK, 1966520471, [{message_id, <<>>}]}},
                smpp_operation:unpack(Response)
            )
    after 100 ->
        ?assert(false)
    end,
    assert_delivery_report(<<"100002200101260826140638052001">>, <<"6279">>, <<"251912646315">>, <<"DELIVRD">>, 0),
    assert_no_mo_message().

non_receipt_data_sm_test() ->
    Body = inbound_body([{esm_class, 0}, {message_payload, <<"application data">>}]),
    handle_pdu(?COMMAND_ID_DATA_SM, 6, Body),
    receive
        {transport_send, Response} ->
            ?assertMatch(
                {ok, {?COMMAND_ID_DATA_SM_RESP, ?ESME_ROK, 6, [{message_id, <<>>}]}},
                smpp_operation:unpack(Response)
            )
    after 100 ->
        ?assert(false)
    end,
    assert_no_callback().

on_delivery_report(MessageId, SrcAddress, DstAddress, SubmitDate, DoneDate, Status, ErrorCode, Args) ->
    self() ! {delivery_report, MessageId, SrcAddress, DstAddress, SubmitDate, DoneDate, Status, ErrorCode, Args}.

on_mo_message(MessageId, SrcAddress, DstAddress, Message, DataCoding, Args) ->
    self() ! {mo_message, MessageId, SrcAddress, DstAddress, Message, DataCoding, Args}.

handle_pdu(CommandId, SequenceNumber, Body) ->
    {ok, Packed} = smpp_operation:pack({CommandId, ?ESME_ROK, SequenceNumber, Body}),
    esmpplib_connection:test_process_incoming(Packed, callback_options()).

callback_options() ->
    #{
        callback_module => ?MODULE,
        delivery_reports_args => dlr_args,
        mo_message_args => mo_args
    }.

inbound_body(Overrides) ->
    lists:foldl(
        fun({Key, Value}, Body) -> lists:keystore(Key, 1, Body, {Key, Value}) end,
        [
            {data_coding, 0},
            {registered_delivery, 0},
            {esm_class, 0},
            {destination_addr, <<"6279">>},
            {dest_addr_npi, 0},
            {dest_addr_ton, 0},
            {source_addr, <<"251912646315">>},
            {source_addr_npi, 0},
            {source_addr_ton, 0},
            {service_type, <<>>}
        ],
        Overrides
    ).

assert_deliver_sm_response(SequenceNumber) ->
    receive
        {transport_send, Response} ->
            ?assertMatch(
                {ok, {?COMMAND_ID_DELIVER_SM_RESP, ?ESME_ROK, SequenceNumber, _}},
                smpp_operation:unpack(Response)
            )
    after 100 ->
        ?assert(false)
    end.

assert_delivery_report(MessageId, SrcAddress, DstAddress, Status, ErrorCode) ->
    receive
        {delivery_report, MessageId, SrcAddress, DstAddress, SubmitDate, DoneDate, Status, ErrorCode, dlr_args} ->
            ?assert(is_integer(SubmitDate)),
            ?assert(is_integer(DoneDate))
    after 100 ->
        ?assert(false)
    end.

assert_no_callback() ->
    receive
        {delivery_report, _, _, _, _, _, _, _, _} ->
            ?assert(false);
        {mo_message, _, _, _, _, _, _} ->
            ?assert(false)
    after 20 ->
        ok
    end.

assert_no_delivery_report() ->
    receive
        {delivery_report, _, _, _, _, _, _, _, _} ->
            ?assert(false)
    after 20 ->
        ok
    end.

assert_no_mo_message() ->
    receive
        {mo_message, _, _, _, _, _, _} ->
            ?assert(false)
    after 20 ->
        ok
    end.
