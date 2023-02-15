using JuMP
import HiGHS
import Gurobi
import Printf
include("./types.jl")


struct ModelData
    network::Network
    scenarios::Dict{Symbol,Scenario}
    budget::Float64
    fossil_generators::Dict{Symbol,Generator}
    renewable_generators::Dict{Symbol,Generator}
end

struct DispatchModel
    data::ModelData
    m::JuMP.Model
    subproblems::Dict{Symbol,JuMP.Model}
    variables::Dict{Symbol,Any}
    constraints::Dict{Symbol,Any}
    objective::Dict{Symbol,Any}
end

function init_solver()::JuMP.Model
    optimizer = () -> Gurobi.Optimizer(GRB_ENV)
    m = JuMP.Model(optimizer)
    set_optimizer_attribute(m, "OutputFlag", 0)

    # m = JuMP.Model(HiGHS.Optimizer)
    # set_optimizer_attribute(m, "log_to_console", false)
    return m
end

function DispatchModel(
    network::Network,
    scenarios::Dict{Symbol,Scenario},
    budget::Float64
)::DispatchModel
    m = init_solver()
    subproblems = Dict{Symbol,JuMP.Model}()

    variables = Dict{Symbol,Any}()
    constraints = Dict{Symbol,Any}()
    objective = Dict{Symbol,Any}()

    fossil_generators, renewable_generators = get_generators_by_type(network.generators)

    data = ModelData(network, scenarios, budget, fossil_generators, renewable_generators)

    return DispatchModel(data, m, subproblems, variables, constraints, objective)
end

function init_model!(
    dm::DispatchModel;
)
    m = dm.m
    init_variables!(dm, Symbol())
    append_objective!(dm, m, Symbol())
    init_constraints!(dm, Symbol())
end

function init_variables!(dm::DispatchModel, vkey::Symbol)
    m = dm.m

    dm.variables[vkey] = Dict{Symbol,Any}()

    for s in keys(dm.data.scenarios)
        dm.variables[vkey][s] = Dict{Symbol,Any}()
    end

    append_binary_variables!(dm, m, vkey)
    append_second_stage_variables!(dm, m, vkey)
end

function append_binary_variables!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol,
)
    busses = dm.data.network.busses
    scenarios = dm.data.scenarios

    dm.variables[vkey][:r] = @variable(m, [b in keys(busses)], Bin, base_name = "r") # bus reinforced

    for s in keys(scenarios)
        append_complicating_variables!(dm, m, vkey, s, false)
    end
end

function append_complicating_variables!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol,
    s::Symbol,
    decomposed::Bool
)
    busses = dm.data.network.busses
    # in the decomposed case we don't need z to be binary, as we will fix it
    if decomposed
        dm.variables[vkey][s][:z] = @variable(m, [b in keys(busses)], base_name = "z") # bus active
    else
        dm.variables[vkey][s][:z] = @variable(m, [b in keys(busses)], Bin, base_name = "z") # bus active
    end
end

function append_second_stage_variables_for_scenario!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol,
    s::Symbol,
)
    busses = dm.data.network.busses
    lines = dm.data.network.lines
    fossil_generators = dm.data.fossil_generators
    renewable_generators = dm.data.renewable_generators

    # second-stage
    dm.variables[vkey][s][:P_f] = @variable(m,
        [g in keys(fossil_generators)],
        base_name = "P_f"
    ) # fossil power generation

    dm.variables[vkey][s][:P_r] = @variable(m,
        [g in keys(renewable_generators)],
        base_name = "P_r"
    ) # renewable power generation


    dm.variables[vkey][s][:P] = merge_dense_axis_arrays(
        dm.variables[vkey][s][:P_f],
        dm.variables[vkey][s][:P_r]
    ) # total power generation

    dm.variables[vkey][s][:L_shed] = @variable(m,
        [b in keys(busses)],
        base_name = "L_shed"
    ) # load shedding

    dm.variables[vkey][s][:F] = @variable(m,
        [l in keys(lines)],
        base_name = "F"
    ) # power flow

    dm.variables[vkey][s][:δ] = @variable(m,
        [b in keys(busses)],
        base_name = "δ"
    ) # voltage angle

