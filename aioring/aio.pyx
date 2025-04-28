import os
import io
import abc
import sys
import stat
import errno
import codecs
import asyncio

from aioring import aos

# open() uses st_blksize whenever we can
DEFAULT_BUFFER_SIZE = 8 * 1024  # bytes


# Does io.IOBase finalizer log the exception if the close() method fails?
# The exception is ignored silently by default in release build.
_IOBASE_EMITS_UNRAISABLE = (hasattr(sys, "gettotalrefcount") or sys.flags.dev_mode)
# Does open() check its 'errors' argument?
_CHECK_ERRORS = _IOBASE_EMITS_UNRAISABLE


def text_encoding(encoding, stacklevel=2):
    """
    A helper function to choose the text encoding.

    When encoding is not None, this function returns it.
    Otherwise, this function returns the default text encoding
    (i.e. "locale" or "utf-8" depends on UTF-8 mode).

    This function emits an EncodingWarning if *encoding* is None and
    sys.flags.warn_default_encoding is true.

    This can be used in APIs with an encoding=None parameter
    that pass it to TextIOWrapper or open.
    However, please consider using encoding="utf-8" for new APIs.
    """
    if encoding is None:
        if sys.flags.utf8_mode:
            encoding = "utf-8"
        else:
            encoding = "locale"
        if sys.flags.warn_default_encoding:
            import warnings
            warnings.warn("'encoding' argument not specified.",
                          EncodingWarning, stacklevel + 1)
    return encoding


# Wrapper for builtins.open
#
# Trick so that open() won't become a bound method when stored
# as a class variable (as dbm.dumb does).
#
# See init_set_builtins_open() in Python/pylifecycle.c.
@staticmethod
async def open(file, mode="r", buffering=-1, encoding=None, errors=None,
         newline=None, closefd=True, opener=None):

    if not isinstance(file, int):
        file = os.fspath(file)
    if not isinstance(file, (str, bytes, int)):
        raise TypeError("invalid file: %r" % file)
    if not isinstance(mode, str):
        raise TypeError("invalid mode: %r" % mode)
    if not isinstance(buffering, int):
        raise TypeError("invalid buffering: %r" % buffering)
    if encoding is not None and not isinstance(encoding, str):
        raise TypeError("invalid encoding: %r" % encoding)
    if errors is not None and not isinstance(errors, str):
        raise TypeError("invalid errors: %r" % errors)
    modes = set(mode)
    if modes - set("axrwb+t") or len(mode) > len(modes):
        raise ValueError("invalid mode: %r" % mode)
    creating = "x" in modes
    reading = "r" in modes
    writing = "w" in modes
    appending = "a" in modes
    updating = "+" in modes
    text = "t" in modes
    binary = "b" in modes
    if text and binary:
        raise ValueError("can't have text and binary mode at once")
    if creating + reading + writing + appending > 1:
        raise ValueError("can't have read/write/append mode at once")
    if not (creating or reading or writing or appending):
        raise ValueError("must have exactly one of read/write/append mode")
    if binary and encoding is not None:
        raise ValueError("binary mode doesn't take an encoding argument")
    if binary and errors is not None:
        raise ValueError("binary mode doesn't take an errors argument")
    if binary and newline is not None:
        raise ValueError("binary mode doesn't take a newline argument")
    if binary and buffering == 1:
        import warnings
        warnings.warn("line buffering (buffering=1) isn't supported in binary "
                      "mode, the default buffer size will be used",
                      RuntimeWarning, 2)
    mode = (creating and "x" or "") + (reading and "r" or "") + (writing and "w" or "") + (appending and "a" or "") + (updating and "+" or "")
    raw = await AsyncFileIO._open(file, mode, closefd, opener=opener)
    result = raw
    try:
        line_buffering = False
        #if buffering == 1 or buffering < 0 and raw.isatty(): ttys are not supported
        #    buffering = -1
        #    line_buffering = True
        if buffering < 0:
            buffering = DEFAULT_BUFFER_SIZE
            try:
                bs = (await aos.fstat(raw.fileno())).st_blksize
            except (OSError, AttributeError):
                pass
            else:
                if bs > 1:
                    buffering = bs
        if buffering < 0:
            raise ValueError("invalid buffering size")
        if buffering == 0:
            if binary:
                return result
            raise ValueError("can't have unbuffered text I/O")
        if updating:
            buffer = AsyncBufferedRandom(raw, buffering)
        elif creating or writing or appending:
            buffer = AsyncBufferedWriter(raw, buffering)
        elif reading:
            buffer = AsyncBufferedReader(raw, buffering)
        else:
            raise ValueError("unknown mode: %r" % mode)
        result = buffer
        if binary:
            return result
        encoding = text_encoding(encoding)
        text = AsyncTextIOWrapper(buffer, encoding, errors, newline, line_buffering)
        result = text
        text.mode = mode
        return result
    except:
        await raw.close()
        raise


# In normal operation, both `UnsupportedOperation`s should be bound to the
# same object.
try:
    UnsupportedOperation = io.UnsupportedOperation
except AttributeError:
    class UnsupportedOperation(OSError, ValueError):
        pass

cdef long POS_NONE = 0xffffffffffffffff


