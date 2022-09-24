from aioring.ring cimport IoRing


cdef class IoRingAsyncioPlugin:
    cdef public object ring
    cdef public object loop 
    cdef bint close_ring_on_exit
    cdef bint closed

    cpdef int close(self) except -1
    cpdef object create_future(self)

