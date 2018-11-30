# import KNITRO's MOIWrapper
# This file is largely inspired from:
# https://github.com/JuliaOpt/Ipopt.jl/blob/master/src/MOIWrapper.jl
# The authors are indebted to the developpers of Ipopt.jl for
# the current MOI wrapper.
#
#
import MathOptInterface
const MOI = MathOptInterface

##################################################
# import legacy from LinQuadOptInterface to ease the integration
# of KNITRO quadratic and linear facilities
"""
    canonical_quadratic_reduction(func::Quad)

Reduce a ScalarQuadraticFunction into three arrays, returned in the following
order:
 3. a vector of quadratic row indices
 4. a vector of quadratic column indices
 5. a vector of quadratic coefficients

Warning: we assume in this function that all variables are correctly
ordered, that is no deletion or swap has occured.
"""
function canonical_quadratic_reduction(func::MOI.ScalarQuadraticFunction)
    quad_columns_1, quad_columns_2, quad_coefficients = (
        [term.variable_index_1 for term in func.quadratic_terms],
        [term.variable_index_2 for term in func.quadratic_terms],
        [term.coefficient for term in func.quadratic_terms]
    )
    return quad_columns_1, quad_columns_2, quad_coefficients
end

"""
    canonical_linear_reduction(func::Quad)

Reduce a ScalarQuadraticFunction into two arrays, returned in the following
order:
 1. a vector of quadratic column indices
 2. a vector of linear coefficients

Warning: we assume in this function that all variables are correctly
ordered, that is no deletion or swap has occured.
"""
function canonical_linear_reduction(func::Union{MOI.ScalarLinearFunction, MOI.ScalarQuadraticFunction})
    affine_columns = [term.variable_index for term in func.affine_terms]
    affine_coefficients = [term.coefficient for term in func.affine_terms]
    return affine_columns, affine_coefficients
end


##################################################

mutable struct VariableInfo
    lower_bound::Float64  # May be -Inf even if has_lower_bound == true
    has_lower_bound::Bool # Implies lower_bound == Inf
    upper_bound::Float64  # May be Inf even if has_upper_bound == true
    has_upper_bound::Bool # Implies upper_bound == Inf
    is_fixed::Bool        # Implies lower_bound == upper_bound and !has_lower_bound and !has_upper_bound.
    start::Float64
end
# The default start value is zero.
VariableInfo() = VariableInfo(-Inf, false, Inf, false, false, 0.0)

mutable struct Optimizer <: MOI.AbstractOptimizer
    inner::Union{Model, Nothing}
    # we only keep in memory some information about variables
    # as we cannot delete variables, we do not have to store an index
    variable_info::Vector{VariableInfo}
    nlp_data::MOI.NLPBlockData
    sense::MOI.OptimizationSense
    objective::Union{MOI.SingleVariable,MOI.ScalarAffineFunction{Float64},MOI.ScalarQuadraticFunction{Float64},Nothing}
    # linear constraint
    linear_le_constraints::Vector{Tuple{MOI.ScalarAffineFunction{Float64}, MOI.LessThan{Float64}}}
    linear_ge_constraints::Vector{Tuple{MOI.ScalarAffineFunction{Float64}, MOI.GreaterThan{Float64}}}
    linear_eq_constraints::Vector{Tuple{MOI.ScalarAffineFunction{Float64}, MOI.EqualTo{Float64}}}
    # quadratic constraint
    quadratic_le_constraints::Vector{Tuple{MOI.ScalarQuadraticFunction{Float64}, MOI.LessThan{Float64}}}
    quadratic_ge_constraints::Vector{Tuple{MOI.ScalarQuadraticFunction{Float64}, MOI.GreaterThan{Float64}}}
    quadratic_eq_constraints::Vector{Tuple{MOI.ScalarQuadraticFunction{Float64}, MOI.EqualTo{Float64}}}
    options
end

struct EmptyNLPEvaluator <: MOI.AbstractNLPEvaluator end
MOI.features_available(::EmptyNLPEvaluator) = [:Grad, :Jac, :Hess]
MOI.initialize(::EmptyNLPEvaluator, features) = nothing
MOI.eval_objective(::EmptyNLPEvaluator, x) = NaN
function MOI.eval_constraint(::EmptyNLPEvaluator, g, x)
    @assert length(g) == 0
    return
end
MOI.eval_objective_gradient(::EmptyNLPEvaluator, g, x) = nothing
MOI.jacobian_structure(::EmptyNLPEvaluator) = Tuple{Int64,Int64}[]
MOI.hessian_lagrangian_structure(::EmptyNLPEvaluator) = Tuple{Int64,Int64}[]
function MOI.eval_constraint_jacobian(::EmptyNLPEvaluator, J, x)
    @assert length(J) == 0
    return