cdef class AsyncIOBase:
    cdef bint _closed

    def __init__(self):
        self._closed = False

    cdef int _unsupported(self, str name) except -1:
        """Internal: raise an OSError exception for unsupported operations."""
        raise UnsupportedOperation("%s.%s() not supported" %
                                   (self.__class__.__name__, name))

    async def seek(self, long pos, int whence=0):
        self._unsupported("seek")

    async def tell(self):
        return await self.seek(0, 1)

    async def truncate(self, long pos=POS_NONE):
        self._unsupported("truncate")

    ### Flush and close ###

    async def flush(self):
        self._checkClosed()
        # XXX Should this return the number of bytes written???

    async def close(self):
        """Flush and close the IO object.

        This method has no effect if the file is already closed.
        """
        if not self._closed:
            try:
                await self.flush()
            finally:
                self._closed = True

    def __del__(self):
        """Destructor.  Calls close()."""
        try:
            closed = self.closed
        except AttributeError:
            # If getting closed fails, then the object is probably
            # in an unusable state, so ignore.
            return

        if closed:
            return

        if _IOBASE_EMITS_UNRAISABLE:
            self.close()
        else:
            # The try/except block is in case this is called at program
            # exit time, when it's possible that globals have already been
            # deleted, and then the close() call might fail.  Since
            # there's nothing we can do about such failures and they annoy
            # the end users, we suppress the traceback.
            try:
                os.close(self.fileno())
                self._closed = True
            except:
                pass

    ### Inquiries ###

    cpdef bint seekable(self):
        return False

    cdef int _checkSeekable(self, str msg=None) except -1:
        """Internal: raise UnsupportedOperation if file is not seekable
        """
        if not self.seekable():
            raise UnsupportedOperation("File or stream is not seekable."
                                       if msg is None else msg)

    cpdef bint readable(self):
        return False

    cdef int _checkReadable(self, str msg=None) except -1:
        if not self.readable():
            raise UnsupportedOperation("File or stream is not readable."
                                       if msg is None else msg)

    cpdef bint writable(self):
        return False

    cdef int _checkWritable(self, str msg=None) except -1:
        if not self.writable():
            raise UnsupportedOperation("File or stream is not writable."
                                       if msg is None else msg)

    @property
    def closed(self):
        return self._closed

    cdef int _checkClosed(self, str msg=None) except -1:
        if self._closed:
            raise ValueError("I/O operation on closed file."
                             if msg is None else msg)

    ### Context manager ###

    async def __aenter__(self):  # That's a forward reference
        """Context management protocol.  Returns self (an instance of IOBase)."""
        self._checkClosed()
        return self

    async def __aexit__(self, *args):
        """Context management protocol.  Calls close()"""
        await self.close()

    ### Lower-level APIs ###

    # XXX Should these be present even if unimplemented?

    cpdef int fileno(self) except -1:
        self._unsupported("fileno")

    cpdef bint isatty(self) except *:
        self._checkClosed()
        return False

    ### Readline[s] and writelines ###

    # TODO: Optimize this.
    async def readline(self, long size=-1):
        # For backwards compatibility, a (slowish) readline().
        if hasattr(self, "peek"):
            async def nreadahead():
                readahead = await self.peek(1)
                if not readahead:
                    return 1
                n = (readahead.find(b"\n") + 1) or len(readahead)
                if size >= 0:
                    n = min(n, size)
                return n
        else:
            async def nreadahead():
                return 1
        if size is None:
            size = -1
        else:
            try:
                size_index = size.__index__
            except AttributeError:
                raise TypeError(f"{size!r} is not an integer")
            else:
                size = size_index()
        res = bytearray()
        while size < 0 or len(res) < size:
            b = await self.read(await nreadahead())
            if not b:
                break
            res += b
            if res.endswith(b"\n"):
                break
        return bytes(res)

    def __aiter__(self):
        self._checkClosed()
        return self

    async def __anext__(self):
        line = await self.readline()
        if not line:
            raise StopAsyncIteration
        return line

    async def readlines(self, long hint=-1):
        n = 0
        lines = []
        async for line in self:
            lines.append(line)
            n += len(line)
            if n >= hint and hint > 0:
                break
        return lines

    async def writelines(self, list lines):
        self._checkClosed()
        for line in lines:
            await self.write(line)



cdef class AsyncRawIOBase(AsyncIOBase):


    async def read(self, long size=-1):
        if size < 0:
            return await self.readall()
        b = bytearray(size)
        n = await self.readinto(b)
        if n is None:
            return None
        del b[n:]
        return bytes(b)

    async def readall(self):
        """Read until EOF, using multiple read() call."""
        res = bytearray()
        while True:
            data = await self.read(DEFAULT_BUFFER_SIZE)
            if not data:
                break
            res += data
        if res:
            return bytes(res)
        else:
            # b'' or None
            return data

    async def readinto(self, bytearray b):
        self._unsupported("readinto")

    async def write(self, bytes b):
        self._unsupported("write")



cdef class AsyncBufferedIOBase(AsyncIOBase):

    async def read(self, long size=-1):
        self._unsupported("read")

    async def read1(self, long size=-1):
        self._unsupported("read1")

    async def readinto(self, bytearray b):
        return await self._readinto(b, read1=False)

    async def readinto1(self, bytearray b):
        return self._readinto(b, read1=True)

    async def _readinto(self, bytearray b, bint read1):
        if read1:
            data = await self.read1(len(b))
        else:
            data = await self.read(len(b))
        n = len(data)

        b[:n] = data

        return n

    async def write(self, b):
        self._unsupported("write")

    async def detach(self):
        self._unsupported("detach")



cdef class _AsyncBufferedIOMixin(AsyncBufferedIOBase):
    cdef AsyncIOBase _raw

    def __init__(self, raw):
        self._raw = raw

    ### Positioning ###

    async def seek(self, long pos, int whence=0):
        return await self.raw.seek(pos, whence)

    async def tell(self):
        return await self.raw.tell()

    async def truncate(self, long pos=POS_NONE):
        self._checkClosed()
        self._checkWritable()

        # Flush the stream.  We're mixing buffered I/O with lower-level I/O,
        # and a flush may be necessary to synch both views of the current
        # file state.
        await self.flush()

        if pos == POS_NONE:
            pos = await self.tell()
        return await self.raw.truncate(pos)

    async def flush(self):
        if self._closed:
            raise ValueError("flush on closed file")
        await self.raw.flush()

    async def close(self):
        if self.raw is not None and not self._closed:
            try:
                await self.flush()
            finally:
                await self.raw.close()

    async def detach(self):
        cdef AsyncIOBase raw
        if self.raw is None:
            raise ValueError("raw stream already detached")
        await self.flush()
        raw = self._raw
        self._raw = None
        return raw

    ### Inquiries ###

    cpdef bint seekable(self):
        return self.raw.seekable()

    @property
    def raw(self):
        return self._raw

    @property
    def closed(self):
        return self._raw.closed

    @property
    def name(self):
        return self._raw.name

    @property
    def mode(self):
        return self._raw.mode

    def __getstate__(self):
        raise TypeError(f"cannot pickle {self.__class__.__name__!r} object")

    def __repr__(self):
        modname = self.__class__.__module__
        clsname = self.__class__.__qualname__
        try:
            name = self.name
        except AttributeError:
            return "<{}.{}>".format(modname, clsname)
        else:
            return "<{}.{} name={!r}>".format(modname, clsname, name)

    ### Lower-level APIs ###

    cpdef int fileno(self) except -1:
        return self.raw.fileno()

    cpdef bint isatty(self) except *:
        return self.raw.isatty()



