"""
SnowLoads.jl

Interactive roof snow load calculator. The design code / standard is an
input; currently only ASCE/SEI 7-22, Chapter 7 is implemented (US customary
units: psf, ft, pcf). Other standards are registered but left blank (they
raise a "not implemented yet" error) - see the STANDARDS section below.

Supports enclosed buildings with
  * flat roofs
  * gable roofs   (balanced + unbalanced loads)
  * mono-slope roofs

The user chooses the design method (ASD or LRFD). Snow load S from Chapter 7
is reported at the corresponding design level using the ASCE 7-22 principal
snow-load load factors (Sec. 2.3.1 / 2.4.1, combination 3a):
  * LRFD : snow factor 1.0   (pg is already ultimate level)
  * ASD  : snow factor 0.7   (converts ultimate level to service level)

For ASCE 7-16, pg is a service-level (50-yr MRI) value, so the factors are
LRFD 1.6 (1.2D + 1.6S) and ASD 1.0 (D + S). See PG_BASIS in the source.

Run:   julia --project -e 'using SnowLoads; SnowLoads.main()'

This package only computes flat / sloped roof snow loads from the ground snow
load; it does not combine them with dead load or other loads.

Inputs from the ASCE 7 Hazard Tool (https://asce7hazardtool.online/):
  * pg  - design ground snow load for the building's Risk Category
  * W2  - winter wind parameter (only needed for gable unbalanced load)

NOT covered: drifts at roof steps / projections / parapets (7.7, 7.8), sliding
snow (7.9), partial loading of continuous members (7.5), ice dams (7.4.4),
curved / sawtooth / air-supported roofs, ponding instability (7.11), open or
partially enclosed structures, and the Sec. 7.2 exceptions for negligible pg.
"""
module SnowLoads

# ---------------------------------------------------------------------------
# ARCHITECTURE - one self-contained code path per design standard
#
# The user (or caller) picks a standard key from STANDARDS. Everything that
# follows dispatches on it:
#
#   ask_inputs(Val(key), method)   prompt for that standard's inputs
#                                  -> <Std>Input  (<: AbstractSnowInput)
#   make_input(Val(key); kw...)    non-interactive equivalent of the above
#   compute_snow(input)            -> <Std>Result (<: AbstractSnowResult)
#   print_report(result)           report in that standard's terms
#
# Each standard defines its own Input / Result structs, tables and equations,
# so code-specific parameters (e.g. ASCE's Ce/Ct/W2, Canada's Ss/Sr, Eurocode's
# sk/Ce/Ct/mu) never leak into another standard's path.
#
# To add a standard:
#   1. define `struct <Std>Input <: AbstractSnowInput` and `<Std>Result`
#   2. add methods: ask_inputs(::Val{:KEY}, method), make_input(::Val{:KEY}; kw...),
#      compute_snow(::<Std>Input), print_report(::<Std>Result)
#   3. flip its flag to `true` in STANDARDS below
# ---------------------------------------------------------------------------

abstract type AbstractSnowInput end
abstract type AbstractSnowResult end

# STANDARDS - design codes selectable by the user: key => (display name, implemented?)

const STANDARDS = [
    :ASCE7_22    => ("ASCE/SEI 7-22 (USA)",                        true),
    :ASCE7_16    => ("ASCE/SEI 7-16 (USA)",                        true),
    :ASCE7_10    => ("ASCE/SEI 7-10 (USA)",                        false),
    :NBCC_2020   => ("NBC Canada 2020 (Part 4, Div. B)",           false),
    :NBCC_2015   => ("NBC Canada 2015 (Part 4, Div. B)",           false),
    :EN1991_1_3  => ("EN 1991-1-3 Eurocode 1 - Snow loads",        false),
    :AS_NZS_1170 => ("AS/NZS 1170.3 (Australia / New Zealand)",    false),
    :AIJ_2015    => ("AIJ Recommendations for Loads (Japan)",      false),
    :GB_50009    => ("GB 50009 (China)",                           false),
    :OTHER       => ("Other equivalent code",                      false),
]

standard_name(key::Symbol) = first(Dict(STANDARDS)[key])

# ---------------------------------------------------------------------------
# LOAD LEVEL of the ground snow load pg returned by the ASCE 7 Hazard Tool
#
# Every snow load computed by this package is proportional to pg, so it is at
# the same level as the pg that is entered. The factors below convert that
# computed load S to each design level:
#
#   ASCE 7-16: pg is a SERVICE-level (50-yr MRI) value.
#              ASD  uses S as is           (D + S)        -> service factor  1.0
#              LRFD uses 1.6 S             (1.2D + 1.6S)  -> ultimate factor 1.6
#   ASCE 7-22: pg is an ULTIMATE-level (risk-targeted) value.
#              LRFD uses S as is           (1.2D + 1.0S)  -> ultimate factor 1.0
#              ASD  uses 0.7 S             (D + 0.7S)     -> service factor  0.7
# ---------------------------------------------------------------------------

