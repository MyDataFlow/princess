-module(utp_buffer).
-include("utp.hrl").
-export([new/0]).
-export([get_seq/1,get_ack/1,set_seq/2,set_ack/2]).
-export([set_send_buf_size/2,get_send_buf_size/1]).
-export([set_recv_buf_size/2,get_recv_buf_size/1]).
-export([ack_packet/2]).

-record(utp_packet,{
          data,
        	transmissions = 0,
        	send_time = 0 :: integer(),
        	need_resend = false :: boolean()
        }).

-record(utp_buffer_context, {
          recv_buf = []              	  :: orddict:orddict(),
          send_buf = []     			      :: orddict:orddict(),
          recv_buf_size = 1024 * 1024   :: integer(),
          send_buf_size = 1024 * 1024   :: integer(),
          out_order_size  = 0           :: integer(),
          cur_window = 0                :: integer(),
          max_window = 0                :: integer(),
          peer_window = 0               :: integer(),
          reorder_count = 0             :: integer(), % When and what to reorder
          cur_window_packets = 0        :: integer(),
          got_fin = false			 :: boolean(),
          eof_nr = 0 					 :: 0..16#FFFF,
          ack_nr = 0      		 :: 0..16#FFFF, % Next expected packet
          seq_nr = 0           :: 0..16#FFFF % Next Sequence number to use when sending
       	}).

new()->
	#utp_buffer_context{}.

get_send_buf_size(Context)->
  Context#utp_buffer_context.send_buf_size.
get_recv_buf_size(Context)->
  Context#utp_buffer_context.recv_buf_size.
get_seq(Context)->
	Context#utp_buffer_context.seq_nr.
get_ack(Context)->
	Context#utp_buffer_context.ack_nr.

set_send_buf_size(Context,SendBufSize)->
  Context#utp_buffer_context{send_buf_size =  SendBufSize}.
set_recv_buf_size(Context,RecvBufSize)->
  Context#utp_buffer_context{recv_buf_size = RecvBufSize}.
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


update_recv_buffer(SeqNo, Payload,
                   #utp_buffer_context{ got_fin = true,eof_nr = SeqNo,
                   ack_nr = SeqNo } = Context, Acc) ->
	NewAcc = [Payload|Acc],
    {got_fin, lists:reverse(NewAcc),
    	Context#utp_buffer_context{ ack_nr = utp_util:bit16(SeqNo + 1)}};
update_recv_buffer(SeqNo, Payload, #utp_buffer_context{ ack_nr = SeqNo } = Context, Acc) ->
	NewAcc = [Payload|Acc],
    satisfy_from_recv_buffer(
      Context#utp_buffer_context{ ack_nr = utp_util:bit16(SeqNo + 1) }, NewAcc);
update_recv_buffer(SeqNo, Payload, Context, Acc) when is_integer(SeqNo) ->
   R =  recv_buffer_in(SeqNo, Payload,Context),
   case R of
   	duplicate  ->
   		duplicate;
   	{ok,NewContext}->
   		{ok,lists:reverse(Acc),NewContext}
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

recv_buffer_in(Context,SeqNo,Payload) ->
    case orddict:is_key(SeqNo, Context#utp_buffer_context.recv_buf) of
        true -> 
        	duplicate;
        false -> 
        	RecvBuf = orddict:store(SeqNo,Payload,Context#utp_buffer_context.recv_buf),
        	{ok, Context#utp_buffer_context{recv_buf= RecvBuf}}
    end.

overflow(Context,Bytes)->
  CurWindowPackets = Context#utp_buffer_context.cur_window_packets + 1,
  if
    CurWindowPackets >= (?UTP_SEND_BUFFER_MAX_SLOT -1) ->
      true;
    true->
      Win = send_window(Context),
      CurWin = Context#utp_buffer_context.cur_window,
      All = CurWin + Bytes,
      if 
        All > Win ->
          true;
        true ->
          false
      end
  end.

send_window(#utp_buffer_context{send_buf_size = SendBufSize,max_window = MaxWin,
  peer_window = PeerWin})->
  lists:min([SendBufSize,MaxWin,PeerWin]).

recv_window(#utp_buffer_context{out_order_size = Recved, recv_buf_size = RecvBufSize}) ->
  case RecvBufSize - Recved of
      N when N >= 0 ->
          N;
      N when N < 0 ->
          0 % Case happens when the sender forces a packet through
  end.
