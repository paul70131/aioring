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

    async def test_fstat_single(self):
        fd = os.open("README.md", os.O_RDONLY)

        s_stat = os.fstat(fd)
        a_stat = await aos.fstat(fd)

        attributes = ["st_mode", "st_ino", "st_dev", "st_nlink", "st_uid", "st_gid", "st_size", "st_atime", "st_mtime", "st_ctime"]
        for attr in attributes:
            self.assertEqual(getattr(s_stat, attr), getattr(a_stat, attr))
        os.close(fd)

    async def test_stat_single(self):
        s_stat = os.stat("README.md")
        a_stat = await aos.stat("README.md")

        attributes = ["st_mode", "st_ino", "st_dev", "st_nlink", "st_uid", "st_gid", "st_size", "st_atime", "st_mtime", "st_ctime"]
        for attr in attributes:
            self.assertEqual(getattr(s_stat, attr), getattr(a_stat, attr))

    
    async def test_stat_relative(self):
        s_stat = os.stat("tests/data/test.txt")
        a_stat = await aos.stat("tests/data/test.txt")

        attributes = ["st_mode", "st_ino", "st_dev", "st_nlink", "st_uid", "st_gid", "st_size", "st_atime", "st_mtime", "st_ctime"]
        for attr in attributes:
            self.assertEqual(getattr(s_stat, attr), getattr(a_stat, attr))
    
