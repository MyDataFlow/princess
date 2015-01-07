%enum {
%	ST_DATA = 0,		// Data packet.
%	ST_FIN = 1,			// Finalize the connection. This is the last packet.
%	ST_STATE = 2,		// State packet. Used to transmit an ACK with no data.
%	ST_RESET = 3,		// Terminate connection forcefully.
%	ST_SYN = 4,			// Connect SYN
%	ST_NUM_STATES,		// used for bounds checking
%};
-define(UTP_PACKET_ST_DATA,0).
-define(UTP_PACKET_ST_FIN,1).
-define(UTP_PACKET_ST_STATE,2).
-define(UTP_PACKET_ST_RESET,3).
-define(UTP_PACKET_ST_SYN,4).

-define(UTP_PACKET_EXT_SACK, 1).
-define(UTP_PACKET_EXT_BITS,2).

-define(UTP_PACKET_VERSION,1).
-define(UTP_PACKET_HEADR_SIZE,20).

%struct PACKED_ATTRIBUTE PacketFormatV1 {
%	// packet_type (4 high bits)
%	// protocol version (4 low bits)
%	byte ver_type;
%	byte version() const { return ver_type & 0xf; }
%	byte type() const { return ver_type >> 4; }
%	void set_version(byte v) { ver_type = (ver_type & 0xf0) | (v & 0xf); }
%	void set_type(byte t) { ver_type = (ver_type & 0xf) | (t << 4); }
%
%	// Type of the first extension header
%	byte ext;
%	// connection ID
%	uint16_big connid;
%	uint32_big tv_usec;
%	uint32_big reply_micro;
%	// receive window size in bytes
%	uint32_big windowsize;
%	// Sequence number
%	uint16_big seq_nr;
%	// Acknowledgment number
%	uint16_big ack_nr;
%};


