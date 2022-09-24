from aioring import aos, DefaultRing
from .base import BaseTestCase

import unittest
import asyncio
import os

import asyncio.tasks
asyncio.tasks.Task = asyncio.tasks._PyTask

import timeit

from aioring.asyncio_plugin import create_plugin

class AosTest(BaseTestCase):


    def init_loop(self, ring=None):
        loop = asyncio.get_event_loop()
        self.plugin = create_plugin(loop, ring)
        
    async def test_pread_single(self):
        with open("tests/data/test.txt", "rb") as f:
            data = await aos.pread(f.fileno(), 4096, 0)
            f.seek(0, os.SEEK_SET)
            self.assertEqual(data, f.read()[:4096])

    async def test_pread_multiple(self):
        opcount = [1, 8, 32, 64]
        for count in opcount:
            with open("tests/data/test.txt", "rb") as f:
                async def sync_read(fd):
                    if hasattr("os", "pread"):
                        return os.pread(fd, 4096, 0)
                    else:
                        os.lseek(fd, 0, os.SEEK_SET)
                        return os.read(fd, 4096)

                async def async_read(fd):
                    return await aos.pread(fd, 4096, 0)
 
                async_buffers = await asyncio.gather(*[async_read(f.fileno()) for _ in range(count)])

                for buffer in async_buffers:
                    data = await sync_read(f.fileno())
                    self.assertEqual(buffer, data)

    async def test_pread_ring_full(self):
        ring = DefaultRing(4)
        self.init_loop(ring)
        with open("tests/data/test.txt", "rb") as f:
            await asyncio.gather(*[aos.pread(f.fileno(), 4096, 0) for _ in range(16)])
        ring.close()