-module(utp_buffer).
-include("utp.hrl").
-export([new/0]).
-export([get_seq/1,get_ack/1,set_seq/2,set_ack/2]).
-export([overflow/1]).
-export([ack_packet/2]).

-record(utp_packet,{
			data,
        	transmissions = 0,
        	send_time = 0 :: integer(),
        	need_resend = false :: boolean()
        }).

-record(utp_buffer_context, {
          recv_buf = []              	:: orddict:orddict(),
          send_buf = []     			:: orddict:orddict(),
          reorder_count = 0             :: integer(), % When and what to reorder
          cur_window_packets = 0        :: integer(),
          got_fin = false				:: boolean(),
          eof_nr = 0 					:: 0..16#FFFF,
          ack_nr = 0      				:: 0..16#FFFF, % Next expected packet
          seq_nr = 0                    :: 0..16#FFFF % Next Sequence number to use when sending
       	}).

new()->
	#utp_buffer_context{}.

get_seq(Context)->
	Context#utp_buffer_context.seq_nr.
get_ack(Context)->
	Context#utp_buffer_context.ack_nr.
set_seq(Context,Seq)->
	Context#utp_buffer_context{seq_nr = Seq}.
set_ack(Context,Ack)->
	Context#utp_buffer_context{ack_nr = Ack}.

ack_packet(Context,Seq)->
	Packet = orddict:find(Seq,Context#utp_buffer_context.send_buf),
	case Packet of
		{ok,_}->
			{Ret,SendTime} = ack_packet_internal(Packet),
			case Ret of
				{error,_}->
					{error,0,Context};
				{ok,_}->
					SendBuf = orddict:erase(Seq,Context#utp_buffer_context.send_buf),
					CurWindowPackets = Context#utp_buffer_context.cur_window_packets -1 ,
					NewContext = Context#utp_buffer_context{
						send_buf = SendBuf,
						cur_window_packets = CurWindowPackets
					},
					{ok,SendTime,NewContext}
				end;
		error->
			{error,0,Context}
	end.
ack_packet_internal(#utp_packet{transmissions = 0} = _Packet)->
	{error,0};
ack_packet_internal(#utp_packet{need_resend = true} = _Packet)->
	{error,0};
ack_packet_internal(#utp_packet{transmissions = 1,need_resend = false} = Packet)->
	{ok,Packet#utp_packet.send_time}.

overflow(Context)->
	CurWindowPackets = Context#utp_buffer_context.cur_window_packets + 1,
	if
		CurWindowPackets >= (?UTP_SEND_BUFFER_MAX_SLOT -1) ->
			true;
		true->
			false
	end.


satisfy_from_recv_buffer(#utp_buffer_context{recv_buf = [] } = Context,Acc) ->
    {ok, list:reverse(Acc),Context};

satisfy_from_recv_buffer(#utp_buffer_context{ ack_nr = AckNo,
                                       got_fin = true,eof_nr = AckNo,
                                       recv_buf = [{AckNo, Payload} | R]} = Context,Acc) ->
	NewAcc = [Payload|Acc],
    {got_fin,list:reverse(NewAcc),Context#utp_buffer_context{ ack_nr = utp_util:bit16(AckNo + 1),
                             recv_buf = R}};

satisfy_from_recv_buffer(#utp_buffer_context{ ack_nr = AckNo,
                                       recv_buf = [{AckNo, Payload} | R]} = Context,Acc) ->
	NewAcc = [Payload|Acc],
    satisfy_from_recv_buffer(
      Context#utp_buffer_context { ack_nr = utp_util:bit16(AckNo + 1),
                     recv_buf = R},NewAcc);
satisfy_from_recv_buffer(#utp_buffer_context{} = Context,Acc) ->
    {ok,list:reverse(Acc),Context}.

recv_buffer_in(Context,Seq,Payload) ->
    case orddict:is_key(Seq, Context#utp_buffer_context.recv_buf) of
        true -> 
        	duplicate;
        false -> 
        	RecvBuf = orddict:store(Seq,Payload,Context#utp_buffer_context.recv_buf),
        	{ok, Context#utp_buffer_context{recv_buf= RecvBuf}}
    end.