end

function append_second_stage_variables!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol,
)
    scenarios = dm.data.scenarios
    for s in keys(scenarios)
        append_second_stage_variables_for_scenario!(dm, m, vkey, s)
    end
end

function get_generators_by_type(
    generators::Dict{Symbol,Generator}
)::Tuple{Dict{Symbol,Generator},Dict{Symbol,Generator}}
    fossil_generators = Dict{Symbol,Generator}()
    renewable_generators = Dict{Symbol,Generator}()

    for (id, generator) in generators
        if generator.type == fossil
            fossil_generators[id] = generator
            continue
        elseif generator.type == wind || generator.type == solar
            renewable_generators[id] = generator
            continue
        else
            error("Unknown generator type: $(generator.type)")
        end
    end

    return fossil_generators, renewable_generators
end

function append_objective!(dm::DispatchModel, m::JuMP.Model, vkey::Symbol)
    busses = dm.data.network.busses
    scenarios = dm.data.scenarios

    # minimize expected load shedding over all scenarios
    dm.objective[vkey] = @objective(m,
        Min,
        sum(
            sum(dm.variables[vkey][s][:L_shed][b] for b in keys(busses))
            *
            scenarios[s].probability for s in keys(scenarios)
        )
    )
end

function append_sp_objective!(dm::DispatchModel, m::JuMP.Model, vkey::Symbol, s::Symbol)
    busses = dm.data.network.busses
    L_shed = dm.variables[vkey][s][:L_shed]
    scenario = dm.data.scenarios[s]

    dm.objective[vkey][s] = @objective(m,
        Min,
        sum(L_shed[b] for b in keys(busses)) * scenario.probability
    )
end

function init_constraints!(dm::DispatchModel, vkey::Symbol)
    m = dm.m

    dm.constraints[vkey] = Dict{Symbol,Any}()

    append_first_stage_constraints!(dm, m, vkey)
    append_second_stage_constraints!(dm, m, vkey)
end

function append_first_stage_constraints!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol
)
    busses = dm.data.network.busses
    budget = dm.data.budget

    r = dm.variables[vkey][:r]

    ### reinforcement budget
    dm.constraints[vkey][:reinforcement_budget] = @constraint(m,
        reinforcement_budget,
        sum(r[b] * busses[b].reinforcement_cost for b in keys(busses))
        <=
        budget
    )
end