const PG_BASIS = Dict(
    :ASCE7_22 => (level = :ultimate, service = 0.7, ultimate = 1.0),
    :ASCE7_16 => (level = :service,  service = 1.0, ultimate = 1.6),
)

# Load-combination factor on snow when it is a COMPANION load (with wind or live load),
# from the basic combinations of each standard:
#   ASCE 7-22: LRFD 0.3 S (Sec. 2.3.1 eqs. 2a, 4a);  ASD 0.75 (0.7 S) (Sec. 2.4.1 eqs. 4a, 6a)
#   ASCE 7-16: LRFD 0.5 S (Sec. 2.3.2 eqs. 2, 4);    ASD 0.75 S       (Sec. 2.4.1 eqs. 4, 6)
# LRFD values multiply the ultimate-level snow load; ASD values multiply the
# service-level (design-level) snow load.
const SNOW_COMPANION = Dict(
    :ASCE7_22 => (LRFD = 0.3, ASD = 0.75),
    :ASCE7_16 => (LRFD = 0.5, ASD = 0.75),
)


"""
    snow_combination(code::Symbol, method::Symbol)

Snow terms for the load combinations of standard `code`, for scripts that combine
the snow load with dead, live and wind loads. Load combinations should use the
snow load `S_d = factor * S` (the design-level snow load, `result.factor * load`),
where `factor = design_factor(code, method)`, and then:

  * principal snow combination  ->  `S_d`                    (label `principal_label`)
  * companion snow combination  ->  `companion * S_d`        (label `companion_label`)

So no standard-specific snow factor (0.7, 1.0, 1.6, 0.3, 0.5, 0.75) has to be
hard-coded in the calling script.
"""
function snow_combination(code::Symbol, method::Symbol)
    haskey(PG_BASIS, code) || not_implemented(code)
    d = design_factor(code, method)
    c = getproperty(SNOW_COMPANION[code], method)
    companion = method == :LRFD ? c / d : c          # relative to the design-level snow load
    principal_label = d == 1.0 && method == :ASD ? "S" : string(fmt_factor_S(d), "S")
    companion_label = method == :LRFD ? string(fmt_factor_S(c), "S") :
                      (d == 1.0 ? "0.75S" : string("0.75(", fmt_factor_S(d), "S)"))
    return (design = d, companion = companion,
            principal_label = principal_label, companion_label = companion_label)
end
fmt_factor_S(x) = x == round(x) ? string(Int(x), ".0") : string(x)

"Factor applied to the computed snow load S to reach the requested design level."
design_factor(key::Symbol, method::Symbol) =
    method == :LRFD ? PG_BASIS[key].ultimate :
    method == :ASD  ? PG_BASIS[key].service  :
    error("Design method must be :ASD or :LRFD, got :$method")

is_implemented(key::Symbol) = last(Dict(STANDARDS)[key])

# Fallbacks for standards that are registered but not built yet (intentionally
# blank). Implemented standards add more specific methods below.
not_implemented(key) = error("Standard $(standard_name(key)) is not implemented yet.")
ask_inputs(::Val{K}, method) where {K} = not_implemented(K)
make_input(::Val{K}; kw...) where {K} = not_implemented(K)

"""
    compute_snow(code::Symbol; kw...)

Build the input for standard `code` from keyword arguments and compute the
snow loads, e.g. `compute_snow(:ASCE7_22; method = :LRFD, roof_type = :flat, ...)`.
"""
compute_snow(code::Symbol; kw...) = compute_snow(make_input(Val(code); kw...))

# ===========================================================================
# ASCE/SEI 7-22  (key :ASCE7_22)
# ===========================================================================

# ---------------------------------------------------------------------------
# Code tables (ASCE 7-22)
# ---------------------------------------------------------------------------

# Table 7.3-4 - pm,max by Risk Category (psf)
const PM_MAX = Dict(1 => 25.0, 2 => 30.0, 3 => 35.0, 4 => 40.0)

# Table 7.3-1 - exposure factor Ce: (terrain, roof exposure) -> Ce
# terrain: :B :C :D  :T (above tree line, windswept)  :A (Alaska, no trees)
const CE_TABLE = Dict(
    (:B, :fully) => 0.9, (:B, :partially) => 1.0, (:B, :sheltered) => 1.2,
    (:C, :fully) => 0.9, (:C, :partially) => 1.0, (:C, :sheltered) => 1.1,
    (:D, :fully) => 0.8, (:D, :partially) => 0.9, (:D, :sheltered) => 1.0,
    (:T, :fully) => 0.7, (:T, :partially) => 0.8,
    (:A, :fully) => 0.7, (:A, :partially) => 0.8,
)

# Table 7.3-3 - Ct for heated structures with unventilated roofs
const CT33_PG = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0]     # columns
const CT33_R  = [20.0, 30.0, 40.0, 50.0]                         # rows (R-value)
const CT33 = [
    1.20 1.11 1.05 1.01 1.00 1.00 1.00;    # R <= 20
    1.20 1.17 1.14 1.13 1.12 1.11 1.10;    # R  = 30
    1.20 1.19 1.17 1.16 1.16 1.15 1.15;    # R  = 40
    1.20 1.20 1.19 1.19 1.19 1.18 1.18;    # R  = 50
]

# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------

Base.@kwdef struct ASCE7_22Input <: AbstractSnowInput
    method::Symbol            # :ASD or :LRFD
    roof_type::Symbol         # :flat, :gable, :monoslope
    pg::Float64               # design ground snow load (Hazard Tool), psf
    risk_category::Int        # 1-4
    terrain::Symbol           # :B :C :D :T :A
    exposure::Symbol          # :fully :partially :sheltered
    Ct::Float64               # thermal factor (Tables 7.3-2 / 7.3-3)
    rise12::Float64 = 0.0     # roof slope, rise per 12 in. run
    W::Float64 = 0.0          # horizontal eave-to-ridge distance (gable) or
                              # eave-to-high-eave width (mono/flat), ft
    slippery::Bool = false    # unobstructed slippery surface (Cs)
    W2::Float64 = 0.0         # winter wind parameter, fraction 0-1 (gable unbalanced)
end

struct ASCE7_22Result <: AbstractSnowResult
    input::ASCE7_22Input
    theta::Float64      # slope, degrees
    Ce::Float64
    Ct::Float64
    Cs::Float64
    pf::Float64         # flat roof snow load
    pm::Float64         # minimum snow load, separate case (0 if n/a)
    ps::Float64         # sloped roof (balanced) snow load
    ros::Float64        # rain-on-snow surcharge added to ps (psf)
    balanced::Float64   # balanced load case: ps + ros
    unbalanced::Union{Nothing,NamedTuple}
    factor::Float64     # S -> design level: LRFD 1.0 (ultimate), ASD 0.7 (service)
    notes::Vector{String}
end

# ---------------------------------------------------------------------------
# Code equations
# ---------------------------------------------------------------------------

slope_deg(rise12) = atand(rise12 / 12)

"Flat roof snow load, Eq. 7.3-1: pf = 0.7 Ce Ct pg"
flat_roof_load(pg, Ce, Ct) = 0.7 * Ce * Ct * pg

"Minimum snow load pm for low-slope roofs, Sec. 7.3.3 and Table 7.3-4"
minimum_load(pg, risk) = min(pg, PM_MAX[risk])

"Bilinear interpolation of Table 7.3-3 (clamped to the table range)."
function ct_heated_unventilated(pg, R)
    R > 50 && return 1.2
    pgc = clamp(pg, CT33_PG[1], CT33_PG[end])
    Rc = clamp(R, CT33_R[1], CT33_R[end])
    j = min(searchsortedlast(CT33_PG, pgc), length(CT33_PG) - 1)
    i = min(searchsortedlast(CT33_R, Rc), length(CT33_R) - 1)
    tj = (pgc - CT33_PG[j]) / (CT33_PG[j+1] - CT33_PG[j])
    ti = (Rc - CT33_R[i]) / (CT33_R[i+1] - CT33_R[i])
    return (1 - ti) * ((1 - tj) * CT33[i, j]   + tj * CT33[i, j+1]) +
           ti       * ((1 - tj) * CT33[i+1, j] + tj * CT33[i+1, j+1])
end

"""
Roof slope factor Cs, Fig. 7.4-1 (selected by Ct per Sec. 7.4.4). Cs = 1 up to
a threshold angle, then linear to 0 at 70 deg.
  Ct <= 1.1        : 30 deg, all surfaces
  1.1 < Ct < 1.2   : 37.5 deg other surfaces, 10 deg slippery
  Ct >= 1.2        : 45 deg other surfaces,   15 deg slippery
"""
function slope_factor(theta, Ct, slippery)
    θ0 = if Ct <= 1.1
        30.0
    elseif Ct < 1.2
        slippery ? 10.0 : 37.5
    else
        slippery ? 15.0 : 45.0
    end
    theta <= θ0 && return 1.0
    theta >= 70 && return 0.0
    return (70 - theta) / (70 - θ0)
end

"Snow density, Eq. 7.7-1: γ = 0.13 pg + 14 <= 30 pcf"
snow_density(pg) = min(0.13 * pg + 14, 30.0)

"Drift height hd (ft), Eq. 7.6-1: 1.5 sqrt(pg^0.74 lu^0.70 W2^1.7 / γ)"
drift_height(pg, lu, W2) = 1.5 * sqrt(pg^0.74 * lu^0.70 * W2^1.7 / snow_density(pg))

# ---------------------------------------------------------------------------
# Main calculation
# ---------------------------------------------------------------------------

make_input(::Val{:ASCE7_22}; kw...) = ASCE7_22Input(; kw...)

