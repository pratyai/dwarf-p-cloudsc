# Precision Lowering Report — CLOUDSC SC2026

## What JPRL means per build mode

| Build | JPRB | JPRL | Effect |
|-------|------|------|--------|
| FP64 | float64 | float64 | No differentiation — identical |
| FP32 (SINGLE) | float32 | float32 | No differentiation — identical |
| FP16 (HALF) | float16 | **float32** | JPRL fields get FP32 protection |

**FP32 and FP64 builds are completely unaffected** — JPRL collapses to JPRB.

## Category A: Promoted to JPRL (FP32 in HALF mode)

### Input fields (overflow — values exceed FP16 max 65504)

- `PAP` — pressure on full levels (~0–101325 Pa)
- `PAPH` — pressure on half levels (~0–101325 Pa)
- `PCLV` — cloud condensate mixing ratios (5 species: QL, QI, QR, QS, QV)
  - Values 1e-6 to 1e-10 kg/kg fall below FP16 subnormal range
  - Without promotion, values flush to zero causing catastrophic divergence

### Physical constants (overflow)

- `RLVTT` (~2.501e5 J/kg) — vaporization latent heat
- `RLSTT` (~2.834e5 J/kg) — sublimation latent heat
- `RLMLT` (~3.34e5 J/kg) — melting latent heat
- Wet-bulb fitting parameters including `ZTW3 = 0.85e5`

### Kernel-local computation variables (158 scalar/array declarations)

The entire microphysics computation runs in JPRL:
- Temperature/humidity working vars (ZTP1, ZQOLD, ZQNEW, …)
- Saturation calculations (ZQSAT, ZFOEEW, …)
- Cloud water/ice (ZLIQCLD, ZICECLD, ZQX arrays)
- Implicit solver matrices (ZSOLQA, ZSOLQB — NCLV×NCLV)
- All autoconversion, accretion, sedimentation rates
- Pressure-related derivatives (ZDP, ZSIG, ZDTDP, ZGDCP, ZRLDCP, …)

## Category B: Stays at JPRB (FP16 in HALF mode)

### Input arrays (values fit in FP16 range)

- `PT`, `PQ`, `PA`, `PSUPSAT`
- `PVFA`/`PVFL`/`PVFI`, `PDYNA`/`PDYNL`/`PDYNI`
- `PHRSW`, `PHRLW`, `PVERVEL`
- `PLU`, `PLUDE`, `PSNDE`, `PMFU`, `PMFD`
- Aerosol fields (`PLCRIT_AER`, `PICRIT_AER`, `PCCN`, `PNICE`, `PRE_ICE`)

### Output tendencies and fluxes (small rates/fractions)

- `TENDENCY_LOC_T/Q/A/CLD` (stored in `B_LOC`)
- 14 flux diagnostic fields (`PFSQLF`, `PFSQIF`, …)
- `PCOVPTOT`, `PRAINFRAC_TOPRFZ`

## Category C: Couldn't be promoted

Nothing was blocked for technical reasons. The interface design cleanly
separates JPRL (storage/constants) from JPRB (I/O interface).

## Notes

- JPRL is defined in `parkind1.F90`: `JPRL = SELECTED_REAL_KIND(6)` when
  `HALF` is defined, otherwise `JPRL = JPRB`.
- The JPRD (always FP64) load path for PAP/PAPH avoids FP16 truncation
  during HDF5 input. `load_array_r2_dprd` and `load_and_expand_r2_dprd`
  are called by explicit name (not via generic interface) because
  `JPRB = JPRD` in FP64 builds would cause ambiguity.
- The `B_LOC` tendency buffer CLD slots (indices 4:8) carry PCLV tendencies
  at JPRB precision. These are promoted to JPRL inside the kernel for
  computation, then truncated back to JPRB on output.
