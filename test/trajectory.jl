using Test, AdvancedHMC, Random
using Statistics: mean
using LinearAlgebra: dot
using Distributions
using ForwardDiff
include("common.jl")

ϵ = 0.01
lf = Leapfrog(ϵ)

θ_init = randn(D)
h = Hamiltonian(UnitEuclideanMetric(D), ℓπ, ∂ℓπ∂θ)
τ = NUTS(Leapfrog(find_good_stepsize(h, θ_init)))
r_init = AdvancedHMC.rand(h.metric)

@testset "Passing random number generator" begin
    τ_with_jittered_lf = NUTS(JitteredLeapfrog(find_good_stepsize(h, θ_init), 1.0))
    for τ_test in [τ, τ_with_jittered_lf],
        seed in [1234, 5678, 90]
        rng = MersenneTwister(seed)
        z = AdvancedHMC.phasepoint(h, θ_init, r_init)
        z1′ = AdvancedHMC.transition(rng, τ_test, h, z).z

        rng = MersenneTwister(seed)
        z = AdvancedHMC.phasepoint(h, θ_init, r_init)
        z2′ = AdvancedHMC.transition(rng, τ_test, h, z).z

        @test z1′.θ == z2′.θ
        @test z1′.r == z2′.r
    end
end

@testset "TreeSampler" begin
    n_samples = 10_000
    z1 = AdvancedHMC.phasepoint(h, zeros(D), r_init)
    z2 = AdvancedHMC.phasepoint(h, ones(D), r_init)

    rng = MersenneTwister(1234)

    ℓu = rand()
    n1 = 2
    s1 = AdvancedHMC.SliceTS(z1, ℓu, n1) 
    n2 = 1
    s2 = AdvancedHMC.SliceTS(z2, ℓu, n2) 
    s3 = AdvancedHMC.combine(rng, s1, s2)
    @test s3.ℓu == ℓu
    @test s3.n == n1 + n2

    
    s3_θ = Vector(undef, n_samples)
    for i = 1:n_samples
        s3_θ[i] = AdvancedHMC.combine(rng, s1, s2).zcand.θ
    end
    @test mean(s3_θ) ≈ ones(D) * n2 / (n1 + n2) rtol=0.01

    w1 = 100
    s1 = AdvancedHMC.MultinomialTS(z1, log(w1))
    w2 = 150
    s2 = AdvancedHMC.MultinomialTS(z2, log(w2))
    s3 = AdvancedHMC.combine(rng, s1, s2)
    @test s3.ℓw ≈ log(w1 + w2)

    s3_θ = Vector(undef, n_samples)
    for i = 1:n_samples
        s3_θ[i] = AdvancedHMC.combine(rng, s1, s2).zcand.θ
    end
    @test mean(s3_θ) ≈ ones(D) * w2 / (w1 + w2) rtol=0.01
end

@testset "TerminationCriterion" begin
    z1 = AdvancedHMC.phasepoint(h, θ_init, randn(D))
    c1 = AdvancedHMC.ClassicNoUTurn(z1)
    z2 = AdvancedHMC.phasepoint(h, θ_init, randn(D))
    c2 = AdvancedHMC.ClassicNoUTurn(z2)
    c3 = AdvancedHMC.combine(c1, c2)
    @test c1 == c2 == c3

    r1 = randn(D)
    z1 = AdvancedHMC.phasepoint(h, θ_init, r1)
    c1 = AdvancedHMC.GeneralisedNoUTurn(z1) 
    r2 = randn(D)
    z2 = AdvancedHMC.phasepoint(h, θ_init, r2)
    c2 = AdvancedHMC.GeneralisedNoUTurn(z2) 
    c3 = AdvancedHMC.combine(c1, c2)
    @test c3.rho == r1 + r2
end