"Compute ASCE 7-22 roof snow loads."
function compute_snow(inp::ASCE7_22Input)
    notes = String[]
    haskey(CE_TABLE, (inp.terrain, inp.exposure)) ||
        error("Ce is not permitted for this terrain/exposure combination (Table 7.3-1).")
    Ce = CE_TABLE[(inp.terrain, inp.exposure)]
    Ct = inp.Ct
    θ = inp.roof_type == :flat ? 0.0 : slope_deg(inp.rise12)
    factor = design_factor(:ASCE7_22, inp.method)

    pf = flat_roof_load(inp.pg, Ce, Ct)
    Cs = inp.roof_type == :flat ? 1.0 : slope_factor(θ, Ct, inp.slippery)
    ps = Cs * pf                                       # Eq. 7.4-1

    # 7.3.3 minimum load (separate uniform load case), slopes < 15 deg
    pm = (θ < 15 && inp.pg > 0) ? minimum_load(inp.pg, inp.risk_category) : 0.0
    pm > 0 && push!(notes, "pm is a separate uniform load case (7.3.3); it is not " *
                           "combined with unbalanced, drift, sliding or partial loads.")

    # 7.10 rain-on-snow surcharge: 0 < pg <= pm,max and slope (deg) < W/50
    ros = 0.0
    if 0 < inp.pg <= PM_MAX[inp.risk_category] && inp.W > 0 && θ < inp.W / 50
        ros = 8.0
        push!(notes, "8 psf rain-on-snow surcharge added to the balanced load (7.10); " *
                     "not used with drift, sliding, unbalanced, minimum or partial loads.")
    end
    balanced = ps + ros

    # 7.6.1 unbalanced load, gable roofs
    unb = nothing
    if inp.roof_type == :gable
        inp.W > 0 || error("Gable roofs need the eave-to-ridge horizontal distance W.")
        if 2.38 <= θ <= 30.2
            S = 12 / inp.rise12                         # run for a rise of one
            γ = snow_density(inp.pg)
            hd = inp.W2 > 0 ? drift_height(inp.pg, inp.W, inp.W2) : 0.0
            pd = hd * γ / sqrt(S)                       # rectangular surcharge
            wd = min(8 * hd * sqrt(S) / 3, inp.W)       # extent from ridge
            unb = (windward = 0.3 * ps, leeward = ps, surcharge = pd,
                   extent = wd, hd = hd, γ = γ, short_span = nothing)
            if inp.W <= 20
                unb = merge(unb, (short_span = (windward = 0.0, leeward = inp.pg),))
                push!(notes, "W <= 20 ft: if members are simply supported prismatic " *
                             "members spanning ridge to eave, design for the leeward " *
                             "uniform load pg with the windward side unloaded (7.6.1) " *
                             "in place of the 0.3ps / ps + surcharge case.")
            end
            inp.W2 > 0 || push!(notes, "W2 not provided: drift surcharge not computed.")
        else
            push!(notes, "Unbalanced load not required: slope outside " *
                         "2.38 deg (1/2:12) to 30.2 deg (7:12) (7.6.1).")
        end
    end

    return ASCE7_22Result(inp, θ, Ce, Ct, Cs, pf, pm, ps, ros, balanced, unb, factor, notes)
end

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

fmt(x) = string(round(x; digits = 2))

function print_report(r::ASCE7_22Result)
    i = r.input
    f = r.factor
    line = "="^68
    println("\n", line)
    println(" ", uppercase(standard_name(:ASCE7_22)), " ROOF SNOW LOADS  -  ", uppercase(String(i.roof_type)), " ROOF, ",
            i.method)
    println(line)
    println(" Ground snow load  pg      = ", fmt(i.pg), " psf  (Risk Category ",
            i.risk_category, ")")
    println(" pg basis                  = ultimate-level (risk-targeted), as given by the Hazard Tool")
    println(" Terrain / exposure / Ce   = ", i.terrain, " / ", i.exposure, " / ", r.Ce)
    println(" Thermal factor    Ct      = ", fmt(r.Ct))
    if i.roof_type != :flat
        println(" Roof slope                = ", i.rise12, ":12  (", fmt(r.theta), " deg)")
        println(" Slope factor      Cs      = ", fmt(r.Cs),
                i.slippery ? "  (unobstructed slippery surface)" : "")
    end
    println("-"^68)
    println(" ULTIMATE-LEVEL SNOW LOADS (from ultimate-level pg)")
    println("   Flat roof load    pf    = ", fmt(r.pf), " psf   (Eq. 7.3-1)")
    i.roof_type != :flat &&
        println("   Sloped roof load  ps    = ", fmt(r.ps), " psf   (Eq. 7.4-1)")
    r.ros > 0 && println("   Rain-on-snow surcharge  = ", fmt(r.ros), " psf   (7.10)")
    println("   Balanced load           = ", fmt(r.balanced), " psf")
    r.pm > 0 && println("   Minimum load      pm    = ", fmt(r.pm), " psf   (7.3.3, separate case)")

    if r.unbalanced !== nothing
        u = r.unbalanced
        println("   Unbalanced (7.6.1):")
        println("     Windward              = ", fmt(u.windward), " psf (0.3 ps)")
        println("     Leeward               = ", fmt(u.leeward), " psf + ",
                fmt(u.surcharge), " psf surcharge over ", fmt(u.extent), " ft from ridge")
        println("       (hd = ", fmt(u.hd), " ft, γ = ", fmt(u.γ), " pcf)")
        if u.short_span !== nothing
            println("     Short span (W <= 20)  = windward 0, leeward ",
                    fmt(u.short_span.leeward), " psf")
        end
    end

    println("-"^68)
    println(" DESIGN LEVEL: ", i.method, "  (snow factor = ", f, ")")
    println("   (service-level = ", PG_BASIS[:ASCE7_22].service, " S,  ultimate-level = ",
            PG_BASIS[:ASCE7_22].ultimate, " S)")
    println("   Balanced load           = ", fmt(f * r.balanced), " psf")
    r.pm > 0 && println("   Minimum load      pm    = ", fmt(f * r.pm), " psf")
    if r.unbalanced !== nothing
        u = r.unbalanced
        println("   Unbalanced windward     = ", fmt(f * u.windward), " psf")
        println("   Unbalanced leeward      = ", fmt(f * u.leeward), " psf  (+ ",
                fmt(f * u.surcharge), " psf surcharge)")
        u.short_span !== nothing &&
            println("   Short-span leeward      = ", fmt(f * u.short_span.leeward), " psf")
    end
    for n in r.notes
        println(" * ", n)
    end
    println(line, "\n")
