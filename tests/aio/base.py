import unittest
import asyncio

import faulthandler
faulthandler.enable()

class BaseTestCase(unittest.TestCase):
    
    def _callTestMethod(self ,method):
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)

        loop.run_until_complete(method())
        loop.close()
        asyncio.set_event_loop(None)