cdef class AsyncBufferedReader(_AsyncBufferedIOMixin):
    cdef object _read_lock
    cdef bytearray _read_buf
    cdef long _read_pos
    cdef unsigned long buffer_size

    def __init__(self, raw, buffer_size=DEFAULT_BUFFER_SIZE):
        """Create a new buffered reader using the given readable raw IO object.
        """
        if not raw.readable():
            raise OSError('"raw" argument must be readable.')

        _AsyncBufferedIOMixin.__init__(self, raw)
        if buffer_size <= 0:
            raise ValueError("invalid buffer size")
        self.buffer_size = buffer_size
        self._reset_read_buf()
        self._read_lock = asyncio.Lock()

    cpdef bint readable(self):
        return self.raw.readable()

    cdef void _reset_read_buf(self):
        self._read_buf = bytearray()
        self._read_pos = 0

    async def read(self, long size=-1):
        if size < -1:
            raise ValueError("invalid number of bytes to read")
        async with self._read_lock:
            return await self._read_unlocked(size)

    async def _read_unlocked(self, long n=-1) -> bytes:
        cdef bytes nodata_val = b""
        cdef tuple empty_values = (b"", None)
        cdef bytearray buf = self._read_buf
        cdef long pos = self._read_pos
        cdef bytes chunk
        cdef list chunks
        cdef long current_size
        cdef long avail
        cdef long wanted
        cdef bytearray out

        # Special case for when the number of bytes to read is unspecified.
        if n == -1:
            self._reset_read_buf()
            if hasattr(self.raw, 'readall'):
                chunk = await self.raw.readall()
                if chunk is None:
                    return bytes(buf[pos:]) or None
                else:
                    return bytes(buf[pos:] + chunk)
            chunks = [buf[pos:]]  # Strip the consumed bytes.
            current_size = 0
            while True:
                # Read until EOF or until read() would block.
                chunk = await self.raw.read()
                if chunk in empty_values:
                    nodata_val = chunk
                    break
                current_size += len(chunk)
                chunks.append(chunk)
            return b"".join(chunks) or nodata_val

        # The number of bytes to read is specified, return at most n bytes.
        avail = len(buf) - pos  # Length of the available buffered data.
        if n <= avail:
            # Fast path: the data to read is fully buffered.
            self._read_pos += n
            return bytes(buf[pos:pos+n])
        # Slow path: read from the stream until enough bytes are read,
        # or until an EOF occurs or until read() would block.
        chunks = [buf[pos:]]
        wanted = max(self.buffer_size, n)
        while avail < n:
            chunk = await self.raw.read(wanted)
            if chunk in empty_values:
                nodata_val = chunk
                break
            avail += len(chunk)
            chunks.append(chunk)
        # n is more than avail only when an EOF occurred or when
        # read() would have blocked.
        n = min(n, avail)
        out = bytearray().join(chunks)
        self._read_buf = out[n:]  # Save the extra data in the buffer.
        self._read_pos = 0
        return bytes(out[:n]) if out else nodata_val

    async def peek(self, long size=0):
        async with self._read_lock:
            return await self._peek_unlocked(size)

    async def _peek_unlocked(self, long n=0):
        cdef long want = min(n, self.buffer_size)
        cdef long have = len(self._read_buf) - self._read_pos
        cdef long to_read
        cdef bytes current
        if have < want or have <= 0:
            to_read = self.buffer_size - have
            current = await self.raw.read(to_read)
            if current:
                self._read_buf = self._read_buf[self._read_pos:] + current
                self._read_pos = 0
        return self._read_buf[self._read_pos:]

    async def read1(self, long size=-1):
        if size < 0:
            size = self.buffer_size
        if size == 0:
            return b""
        async with self._read_lock:
            await self._peek_unlocked(1)
            return await self._read_unlocked(
                min(size, len(self._read_buf) - self._read_pos))

    async def _readinto(self, bytearray buf, bint read1):
        cdef long written = 0
        cdef long size = len(buf)
        cdef long avail
        cdef long n

        if size == 0:
            return buf

        async with self._read_lock:
            while written < size:

                # First try to read from internal buffer
                avail = min(len(self._read_buf) - self._read_pos, size)
                if avail:
                    buf[written:written+avail] = \
                        self._read_buf[self._read_pos:self._read_pos+avail]
                    self._read_pos += avail
                    written += avail
                    if written == size:
                        break

                # If remaining space in callers buffer is larger than
                # internal buffer, read directly into callers buffer
                if size - written > self.buffer_size:
                    n = await self.raw.readinto(buf[written:])
                    if not n:
                        break # eof
                    written += n

                # Otherwise refill internal buffer - unless we're
                # in read1 mode and already got some data
                elif not (read1 and written):
                    if not await self._peek_unlocked(1):
                        break # eof

                # In readinto1 mode, return as soon as we have some data
                if read1 and written:
                    break

        return written

    async def tell(self):
        return (await _AsyncBufferedIOMixin.tell(self)) - len(self._read_buf) + self._read_pos

    async def seek(self, pos, long whence=0):
        async with self._read_lock:
            if whence == 1:
                pos -= len(self._read_buf) - self._read_pos
            pos = await _AsyncBufferedIOMixin.seek(self, pos, whence)
            self._reset_read_buf()
            return pos

cdef class AsyncBufferedWriter(_AsyncBufferedIOMixin):
    cdef long buffer_size
    cdef bytearray _write_buf
    cdef object _write_lock


    def __init__(self, raw, buffer_size=DEFAULT_BUFFER_SIZE):
        if not raw.writable():
            raise OSError('"raw" argument must be writable.')

        _AsyncBufferedIOMixin.__init__(self, raw)
        if buffer_size <= 0:
            raise ValueError("invalid buffer size")
        self.buffer_size = buffer_size
        self._write_buf = bytearray()
        self._write_lock = asyncio.Lock()

    cpdef bint writable(self):
        return self.raw.writable()

    async def write(self, object b):
        cdef long before
        cdef long written
        cdef long overage

        if isinstance(b, str):
            raise TypeError("can't write str to binary stream")
        async with self._write_lock:
            if self.closed:
                raise ValueError("write to closed file")
            # XXX we can implement some more tricks to try and avoid
            # partial writes
            if len(self._write_buf) > self.buffer_size:
                # We're full, so let's pre-flush the buffer.  (This may
                # raise BlockingIOError with characters_written == 0.)
                await self._flush_unlocked()
            before = len(self._write_buf)
            self._write_buf.extend(b)
            written = len(self._write_buf) - before
            if len(self._write_buf) > self.buffer_size:
                try:
                    await self._flush_unlocked()
                except BlockingIOError as e:
                    if len(self._write_buf) > self.buffer_size:
                        # We've hit the buffer_size. We have to accept a partial
                        # write and cut back our buffer.
                        overage = len(self._write_buf) - self.buffer_size
                        written -= overage
                        self._write_buf = self._write_buf[:self.buffer_size]
                        raise BlockingIOError(e.errno, e.strerror, written)
            return written

    async def truncate(self, long pos=-1):
        async with self._write_lock:
            await self._flush_unlocked()
            if pos is None:
                pos = await self.raw.tell()
            return await self.raw.truncate(pos)

    async def flush(self):
        async with self._write_lock:
            await self._flush_unlocked()

    async def _flush_unlocked(self):
        cdef long n

        if self.closed:
            raise ValueError("flush on closed file")
        while self._write_buf:
            n = await self.raw.write(self._write_buf)
            if n > len(self._write_buf) or n < 0:
                raise OSError("write() returned incorrect number of bytes")
            del self._write_buf[:n]

    async def tell(self):
        return await _AsyncBufferedIOMixin.tell(self) + len(self._write_buf)

    async def seek(self, long pos, int whence=0):
        async with self._write_lock:
            await self._flush_unlocked()
            return await _AsyncBufferedIOMixin.seek(self, pos, whence)

    async def close(self):
        async with self._write_lock:
            if self.raw is None or self.closed:
                return
        # We have to release the lock and call self.flush() (which will
        # probably just re-take the lock) in case flush has been overridden in
        # a subclass or the user set self.flush to something. This is the same
        # behavior as the C implementation.
        try:
            # may raise BlockingIOError or BrokenPipeError etc
            await self.flush()
        finally:
            async with self._write_lock:
                await self.raw.close()

