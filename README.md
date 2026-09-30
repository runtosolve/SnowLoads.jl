# SnowLoads.jl

Roof snow load calculator for enclosed buildings. Enter the ground snow load from
the [ASCE 7 Hazard Tool](https://asce7hazardtool.online/) and get flat-roof and
sloped-roof snow loads for **flat**, **gable** and **mono-slope** roofs, at
**ASD** or **LRFD** design level.

The design standard is an input. **ASCE/SEI 7-22 and ASCE/SEI 7-16 (Chapter 7) are implemented.**
The other standards are listed but intentionally blank for now.

| Standard | Status |
|---|---|
| ASCE/SEI 7-22 (USA) | implemented |
| ASCE/SEI 7-16 (USA) | implemented |
| ASCE/SEI 7-10 (USA) | not implemented |
| NBC Canada 2020, 2015 | not implemented |
| EN 1991-1-3 (Eurocode) | not implemented |
| AS/NZS 1170.3, AIJ (Japan), GB 50009 (China), other | not implemented |

## Usage

Install (once the repository is on GitHub; replace `<user>`):

```julia
using Pkg
Pkg.add(url = "https://github.com/<user>/SnowLoads.jl")
```

Interactive (US customary units: psf, ft, pcf):

```
julia --project -e 'using SnowLoads; SnowLoads.main()'
```

From Julia (nothing is exported, so use qualified names). The standard is the first
argument; each standard has its own input fields:

```julia
using SnowLoads

r = SnowLoads.compute_snow(:ASCE7_22;
    method = :LRFD, roof_type = :gable,
    pg = 30.0, risk_category = 2, terrain = :B, exposure = :partially,
    Ct = SnowLoads.ct_heated_unventilated(30, 30),   # heated, R = 30
    rise12 = 6.0, W = 30.0, W2 = 0.55,
)
SnowLoads.print_report(r)
```

Selecting a standard that is not built yet (for example `:NBCC_2020`) raises
`Standard NBC Canada 2020 (Part 4, Div. B) is not implemented yet.`

### Inputs

| Input | Notes |
|---|---|
| `pg` | Design ground snow load for the building's Risk Category (Hazard Tool) |
| `W2` | Winter wind parameter, fraction 0–1 (Hazard Tool). Gable unbalanced drift only; `0` skips the drift surcharge |
| `risk_category` | 1–4 (used for `pm,max` and the rain-on-snow limit) |
| `terrain`, `exposure` | Surface roughness `:B :C :D :T :A`; roof exposure `:fully :partially :sheltered` (Table 7.3-1) |
| `Ct` | Thermal factor: Table 7.3-3 for heated unventilated roofs (needs roof R-value), 1.2 unheated/cold, 1.3 freezer, 0.85 greenhouse |
| `rise12`, `W` | Slope (rise per 12 in.) and horizontal eave-to-ridge distance (ft) |
| `slippery` | Unobstructed slippery surface (affects `Cs`) |
| `method` | `:ASD` or `:LRFD` |

### What it computes (ASCE 7-22)

- Flat roof load `pf = 0.7 Ce Ct pg` (Eq. 7.3-1)
- Sloped roof load `ps = Cs pf` (Eq. 7.4-1, Fig. 7.4-1)
- Minimum load `pm` for slopes under 15° (7.3.3, Table 7.3-4), as a separate case
- Rain-on-snow surcharge of 8 psf (7.10)
- Gable unbalanced load (7.6.1): 0.3 ps windward; ps plus drift surcharge leeward, plus the
  W ≤ 20 ft short-span alternative
- Design-level loads. The ground snow load from the Hazard Tool is at a different level in each code,
  and the package converts accordingly:

  | Standard | `pg` from Hazard Tool | LRFD (ultimate) | ASD (service) |
  |---|---|---|---|
  | ASCE 7-16 | service level (50-yr MRI) | 1.6 × S  (1.2D + 1.6S) | 1.0 × S  (D + S) |
  | ASCE 7-22 | ultimate level (risk-targeted, per Risk Category) | 1.0 × S  (1.2D + 1.0S) | 0.7 × S  (D + 0.7S) |

  Enter `pg` exactly as the Hazard Tool reports it for the selected standard; do not pre-factor it.
  Dead load and other loads are **not** combined by the package. Scripts that build load combinations
  should take their snow terms from `SnowLoads.snow_combination(standard, method)` instead of hard-coding
  0.7 / 1.0 / 1.6 / 0.3 / 0.5: it returns `design` (S → design-level factor, same as `result.factor`),
  `companion` (factor on the design-level snow when snow accompanies wind or live load) and ready-made
  `principal_label` / `companion_label` strings (e.g. `"0.7S"`, `"0.75(0.7S)"`).
  Dead load and other loads are **not** combined.

### Not covered

Drifts at roof steps, projections and parapets (7.7, 7.8), sliding snow (7.9), partial loading
(7.5), ice dams (7.4.4), curved / sawtooth / air-supported roofs, ponding (7.11), open or
partially enclosed structures, and the negligible-`pg` exceptions of 7.2.

## Adding a standard

Each standard is a self-contained code path with its own input/result types, tables and
equations (see the architecture note at the top of `src/SnowLoads.jl`):

1. Define `<Std>Input <: AbstractSnowInput` and `<Std>Result <: AbstractSnowResult`
   (see `ASCE7_22Input` / `ASCE7_22Result`).
2. Add methods `ask_inputs(::Val{:KEY}, method)`, `make_input(::Val{:KEY}; kw...)`,
   `compute_snow(::<Std>Input)` and `print_report(::<Std>Result)`.
3. Set its flag to `true` in the `STANDARDS` list.

## Tests

```
julia --project -e 'using Pkg; Pkg.test()'
```

Covers every table entry, every code path (flat, mono-slope, gable, slope thresholds,
`pm`, rain-on-snow, unbalanced load, ASD/LRFD, unimplemented standards), the interactive
prompts, and the worked Example 1 from the ASCE 7-22 commentary.

## Disclaimer

Verify results against the standard before using them for design. The software is provided
as-is under the MIT License (see `LICENSE`).
