using JuMP
import HiGHS
import Gurobi
include("./types.jl")


struct ModelData
    network::Network
    scenarios::Dict{Symbol,Scenario}
    budget::Float64
end

struct DispatchModel
    data::ModelData
    m::JuMP.Model
    subproblems::Dict{Symbol,JuMP.Model}
    variables::Dict{Symbol,Any}
    constraints::Dict{Symbol,Any}
    objective::Dict{Symbol,Any}
end

function DispatchModel(
    network::Network,
    scenarios::Dict{Symbol,Scenario},
    budget::Float64
)::DispatchModel
    optimizer = () -> Gurobi.Optimizer(GRB_ENV)
    m = JuMP.Model(optimizer)
    subproblems = Dict{Symbol,JuMP.Model}()
    # m = JuMP.Model(HiGHS.Optimizer)
    set_optimizer_attribute(m, "OutputFlag", 0)
    # set_optimizer_attribute(m, "log_to_console", false)


    variables = Dict{Symbol,Any}()
    constraints = Dict{Symbol,Any}()
    objective = Dict{Symbol,Any}()

    data = ModelData(network, scenarios, budget)

    return DispatchModel(data, m, subproblems, variables, constraints, objective)
end

function init_model!(
    dm::DispatchModel;
)
    m = dm.m
    init_variables!(dm, Symbol())
    init_objective!(dm, m, Symbol())
    init_constraints!(dm, Symbol())
end

function init_variables!(dm::DispatchModel, vkey::Symbol)
    m = dm.m

    dm.variables[vkey] = Dict{Symbol,Any}()
    append_first_stage_variables!(dm, m, vkey)
    append_second_stage_variables!(dm, m, vkey)
end

function append_first_stage_variables!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol,
)
    busses = dm.data.network.busses

    dm.variables[vkey][:r] = @variable(m, r[b in keys(busses)], Bin) # reinforce bus
end

function append_second_stage_variables!(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol,
)
    generators = dm.data.network.generators
    busses = dm.data.network.busses
    lines = dm.data.network.lines
    scenarios = dm.data.scenarios

    fossil_generators, renewable_generators = get_generators_by_type(generators)

    ## second-stage
    # note: the constraints in the following variables are redundant
    # they may improve or worsen the performance of the solver - to be tested
    dm.variables[vkey][:P_f] = @variable(m,
        0 <=
        P_f[g in keys(fossil_generators), s in keys(scenarios)]
        <= fossil_generators[g].max_capacity
    ) # fossil power generation

    dm.variables[vkey][:P_r] = @variable(m,
        0 <=
        P_w[g in keys(renewable_generators), s in keys(scenarios)]
        <= renewable_generators[g].max_capacity
    ) # renewable power generation


    dm.variables[vkey][:P] = merge_dense_axis_arrays(
        dm.variables[vkey][:P_f],
        dm.variables[vkey][:P_r]
    ) # total power generation

    dm.variables[vkey][:L_shed] = @variable(m,
        0 <=
        L_shed[b in keys(busses), s in keys(scenarios)]
        <= scenarios[s].loads[b]
    ) # load shedding

    dm.variables[vkey][:z] = @variable(m,
        z[b in keys(busses), s in keys(scenarios)],
        Bin
    ) # bus outage

    dm.variables[vkey][:F] = @variable(m,
        F[l in keys(lines), s in keys(scenarios)]
    ) # power flow

    dm.variables[vkey][:δ] = @variable(m,
        δ[b in keys(busses), s in keys(scenarios)]
    ) # voltage angle
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

function init_objective!(dm::DispatchModel, m::JuMP.Model, vkey::Symbol)
    busses = dm.data.network.busses
    scenarios = dm.data.scenarios
    L_shed = dm.variables[vkey][:L_shed]

    # minimize expected load shedding over all scenarios
    dm.objective[vkey] = @objective(m,
        Min,
        sum(
            sum(L_shed[b, s] for b in keys(busses))
            *
            scenarios[s].probability for s in keys(scenarios)
        )
    )
end

function init_constraints!(dm::DispatchModel, vkey::Symbol)
    m = dm.m

    dm.constraints[vkey] = Dict{Symbol,Any}()

    init_first_stage_constraints(dm, m, vkey)
    init_second_stage_constraints(dm, m, vkey)
end

