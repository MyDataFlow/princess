-module(fixed_length_codec).
-export([encode/2,decode/2,new/2]).
-record(fixed_length_codec_context,{
			field_length,
			fixed_length,
			remain
		}).

new(Field,Fixed)->
	case check_overflow(Field,Fixed) of
		false  ->
			{error,undefined};
		true->
			Conext = #fixed_length_codec_context{
					field_length = Field,
					fixed_length = Fixed,
					remain = <<>>
				},
			{ok,Conext}
	end.

check_overflow(1,Fixed) when Fixed < 256->
	true;
check_overflow(2,Fixed) when Fixed < 65536->
	true;
check_overflow(3,Fixed) when Fixed < 16777216 ->
	true;
check_overflow(Field,_Fixed) when Field =< 8->
	true;
check_overflow(_Field,_Fixed)->
	false.
	
encode(Conext,Data)->
	Field = Conext#fixed_length_codec_context.field_length,
	Fixed = Conext#fixed_length_codec_context.fixed_length,
	Len = erlang:byte_size(Data),
	{ok,Buff} = fixed_length_encode(Field,Fixed, Len,Data),
	{ok,Buff,Conext}.

fixed_length_encode(Field,Fixed,Len,Data)->
	Full = Len div Fixed,
	Part = Len rem Fixed,
	FiledBits = Field * 8,
	{FullPackets,PartData} = fixed_length_encode_full(FiledBits,Fixed,Full,Data,[]),
	Packets = if
		Part > 0 ->
			Packet1 = <<Part:FiledBits/little-integer,PartData/bits>>,
			Diff = (Fixed - Part) * 8,
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

fixed_length_encode_full(_FiledBits,_Fixed,0,Data,Acc)->
	{Acc,Data};
fixed_length_encode_full(FiledBits,Fixed,Full,Data,Acc)->
	<<Payload:Fixed/binary, Rest/bits>> = Data,
	Packet = <<Fixed:FiledBits/little-integer,Payload/bits>>,
	fixed_length_encode_full(FiledBits,Fixed,Full-1,Rest,[Packet|Acc]).

decode(Conext,Data)->
	Field = Conext#fixed_length_codec_context.field_length,
	Fixed = Conext#fixed_length_codec_context.fixed_length,
	Remain = Conext#fixed_length_codec_context.remain,
	NewData = <<Remain/bits,Data/bits>>,
	Len = erlang:byte_size(NewData),
	{ok,Buff,RemainData} = fixed_length_decode(Field,Fixed + Field, Len,NewData),
	{ok,Buff,Conext#fixed_length_codec_context{remain = RemainData}}.

fixed_length_decode(_Field,Fixed, Len,Data) when  Len < Fixed ->
	{ok,<<>>,Data};

fixed_length_decode(Field,Fixed,Len,Data)->
	Full = Len div Fixed,
	FiledBits = Field * 8,
	{Packets,RemainData} = fixed_length_decode_full(FiledBits,Fixed,Full,Data,[]),
	Buff = lists:foldr(
		fun(E,Acc)->
			<<Acc/bits,E/bits>>
		end,<<>>,Packets),
	{ok,Buff,RemainData}.

fixed_length_decode_full(_FiledBits,_Fixed,0,Data,Acc)->
	{Acc,Data};
fixed_length_decode_full(FiledBits,Fixed,Full,Data,Acc)->
	<<Payload:Fixed/binary,Rest/bits>> = Data,
	<<PayloadSize:FiledBits/little-integer,PayloadData/bits>> = Payload,
	PayloadDataSize  = erlang:byte_size(PayloadData),
	RelPayload = if 
			PayloadSize < PayloadDataSize ->
				<<Rel:PayloadSize/binary,_/bits>> = PayloadData,
				Rel;
			true ->
				PayloadData
			end,
	fixed_length_decode_full(FiledBits,Fixed,Full-1,Rest,[RelPayload|Acc]).
