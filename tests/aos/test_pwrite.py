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
        
    async def test_pwrite_single(self):
        with open("tests/data/new.txt", "wb+") as f:
            data = b'a' * 4096
            await aos.pwrite(f.fileno(), data, 0)
            f.seek(0, os.SEEK_SET)
        
        with open("tests/data/new.txt", "rb") as f:
            self.assertEqual(f.read(), data)
        os.remove("tests/data/new.txt")

    async def test_pwrite_multiple(self):
        opcount = [1, 8, 32, 64, 128, 256] # cant to more since we are limited by the size of a byte
        for count in opcount:
            with open("tests/data/new.txt", "wb+") as f:
 
                await asyncio.gather(*[aos.pwrite(f.fileno(), i.to_bytes(1, "big"), i ) for i in range(count)])

            with open("tests/data/new.txt", "rb") as f:
                buffer = f.read()
                prev = 0
                for b in buffer:
                    self.assertEqual(b, prev)
                    prev += 1
        os.remove("tests/data/new.txt")