end
function MOI.eval_hessian_lagrangian(::EmptyNLPEvaluator, H, x, σ, μ)
    @assert length(H) == 0
    return
end


empty_nlp_data() = MOI.NLPBlockData([], EmptyNLPEvaluator(), false)


Optimizer(;options...) = Optimizer(KN_new(), [], empty_nlp_data(), MOI.FeasibilitySense, nothing, [], [], [], [], [], [], 0, Dict(), options)

MOI.supports(::Optimizer, ::MOI.NLPBlock) = true
MOI.supports(::Optimizer, ::MOI.ObjectiveFunction{MOI.SingleVariable}) = true
MOI.supports(::Optimizer, ::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}) = true
MOI.supports(::Optimizer, ::MOI.ObjectiveFunction{MOI.ScalarQuadraticFunction{Float64}}) = true
MOI.supports(::Optimizer, ::MOI.ObjectiveSense) = true
MOI.supports_constraint(::Optimizer, ::Type{MOI.SingleVariable}, ::Type{MOI.LessThan{Float64}}) = true
MOI.supports_constraint(::Optimizer, ::Type{MOI.SingleVariable}, ::Type{MOI.GreaterThan{Float64}}) = true
MOI.supports_constraint(::Optimizer, ::Type{MOI.SingleVariable}, ::Type{MOI.EqualTo{Float64}}) = true
MOI.supports_constraint(::Optimizer, ::Type{MOI.ScalarAffineFunction{Float64}}, ::Type{MOI.LessThan{Float64}}) = true
MOI.supports_constraint(::Optimizer, ::Type{MOI.ScalarAffineFunction{Float64}}, ::Type{MOI.GreaterThan{Float64}}) = true
MOI.supports_constraint(::Optimizer, ::Type{MOI.ScalarAffineFunction{Float64}}, ::Type{MOI.EqualTo{Float64}}) = true
MOI.supports_constraint(::Optimizer, ::Type{MOI.ScalarQuadraticFunction{Float64}}, ::Type{MOI.LessThan{Float64}}) = true
MOI.supports_constraint(::Optimizer, ::Type{MOI.ScalarQuadraticFunction{Float64}}, ::Type{MOI.GreaterThan{Float64}}) = true
MOI.supports_constraint(::Optimizer, ::Type{MOI.ScalarQuadraticFunction{Float64}}, ::Type{MOI.EqualTo{Float64}}) = true

function MOI.copy_to(model::Optimizer, src::MOI.ModelLike; copy_names = false)
    return MOI.Utilities.default_copy_to(model, src, copy_names)
end

MOI.get(model::Optimizer, ::MOI.NumberOfVariables) = length(model.variable_info)

function MOI.get(model::Optimizer, ::MOI.ListOfVariableIndices)
    return [MOI.VariableIndex(i) for i in 1:length(model.variable_info)]
end


function MOI.set(model::Optimizer, ::MOI.ObjectiveSense,
                 sense::MOI.OptimizationSense)
    model.sense = sense
    if model.sense == MOI.MaxSense
        KN_set_obj_goal(model.inner, KN_OBJGOAL_MAXIMIZE)
    elseif model.sense == MOI.MinSense
        KN_set_obj_goal(model.inner, KN_OBJGOAL_MINIMIZE)
    end
    return
end

function MOI.empty!(model::Optimizer)
    # free KNITRO model properly
    KN_free(model.inner)
    # set null pointer to inner model
    model.inner = nothing
    empty!(model.variable_info)
    model.nlp_data = empty_nlp_data()
    model.sense = MOI.FeasibilitySense
    model.objective = nothing
    empty!(model.linear_le_constraints)
    empty!(model.linear_ge_constraints)
    empty!(model.linear_eq_constraints)
    empty!(model.quadratic_le_constraints)
    empty!(model.quadratic_ge_constraints)
    empty!(model.quadratic_eq_constraints)
end

function MOI.is_empty(model::Optimizer)
    return isempty(model.variable_info) &&
           model.nlp_data.evaluator isa EmptyNLPEvaluator &&
           model.sense == MOI.FeasibilitySense &&
           isempty(model.linear_le_constraints) &&
           isempty(model.linear_ge_constraints) &&
           isempty(model.linear_eq_constraints) &&
           isempty(model.quadratic_le_constraints) &&
           isempty(model.quadratic_ge_constraints) &&
           isempty(model.quadratic_eq_constraints)
end

