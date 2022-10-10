from aioring.ring cimport IoRingCqe, IoRing
from aioring.ring import RingFullError, RingClosedError

from functools import partial
from concurrent.futures import ThreadPoolExecutor

import os
import errno
import warnings
import threading

cdef class stat_result:
    cdef object _st_mode
    cdef object _st_ino
    cdef object _st_dev
    cdef object _st_nlink
    cdef object _st_uid
    cdef object _st_gid
    cdef object _st_size
    cdef object _st_atime
    cdef object _st_mtime
    cdef object _st_ctime
    cdef object _st_atime_ns
    cdef object _st_mtime_ns
    cdef object _st_ctime_ns
    cdef object _st_blocks
    cdef object _st_rdev

    def set_data(self, stat):
        if hasattr(stat, 'st_mode'):
            self._st_mode = stat.st_mode
        if hasattr(stat, 'st_ino'):
            self._st_ino = stat.st_ino
        if hasattr(stat, 'st_dev'):
            self._st_dev = stat.st_dev
        if hasattr(stat, 'st_nlink'):
            self._st_nlink = stat.st_nlink
        if hasattr(stat, 'st_uid'):
            self._st_uid = stat.st_uid
        if hasattr(stat, 'st_gid'):
            self._st_gid = stat.st_gid
        if hasattr(stat, 'st_size'):
            self._st_size = stat.st_size
        if hasattr(stat, 'st_atime'):
            self._st_atime = stat.st_atime
        if hasattr(stat, 'st_mtime'):
            self._st_mtime = stat.st_mtime
        if hasattr(stat, 'st_ctime'):
            self._st_ctime = stat.st_ctime
        if hasattr(stat, 'st_atime_ns'):
            self._st_atime_ns = stat.st_atime_ns
        if hasattr(stat, 'st_mtime_ns'):    
            self._st_mtime_ns = stat.st_mtime_ns
        if hasattr(stat, 'st_ctime_ns'):
            self._st_ctime_ns = stat.st_ctime_ns
        if hasattr(stat, 'st_blocks'):
            self._st_blocks = stat.st_blocks
        if hasattr(stat, 'st_rdev'):
            self._st_rdev = stat.st_rdev

    @property
    def st_mode(self):
        return self._st_mode
    
    @property
    def st_ino(self):
        return self._st_ino

    @property
    def st_dev(self):
        return self._st_dev

    @property
    def st_nlink(self):
        return self._st_nlink
    
    @property
    def st_uid(self):
        return self._st_uid
    
    @property
    def st_gid(self):
        return self._st_gid

    @property
    def st_size(self):
        return self._st_size
    
    @property
    def st_atime(self):
        return self._st_atime

    @property
    def st_mtime(self):
        return self._st_mtime

    @property
    def st_ctime(self):
        return self._st_ctime

    @property
    def st_atime_ns(self):
        return self._st_atime_ns

    @property
    def st_mtime_ns(self):
        return self._st_mtime_ns

    @property
    def st_ctime_ns(self):
        return self._st_ctime_ns

    @property
    def st_blocks(self):
        return self._st_blocks

    @property
    def st_rdev(self):
        return self._st_rdev



cdef class _IoRingCqe(IoRingCqe):
    cdef long res
    cdef object user_data

    def __init__(self, long res, object user_data):
        self.res = res
        self.user_data = user_data

    cpdef object get_data(self):
        return self.user_data

    cpdef int get_res(self):
        return self.res

cdef class _IoRingSqe:
    cdef object user_data
    cdef object func
    cdef object future

    def __init__(self, user_data, func):
        self.user_data = user_data
        self.func = func

    cpdef object get_data(self):
        return self.user_data

cdef _copy_to_bytes_obj(bytes target, bytes source, long size):
    cdef char* target_ptr = <char*>target
    cdef char* source_ptr = <char*>source
    cdef long i = 0
    while i < size:
        target_ptr[i] = source_ptr[i]
        i += 1

read_locks = {}
def _readinto(fd, buf, count, offset):
    try:
        if hasattr(os, "pread"):
            data = os.pread(fd, count, offset)
        else:
            # TODO: implement pread for non IoUring properly.
            # this solution leaks locks
            lock = read_locks.get(fd)
            if lock is None:
                lock = threading.Lock()
                read_locks[fd] = lock
            with lock:
                pos = os.lseek(fd, offset, os.SEEK_SET)
                data = os.read(fd, count)

        _copy_to_bytes_obj(buf, data, len(data))
        return len(data)
    except OSError as e:
        return -e.errno

