import platform



from .ring import RingFullError, RingClosedError

def _linux_supported():
    rel_split = platform.release().split('.')
    return platform.platform().startswith('Linux') and int(rel_split[0]) >= 5 and int(rel_split[1]) >= 4 # maybe we could go event older than 5.4


from .ring_threaded import ThreadPoolIoRing
ring_implementations = [ThreadPoolIoRing,]
DefaultRing = ThreadPoolIoRing

if _linux_supported():
    from .ring_linux import IoUring
    DefaultRing = IoUring
    ring_implementations.append(IoUring)

from . import asyncio_plugin

from . import aos
from . import aio