function MOI.add_variable(model::Optimizer)
    push!(model.variable_info, VariableInfo())
    KN_add_var(model.inner)
    return MOI.VariableIndex(length(model.variable_info))
end
# TODO: maybe we can rewrite this function to go faster
function MOI.add_variables(model::Optimizer, n::Int)
    return [MOI.add_variable(model) for i in 1:n]
end

function check_inbounds(model::Optimizer, vi::MOI.VariableIndex)
    num_variables = length(model.variable_info)
    if !(1 <= vi.value <= num_variables)
        error("Invalid variable index $vi. ($num_variables variables in the model.)")
    end
end

function check_inbounds(model::Optimizer, var::MOI.SingleVariable)
    return check_inbounds(model, var.variable)
end

function check_inbounds(model::Optimizer, aff::MOI.ScalarAffineFunction)
    for term in aff.terms
        check_inbounds(model, term.variable_index)
    end
end

function check_inbounds(model::Optimizer, quad::MOI.ScalarQuadraticFunction)
    for term in quad.affine_terms
        check_inbounds(model, term.variable_index)
    end
    for term in quad.quadratic_terms
        check_inbounds(model, term.variable_index_1)
        check_inbounds(model, term.variable_index_2)
    end
end

function has_upper_bound(model::Optimizer, vi::MOI.VariableIndex)
    return model.variable_info[vi.value].has_upper_bound
end

function has_lower_bound(model::Optimizer, vi::MOI.VariableIndex)
    return model.variable_info[vi.value].has_lower_bound
end

function is_fixed(model::Optimizer, vi::MOI.VariableIndex)
    return model.variable_info[vi.value].is_fixed
end

#--------------------------------------------------
# Bound constraint on variables
function MOI.add_constraint(model::Optimizer, v::MOI.SingleVariable, lt::MOI.LessThan{Float64})
    vi = v.variable
    check_inbounds(model, vi)
    if isnan(lt.upper)
        error("Invalid upper bound value $(lt.upper).")
    end
    if has_upper_bound(model, vi)
        error("Upper bound on variable $vi already exists.")
    end
    if is_fixed(model, vi)
        error("Variable $vi is fixed. Cannot also set upper bound.")
    end
    model.variable_info[vi.value].upper_bound = lt.upper
    model.variable_info[vi.value].has_upper_bound = true
    # we assume that MOI's indexing is the same as KNITRO's indexing
    KN_set_var_upbnds(model.inner, vi.value, lt.value)
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}(vi.value)
end

function MOI.add_constraint(model::Optimizer, v::MOI.SingleVariable, gt::MOI.GreaterThan{Float64})
    vi = v.variable
    check_inbounds(model, vi)
    if isnan(gt.lower)
        error("Invalid lower bound value $(gt.lower).")
    end
    if has_lower_bound(model, vi)
        error("Lower bound on variable $vi already exists.")
    end
    if is_fixed(model, vi)
        error("Variable $vi is fixed. Cannot also set lower bound.")
    end
    model.variable_info[vi.value].lower_bound = gt.lower
    model.variable_info[vi.value].has_lower_bound = true
    # we assume that MOI's indexing is the same as KNITRO's indexing
    KN_set_var_lobnds(model.inner, vi.value, gt.value)
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}(vi.value)
end

function MOI.add_constraint(model::Optimizer, v::MOI.SingleVariable, eq::MOI.EqualTo{Float64})
    vi = v.variable
    check_inbounds(model, vi)
    if isnan(eq.value)
        error("Invalid fixed value $(gt.lower).")
    end
    if has_lower_bound(model, vi)
        error("Variable $vi has a lower bound. Cannot be fixed.")
    end
    if has_upper_bound(model, vi)
        error("Variable $vi has an upper bound. Cannot be fixed.")
    end
    if is_fixed(model, vi)
        error("Variable $vi is already fixed.")
    end
    model.variable_info[vi.value].lower_bound = eq.value
    model.variable_info[vi.value].upper_bound = eq.value
    model.variable_info[vi.value].is_fixed = true
    # we assume that MOI's indexing is the same as KNITRO's indexing
    KN_set_var_fxbnds(model.inner, vi.value, eq.value)
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}(vi.value)
end

#--------------------------------------------------
# generic constraint definition
macro define_add_constraint(function_type, set_type, array_name)
    quote
        function MOI.add_constraint(model::Optimizer, func::$function_type, set::$set_type)
            check_inbounds(model, func)
            push!(model.$(array_name), (func, set))
            # we add a constraint in KNITRO
            KN_add_con(model.inner)
            return MOI.ConstraintIndex{$function_type, $set_type}(length(model.$(array_name)))
        end
    end
