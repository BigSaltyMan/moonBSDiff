# In-memory library example

From the source checkout with the pinned MoonBit toolchain and Node available:

```sh
moon run cmd/example --target js
```

Source: `cmd/example/main.mbt`. It uses only public diff/apply and for_diff/for_apply,
fixed old/new binary bytes, and a complete comparison to the predefined new bytes.
It has no filesystem, Python or C reference dependency. Failures abort nonzero.
Output reports old/new/patch sizes and PASS. For this tiny input the patch is
larger than the new data because BSDIFF40 and three bzip2 streams have overhead;
no patch-size advantage is promised. This is source-checkout usage, not Mooncakes
registry consumption. The combined reproducible driver is documented next door.
