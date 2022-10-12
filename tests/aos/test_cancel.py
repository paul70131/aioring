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
        
    async def test_cancel(self):
        async def _task():
            fd = await aos.open("README.md", os.O_RDONLY)
            while True:
                await aos.pread(fd, 1024, 0)
        
        task = asyncio.create_task(_task())
        await asyncio.sleep(0.1)
        task.cancel()
        
        failed = False
        try:
            await task
        except asyncio.CancelledError:
            failed = True
        self.assertTrue(failed)

