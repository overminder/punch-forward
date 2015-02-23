import os
import json
from datetime import datetime

import tornado.ioloop
import tornado.web

# This runs on heroku

# listeners :: Map (v_addr :: str) (lastAccessDate :: datetime, [F])
# type F = (client_addr :: (host :: str, port :: int))
#       -> (server_addr :: (host :: str, port :: int))
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

class Reflect(tornado.web.RequestHandler):
    def get(self):
        self.write({
            'ip': self.request.remote_ip
        })

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

        server_port = json.loads(self.request.body)['port']
        server_ip = self.request.remote_ip
        def f((host, port)):
            reactor.remove_timeout(cancel_key)
            self.write_and_finish(addr_response(host, port))
            return (server_ip, server_port)
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
        client_port = json.loads(self.request.body)['port']
        client_ip = self.request.remote_ip
        server_addr = f((client_ip, client_port))
        self.write(addr_response(*server_addr))

routes = [
    (r'/', Index),
    (r'/list/', List),
    (r'/reflect/', Reflect),
    (r'/bindListen/(.*)', Bind),
    (r'/accept/(.*)', Accept),
    (r'/connect/(.*)', Connect),
]

if __name__ == '__main__':
    app = tornado.web.Application(routes)
    app.listen(int(os.environ.get('PORT', 5000)), xheaders=True)
    reactor.start()