end

# we pass only ScalarAffineFunction and ScalarQuadraticFunction as
# NLP constraints are specified in callbacks
@define_add_constraint(MOI.ScalarAffineFunction{Float64}, MOI.LessThan{Float64},
                       linear_le_constraints)
@define_add_constraint(MOI.ScalarAffineFunction{Float64},
                       MOI.GreaterThan{Float64}, linear_ge_constraints)
@define_add_constraint(MOI.ScalarAffineFunction{Float64}, MOI.EqualTo{Float64},
                       linear_eq_constraints)
@define_add_constraint(MOI.ScalarQuadraticFunction{Float64},
                       MOI.LessThan{Float64}, quadratic_le_constraints)
@define_add_constraint(MOI.ScalarQuadraticFunction{Float64},
                       MOI.GreaterThan{Float64}, quadratic_ge_constraints)
@define_add_constraint(MOI.ScalarQuadraticFunction{Float64},
                       MOI.EqualTo{Float64}, quadratic_eq_constraints)

#--------------------------------------------------
# Primal and dual warmstart
function MOI.supports(::Optimizer, ::MOI.VariablePrimalStart,
                      ::Type{MOI.VariableIndex})
    return true
end
function MOI.set(model::Optimizer, ::MOI.VariablePrimalStart,
                 vi::MOI.VariableIndex, value::Real)
    check_inbounds(model, vi)
    model.variable_info[vi.value].start = value
    KN_set_var_primal_init_values(model.inner, vi.value, value)
    return
end

function MOI.supports(::Optimizer, ::MOI.ConstraintDualStart,
                      ::Type{MOI.VariableIndex})
    return true
end
function MOI.set(model::Optimizer, ::MOI.VariablePrimalStart,
                 ci::MOI.ConstraintIndex, value::Real)
    check_inbounds(model, ci)
    KN_set_con_dual_init_values(model.inner, ci.value, value)
    return
end

function MOI.set(model::Optimizer, ::MOI.NLPBlock, nlp_data::MOI.NLPBlockData)
    model.nlp_data = nlp_data
    return
end

function MOI.set(model::Optimizer, ::MOI.ObjectiveFunction,
                 func::Union{MOI.SingleVariable, MOI.ScalarAffineFunction,
                             MOI.ScalarQuadraticFunction})
    check_inbounds(model, func)
    model.objective = func
    return
end

# In setting up the data for KNITRO, we order the constraints as follows:
# - linear_le_constraints
# - linear_ge_constraints
# - linear_eq_constraints
# - quadratic_le_constraints
# - quadratic_ge_constraints
# - quadratic_eq_constraints
# - nonlinear constraints from nlp_data

linear_le_offset(model::Optimizer) = 0
linear_ge_offset(model::Optimizer) = length(model.linear_le_constraints)
linear_eq_offset(model::Optimizer) = linear_ge_offset(model) + length(model.linear_ge_constraints)
quadratic_le_offset(model::Optimizer) = linear_eq_offset(model) + length(model.linear_eq_constraints)
quadratic_ge_offset(model::Optimizer) = quadratic_le_offset(model) + length(model.quadratic_le_constraints)
quadratic_eq_offset(model::Optimizer) = quadratic_ge_offset(model) + length(model.quadratic_ge_constraints)
nlp_constraint_offset(model::Optimizer) = quadratic_eq_offset(model) + length(model.quadratic_eq_constraints)
get_number_linear_constraints(model::Optimizer) = quadratic_le_offset(model)

# Convenience functions used only in optimize!

function eval_function(var::MOI.SingleVariable, x)
    return x[var.variable.value]
end

function eval_function(aff::MOI.ScalarAffineFunction, x)
    function_value = aff.constant
    for term in aff.terms
        # Note the implicit assumtion that VariableIndex values match up with
        # x indices. This is valid because in this wrapper ListOfVariableIndices
        # is always [1, ..., NumberOfVariables].
        function_value += term.coefficient*x[term.variable_index.value]
    end
    return function_value
end

function eval_function(quad::MOI.ScalarQuadraticFunction, x)
    function_value = quad.constant
    for term in quad.affine_terms
        function_value += term.coefficient*x[term.variable_index.value]
    end
    for term in quad.quadratic_terms
        row_idx = term.variable_index_1
        col_idx = term.variable_index_2
        coefficient = term.coefficient
        if row_idx == col_idx
            function_value += 0.5*coefficient*x[row_idx.value]*x[col_idx.value]
        else
            function_value += coefficient*x[row_idx.value]*x[col_idx.value]
        end
    end
    return function_value
end