%version 1 header:
%
%0       4       8               16              24              32
%+-------+-------+---------------+---------------+---------------+
%| type  | ver   | extension     | connection_id                 |
%+-------+-------+---------------+---------------+---------------+
%| timestamp_microseconds                                        |
%+---------------+---------------+---------------+---------------+
%| timestamp_difference_microseconds                             |
%+---------------+---------------+---------------+---------------+
%| wnd_size                                                      |
%+---------------+---------------+---------------+---------------+
%| seq_nr                        | ack_nr                        |
%+---------------+---------------+---------------+---------------+
%All fields are in network byte order (big endian).
%
%version
%
%This is the protocol version. The current version is 1.
%
%connection_id
%
%This is a random, unique, number identifying all the packets that belong to the same 
%connection. Each socket has one connection ID for sending packets and a different 
%connection ID for receiving packets. The endpoint initiating the connection decides
% which ID to use, and the return path has the same ID + 1.
%
%timestamp_microseconds
%
%This is the 'microseconds' parts of the timestamp of when this packet was sent.
% This is set using gettimeofday() on posix and QueryPerformanceTimer() on windows.
% The higher resolution this timestamp has, the better. 
%The closer to the actual transmit time it is set, the better.
%
%timestamp_difference_microseconds
%
%This is the difference between the local time and the timestamp in the last received packet,
% at the time the last packet was received. 
%This is the latest one-way delay measurement of the link from 
%the remote peer to the local machine.
%
%When a socket is newly opened and doesn't have any delay samples yet,
% this must be set to 0.
%
%wnd_size
%
%Advertised receive window. This is 32 bits wide and specified in bytes.
%
%The window size is the number of bytes currently in-flight, 
%i.e. sent but not acked. The advertised receive window lets the other end cap 
%the window size if it cannot receive any faster, if its receive buffer is filling up.
%
%When sending packets, this should be set to the number of bytes l
%eft in the socket's receive buffer.
%
%extension
%
%The type of the first extension in a linked list of extension headers.
% 0 means no extension.
%
%There is currently one extension:
%
%Selective acks
%Extensions are linked, just like TCP options. If the extension field is non-zero, 
%immediately following the uTP header are two bytes:
%
%0               8               16
%+---------------+---------------+
%| extension     | len           |
%+---------------+---------------+
%where extension specifies the type of the next extension in the linked list, 
%0 terminates the list. And len specifies the number of bytes of this extension. 
%Unknown extensions can be skipped by simply advancing len bytes.
%
%SELECTIVE ACK
%
%Selective ACK is an extension that can selectively ACK packets non-sequentially. 
%Its payload is a bitmask of at least 32 bits, in multiples of 32 bits. 
%Each bit represents one packet in the send window. Bits that are outside of the 
%send window are ignored. A set bit specifies that packet has been received, 
%a cleared bit specifies that the packet has not been received. 
%The header looks like this:
%
%0               8               16
%+---------------+---------------+---------------+---------------+
%| extension     | len           | bitmask
%+---------------+---------------+---------------+---------------+
%                                |
%+---------------+---------------+
%Note that the len field of extensions refer to bytes, 
%which in this extension must be at least 4, and in multiples of 4.
%
%The selective ACK is only sent when at least one sequence number was skipped in
% the received stream. 
%The first bit in the mask therefore represents ack_nr + 2. 
%ack_nr + 1 is assumed to have been dropped or be missing when this packet was sent.
% A set bit represents a packet that has been received, 
%a cleared bit represents a packet that has not yet been received.
%
%The bitmask has reverse byte order. 
%The first byte represents packets [ack_nr + 2, ack_nr + 2 + 7] in reverse order.
% The least significant bit in the byte represents ack_nr + 2, 
%the most significant bit in the byte represents ack_nr + 2 + 7. 
%The next byte in the mask represents [ack_nr + 2 + 8, ack_nr + 2 + 15] in reverse order,
% and so on. The bitmask is not limited to 32 bits but can be of any size.
%
%Here is the layout of a bitmask representing 
%the first 32 packet acks represented in a selective ACK bitfield:
%
%0               8               16
%+---------------+---------------+---------------+---------------+
%| 9 8 ...   3 2 | 17   ...   10 | 25   ...   18 | 33   ...   26 |
%+---------------+---------------+---------------+---------------+
%The number in the diagram maps the bit in the bitmask to the offset to 
%add to ack_nr in order to calculate the sequence number that the bit is ACKing.
%
%type
%
%The type field describes the type of packet.
%
%It can be one of:
%
%ST_DATA = 0
%regular data packet. Socket is in connected state and has data to send.
% An ST_DATA packet always has a data payload.
%ST_FIN = 1
%Finalize the connection. This is the last packet. 
%It closes the connection, similar to TCP FIN flag. 
%This connection will never have a sequence number greater than the sequence number 
%in this packet. The socket records this sequence number as eof_pkt. 
%This lets the socket wait for packets that might still be missing and 
%arrive out of order even after receiving the ST_FIN packet.
%ST_STATE = 2
%State packet. Used to transmit an ACK with no data.
% Packets that don't include any payload do not increase the seq_nr.
%ST_RESET = 3
%Terminate connection forcefully. Similar to TCP RST flag. 
%The remote host does not have any state for this connection. 
%It is stale and should be terminated.
%ST_SYN = 4
%Connect SYN. Similar to TCP SYN flag, this packet initiates a connection. 
%The sequence number is initialized to 1. The connection ID is initialized to a 
%random number. The syn packet is special, all subsequent packets sent on this 
%connection (except for re-sends of the ST_SYN) are sent with the connection ID + 1.
% The connection ID is what the other end is expected to use in its responses.
%
%When receiving an ST_SYN, the new socket should be initialized with the ID in the packet 
%header. The send ID for the socket should be initialized to the ID + 1. 
%The sequence number for the return channel is initialized to a random number. 
%The other end expects an ST_STATE packet (only an ACK) in response.

%seq_nr

%This is the sequence number of this packet. As opposed to TCP,
% uTP sequence numbers are not referring to bytes, but packets. 
%The sequence number tells the other end in which order packets
% should be served back to the application layer.

%ack_nr

%This is the sequence number the sender of the packet last received in the other direction.
-record(packet_ver_one_header,{
		type,
		version,
		extension,
		connection_id,
		timestamp_ms,
		timestamp_df_ms,
		wnd_size,
		seq_nr,
		ack_nr
	}).

%struct PACKED_ATTRIBUTE PacketFormatAckV1 {
%	PacketFormatV1 pf;
%	byte ext_next;
%	byte ext_len;
%	byte acks[4];
%};
-record(packet_ver_one_ack,{
		ver_one_header,
		next_extension,
		extension_len,
		acks
	}).