function append_second_stage_constraints_for_scenario!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol,
    s::Symbol,
    decomposed::Bool
)
    busses = dm.data.network.busses
    lines = dm.data.network.lines
    scenario = dm.data.scenarios[s]

    fossil_generators = dm.data.fossil_generators
    renewable_generators = dm.data.renewable_generators

    r = nothing
    if !decomposed
        r = dm.variables[vkey][:r]
    end

    F = dm.variables[vkey][s][:F]
    L_shed = dm.variables[vkey][s][:L_shed]
    z = dm.variables[vkey][s][:z]
    δ = dm.variables[vkey][s][:δ]
    P = dm.variables[vkey][s][:P]
    P_f = dm.variables[vkey][s][:P_f]
    P_r = dm.variables[vkey][s][:P_r]


    dm.constraints[vkey][s] = Dict{Symbol,Any}()

    ## second-stage

    dm.constraints[vkey][s][:P_f_lower] = @constraint(m,
        [g in keys(fossil_generators)],
        #
        P_f[g] >= 0
    )
    dm.constraints[vkey][s][:P_r_lower] = @constraint(m,
        [g in keys(renewable_generators)],
        #
        P_r[g] >= 0
    )


    dm.constraints[vkey][s][:L_shed_bounds] = @constraint(m,
        [b in keys(busses)],
        #
        0 <= L_shed[b] <= scenario.loads[b]
    ) # load shedding


    ### power balance
    dm.constraints[vkey][s][:power_balance] = @constraint(m,
        [b in keys(busses)],
        #
        sum(P[g] for g in busses[b].generators)
        +
        sum(F[l] for l in busses[b].incoming)
        -
        sum(F[l] for l in busses[b].outgoing)
        +
        L_shed[b]
        -
        scenario.loads[b] == 0
    )

    ### line flow
    dm.constraints[vkey][s][:line_flow] = @constraint(m,
        [l in keys(lines)],
        #
        F[l] ==
        lines[l].susceptance * (δ[lines[l].from] - δ[lines[l].to])
    )

    ### line flow under outage upper
    dm.constraints[vkey][s][:line_flow_under_outage_upper] = @constraint(m,
        [b in keys(busses), l in union(busses[b].incoming, busses[b].outgoing)],
        #
        F[l] <= lines[l].capacity * z[b]
    )

    ### line flow under outage lower
    dm.constraints[vkey][s][:line_flow_under_outage_lower] = @constraint(m,
        [b in keys(busses), l in union(busses[b].incoming, busses[b].outgoing)],
        #
        -lines[l].capacity * z[b] <= F[l]
    )

    ### fossil generator under outage lower
    dm.constraints[vkey][s][:fossil_generator_under_outage_lower] = @constraint(m,
        [g in keys(fossil_generators)],
        #
        fossil_generators[g].min_capacity * z[fossil_generators[g].bus] <= P_f[g]
    )

    ### fossil generator under outage upper
    dm.constraints[vkey][s][:fossil_generator_under_outage_upper] = @constraint(m,
        [g in keys(fossil_generators)],
        #
        P_f[g] <= fossil_generators[g].max_capacity * z[fossil_generators[g].bus]
    )

    ### renewable generator under outage lower
    dm.constraints[vkey][s][:renewable_generator_under_outage_lower] = @constraint(m,
        [g in keys(renewable_generators)],
        #
        0 <= P_r[g]
    )

    ### fossil generator under outage upper
    dm.constraints[vkey][s][:renewable_generator_under_outage_upper] = @constraint(m,
        [g in keys(renewable_generators)],
        #
        P_r[g] <= scenario.capacities[g] * z[renewable_generators[g].bus]
    )

    ### reference angle
    dm.constraints[vkey][s][:reference_angle] = @constraint(m,
        δ[:B1] == 0
    )

    # in the decomposed case z is fixed
    if !decomposed
        ### attacked busses
        dm.constraints[vkey][s][:attacked_busses] = @constraint(m,
            [b in keys(busses)],
            #
            z[b] <= 1 - (b in scenario.attacked_busses ? 1 : 0) + r[b])
    end
end

function append_second_stage_constraints!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol
)
    scenarios = dm.data.scenarios

    for s in keys(scenarios)
        append_second_stage_constraints_for_scenario!(dm, m, vkey, s, false)
    end
end


function solve!(model::DispatchModel)
    solve_problem!(model.m)
end

ABSOLUTE_OPTIMALITY_GAP = 1e-6
function solve_with_benders!(dm::DispatchModel)
    init_masterproblem!(dm)
    init_subproblems!(dm)


    # z_k = init_complicating_variables(dm)

    z_ks = []

    print_header()
    for i in 1:1000
        solve_masterproblem!(dm)
        lower_bound = JuMP.objective_value(dm.m)

        # get values of complicating variables from master problem
        z_k = get_values_of_cv(dm)
        z_ks = [z_ks; z_k]

        # cv = complicating variables
        # sps = subproblems
        fix_cvs_in_sps!(dm, z_k)

        solve_subproblems!(dm)
        objectives = get_objectives_of_sps(dm)

        upper_bound = sum([objectives[s] for s in keys(objectives)])

        gap = (upper_bound - lower_bound)
        normalized_gap = gap / abs(upper_bound)
        print_iteration(i, lower_bound, upper_bound, gap, normalized_gap)

        if gap < ABSOLUTE_OPTIMALITY_GAP
            println("Optimal solution found.")
            break
        end

        μs = get_duals_of_cv(dm)
        append_benders_cut_to_masterproblem!(dm, z_k, objectives, μs, i)
    end
    return z_ks, μs
