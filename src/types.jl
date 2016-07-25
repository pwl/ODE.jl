# The main types:
# - IVP -- holds the mathematical aspects of a IVP
# - AbstractStepper -- an integrator/solver  (maybe AbstractIntegrator?)
# - Solver -- holds IVP + Stepper (maybe ProblemSpec, Problem, Spec?)
# - AbstractState -- holds the iterator state
#   - Step -- holds the state at one time
# -


abstract AbstractIVP{T,Y}
Base.eltype{T,Y}(::Type{AbstractIVP{T,Y}}) = T,Y

"""

Defines the mathematical part of an IVP (initial value problem)
specified in the general form:

`F(t, y) =  G(t, y, dy)` with `y(t0)= y0`

Depending on the combination of the parameters this type can represent
a wide range of problems, including ODE, DAE and IMEX.  Nevertheless
not all solvers will support any combinations of `F` and `G`.  Note
that not specifying `G` amounts to `G=dy/dt`.


- `tspan` -- tuple `(start_t,end_t)`
- `y0` -- initial condition
- `F!` -- in-place `F` function `F!(t,y,res)`.  If `F=0` set to `nothing`.
- `G!` -- in-place `G` function `G!(t,y,dy,res)`.  If `G=dy/dt` then
          set to `nothing` (or `dy` if the solver supports this).  Can
          also be a mass matrix for a RHS `M dy/dt`
- `J!` -- in-place Jacobian function `J!(t,y,dy,res)`.

TODO: how to fit the sparsity pattern in J?

"""
type IVP{T,Y,F,G,J} <: AbstractIVP{T,Y}
    t0  ::T
    y0  ::Y
    dy0 ::Y
    F!  ::F
    G!  ::G
    J!  ::J
end
@compat Base.eltype(t::Type{IVP}) = eltype(supertype(t))
Base.eltype(t::IVP) = eltype(typeof(t))


"""

Explicit ODE representing the problem

`dy = F(t,y)` with `y(t0)=y0`

- t0, y0: initial conditions
- F!: in place version of `F` called by `F!(t,y,dy)`
- J!: (optional) computes `J=dF/dy` in place, called with `J!(t,y,J)`

"""
typealias ExplicitODE{T,Y} IVP{T,Y,Function,Void,Function}
@compat function (::Type{ExplicitODE}){T,Y}(t0::T,
                                            y0::Y,
                                            F!::Function;
                                            J!::Function = forward_jacobian!(F!,similar(y0)),
                                            kargs...)
    ExplicitODE{T,Y}(t0,y0,similar(y0),F!,nothing,J!)
end

"""

Implicit ODE representing the problem

`G(t,y,dy)=0` with `y(t0)=y0` and optionally `y'(t0)=dy0`

- t0, y0: initial conditions
- G!: in place version of `G` called by `G!(res,t,y,dy)`,
      returns residual in-place in `res`.
- J!: (optional) computes `J=dF/dy+a*dF/dy'` for prescribed `a`, called with `J!(out,t,y,dy,a)`.
      Returns Jacobian in-place in `out`.

"""
typealias ImplicitODE{T,Y} IVP{T,Y,Void,Function,Function}
@compat function (::Type{ImplicitODE}){T,Y}(t0::T,
                                            y0::Y,
                                            G!::Function;
                                            J!::Function = forward_jacobian_implicit!(G!,similar(y0)),
                                            dy0::Y = zero(y0),
                                            kargs...)
    ImplicitODE{T,Y}(t0,y0,dy0,nothing,G!,J!)
end

"""

The abstract type of the actual algorithm to solve an ODE.

"""
abstract AbstractStepper{T}


"""

AbstractState keeps the temporary data (state) for the iterator
Solver{::AbstractStepper}.

"""
abstract AbstractState{T,Y}

# m3:
# - docs
# - maybe use the typevars as defined in make_consistent_types for t,
#   y, dy?  T->Et, S->Ty
#   (or something else consistent throughout, maybe nicer would be all
#   uppercase: ET, EFY, TT, TY).
# - if find `Step` a bit confusing name, in particular combined with
#   AbstractStepper, but not sure what's better.

"""

Holds a value of a function and its derivative at time t.  This is
usually used to store the solution of an ODE at particular times.

"""
type Step{T,Y}
    t ::T
    y ::Y
    dy::Y
end


function show(io::IO, state::Step)
    println("t  =$(state.t)")
    println("y  =$(state.y)")
    println("dy =$(state.dy)")
end


"""

This is an iterable type, each call to next(...) produces a next step
of a numerical solution to an ODE.

- ode: is the prescrived ode, along with the initial data
- stepper: the algorithm used to produce subsequent steps


"""
immutable Solver{O<:AbstractIVP,S<:AbstractStepper}
    ode     ::O
    stepper ::S
end
#m3:
# - calling this `Solver` still trips me up

Base.eltype{O}(::Type{Solver{O}}) = eltype(O)
Base.eltype{O}(::Solver{O}) = eltype(O)

# filter the wrong combinations of ode and stepper
solve{O,S}(ode::O, stepper::Type{S}, options...) =
    error("The $S doesn't support $O")