end

# ---------------------------------------------------------------------------
# Interactive input
# ---------------------------------------------------------------------------

function prompt(msg)
    print(msg)
    s = readline()
    eof(stdin) && isempty(s) && error("Input ended unexpectedly.")
    return strip(s)
end

function ask_choice(title, options::Vector{String})
    println("\n", title)
    for (k, o) in enumerate(options)
        println("  ", k, ") ", o)
    end
    while true
        n = tryparse(Int, prompt("Select [1-$(length(options))]: "))
        n !== nothing && 1 <= n <= length(options) && return n
        println("  Invalid selection.")
    end
end

function ask_float(msg; lo = -Inf, hi = Inf)
    while true
        x = tryparse(Float64, prompt(msg))
        x !== nothing && lo <= x <= hi && return x
        println("  Enter a number between $lo and $hi.")
    end
end

function ask_inputs()
    println("Roof Snow Loads (enclosed buildings)")
    code = STANDARDS[ask_choice("Design code / standard:",
                     [string(n[1], n[2] ? "" : "  [not implemented yet]")
                      for (_, n) in STANDARDS])].first
    method = (:ASD, :LRFD)[ask_choice("Design method:", ["ASD", "LRFD"])]
    return ask_inputs(Val(code), method)
end

# ---- ASCE/SEI 7-22 ---------------------------------------------------------
function ask_inputs(::Val{:ASCE7_22}, method)
    roof = (:flat, :gable, :monoslope)[ask_choice("Roof type:",
                ["Flat", "Gable", "Mono-slope"])]

    rc = ask_choice("Risk Category:", ["I", "II", "III", "IV"])
    pg = ask_float("\nUltimate-level ground snow load pg for this Risk Category " *
                   "(psf, ASCE 7-22 Hazard Tool): "; lo = 0)

    terrain = (:B, :C, :D, :T, :A)[ask_choice("Surface roughness category (Table 7.3-1):",
                ["B - urban / suburban / wooded",
                 "C - open terrain, scattered obstructions",
                 "D - flat, unobstructed areas, water surfaces",
                 "Above the tree line in windswept mountainous areas",
                 "Alaska, no trees within a 2-mi radius"])]
    expo_opts = ["Fully exposed", "Partially exposed"]
    terrain in (:B, :C, :D) && push!(expo_opts, "Sheltered")
    exposure = (:fully, :partially, :sheltered)[ask_choice("Roof exposure:", expo_opts)]

    tc = ask_choice("Thermal condition (Table 7.3-2):",
            ["All structures except as indicated below (heated, unventilated roof; Table 7.3-3)",
             "Unheated / open-air / just above freezing / cold ventilated roof (Ct = 1.2)",
             "Freezer building (Ct = 1.3)",
             "Continuously heated greenhouse, R < 2.0 (Ct = 0.85)"])
    ct = if tc == 1
        R = ask_float("Roof thermal resistance R (h·ft²·°F/Btu): "; lo = 0.1)
        ct_heated_unventilated(pg, R)
    else
        (0.0, 1.2, 1.3, 0.85)[tc]
    end

    rise12 = 0.0; W = 0.0; slippery = false; W2 = 0.0
    if roof != :flat
        rise12 = ask_float("\nRoof slope, rise per 12 in. of run (e.g. 4 for 4:12): ";
                           lo = 0.01, hi = 12 * tand(70))
        W = ask_float(roof == :gable ?
                "Horizontal eave-to-ridge distance W (ft): " :
                "Horizontal roof width, eave to high eave W (ft): "; lo = 0.1)
        slippery = ask_choice("Roof surface for Cs (Fig. 7.4-1):",
                ["All other surfaces",
                 "Unobstructed slippery surface (metal, slate, glass, smooth membrane; " *
                 "space below eaves for sliding snow)"]) == 2
        if roof == :gable
            W2 = ask_float("Winter wind parameter W2 (fraction 0-1, Hazard Tool; 0 to skip drift): ";
                           lo = 0, hi = 1)
        end
    else
        W = ask_float("\nHorizontal roof width W for rain-on-snow check (ft): "; lo = 0.1)
    end

    return ASCE7_22Input(; method, roof_type = roof, pg, risk_category = rc, terrain,
                     exposure, Ct = ct, rise12, W, slippery, W2)
