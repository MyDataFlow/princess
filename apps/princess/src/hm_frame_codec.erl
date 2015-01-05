-module(hm_frame_codec).
-export([fixed_length_encode/2,fixed_length_decode/2]).

fixed_length_encode(Fixed,Data)->
	if 
		Fixed =< 2 ->
			error;
		Fixed > 65535 ->
			error;
		true->
			Len = erlang:byte_size(Data),
			fixed_length_encode(Fixed - 2, Len,Data)
	end.
fixed_length_encode(Fixed,Len,Data)->
	Full = Len div Fixed,
	Remain = Len rem Fixed,
	{FullPackets,RemainData} = fixed_length_encode_full(Fixed,Full,Data,[]),
	Packets = if
		Remain > 0 ->
			Packet1 = <<Remain:16/little-integer,RemainData/bits>>,
			Diff = (Fixed - Remain) * 8,
			Packet = <<Packet1/bits,0:Diff/little-integer>>,
			[Packet|FullPackets];
		true ->
			FullPackets
	end,
	Buff = lists:foldr(
		fun(E,Acc)->
			<<Acc/bits,E/bits>>
		end,<<>>,Packets),
	{ok,Buff}.

fixed_length_encode_full(_Fixed,0,Data,Acc)->
	{Acc,Data};
fixed_length_encode_full(Fixed,Full,Data,Acc)->
	<<Payload:Fixed/binary, Rest/bits>> = Data,
	Packet = <<Fixed:16/little-integer,Payload/bits>>,
	fixed_length_encode_full(Fixed,Full-1,Rest,[Packet|Acc]).

fixed_length_decode(Fixed,Data)->
	if 
		Fixed =< 2 ->
			error;
		Fixed > 65535 ->
			error;
		true->
			Len = erlang:byte_size(Data),
			fixed_length_decode(Fixed, Len,Data)
	end.
fixed_length_decode(Fixed, Len,Data) when  Len < Fixed ->
	{error,Data};

fixed_length_decode(Fixed,Len,Data)->
	Full = Len div Fixed,
	{Packets,RemainData} = fixed_length_decode_full(Fixed,Full,Data,[]),
	Buff = lists:foldr(
		fun(E,Acc)->
			<<Acc/bits,E/bits>>
		end,<<>>,Packets),
	{ok,Buff,RemainData}.

fixed_length_decode_full(_Fixed,0,Data,Acc)->
	{Acc,Data};
fixed_length_decode_full(Fixed,Full,Data,Acc)->
	<<Payload:Fixed/binary,Rest/bits>> = Data,
	<<PayloadSize:16/little-integer,PayloadData/bits>> = Payload,
	PayloadDataSize  = erlang:byte_size(PayloadData),
	RelPayload = if 
			PayloadSize < PayloadDataSize ->
				<<Rel:PayloadSize/binary,_/bits>> = PayloadData,
				Rel;
			true ->
				PayloadData
			end,
	fixed_length_decode_full(Fixed,Full-1,Rest,[RelPayload|Acc]).