end

function print_header()
    header = ["lower bound", "upper bound", "gap"]
    header_padded = [lpad(h, 15) for h in header]
    println(lpad(0, 9), " ", join(header_padded, " "))
end

function print_iteration(k, args...)
    f(x) = Printf.@sprintf("%15i", x)
    println(lpad(k, 9), " ", join(f.(args), " "))
    return
end

function init_masterproblem!(dm::DispatchModel)
    m = dm.m

    vkey = :mp

    dm.variables[vkey] = Dict{Symbol,Any}()
    for s in keys(dm.data.scenarios)
        dm.variables[vkey][s] = Dict{Symbol,Any}()
    end
    dm.constraints[vkey] = Dict{Symbol,Any}()

    append_binary_variables!(dm, m, vkey)
    append_master_problem_variables!(dm, m, vkey) # appends α

    append_masterproblem_objective!(dm, m, vkey)

    append_first_stage_constraints!(dm, m, vkey)
    append_z_derived_by_r_constraints!(dm, m, vkey)
end

function append_z_derived_by_r_constraints!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol,
)
    busses = dm.data.network.busses

    scenarios = dm.data.scenarios

    for s in keys(scenarios)
        scenario = scenarios[s]
        z = dm.variables[vkey][s][:z]
        r = dm.variables[vkey][:r]

        dm.constraints[vkey][s] = Dict{Symbol,Any}()

        ### attacked busses
        dm.constraints[vkey][s][:attacked_busses] = @constraint(m,
            [b in keys(busses)],
            #
            z[b] <= 1 - (b in scenario.attacked_busses ? 1 : 0) + r[b])
    end
end

function append_master_problem_variables!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol,
)
    scenarios = dm.data.scenarios
    dm.variables[vkey][:α] = @variable(m,
        α[s in keys(scenarios)] >= -1000 # TODO: what is a good lower bound?
    )
end

function append_masterproblem_objective!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol,
)
    @objective(m,
        Min,
        sum(
            sum(
                dm.variables[vkey][:α][s]
                for s in keys(dm.data.scenarios)
            )
            for b in keys(dm.data.network.busses)
        )
    )
end

function init_subproblems!(dm::DispatchModel)
    vkey = Symbol(:sp)
    dm.variables[vkey] = Dict{Symbol,Any}()
    dm.constraints[vkey] = Dict{Symbol,Any}()
    dm.objective[vkey] = Dict{Symbol,Any}()

    for s in keys(dm.data.scenarios)
        init_subproblem!(dm, s)
    end
end

function init_subproblem!(dm::DispatchModel, s::Symbol)
    vkey = Symbol(:sp)

    m = init_solver()

    dm.subproblems[s] = m
    dm.variables[vkey][s] = Dict{Symbol,Any}()
    dm.constraints[vkey][s] = Dict{Symbol,Any}()

    append_second_stage_variables_for_scenario!(dm, m, vkey, s)
    append_complicating_variables!(dm, m, vkey, s, true)
    append_sp_objective!(dm, m, vkey, s)
    append_second_stage_constraints_for_scenario!(dm, m, vkey, s, true)
end


# merges two one-dimensional DenseAxisArrays
function merge_dense_axis_arrays(
    daa1::JuMP.Containers.DenseAxisArray,
    daa2::JuMP.Containers.DenseAxisArray,
)
    axes = vcat(daa1.axes[1], daa2.axes[1])
    daa = JuMP.Containers.DenseAxisArray(vcat(daa1.data, daa2.data), axes)
    return daa
end