# this is defined as a proxy class to either AsyncBufferedReader or AsyncBufferedWriter
cdef class AsyncBufferedRandom(_AsyncBufferedIOMixin):
    cdef AsyncBufferedReader _reader
    cdef AsyncBufferedWriter _writer



    def __init__(self, raw, buffer_size=DEFAULT_BUFFER_SIZE):
        _AsyncBufferedIOMixin.__init__(self, raw)
        self._reader = AsyncBufferedReader(raw, buffer_size)
        self._writer = AsyncBufferedWriter(raw, buffer_size)

    # 0 = _reader -> _writer
    # 1 = _writer -> _reader
    async def _sync_offset(self, int dir = 0):
        cdef offset = 0
        if dir == 0:
            offset = await self._reader.tell()
        elif dir == 1:
            offset = await self._writer.tell()
        await self._writer.seek(offset, os.SEEK_SET)
        await self._reader.seek(offset, os.SEEK_SET)

    async def close(self):
        try:
            await self._reader.flush()
        finally:
            await self._writer.close()

    async def flush(self):
        res = await self._writer.flush()
        await self._sync_offset(1)
        return res

    async def peek(self):
        res = await self._reader.peek()
        await self._sync_offset(0)
        return res

    async def read(self, long size=-1):
        data = await self._reader.read(size)
        await self._sync_offset(0)
        return data

    async def read1(self, long size=-1):
        data = await self._reader.read1(size)
        await self._sync_offset(0)
        return data

    cpdef bint readable(self):
        return self._reader.readable()

    async def readinto(self, bytearray b):
        res = await self._reader.readinto(b)
        await self._sync_offset(0)
        return res

    async def readinto1(self, bytearray b):
        res = await self._reader.readinto(b)
        await self._sync_offset(0)
        return res

    async def readline(self, long size=-1):
        line = await self._reader.readline(size)
        await self._sync_offset(0)
        return line

    async def readlines(self, long hint=-1):
        lines = await self._reader.readlines(hint)
        await self._sync_offset(0)
        return lines
    
    async def seek(self, long pos, int whence=0):
        await self._writer.seek(pos, whence)
        await self._sync_offset(1)

    cpdef bint seekable(self):
        return True

    async def tell(self):
        # should be the same for reader and writer
        return await self._writer.tell()

    async def truncate(self, long pos=-1):
        res = await self._writer.truncate(pos)
        await self._sync_offset(1)
        return res

    cpdef bint writeable(self):
        return self._writer.writeable()

    async def write(self, object b):
        res = await self._writer.write(b)
        await self._sync_offset(1)
        return res


    

cdef class AsyncFileIO(AsyncRawIOBase):
    cdef int _fd
    cdef public bint _created
    cdef public bint _readable
    cdef public bint _writable
    cdef public bint _appending
    cdef public bint _seekable
    cdef public bint _closefd
    cdef public long _offset
    cdef public long _blksize
    cdef public object name

    def __init__(self, fd, created, writeable, readable, appending, closefd, blksize, name, offset):
        self._fd = fd
        self._created = created
        self._readable = readable
        self._writable = writeable
        self._appending = appending
        self._closefd = closefd
        self._blksize = blksize
        self.name = name
        self._offset = offset


    @staticmethod
    async def _open(file, str mode='r', bint closefd=True, object opener=None):
        cdef bint _writeable = False
        cdef bint _created = False
        cdef bint _readable = False
        cdef bint _appending = False
        cdef int owned_fd = -1
        cdef int fd
        cdef int flags
        cdef int noinherit_flag = (getattr(os, 'O_NOINHERIT', 0) or getattr(os, 'O_CLOEXEC', 0))
        cdef long _blksize
        cdef object loop
        cdef object fdfstat

        if isinstance(file, float):
            raise TypeError('integer argument expected, got float')
        if isinstance(file, int):
            fd = file
            if fd < 0:
                raise ValueError('negative file descriptor')
        else:
            fd = -1

        if not isinstance(mode, str):
            raise TypeError('invalid mode: %s' % (mode,))
        if not set(mode) <= set('xrwab+'):
            raise ValueError('invalid mode: %s' % (mode,))
        if sum(c in 'rwax' for c in mode) != 1 or mode.count('+') > 1:
            raise ValueError('Must have exactly one of create/read/write/append '
                             'mode and at most one plus')

        if 'x' in mode:
            _created = True
            _writeable = True
            flags = os.O_EXCL | os.O_CREAT
        elif 'r' in mode:
            _readable = True
            flags = 0
        elif 'w' in mode:
            _writeable = True
            flags = os.O_CREAT | os.O_TRUNC
        elif 'a' in mode:
            _writeable = True
            _appending = True
            flags = os.O_APPEND | os.O_CREAT

        if '+' in mode:
            _readable = True
            _writeable = True

        if _readable and _writeable:
            flags |= os.O_RDWR
        elif _readable:
            flags |= os.O_RDONLY
        else:
            flags |= os.O_WRONLY

        flags |= getattr(os, 'O_BINARY', 0)
        flags |= noinherit_flag

        try:
            if fd < 0:
                if not closefd:
                    raise ValueError('Cannot use closefd=False with file name')
                if opener is None:
                    fd = await aos.open(file, flags, 0o666)
                else:
                    loop = asyncio.get_event_loop()
                    fd = await loop.run_in_executor(None, opener, file, flags)
                    if not isinstance(fd, int):
                        raise TypeError('expected integer from opener')
                    if fd < 0:
                        raise OSError('Negative file descriptor')
                owned_fd = fd
                if not noinherit_flag:
                    os.set_inheritable(fd, False)

            fdfstat = await aos.fstat(fd)
            try:
                if stat.S_ISDIR(fdfstat.st_mode):
                    raise IsADirectoryError(errno.EISDIR,
                                            os.strerror(errno.EISDIR), file)
            except AttributeError:
                # Ignore the AttributeError if stat.S_ISDIR or errno.EISDIR
                # don't exist.
                pass

            _blksize = getattr(fdfstat, 'st_blksize', 0)
            if _blksize <= 1:
                _blksize = DEFAULT_BUFFER_SIZE

            name = file
            offset = 0
            if _appending:
                offset = fdfstat.st_size

        except:
            if owned_fd != -1:
                await aos.close(owned_fd)
            raise
        return AsyncFileIO(
            fd, _created, _writeable,
            _readable, _appending, closefd,
            _blksize, name, offset)
        

    def __del__(self):
        if self._fd >= 0 and self._closefd and not self.closed:
            import warnings
            warnings.warn('unclosed file %r' % (self,), ResourceWarning,
                          stacklevel=2, source=self)
            os.close(self.fileno()) # since this needs to be sync

    def __getstate__(self):
        raise TypeError(f"cannot pickle {self.__class__.__name__!r} object")

    def __repr__(self):
        class_name = '%s.%s' % (self.__class__.__module__,
                                self.__class__.__qualname__)
        if self.closed:
            return '<%s [closed]>' % class_name
        try:
            name = self.name
        except AttributeError:
            return ('<%s fd=%d mode=%r closefd=%r>' %
                    (class_name, self._fd, self.mode, self._closefd))
        else:
            return ('<%s name=%r mode=%r closefd=%r>' %
                    (class_name, name, self.mode, self._closefd))

    cdef int _checkReadable(self, str msg=None) except -1:
        if not self._readable:
            raise UnsupportedOperation('File not open for reading')

    cdef int _checkWritable(self, str msg=None) except -1:
        if not self._writable:
            raise UnsupportedOperation('File not open for writing')

    async def read(self, long size=-1):
        cdef bytes buffer

        self._checkClosed()
        self._checkReadable()

        if size < 0:
            return await self.readall()
        try:
            buffer = await aos.pread(self._fd, size, self._offset)
            self._offset += len(buffer)
            return buffer

        except BlockingIOError:
            return None

    async def readall(self):
        cdef bytearray result = bytearray()
        cdef long pos
        cdef long bufsize
        cdef long n
        cdef long end
        cdef bytes chunk
        
        self._checkClosed()
        self._checkReadable()
        bufsize = DEFAULT_BUFFER_SIZE
        try:
            pos = self._offset
            end = (await aos.fstat(self._fd)).st_size
            if end >= pos:
                bufsize = end - pos + 1
        except OSError:
            pass

        while True:
            if len(result) >= bufsize:
                bufsize = len(result)
                bufsize += max(bufsize, DEFAULT_BUFFER_SIZE)
            n = bufsize - len(result)
            try:
                chunk = await aos.pread(self._fd, n, self._offset)
                self._offset += len(chunk)
            except BlockingIOError:
                if result:
                    break
                return None
            if not chunk: # reached the end of the file
                break
            result += chunk

        return bytes(result)

    async def readinto(self, bytearray b):
        cdef bytes data
        cdef long n

        data = await self.read(len(b))
        n = len(data)
        b[:n] = data
        return n

    async def write(self, object b):
        cdef long written

        self._checkClosed()
        self._checkWritable()
        try:
            written = await aos.pwrite(self._fd, bytes(b), self._offset)
            self._offset += written
            return written
        except BlockingIOError:
            return None

    async def seek(self, long pos, int whence=os.SEEK_SET):
        self._checkClosed()
        if whence == os.SEEK_SET:
            self._offset = pos
        elif whence == os.SEEK_CUR:
            self._offset += pos
        elif whence == os.SEEK_END:
            self._offset = (await aos.fstat(self._fd)).st_size + pos
        else:
            raise ValueError('Invalid value for whence')

    async def tell(self):
        return self._offset

    async def truncate(self, long size=-1):
        self._checkClosed()
        self._checkWritable()
        if size == -1:
            size = await self.tell()
        await aos.ftruncate(self._fd, size)
        return size

    async def close(self):
        if not self.closed:
            try:
                if self._closefd:
                    await aos.close(self._fd)
            finally:
                await super().close()
                self._closed = True

    cpdef bint seekable(self):
        return True

    cpdef bint readable(self):
        self._checkClosed()
        return self._readable

    cpdef bint writable(self):
        self._checkClosed()
        return self._writable

    cpdef int fileno(self) except -1:
        self._checkClosed()
        return self._fd

    cpdef bint isatty(self) except *:
        return False

    @property
    def closefd(self):
        return self._closefd

    @property
    def mode(self):
        if self._created:
            if self._readable:
                return 'xb+'
            else:
                return 'xb'
        elif self._appending:
            if self._readable:
                return 'ab+'
            else:
                return 'ab'
        elif self._readable:
            if self._writable:
                return 'rb+'
            else:
                return 'rb'
        else:
            return 'wb'


