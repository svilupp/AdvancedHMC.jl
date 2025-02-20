module AdvancedHMC

const DEBUG = convert(Bool, parse(Int, get(ENV, "DEBUG_AHMC", "0")))

using Statistics: mean, var, middle
using LinearAlgebra: Symmetric, UpperTriangular, mul!, ldiv!, dot, I, diag, cholesky, UniformScaling
using StatsFuns: logaddexp, logsumexp
import Random
using Random: GLOBAL_RNG, AbstractRNG
using ProgressMeter: ProgressMeter
using UnPack: @unpack

using Setfield
import Setfield: ConstructionBase

using ArgCheck: @argcheck

using DocStringExtensions

using LogDensityProblems
using LogDensityProblemsAD: LogDensityProblemsAD

import AbstractMCMC
using AbstractMCMC: LogDensityModel

import StatsBase: sample

include("utilities.jl")

# Notations
# ℓπ: log density of the target distribution
# θ: position variables / model parameters
# ∂ℓπ∂θ: gradient of the log density of the target distribution w.r.t θ
# r: momentum variables
# z: phase point / a pair of θ and r

# TODO Move it back to hamiltonian.jl after the rand interface is updated
abstract type AbstractKinetic end

struct GaussianKinetic <: AbstractKinetic end

export GaussianKinetic

include("metric.jl")
export UnitEuclideanMetric, DiagEuclideanMetric, DenseEuclideanMetric

include("hamiltonian.jl")
export Hamiltonian

include("integrator.jl")
export Leapfrog, JitteredLeapfrog, TemperedLeapfrog

include("trajectory.jl")
export Trajectory, HMCKernel,
       FixedNSteps, FixedIntegrationTime,
       ClassicNoUTurn, GeneralisedNoUTurn, StrictGeneralisedNoUTurn,
       EndPointTS, SliceTS, MultinomialTS, 
       find_good_stepsize

# Useful defaults

struct NUTS{TS, TC} end

"""
$(SIGNATURES)

Convenient constructor for the no-U-turn sampler (NUTS).
This falls back to `HMCKernel(Trajectory{TS}(int, TC(args...; kwargs...)))` where

- `TS<:Union{MultinomialTS, SliceTS}` is the type for trajectory sampler
- `TC<:Union{ClassicNoUTurn, GeneralisedNoUTurn, StrictGeneralisedNoUTurn}` is the type for termination criterion.

See [`ClassicNoUTurn`](@ref), [`GeneralisedNoUTurn`](@ref) and [`StrictGeneralisedNoUTurn`](@ref) for details in parameters.
"""
NUTS{TS, TC}(int::AbstractIntegrator, args...; kwargs...) where {TS, TC} = 
    HMCKernel(Trajectory{TS}(int, TC(args...; kwargs...)))
NUTS(int::AbstractIntegrator, args...; kwargs...) = 
    HMCKernel(Trajectory{MultinomialTS}(int, GeneralisedNoUTurn(args...; kwargs...)))
NUTS(ϵ::AbstractScalarOrVec{<:Real}) =
    HMCKernel(Trajectory{MultinomialTS}(Leapfrog(ϵ), GeneralisedNoUTurn()))

export NUTS

# Deprecations for trajectory.jl

abstract type AbstractTrajectory end

struct StaticTrajectory{TS} end
@deprecate StaticTrajectory{TS}(int::AbstractIntegrator, L) where {TS} HMCKernel(Trajectory{TS}(int, FixedNSteps(L)))
@deprecate StaticTrajectory(int::AbstractIntegrator, L) HMCKernel(Trajectory{EndPointTS}(int, FixedNSteps(L)))
@deprecate StaticTrajectory(ϵ::AbstractScalarOrVec{<:Real}, L) HMCKernel(Trajectory{EndPointTS}(Leapfrog(ϵ), FixedNSteps(L)))

struct HMCDA{TS} end
@deprecate HMCDA{TS}(int::AbstractIntegrator, λ) where {TS} HMCKernel(Trajectory{TS}(int, FixedIntegrationTime(λ)))
@deprecate HMCDA(int::AbstractIntegrator, λ) HMCKernel(Trajectory{EndPointTS}(int, FixedIntegrationTime(λ)))
@deprecate HMCDA(ϵ::AbstractScalarOrVec{<:Real}, λ) HMCKernel(Trajectory{EndPointTS}(Leapfrog(ϵ), FixedIntegrationTime(λ)))

@deprecate find_good_eps find_good_stepsize

export StaticTrajectory, HMCDA, find_good_eps

