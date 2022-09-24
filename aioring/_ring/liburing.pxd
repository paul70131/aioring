cdef extern from "liburing.h":

    cdef struct io_uring_sqe:
        unsigned int user_data
    
    cdef struct io_uring_cqe:
        unsigned long user_data
        int res
        unsigned int flags

    cdef struct io_uring_sq:
        pass
    
    cdef struct io_uring_cq:
        pass

    cdef struct io_uring:
        pass

    cdef enum io_uring_op:
        pass

    cdef int io_uring_queue_init(
        unsigned int entries,
        io_uring *ring,
        unsigned int flags
    )

    cdef int io_uring_queue_exit(
        io_uring *ring
    )

    cdef int io_uring_submit(
        io_uring *ring
    )

    cdef void io_uring_cqe_seen(
        io_uring *ring,
        io_uring_cqe *cqe
    )

    cdef int io_uring_peek_cqe(
        io_uring *ring,
        io_uring_cqe **cqe
    )

    cdef io_uring_sqe* io_uring_get_sqe(
        io_uring *ring
    )

    cdef int io_uring_register_eventfd(
        io_uring *ring,
        int fd
    )

    cdef void io_uring_sqe_set_data(
        io_uring_sqe *sqe,
        void* data
    )

    cdef void io_uring_prep_nop(
        io_uring_sqe *sqe
    )

    cdef void io_uring_prep_read(
        io_uring_sqe *sqe,
        int fd,
        void *buf,
        unsigned int nbytes,
        unsigned int offset
    )

    cdef void io_uring_prep_write(
        io_uring_sqe *sqe,
        int fd,
        void *buf,
        unsigned int nbytes,
        unsigned int offset
    )

    cdef void io_uring_prep_cancel(
        io_uring_sqe *sqe,
        void* user_data,
        int flags
    )

    cdef void io_uring_prep_statx(
        io_uring_sqe *sqe,
        int dfd,
        char* path,
        int flags, 
        unsigned int mask,
        void* statx
    )

    cdef void io_uring_prep_openat(
        io_uring_sqe *sqe,
        int dfd,
        char* path,
        int flags,
        int mode
    )