end

# ===========================================================================
# ASCE/SEI 7-16  (key :ASCE7_16)   - Chapter 7, Snow Loads
#
# Differences from ASCE 7-22 handled here:
#   * pg is the 50-yr MRI ground snow load (Fig. 7.2-1 / Hazard Tool) and the
#     snow importance factor Is (Table 1.5-2) is applied:  pf = 0.7 Ce Ct Is pg
#   * Ct is a simple 5-value table (no R-value interpolation table)
#   * Cs: slippery-surface curve in the warm-roof chart needs R >= 30 (unvent.)
#     or R >= 20 (ventilated)
#   * pm = Is pg (pg <= 20 psf) or 20 Is
#   * rain-on-snow surcharge 5 psf when pg <= 20 psf
#   * drift height hd = sqrt(Is) (0.43 lu^(1/3) (pg+10)^(1/4) - 1.5), Fig. 7.6-1
#     (no winter wind parameter W2)
#   * short-span gable unbalanced leeward load = Is pg
#   * load factors: LRFD 1.6 S (1.2D + 1.6S), ASD 1.0 S (D + S)
# ===========================================================================

# Table 1.5-2 - snow importance factor Is by Risk Category
const IS_16 = Dict(1 => 0.8, 2 => 1.0, 3 => 1.1, 4 => 1.2)

# Table 7.3-2 - thermal factor Ct
const CT_OPTIONS_16 = [
    ("All structures except as indicated below",                               1.0),
    ("Structures kept just above freezing; cold ventilated roofs, R > 25",     1.1),
    ("Unheated and open-air structures",                                       1.2),
    ("Freezer building",                                                       1.3),
    ("Continuously heated greenhouse, R < 2.0",                                0.85),
]

Base.@kwdef struct ASCE7_16Input <: AbstractSnowInput
    method::Symbol            # :ASD or :LRFD
    roof_type::Symbol         # :flat, :gable, :monoslope
    pg::Float64               # ground snow load (Fig. 7.2-1 / Hazard Tool), psf
    risk_category::Int        # 1-4
    terrain::Symbol           # :B :C :D :T :A
    exposure::Symbol          # :fully :partially :sheltered
    Ct::Float64               # thermal factor (Table 7.3-2)
    rise12::Float64 = 0.0     # roof slope, rise per 12 in. run
    W::Float64 = 0.0          # horizontal eave-to-ridge distance (gable) or
                              # eave-to-high-eave width (mono/flat), ft
    slippery::Bool = false    # unobstructed slippery surface (Cs)
    R_roof::Float64 = 0.0     # roof thermal resistance, h·ft²·°F/Btu (warm slippery roofs)
    ventilated::Bool = false  # ventilated roof (R threshold 20 instead of 30)
end

struct ASCE7_16Result <: AbstractSnowResult
    input::ASCE7_16Input
    theta::Float64
    Is::Float64
    Ce::Float64
    Ct::Float64
    Cs::Float64
    slippery_used::Bool # slippery curve actually applied
    pf::Float64
    pm::Float64
    ps::Float64
    ros::Float64
    balanced::Float64
    unbalanced::Union{Nothing,NamedTuple}
    factor::Float64     # S -> design level: LRFD 1.6 (ultimate), ASD 1.0 (service)
    notes::Vector{String}
end

"Flat roof snow load, Eq. 7.3-1: pf = 0.7 Ce Ct Is pg"
flat_roof_load_16(pg, Ce, Ct, Is) = 0.7 * Ce * Ct * Is * pg

"Minimum snow load pm, Sec. 7.3.4"
minimum_load_16(pg, Is) = pg <= 20 ? Is * pg : 20 * Is

"""
Roof slope factor Cs, Fig. 7.4-1 / Sec. 7.4.1-7.4.2. Cs = 1 up to a threshold
angle, then linear to 0 at 70 deg.
  Ct <= 1.0 : 30 deg other surfaces, 5 deg slippery
  Ct = 1.1  : 37.5 deg other,        10 deg slippery
  Ct >= 1.2 : 45 deg other,          15 deg slippery
"""
function slope_factor_16(theta, Ct, slippery)
    θ0 = if Ct <= 1.0
        slippery ? 5.0 : 30.0
    elseif Ct < 1.2
        slippery ? 10.0 : 37.5
    else
        slippery ? 15.0 : 45.0
    end
    theta <= θ0 && return 1.0
    theta >= 70 && return 0.0
    return (70 - theta) / (70 - θ0)
end

"""
Drift height hd (ft), Fig. 7.6-1: hd = sqrt(Is)(0.43 lu^(1/3) (pg+10)^(1/4) - 1.5),
lu taken as at least 20 ft; for lu < 20 ft hd need not exceed sqrt(Is pg lu / (4γ))
with the actual lu.
"""
function drift_height_16(pg, lu, Is)
    hd = sqrt(Is) * max(0.43 * cbrt(max(lu, 20.0)) * (pg + 10)^0.25 - 1.5, 0.0)
    lu < 20 && (hd = min(hd, sqrt(Is * pg * lu / (4 * snow_density(pg)))))
    return hd
