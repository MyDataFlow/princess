-module(utp_protocol).

-include("utp_packet.hrl").
-export([encode/3,decode/1,make_connection_id/0,validate/1]).
%-record(packet_ver_one_header,{
%    type,
%    version,
%    extension,
%    connection_id,
%    timestamp_ms,
%    timestamp_df_ms,
%    wnd_size,
%    seq_nr,
%    ack_nr
%  }).

make_connection_id() ->
    <<N:16/integer>> = crypto:rand_bytes(2),
    N.

validate(#packet_ver_one_header{ 
        seq_nr = SeqNo,
        ack_nr = AckNo } = _Header) ->
    case (0 =< SeqNo andalso SeqNo =< 65535)
         andalso
         (0 =< AckNo andalso AckNo =< 65535) of
        true ->
            true;
        false ->
            false
    end.

encode(Header,ExtList,Payload)->
    try
        {Extension,ExtPayload} = encode_body(ExtList,Payload),
        NewHeader = Header#packet_ver_one_header{extension = Extension},
        HeaderBin = encode_header(NewHeader),
        {ok,<<HeaderBin/binary,ExtPayload/binary>>}
    catch
        _:Reason ->
            {error, Reason}
    end.

encode_header(#packet_ver_one_header{ 
        type = Type,
        version = Version,
        extension = Extension,
		connection_id = ConnetionID,
        timestamp_ms = TimeStamp,
        timestamp_df_ms = TimeStampDiff,
        wnd_size = WinSize,
        seq_nr = SeqNo,
        ack_nr = AckNo} = _Header) ->

    <<Type:4/big-integer,Version:4/big-integer, 
        Extension:8/big-integer, ConnetionID:16/big-integer,
        TimeStamp:32/big-integer,
        TimeStampDiff:32/big-integer,
        WinSize:32/big-integer,
        SeqNo:16/big-integer, AckNo:16/big-integer>>.

encode_body(ExtList,Payload)->
    {Extension,ExtPayload} = encode_extensions(ExtList),
    {Extension,<<ExtPayload/binary,Payload/binary>>}.

encode_extensions([]) ->
    {0, <<>>};
encode_extensions([{?UTP_PACKET_EXT_SACK, Bits} | R]) ->
    {Next, Bin} = encode_extensions(R),
    Sz = erlang:byte_size(Bits),
    {?UTP_PACKET_EXT_SACK, <<Next:8/big-integer, Sz:8/big-integer, Bits/binary, Bin/binary>>};
encode_extensions([{?UTP_PACKET_EXT_BITS, Bits} | R]) ->
    {Next, Bin} = encode_extensions(R),
    Sz = erlang:byte_size(Bits),
    {?UTP_PACKET_EXT_BITS, <<Next:8/big-integer, Sz:8/big-integer, Bits/binary, Bin/binary>>}.

decode(Packet) ->
    try
        {Header,ExtPayload} = decode_header(Packet),
        {Extensions,Payload} = decode_body(Header#packet_ver_one_header.extension,ExtPayload),
        {ok, {Header,Extensions,Payload}}
    catch
        _:Reason ->
            {error, Reason}
    end.

decode_header(Packet) ->
    <<Type:4/big-integer,Version:4/big-integer, 
        Extension:8/big-integer, ConnetionID:16/big-integer,
        TimeStamp:32/big-integer,
        TimeStampDiff:32/big-integer,
        WinSize:32/big-integer,
        SeqNo:16/big-integer, AckNo:16/big-integer,
        Payload/binary>> = Packet,

    Header = #packet_ver_one_header{ 
        type = Type,
        version = Version,
        extension = Extension,
        connection_id = ConnetionID,
        timestamp_ms = TimeStamp,
        timestamp_df_ms = TimeStampDiff,
        wnd_size = WinSize,
        seq_nr = SeqNo,
        ack_nr = AckNo},
    {Header,Payload}.

decode_body(Extension,ExtPayload)->
    decode_extensions(Extension, ExtPayload, []).

decode_extensions(0, Payload, Exts) ->
    {lists:reverse(Exts), Payload};
decode_extensions(?UTP_PACKET_EXT_SACK, 
    <<Next:8/big-integer,Len:8/big-integer, R/bits>>, Acc) ->
    <<Bits:Len/binary, Rest/bits>> = R,
    decode_extensions(Next, Rest, [{?UTP_PACKET_EXT_SACK, Bits} | Acc]);
decode_extensions(?UTP_PACKET_EXT_BITS, 
    <<Next:8/big-integer,Len:8/big-integer, R/binary>>, Acc) ->
    <<ExtBits:Len/binary, Rest/binary>> = R,
    decode_extensions(Next, Rest, [{?UTP_PACKET_EXT_BITS, ExtBits} | Acc]).