function eval_objective(model::Optimizer, x)
    @assert !(model.nlp_data.has_objective && model.objective !== nothing)
    if model.nlp_data.has_objective
        return MOI.eval_objective(model.nlp_data.evaluator, x)
    elseif model.objective !== nothing
        return eval_function(model.objective, x)
    else
        # No objective function set. This could happen with FeasibilitySense.
        return 0.0
    end
end

function fill_gradient!(grad, x, var::MOI.SingleVariable)
    fill!(grad, 0.0)
    grad[var.variable.value] = 1.0
end

function fill_gradient!(grad, x, aff::MOI.ScalarAffineFunction{Float64})
    fill!(grad, 0.0)
    for term in aff.terms
        grad[term.variable_index.value] += term.coefficient
    end
end

function fill_gradient!(grad, x, quad::MOI.ScalarQuadraticFunction{Float64})
    fill!(grad, 0.0)
    for term in quad.affine_terms
        grad[term.variable_index.value] += term.coefficient
    end
    for term in quad.quadratic_terms
        row_idx = term.variable_index_1
        col_idx = term.variable_index_2
        coefficient = term.coefficient
        if row_idx == col_idx
            grad[row_idx.value] += coefficient*x[row_idx.value]
        else
            grad[row_idx.value] += coefficient*x[col_idx.value]
            grad[col_idx.value] += coefficient*x[row_idx.value]
        end
    end
end

function eval_objective_gradient(model::Optimizer, grad, x)
    @assert !(model.nlp_data.has_objective && model.objective !== nothing)
    if model.nlp_data.has_objective
        MOI.eval_objective_gradient(model.nlp_data.evaluator, grad, x)
    elseif model.objective !== nothing
        fill_gradient!(grad, x, model.objective)
    end
    return
end

function parse_cons_linear_struct(model::Optimizer)

    indexCons = []
    indexVars = []
    coefs = []

    index_cons = 0
    for constraint_expr in [model.linear_le_constraints,
                            model.linear_ge_constraints,
                            model.linear_eq_constraints,
                            model.quadratic_le_constraints,
                            model.quadratic_ge_constraints,
                            model.quadratic_eq_constraints]

        currentvars, currentcoefs = canonical_linear_reduction(constraint_expr)
        push!(indexCons, fill(index_cons, length(currentvars))...)
        push!(indexVars, currentvars...)
        push!(coefs, currentcoefs...)

        index_cons += 1
    end

    return indexCons, indexVars, coefs
end

function parse_cons_quad_struct(model::Optimizer)
    indexCons = []
    indexVars1 = []
    indexVars2 = []
    coefs = []

    index_cons = get_number_linear_constraints(model)
    for constraint_expr in [model.quadratic_le_constraints,
                            model.quadratic_ge_constraints,
                            model.quadratic_eq_constraints]

        currentvars1, currentvars2, currentcoefs = canonical_quad_reduction(constraint_expr)
        push!(indexCons, fill(index_cons, length(currentvars1))...)
        push!(indexVars1, currentvars1...)
        push!(indexVars2, currentvars2...)
        push!(coefs, currentcoefs...)

        index_cons += 1
    end

    return indexCons, indexVars1, indexVars2, coefs
end

# get constraints upper and lower bounds
function constraint_bounds(model::Optimizer)
    constraint_lb = Float64[]
    constraint_ub = Float64[]
    for (func, set) in model.linear_le_constraints
        push!(constraint_lb, -Inf)
        push!(constraint_ub, set.upper)
    end
    for (func, set) in model.linear_ge_constraints
        push!(constraint_lb, set.lower)
        push!(constraint_ub, Inf)
    end
    for (func, set) in model.linear_eq_constraints
        push!(constraint_lb, set.value)
        push!(constraint_ub, set.value)
    end
    for (func, set) in model.quadratic_le_constraints
        push!(constraint_lb, -Inf)
        push!(constraint_ub, set.upper)
    end
    for (func, set) in model.quadratic_ge_constraints
        push!(constraint_lb, set.lower)
        push!(constraint_ub, Inf)
    end
    for (func, set) in model.quadratic_eq_constraints
        push!(constraint_lb, set.value)
        push!(constraint_ub, set.value)
    end
    for bound in model.nlp_data.constraint_bounds
        push!(constraint_lb, bound.lower)
        push!(constraint_ub, bound.upper)
    end
    return constraint_lb, constraint_ub
end