cdef class AsyncTextIOBase(AsyncIOBase):

    async def read(self, size=-1):
        self._unsupported("read")

    async def write(self, s):
        self._unsupported("write")

    async def truncate(self, pos=None):
        self._unsupported("truncate")

    async def readline(self):
        self._unsupported("readline")

    async def detach(self):
        self._unsupported("detach")

    @property
    def encoding(self):
        return None

    @property
    def newlines(self):
        return None

    @property
    def errors(self):
        return None


class IncrementalNewlineDecoder(codecs.IncrementalDecoder):
    r"""Codec used when reading a file in universal newlines mode.  It wraps
    another incremental decoder, translating \r\n and \r into \n.  It also
    records the types of newlines encountered.  When used with
    translate=False, it ensures that the newline sequence is returned in
    one piece.
    """
    def __init__(self, decoder, translate, errors='strict'):
        codecs.IncrementalDecoder.__init__(self, errors=errors)
        self.translate = translate
        self.decoder = decoder
        self.seennl = 0
        self.pendingcr = False

    def decode(self, input, final=False):
        # decode input (with the eventual \r from a previous pass)
        if self.decoder is None:
            output = input
        else:
            output = self.decoder.decode(input, final=final)
        if self.pendingcr and (output or final):
            output = "\r" + output
            self.pendingcr = False

        # retain last \r even when not translating data:
        # then readline() is sure to get \r\n in one pass
        if output.endswith("\r") and not final:
            output = output[:-1]
            self.pendingcr = True

        # Record which newlines are read
        crlf = output.count('\r\n')
        cr = output.count('\r') - crlf
        lf = output.count('\n') - crlf
        self.seennl |= (lf and self._LF) | (cr and self._CR) \
                    | (crlf and self._CRLF)

        if self.translate:
            if crlf:
                output = output.replace("\r\n", "\n")
            if cr:
                output = output.replace("\r", "\n")

        return output

    def getstate(self):
        if self.decoder is None:
            buf = b""
            flag = 0
        else:
            buf, flag = self.decoder.getstate()
        flag <<= 1
        if self.pendingcr:
            flag |= 1
        return buf, flag

    def setstate(self, state):
        buf, flag = state
        self.pendingcr = bool(flag & 1)
        if self.decoder is not None:
            self.decoder.setstate((buf, flag >> 1))

    def reset(self):
        self.seennl = 0
        self.pendingcr = False
        if self.decoder is not None:
            self.decoder.reset()

    _LF = 1
    _CR = 2
    _CRLF = 4

    @property
    def newlines(self):
        return (None,
                "\n",
                "\r",
                ("\r", "\n"),
                "\r\n",
                ("\n", "\r\n"),
                ("\r", "\r\n"),
                ("\r", "\n", "\r\n")
               )[self.seennl]


