using Oceananigans.Diagnostics: AbstractDiagnostic
using Oceananigans.OutputWriters: fetch_output
using Oceananigans.Models: AbstractModel
using Oceananigans.Utils: AbstractSchedule, prettytime
using Oceananigans.TimeSteppers: Clock

import Oceananigans: run_diagnostic!
import Oceananigans.Utils: TimeInterval, SpecifiedTimes
import Oceananigans.Fields: location, indices, set!

"""
    mutable struct AveragedTimeInterval <: AbstractSchedule

Container for parameters that configure and handle time-averaged output.
"""
mutable struct AveragedTimeInterval <: AbstractSchedule
    interval :: Float64
    window :: Float64
    stride :: Int
    first_actuation_time :: Float64
    actuations :: Int
    collecting :: Bool
end

"""
    AveragedTimeInterval(interval; window=interval, stride=1)

Returns a `schedule` that specifies periodic time-averaging of output.
The time `window` specifies the extent of the time-average, which
reoccurs every `interval`.

`output` is computed and accumulated into the average every `stride` iterations
during the averaging window. For example, `stride=1` computes output every iteration,
whereas `stride=2` computes output every other iteration. Time-averages with
longer `stride`s are faster to compute, but less accurate.

The time-average of ``a`` is a left Riemann sum corresponding to

```math
⟨a⟩ = T⁻¹ \\int_{tᵢ-T}^{tᵢ} a \\mathrm{d} t \\, ,
```

where ``⟨a⟩`` is the time-average of ``a``, ``T`` is the time-window for averaging,
and the ``tᵢ`` are discrete times separated by the time `interval`. The ``tᵢ`` specify
both the end of the averaging window and the time at which output is written.

Example
=======

```jldoctest averaged_time_interval
using Oceananigans.OutputWriters: AveragedTimeInterval
using Oceananigans.Utils: days

schedule = AveragedTimeInterval(4days, window=2days)

# output
AveragedTimeInterval(window=2 days, stride=1, interval=4 days)
```

An `AveragedTimeInterval` schedule directs an output writer
to time-average its outputs before writing them to disk:

```@example averaged_time_interval
using Oceananigans
using Oceananigans.Units

model = NonhydrostaticModel(grid=RectilinearGrid(size=(1, 1, 1), extent=(1, 1, 1)))

simulation = Simulation(model, Δt=10minutes, stop_time=30days)

simulation.output_writers[:velocities] = JLD2Writer(model, model.velocities,
                                                    filename= "averaged_velocity_data.jld2",
                                                    schedule = AveragedTimeInterval(4days, window=2days, stride=2))
```
"""
function AveragedTimeInterval(interval; window=interval, stride=1)
    window > interval && throw(ArgumentError("Averaging window $window is greater than the output interval $interval."))
    return AveragedTimeInterval(Float64(interval), Float64(window), stride, 0.0, 0, false)
end

function next_actuation_time(sch::AveragedTimeInterval)
    t₀ = sch.first_actuation_time
    N = sch.actuations
    interval = sch.interval
    return t₀ + (N + 1) * interval
    # the next actuation time is the end of the time averaging window
end

# Schedule actuation
function (sch::AveragedTimeInterval)(model)
    scheduled = sch.collecting || model.clock.time > next_actuation_time(sch) - sch.window
    return scheduled
end
initialize_schedule!(sch::AveragedTimeInterval, clock) = nothing
outside_window(sch::AveragedTimeInterval, clock) = clock.time <=  next_actuation_time(sch) - sch.window
end_of_window(sch::AveragedTimeInterval, clock) = clock.time >= next_actuation_time(sch)

TimeInterval(sch::AveragedTimeInterval) = TimeInterval(sch.interval)
Base.copy(sch::AveragedTimeInterval) = AveragedTimeInterval(sch.interval, window=sch.window, stride=sch.stride)



"""
    mutable struct AveragedSpecifiedTimes <: AbstractSchedule

A schedule for averaging over windows that precede SpecifiedTimes.
"""
mutable struct AveragedSpecifiedTimes <: AbstractSchedule
    specified_times :: SpecifiedTimes
    window :: Float64
    stride :: Int
    collecting :: Bool
end

AveragedSpecifiedTimes(specified_times::SpecifiedTimes; window, stride=1) =
    AveragedSpecifiedTimes(specified_times, window, stride, false)

AveragedSpecifiedTimes(times; kw...) = AveragedSpecifiedTimes(SpecifiedTimes(times); kw...)

function (schedule::AveragedSpecifiedTimes)(model)
    time = model.clock.time

    next = schedule.specified_times.previous_actuation + 1
    next > length(schedule.specified_times.times) && return false

    next_time = schedule.specified_times.times[next]
    window = schedule.window

    schedule.collecting || time >= next_time - window
end

initialize_schedule!(sch::AveragedSpecifiedTimes, clock) = nothing

function outside_window(schedule::AveragedSpecifiedTimes, clock)
    next = schedule.specified_times.previous_actuation + 1
    next > length(schedule.specified_times.times) && return true
    next_time = schedule.specified_times.times[next]
    return clock.time < next_time - schedule.window
end

function end_of_window(schedule::AveragedSpecifiedTimes, clock)
    next = schedule.specified_times.previous_actuation + 1
    next > length(schedule.specified_times.times) && return true
    next_time = schedule.specified_times.times[next]
    return clock.time >= next_time
end

#####
##### WindowedTimeAverage
#####

mutable struct WindowedTimeAverage{OP, R, S} <: AbstractDiagnostic
                      result :: R
                     operand :: OP
           window_start_time :: Float64
      window_start_iteration :: Int
    previous_collection_time :: Float64
                    schedule :: S
               fetch_operand :: Bool