function MOI.optimize!(model::Optimizer)
    # TODO: Reuse model.inner for incremental solves if possible.
    num_variables = length(model.variable_info)
    num_linear_le_constraints = length(model.linear_le_constraints)
    num_linear_ge_constraints = length(model.linear_ge_constraints)
    num_linear_eq_constraints = length(model.linear_eq_constraints)
    nlp_row_offset = nlp_constraint_offset(model)
    num_quadratic_constraints = nlp_constraint_offset(model) -
                                quadratic_le_offset(model)
    num_nlp_constraints = length(model.nlp_data.constraint_bounds)
    num_constraints = num_nlp_constraints + nlp_row_offset

    evaluator = model.nlp_data.evaluator
    features = MOI.features_available(evaluator)
    has_hessian = (:Hess in features)
    init_feat = [:Grad]
    has_hessian && push!(init_feat, :Hess)
    num_nlp_constraints > 0 && push!(init_feat, :Jac)

    MOI.initialize(evaluator, init_feat)

    # first, we need to add the remaining NLP constraints
    # inside KNITRO
    num_nlp_constraints > 0 && KN_add_cons(model.inner, num_nlp_constraints)

    # the callbacks must match the signature of the callbacks
    # defined in knitro.h.
    # Objective callback (set both objective and constraint evaluation
    function eval_f_cb(kc, cb, evalRequest, evalResult, userParams)
        # evaluate objective:
        evalResult.obj[1] = eval_objective(model, evalRequest.x)
        # evaluate nonlinear term in constraint
        eval_constraint(model, evalResult.c, evalRequest.x)
        return 0
    end

    # Objective gradient callback
    function eval_grad_cb(kc, cb, evalRequest, evalResult, userParams)
        # evaluate non-linear term in objective gradient
        eval_objective_gradient(model, evalResult.objGrad, evalRequest.x)
        eval_constraint_jacobian(model, evalResult.objGrad, evalRequest.x)
        eval_objective_gradient(model, evalResult.jac, evalRequest.x)
    end

    if has_hessian
        # Hessian callback
        function eval_h_cb(kc, cb, evalRequest, evalResult, userParams)
            eval_hessian_lagrangian(model, evalResult.hess, evalRequest.x)
        end
    else
        eval_h_cb = nothing
    end

    # add linear structure
    # do something similar as canonical reduction
    lconIndexCons, lconIndexVars, lconCoefs = parse_cons_linear_struct(model)
    # store linear structure directly inside KNITRO
    KN_add_con_linear_struct(model.inner, lconIndexCons, lconIndexVars, lconCoefs)

    # add quadratic structure
    qconIndexCons, qconIndexVars1, qconIndexVars2, lconCoefs = parse_cons_quadratic_struct(model)
    # store quadratic structure directly inside KNITRO
    KN_add_con_quadratic_struct(model.inner, qconIndexCons,
                                qconIndexVars1, qconIndexVars2,
                                qconCoefs)

    # eventually, get constraints upper and lower bounds
    cons_lb, cons_ub = constraints_bounds(model)
    KN_set_con_upbnds(m, cons_ub)
    KN_set_con_lobnds(m, cons_lb)

    # add NLP structure
    # here, we assume that the full objective is evaluate in eval_f
    cb = KN_add_eval_callback(kc, eval_f_cb)

    # get jacobian structure
    nnzJ = length()
    if nnzJ == 0
        KN_set_cb_grad(kc, cb, eval_grad_cb)
    else
        jacob_structure = MOI.jacobian_structure(d)
        jacIndexCons =
        jacIndexVars =
        KN_set_cb_grad(kc, cb, eval_grad_cb,
                       jacIndexCons=jacIndexCons, jacIndexVars=jacIndexVars)
    end

    if has_hessian
        nnzH = length()
        # get hessian structure
        hessIndexVars1 =
        hessIndexVars2 =

        KN_set_cb_hess(kc, cb, nnzH, eval_hessian_cb,
                       hessIndexVars1=hessIndexVars1,
                       hessIndexVars2=hessIndexVars2)
    end

    # set KNITRO option
    for (name,value) in model.options
        sname = string(name)
        if name == "option_file"
            KN_load_param_file(m.inner, value)
        elseif name == "tuner_file"
            KN_load_tuner_file(m.inner, value)
        else
            if haskey(KN_paramName2Indx, name) # KN_PARAM_*
                set_param(m.inner, paramName2Indx[name], value)
            else # string name
                set_param(model.inner, sname, value)
            end
    end

    KN_solve(model.inner)
end

