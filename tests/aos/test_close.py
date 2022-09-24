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
        
    async def test_close_single(self):
        fd = os.open("tests/data/test.txt", os.O_RDONLY)
        await aos.close(fd)
        self.assertRaises(OSError, os.fstat, fd)


