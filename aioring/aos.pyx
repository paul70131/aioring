from aioring.asyncio_plugin import create_plugin
from aioring import RingFullError

import asyncio
import os

cdef object _get_plugin():
    loop = asyncio.get_event_loop()
    if not hasattr(loop, '_aioring'):
        plugin = create_plugin(loop)

    return loop._aioring

cdef _submit_soon_cb(plugin):
    global _submit_soon_sent
    count = plugin.ring.submit()
    _submit_soon_sent = False

_submit_soon_sent = False
def _submit_soon(plugin):
    global _submit_soon_sent
    if not _submit_soon_sent:
        _submit_soon_sent = True
        plugin.loop.call_soon(_submit_soon_cb, plugin)

async def pread(fd, count, offset):
    plugin = _get_plugin()
    
    future = plugin.create_future()
    return await _pread(future, fd, count, offset, plugin)

async def _pread(future, fd, count, offset, plugin):
    try:
        buffer = plugin.ring.schedule_read(future, fd, count, offset)
        _submit_soon(plugin)
        bytes_read = await future
        return buffer[:bytes_read]
    except RingFullError:
        _submit_soon(plugin)
        await asyncio.sleep(0) # move to next loop iteration to submit
        return await _pread(future, fd, count, offset, plugin)

async def pwrite(fd, buffer, offset):
    plugin = _get_plugin()
    future = plugin.create_future()
    return await _pwrite(future, fd, buffer, offset, plugin)

async def _pwrite(future, fd, buffer, offset, plugin):
    try:
        plugin.ring.schedule_write(future, fd, buffer, len(buffer), offset)
        _submit_soon(plugin)
        return await future
    except RingFullError:
        _submit_soon(plugin)
        await asyncio.sleep(0) # move to next loop iteration to submit
        return await _pwrite(future, fd, buffer, offset, plugin)

async def close(fd):
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, os.close, fd)

async def open(path, flags, mode=0o777, *, dir_fd=None):
    plugin = _get_plugin()
    future = plugin.create_future()
    path = os.fsencode(path) # we need to decode it here so it doesnt get GC'd before the ring accesses it
    if not dir_fd:
        dir_fd = -100
    return await _open(future, path, flags, mode, dir_fd, plugin)

async def _open(future, path, flags, mode, dir_fd, plugin):
    try:
        fd = plugin.ring.schedule_open(future, path, dir_fd, flags, mode)
        _submit_soon(plugin)
        return await future
    except RingFullError:
        _submit_soon(plugin)
        await asyncio.sleep(0) # move to next loop iteration to submit
        return await _open(future, path, flags, mode, dir_fd, plugin)

async def fstat(fd):
    plugin = _get_plugin()
    future = plugin.create_future()
    return await _fstat(future, fd, plugin)

async def _fstat(future, fd, plugin):
    try:
        statx = plugin.ring.schedule_stat(future, fd, b'')
        _submit_soon(plugin)
        await future
        return statx
    except RingFullError:
        _submit_soon(plugin)
        await asyncio.sleep(0) # move to next loop iteration to submit
        return await _fstat(future, fd, plugin)

async def stat(path):
    if isinstance(path, int):
        return await fstat(path)
    plugin = _get_plugin()
    future = plugin.create_future()
    path = os.fsencode(path) # we need to decode it here so it doesnt get GC'd before the ring accesses it
    return await _stat(future, path, plugin)

async def _stat(future, path, plugin):
    try:
        statx = plugin.ring.schedule_stat(future, 0, path)
        _submit_soon(plugin)
        await future
        return statx
    except RingFullError:
        _submit_soon(plugin)
        await asyncio.sleep(0) # move to next loop iteration to submit
        return await _stat(future, path, plugin)