function MOI.get(model::Optimizer, ::MOI.TerminationStatus)
    # TODO: clean
    status = get_status(model.inner)
    if status == -1
        # chosen not to clash with any of the KTR_RC_* codes
        return :Uninitialized
    elseif status == 101
        # chosen not to clash with any of the KTR_RC_* codes
        return :Initialized
    elseif status == 0
        return MOI.Success
    elseif -109 <= status <= -100
        return :FeasibleApproximate
    elseif -209 <= status <= -200
        return MOI.Success
    elseif status == -300
        return :Unbounded
    elseif -419 <= status <= -400
        return MOI.Interrupted
    elseif -599 <= status <= -500
        return MOI.OtherError
    else
        error("Unrecognized KNITRO status $status")
    end
end

# KNITRO always has an iterate available.
function MOI.get(model::Optimizer, ::MOI.ResultCount)
    return (model.inner !== nothing) ? 1 : 0
end

function MOI.get(model::Optimizer, ::MOI.PrimalStatus)
    if model.inner === nothing
        return MOI.NoSolution
    end
    status = ApplicationReturnStatus[get_status(model.inner)]
    if status == :Solve_Succeeded
        return MOI.FeasiblePoint
    elseif status == :Feasible_Point_Found
        return MOI.FeasiblePoint
    elseif status == :Solved_To_Acceptable_Level
        # Solutions are only guaranteed to satisfy the "acceptable" convergence
        # tolerances.
        return MOI.NearlyFeasiblePoint
    elseif status == :Infeasible_Problem_Detected
        return MOI.InfeasiblePoint
    else
        return MOI.UnknownResultStatus
    end
end

function MOI.get(model::Optimizer, ::MOI.DualStatus)
    if model.inner === nothing
        return MOI.NoSolution
    end
    status = ApplicationReturnStatus[model.inner.status]
    if status == :Solve_Succeeded
        return MOI.FeasiblePoint
    elseif status == :Feasible_Point_Found
        return MOI.FeasiblePoint
    elseif status == :Solved_To_Acceptable_Level
        # Solutions are only guaranteed to satisfy the "acceptable" convergence
        # tolerances.
        return MOI.NearlyFeasiblePoint
    elseif status == :Infeasible_Problem_Detected
        # TODO: What is the interpretation of the dual in this case?
        return MOI.UnknownResultStatus
    else
        return MOI.UnknownResultStatus
    end
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveValue)
    if model.inner === nothing
        error("ObjectiveValue not available.")
    end
    return get_objective(model.inner)
end

# TODO: This is a bit off, because the variable primal should be available
# only after a solve. If model.inner is initialized but we haven't solved, then
# the primal values we return do not have the intended meaning.
function MOI.get(model::Optimizer, ::MOI.VariablePrimal, vi::MOI.VariableIndex)
    if model.inner === nothing
        error("VariablePrimal not available.")
    end
    check_inbounds(model, vi)
    return get_solution(model.inner)[vi.value]
end

macro define_constraint_primal(function_type, set_type, prefix)
    constraint_array = Symbol(string(prefix) * "_constraints")
    offset_function = Symbol(string(prefix) * "_offset")
    quote
        function MOI.get(model::Optimizer, ::MOI.ConstraintPrimal,
                         ci::MOI.ConstraintIndex{$function_type, $set_type})
            if model.inner === nothing
                error("ConstraintPrimal not available.")
            end
            if !(1 <= ci.value <= length(model.$(constraint_array)))
                error("Invalid constraint index ", ci.value)
            end
            return model.inner.g[ci.value + $offset_function(model)]
        end
    end
end

@define_constraint_primal(MOI.ScalarAffineFunction{Float64},
                          MOI.LessThan{Float64}, linear_le)
@define_constraint_primal(MOI.ScalarAffineFunction{Float64},
                          MOI.GreaterThan{Float64}, linear_ge)
@define_constraint_primal(MOI.ScalarAffineFunction{Float64},
                          MOI.EqualTo{Float64}, linear_eq)
@define_constraint_primal(MOI.ScalarQuadraticFunction{Float64},
                          MOI.LessThan{Float64}, quadratic_le)
@define_constraint_primal(MOI.ScalarQuadraticFunction{Float64},
                          MOI.GreaterThan{Float64}, quadratic_ge)
@define_constraint_primal(MOI.ScalarQuadraticFunction{Float64},
                          MOI.EqualTo{Float64}, quadratic_eq)

function MOI.get(model::Optimizer, ::MOI.ConstraintPrimal,
                 ci::MOI.ConstraintIndex{MOI.SingleVariable,
                                         MOI.LessThan{Float64}})
    if model.inner === nothing
        error("ConstraintPrimal not available.")
    end
    vi = MOI.VariableIndex(ci.value)
    check_inbounds(model, vi)
    if !has_upper_bound(model, vi)
        error("Variable $vi has no upper bound -- ConstraintPrimal not defined.")
    end
    return model.inner.x[vi.value]
