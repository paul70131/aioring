cdef class IoRingCqe:
    cpdef object get_data(self):
        raise NotImplementedError()

    cpdef int get_res(self):
        raise NotImplementedError()


cdef class IoRing:
    cpdef object get_event(self):
        raise NotImplementedError()

    cpdef list get_completions(self):
        raise NotImplementedError()

    cpdef int cancel_sqe(self, object user_data):
        raise NotImplementedError()

    cpdef int submit(self) except -1:
        raise NotImplementedError()

    cpdef void close(self)  except *:
        raise NotImplementedError()


    cpdef bytes schedule_read(self, object user_data, int fd, int count, unsigned long offset):
        raise NotImplementedError()

    cpdef int schedule_write(self, object user_data, int fd, bytes buf, int count, unsigned long offset) except -1:
        raise NotImplementedError()

    cpdef object schedule_stat(self, object user_data, int dfd, bytes path):
        raise NotImplementedError()

    cpdef int schedule_open(self, object user_data, char* path, int dirfd, int flags, int mode) except -1:
        raise NotImplementedError()

class RingFullError(Exception):
    pass

class OperationNotSupportedError(Exception):
    pass

class RingClosedError(Exception):
    pass
