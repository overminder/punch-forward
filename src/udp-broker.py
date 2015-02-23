#!/usr/bin/env python

# This runs on ihome

import socket
import struct
from threading import Thread
import time

def decode_addr(xs):
    (host_s, port_s) = xs.split(':')
    host_bs = struct.pack('<I', eval(host_s))
    return (socket.inet_ntoa(host_bs), eval(port_s))

def encode_addr((host, port)):
    host_bs = socket.inet_aton(host)
    (host_num,) = struct.unpack('<I', host_bs)
    return '%d:%d' % (host_num, port)

def run_loop(s):
    print 'run loop started'
    clients = {}
    while True:
        (xs, pub_addr) = s.recvfrom(512)
        print (xs, pub_addr)
        (ty, cid, _, priv_addr) = eval(xs)
        pkt = (ty, cid, encode_addr(pub_addr), priv_addr)
        mb_pending = clients.get(cid)
        if not mb_pending:
            print 'No pending, go next'
            clients[cid] = pkt
            continue

        (pend_ty, _, pend_pub_addr, pend_priv_addr) = mb_pending
        if (pend_ty == 'Connect' and ty == 'Listen') or \
            (pend_ty == 'Listen' and ty == 'Connect'):

            del clients[cid]

            print 'Send: %s -> %s' % (pkt, decode_addr(pend_pub_addr))
            s.sendto(encode_pkt(pkt), decode_addr(pend_pub_addr))
            print 'Send: %s -> %s' % (mb_pending, pub_addr)
            s.sendto(encode_pkt(mb_pending), pub_addr)
            continue

        clients[cid] = pkt

def encode_pkt(x):
    return repr(x).replace("'", '"')

def main():
    port = 10005

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('', port))
    run_loop(s)

main()