@testset "Termination" begin
    t00 = AdvancedHMC.Termination(false, false)
    t01 = AdvancedHMC.Termination(false, true)
    t10 = AdvancedHMC.Termination(true, false)
    t11 = AdvancedHMC.Termination(true, true)

    @test AdvancedHMC.isterminated(t00) == false
    @test AdvancedHMC.isterminated(t01) == true
    @test AdvancedHMC.isterminated(t10) == true
    @test AdvancedHMC.isterminated(t11) == true

    @test AdvancedHMC.isterminated(t00 * t00) == false
    @test AdvancedHMC.isterminated(t00 * t01) == true
    @test AdvancedHMC.isterminated(t00 * t10) == true
    @test AdvancedHMC.isterminated(t00 * t11) == true

    @test AdvancedHMC.isterminated(t01 * t00) == true
    @test AdvancedHMC.isterminated(t01 * t01) == true
    @test AdvancedHMC.isterminated(t01 * t10) == true
    @test AdvancedHMC.isterminated(t01 * t11) == true

    @test AdvancedHMC.isterminated(t10 * t00) == true
    @test AdvancedHMC.isterminated(t10 * t01) == true
    @test AdvancedHMC.isterminated(t10 * t10) == true
    @test AdvancedHMC.isterminated(t10 * t11) == true

    @test AdvancedHMC.isterminated(t11 * t00) == true
    @test AdvancedHMC.isterminated(t11 * t01) == true
    @test AdvancedHMC.isterminated(t11 * t10) == true
    @test AdvancedHMC.isterminated(t11 * t11) == true
end

@testset "BinaryTree" begin
    z = AdvancedHMC.phasepoint(h, θ_init, randn(D))

    t1 = AdvancedHMC.BinaryTree(z, z, ClassicNoUTurn(), 0.1, 1, -2.0)
    t2 = AdvancedHMC.BinaryTree(z, z, ClassicNoUTurn(), 1.1, 2, 1.0)
    t3 = AdvancedHMC.combine(t1, t2)

    @test t3.sum_α ≈ 1.2 atol=1e-9
    @test t3.nα == 3
    @test t3.ΔH_max == -2.0

    t4 = AdvancedHMC.BinaryTree(z, z, ClassicNoUTurn(), 1.1, 2, 3.0)
    t5 = AdvancedHMC.combine(t1, t4)

    @test t5.ΔH_max == 3.0
end

### Test ClassicNoUTurn and GeneralisedNoUTurn

function makeplot(
    plt,
    traj_θ,
    ts_list...
)
    function plotturn!(traj_θ, ts)
        s = 9.0
        idcs_nodiv = ts .== false
        idcs_div = ts .== true
        idcs_nodiv[1] = idcs_div[1] = false # avoid plotting the first point
        plt.scatter(traj_θ[1,idcs_nodiv], traj_θ[2,idcs_nodiv], s=s, c="black",  label="¬div")
        plt.scatter(traj_θ[1,idcs_div], traj_θ[2,idcs_div],  s=s, c="red",    label="div")
        plt.scatter(traj_θ[1,1], traj_θ[2,1], s=s, c="yellow", label="init")
    end

    fig = plt.figure(figsize=(16, 3))

    for (i, ts, title) in zip(
        1:length(ts_list),
        ts_list,
        [
            "Hand original (v = 1)",
            "AHMC original (v = 1)",
            "Hand generalised (v = 1)",
            "AHMC generalised (v = 1)"
        ]
    )
        plt.subplot(1, 4, i)
        plotturn!(traj_θ, ts)
        plt.gca().set_title(title)
        plt.legend()
    end

    return fig
end

function gettraj(rng, ϵ=0.1, n_steps=50)
    lf = Leapfrog(ϵ)
    
    q_init = randn(rng, D)
    p_init = AdvancedHMC.rand(rng, h.metric)
    z = AdvancedHMC.phasepoint(h, q_init, p_init)

    traj_z = Vector(undef, n_steps)
    traj_z[1] = z
    for i = 2:n_steps
        traj_z[i] = AdvancedHMC.step(lf, h, traj_z[i-1])
    end
    
    return traj_z
end

function hand_isturn(z0, z1, rho, v=1)
    θ0minusθ1 = z0.θ - z1.θ
    s = (dot(-θ0minusθ1, -z0.r) >= 0) || (dot(θ0minusθ1, z1.r) >= 0)
    return s
end

ahmc_isturn(z0, z1, rho, v=1) =
    AdvancedHMC.isterminated(h, AdvancedHMC.BinaryTree(z0, z1, ClassicNoUTurn(), 0, 0, 0.0)).dynamic

function hand_isturn_generalised(z0, z1, rho, v=1)
    s = (dot(rho, -z0.r) >= 0) || (dot(-rho, z1.r) >= 0)
    return s
end

ahmc_isturn_generalised(z0, z1, rho, v=1) =
    AdvancedHMC.isterminated(h, AdvancedHMC.BinaryTree(z0, z1, GeneralisedNoUTurn(rho), 0, 0, 0.0)).dynamic