end

function MOI.get(model::Optimizer, ::MOI.ConstraintPrimal,
                 ci::MOI.ConstraintIndex{MOI.SingleVariable,
                                         MOI.GreaterThan{Float64}})
    if model.inner === nothing
        error("ConstraintPrimal not available.")
    end
    vi = MOI.VariableIndex(ci.value)
    check_inbounds(model, vi)
    if !has_lower_bound(model, vi)
        error("Variable $vi has no lower bound -- ConstraintPrimal not defined.")
    end
    return model.inner.x[vi.value]
end

function MOI.get(model::Optimizer, ::MOI.ConstraintPrimal,
                 ci::MOI.ConstraintIndex{MOI.SingleVariable,
                                         MOI.EqualTo{Float64}})
    if model.inner === nothing
        error("ConstraintPrimal not available.")
    end
    vi = MOI.VariableIndex(ci.value)
    check_inbounds(model, vi)
    if !is_fixed(model, vi)
        error("Variable $vi is not fixed -- ConstraintPrimal not defined.")
    end
    return model.inner.x[vi.value]
end

function MOI.get(model::Optimizer, ::MOI.ConstraintDual,
                 ci::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64},
                                         MOI.LessThan{Float64}})
    if model.inner === nothing
        error("ConstraintDual not available.")
    end
    @assert 1 <= ci.value <= length(model.linear_le_constraints)
    # TODO: Unable to find documentation in Ipopt about the signs of duals.
    # Rescaling by -1 here seems to pass the MOI tests.
    return -1 * model.inner.mult_g[ci.value + linear_le_offset(model)]
end

function MOI.get(model::Optimizer, ::MOI.ConstraintDual,
                 ci::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64},
                                         MOI.GreaterThan{Float64}})
    if model.inner === nothing
        error("ConstraintDual not available.")
    end
    @assert 1 <= ci.value <= length(model.linear_ge_constraints)
    # TODO: Unable to find documentation in Ipopt about the signs of duals.
    # Rescaling by -1 here seems to pass the MOI tests.
    return -1 * model.inner.mult_g[ci.value + linear_ge_offset(model)]
end

function MOI.get(model::Optimizer, ::MOI.ConstraintDual,
                 ci::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64},
                                         MOI.EqualTo{Float64}})
    if model.inner === nothing
        error("ConstraintDual not available.")
    end
    @assert 1 <= ci.value <= length(model.linear_eq_constraints)
    # TODO: Rescaling by -1 for consistency, but I don't know if this is covered
    # by tests.
    return -1 * model.inner.mult_g[ci.value + linear_eq_offset(model)]
end

function MOI.get(model::Optimizer, ::MOI.ConstraintDual,
                 ci::MOI.ConstraintIndex{MOI.SingleVariable,
                                         MOI.LessThan{Float64}})
    if model.inner === nothing
        error("ConstraintDual not available.")
    end
    vi = MOI.VariableIndex(ci.value)
    check_inbounds(model, vi)
    if !has_upper_bound(model, vi)
        error("Variable $vi has no upper bound -- ConstraintDual not defined.")
    end
    # MOI convention is for feasible LessThan duals to be nonpositive.
    return -1 * model.inner.mult_x_U[vi.value]
end

function MOI.get(model::Optimizer, ::MOI.ConstraintDual,
                 ci::MOI.ConstraintIndex{MOI.SingleVariable,
                                         MOI.GreaterThan{Float64}})
    if model.inner === nothing
        error("ConstraintDual not available.")
    end
    vi = MOI.VariableIndex(ci.value)
    check_inbounds(model, vi)
    if !has_lower_bound(model, vi)
        error("Variable $vi has no lower bound -- ConstraintDual not defined.")
    end
    return model.inner.mult_x_L[vi.value]
end

function MOI.get(model::Optimizer, ::MOI.ConstraintDual,
                 ci::MOI.ConstraintIndex{MOI.SingleVariable,
                                         MOI.EqualTo{Float64}})
    if model.inner === nothing
        error("ConstraintDual not available.")
    end
    vi = MOI.VariableIndex(ci.value)
    check_inbounds(model, vi)
    if !is_fixed(model, vi)
        error("Variable $vi is not fixed -- ConstraintDual not defined.")
    end
    return model.inner.mult_x_L[vi.value] - model.inner.mult_x_U[vi.value]
end

function MOI.get(model::Optimizer, ::MOI.NLPBlockDual)
    if model.inner === nothing
        error("NLPBlockDual not available.")
    end
    return -1 * model.inner.mult_g[(1 + nlp_constraint_offset(model)):end]
end
