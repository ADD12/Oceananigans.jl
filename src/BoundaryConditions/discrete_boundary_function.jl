"""
    struct DiscreteBoundaryFunction{P, F} <: Function

A wrapper for boundary condition functions with optional parameters.
When `parameters=nothing`, the boundary condition `func` is called with the signature

```
func(i, j, grid, clock, model_fields)
```

where `i, j` are the indices along the boundary,
where `grid` is `model.grid`, `clock.time` is the current simulation time and
`clock.iteration` is the current model iteration, and
`model_fields` is a `NamedTuple` with `u, v, w`, the fields in `model.tracers`,
and the fields in `model.diffusivity_fields`, each of which is an `OffsetArray`s (or `NamedTuple`s
of `OffsetArray`s depending on the turbulence closure) of field data.

When `parameters` is not `nothing`, the boundary condition `func` is called with
the signature

```
func(i, j, grid, clock, model_fields, parameters)
```

*Note* that the index `end` does *not* access the final physical grid point of
a model field in any direction. The final grid point must be explictly specified, as
in `model_fields.u[i, j, grid.Nz]`.
"""
struct DiscreteBoundaryFunction{P, F}
    func :: F
    parameters :: P
end

const UnparameterizedDBF = DiscreteBoundaryFunction{<:Nothing}

@inline getbc(condition::UnparameterizedDBF, i::Integer, j::Integer, grid::AbstractGrid, clock, model_fields, args...) =
    condition.func(i, j, grid, clock, model_fields)

@inline getbc(condition::DiscreteBoundaryFunction, i::Integer, j::Integer, grid::AbstractGrid, clock, model_fields, args...) =
    condition.func(i, j, grid, clock, model_fields, condition.parameters)

# 3D function for immersed boundary conditions
@inline getbc(condition::UnparameterizedDBF, i::Integer, j::Integer, k::Integer, grid::AbstractGrid, clock, model_fields, args...) =
    condition.func(i, j, k, grid, clock, model_fields)

@inline getbc(condition::DiscreteBoundaryFunction, i::Integer, j::Integer, k::Integer, grid::AbstractGrid, clock, model_fields, args...) =
    condition.func(i, j, k, grid, clock, model_fields, condition.parameters)

# Don't re-convert DiscreteBoundaryFunctions passed to BoundaryCondition constructor
BoundaryCondition(Classification::DataType, condition::DiscreteBoundaryFunction) = BoundaryCondition(Classification(), condition)

Base.summary(bf::DiscreteBoundaryFunction{<:Nothing}) = string("DiscreteBoundaryFunction with ", prettysummary(bf.func, false))
Base.summary(bf::DiscreteBoundaryFunction) = string("DiscreteBoundaryFunction ", prettysummary(bf.func, false), " with parameters ", prettysummary(bf.parameters, false))

Adapt.adapt_structure(to, bf::DiscreteBoundaryFunction) = DiscreteBoundaryFunction(Adapt.adapt(to, bf.func),
                                                                                   Adapt.adapt(to, bf.parameters))

on_architecture(to, bf::DiscreteBoundaryFunction) = DiscreteBoundaryFunction(on_architecture(to, bf.func),
                                                                             on_architecture(to, bf.parameters))

