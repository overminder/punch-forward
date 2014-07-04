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

### Diagram

A input packet queue.

    [Packet flag]
    0b000
        ^ -- Received and ack-echo sent (0/1)
       ^ -- Delivered (0/2)
      ^ -- Acked (0/4)

In the current implementation, packets are delivered only after their
ACKs have been received. This can be implemented easily but will introduce
high latency.

Only two input queues are managed in the current implementation. One (`inQ`)
is used to store all of the received DATA packets. Once an ACK has been
received for a DATA packet, the packet will be moved from `inQ` to
`deliveryQ` and waits for delivery.

    [Current]
     -  Seq No  + 
    77771150111101
       ^ Last delivered.
        ^ First non-acked. (Can also be 0 -- i.e. not received)

A new implement aims to reduce the latency by delivery DATA packets before
their ACKS are received.

`inQ` should still be maintained. However, it's now totally separated from
the `deliveryQ`. When a new DATA packet is received, it's put into both
queues. `inQ` maintains the ACK state while `deliveryQ` maintains the
delivery state.

    [Delivery Before ACK]
     -  Seq No  + 
    77773051051101
        ^ Last delivered. (Can also be 0 -- i.e. not received. though
                           that will cause the last delivery to be its
                           predecessor.)
         ^ First non-received
          ^ First acked

## Implementation

The current implementation definitely needs not to be optimized for
performance. It uses `Map` to record packets and `STM` to handle concurrency.

### Performance (as of 3 July)

On July 3 a fast-delivery patch was applied, which greatly improved
the latency.

Sending and echoing 100 packets (sequentially, where the next data segment
is not sent before the echo reply is received) using 1 ms, 5 ms and 50 ms
as the maximum delays, and 0.1% as the packet drop rates:

    $ time ./TestProtocol 1000 0.001
    real    0m0.389s
    user    0m0.076s
    sys     0m0.036s
    
    $ time ./TestProtocol 5000 0.001
    real    0m1.625s
    user    0m0.133s
    sys     0m0.071s
    
    $ time ./TestProtocol 50000 0.001
    real    0m5.723s
    user    0m0.221s
    sys     0m0.142s

This implies that the average roundtrip time will usually be 4ms, 16ms
and 57ms respectively.

If we send all the packets before starting to wait, the time will be:
XXX: Since grace termination (FIN) is not implemented, the result below
should not be treated seriously.

    $ time ./TestProtocol 1000 0.001 100
    real    0m0.030s
    user    0m0.022s
    sys     0m0.007s
    
    $ time ./TestProtocol 50000 0.001 100
    real    0m0.163s
    user    0m0.032s
    sys     0m0.027s
    
    $ time ./TestProtocol 500000 0.001 100
    real    0m0.318s
    user    0m0.026s
    sys     0m0.023s

And for throughoutput, the time used in sending in 100k packets under
1ms latency and 0.1% drop rate:

$ time ./TestProtocol 1000 0.001 100000
^C^C^C^C^C

And previously the non-fast-delivery version used 2s. This is caused by
larger memory consumption. We might need to add congestion control
(e.g. through windowing) here.

