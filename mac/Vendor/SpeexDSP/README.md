# SpeexDSP echo canceller (vendored)

The MDF acoustic echo canceller from [SpeexDSP](https://github.com/xiph/speexdsp) 1.2.1
(tag `SpeexDSP-1.2.1`, commit `1b28a0f`), under the BSD license in `COPYING`.

Only the echo canceller is included: `mdf.c`, the FFT wrapper (`fftwrap.c`) with its built-in
`smallft` FFT, and the headers they use, unmodified. `config.h` and
`include/speex/speexdsp_config_types.h` replace files that upstream generates with autotools:
floating point, `smallft`, standard integer types.
