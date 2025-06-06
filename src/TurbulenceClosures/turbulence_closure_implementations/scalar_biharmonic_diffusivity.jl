import Oceananigans.Grids: required_halo_size_x, required_halo_size_y, required_halo_size_z
using Oceananigans.Utils: prettysummary

"""
    struct ScalarBiharmonicDiffusivity{F, N, K} <: AbstractScalarBiharmonicDiffusivity{F}

Holds viscosity and diffusivities for models with prescribed isotropic diffusivities.
"""
struct ScalarBiharmonicDiffusivity{F, N, V, K} <: AbstractScalarBiharmonicDiffusivity{F, N}
    ν :: V
    κ :: K
    ScalarBiharmonicDiffusivity{F, N}(ν::V, κ::K) where {F, V, K, N} = new{F, N, V, K}(ν, κ)
end

# Aliases that allow specify the floating type, assuming that the discretization is Explicit in time
ScalarBiharmonicDiffusivity(FT::DataType; kwargs...) = ScalarBiharmonicDiffusivity(ThreeDimensionalFormulation(), FT; kwargs...)
VerticalScalarBiharmonicDiffusivity(FT::DataType=Oceananigans.defaults.FloatType; kwargs...) = ScalarBiharmonicDiffusivity(VerticalFormulation(), FT; kwargs...)
HorizontalScalarBiharmonicDiffusivity(FT::DataType=Oceananigans.defaults.FloatType; kwargs...) = ScalarBiharmonicDiffusivity(HorizontalFormulation(), FT; kwargs...)
HorizontalDivergenceScalarBiharmonicDiffusivity(FT::DataType=Oceananigans.defaults.FloatType; kwargs...) = ScalarBiharmonicDiffusivity(HorizontalDivergenceFormulation(), FT; kwargs...)

"""
    ScalarBiharmonicDiffusivity(formulation = ThreeDimensionalFormulation(), FT = Float64;
                                ν = 0,
                                κ = 0,
                                discrete_form = false,
                                loc = (nothing, nothing, nothing),
                                parameters = nothing)

Return a scalar biharmonic diffusivity turbulence closure with viscosity coefficient `ν` and tracer
diffusivities `κ` for each tracer field in `tracers`. If a single `κ` is provided, it is applied to
all tracers. Otherwise `κ` must be a `NamedTuple` with values for every tracer individually.

Arguments
=========

* `formulation`:
  - `HorizontalFormulation()` for diffusivity applied in the horizontal direction(s)
  - `VerticalFormulation()` for diffusivity applied in the vertical direction,
  - `ThreeDimensionalFormulation()` (default) for diffusivity applied isotropically to all directions

* `FT`: the float datatype (default: `Float64`)

Keyword arguments
=================

* `ν`: Viscosity. `Number`, `AbstractArray`, `Field`, or `Function`.

* `κ`: Diffusivity. `Number`, `AbstractArray`, `Field`, `Function`, or
       `NamedTuple` of diffusivities with entries for each tracer.

* `discrete_form`: `Boolean`; default: `false`.

* `required_halo_size = 2`: the required halo size for the closure. This value should be an integer.
  change only if using a function for `ν` or `κ` that requires a halo size larger than 1 to compute.

When prescribing the viscosities or diffusivities as functions, depending on the
value of keyword argument `discrete_form`, the constructor expects:

* `discrete_form = false` (default): functions of the grid's native coordinates
  and time, e.g., `(x, y, z, t)` for a `RectilinearGrid` or `(λ, φ, z, t)` for
  a `LatitudeLongitudeGrid`.

* `discrete_form = true`:
  - with `loc = (nothing, nothing, nothing)` (default):
    functions of `(i, j, k, grid, ℓx, ℓy, ℓz)` with `ℓx`, `ℓy`,
    and `ℓz` either `Face()` or `Center()`.
  - with `loc = (ℓx, ℓy, ℓz)` with `ℓx`, `ℓy`, and `ℓz` either
    `Face()` or `Center()`: functions of `(i, j, k, grid)`.

* `parameters`: `NamedTuple` with parameters used by the functions
  that compute viscosity and/or diffusivity; default: `nothing`.

For examples see [`ScalarDiffusivity`](@ref).
"""
function ScalarBiharmonicDiffusivity(formulation = ThreeDimensionalFormulation(),
                                     FT = Oceananigans.defaults.FloatType;
                                     ν = 0,
                                     κ = 0,
                                     discrete_form = false,
                                     loc = (nothing, nothing, nothing),
                                     parameters = nothing,
                                     required_halo_size::Int = 2)

    ν = convert_diffusivity(FT, ν; discrete_form, loc, parameters)
    κ = convert_diffusivity(FT, κ; discrete_form, loc, parameters)

    # Force a type-stable constructor if ν and κ are numbers
    # This particular short-circuiting of the required_halo_size kwargs is necessary to perform parameter
    # estimation of the diffusivity coefficients using autodiff.
    if ν isa Number && κ isa Number
        return ScalarBiharmonicDiffusivity{typeof(formulation), 2}(ν, κ)
    end

    return ScalarBiharmonicDiffusivity{typeof(formulation), required_halo_size}(ν, κ)
end

function with_tracers(tracers, closure::ScalarBiharmonicDiffusivity{F, N, V, K}) where {F, N, V, K}
    κ = tracer_diffusivities(tracers, closure.κ)
    return ScalarBiharmonicDiffusivity{F, N}(closure.ν, κ)
end

@inline viscosity(closure::ScalarBiharmonicDiffusivity, K) = closure.ν
@inline diffusivity(closure::ScalarBiharmonicDiffusivity, K, ::Val{id}) where id = closure.κ[id]

compute_diffusivities!(diffusivities, closure::ScalarBiharmonicDiffusivity, args...) = nothing

function Base.summary(closure::ScalarBiharmonicDiffusivity)
    F = summary(formulation(closure))

    if closure.κ == NamedTuple()
        summary_str = string("ScalarBiharmonicDiffusivity{$F}(ν=", prettysummary(closure.ν), ")")
    else
        summary_str = string("ScalarBiharmonicDiffusivity{$F}(ν=", prettysummary(closure.ν), ", κ=", prettysummary(closure.κ), ")")
    end

    return summary_str
end

Base.show(io::IO, closure::ScalarBiharmonicDiffusivity) = print(io, summary(closure))

function Adapt.adapt_structure(to, closure::ScalarBiharmonicDiffusivity{F, <:Any, <:Any, N}) where {F, N}
    ν = Adapt.adapt(to, closure.ν)
    κ = Adapt.adapt(to, closure.κ)
    return ScalarBiharmonicDiffusivity{F, N}(ν, κ)
end

function on_architecture(to, closure::ScalarBiharmonicDiffusivity{F, <:Any, <:Any, N}) where {F, N}
    ν = on_architecture(to, closure.ν)
    κ = on_architecture(to, closure.κ)
    return ScalarBiharmonicDiffusivity{F, N}(ν, κ)
end
