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
    # m = JuMP.Model(HiGHS.Optimizer)
    set_optimizer_attribute(m, "OutputFlag", 0)
    # set_optimizer_attribute(m, "log_to_console", false)


    variables = Dict{Symbol,Any}()
    constraints = Dict{Symbol,Any}()
    objective = Dict{Symbol,Any}()

    data = ModelData(network, scenarios, budget)

    return DispatchModel(data, m, variables, constraints, objective)
end

function init_variables!(dm::DispatchModel)
    generators = dm.data.network.generators
    busses = dm.data.network.busses
    lines = dm.data.network.lines
    scenarios = dm.data.scenarios
    m = dm.m

    fossil_generators, renewable_generators = get_generators_by_type(generators)

    # first-stage
    dm.variables[:r] = @variable(m, r[b in keys(busses)], Bin) # reinforce bus

    ## second-stage
    # note: the constraints in the following variables are redundant
    # they may improve or worsen the performance of the solver - to be tested
    dm.variables[:P_f] = @variable(m,
        0 <=
        P_f[g in keys(fossil_generators), s in keys(scenarios)]
        <= fossil_generators[g].max_capacity
    ) # fossil power generation

    dm.variables[:P_r] = @variable(m,
        0 <=
        P_w[g in keys(renewable_generators), s in keys(scenarios)]
        <= renewable_generators[g].max_capacity
    ) # renewable power generation


    dm.variables[:P] = merge_dense_axis_arrays(
        dm.variables[:P_f],
        dm.variables[:P_r]
    ) # total power generation

    dm.variables[:L_shed] = @variable(m,
        0 <=
        L_shed[b in keys(busses), s in keys(scenarios)]
        <= scenarios[s].loads[b]
    ) # load shedding

    dm.variables[:z] = @variable(m,
        z[b in keys(busses), s in keys(scenarios)],
        Bin
    ) # bus outage

    dm.variables[:F] = @variable(m,
        F[l in keys(lines), s in keys(scenarios)]
    ) # power flow

    dm.variables[:δ] = @variable(m,
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

function init_objective!(dm::DispatchModel)
    m = dm.m
    busses = dm.data.network.busses
    scenarios = dm.data.scenarios
    L_shed = dm.variables[:L_shed]

    # minimize expected load shedding over all scenarios
    dm.objective[:obj] = @objective(m,
        Min,
        sum(
            sum(L_shed[b, s] for b in keys(busses))
            *
            scenarios[s].probability for s in keys(scenarios)
        )
    )
end

function init_constraints!(dm::DispatchModel)
    m = dm.m
    busses = dm.data.network.busses
    lines = dm.data.network.lines
    generators = dm.data.network.generators
    scenarios = dm.data.scenarios
    budget = dm.data.budget


    fossil_generators, renewable_generators = get_generators_by_type(generators)

    r = dm.variables[:r]
    F = dm.variables[:F]
    L_shed = dm.variables[:L_shed]
    z = dm.variables[:z]
    δ = dm.variables[:δ]
    P = dm.variables[:P]
    P_f = dm.variables[:P_f]
    P_r = dm.variables[:P_r]


    ## first-stage
    ### reinforcement budget
    dm.constraints[:reinforcement_budget] = @constraint(m,
        reinforcement_budget,
        sum(r[b] * busses[b].reinforcement_cost for b in keys(busses))
        <=
        budget
    )

    ## second-stage
    ### power balance
    dm.constraints[:power_balance] = @constraint(m,
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
    dm.constraints[:line_flow] = @constraint(m,
        line_flow[l in keys(lines), s in keys(scenarios)],
        #
        F[l, s] ==
        lines[l].susceptance * (δ[lines[l].from, s] - δ[lines[l].to, s])
    )

    ### line flow under outage upper
    dm.constraints[:line_flow_under_outage_upper] = @constraint(m,
        line_flow_under_outage_upper[b in keys(busses), l in union(busses[b].incoming, busses[b].outgoing), s in keys(scenarios)],
        #
        F[l, s] <= lines[l].capacity * z[b, s]
    )

    ### line flow under outage lower
    dm.constraints[:line_flow_under_outage_lower] = @constraint(m,
        line_flow_under_outage_lower[b in keys(busses), l in union(busses[b].incoming, busses[b].outgoing), s in keys(scenarios)],
        #
        -lines[l].capacity * z[b, s] <= F[l, s]
    )

    ### fossil generator under outage lower
    dm.constraints[:fossil_generator_under_outage_lower] = @constraint(m,
        fossil_generator_under_outage_lower[g in keys(fossil_generators), s in keys(scenarios)],
        #
        fossil_generators[g].min_capacity * z[fossil_generators[g].bus, s] <= P_f[g, s]
    )

    ### fossil generator under outage upper
    dm.constraints[:fossil_generator_under_outage_upper] = @constraint(m,
        fossil_generator_under_outage_upper[g in keys(fossil_generators), s in keys(scenarios)],
        #
        P_f[g, s] <= fossil_generators[g].max_capacity * z[fossil_generators[g].bus, s]
    )

    ### renewable generator under outage lower
    dm.constraints[:renewable_generator_under_outage_lower] = @constraint(m,
        renewable_generator_under_outage_lower[g in keys(renewable_generators), s in keys(scenarios)],
        #
        0 <= P_r[g, s]
    )

    ### fossil generator under outage upper
    dm.constraints[:renewable_generator_under_outage_upper] = @constraint(m,
        renewable_generator_under_outage_upper[g in keys(renewable_generators), s in keys(scenarios)],
        #
        P_r[g, s] <= scenarios[s].capacities[g] * z[renewable_generators[g].bus, s]
    )

    ### reference angle
    dm.constraints[:reference_angle] = @constraint(m,
        reference_angle[s in keys(scenarios)],
        δ[:B1, s] == 0
    )
    ### attacked busses
    dm.constraints[:attacked_busses] = @constraint(m,
        busses[s in keys(scenarios), b in keys(busses)],
        z[b, s] <= 1 - (b in scenarios[s].attacked_busses ? 1 : 0) + r[b]
    )
end

function init_model!(
    dm::DispatchModel;
)
    init_variables!(dm)
    init_objective!(dm)
    init_constraints!(dm)
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
