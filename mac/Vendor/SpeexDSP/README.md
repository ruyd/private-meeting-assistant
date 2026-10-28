# SpeexDSP echo handling (vendored)

The acoustic echo canceller and preprocessor from [SpeexDSP](https://github.com/xiph/speexdsp) 1.2.1
(tag `SpeexDSP-1.2.1`, commit `1b28a0f`), under the BSD license in `COPYING`.

Only echo handling is included, unmodified: the echo canceller (`mdf.c`), the preprocessor that
suppresses residual echo per frequency band (`preprocess.c`, `filterbank.c`), the FFT wrapper
(`fftwrap.c`) with its built-in `smallft` FFT, and the headers they use. `config.h` and
`include/speex/speexdsp_config_types.h` replace files that upstream generates with autotools:
floating point, `smallft`, standard integer types.