end

const IntervalWindowedTimeAverage = WindowedTimeAverage{<:Any, <:Any, <:AveragedTimeInterval}
const SpecifiedWindowedTimeAverage = WindowedTimeAverage{<:Any, <:Any, <:AveragedSpecifiedTimes}

stride(wta::IntervalWindowedTimeAverage) = wta.schedule.stride
stride(wta::SpecifiedWindowedTimeAverage) = wta.schedule.stride

"""
    WindowedTimeAverage(operand, model=nothing; schedule)

Returns an object for computing running averages of `operand` over `schedule.window` and
recurring on `schedule.interval`, where `schedule` is an `AveragedTimeInterval`.
During the collection period, averages are computed every `schedule.stride` iteration.

`operand` may be a `Oceananigans.Field` or a function that returns an array or scalar.

Calling `wta(model)` for `wta::WindowedTimeAverage` object returns `wta.result`.
"""
function WindowedTimeAverage(operand, model=nothing; schedule, fetch_operand=true)

    if fetch_operand
        output = fetch_output(operand, model)
        result = similar(output)
        result .= output
    else
        result = similar(operand)
        result .= operand
    end

    return WindowedTimeAverage(result, operand, 0.0, 0, 0.0, schedule, fetch_operand)
end

# Time-averaging doesn't change spatial location
location(wta::WindowedTimeAverage) = location(wta.operand)
indices(wta::WindowedTimeAverage) = indices(wta.operand)
set!(u::Field, wta::WindowedTimeAverage) = set!(u, wta.result)
Base.parent(wta::WindowedTimeAverage) = parent(wta.result)

# This is called when output is requested.
function (wta::WindowedTimeAverage)(model)

    # For the paranoid
    wta.schedule.collecting &&
        model.clock.iteration > 0 &&
        @warn "Returning a WindowedTimeAverage before the collection period is complete."

    stride(wta) > 1 && @warn "WindowedTimeAverage can be erroneous when stride > 1 and either the timestep is variable or there are floating point rounding errors in times, both of which result in a decoupling of the model clock times (used in the OutputWriters) and iteration numbers (used for stride)."

    return wta.result
end

function accumulate_result!(wta, model::AbstractModel)
    integrand = wta.fetch_operand ? fetch_output(wta.operand, model) : wta.operand
    return accumulate_result!(wta, model.clock, integrand)
end

function accumulate_result!(wta, clock::Clock, integrand=wta.operand)
    # Time increment:
    Δt = clock.time - wta.previous_collection_time
    # Time intervals:
    T_current = clock.time - wta.window_start_time
    T_previous = wta.previous_collection_time - wta.window_start_time

    # Accumulate left Riemann sum
    @. wta.result = (wta.result * T_previous + integrand * Δt) / T_current

    # Save time of integrand collection
    wta.previous_collection_time = clock.time

    return nothing
end

function advance_time_average!(wta::WindowedTimeAverage, model)

    unscheduled = model.clock.iteration == 0 || outside_window(wta.schedule, model.clock)
    if !(unscheduled)
        if !(wta.schedule.collecting)
            # Zero out result to begin new accumulation window
            wta.result .= 0

            # Begin collecting window-averaged increments
            wta.schedule.collecting = true

            wta.window_start_time = next_actuation_time(wta.schedule) - wta.schedule.window
            wta.previous_collection_time = wta.window_start_time
            wta.window_start_iteration = model.clock.iteration - 1
        end

        if end_of_window(wta.schedule, model.clock)
            accumulate_result!(wta, model)
            # Save averaging start time and the initial data collection time
            wta.schedule.collecting = false
            wta.schedule.actuations += 1

        elseif mod(model.clock.iteration - wta.window_start_iteration, stride(wta)) == 0
            accumulate_result!(wta, model)
        else
            # Off stride, so do nothing.
        end

    end
    return nothing
end

# So it can be used as a Diagnostic
run_diagnostic!(wta::WindowedTimeAverage, model) = advance_time_average!(wta, model)

Base.show(io::IO, schedule::AveragedTimeInterval) = print(io, summary(schedule))

Base.summary(schedule::AveragedTimeInterval) = string("AveragedTimeInterval(",
                                                      "window=", prettytime(schedule.window), ", ",
                                                      "stride=", schedule.stride, ", ",
                                                      "interval=", prettytime(schedule.interval),  ")")

show_averaging_schedule(schedule) = ""
show_averaging_schedule(schedule::AveragedTimeInterval) = string(" averaged on ", summary(schedule))

output_averaging_schedule(output::WindowedTimeAverage) = output.schedule

#####
##### Utils for OutputWriters
#####

time_average_outputs(schedule, outputs, model) = schedule, outputs # fallback

"""
    time_average_outputs(schedule::AveragedTimeInterval, outputs, model, field_slicer)

Wrap each `output` in a `WindowedTimeAverage` on the time-averaged `schedule` and with `field_slicer`.

Returns the `TimeInterval` associated with `schedule` and a `NamedTuple` or `Dict` of the wrapped
outputs.
"""
function time_average_outputs(schedule::AveragedTimeInterval, outputs::Dict, model)
    averaged_outputs = Dict(name => WindowedTimeAverage(output, model; schedule=copy(schedule))
                            for (name, output) in outputs)

    return TimeInterval(schedule), averaged_outputs
end

function time_average_outputs(schedule::AveragedTimeInterval, outputs::NamedTuple, model)
    averaged_outputs = NamedTuple(name => WindowedTimeAverage(outputs[name], model; schedule=copy(schedule))
                                  for name in keys(outputs))

    return TimeInterval(schedule), averaged_outputs
end

