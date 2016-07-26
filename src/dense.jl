# A higher level solver, defined as a wrapper around an integrator.

"""

Dense output options:

- tout    ::Vector{T}  output times

TODO options:

- points   ::Symbol which points are returned: `:specified` only the
  ones in tspan or `:all` which includes also the step-points of the solver.
- stopevent   Stop integration at a zero of this function
- roottol

"""

immutable DenseOptions{T<:Number} <: Options{T}
    tout::Vector{T} # TODO: this should an AbstractVector
    # points   ::Symbol
    # stopevent::S
    # roottol  ::T
end

@compat function (::Type{DenseOptions{T}}){T}(;
                                              tstop        = T(Inf),
                                              tout::Vector = T[tstop],
                                              # points::Symbol= :all,
                                              # stopevent::S  = (t,y)->false,
                                              # roottol       = eps(T)^T(1//3),
                                              kargs...)
    DenseOptions{T}(tout)
end


"""

A solver specialized in dense output; it wraps an integrator. It
stores the subsequent steps generated by `Problem` and interpolates
the results (currently this means at the output times stored in
`opts.tout`).

"""
immutable DenseOutput{I<:AbstractIntegrator,OP<:DenseOptions} <: AbstractSolver
    integ::I  # TODO: Maybe this should be relaxed to a AbstractSolver?
              #       Then we could have a DenseOutput{DenseOutput{RK}}, say!
    opts::OP
end

function solve{I}(ivp::IVP,
                  ::Type{DenseOutput{I}};
                  opts...)
    T = eltype(ivp)[1]
    # create integrator
    integ = I{T}(; opts...)
    # create dense solver
    dense_opts = DenseOptions{T}(; opts...)
    dense_solver = DenseOutput(integ, dense_opts)
    return Problem(ivp, dense_solver)
end

"""

The state of the dense solver `DenseOutput`.

"""
type DenseState{St<:AbstractState,T,Y} <: AbstractState{T,Y}
    tout_i::Int
    step_prev::Step{T,Y}
    step_out::Step{T,Y}
    integrator_state::St
end

output(ds::DenseState) = output(ds.step_out)

function init(ivp::IVP,
              solver::DenseOutput)
    integrator_state = init(ivp, solver.integ)
    dy0 = similar(ivp.y0)
    ivp.F!(ivp.t0,ivp.y0,dy0)
    step_prev = Step(ivp.t0,copy(ivp.y0),dy0)
    step_out = Step(ivp.t0,similar(ivp.y0),similar(ivp.y0))
    return DenseState(1,step_prev,step_out,integrator_state)
end


"""

TODO: rename `tout` to `tout` and drop the support for
`points=:all` outside of the `odeXX`?  Maybe even
`odeXX(;tout=[...])` would use dense output while `odeXX(;)`
wouldn't.

"""

function onestep!(ivp::IVP,
                  solver::DenseOutput,
                  dstate::DenseState)
    i = dstate.tout_i
    if i > length(solver.opts.tout)
        return finish
    end

    # the underlying integrator
    integ = solver.integ

    # our next output time
    ti = solver.opts.tout[i]

    istate = dstate.integrator_state


    # try to get a new set of steps enclosing `ti`, if all goes
    # right we end up with t∈[t1,t2] with
    # t1,_=output(dstate.step_prev)
    # t2,_=output(dstate.integrator_state)
    status = next_interval!(ivp, integ, istate, dstate.step_prev, ti)
    if status == abort
        # we failed to get enough steps
        warn("Iterator was exhausted before the dense output could produce the output.")
        return abort
    else
        # we got the steps, proceed with the interpolation, this fills
        # the dstate.step_out with y(ti) and y'(ti) according to an
        # interpolation algorithm specific for a method (defaults to
        # hermite O(3)).
        interpolate!(istate, dstate.step_prev, ti, dstate.step_out)

        # increase the counter
        dstate.tout_i += 1
        return cont
    end
end

"""

Takes steps using the underlying integrator until it reaches a first
step such that `t>=tout`.  It fills the `steps` variable with
(Step(t1,y(t1),dy(t1)),Step(t2,y(t2),dy(t2))), where `t1` is is the
step before `tout` and `t2` is `>=tout`.  In other words
`tout∈[t1,t2]`.
"""
function next_interval!(ivp, integ, istate, step_prev, tout)
    td = tdir(ivp, integ)
    while true
        # get the current time
        t1   = step_prev.t
        t2,_ = output(istate)

        if td*t1 <= td*tout <= td*t2
            # we found the enclosing times
            return cont
        end

        # save the current state of solution
        t, y, dy = output(istate)
        step_prev.t = t
        copy!(step_prev.y,y)
        copy!(step_prev.dy,dy)

        # try to perform a single step:
        status = onestep!(ivp, integ, istate)

        if status != cont
            return status
        end
    end

    # this will never happen
    return abort
end


"""
Makes dense output

interpolate!(istate::AbstractState, step_prev::Step, tout, step_out::Step)

Input:

- `istate::AbstractState` state of the integrator
- `step_prev` the previous step, part of `dstate`
- tout -- time of requested output
- step_out::Step -- inplace output step

Output: nothing

TODO: output dy too

TOOD: provide arbitrary order dense output. Maybe use work of @obiajulu on A-B-M methods.
"""
function interpolate! end

"""
Make dense output using Hermite interpolation of order O(3), should
work for most integrators and is used as default.  This only needs y
and dy at t1 and t2.

Ref: Hairer & Wanner p.190
"""
function interpolate!(istate::AbstractState,
                      step_prev::Step,
                      tout,
                      step_out::Step)
    t1,y1,dy1 = output(step_prev)
    t2,y2,dy2 = output(istate)
    if tout==t1
        copy!(step_out.y,y1)
    elseif tout==t2
        copy!(step_out.y,y2)
    else
        dt       = t2-t1
        theta    = (tout-t1)/dt
        for i=1:length(y1)
            step_out.y[i] =
                (1-theta)*y1[i] +
                theta*y2[i] +
                theta*(theta-1) *
                ( (1-2*theta)*(y2[i]-y1[i]) +
                  (theta-1)*dt*dy1[i] +
                  theta*dt*dy2[i])
        end
    end
    step_out.t = tout
    return nothing
end
