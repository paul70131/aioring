from .base import BaseTestRingImplementationsTest

import time
import os
import errno
import platform

import faulthandler
faulthandler.enable()

from aioring import RingFullError, RingClosedError

class RingImplementationsTest(BaseTestRingImplementationsTest):
    
    def test_init_close(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                self.assertIsNotNone(ring)
        # init is handles in setUp and tearDown
    
    def test_closed(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                ring.close()
                self.assertRaises(RingClosedError, ring.get_completions)
        self.rings = []

    def test_get_event(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                event = ring.get_event()
                self.assertIsNotNone(event)
                self.assertTrue(hasattr(event, "wait"))

    def test_get_completions_empty(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                completions = ring.get_completions()
                self.assertEqual(len(completions), 0)

    # def test_get_completion_single(self): # also tests this
    def test_schedule_read_single(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                with open("tests/data/test.txt", "rb") as f:
                    fd = f.fileno()
                    buffer = ring.schedule_read(0xAAAA, fd, 4096, 0)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    f.seek(0)
                    data = f.read(4096)
                    
                    self.assertEqual(completions[0].get_res(), len(data))
                    self.assertEqual(data, buffer[:completions[0].get_res()])
                    self.assertEqual(completions[0].get_data(), 0xAAAA)

    # def test_get_completion_multiple(self): # also tests this
    def test_schedule_read_multiple(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                with open("tests/data/test.txt", "rb") as f:
                    r_data = f.read()
                    offsets = range(0, len(r_data) - 8, 8)
                    buffers = []
                    for offset in offsets:
                        buffer = ring.schedule_read(0xAAAA, f.fileno(), 8, offset)
                        buffers.append((offset, buffer))
                    count = ring.submit()
                    completions = []
                    while len(completions) < len(buffers):
                        time.sleep(0)
                        completions += ring.get_completions()
                    for i, buffer in enumerate(buffers):
                        length = len(buffer[1])
                        start = buffer[0]
                        self.assertEqual(buffer[1], r_data[start:start+length])

    def test_schedule_read_errors_linux(self):
        if platform.system() != "Linux":
            self.skipTest("Wrong OS")
        # EBADF, EISDIR
        for ring in self.rings:
            with self.subTest(ring=ring):
                with self.subTest(error="EBADF"):
                    target = errno.EBADF
                    try:
                        os.read(-1, 1)
                    except OSError as e:
                        self.assertEqual(e.errno, target)
                    buffer = ring.schedule_read(0xAAAA, -1, 1, 0)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -target)
                    self.assertEqual(completions[0].get_data(), 0xAAAA)
                    
                with self.subTest(error="EISDIR"):
                    target = errno.EISDIR
                    dirfd = os.open(".", os.O_RDONLY)
                    try:
                        os.read(dirfd, 1)
                    except OSError as e:
                        self.assertEqual(e.errno, target)
                    buffer = ring.schedule_read(0xAAAA, dirfd, 1, 0)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -target)
                    self.assertEqual(completions[0].get_data(), 0xAAAA)

    def test_schedule_write_single(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                with open("tests/data/new.txt", "wb+") as f:
                    data = b"Hello World"
                    ring.schedule_write(0xAAAA, f.fileno(), data, len(data), 0)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                

                with open("tests/data/new.txt", "rb") as f:
                    file_data = f.read(len(data))
                    self.assertEqual(file_data, data)
        os.unlink("tests/data/new.txt")

    def test_schedule_write_multiple(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                with open("tests/data/new.txt", "wb+") as f:
                    data = b"Hello World"
                    op_data = bytearray(256)
                    offsets = [off for off in range(0, 256, 16)]
                    for offset in offsets:
                        op_data[offset:offset+len(data)] = data
                        ring.schedule_write(0xAAAA, f.fileno(), data, len(data), offset)
                    ring.submit()
                    completions = []
                    while len(completions) < len(offsets):
                        time.sleep(0)
                        completions += ring.get_completions()
                    self.assertEqual(len(completions), len(offsets))
                    f.seek(0)
                    file_data = f.read(len(op_data))
                    self.assertEqual(file_data, op_data[:len(file_data)])
        os.unlink("tests/data/new.txt")

    def test_schedule_write_errors_linux(self):
        if platform.system() != "Linux":
            self.skipTest("Wrong OS")
        # EBADF, EISDIR
        for ring in self.rings:
            with self.subTest(ring=ring):
                with self.subTest(error="EBADF"):
                    target = errno.EBADF
                    try:
                        os.write(-1, b"")
                    except OSError as e:
                        self.assertEqual(e.errno, target)
                    buffer = ring.schedule_write(0xAAAA, -1, b"", 1, 0)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -target)
                    self.assertEqual(completions[0].get_data(), 0xAAAA)
                    
                with self.subTest(error="EISDIR"):
                    # with write pythons os.write does not return EISDIR but EBADF

                    target = errno.EBADF #errno.EISDIR 
                    dirfd = os.open(".", os.O_RDONLY)
                    try:
                        os.write(dirfd, b"")
                    except OSError as e:
                        self.assertEqual(e.errno, target)
                    buffer = ring.schedule_write(0xAAAA, dirfd, b"", 1, 0)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -target)
                    self.assertEqual(completions[0].get_data(), 0xAAAA)

    def test_schedule_stat(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                data = 0xAAAA
                stat_1 = ring.schedule_stat(data, 0, b'setup.py')
                ring.submit()
                completions = []
                while not completions:
                    time.sleep(0)
                    completions = ring.get_completions()
                stat_2 = os.stat('setup.py')
                fields = ["st_mode", "st_ino", "st_dev", "st_nlink", "st_uid", "st_gid", "st_size", "st_atime", "st_mtime", "st_ctime"]

                self.assertEqual(len(completions), 1)
                self.assertEqual(completions[0].get_res(), 0)


                for field in fields:
                    self.assertEqual(getattr(stat_1, field), getattr(stat_2, field))

    def test_schedule_stat_errors_linux(self):
        if platform.system() != "Linux":
            self.skipTest("Wrong OS")
        # EACCESS, EBADF, ENAMETOOLONG, ENOENT, ENOTDIR
        for ring in self.rings:
            with self.subTest(ring=ring):
                #with self.subTest(error="EACCESS"): # not sure how to test this on different systems

                with self.subTest(error="EBADF"):
                    fd = -1
                    try:
                        os.stat("setup.py", dir_fd=fd)
                    except OSError as e:
                        self.assertEqual(e.errno, errno.EBADF)
                    stat = ring.schedule_stat(0xAAAA, fd, b'setup.py')
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -errno.EBADF)

                with self.subTest(error="ENAMETOOLONG"):
                    target = errno.ENAMETOOLONG
                    try:
                        os.stat("setup.py" + "a"*256)
                    except OSError as e:
                        self.assertEqual(e.errno, target)
                    stat = ring.schedule_stat(0xAAAA, 0, b'setup.py' + b'a'*256)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -target)
                    self.assertEqual(completions[0].get_data(), 0xAAAA)

                with self.subTest(error="ENOENT"):
                    target = errno.ENOENT
                    try:
                        os.stat("setup.py.not")
                    except OSError as e:
                        self.assertEqual(e.errno, target)
                    stat = ring.schedule_stat(0xAAAA, 0, b'setup.py.not')
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -target)
                    self.assertEqual(completions[0].get_data(), 0xAAAA)

                with self.subTest(error="ENOTDIR"):
                    target = errno.ENOTDIR
                    try:
                        os.stat("setup.py", dir_fd=1)
                    except OSError as e:
                        self.assertEqual(e.errno, target)
                    stat = ring.schedule_stat(0xAAAA, 1, b'setup.py')
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -target)
                    self.assertEqual(completions[0].get_data(), 0xAAAA)

    def test_schedule_open_basedir(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                data = 0xAAAA
                ring.schedule_open(data, b'README.md', -100, os.O_RDONLY, 0o777)
                ring.submit()
                completions = []
                while not completions:
                    time.sleep(0)
                    completions = ring.get_completions()
                self.assertEqual(data, completions[0].get_data())
                self.assertEqual(len(completions), 1)
                self.assertGreaterEqual(completions[0].get_res(), 0)

    def test_schedule_open_subdir(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                data = 0xAAAA
                ring.schedule_open(data, b'tests/data/test.txt', -100, os.O_RDONLY, 0o777)
                ring.submit()
                completions = []
                while not completions:
                    time.sleep(0)
                    completions = ring.get_completions()
                self.assertEqual(data, completions[0].get_data())
                self.assertEqual(len(completions), 1)
                self.assertGreaterEqual(completions[0].get_res(), 0)

    def test_schedule_open_errors_linux(self):
        if platform.system() != "Linux":
            self.skipTest("Wrong OS")
        # openat: EBADF, ENOTDIR
        # open: EEXIST, EISDIR, ENAMETOOLONG, ENOENT
        for ring in self.rings:
            with self.subTest(ring=ring):
                with self.subTest(error="EBADF"):
                    fd = -1
                    try:
                        os.open("README.md", os.O_RDONLY, dir_fd=fd)
                    except OSError as e:
                        self.assertEqual(e.errno, errno.EBADF)
                    ring.schedule_open(0xAAAA, b'README.md', fd, os.O_RDONLY, 0o777)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -errno.EBADF)
                    self.assertEqual(completions[0].get_data(), 0xAAAA)

                with self.subTest(error="ENOTDIR"):
                    # fd 1 on linux is stdout
                    try:
                        os.open("README.md", os.O_RDONLY, dir_fd=1)
                    except OSError as e:
                        self.assertEqual(e.errno, errno.ENOTDIR)
                    ring.schedule_open(0xAAAA, b'README.md', 1, os.O_RDONLY, 0o777)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -errno.ENOTDIR)
                    self.assertEqual(completions[0].get_data(), 0xAAAA)

                with self.subTest(error="EEXIST"):
                    try:
                        res = os.open("README.md", os.O_RDONLY | os.O_CREAT | os.O_EXCL)
                        self.assertGreater(0, res)
                    except OSError as e:
                        self.assertEqual(e.errno, errno.EEXIST)
                    ring.schedule_open(0xAAAA, b'README.md', 0, os.O_RDONLY | os.O_CREAT | os.O_EXCL, 0o777)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -errno.EEXIST)

                with self.subTest(error="EISDIR"):
                    try:
                        res = os.open(".", os.O_WRONLY)
                        self.assertGreater(0, res)
                    except OSError as e:
                        self.assertEqual(e.errno, errno.EISDIR)
                    ring.schedule_open(0xAAAA, b'.', 0, os.O_WRONLY, 0o777)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -errno.EISDIR)

                with self.subTest(error="ENAMETOOLONG"):
                    try:
                        res = os.open("README.md" * 100, os.O_RDONLY)
                        self.assertGreater(0, res)
                    except OSError as e:
                        self.assertEqual(e.errno, errno.ENAMETOOLONG)

                    ring.schedule_open(0xAAAA, b'README.md' * 100, 0, os.O_RDONLY, 0o777)
                    ring.submit()
                    completions = []
                    while not completions:
                        time.sleep(0)
                        completions = ring.get_completions()
                    self.assertEqual(len(completions), 1)
                    self.assertEqual(completions[0].get_res(), -errno.ENAMETOOLONG)
                


    def test_ring_size(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                ring_type = type(ring)
                ring.close()
                self.rings = []
                sizes = [8, 32, 256]
                for size in sizes:
                    with self.subTest(size=size):
                        ring = ring_type(size)
                        for i in range(size):
                            buffer = ring.schedule_read(0, 0, 1, 0)
                        self.assertRaises(RingFullError, ring.schedule_read, 0, 0, 1, 0)
                        ring.close()

    def test_cancel(self):
        for ring in self.rings:
            with self.subTest(ring=ring):
                buffer = ring.schedule_read(0xABCDEF, 0, 1, 0)
                ring.schedule_cancel(0xABCDEF)
                ring.submit()
                completions = []
                while not completions:
                    time.sleep(0)
                    completions = ring.get_completions()

                self.assertGreater(len(completions), 0)
                for completion in completions:
                    if completion.get_data() == None:
                        continue
                    self.assertEqual(completion.get_data(), 0xABCDEF)
                    self.assertEqual(completion.get_res(), -125)
