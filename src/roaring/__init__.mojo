"""`roaring` — pure-Mojo Roaring bitmaps (32-bit and 64-bit), with the
RoaringFormatSpec portable serialization (including the 64-bit extension)
and Apache Iceberg's deletion-vector v1 blob framing.

    from roaring import Bitmap32, Bitmap64, encode_iceberg_dv, decode_iceberg_dv

No dependencies — the CRC-32 used by the Iceberg framing is implemented
locally in `crc32.mojo`.
"""

from .bitmap32 import Bitmap32
from .bitmap64 import Bitmap64
from .container import Container
from .crc32 import crc32
from .iceberg_dv import decode_iceberg_dv, encode_iceberg_dv