function ahmc_isturn_strictgeneralised(z0, z1, rho, v=1)
    t = AdvancedHMC.isterminated(
        h, 
        AdvancedHMC.BinaryTree(z0, z1, StrictGeneralisedNoUTurn(rho), 0, 0, 0.0),
        AdvancedHMC.BinaryTree(z0, z0, StrictGeneralisedNoUTurn(rho - z1.r), 0, 0, 0.0), 
        AdvancedHMC.BinaryTree(z1, z1, StrictGeneralisedNoUTurn(rho - z0.r), 0, 0, 0.0)
    )
    return t.dynamic
end

"""
Check whether the subtree checks adequately detect U-turns.
"""
function check_subtree_u_turns(z0, z1, rho)
    t = AdvancedHMC.BinaryTree(z0, z1, StrictGeneralisedNoUTurn(rho), 0, 0, 0.0)

    # The left and right subtree are created in such a way that the 
    # check_left_subtree and check_right_subtree checks should be equivalent 
    # to the general no U-turn check.
    tleft = AdvancedHMC.BinaryTree(z0, z0, StrictGeneralisedNoUTurn(rho - z1.r), 0, 0, 0.0)
    tright = AdvancedHMC.BinaryTree(z1, z1, StrictGeneralisedNoUTurn(rho - z0.r), 0, 0, 0.0)

    t_generalised = AdvancedHMC.BinaryTree(
        t.zleft,
        t.zright,
        GeneralisedNoUTurn(t.c.rho),
        t.sum_α,
        t.nα,
        t.ΔH_max
    )
    s1 = AdvancedHMC.isterminated(h, t_generalised)

    s2 = AdvancedHMC.check_left_subtree(h, t, tleft, tright)
    s3 = AdvancedHMC.check_right_subtree(h, t, tleft, tright)
    @test s1 == s2 == s3
end

@testset "ClassicNoUTurn" begin
    n_tests = 4
    for _ = 1:n_tests
        seed = abs(rand(Int8) + 128)
        rng = MersenneTwister(seed)
        @testset "seed = $seed" begin
            traj_z = gettraj(rng)
            traj_θ = hcat(map(z -> z.θ, traj_z)...)
            traj_r = hcat(map(z -> z.r, traj_z)...)
            rho = cumsum(traj_r, dims=2)
            
            ts_hand_isturn_fwd = hand_isturn.(Ref(traj_z[1]), traj_z, [rho[:,i] for i = 1:length(traj_z)], Ref(1))
            ts_ahmc_isturn_fwd = ahmc_isturn.(Ref(traj_z[1]), traj_z, [rho[:,i] for i = 1:length(traj_z)], Ref(1))

            ts_hand_isturn_generalised_fwd = hand_isturn_generalised.(Ref(traj_z[1]), traj_z, [rho[:,i] for i = 1:length(traj_z)], Ref(1))
            ts_ahmc_isturn_generalised_fwd = ahmc_isturn_generalised.(Ref(traj_z[1]), traj_z, [rho[:,i] for i = 1:length(traj_z)], Ref(1))

            ts_ahmc_isturn_strictgeneralised_fwd = ahmc_isturn_strictgeneralised.(Ref(traj_z[1]), traj_z, [rho[:,i] for i = 1:length(traj_z)], Ref(1))

            check_subtree_u_turns.(Ref(traj_z[1]), traj_z, [rho[:,i] for i = 1:length(traj_z)])

            @test ts_hand_isturn_fwd[2:end] == 
                ts_ahmc_isturn_fwd[2:end] == 
                ts_hand_isturn_generalised_fwd[2:end] == 
                ts_ahmc_isturn_generalised_fwd[2:end] == 
                ts_ahmc_isturn_strictgeneralised_fwd[2:end]

            if length(ARGS) > 0 && ARGS[1] == "--plot"
                import PyPlot
                fig = makeplot(
                    PyPlot,
                    traj_θ,
                    ts_hand_isturn_fwd, 
                    ts_ahmc_isturn_fwd,
                    ts_hand_isturn_generalised_fwd, 
                    ts_ahmc_isturn_generalised_fwd
                )
                fig.savefig("seed=$seed.png")
            end
        end
    end
end