include("adaptation/Adaptation.jl")
using .Adaptation
import .Adaptation: StepSizeAdaptor, MassMatrixAdaptor, StanHMCAdaptor, NesterovDualAveraging

# Helpers for initializing adaptors via AHMC structs

StepSizeAdaptor(δ::AbstractFloat, stepsize::AbstractScalarOrVec{<:AbstractFloat}) = 
    NesterovDualAveraging(δ, stepsize)
StepSizeAdaptor(δ::AbstractFloat, i::AbstractIntegrator) = StepSizeAdaptor(δ, nom_step_size(i))

MassMatrixAdaptor(m::UnitEuclideanMetric{T}) where {T} =
    UnitMassMatrix{T}()
MassMatrixAdaptor(m::DiagEuclideanMetric{T}) where {T} =
    WelfordVar{T}(size(m); var=copy(m.M⁻¹))
MassMatrixAdaptor(m::DenseEuclideanMetric{T}) where {T} =
    WelfordCov{T}(size(m); cov=copy(m.M⁻¹))

MassMatrixAdaptor(
    m::Type{TM},
    sz::Tuple{Vararg{Int}}=(2,)
) where {TM<:AbstractMetric} = MassMatrixAdaptor(Float64, m, sz)

MassMatrixAdaptor(
    ::Type{T},
    ::Type{TM},
    sz::Tuple{Vararg{Int}}=(2,)
) where {T, TM<:AbstractMetric} = MassMatrixAdaptor(TM(T, sz))

# Deprecations

@deprecate StanHMCAdaptor(n_adapts, pc, ssa) initialize!(StanHMCAdaptor(pc, ssa), n_adapts)
@deprecate NesterovDualAveraging(δ::AbstractFloat, i::AbstractIntegrator) StepSizeAdaptor(δ, i)
@deprecate Preconditioner(args...) MassMatrixAdaptor(args...)

export StepSizeAdaptor, NesterovDualAveraging, 
       MassMatrixAdaptor, UnitMassMatrix, WelfordVar, WelfordCov, 
       NaiveHMCAdaptor, StanHMCAdaptor

include("diagnosis.jl")

include("sampler.jl")
export sample

include("abstractmcmc.jl")

## Without explicit AD backend
function Hamiltonian(metric::AbstractMetric, ℓ::LogDensityModel; kwargs...)
    return Hamiltonian(metric, ℓ.logdensity; kwargs...)
end
function Hamiltonian(metric::AbstractMetric, ℓ; kwargs...)
    cap = LogDensityProblems.capabilities(ℓ)
    if cap === nothing
        throw(ArgumentError("The log density function does not support the LogDensityProblems.jl interface"))
    end
    # Check if we're capable of computing gradients.
    ℓπ = if cap === LogDensityProblems.LogDensityOrder{0}()
        # In this case ℓ does not support evaluation of the gradient of the log density function
        # We use ForwardDiff to compute the gradient
        LogDensityProblemsAD.ADgradient(Val(:ForwardDiff), ℓ; kwargs...)
    else
        # In this case ℓ already supports evaluation of the gradient of the log density function
        ℓ
    end
    return Hamiltonian(
        metric,
        Base.Fix1(LogDensityProblems.logdensity, ℓπ),
        Base.Fix1(LogDensityProblems.logdensity_and_gradient, ℓπ),
    )
end

## With explicit AD specification
function Hamiltonian(metric::AbstractMetric, ℓπ::LogDensityModel, kind::Union{Symbol,Val,Module}; kwargs...)
    return Hamiltonian(metric, ℓπ.logdensity, kind; kwargs...)
end
Hamiltonian(metric::AbstractMetric, ℓπ, m::Module; kwargs...) = Hamiltonian(metric, ℓπ, Val(Symbol(m)); kwargs...)
function Hamiltonian(metric::AbstractMetric, ℓπ, kind::Union{Symbol,Val}; kwargs...)
    if LogDensityProblems.capabilities(ℓπ) === nothing
        throw(ArgumentError("The log density function does not support the LogDensityProblems.jl interface"))
    end
    ℓ = LogDensityProblemsAD.ADgradient(kind, ℓπ; kwargs...)
    return Hamiltonian(metric, ℓ)
end

### Init

using Requires

function __init__()
    @require OrdinaryDiffEq = "1dea7af3-3e70-54e6-95c3-0bf5283fa5ed" begin
        export DiffEqIntegrator
        include("contrib/diffeq.jl")
    end

    @require CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba" begin 
        include("contrib/cuda.jl")
    end
end

end # module
