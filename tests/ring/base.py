import unittest
import time

from aioring import ring_implementations#, ThreadPoolIoRing, IoUring

class BaseTestRingImplementationsTest(unittest.TestCase):

    def setUp(self):
        #self.rings = [ThreadPoolIoRing(),]
        self.rings = []
        for ring_impl in ring_implementations:
            self.rings.append(ring_impl())
        
    def tearDown(self):
        for ring in self.rings:
            ring.close()
