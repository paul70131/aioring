import asyncio
from re import A
from .base import BaseTestCase

from aioring import aio
import os

class AioTest(BaseTestCase):
    async def test_open_read_text(self):
        with open("tests/data/test.txt", "r") as file:
            s_text = file.read()
        async with await aio.open("tests/data/test.txt", "r") as file:
            a_text = await file.read()

    async def test_open_read_binary(self):
        with open("tests/data/test.txt", "rb") as file:
            s_binary = file.read()
        async with await aio.open("tests/data/test.txt", "rb") as file:
            a_binary = await file.read()

    async def test_open_write_text(self):
        async with await aio.open("tests/data/new.txt", "w+") as file:
            a_text = "Hello World"
            await file.write(a_text)
        
        with open("tests/data/new.txt", "r") as file:
            s_text = file.read()
        self.assertEqual(s_text, a_text)
        os.unlink("tests/data/new.txt")

    async def test_open_write_binary(self):
        async with await aio.open("tests/data/new.txt", "wb+") as file:
            a_binary = b"Hello World"
            await file.write(a_binary)
        
        with open("tests/data/new.txt", "rb") as file:
            s_binary = file.read()
        self.assertEqual(s_binary, a_binary)
        os.unlink("tests/data/new.txt")

    async def test_open_append_text(self):
        async with await aio.open("tests/data/new.txt", "w+") as file:
            a_text = "Hello World"
            await file.write(a_text)

        async with await aio.open("tests/data/new.txt", "a+") as file:
            a_text = "Hello World"
            await file.write(a_text)
        
        with open("tests/data/new.txt", "r") as file:
            s_text = file.read()
        self.assertEqual(s_text, a_text * 2)
        os.unlink("tests/data/new.txt")

    async def test_open_append_binary(self):
        async with await aio.open("tests/data/new.txt", "wb+") as file:
            a_binary = b"Hello World"
            await file.write(a_binary)

        with open("tests/data/new.txt", "rb") as file:
            s_binary = file.read()
            self.assertEqual(s_binary, a_binary)

        async with await aio.open("tests/data/new.txt", "ab+") as file:
            a_binary = b"Hello World"
            await file.write(a_binary)
        
        with open("tests/data/new.txt", "rb") as file:
            s_binary = file.read()
        self.assertEqual(s_binary, a_binary * 2)
        os.unlink("tests/data/new.txt")

    async def test_async_iterator_text(self):
        s_lines = []
        a_lines = []
        with open("tests/data/test.txt", "r") as file:
            for line in file:
                s_lines.append(line)
        async with await aio.open("tests/data/test.txt", "r") as file:
            async for line in file:
                a_lines.append(line)
        self.assertEqual(s_lines, a_lines)

    async def test_async_iterator_binary(self):
        s_lines = []
        a_lines = []
        with open("tests/data/test.txt", "rb") as file:
            for line in file:
                s_lines.append(line)
        async with await aio.open("tests/data/test.txt", "rb") as file:
            async for line in file:
                a_lines.append(line)
        self.assertEqual(s_lines, a_lines)

    async def test_readlines_text(self):
        s_lines = []
        a_lines = []
        with open("tests/data/test.txt", "r") as file:
            s_lines = file.readlines()
        async with await aio.open("tests/data/test.txt", "r") as file:
            a_lines = await file.readlines()

        self.assertEqual(s_lines, a_lines)

    async def test_readline_text(self):
        with open("tests/data/test.txt", "r") as s_file:
            async with await aio.open("tests/data/test.txt", "r") as a_file:
                s_line = s_file.readline()
                a_line = await a_file.readline()
                self.assertEqual(s_line, a_line)