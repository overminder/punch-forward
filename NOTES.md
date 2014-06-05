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

### Performance (as of 5 June)

Sending and echoing 100 packets using 1 ms, 2 ms and 5 ms as the maximum
delays, and 1%, 2% and 5% as the packet drop rates.

    $ time ./TestProtocol 1000 0.01
    real    0m1.579s
    user    0m0.071s
    sys     0m0.069s

    $ time ./TestProtocol 2000 0.02
    real    0m2.389s
    user    0m0.077s
    sys     0m0.076s

    $ time ./TestProtocol 5000 0.05
    real    0m4.500s
    user    0m0.097s
    sys     0m0.102s

This seems to be not usable -- Even when the network condition is pretty
good (1 ms delay with 1% drop rate), the maximum bandwidth can only
reach `480 * 100 / 1.579 = 30398 bytes/second`.

Batch sending ("window" in TCP term) needs to be implemented.

