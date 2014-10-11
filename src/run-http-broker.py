import os
import json
from datetime import datetime

import tornado.ioloop
import tornado.web

listeners = {}

reactor = tornado.ioloop.IOLoop.instance()

def error_response(name):
    return {
        'type': 'error',
        'reason': {
            'code': name
        }
    }

def addr_response(host, port):
    return {
        'type': 'okAddr',
        'addr': {
            'host': host,
            'port': port
        }
    }

class Index(tornado.web.RequestHandler):
    def get(self):
        self.write('<h1>Too simple, sometimes naive!</h1>')

class List(tornado.web.RequestHandler):
    def get(self):
        self.write({k: str(t) for (k, (t, _)) in listeners.iteritems()})

class Bind(tornado.web.RequestHandler):
    def post(self, v_addr):
        listener = listeners.get(v_addr)
        if listener:
            self.write(error_response('AddrInUse'))
        else:
            listeners[v_addr] = (datetime.now(), [])
            self.write({
                'type': 'ok'
            })

class Accept(tornado.web.RequestHandler):
    def write_and_finish(self, wat):
        self.write(wat)
        self.finish()

    @tornado.web.asynchronous
    def post(self, v_addr):
        listener = listeners.get(v_addr)
        if not listener:
            return self.write_and_finish(error_response('NotBound'))

        (_, mb_f) = listener
        # Set last modified date
        listeners[v_addr] = (datetime.now(), mb_f)

        if mb_f:
            return self.write_and_finish(error_response('AlreadyAccepting'))

        my_addr = json.loads(self.request.body)
        def f((host, port)):
            reactor.remove_timeout(cancel_key)
            self.write_and_finish(addr_response(host, port))
            return my_addr
        mb_f.append(f)

        def on_timeup():
            mb_f.pop()
            self.write_and_finish(error_response('Timeout'))
        cancel_key = reactor.call_later(15, on_timeup)

class Connect(tornado.web.RequestHandler):
    def post(self, v_addr):
        listener = listeners.get(v_addr)
        if not listener:
            return self.write(error_response('NotBound'))

        (_, mb_f) = listener
        if not mb_f:
            return self.write(error_response('NoAcceptor'))

        f = mb_f.pop()
        my_addr = json.loads(self.request.body)
        (host, port) = f(my_addr)
        self.write(addr_response(host, port))

routes = [
    (r'/', Index),
    (r'/list/', List),
    (r'/bindListen/(.*)', Bind),
    (r'/accept/(.*)', Accept),
    (r'/connect/(.*)', Connect),
]

if __name__ == '__main__':
    app = tornado.web.Application(routes)
    app.listen(int(os.environ.get('PORT', 5000)))
    reactor.start()