def _writeinto(fd, buf, count, offset):
    try:
        if hasattr(os, "pwrite"):
            return os.pwrite(fd, buf, offset)
        else:
            # TODO: implement pwrite for non IoUring properly.
            # this solution leaks locks
            lock = read_locks.get(fd)
            if lock is None:
                lock = threading.Lock()
                read_locks[fd] = lock
            with lock:
                pos = os.lseek(fd, offset, os.SEEK_SET)
                return os.write(fd, buf)
    except OSError as e:
        return -e.errno

def _statx(path, fd, obj):
    try:
        if not path:
            obj.set_data(os.fstat(fd))
        else:
            if fd != 0:
                obj.set_data(os.stat(os.fsdecode(path), dir_fd=fd))
            else:
                obj.set_data(os.stat(os.fsdecode(path)))
        return 0
    except OSError as e:
        return -e.errno

def _open(pathname, dirfd, flags, mode):
    try:
        if not dirfd:
            return os.open(os.fsdecode(pathname), flags, mode=mode)
        else:
            return os.open(os.fsdecode(pathname), flags, dir_fd=dirfd, mode=mode)
    except OSError as e:
        return -e.errno


cdef class ThreadPoolIoRing(IoRing):
    cdef int entries
    cdef list scheduled_ops
    cdef list completed_tasks
    cdef object thread_pool_executor
    cdef bint closed

    def __init__(self, entries=256):
        self._setup_ring(entries)
        self.event = None
        self.completed_tasks = []
        self.scheduled_ops = []
        self.closed = False

    cdef void _setup_ring(self, entries) except *:
        self.thread_pool_executor = ThreadPoolExecutor(max_workers=32)
        self.entries = entries

    cpdef object get_event(self):
        if self.event is None:
            self.event = threading.Event()
        return self.event

    cpdef list get_completions(self):
        if self.closed:
            raise RingClosedError()

        cdef list completions = self.completed_tasks
        self.completed_tasks = []
        return completions

    cpdef int submit(self) except -1:
        for sqe in self.scheduled_ops:
            self._submit_to_executor(sqe)
        count = len(self.scheduled_ops)
        self.scheduled_ops = []
        return count
            
    cdef int _submit_to_executor(self, _IoRingSqe sqe) except -1:
        future = self.thread_pool_executor.submit(sqe.func)
        future.add_done_callback(partial(self._on_future_done, sqe))

    def _on_future_done(self, _IoRingSqe sqe, object future):
        if self.event is not None:
            self.event.set()
        self.completed_tasks.append(_IoRingCqe(
            future.result(),
            sqe.user_data
        ))
    
    cpdef void close(self) except *:
        if not self.closed:
            self.event = None
            self.thread_pool_executor.shutdown()
            self.closed = True

    def __del__(self):
        if not self.closed:
            warnings.warn("Unclosed ThreadPoolIoRing", ResourceWarning)
            self.close()
        
        

    cdef int _schedule(self, _IoRingSqe sqe) except -1:
        if len(self.scheduled_ops) >= self.entries:
            raise RingFullError()
        else:
            self.scheduled_ops.append(sqe)
            return 0

    cpdef bytes schedule_read(self, object user_data, int fd, int count, unsigned long offset):
        cdef bytes buf = bytes(count)
        self._schedule(
            _IoRingSqe(
                user_data, 
                partial(_readinto, fd, buf, count, offset)
            )
        )
        return buf

    cpdef int schedule_write(self, object user_data, int fd, bytes buf, int count, unsigned long offset) except -1:
        return self._schedule(
            _IoRingSqe(
                user_data, 
                partial(_writeinto, fd, buf, count, offset)
            )
        )

    cpdef object schedule_stat(self, object user_data, int dfd, bytes path):
        cdef object result = stat_result()
        self._schedule(
            _IoRingSqe(
                user_data, 
                partial(_statx, path, dfd, result)
            )
        )
        return result

    cpdef int schedule_open(self, object user_data, char* path, int dirfd, int flags, int mode) except -1:
        return self._schedule(
            _IoRingSqe(
                user_data, 
                partial(_open, path, dirfd, flags, mode)
            )
        )

    cpdef int schedule_cancel(self, object sqe) except -1:
        for op in self.scheduled_ops:
            if op.get_data() == sqe:
                self.scheduled_ops.remove(op)
                self.completed_tasks.append(_IoRingCqe(
                    -125, #ECANCELLED,
                    sqe
                ))
