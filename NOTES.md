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

XXX: I just found that according to Wikipedia, a 0.1% drop rate would be
tolerable, and anything above that will affect the connection quality
significantly. Huh..

Sending and echoing 100 packets (sequentially, where the next data segment
is not sent before the echo reply is received) using 1 ms, 5 ms and 50 ms
as the maximum delays, and 0.1% as the packet drop rates:

    $ time ./TestProtocol 1000 0.001
    real    0m0.837s
    user    0m0.058s
    sys     0m0.056s
    
    $ time ./TestProtocol 5000 0.001
    real    0m2.146s
    user    0m0.090s
    sys     0m0.092s
    
    $ time ./TestProtocol 50000 0.001
    real    0m12.032s
    user    0m0.146s
    sys     0m0.164s

This implies that the average roundtrip time will usually be 8ms, 20ms
and 120ms respectively.

If we send all the packets before starting to wait, the time will be:

    $ time ./TestProtocol 1000 0.001 100
    real    0m0.283s
    user    0m0.010s
    sys     0m0.010s
    
    $ time ./TestProtocol 50000 0.001 100
    real    0m0.412s
    user    0m0.032s
    sys     0m0.027s
    
    $ time ./TestProtocol 500000 0.001 100
    real    0m0.718s
    user    0m0.026s
    sys     0m0.023s

And for throughoutput, the time used in sending in 100k packets under
1ms latency and 0.1% drop rate:

$ time ./TestProtocol 1000 0.001 100000
real    0m2.854s
user    0m2.763s
sys     0m0.069s

That's 40MB/s in one direction.