end

make_input(::Val{:ASCE7_16}; kw...) = ASCE7_16Input(; kw...)

"Compute ASCE 7-16 roof snow loads."
function compute_snow(inp::ASCE7_16Input)
    notes = String[]
    haskey(CE_TABLE, (inp.terrain, inp.exposure)) ||
        error("Ce is not permitted for this terrain/exposure combination (Table 7.3-1).")
    Ce = CE_TABLE[(inp.terrain, inp.exposure)]      # Table 7.3-1 unchanged from 7-22
    Is = IS_16[inp.risk_category]
    Ct = inp.Ct
    θ = inp.roof_type == :flat ? 0.0 : slope_deg(inp.rise12)
    factor = design_factor(:ASCE7_16, inp.method)

    pf = flat_roof_load_16(inp.pg, Ce, Ct, Is)

    # 7.4.1: slippery curve for warm roofs only if R is large enough
    slippery = inp.slippery
    if slippery && Ct <= 1.0 && inp.roof_type != :flat
        Rmin = inp.ventilated ? 20.0 : 30.0
        if inp.R_roof < Rmin
            slippery = false
            push!(notes, "Slippery-surface curve not used: warm roof R-value " *
                         "$(inp.R_roof) < $(Rmin) (7.4.1); solid line applied.")
        end
    end
    Cs = inp.roof_type == :flat ? 1.0 : slope_factor_16(θ, Ct, slippery)
    ps = Cs * pf

    # 7.3.4 minimum load (separate case), slopes < 15 deg
    pm = (θ < 15 && inp.pg > 0) ? minimum_load_16(inp.pg, Is) : 0.0
    pm > 0 && push!(notes, "pm is a separate uniform load case (7.3.4); it is not " *
                           "combined with unbalanced, drift, sliding or partial loads.")

    # 7.10 rain-on-snow: 0 < pg <= 20 psf and slope (deg) < W/50
    ros = 0.0
    if 0 < inp.pg <= 20 && inp.W > 0 && θ < inp.W / 50
        ros = 5.0
        push!(notes, "5 psf rain-on-snow surcharge added to the balanced load (7.10); " *
                     "not used with drift, sliding, unbalanced, minimum or partial loads.")
    end
    balanced = ps + ros

    # 7.6.1 unbalanced load, gable roofs
    unb = nothing
    if inp.roof_type == :gable
        inp.W > 0 || error("Gable roofs need the eave-to-ridge horizontal distance W.")
        if 2.38 <= θ <= 30.2
            S = 12 / inp.rise12
            γ = snow_density(inp.pg)
            hd = drift_height_16(inp.pg, inp.W, Is)
            pd = hd * γ / sqrt(S)
            wd = min(8 * hd * sqrt(S) / 3, inp.W)
            unb = (windward = 0.3 * ps, leeward = ps, surcharge = pd,
                   extent = wd, hd = hd, γ = γ, short_span = nothing)
            if inp.W <= 20
                unb = merge(unb, (short_span = (windward = 0.0, leeward = Is * inp.pg),))
                push!(notes, "W <= 20 ft: if members are simply supported prismatic " *
                             "members spanning ridge to eave, design for the leeward " *
                             "uniform load Is*pg with the windward side unloaded (7.6.1) " *
                             "in place of the 0.3ps / ps + surcharge case.")
            end
        else
            push!(notes, "Unbalanced load not required: slope outside " *
                         "2.38 deg (1/2:12) to 30.2 deg (7:12) (7.6.1).")
        end
    end

    return ASCE7_16Result(inp, θ, Is, Ce, Ct, Cs, slippery, pf, pm, ps, ros, balanced,
                          unb, factor, notes)
end