@testset "iterative/recursive NUTS regression" begin
    @testset "standard normal" begin
        D = 10; initial_θ = rand(D)
        n_samples, n_adapts = 2_000, 1_000
        metric = UnitEuclideanMetric(D)
        ℓπ(x) = logpdf(MvNormal(ones(D)), x)
        hamiltonian = Hamiltonian(metric, ℓπ, ForwardDiff)
        initial_ϵ = find_good_stepsize(hamiltonian, initial_θ)
        integrator = Leapfrog(initial_ϵ)
        adaptor = StanHMCAdaptor(MassMatrixAdaptor(metric), StepSizeAdaptor(0.8, integrator))

        seeds = rand(UInt, 100)
        for seed in seeds
            rng = MersenneTwister(seed)
            proposal_recur = NUTS{MultinomialTS,StrictGeneralisedNoUTurn,typeof(integrator),Float64,AdvancedHMC.RecursiveTreeBuilding}(integrator, 10, 1000.0)
            samples_recur, stats_recur = sample(rng, hamiltonian, proposal_recur, initial_θ, n_samples, deepcopy(adaptor), n_adapts, verbose = false)

            rng = MersenneTwister(seed)
            proposal_iter = NUTS{MultinomialTS,StrictGeneralisedNoUTurn,typeof(integrator),Float64,AdvancedHMC.IterativeTreeBuilding}(integrator, 10, 1000.0)
            samples_iter, stats_iter = sample(rng, hamiltonian, proposal_iter, initial_θ, n_samples, deepcopy(adaptor), n_adapts, verbose = false)
            @test samples_iter == samples_recur
            @test stats_iter == stats_recur
        end
    end

    @testset "high curvature" begin
        # Neal's funnel
        D = 10; initial_θ = rand(D)
        n_samples, n_adapts = 2_000, 1_000
        metric = UnitEuclideanMetric(D)
        function ℓπ(x)
            σ = clamp(exp(x[1] / 2), sqrt(eps()), Inf)
            return logpdf(Normal(0, 3), x[1]) + sum(logpdf.(Normal(0, σ), x[2:end]))
        end
        hamiltonian = Hamiltonian(metric, ℓπ, ForwardDiff)
        initial_ϵ = find_good_stepsize(hamiltonian, initial_θ)
        integrator = Leapfrog(initial_ϵ)
        adaptor = StanHMCAdaptor(MassMatrixAdaptor(metric), StepSizeAdaptor(0.8, integrator))

        seeds = rand(UInt, 10)
        for seed in seeds
            rng = MersenneTwister(seed)
            proposal_recur = NUTS{MultinomialTS,StrictGeneralisedNoUTurn,typeof(integrator),Float64,AdvancedHMC.RecursiveTreeBuilding}(integrator, 10, 1000.0)
            samples_recur, stats_recur = sample(rng, hamiltonian, proposal_recur, initial_θ, n_samples, deepcopy(adaptor), n_adapts, verbose = false)

            rng = MersenneTwister(seed)
            proposal_iter = NUTS{MultinomialTS,StrictGeneralisedNoUTurn,typeof(integrator),Float64,AdvancedHMC.IterativeTreeBuilding}(integrator, 10, 1000.0)
            samples_iter, stats_iter = sample(rng, hamiltonian, proposal_iter, initial_θ, n_samples, deepcopy(adaptor), n_adapts, verbose = false)
            @test samples_iter == samples_recur
            @test stats_iter == stats_recur
        end
    end

    @testset "heavy-tailed" begin
        D = 10; initial_θ = rand(D)
        n_samples, n_adapts = 2_000, 1_000
        metric = UnitEuclideanMetric(D)
        ℓπ(x) = sum(logpdf.(TDist(1.0), x))
        hamiltonian = Hamiltonian(metric, ℓπ, ForwardDiff)
        initial_ϵ = find_good_stepsize(hamiltonian, initial_θ)
        integrator = Leapfrog(initial_ϵ)
        adaptor = StanHMCAdaptor(MassMatrixAdaptor(metric), StepSizeAdaptor(0.8, integrator))

        seeds = rand(UInt, 10)
        for seed in seeds
            rng = MersenneTwister(seed)
            proposal_recur = NUTS{MultinomialTS,StrictGeneralisedNoUTurn,typeof(integrator),Float64,AdvancedHMC.RecursiveTreeBuilding}(integrator, 10, 1000.0)
            samples_recur, stats_recur = sample(rng, hamiltonian, proposal_recur, initial_θ, n_samples, deepcopy(adaptor), n_adapts, verbose = false)

            rng = MersenneTwister(seed)
            proposal_iter = NUTS{MultinomialTS,StrictGeneralisedNoUTurn,typeof(integrator),Float64,AdvancedHMC.IterativeTreeBuilding}(integrator, 10, 1000.0)
            samples_iter, stats_iter = sample(rng, hamiltonian, proposal_iter, initial_θ, n_samples, deepcopy(adaptor), n_adapts, verbose = false)
            @test samples_iter == samples_recur
            @test stats_iter == stats_recur
        end
    end
end
