-module(princess_udp_packet).

-include("priv/udp_seq.hrl").

-record(state,{
		next_seq = 0,
		queue = []
	}).

init()->
	#state{}.

decode(Packet,State)->
	CheckedPacket = check_packet(Packet),
	case CheckedPacket of
		undefined ->
			undefined;
		{Data,_CRC} ->
			decode_packet(Data,State)
	end.
decode_packet(<<PacketSeq:32/big,Frame:1,Data/binary>> = Packet,State)->
	NextSeq = State#state.next_seq,
	if
		NextSeq ==  PacketSeq ->	
			State1 = State#state{next_seq = ?SEQ_NEXT(NextSeq)},
			decode_or_enqueue(PacketSeq,Frame,Packet,State1);
		true ->
			enqueue(PacketSeq,Packet,State)
	end.

enqueue(PacketSeq,Packet,State)->
	Queue = orddict:store(PacketSeq,Packet,State#state.queue)
	State#state{queue = Queue}.
%% Frame is zero 
%% it means that it's not the last frame
decode_or_enqueue(PacketSeq,0,Packet,State)->
	enqueue(PacketSeq,Packet,State);

decode_or_enqueue(PacketSeq,1,Packet,State)->
	Queue = orddict:store(PacketSeq,Packet,State#state.queue)
	State#state{queue = Queue}.

check_packet(Packet) when erlang:size(Packet) < 8->
	undefined;

check_packet(Packet)->
	Size = erlang:size(Packet),
	DataSize = Size - 8,
	<<Data:DataSize/binary,CRC:8/binary>> = Packet,
	CRC1 = erlang:binary_to_list(CRC),
	CRC2 = checksum(Data),
	if
		CRC2 == CRC1 ->
			{Data,CRC}
		true ->
			undefined
	end.

checksum(Bin)->
	CRC = erlang:crc32(Bin),
	[C] = io_lib:format("~.16B",[CRC]),
	C.