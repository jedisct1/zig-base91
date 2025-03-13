# Base91 for Zig

An implementation of the Base91 encoding scheme written in Zig.

It enables you to convert binary data to a Base91-encoded string and vice versa.

## Overview

- **Space Efficiency:** Base91 produces shorter encoded strings compared to Base64, which can be advantageous when minimizing data size is a priority.
- **Performance Trade-Off:** Although Base91 is more space-efficient, its encoding/decoding operations are generally slower than those of Base64. This trade-off should be considered based on your application’s requirements.

## Considerations

- **When to Use:** Opt for Base91 when reducing the size of encoded data is critical, such as in bandwidth-constrained environments or when storing large volumes of encoded data.
- **When to Avoid:** If your application is performance-sensitive and the encoding/decoding speed is paramount, Base64 might be a more suitable alternative.
