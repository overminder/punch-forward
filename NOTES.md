# Protocol

## Design

It's mostly TCP but without many things. The basic idea is the three-step
communication. A packet is a four-tuple `(seqNo, ackNo, flags, payload)`.

### Handshake

1. Client sends `(C, -1, SYN, null)` where `C` is a randomly generated
   number.
2. Server responds with `(S, C, ACK|SYN, null)` where S is another randomly
   generated number.
3. Client responds with `(C+1, S, ACK, null)`.

### Data exchange

1. Sender sends `(S, -1, 0, data)` where S is the sender's next
   sequence number.
2. Receiver responds with `(R, S, ACK|ECHO, null)` where R is the receiver's
   next sequence number. Note this is different from TCP in the sense that
   the data is not echoed back for integrity checking. Rather, we rely
   on the UDP checksum. (XXX: is the UDP checksum reliable?)
3. Sender responds with `(S', R, ACK, null)` where S' is the sender's
   next sequence number.

### Termination

Hmm...

## Implementation

The current implementation definitely needs not to be optimized for
performance. It uses `Map` to record packets and `STM` to handle concurrency.

