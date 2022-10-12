from aioring.ring import IoRing
from aioring import DefaultRing

import threading
import warnings
import types
import os

def loop_close(loop):
    if hasattr(loop, '_aioring'):
        loop._aioring.close()
    loop._org_close()


cdef class IoRingAsyncioPlugin:
#    cdef public object ring
#    cdef bint close_ring_on_exit
#    cdef public object loop
#    cdef bint closed

    def __init__(self, loop, *args):
        self.loop = loop
        self.closed = False
        setattr(self.loop, '_aioring', self)
        if len(args) > 0 and isinstance(args[0], IoRing):
            self.ring = args[0]
            self.close_ring_on_exit = False
        else:
            self.ring = DefaultRing(*args)
            self.close_ring_on_exit = True

        loop._org_close = types.MethodType(type(loop).close, loop)
        loop.close = types.MethodType(loop_close, loop)

    def on_ring_events(self):
        cdef list cqes
        self.ring.event.clear()
        try:
            cqes = self.ring.get_completions()
        except:
            return
        # this has to be called in the loop thread
        for cqe in cqes:
            future = cqe.get_data()
            if not future:
                continue
            if future.cancelled():
                continue
            if cqe.get_res() < 0:
                future.set_exception(OSError(-cqe.get_res(), os.strerror(-cqe.get_res())))
            else:
                future.set_result(cqe.get_res())
    
    cpdef int close(self) except -1:
        if self.close_ring_on_exit:
            self.ring.close()
        self.closed = True

    def _future_done_db(self, future):
        if future.cancelled():
            self.ring.schedule_cancel(future)
            self.ring.submit()



    cpdef object create_future(self):
        cdef object future = self.loop.create_future()
        future.add_done_callback(self._future_done_db)
        return future

    def __del__(self):
        if not self.closed:
            self.close()
            warnings.warn("unclosed IoRingAsyncioPlugin", ResourceWarning)
        ##self.close() TODO: close if not closed already

cdef class ReaderAsyncioPlugin(IoRingAsyncioPlugin):
    
    def __init__(self, *args):
        super().__init__(*args)
        self.loop.add_reader(self.ring.get_event().fd, self.on_ring_events)

cdef unsigned int MAX_UINT32 = 0xffffffff

cdef class WaitingThreadAsyncioPlugin(IoRingAsyncioPlugin):
    cdef object thread
    cdef object event
    cdef bint closing
        
    def __init__(self, *args):
        super().__init__(*args)
        self._start_reader_thread()

    cdef _start_reader_thread(self):
        self.thread = threading.Thread(target=self.thread_run)
        self.thread.start()
    
    def thread_run(self):
        self.event = self.ring.get_event()
        while not self.closing:
            self.event.wait()
            self.loop.call_soon_threadsafe(self.on_ring_events)
        
    cpdef int close(self) except -1:
        IoRingAsyncioPlugin.close(self)
        self.closing = True
        self.event.set()
        self.thread.join()

def create_plugin(loop, *args):
    try:
        plugin = ReaderAsyncioPlugin(loop, *args)
    except Exception as e:
        plugin = WaitingThreadAsyncioPlugin(loop, *args)
    return plugin