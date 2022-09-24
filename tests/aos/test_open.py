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

    async def test_open_single(self):
        fd = await aos.open("README.md", os.O_RDONLY)
        self.assertGreater(fd, 0)
        os.fstat(fd)
        os.close(fd)
        self.assertRaises(OSError, os.fstat, fd)

    async def test_open_relative(self):
        fd = await aos.open("tests/data/test.txt", os.O_RDONLY)
        self.assertGreater(fd, 0)
        os.fstat(fd)
        os.close(fd)
        self.assertRaises(OSError, os.fstat, fd)

    