function init_complicating_variables(
    dm::DispatchModel,
)::Dict{Symbol,Dict{Symbol,Int}}
    busses = dm.data.network.busses
    scenarios = dm.data.scenarios

    z = Dict{Symbol,Dict{Symbol,Int}}()
    for s in keys(scenarios)
        scenario = scenarios[s]
        z[s] = Dict{Symbol,Int}()
        for b in keys(busses)
            # initally set bus active if it is not attacked
            z[s][b] = (b in scenario.attacked_busses ? 0 : 1)
        end
    end

    return z
end

function fix_cvs_in_sps!(
    dm::DispatchModel,
    z_k::Dict{Symbol,Dict{Symbol,Int}}
)
    for s in keys(dm.data.scenarios)
        fix_cvs_in_sp!(dm, s, z_k)
    end
end

function remove_cv_fixed_constraint_from_sps!(dm::DispatchModel)
    for s in keys(dm.data.scenarios)
        remove_cv_fixed_constraint_from_sp!(dm, s)
    end
end

function fix_cvs_in_sp!(
    dm::DispatchModel,
    s::Symbol,
    z_k::Dict{Symbol,Dict{Symbol,Int}}
)
    vkey = :sp
    busses = dm.data.network.busses

    for b in keys(busses)
        fix(dm.variables[vkey][s][:z][b], z_k[s][b])
    end
end

function solve_subproblems!(dm::DispatchModel)
    for s in keys(dm.data.scenarios)
        solve_subproblem!(dm, s)
    end
end

function solve_subproblem!(dm::DispatchModel, s::Symbol)
    m = dm.subproblems[s]
    solve_problem!(m)
end

function get_objectives_of_sps(dm::DispatchModel)
    objectives = Dict{Symbol,Float64}()
    for s in keys(dm.data.scenarios)
        objectives[s] = JuMP.objective_value(dm.subproblems[s])
    end
    return objectives
end

function get_duals_of_cv(dm::DispatchModel)
    μs = Dict{Symbol,Dict{Symbol,Float64}}()
    for s in keys(dm.data.scenarios)
        μs[s] = Dict{Symbol,Float64}()
        for b in keys(dm.data.network.busses)
            μs[s][b] = JuMP.reduced_cost(dm.variables[:sp][s][:z][b])
        end
    end
    return μs
end

function append_benders_cut_to_masterproblem!(
    dm::DispatchModel,
    z_k::Dict{Symbol,Dict{Symbol,Int}},
    objectives::Dict{Symbol,Float64},
    μs::Dict{Symbol,Dict{Symbol,Float64}},
    i::Int,
)
    m = dm.m
    vkey = :mp
    busses = dm.data.network.busses

    α = dm.variables[vkey][:α]

    dm.constraints[vkey][Symbol(:benders_cut, i)] = @constraint(m,
        [s in keys(dm.data.scenarios)],
        #
        α[s] >= objectives[s] + sum(μs[s][b] * (dm.variables[vkey][s][:z][b] - z_k[s][b]) for b in keys(busses)),
        base_name = Symbol(:benders_cut, i)
    )
end

function solve_masterproblem!(dm::DispatchModel)
    m = dm.m
    solve_problem!(m)
end

function solve_problem!(m)
    JuMP.optimize!(m)

    if JuMP.termination_status(m) != MOI.OPTIMAL
        if JuMp.termination_status(m) == MOI.TIME_LIMIT && JuMP.has_values(m)
            @warn("Optimization stopped with suboptimal solution")
        else
            @error("Optimization failed with status $(JuMP.termination_status(m))")
        end
    end
end

function get_values_of_cv(dm::DispatchModel)::Dict{Symbol,Dict{Symbol,Int}}
    z = Dict{Symbol,Dict{Symbol,Int}}()
    for s in keys(dm.data.scenarios)
        z[s] = Dict{Symbol,Int}()
        for b in keys(dm.data.network.busses)
            z[s][b] = round(JuMP.value(dm.variables[:mp][s][:z][b]))
        end
    end
    return z
end