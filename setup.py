from distutils.command.build import build
from distutils.command.build_ext import build_ext
import warnings
from setuptools import setup, Extension, find_packages

from Cython.Build import cythonize

import platform
import os
import shutil
import subprocess

extensions = [
    Extension(
        'aioring.ring',
        ['aioring/ring.pyx',],
    ), 
    Extension(
        name="aioring.ring_threaded",
        sources=["aioring/_ring/ring_threaded.pyx",],
        include_dirs=[".",]
    ),
    Extension(
        name="aioring.asyncio_plugin", 
        sources=["aioring/asyncio_plugin.pyx",],
        include_dirs=[".",]
    ),
    Extension(
        name="aioring.aos",
        sources=["aioring/aos.pyx",],
        include_dirs=[".",]
    ), Extension(
        name="aioring.aio",
        sources=["aioring/aio.pyx",],
        include_dirs=[".",]
    ),
]

if platform.system() == 'Linux':
    # run configure in subprocess
    dir = os.getcwd()
    os.chdir("aioring/lib/liburing/")
    subprocess.run(["bash", "configure"])
    os.chdir(dir)
    linux_ring = Extension(
        name="aioring.ring_linux",
        sources=[
            "aioring/_ring/ring_linux.pyx",
            "aioring/lib/liburing/src/queue.c",
            "aioring/lib/liburing/src/setup.c",
            "aioring/lib/liburing/src/register.c",
        ],
        include_dirs=[
            "aioring/lib/liburing/src/include",
            "."
        ],
        define_macros=[
            ("AT_FDCWD", "-100"),
        ]
    )
    extensions.append(linux_ring)

shutil.copy(
    "./aioring/__init__.py",
    "./__init__.py"
)

setup(
    name='aioring',
    description="Access to IoRings for fileIO with asyncio",
    ext_modules=cythonize(extensions, language_level=3, build_dir="build/c"),
    packages=find_packages(),
    package_dir={'aioring': 'aioring'},
    zip_safe=False,
    long_description=open('README.md').read(),
    version='0.1.0',
    author="Paul K."
)
