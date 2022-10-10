from aioring.ring cimport IoRingCqe, IoRing
from aioring.ring import RingFullError, RingClosedError

from aioring._ring.linux cimport AT_FDCWD, statx, statx_timestamp, AT_EMPTY_PATH

from aioring._ring.liburing cimport io_uring, io_uring_cqe, io_uring_sqe
from aioring._ring.liburing cimport io_uring_queue_init, io_uring_queue_exit, io_uring_register_eventfd, io_uring_peek_cqe, io_uring_submit, io_uring_get_sqe, io_uring_sqe_set_data, io_uring_cqe_seen
from aioring._ring.liburing cimport io_uring_prep_read, io_uring_prep_write, io_uring_prep_statx, io_uring_prep_openat, io_uring_prep_cancel

import os
import warnings

cdef class stat_result:
    cdef statx buf

    cdef statx_timestamp_to_float(self, statx_timestamp t):
        return (t.tv_sec + t.tv_nsec / 1e9)

    @property
    def st_mode(self):
        return self.buf.stx_mode
    
    @property
    def st_ino(self):
        return self.buf.stx_ino
    
    @property
    def st_dev(self):
        return os.makedev(self.buf.stx_dev_major, self.buf.stx_dev_minor)

    @property
    def st_nlink(self):
        return self.buf.stx_nlink

    @property
    def st_uid(self):
        return self.buf.stx_uid
    
    @property
    def st_gid(self):
        return self.buf.stx_gid
    
    @property
    def st_size(self):
        return self.buf.stx_size
    
    @property
    def st_atime(self):
        return self.statx_timestamp_to_float(self.buf.stx_atime)

    @property
    def st_mtime(self):
        return self.statx_timestamp_to_float(self.buf.stx_mtime)

    @property
    def st_ctime(self):
        return self.statx_timestamp_to_float(self.buf.stx_ctime)
    
    @property
    def st_atime_ns(self):
        return self.buf.stx_atime.tv_nsec

    @property
    def st_mtime_ns(self):
        return self.buf.stx_mtime.tv_nsec
    
    @property
    def st_ctime_ns(self):
        return self.buf.stx_ctime.tv_nsec
    
    @property
    def st_blocks(self):
        return self.buf.stx_blocks
    
    @property
    def st_blksize(self):
        return self.buf.stx_blksize

    @property
    def st_rdev(self):
        return os.makedev(self.buf.stx_rdev_major, self.buf.stx_rdev_minor)

    @property
    def st_flags(self):
        return self.buf.stx_flags
    


cdef class _IoUringCqe(IoRingCqe):
    cdef object data
    cdef int res

    def __init__(self, data, res):
        self.data = data
        self.res = res

    cpdef object get_data(self):
        return self.data

    cpdef int get_res(self):
        return self.res

cdef class IoUringEvent:
    cdef public int fd

    def __init__(self):
        self.fd = os.eventfd(0)

    cpdef void wait(self):
        os.eventfd_read(self.fd)
        
    cpdef void clear(self):
        self.wait()

    cpdef void close(self):
        os.close(self.fd)


cdef class IoUring(IoRing):
    cdef io_uring ring
    cdef bint closed

    def __init__(self, entries=256):
        cdef int res = io_uring_queue_init(entries, &self.ring, 0)
        if res < 0:
            raise OSError(-res, os.strerror(-res))
        self.event = None
        self.closed = False

    cpdef object get_event(self):
        cdef int res
        if self.event is None:
            self.event = IoUringEvent()
            res = io_uring_register_eventfd(&self.ring, self.event.fd)
            if res < 0:
                raise OSError(-res, os.strerror(-res))
        return self.event

    cpdef list get_completions(self):
        cdef list results = []
        cdef io_uring_cqe *cqe = NULL
        cdef int res = 0
        if self.closed:
            raise RingClosedError()

        res = io_uring_peek_cqe(&self.ring, &cqe)
        while res == 0:
            results.append(_IoUringCqe(
                <object><void*>cqe.user_data,
                cqe.res
            ))
            io_uring_cqe_seen(&self.ring, cqe)
            res = io_uring_peek_cqe(&self.ring, &cqe)
        return results

    #cpdef int cancel_sqe(self, object user_data)
    cpdef int submit(self) except -1:
        cdef int res = io_uring_submit(&self.ring)
        if res < 0:
            raise OSError(-res, os.strerror(-res))
        return res

    cpdef void close(self) except *:
        if self.closed:
            warnings.warn("IoUring already closed", ResourceWarning)
            return
        io_uring_queue_exit(&self.ring)
        if self.event is not None:
            self.event.close()
            self.event = None
        self.closed = True

    def __del__(self):
        if not self.closed:
            warnings.warn("IoUring not closed", ResourceWarning)
            self.close()

    cpdef bytes schedule_read(self, object user_data, int fd, int count, unsigned long offset):
        cdef bytes buf  = bytes(count)
        cdef io_uring_sqe* sqe = io_uring_get_sqe(&self.ring)
        if sqe == NULL:
            raise RingFullError()
        io_uring_prep_read(sqe, fd, <char*>buf, count, offset)
        io_uring_sqe_set_data(sqe, <void*>user_data)
        return buf

    cpdef int schedule_write(self, object user_data, int fd, bytes buf, int count, unsigned long offset) except -1:
        cdef io_uring_sqe* sqe = io_uring_get_sqe(&self.ring)
        if sqe == NULL:
            raise RingFullError()
        io_uring_prep_write(sqe, fd, <char*>buf, count, offset)
        io_uring_sqe_set_data(sqe, <void*>user_data)

    cpdef object schedule_stat(self, object user_data, int dfd, bytes path):
        cdef stat_result buf = stat_result()
        cdef io_uring_sqe* sqe = io_uring_get_sqe(&self.ring)
        cdef int flags = 0
        if dfd == 0:
            dfd = -100
        if len(path) == 0:
            flags |= AT_EMPTY_PATH
        if sqe == NULL:
            raise RingFullError()
        io_uring_prep_statx(sqe, dfd, <char*>path, flags, 0, <void*>&buf.buf)
        io_uring_sqe_set_data(sqe, <void*>user_data)
        return buf
        
            
    cpdef int schedule_open(self, object user_data, char* path, int dirfd, int flags, int mode) except -1:
        cdef io_uring_sqe* sqe = io_uring_get_sqe(&self.ring)
        if sqe == NULL:
            raise RingFullError()
        if dirfd == 0:
            dirfd = -100
        io_uring_prep_openat(sqe, dirfd, path, flags, mode)
        io_uring_sqe_set_data(sqe, <void*>user_data)

    cpdef int schedule_cancel(self, object target) except -1:
        cdef io_uring_sqe* sqe = io_uring_get_sqe(&self.ring)
        if sqe == NULL:
            raise RingFullError()
        io_uring_prep_cancel(sqe, <void*>target, 0)
        io_uring_sqe_set_data(sqe, <void*>None)