cdef class AsyncTextIOWrapper(AsyncTextIOBase):
    cdef object _buffer
    cdef object msg
    cdef str _decoded_chars
    cdef long _decoded_chars_used
    cdef object _snapshot
    cdef bint _has_read1
    cdef object _encoding
    cdef object _errors
    cdef object _encoder
    cdef object _decoder
    cdef double _b2cratio
    cdef bint _readuniversal
    cdef bint _readtranslate
    cdef object _readnl
    cdef bint _writetranslate
    cdef object _writenl
    cdef bint _line_buffering
    cdef bint _write_through
    cdef bint _seekable
    cdef bint _telling
    cdef public object mode

    _CHUNK_SIZE = 2048

    # The write_through argument has no effect here since this
    # implementation always writes through.  The argument is present only
    # so that the signature can match the signature of the C version.
    def __init__(self, object buffer, object encoding=None, object errors=None, object newline=None,
                 bint line_buffering=False, bint write_through=False):
        self._check_newline(newline)
        encoding = text_encoding(encoding)

        if encoding == "locale":
            encoding = self._get_locale_encoding()

        if not isinstance(encoding, str):
            raise ValueError("invalid encoding: %r" % encoding)

        if not codecs.lookup(encoding)._is_text_encoding:
            msg = ("%r is not a text encoding; "
                   "use codecs.open() to handle arbitrary codecs")
            raise LookupError(msg % encoding)

        if errors is None:
            errors = "strict"
        else:
            if not isinstance(errors, str):
                raise ValueError("invalid errors: %r" % errors)
            if _CHECK_ERRORS:
                codecs.lookup_error(errors)

        self._buffer = buffer
        self._decoded_chars = ''  # buffer for text returned from decoder
        self._decoded_chars_used = 0  # offset into _decoded_chars for read()
        self._snapshot = None  # info for reconstructing decoder state
        self._seekable = self._telling = self.buffer.seekable()
        self._has_read1 = hasattr(self.buffer, 'read1')
        self._configure(encoding, errors, newline,
                        line_buffering, write_through)

    def _check_newline(self, newline):
        if newline is not None and not isinstance(newline, str):
            raise TypeError("illegal newline type: %r" % (type(newline),))
        if newline not in (None, "", "\n", "\r", "\r\n"):
            raise ValueError("illegal newline value: %r" % (newline,))

    cdef _configure(self, object encoding=None, object errors=None, object newline=None,
                   bint line_buffering=False, bint write_through=False):
        cdef long position
                
        self._encoding = encoding
        self._errors = errors
        self._encoder = None
        self._decoder = None
        self._b2cratio = 0.0

        self._readuniversal = not newline
        self._readtranslate = newline is None
        self._readnl = newline
        self._writetranslate = newline != ''
        self._writenl = newline or os.linesep

        self._line_buffering = line_buffering
        self._write_through = write_through

        # don't write a BOM in the middle of a file
        if self._seekable and self.writable():
            position = self.buffer.raw._offset # cant use tell since its async but _offset is the same
            if position != 0:
                try:
                    self._get_encoder().setstate(0)
                except LookupError:
                    # Sometimes the encoder doesn't exist
                    pass

    # self._snapshot is either None, or a tuple (dec_flags, next_input)
    # where dec_flags is the second (integer) item of the decoder state
    # and next_input is the chunk of input bytes that comes next after the
    # snapshot point.  We use this to reconstruct decoder states in tell().

    # Naming convention:
    #   - "bytes_..." for integer variables that count input bytes
    #   - "chars_..." for integer variables that count decoded characters

    def __repr__(self):
        result = "<{}.{}".format(self.__class__.__module__,
                                 self.__class__.__qualname__)
        try:
            name = self.name
        except AttributeError:
            pass
        else:
            result += " name={0!r}".format(name)
        try:
            mode = self.mode
        except AttributeError:
            pass
        else:
            result += " mode={0!r}".format(mode)
        return result + " encoding={0!r}>".format(self.encoding)

    @property
    def encoding(self):
        return self._encoding

    @property
    def errors(self):
        return self._errors

    @property
    def line_buffering(self):
        return self._line_buffering

    @property
    def write_through(self):
        return self._write_through

    @property
    def buffer(self):
        return self._buffer

    async def reconfigure(self, *,
                    encoding=None, errors=None, newline=Ellipsis,
                    line_buffering=None, write_through=None):
        """Reconfigure the text stream with new parameters.

        This also flushes the stream.
        """
        if (self._decoder is not None
                and (encoding is not None or errors is not None
                     or newline is not Ellipsis)):
            raise UnsupportedOperation(
                "It is not possible to set the encoding or newline of stream "
                "after the first read")

        if errors is None:
            if encoding is None:
                errors = self._errors
            else:
                errors = 'strict'
        elif not isinstance(errors, str):
            raise TypeError("invalid errors: %r" % errors)

        if encoding is None:
            encoding = self._encoding
        else:
            if not isinstance(encoding, str):
                raise TypeError("invalid encoding: %r" % encoding)
            if encoding == "locale":
                encoding = self._get_locale_encoding()

        if newline is Ellipsis:
            newline = self._readnl
        self._check_newline(newline)

        if line_buffering is None:
            line_buffering = self.line_buffering
        if write_through is None:
            write_through = self.write_through

        await self.flush()
        self._configure(encoding, errors, newline,
                        line_buffering, write_through)

    cpdef bint seekable(self):
        if self.closed:
            return False
        return self._seekable

    cpdef bint readable(self):
        return self.buffer.readable()

    cpdef bint writable(self):
        return self.buffer.writable()

    async def flush(self):
        await self.buffer.flush()
        self._telling = self._seekable

    async def close(self):
        if self.buffer is not None and not self.closed:
            try:
                await self.flush()
            finally:
                await self.buffer.close()

    @property
    def closed(self):
        return self.buffer.closed

    @property
    def name(self):
        return self.buffer.name

    cpdef int fileno(self) except -1:
        return self.buffer.fileno()

    cpdef bint isatty(self) except *:
        return self.buffer.isatty()

    async def write(self, str s):
        cdef long length = len(s)
        cdef bint haslf = (self._writetranslate or self._line_buffering) and "\n" in s
        cdef object encoder
        cdef object b

        if self.closed:
            raise ValueError("write to closed file")

        
        if haslf and self._writetranslate and self._writenl != "\n":
            s = s.replace("\n", self._writenl)

        encoder = self._encoder or self._get_encoder()
        # XXX What if we were just reading?
        b = encoder.encode(s)
        await self.buffer.write(b)
        if self._line_buffering and (haslf or "\r" in s):
            await self.flush()
        self._set_decoded_chars('')
        self._snapshot = None
        if self._decoder:
            self._decoder.reset()
        return length

    cdef object _get_encoder(self):
        cdef object make_encoder = codecs.getincrementalencoder(self._encoding)
        self._encoder = make_encoder(self._errors)
        return self._encoder

    cdef object _get_decoder(self):
        cdef object make_decoder = codecs.getincrementaldecoder(self._encoding)
        cdef object decoder = make_decoder(self._errors)
        if self._readuniversal:
            decoder = IncrementalNewlineDecoder(decoder, self._readtranslate)
        self._decoder = decoder
        return decoder

    # The following three methods implement an ADT for _decoded_chars.
    # Text returned from the decoder is buffered here until the client
    # requests it by calling our read() or readline() method.
    cdef void _set_decoded_chars(self, str chars):
        self._decoded_chars = chars
        self._decoded_chars_used = 0

    cdef str _get_decoded_chars(self, long n=-1):
        cdef long offset = self._decoded_chars_used
        cdef str chars
        if n == -1:
            chars = self._decoded_chars[offset:]
        else:
            chars = self._decoded_chars[offset:offset + n]
        self._decoded_chars_used += len(chars)
        return chars

    cdef object _get_locale_encoding(self):
        cdef object encoding = None
        try:
            encoding = os.device_encoding(self.buffer.fileno()) or "locale"
        except (AttributeError, UnsupportedOperation):
            pass

        if not encoding:
            try:
                import locale
            except ImportError:
                # Importing locale may fail if Python is being built
                encoding = "utf-8"
            else:
                encoding = locale.getpreferredencoding(False)
        return encoding

    cdef int _rewind_decoded_chars(self, long n) except -1:
        if self._decoded_chars_used < n:
            raise AssertionError("rewind decoded_chars out of bounds")
        self._decoded_chars_used -= n

    async def _read_chunk(self):
        cdef object dec_buffer
        cdef object dec_flags
        cdef bytes input_chunk
        cdef bint eof
        cdef str decoded_chars

        if self._decoder is None:
            raise ValueError("no decoder")

        if self._telling:
            # To prepare for tell(), we need to snapshot a point in the
            # file where the decoder's input buffer is empty.

            dec_buffer, dec_flags = self._decoder.getstate()
            # Given this, we know there was a valid snapshot point
            # len(dec_buffer) bytes ago with decoder state (b'', dec_flags).

        # Read a chunk, decode it, and put the result in self._decoded_chars.
        if self._has_read1:
            input_chunk = await self.buffer.read1(self._CHUNK_SIZE)
        else:
            input_chunk = await self.buffer.read(self._CHUNK_SIZE)
        eof = not input_chunk
        decoded_chars = self._decoder.decode(input_chunk, eof)
        self._set_decoded_chars(decoded_chars)
        if decoded_chars:
            self._b2cratio = len(input_chunk) / len(self._decoded_chars)
        else:
            self._b2cratio = 0.0

        if self._telling:
            # At the snapshot point, len(dec_buffer) bytes before the read,
            # the next input to be decoded is dec_buffer + input_chunk.
            self._snapshot = (dec_flags, dec_buffer + input_chunk)

        return not eof

    cdef _pack_cookie(self, long position, long dec_flags=0,
                           long bytes_to_feed=0, bint need_eof=False, long chars_to_skip=0):
        # The meaning of a tell() cookie is: seek to position, set the
        # decoder flags to dec_flags, read bytes_to_feed bytes, feed them
        # into the decoder with need_eof as the EOF flag, then skip
        # chars_to_skip characters of the decoded result.  For most simple
        # decoders, tell() will often just give a byte offset in the file.
        return (position | (dec_flags<<64) | (bytes_to_feed<<128) |
               (chars_to_skip<<192) | bool(need_eof)<<256)

    cdef _unpack_cookie(self, bigint):
        rest, position = divmod(bigint, 1<<64)
        rest, dec_flags = divmod(rest, 1<<64)
        rest, bytes_to_feed = divmod(rest, 1<<64)
        need_eof, chars_to_skip = divmod(rest, 1<<64)
        return position, dec_flags, bytes_to_feed, bool(need_eof), chars_to_skip

    async def tell(self):
        cdef long position
        cdef int dec_flags
        cdef object next_input
        cdef long chars_to_skip
        cdef object saved_state
        cdef long skip_bytes
        cdef long skip_back
        cdef long n
        cdef object b
        cdef object d
        cdef long start_pos
        cdef int start_flags
        cdef long bytes_fed
        cdef bint need_eof
        cdef long chars_decoded

        if not self._telling:
            raise OSError("telling position disabled by next() call")
        await self.flush()
        position = await self.buffer.tell()
        decoder = self._decoder
        if decoder is None or self._snapshot is None:
            if self._decoded_chars:
                # This should never happen.
                raise AssertionError("pending decoded text")
            return position

        # Skip backward to the snapshot point (see _read_chunk).
        dec_flags, next_input = self._snapshot
        position -= len(next_input)

        # How many decoded characters have been used up since the snapshot?
        chars_to_skip = self._decoded_chars_used
        if chars_to_skip == 0:
            # We haven't moved from the snapshot point.
            return self._pack_cookie(position, dec_flags)

        # Starting from the snapshot position, we will walk the decoder
        # forward until it gives us enough decoded characters.
        saved_state = decoder.getstate()
        try:
            # Fast search for an acceptable start point, close to our
            # current pos.
            # Rationale: calling decoder.decode() has a large overhead
            # regardless of chunk size; we want the number of such calls to
            # be O(1) in most situations (common decoders, sensible input).
            # Actually, it will be exactly 1 for fixed-size codecs (all
            # 8-bit codecs, also UTF-16 and UTF-32).
            skip_bytes = int(self._b2cratio * chars_to_skip)
            skip_back = 1
            assert skip_bytes <= len(next_input)
            while skip_bytes > 0:
                decoder.setstate((b'', dec_flags))
                # Decode up to temptative start point
                n = len(decoder.decode(next_input[:skip_bytes]))
                if n <= chars_to_skip:
                    b, d = decoder.getstate()
                    if not b:
                        # Before pos and no bytes buffered in decoder => OK
                        dec_flags = d
                        chars_to_skip -= n
                        break
                    # Skip back by buffered amount and reset heuristic
                    skip_bytes -= len(b)
                    skip_back = 1
                else:
                    # We're too far ahead, skip back a bit
                    skip_bytes -= skip_back
                    skip_back = skip_back * 2
            else:
                skip_bytes = 0
                decoder.setstate((b'', dec_flags))

            # Note our initial start point.
            start_pos = position + skip_bytes
            start_flags = dec_flags
            if chars_to_skip == 0:
                # We haven't moved from the start point.
                return self._pack_cookie(start_pos, start_flags)

            # Feed the decoder one byte at a time.  As we go, note the
            # nearest "safe start point" before the current location
            # (a point where the decoder has nothing buffered, so seek()
            # can safely start from there and advance to this location).
            bytes_fed = 0
            need_eof = False
            # Chars decoded since `start_pos`
            chars_decoded = 0
            for i in range(skip_bytes, len(next_input)):
                bytes_fed += 1
                chars_decoded += len(decoder.decode(next_input[i:i+1]))
                dec_buffer, dec_flags = decoder.getstate()
                if not dec_buffer and chars_decoded <= chars_to_skip:
                    # Decoder buffer is empty, so this is a safe start point.
                    start_pos += bytes_fed
                    chars_to_skip -= chars_decoded
                    start_flags, bytes_fed, chars_decoded = dec_flags, 0, 0
                if chars_decoded >= chars_to_skip:
                    break
            else:
                # We didn't get enough decoded data; signal EOF to get more.
                chars_decoded += len(decoder.decode(b'', final=True))
                need_eof = True
                if chars_decoded < chars_to_skip:
                    raise OSError("can't reconstruct logical file position")

            # The returned cookie corresponds to the last safe start point.
            return self._pack_cookie(
                start_pos, start_flags, bytes_fed, need_eof, chars_to_skip)
        finally:
            decoder.setstate(saved_state)

    async def truncate(self, long pos=-1):
        await self.flush()
        if pos == -1:
            pos = self.tell()
        return await self.buffer.truncate(pos)

    async def detach(self):
        cdef object buffer
        if self.buffer is None:
            raise ValueError("buffer is already detached")
        await self.flush()
        buffer = self._buffer
        self._buffer = None
        return buffer

    async def seek(self, object cookie, int whence=0):
        def _reset_encoder(position):
            """Reset the encoder (merely useful for proper BOM handling)"""
            try:
                encoder = self._encoder or self._get_encoder()
            except LookupError:
                # Sometimes the encoder doesn't exist
                pass
            else:
                if position != 0:
                    encoder.setstate(0)
                else:
                    encoder.reset()

        if self.closed:
            raise ValueError("tell on closed file")
        if not self._seekable:
            raise UnsupportedOperation("underlying stream is not seekable")
        if whence == os.SEEK_CUR:
            if cookie != 0:
                raise UnsupportedOperation("can't do nonzero cur-relative seeks")
            # Seeking to the current position should attempt to
            # sync the underlying buffer with the current position.
            whence = 0
            cookie = await self.tell()
        elif whence == os.SEEK_END:
            if cookie != 0:
                raise UnsupportedOperation("can't do nonzero end-relative seeks")
            await self.flush()
            position = await self.buffer.seek(0, whence)
            self._set_decoded_chars('')
            self._snapshot = None
            if self._decoder:
                self._decoder.reset()
            _reset_encoder(position)
            return position
        if whence != 0:
            raise ValueError("unsupported whence (%r)" % (whence,))
        if cookie < 0:
            raise ValueError("negative seek position %r" % (cookie,))
        await self.flush()

        # The strategy of seek() is to go back to the safe start point
        # and replay the effect of read(chars_to_skip) from there.
        start_pos, dec_flags, bytes_to_feed, need_eof, chars_to_skip = \
            self._unpack_cookie(cookie)

        # Seek back to the safe start point.
        await self.buffer.seek(start_pos)
        self._set_decoded_chars('')
        self._snapshot = None

        # Restore the decoder to its state from the safe start point.
        if cookie == 0 and self._decoder:
            self._decoder.reset()
        elif self._decoder or dec_flags or chars_to_skip:
            self._decoder = self._decoder or self._get_decoder()
            self._decoder.setstate((b'', dec_flags))
            self._snapshot = (dec_flags, b'')

        if chars_to_skip:
            # Just like _read_chunk, feed the decoder and save a snapshot.
            input_chunk = self.buffer.read(bytes_to_feed)
            self._set_decoded_chars(
                self._decoder.decode(input_chunk, need_eof))
            self._snapshot = (dec_flags, input_chunk)

            # Skip chars_to_skip of the decoded characters.
            if len(self._decoded_chars) < chars_to_skip:
                raise OSError("can't restore logical file position")
            self._decoded_chars_used = chars_to_skip

        _reset_encoder(cookie)
        return cookie

    async def read(self, long size=-1):
        cdef object decoder
        cdef object result
        cdef bint eof = False

        self._checkReadable()

        decoder = self._decoder or self._get_decoder()
        if size < 0:
            # Read everything.
            result = (self._get_decoded_chars() +
                      decoder.decode(await self.buffer.read(), final=True))
            self._set_decoded_chars('')
            self._snapshot = None
            return result
        else:
            # Keep reading chunks until we have size characters to return.
            result = self._get_decoded_chars(size)
            while len(result) < size and not eof:
                eof = not await self._read_chunk()
                result += self._get_decoded_chars(size - len(result))
            return result

    async def __anext__(self):
        cdef object line
    
        self._telling = False
        line = await self.readline()
        if not line:
            self._snapshot = None
            self._telling = self._seekable
            raise StopAsyncIteration
        return line

    async def readline(self, size=None):
        cdef object line
        cdef long start = 0
        cdef long pos = -1
        cdef long endpos = -1
        cdef long nlpos
        cdef long crpos

        if self.closed:
            raise ValueError("read from closed file")
        if size is None:
            size = -1
        else:
            try:
                size_index = size.__index__
            except AttributeError:
                raise TypeError(f"{size!r} is not an integer")
            else:
                size = size_index()

        # Grab all the decoded text (we will rewind any extra bits later).
        line = self._get_decoded_chars()

        # Make the decoder if it doesn't already exist.
        if not self._decoder:
            self._get_decoder()

        pos = endpos = -1
        while True:
            if self._readtranslate:
                # Newlines are already translated, only search for \n
                pos = line.find('\n', start)
                if pos >= 0:
                    endpos = pos + 1
                    break
                else:
                    start = len(line)

            elif self._readuniversal:
                # Universal newline search. Find any of \r, \r\n, \n
                # The decoder ensures that \r\n are not split in two pieces

                # In C we'd look for these in parallel of course.
                nlpos = line.find("\n", start)
                crpos = line.find("\r", start)
                if crpos == -1:
                    if nlpos == -1:
                        # Nothing found
                        start = len(line)
                    else:
                        # Found \n
                        endpos = nlpos + 1
                        break
                elif nlpos == -1:
                    # Found lone \r
                    endpos = crpos + 1
                    break
                elif nlpos < crpos:
                    # Found \n
                    endpos = nlpos + 1
                    break
                elif nlpos == crpos + 1:
                    # Found \r\n
                    endpos = crpos + 2
                    break
                else:
                    # Found \r
                    endpos = crpos + 1
                    break
            else:
                # non-universal
                pos = line.find(self._readnl)
                if pos >= 0:
                    endpos = pos + len(self._readnl)
                    break

            if size >= 0 and len(line) >= size:
                endpos = size  # reached length size
                break

            # No line ending seen yet - get more data'
            while await self._read_chunk():
                if self._decoded_chars:
                    break
            if self._decoded_chars:
                line += self._get_decoded_chars()
            else:
                # end of file
                self._set_decoded_chars('')
                self._snapshot = None
                return line

        if size >= 0 and endpos > size:
            endpos = size  # don't exceed size

        # Rewind _decoded_chars to just after the line ending we found.
        self._rewind_decoded_chars(len(line) - endpos)
        return line[:endpos]

    @property
    def newlines(self):
        return self._decoder.newlines if self._decoder else None
