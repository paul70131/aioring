cdef class IoRingCqe:
    cpdef object get_data(self)
    cpdef int get_res(self)

cdef class IoRing:
    cpdef object get_event(self)
    cpdef list get_completions(self)
    cpdef int cancel_sqe(self, object user_data)
    cpdef int submit(self) except -1
    cpdef void close(self) except *

    cpdef bytes schedule_read(self, object user_data, int fd, int count, unsigned long offset)
    cpdef int schedule_write(self, object user_data, int fd, bytes buf, int count, unsigned long offset) except -1
    cpdef object schedule_stat(self, object user_data, int dfd, bytes path)
    cpdef int schedule_open(self, object user_data, char* path, int dirfd, int flags, int mode) except -1