# In Julia 0.5 the collect needs length to be defined, we cannot do
# that for a solver but we can implement our own collect
function collect(s::Solver)
    T,Y = eltype(s)
    pairs = Array(Tuple{T,Y},0)
    for (t,y) in s
        push!(pairs,(t,copy(y)))
    end
    return pairs
end


# Iteration: take one step on a ODE/DAE `Problem`
#
# Defines:
# start(iter) -> state
# next(iter, state) -> output(state), state
# done(iter, state) -> bool
#
# Perhaps unintuitively, the next step is computed in `done`.  Such
# implementation allows to decide if the iterator is exhausted in case
# when the next step was computed but it was deemed incorrect.  In
# such situation `done` returns `false` after computing the step and
# the failed step never sees the light of the day (by not being
# returned by `next`).
#
# TODO: this implementation fails to return the zeroth step (t0,y0)
#
# TODO: store the current Step outside of the actual state
# Base.start(sol::Solver) = (init(sol), Step(ode.sol))

Base.start(sol::Solver) = init(sol)

function Base.done(s::Solver, st)
    # Determine whether the next step can be made by calling the
    # stepping routine.  onestep! will take the step in-place.
    finished = onestep!(s, st)
    return finished
end

function Base.next(sol::Solver, st)
    # Output the step (we know that `done` allowed it, so we are safe
    # to do it)
    return output(st), st
end

#m3: I don't think it makes sense to type-fy this.  TODO: delete
# """
# TODO: Holds the solver status after onestep.
# """
# type Status{T} end
# successful(status::Status) = status == StatusContinue
# const StatusContinue = Status{:cont}()
# const StatusFailed = Status{:failed}()
# const StatusFinished = Status{:finished}()
"""
Holds the solver status, used inside of `onestep!`.

Values:

- cont -- continue integration
- abort -- abort integration
- finish -- integration reached the end
"""
@enum Status cont abort finish # TODO these need better names

#####
# Interface to implement by solvers to hook into iteration
#####
#
# See runge_kutta.jl and rosenbrock.jl for example implementations.

# A stepper has to implement
# - init
# - output
# and either
# - onestep!
# - trialstep!, errorcontrol! and accept!

# Just to make it more readable below
const _notdone = false
const _done = true

"""

Take a step, modifies `state` in-place.  This is the core function to
be implemented by a solver.  However, if possible solvers should opt
to implement the sub-step functions `trialstep!`, `errorcontrol!` and
`accept!`, instead of directly `onestep!`.

Input:

- sol::Solver, state::AbstractState

Output:

- Bool: `false`: continue iteration, `true`: terminate iteration.

substeps.
"""
function onestep!(sol::Solver, state::AbstractState)
    opt = sol.stepper.options
    while true
        status = trialstep!(sol, state)
        # This could be moved into a @check macro:
        if status==abort
            warn("Abort in trialstep!")
            return _done
        elseif status==finish
            return _done
        end

        err, status_err = errorcontrol!(sol, state)
        if status_err==abort
            warn("Abort in errorcontrol!")
            return _done
        end
        if err<=1 && status==cont
            # a successful step
            status_acc = accept!(sol, state)
            if status_acc==abort
                warn("Abort in accept!")
                return _done
            else
                return _notdone
            end
        end
        # if we get here: try step again with updated state (step
        # size, order) as done inside errorcontrol!
    end
end


# TODO: the docs here are still confusing, I would rather have a
# separate type to store the `accepted` step (perhaps `Step`?) and
# call `trialstep!(solver,state,step)` to fill the `state` with the
# newly made step, then `accept!(solver,state,step)` would use the
# data in `state` to fill the `step` with new step.  This way we could
# also implement a standard `output` function that would work on
# `step` instead of `state`.  The step would contain the current state
# of the solution: `(t,y)` at minimum, but it could also be
# `(t,y,dy,dt)`.  Thoughts?
#
#m3: No, that doesn't work if we want to allow zero-allocation
#    algorithms.  Unless you make `step` part of `state` but then it
#    becomes pointless.

"""

Advances the solution by trying to compute a single step.  The new
step is kept in the `state` in work arrays so that `errorcontrol!` can
compute the magnitude of its error.  If the error is small enough
`accept!` updates `state` to reflect the state at the new time.

Returns `Status`.

"""
trialstep!{O,S}(::Solver{O,S}, ::AbstractState) =
    error("Function `trialstep!` and companions (or alternatively `onestep!`) need to be implemented for adaptive solver $S")

"""

Estimates the error (such that a step is accepted if err<=1).
Depending on the stepper it may update the state, e.g. by computing a
new dt or a new order (but not by computing a new solution!).

Returns `(err,Status)`.

If the `status==abort` then the integration is aborted, status values
of `cont` and `finish` are ignored.

"""
errorcontrol!{T}(::Solver,::AbstractState{T}) =
    error("Function `errorcontrol!` and companions (or alternatively `onestep!`) need to be implemented for adaptive solver $S")

"""

Accepts (in-place) the computed step.  Called if `errorcontrol!` gave
a small enough error.

Returns `Status`.

"""
accept!{O,S}(::Solver{O,S}, ::AbstractState) =
    error("Function `accept!` and companions (or alternatively `onestep!`) need to be implemented for adaptive solver $S")
