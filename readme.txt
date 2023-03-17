To run:  zig build run -- ../materials_repo/perfaware/part1/listing_0037_single_register_mov.asm
To test: zig build test

TODO:
[ ] get rid of build.zig and just use zig build-exe in flat directory
    [ ] so also rename main.zig to someting more sensible to use as as command
    [ ] try to use PowerShell naming like get-* set-*,
        convert-from-binaryto-asm might be a good candidate?
        but it does not say that its 8086 decoder hmm
        decode-8086 ? yeah that's nice
