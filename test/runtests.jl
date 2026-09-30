using Test

using SnowLoads
const SL = SnowLoads
const PKGDIR = normpath(joinpath(@__DIR__, ".."))

# Baseline input; individual tests override fields.
function inp(; kw...)
    base = (method = :LRFD, roof_type = :gable, pg = 30.0, risk_category = 2,
            terrain = :B, exposure = :partially, Ct = 1.0, rise12 = 6.0, W = 30.0,
            slippery = false, W2 = 0.55)
    SL.ASCE7_22Input(; merge(base, kw)...)
end
calc(; kw...) = SL.compute_snow(inp(; kw...))

# Run the interactive script as a subprocess with scripted stdin.
fmt_answer(x) = x isa AbstractFloat && isinteger(x) ? string(Int(x)) : string(x)
function run_script(answers::Vector)
    out = IOBuffer()
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$PKGDIR -e "using SnowLoads; SnowLoads.main()"`
    run(pipeline(cmd; stdin = IOBuffer(join(fmt_answer.(answers), "\n") * "\n"),
                 stdout = out, stderr = out))
    String(take!(out))
end
function report_text(r)
    mktemp() do path, io
        redirect_stdout(io) do
            SL.print_report(r)
        end
        close(io)
        read(path, String)
    end
end

@testset "SnowLoads (ASCE 7-22)" begin

@testset "Table 7.3-1  Ce" begin
    expected = Dict(
        (:B, :fully) => 0.9, (:B, :partially) => 1.0, (:B, :sheltered) => 1.2,
        (:C, :fully) => 0.9, (:C, :partially) => 1.0, (:C, :sheltered) => 1.1,
        (:D, :fully) => 0.8, (:D, :partially) => 0.9, (:D, :sheltered) => 1.0,
        (:T, :fully) => 0.7, (:T, :partially) => 0.8,
        (:A, :fully) => 0.7, (:A, :partially) => 0.8)
    for ((t, e), ce) in expected
        r = calc(terrain = t, exposure = e, Ct = 1.0, rise12 = 0.0, roof_type = :flat)
        @test r.Ce == ce
        @test r.pf ≈ 0.7 * ce * 1.0 * 30.0          # Eq. 7.3-1
    end
    # "N/A" cells must be rejected
    @test_throws ErrorException calc(terrain = :T, exposure = :sheltered)
    @test_throws ErrorException calc(terrain = :A, exposure = :sheltered)
end

@testset "Table 7.3-3  Ct interpolation" begin
    ct = SL.ct_heated_unventilated
    # every tabulated node
    for (i, R) in enumerate(SL.CT33_R), (j, pg) in enumerate(SL.CT33_PG)
        @test ct(pg, R) ≈ SL.CT33[i, j]
    end
    @test ct(30, 30) ≈ 1.14                          # code commentary Example 1
    @test ct(25, 30) ≈ (1.17 + 1.14) / 2             # linear in pg
    @test ct(30, 25) ≈ (1.05 + 1.14) / 2             # linear in R
    @test ct(25, 25) ≈ (1.11 + 1.17 + 1.05 + 1.14) / 4   # bilinear center
    @test ct(30, 10) ≈ ct(30, 20)                    # R <= 20 clamps to first row
    @test ct(5, 30) ≈ ct(10, 30)                     # pg <= 10 clamps
    @test ct(100, 30) ≈ ct(70, 30)                   # pg >= 70 clamps
    @test ct(30, 60) == 1.2                          # R > 50 -> 1.2
    @test ct(30, 50) ≈ 1.19                          # R = 50 still tabulated
    # results always inside the physical band 1.0..1.2
    for pg in 0:5:120, R in (5, 20, 33, 47, 50, 80)
        @test 1.0 <= ct(pg, R) <= 1.2
    end
end

@testset "Fig. 7.4-1  Cs" begin
    cs = SL.slope_factor
    # Ct <= 1.1: 30 deg break, slippery irrelevant
    for slip in (false, true)
        @test cs(0, 1.0, slip) == 1.0
        @test cs(30, 1.0, slip) == 1.0
        @test cs(50, 1.0, slip) ≈ 0.5
        @test cs(70, 1.0, slip) == 0.0
        @test cs(85, 1.0, slip) == 0.0
    end
    @test cs(50, 0.85, false) ≈ 0.5                  # greenhouse falls in 7.4-1a
    @test cs(50, 1.1, true)  ≈ 0.5                   # Ct = 1.1 is still chart (a)
    # 1.1 < Ct < 1.2
    @test cs(37.5, 1.15, false) == 1.0
    @test cs(53.75, 1.15, false) ≈ 0.5
    @test cs(10, 1.15, true) == 1.0
    @test cs(40, 1.15, true) ≈ 0.5
    # Ct >= 1.2
    for ct in (1.2, 1.3)
        @test cs(45, ct, false) == 1.0
        @test cs(57.5, ct, false) ≈ 0.5
        @test cs(15, ct, true) == 1.0
        @test cs(42.5, ct, true) ≈ 0.5
    end
    # monotone non-increasing in slope, within [0,1]
    for ct in (1.0, 1.15, 1.2), slip in (false, true)
        v = [cs(θ, ct, slip) for θ in 0:0.5:90]
        @test all(0 .<= v .<= 1)
        @test issorted(v; rev = true)
    end
    # slippery never carries more snow than non-slippery
    for θ in 0:90, ct in (1.0, 1.15, 1.2)
        @test cs(θ, ct, true) <= cs(θ, ct, false) + 1e-12
    end
end

@testset "Flat roof" begin
    r = calc(roof_type = :flat, pg = 40, terrain = :C, exposure = :fully, Ct = 1.2, W = 100)
    @test r.theta == 0 && r.Cs == 1.0
    @test r.pf ≈ 0.7 * 0.9 * 1.2 * 40                # 30.24
    @test r.ps ≈ r.pf
    @test r.pm ≈ 30.0                                # pg 40 > pm,max(RC II)=30
    @test r.ros == 0.0                               # pg 40 > 30 -> no surcharge
    @test r.balanced ≈ 30.24
    @test r.unbalanced === nothing
    # pm = pg when pg is small
    r = calc(roof_type = :flat, pg = 12, Ct = 1.0, W = 10)
    @test r.pm ≈ 12
    # pg == 0 : everything is zero, no pm, no surcharge
    r = calc(roof_type = :flat, pg = 0, W = 100)
    @test r.pf == 0 && r.pm == 0 && r.ros == 0 && r.balanced == 0
    # slope input is ignored for flat roofs
    r = calc(roof_type = :flat, rise12 = 9.0)
    @test r.theta == 0 && r.Cs == 1.0
    # linear in pg
    a = calc(roof_type = :flat, pg = 20, W = 5).pf
    b = calc(roof_type = :flat, pg = 40, W = 5).pf
    @test b ≈ 2a
end

@testset "Table 7.3-4 / 7.3.3  minimum load pm" begin
    for (rc, pmax) in ((1, 25.0), (2, 30.0), (3, 35.0), (4, 40.0))
        @test SL.minimum_load(pmax - 5, rc) ≈ pmax - 5    # below limit: pm = pg
        @test SL.minimum_load(pmax, rc) ≈ pmax
        @test SL.minimum_load(pmax + 50, rc) ≈ pmax       # above limit: pm = pm,max
        r = calc(roof_type = :flat, pg = 200, risk_category = rc)
        @test r.pm ≈ pmax
    end
    # applies only for slope < 15 deg
    rise15 = 12 * tand(15)
    @test calc(roof_type = :monoslope, rise12 = rise15 - 0.01).pm > 0
    @test calc(roof_type = :monoslope, rise12 = rise15 + 0.01).pm == 0
    @test calc(roof_type = :gable, rise12 = 3.0).pm > 0        # 14.04 deg
    @test calc(roof_type = :gable, rise12 = 4.0).pm == 0       # 18.4 deg
end

@testset "7.10  rain-on-snow surcharge" begin
    # limit is pm,max of the Risk Category
    @test calc(roof_type = :flat, pg = 25, risk_category = 1, W = 100).ros == 8.0
    @test calc(roof_type = :flat, pg = 25.1, risk_category = 1, W = 100).ros == 0.0
    @test calc(roof_type = :flat, pg = 40, risk_category = 4, W = 100).ros == 8.0
    @test calc(roof_type = :flat, pg = 40.1, risk_category = 4, W = 100).ros == 0.0
    @test calc(roof_type = :flat, pg = 0, W = 100).ros == 0.0
    # slope (deg) < W/50
    @test calc(roof_type = :gable, pg = 20, W = 100, rise12 = 0.4).ros == 8.0   # 1.91 < 2
    @test calc(roof_type = :gable, pg = 20, W = 100, rise12 = 0.5).ros == 0.0   # 2.39 > 2
    # commentary Example 1: 26.6 deg vs W/50 = 0.6 -> none
    @test calc().ros == 0.0
    # added to balanced load only; pm stays separate
    r = calc(roof_type = :flat, pg = 15, Ct = 1.2, terrain = :B, exposure = :fully, W = 100)
    @test r.ros == 8.0
    @test r.balanced ≈ r.ps + 8.0
    @test r.pm ≈ 15.0
end

@testset "Sloped roofs (mono-slope)" begin
    # warm roof, steep slope reduces load: theta = 50 deg -> Cs = 0.5
    rise = 12 * tand(50)
    r = calc(roof_type = :monoslope, Ct = 1.0, rise12 = rise, pg = 40, terrain = :C,
             exposure = :fully, W = 30)
    @test r.theta ≈ 50
    @test r.Cs ≈ 0.5
    @test r.ps ≈ 0.5 * r.pf
    @test r.pf ≈ 0.7 * 0.9 * 40
    @test r.unbalanced === nothing                   # only hip / gable have 7.6.1
    @test r.pm == 0
    # slippery, Ct = 1.2, 42.5 deg -> 0.5
    r = calc(roof_type = :monoslope, Ct = 1.2, slippery = true, rise12 = 12 * tand(42.5))
    @test r.Cs ≈ 0.5
    # roof of 70+ deg carries no snow
    r = calc(roof_type = :monoslope, rise12 = 12 * tand(75))
    @test r.Cs == 0 && r.ps == 0 && r.balanced == 0
    # low-slope mono: pm applies
    r = calc(roof_type = :monoslope, rise12 = 1.0, pg = 50, W = 60)
    @test r.Cs == 1.0 && r.pm == 30
end

@testset "7.6.1  gable unbalanced load" begin
    # Commentary Example 1 (pg=30, W2=0.55, 6:12, W=30, R=30 unventilated)
    ct = SL.ct_heated_unventilated(30, 30)
    r = calc(Ct = ct)
    @test r.pf ≈ 23.9  atol = 0.05
    @test r.ps ≈ 23.9  atol = 0.05
    u = r.unbalanced
    @test u.γ ≈ 17.9 atol = 0.01
    @test u.hd ≈ 2.46 atol = 0.02
    @test u.surcharge ≈ 31.1 atol = 0.3
    @test u.extent ≈ 9.3 atol = 0.05
    @test u.windward ≈ 0.3 * r.ps
    @test u.leeward ≈ r.ps
    # independent evaluation of Eq. 7.6-1 / 7.7-1
    γ = 0.13 * 30 + 14
    hd = 1.5 * sqrt(30^0.74 * 30^0.70 * 0.55^1.7 / γ)
    @test u.hd ≈ hd
    @test u.surcharge ≈ hd * γ / sqrt(12 / 6)
    @test u.extent ≈ 8 * hd * sqrt(12 / 6) / 3

    # slope window 2.38 .. 30.2 deg
    @test calc(rise12 = 0.49).unbalanced === nothing        # 2.34 deg
    @test calc(rise12 = 0.50).unbalanced !== nothing        # 2.39 deg
    @test calc(rise12 = 6.9).unbalanced !== nothing         # 29.9 deg
    @test calc(rise12 = 7.0).unbalanced === nothing         # 30.26 deg
    @test calc(rise12 = 12.0).unbalanced === nothing

    # snow density cap at 30 pcf
    @test SL.snow_density(200) == 30.0
    @test SL.snow_density(30) ≈ 17.9
    @test calc(pg = 200, W2 = 0.5).unbalanced.γ == 30.0

    # W2 = 0 : no surcharge, note emitted
    r = calc(W2 = 0.0)
    @test r.unbalanced.hd == 0 && r.unbalanced.surcharge == 0 && r.unbalanced.extent == 0
    @test any(occursin("W2", n) for n in r.notes)

    # surcharge extent is truncated at the leeward length W
    r = calc(W = 30.0, W2 = 1.0, pg = 150, rise12 = 6.0)
    @test r.unbalanced.extent <= 30.0

    # short-span alternative only for W <= 20 ft
    @test calc(W = 20.0).unbalanced.short_span == (windward = 0.0, leeward = 30.0)
    @test calc(W = 20.01).unbalanced.short_span === nothing
    @test any(occursin("W <= 20", n) for n in calc(W = 15.0).notes)

    # drift grows with W2, pg and W
    h(; kw...) = calc(; kw...).unbalanced.hd
    @test h(W2 = 0.3) < h(W2 = 0.6)
    @test h(W = 20.0) < h(W = 40.0)
    @test h(pg = 20.0) < h(pg = 40.0)

    # missing W is an error for gable roofs
    @test_throws ErrorException calc(W = 0.0)
end

@testset "Design level ASD / LRFD" begin
    @test calc(method = :LRFD).factor == 1.0
    @test calc(method = :ASD).factor == 0.7
    a, l = calc(method = :ASD), calc(method = :LRFD)
    # nominal loads are independent of the design method
    @test a.pf == l.pf && a.ps == l.ps && a.balanced == l.balanced
    @test a.unbalanced == l.unbalanced
    ta, tl = report_text(a), report_text(l)
    @test occursin("snow factor = 0.7", ta)
    @test occursin("snow factor = 1.0", tl)
    # design balanced value printed = factor * balanced
    @test occursin(SL.fmt(0.7 * a.balanced), ta)
    @test occursin(SL.fmt(1.0 * l.balanced), tl)
    # no dead-load output anywhere
    @test !occursin("dead", lowercase(ta)) && !occursin("1.2D", ta)
end

@testset "Report output for every roof path" begin
    cases = [
        calc(roof_type = :flat, pg = 15, W = 100),                       # ROS + pm
        calc(roof_type = :flat, pg = 60, W = 100),                       # pm only
        calc(roof_type = :monoslope, rise12 = 2.0, pg = 20, W = 40),
        calc(roof_type = :monoslope, rise12 = 8.0, pg = 50, slippery = true),
        calc(roof_type = :gable, rise12 = 4.0, W = 15.0),                # short span
        calc(roof_type = :gable, rise12 = 4.0, W = 40.0),
        calc(roof_type = :gable, rise12 = 0.2, W = 40.0),                # no unbalanced
        calc(roof_type = :gable, rise12 = 10.0, W = 40.0, slippery = true),
    ]
    for r in cases, m in (:ASD, :LRFD)
        t = report_text(SL.compute_snow(SL.ASCE7_22Input(; (k => getfield(r.input, k)
                for k in fieldnames(SL.ASCE7_22Input) if k != :method)..., method = m)))
        @test occursin("ROOF SNOW LOADS", t)
        @test occursin("ASCE/SEI 7-22", t)
        @test !occursin("NaN", t) && !occursin("Inf", t)
    end
end

@testset "Sanity: physical consistency" begin
    for rc in 1:4, pg in (0, 10, 25, 60, 150), rise in (0.0, 0.3, 2, 4, 8, 12, 30),
        terrain in (:B, :C, :D), exp in (:fully, :partially, :sheltered),
        ct in (0.85, 1.0, 1.15, 1.2, 1.3), slip in (false, true), roof in (:flat, :gable, :monoslope)
        (roof != :flat && rise == 0.0) && continue
        r = calc(risk_category = rc, pg = pg, rise12 = rise == 0.0 ? 0.01 : rise,
                 terrain = terrain, exposure = exp, Ct = ct, slippery = slip,
                 roof_type = roof, W = 35.0, W2 = 0.4)
        @test isfinite(r.pf) && isfinite(r.ps) && isfinite(r.balanced)
        @test r.pf >= 0 && r.ps >= 0
        @test r.ps <= r.pf + 1e-12                    # slope never adds snow
        @test r.balanced ≈ r.ps + r.ros
        @test 0 <= r.pm <= SL.PM_MAX[rc]
        @test r.pm <= pg + 1e-12
        if r.unbalanced !== nothing
            u = r.unbalanced
            @test u.windward ≈ 0.3 * r.ps
            @test u.surcharge >= 0 && 0 <= u.extent <= 35.0
        end
    end
end

@testset "Standards registry and dispatch" begin
    @test SL.is_implemented(:ASCE7_22) && SL.is_implemented(:ASCE7_16)
    @test SL.standard_name(:ASCE7_22) == "ASCE/SEI 7-22 (USA)"
    @test length(SL.STANDARDS) >= 10
    @test allunique(first.(SL.STANDARDS))
    # the symbol entry point builds the ASCE 7-22 input and gives the same result
    kw = (method = :ASD, roof_type = :gable, pg = 30.0, risk_category = 2,
          terrain = :B, exposure = :partially, Ct = 1.14, rise12 = 6.0, W = 30.0, W2 = 0.55)
    r = SL.compute_snow(:ASCE7_22; kw...)
    @test r isa SL.ASCE7_22Result && r isa SL.AbstractSnowResult
    @test r.input isa SL.ASCE7_22Input && r.input isa SL.AbstractSnowInput
    @test r.ps == SL.compute_snow(SL.ASCE7_22Input(; kw...)).ps
    @test SL.make_input(Val(:ASCE7_22); kw...) isa SL.ASCE7_22Input
    # unknown key
    @test_throws KeyError SL.standard_name(:NOPE)
end

@testset "Unimplemented standards" begin
    for (key, (name, implemented)) in SL.STANDARDS
        key in (:ASCE7_22, :ASCE7_16) && continue
        @test !implemented
        @test !SL.is_implemented(key)
        @test SL.standard_name(key) == name
        for f in (() -> SL.compute_snow(key; method = :ASD, roof_type = :flat, pg = 20.0),
                  () -> SL.make_input(Val(key)),
                  () -> SL.ask_inputs(Val(key), :ASD))
            e = try f(); nothing catch ex; ex end
            @test e isa ErrorException && occursin("not implemented yet", e.msg)
            @test occursin(name, e.msg)
        end
    end
end

@testset "ASCE 7-16 code path" begin
    c16(; kw...) = SL.compute_snow(:ASCE7_16; merge((method = :LRFD, roof_type = :gable,
        pg = 30.0, risk_category = 2, terrain = :B, exposure = :partially, Ct = 1.0,
        rise12 = 6.0, W = 30.0), NamedTuple(kw))...)

    @testset "tables" begin
        @test SL.IS_16 == Dict(1 => 0.8, 2 => 1.0, 3 => 1.1, 4 => 1.2)
        @test [c[2] for c in SL.CT_OPTIONS_16] == [1.0, 1.1, 1.2, 1.3, 0.85]
        for rc in 1:4
            r = c16(roof_type = :flat, risk_category = rc, pg = 40.0, W = 10.0)
            @test r.Is == SL.IS_16[rc]
            @test r.pf ≈ 0.7 * 1.0 * 1.0 * SL.IS_16[rc] * 40.0       # Eq. 7.3-1 with Is
        end
        # Ce same table as 7-22, N/A cells rejected
        @test c16(terrain = :D, exposure = :sheltered).Ce == 1.0
        @test_throws ErrorException c16(terrain = :T, exposure = :sheltered)
    end

    @testset "commentary Example 1 (Hartford, pg=30, 6:12, W=30)" begin
        r = c16()
        @test r.pf ≈ 21.0 && r.ps ≈ 21.0 && r.Cs == 1.0 && r.pm == 0 && r.ros == 0
        u = r.unbalanced
        @test u.hd ≈ 1.86 atol = 0.01
        @test u.γ ≈ 17.9 atol = 0.01
        @test u.windward ≈ 6.3
        @test u.surcharge ≈ 23.5 atol = 0.1
        @test u.extent ≈ 7.0 atol = 0.05
    end

    @testset "commentary Example 2 (theater, pg=25, RC III, Ce=0.9)" begin
        r = c16(roof_type = :flat, pg = 25.0, risk_category = 3, exposure = :fully, W = 80.0)
        @test r.pf ≈ 0.7 * 0.9 * 1.0 * 1.1 * 25
        @test r.pf ≈ 17 atol = 0.5
        # Cs at a 41 deg slope = 0.72
        @test SL.slope_factor_16(41, 1.0, false) ≈ 0.72 atol = 0.01   # 0.725, rounded in commentary
        @test SL.slope_factor_16(30, 1.0, false) == 1.0
    end

    @testset "Cs charts (Fig. 7.4-1)" begin
        cs = SL.slope_factor_16
        # Ct <= 1.0: 30 deg / slippery 5 deg
        @test cs(30, 1.0, false) == 1.0 && cs(50, 1.0, false) ≈ 0.5
        @test cs(5, 1.0, true) == 1.0 && cs(37.5, 1.0, true) ≈ 0.5
        @test cs(50, 0.85, false) ≈ 0.5
        # Ct = 1.1: 37.5 / slippery 10
        @test cs(37.5, 1.1, false) == 1.0 && cs(53.75, 1.1, false) ≈ 0.5
        @test cs(10, 1.1, true) == 1.0 && cs(40, 1.1, true) ≈ 0.5
        # Ct >= 1.2: 45 / slippery 15
        for ct in (1.2, 1.3)
            @test cs(45, ct, false) == 1.0 && cs(57.5, ct, false) ≈ 0.5
            @test cs(15, ct, true) == 1.0 && cs(42.5, ct, true) ≈ 0.5
        end
        @test cs(70, 1.0, false) == 0 && cs(85, 1.2, true) == 0
        for ct in (1.0, 1.1, 1.2), slip in (false, true)
            v = [cs(θ, ct, slip) for θ in 0:0.5:90]
            @test all(0 .<= v .<= 1) && issorted(v; rev = true)
        end
    end

    @testset "warm-roof slippery R-value rule (7.4.1)" begin
        steep = 12 * tand(40)
        unvent30 = c16(roof_type = :monoslope, rise12 = steep, slippery = true, R_roof = 30.0)
        @test unvent30.Cs ≈ SL.slope_factor_16(40, 1.0, true)
        unvent29 = c16(roof_type = :monoslope, rise12 = steep, slippery = true, R_roof = 29.0)
        @test unvent29.Cs ≈ SL.slope_factor_16(40, 1.0, false)      # falls back to solid line
        @test any(occursin("R-value", n) for n in unvent29.notes)
        vent20 = c16(roof_type = :monoslope, rise12 = steep, slippery = true,
                     R_roof = 20.0, ventilated = true)
        @test vent20.Cs ≈ SL.slope_factor_16(40, 1.0, true)
        vent19 = c16(roof_type = :monoslope, rise12 = steep, slippery = true,
                     R_roof = 19.0, ventilated = true)
        @test vent19.Cs ≈ SL.slope_factor_16(40, 1.0, false)
        # cold roofs: no R requirement
        cold = c16(roof_type = :monoslope, rise12 = steep, slippery = true, Ct = 1.2)
        @test cold.Cs ≈ SL.slope_factor_16(40, 1.2, true)
    end

    @testset "pm and rain-on-snow" begin
        # pm = Is pg (pg <= 20), 20 Is otherwise
        @test SL.minimum_load_16(15, 1.2) ≈ 18
        @test SL.minimum_load_16(20, 1.1) ≈ 22
        @test SL.minimum_load_16(60, 1.2) ≈ 24
        @test c16(roof_type = :flat, pg = 60.0, risk_category = 4, W = 50.0).pm ≈ 24
        @test c16(roof_type = :monoslope, rise12 = 4.0).pm == 0     # 18.4 deg
        @test c16(roof_type = :monoslope, rise12 = 2.0).pm > 0
        # 5 psf, pg <= 20 only (not pm,max as in 7-22)
        @test c16(roof_type = :flat, pg = 20.0, W = 100.0).ros == 5.0
        @test c16(roof_type = :flat, pg = 20.1, W = 100.0).ros == 0.0
        @test c16(roof_type = :flat, pg = 0.0, W = 100.0).ros == 0.0
        @test c16(roof_type = :gable, pg = 15.0, W = 100.0, rise12 = 0.4).ros == 5.0
        @test c16(roof_type = :gable, pg = 15.0, W = 100.0, rise12 = 0.5).ros == 0.0
    end

    @testset "unbalanced gable (7.6.1, Fig. 7.6-1)" begin
        # independent evaluation of the drift equation
        hd(pg, lu, Is) = sqrt(Is) * (0.43 * cbrt(lu) * (pg + 10)^0.25 - 1.5)
        @test SL.drift_height_16(30, 30, 1.0) ≈ hd(30, 30, 1.0)
        @test SL.drift_height_16(50, 120, 1.2) ≈ hd(50, 120, 1.2)
        @test SL.drift_height_16(50, 700, 1.0) ≈ hd(50, 700, 1.0)   # > 600 ft: equation
        # lu < 20 ft: evaluated at 20 ft but capped at sqrt(Is pg lu/(4γ))
        γ = SL.snow_density(30)
        @test SL.drift_height_16(30, 10, 1.0) ≈ min(hd(30, 20, 1.0), sqrt(30 * 10 / (4γ)))
        @test all(SL.drift_height_16(pg, lu, Is) >= 0 for pg in (0, 5, 30, 150),
                  lu in (1, 10, 20, 100, 700), Is in (0.8, 1.0, 1.2))
        # Is enters the drift height as sqrt(Is)
        @test SL.drift_height_16(30, 30, 1.2) ≈ sqrt(1.2) * SL.drift_height_16(30, 30, 1.0)
        # slope window and short-span alternative
        @test c16(rise12 = 0.49).unbalanced === nothing
        @test c16(rise12 = 0.50).unbalanced !== nothing
        @test c16(rise12 = 6.9).unbalanced !== nothing
        @test c16(rise12 = 7.0).unbalanced === nothing
        @test c16(W = 20.0, risk_category = 3).unbalanced.short_span ==
              (windward = 0.0, leeward = 1.1 * 30.0)                # Is * pg
        @test c16(W = 20.01).unbalanced.short_span === nothing
        @test c16(roof_type = :monoslope).unbalanced === nothing
        @test c16(W = 30.0, pg = 150.0, risk_category = 4, rise12 = 6.0).unbalanced.extent <= 30.0
        @test_throws ErrorException c16(W = 0.0)
    end

    @testset "ASD / LRFD factors and report" begin
        @test c16(method = :LRFD).factor == 1.6
        @test c16(method = :ASD).factor == 1.0
        a, l = c16(method = :ASD), c16(method = :LRFD)
        @test a.pf == l.pf && a.unbalanced == l.unbalanced
        tl = report_text(l)
        @test occursin("ASCE/SEI 7-16", tl) && occursin("snow factor = 1.6", tl)
        @test occursin(SL.fmt(1.6 * l.balanced), tl)
        @test occursin("snow factor = 1.0", report_text(a))
    end

    @testset "sanity sweep" begin
        for rc in 1:4, pg in (0, 10, 20, 25, 80), rise in (0.3, 2, 4, 8, 12, 30),
            ct in (0.85, 1.0, 1.1, 1.2, 1.3), slip in (false, true),
            roof in (:flat, :gable, :monoslope), vent in (false, true)
            r = c16(risk_category = rc, pg = Float64(pg), rise12 = Float64(rise), Ct = ct,
                    slippery = slip, roof_type = roof, W = 35.0, R_roof = 25.0, ventilated = vent)
            @test isfinite(r.pf) && isfinite(r.ps) && isfinite(r.balanced)
            @test r.ps <= r.pf + 1e-12 && r.pf >= 0
            @test r.balanced ≈ r.ps + r.ros
            @test 0 <= r.pm <= 20 * SL.IS_16[rc] + 1e-12
            if r.unbalanced !== nothing
                @test r.unbalanced.surcharge >= 0 && 0 <= r.unbalanced.extent <= 35.0
            end
        end
    end
end

@testset "7-16 vs 7-22 sanity" begin
    # Risk Category II, Ct = 1: Is = 1, so the flat roof loads coincide
    kw = (method = :ASD, roof_type = :flat, pg = 25.0, risk_category = 2,
          terrain = :C, exposure = :partially, Ct = 1.0, W = 50.0)
    a = SL.compute_snow(:ASCE7_16; kw...)
    b = SL.compute_snow(:ASCE7_22; kw...)
    @test a.pf ≈ b.pf
    # code-specific rain-on-snow rules: 7-16 needs pg <= 20 psf; 7-22 needs pg <= pm,max
    @test a.ros == 0.0 && b.ros == 8.0
    # LRFD snow factor differs: 1.6 (7-16) vs 1.0 (7-22)
    @test SL.compute_snow(:ASCE7_16; kw..., method = :LRFD).factor == 1.6
    @test SL.compute_snow(:ASCE7_22; kw..., method = :LRFD).factor == 1.0
end

@testset "pg load level: service (7-16) vs ultimate (7-22)" begin
    @test SL.PG_BASIS[:ASCE7_16].level == :service
    @test SL.PG_BASIS[:ASCE7_22].level == :ultimate
    # design factor per (standard, method)
    @test SL.design_factor(:ASCE7_16, :ASD)  == 1.0
    @test SL.design_factor(:ASCE7_16, :LRFD) == 1.6
    @test SL.design_factor(:ASCE7_22, :ASD)  == 0.7
    @test SL.design_factor(:ASCE7_22, :LRFD) == 1.0
    @test_throws ErrorException SL.design_factor(:ASCE7_22, :WSD)

    kw = (roof_type = :flat, pg = 40.0, risk_category = 2, terrain = :C,
          exposure = :partially, Ct = 1.0, W = 60.0)
    for code in (:ASCE7_16, :ASCE7_22)
        a = SL.compute_snow(code; kw..., method = :ASD)
        l = SL.compute_snow(code; kw..., method = :LRFD)
        S = a.balanced
        @test l.balanced == S                              # S itself does not depend on method
        b = SL.PG_BASIS[code]
        @test a.factor * S ≈ b.service * S
        @test l.factor * S ≈ b.ultimate * S
    end

    # 7-16 (service pg): ultimate is 1.6x the service-level load, ASD = service
    a16 = SL.compute_snow(:ASCE7_16; kw..., method = :ASD)
    l16 = SL.compute_snow(:ASCE7_16; kw..., method = :LRFD)
    @test l16.factor / a16.factor ≈ 1.6
    @test a16.factor * a16.pf ≈ a16.pf                     # ASD design load = pf
    @test l16.factor * l16.pf ≈ 1.6 * 0.7 * 1.0 * 1.0 * 1.0 * 40   # 1.6 * 0.7 Ce Ct Is pg (Ce = 1.0, terrain C partial)

    # 7-22 (ultimate pg): LRFD = pf, service-level (ASD) = 0.7 pf
    a22 = SL.compute_snow(:ASCE7_22; kw..., method = :ASD)
    l22 = SL.compute_snow(:ASCE7_22; kw..., method = :LRFD)
    @test l22.factor * l22.pf ≈ 0.7 * 1.0 * 1.0 * 40       # pf
    @test a22.factor * a22.pf ≈ 0.7 * (0.7 * 1.0 * 1.0 * 40)
    @test a22.factor / l22.factor ≈ 0.7

    # same numerical pg and Is = 1: the two codes give different design loads
    # 7-16 LRFD 1.6 pf  vs  7-22 LRFD 1.0 pf ; 7-16 ASD 1.0 pf vs 7-22 ASD 0.7 pf
    @test l16.factor * l16.pf / (l22.factor * l22.pf) ≈ 1.6
    @test a16.factor * a16.pf / (a22.factor * a22.pf) ≈ 1 / 0.7

    # reports state the basis and the conversion
    t16, t22 = report_text(l16), report_text(l22)
    @test occursin("service-level (50-yr MRI)", t16) && occursin("SERVICE-LEVEL SNOW LOADS", t16)
    @test occursin("ultimate-level (risk-targeted)", t22) && occursin("ULTIMATE-LEVEL SNOW LOADS", t22)
    @test occursin("ultimate-level = 1.6 S", t16)
    @test occursin("service-level = 0.7 S", t22)
end

@testset "Interactive script (stdin driven)" begin
    # answers: code, method, roof, RC, pg, terrain, exposure, thermal, [R], ...
    # 1) ASCE 7-22, ASD, flat, RC II, pg 20, terrain C, fully exposed, unheated (1.2), W=100
    out = run_script([1, 1, 1, 2, 20, 2, 1, 2, 100])
    @test occursin("ASCE/SEI 7-22", out) && occursin("FLAT ROOF, ASD", out)
    @test occursin("pf    = 15.12 psf", out)                # 0.7*0.9*1.2*20
    @test occursin("Rain-on-snow surcharge  = 8.0", out)
    @test occursin("Minimum load      pm    = 20.0", out)
    @test occursin("Balanced load           = 16.18 psf", out)  # 0.7*23.12

    # 2) commentary Example 1, LRFD gable
    out = run_script([1, 2, 2, 2, 30, 1, 2, 1, 30, 6, 30, 1, 0.55])
    @test occursin("GABLE ROOF, LRFD", out)
    @test occursin("Ct      = 1.14", out)
    @test occursin("pf    = 23.94", out)
    @test occursin("31.25 psf surcharge over 9.31 ft", out)
    @test occursin("hd = 2.47 ft", out)

    # 3) mono-slope, LRFD, slippery, freezer (Ct=1.3), sheltered terrain D
    out = run_script([1, 2, 3, 3, 40, 3, 3, 3, 12, 30, 2])
    @test occursin("MONOSLOPE ROOF, LRFD", out)
    @test occursin("Ct      = 1.3", out)
    @test occursin("Ce", out) && occursin("/ 1.0", out)
    @test occursin("unobstructed slippery surface", out)
    @test !occursin("Unbalanced", out)

    # 4) alaska / above-treeline: 'Sheltered' option not offered (only 2 choices)
    out = run_script([1, 1, 1, 2, 30, 4, 1, 4, 50])
    @test occursin("Ct      = 0.85", out) && occursin("/ 0.7", out)

    # 5) heated, unventilated, R asked; invalid entries re-prompt
    out = run_script([1, 1, 2, 2, 30, 1, 2, "x", 9, 1, 30, 6, 30, 1, "abc", 0.4])
    @test occursin("Invalid selection", out)
    @test occursin("Enter a number between", out)
    @test occursin("Ct      = 1.14", out)                   # R = 30 hit; pg = 30

    # 6) ASCE 7-16: code=2, LRFD, gable, RC II, pg 30, terrain B, partially, Ct 1.0, 6:12, W=30
    out = run_script([2, 2, 2, 2, 30, 1, 2, 1, 6, 30, 1])
    @test occursin("ASCE/SEI 7-16", out) && occursin("GABLE ROOF, LRFD", out)
    @test occursin("pf    = 21.0", out) && occursin("23.54 psf surcharge over 7.02 ft", out)
    @test occursin("snow factor = 1.6", out)
    # 7-16 slippery warm roof asks for ventilation and R
    out = run_script([2, 1, 3, 2, 30, 1, 2, 1, 8, 30, 2, 1, 40])
    @test occursin("Roof ventilation", out) && occursin("MONOSLOPE ROOF, ASD", out)

    # 7) unimplemented standards exit cleanly with a message
    for k in 3:10
        out = run_script([k, 1])
        @test occursin("not implemented yet", out)
        @test !occursin("Stacktrace", out)
    end
end

end
