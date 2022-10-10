## aioring (Io Rings for asyncio)

aioring is a library that handles async fileIO.
Currently we only support io_uring on linux, other operating systems fall back to a custom ring using python threads which is only intended for development purposes and should not be used in production.


```python
from aioring import aio

async with await aio.open("file.name", "r") as f:
  content = await f.read()
```

# install
aioring can be installed with pip 
```sh
pip install aioring
```

# aos
in aos we expose async versions of functions defined in the 'os' module.
currently we support:
* `aos.pread(fd: int, count: int, offset: int)`
* `aos.pwrite(fd: int, buffer: bytes, offset: int)`
* `aos.close(fd: int)`
* `aos.open(path: str, flags: int, mode: int=0o777, *, dir_fd=None)`
* `aos.fstat(fd: int)`
* `aos.stat(path: str)`
these functions should work the same way as their counterpart in the os module but need to be called with await.

# aio
in aio we expose a async implementation of the cpython pyio module (https://github.com/python/cpython/blob/3.10/Lib/_pyio.py)
usage is like normal io but with async/await
```python
from aioring import aio
# read file
async with await aio.open("file.txt", "r") as f:
    data = await f.read()
    
# write file
async with await aio.open("file.txt", "w") as f:
    data = await f.write("test")
```

# Plans
* [X] fileIO
* [ ] Windows IoRing
* [ ] socketIO
