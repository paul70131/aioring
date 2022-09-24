cdef extern from "fcntl.h":
    cdef int AT_FDCWD "AT_FDCWD"
    

cdef extern from "sys/stat.h":

    cdef int AT_EMPTY_PATH "AT_EMPTY_PATH"

    cdef struct statx_timestamp:
        long tv_sec
        int tv_nsec

    cdef struct statx:
        unsigned int stx_mask
        unsigned int stx_blksize
        unsigned long stx_attributes
        unsigned int stx_nlink
        unsigned int stx_uid
        unsigned int stx_gid
        unsigned short stx_mode
        unsigned long stx_ino
        unsigned long stx_size
        unsigned long stx_blocks
        unsigned long stx_attributes_mask

        statx_timestamp stx_atime
        statx_timestamp stx_btime
        statx_timestamp stx_ctime
        statx_timestamp stx_mtime

        unsigned int stx_rdev_major
        unsigned int stx_rdev_minor

        unsigned long stx_dev_major
        unsigned long stx_dev_minor
        unsigned long stx_mnt_id