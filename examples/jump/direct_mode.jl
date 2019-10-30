# Test JuMP in DIRECT modes [EXPERIMENTAL].

using KNITRO, JuMP
using Test
using MathOptInterface
const MOI = MathOptInterface

# hs071
# Polynomial objective and constraints
# min x1 * x4 * (x1 + x2 + x3) + x3
# st  x1 * x2 * x3 * x4 >= 25
#     x1^2 + x2^2 + x3^2 + x4^2 = 40
#     1 <= x1, x2, x3, x4 <= 5
# Start at (1,5,5,1)
# End at (1.000..., 4.743..., 3.821..., 1.379...)

# Create JuMP Model in direct mode.
model = JuMP.direct_model(KNITRO.Optimizer())

initval = [1, 5, 5, 1]

@variable(model, 1 <= x[i=1:4] <= 5, start=initval[i])
@NLobjective(model, Min, x[1] * x[4] * (x[1] + x[2] + x[3]) + x[3])
c1 = @NLconstraint(model, x[1] * x[2] * x[3] * x[4] >= 25)
c2 = @NLconstraint(model, sum(x[i]^2 for i=1:4) == 40)

JuMP.optimize!(model)

@test JuMP.has_values(model)
@test JuMP.termination_status(model) == MOI.LOCALLY_SOLVED
@test JuMP.primal_status(model) == MOI.FEASIBLE_POINT

@test JuMP.value.(x) ≈ [1.000000, 4.742999, 3.821150, 1.379408] atol=1e-3
