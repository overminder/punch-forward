# Protocol

## Design

It's mostly TCP but without many things. The basic idea is the three-step
communication. A packet is a four-tuple `(seqNo, ackNo, flags, payload)`.

### Handshake

1. Client sends `(C, -1, SYN, null)` where `C` is a randomly generated
   number. It will resend this packet until the packet in (2) is received.
2. Server responds with `(S, C, ACK|SYN, null)` where S is another randomly
   generated number. It will resend this packet until the packet in (3)
   is received.
3. Client responds with `(-1, S, ACK, null)`. It will send this packet
   everytime the packet in (2) is received.

### Data exchange

The packet resending is done in the same way as in the handshake section
above.

1. Sender sends `(S, -1, 0, data)` where S is the sender's next
   sequence number.
2. Receiver responds with `(R, S, ACK|ECHO, null)` where R is the receiver's
   next sequence number. Note this is different from TCP in the sense that
   the data is not echoed back for integrity checking. Rather, we rely
   on the UDP checksum. (XXX: is the UDP checksum reliable?)
3. Sender responds with `(-1, R, ACK, null)`.

### Termination

Hmm...

## Implementation

The current implementation definitely needs not to be optimized for
performance. It uses `Map` to record packets and `STM` to handle concurrency.