function print_report(r::ASCE7_16Result)
    i = r.input
    f = r.factor
    line = "="^68
    println("\n", line)
    println(" ", uppercase(standard_name(:ASCE7_16)), " ROOF SNOW LOADS  -  ",
            uppercase(String(i.roof_type)), " ROOF, ", i.method)
    println(line)
    println(" Ground snow load  pg      = ", fmt(i.pg), " psf")
    println(" pg basis                  = service-level (50-yr MRI), as given by Fig. 7.2-1 / Hazard Tool")
    println(" Risk Category / Is        = ", i.risk_category, " / ", r.Is)
    println(" Terrain / exposure / Ce   = ", i.terrain, " / ", i.exposure, " / ", r.Ce)
    println(" Thermal factor    Ct      = ", fmt(r.Ct))
    if i.roof_type != :flat
        println(" Roof slope                = ", i.rise12, ":12  (", fmt(r.theta), " deg)")
        println(" Slope factor      Cs      = ", fmt(r.Cs),
                r.slippery_used ? "  (unobstructed slippery surface)" : "")
    end
    println("-"^68)
    println(" SERVICE-LEVEL SNOW LOADS (from service-level pg)")
    println("   Flat roof load    pf    = ", fmt(r.pf), " psf   (Eq. 7.3-1)")
    i.roof_type != :flat &&
        println("   Sloped roof load  ps    = ", fmt(r.ps), " psf   (Eq. 7.4-1)")
    r.ros > 0 && println("   Rain-on-snow surcharge  = ", fmt(r.ros), " psf   (7.10)")
    println("   Balanced load           = ", fmt(r.balanced), " psf")
    r.pm > 0 && println("   Minimum load      pm    = ", fmt(r.pm), " psf   (7.3.4, separate case)")
    if r.unbalanced !== nothing
        u = r.unbalanced
        println("   Unbalanced (7.6.1):")
        println("     Windward              = ", fmt(u.windward), " psf (0.3 ps)")
        println("     Leeward               = ", fmt(u.leeward), " psf + ",
                fmt(u.surcharge), " psf surcharge over ", fmt(u.extent), " ft from ridge")
        println("       (hd = ", fmt(u.hd), " ft, γ = ", fmt(u.γ), " pcf)")
        u.short_span !== nothing &&
            println("     Short span (W <= 20)  = windward 0, leeward ",
                    fmt(u.short_span.leeward), " psf")
    end
    println("-"^68)
    println(" DESIGN LEVEL: ", i.method, "  (snow factor = ", f, ")")
    println("   (service-level = ", PG_BASIS[:ASCE7_16].service, " S,  ultimate-level = ",
            PG_BASIS[:ASCE7_16].ultimate, " S)")
    println("   Balanced load           = ", fmt(f * r.balanced), " psf")
    r.pm > 0 && println("   Minimum load      pm    = ", fmt(f * r.pm), " psf")
    if r.unbalanced !== nothing
        u = r.unbalanced
        println("   Unbalanced windward     = ", fmt(f * u.windward), " psf")
        println("   Unbalanced leeward      = ", fmt(f * u.leeward), " psf  (+ ",
                fmt(f * u.surcharge), " psf surcharge)")
        u.short_span !== nothing &&
            println("   Short-span leeward      = ", fmt(f * u.short_span.leeward), " psf")
    end
    for n in r.notes
        println(" * ", n)
    end
    println(line, "\n")
end

function ask_inputs(::Val{:ASCE7_16}, method)
    roof = (:flat, :gable, :monoslope)[ask_choice("Roof type:",
                ["Flat", "Gable", "Mono-slope"])]
    rc = ask_choice("Risk Category:", ["I", "II", "III", "IV"])
    pg = ask_float("\nService-level (50-yr) ground snow load pg (psf, ASCE 7-16 " *
                   "Fig. 7.2-1 / Hazard Tool): "; lo = 0)

    terrain = (:B, :C, :D, :T, :A)[ask_choice("Surface roughness category (Table 7.3-1):",
                ["B - urban / suburban / wooded",
                 "C - open terrain, scattered obstructions",
                 "D - flat, unobstructed areas, water surfaces",
                 "Above the tree line in windswept mountainous areas",
                 "Alaska, no trees within a 2-mi radius"])]
    expo_opts = ["Fully exposed", "Partially exposed"]
    terrain in (:B, :C, :D) && push!(expo_opts, "Sheltered")
    exposure = (:fully, :partially, :sheltered)[ask_choice("Roof exposure:", expo_opts)]

    ct = CT_OPTIONS_16[ask_choice("Thermal condition (Table 7.3-2):",
            [o[1] for o in CT_OPTIONS_16])][2]

    rise12 = 0.0; W = 0.0; slippery = false; R = 0.0; vent = false
    if roof != :flat
        rise12 = ask_float("\nRoof slope, rise per 12 in. of run (e.g. 4 for 4:12): ";
                           lo = 0.01, hi = 12 * tand(70))
        W = ask_float(roof == :gable ?
                "Horizontal eave-to-ridge distance W (ft): " :
                "Horizontal roof width, eave to high eave W (ft): "; lo = 0.1)
        slippery = ask_choice("Roof surface for Cs (Fig. 7.4-1):",
                ["All other surfaces",
                 "Unobstructed slippery surface (metal, slate, glass, smooth membrane; " *
                 "space below eaves for sliding snow)"]) == 2
        if slippery && ct <= 1.0
            vent = ask_choice("Roof ventilation:", ["Unventilated", "Ventilated"]) == 2
            R = ask_float("Roof thermal resistance R (h·ft²·°F/Btu): "; lo = 0)
        end
    else
        W = ask_float("\nHorizontal roof width W for rain-on-snow check (ft): "; lo = 0.1)
    end

    return ASCE7_16Input(; method, roof_type = roof, pg, risk_category = rc, terrain,
                         exposure, Ct = ct, rise12, W, slippery, R_roof = R, ventilated = vent)
end

function main()
    local inp
    try
        inp = ask_inputs()
    catch e
        e isa ErrorException || rethrow()
        println("
", e.msg)
        return nothing
    end
    result = compute_snow(inp)
    print_report(result)
    return result
end

end # module