function init_first_stage_constraints(
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

function init_second_stage_constraints(
    dm::DispatchModel,
    m::JuMP.Model,
    vkey::Symbol
)
    busses = dm.data.network.busses
    lines = dm.data.network.lines
    generators = dm.data.network.generators
    scenarios = dm.data.scenarios

    fossil_generators, renewable_generators = get_generators_by_type(generators)

    r = dm.variables[vkey][:r]
    F = dm.variables[vkey][:F]
    L_shed = dm.variables[vkey][:L_shed]
    z = dm.variables[vkey][:z]
    δ = dm.variables[vkey][:δ]
    P = dm.variables[vkey][:P]
    P_f = dm.variables[vkey][:P_f]
    P_r = dm.variables[vkey][:P_r]



    ## second-stage
    ### power balance
    dm.constraints[vkey][:power_balance] = @constraint(m,
        power_balance[b in keys(busses), s in keys(scenarios)],
        #
        sum(P[g, s] for g in busses[b].generators)
        +
        sum(F[l, s] for l in busses[b].incoming)
        -
        sum(F[l, s] for l in busses[b].outgoing)
        +
        L_shed[b, s]
        -
        scenarios[s].loads[b] == 0
    )

    ### line flow
    dm.constraints[vkey][:line_flow] = @constraint(m,
        line_flow[l in keys(lines), s in keys(scenarios)],
        #
        F[l, s] ==
        lines[l].susceptance * (δ[lines[l].from, s] - δ[lines[l].to, s])
    )

    ### line flow under outage upper
    dm.constraints[vkey][:line_flow_under_outage_upper] = @constraint(m,
        line_flow_under_outage_upper[b in keys(busses), l in union(busses[b].incoming, busses[b].outgoing), s in keys(scenarios)],
        #
        F[l, s] <= lines[l].capacity * z[b, s]
    )

    ### line flow under outage lower
    dm.constraints[vkey][:line_flow_under_outage_lower] = @constraint(m,
        line_flow_under_outage_lower[b in keys(busses), l in union(busses[b].incoming, busses[b].outgoing), s in keys(scenarios)],
        #
        -lines[l].capacity * z[b, s] <= F[l, s]
    )

    ### fossil generator under outage lower
    dm.constraints[vkey][:fossil_generator_under_outage_lower] = @constraint(m,
        fossil_generator_under_outage_lower[g in keys(fossil_generators), s in keys(scenarios)],
        #
        fossil_generators[g].min_capacity * z[fossil_generators[g].bus, s] <= P_f[g, s]
    )

    ### fossil generator under outage upper
    dm.constraints[vkey][:fossil_generator_under_outage_upper] = @constraint(m,
        fossil_generator_under_outage_upper[g in keys(fossil_generators), s in keys(scenarios)],
        #
        P_f[g, s] <= fossil_generators[g].max_capacity * z[fossil_generators[g].bus, s]
    )

    ### renewable generator under outage lower
    dm.constraints[vkey][:renewable_generator_under_outage_lower] = @constraint(m,
        renewable_generator_under_outage_lower[g in keys(renewable_generators), s in keys(scenarios)],
        #
        0 <= P_r[g, s]
    )

    ### fossil generator under outage upper
    dm.constraints[vkey][:renewable_generator_under_outage_upper] = @constraint(m,
        renewable_generator_under_outage_upper[g in keys(renewable_generators), s in keys(scenarios)],
        #
        P_r[g, s] <= scenarios[s].capacities[g] * z[renewable_generators[g].bus, s]
    )

    ### reference angle
    dm.constraints[vkey][:reference_angle] = @constraint(m,
        reference_angle[s in keys(scenarios)],
        δ[:B1, s] == 0
    )
    ### attacked busses
    dm.constraints[vkey][:attacked_busses] = @constraint(m,
        busses[s in keys(scenarios), b in keys(busses)],
        z[b, s] <= 1 - (b in scenarios[s].attacked_busses ? 1 : 0) + r[b]
    )
end


function solve!(model::DispatchModel)
    JuMP.optimize!(model.m)
    return JuMP.termination_status(model.m)
end


# merges two DenseAxisArrays with equal second axis
function merge_dense_axis_arrays(
    daa1::JuMP.Containers.DenseAxisArray,
    daa2::JuMP.Containers.DenseAxisArray,
)
    axes = [vcat(daa1.axes[1], daa2.axes[1]), daa1.axes[2]]
    daa = JuMP.Containers.DenseAxisArray(vcat(daa1.data, daa2.data), axes...)
    return daa
end
