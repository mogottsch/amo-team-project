import JuMP
import HiGHS
include("./types.jl")

struct DispatchModel
    m::JuMP.Model
    variables::Dict{Symbol,Any}
    constraints::Dict{Symbol,Any}
end

function build_model(
    network::Network,
    scenarios::Dict{Symbol,Scenario},
    budget::Float64,
)::DispatchModel
    m = JuMP.Model(HiGHS.Optimizer)

    busses = network.busses
    generators = network.generators
    lines = network.lines

    ##################### Variables #####################
    @variable(m, r[b in keys(busses)], Bin) # reinforce bus

    ## second-stage
    @variable(m, 0 <= P[g in keys(generators), s in keys(scenarios)]) # power generation
    @variable(m, 0 <= L_shed[b in keys(busses), s in keys(scenarios)] <= busses[b].load) # load shedding

    @variable(m, z[b in keys(busses), s in keys(scenarios)], Bin) # bus outage

    @variable(m, F[l in keys(lines), s in keys(scenarios)]) # power flow
    @variable(m, δ[b in keys(busses), s in keys(scenarios)]) # voltage angle

    variables = Dict(
        :r => r,
        :P => P,
        :L_shed => L_shed,
        :z => z,
        :F => F,
        :δ => δ
    )



    ##################### Objective #####################
    # minimize expected load shedding over all scenarios
    @objective(m, Min, sum(sum(L_shed[b, s] for b in keys(busses)) * 1 / length(scenarios) for s in keys(scenarios)))


    ##################### Constraints #####################

    ## first-stage
    ### reinforcement budget
    @constraint(m,
        reinforcement_budget,
        sum(r[b] * busses[b].reinforcement_cost for b in keys(busses))
        <=
        budget
    )

    ## second-stage
    ### power balance
    @constraint(m,
        power_balance[b in keys(busses), s in keys(scenarios)],
        sum(P[g, s] for g in busses[b].generators)
        +
        sum(F[l, s] for l in busses[b].incoming)
        -
        sum(F[l, s] for l in busses[b].outgoing)
        +
        L_shed[b, s]
        -
        busses[b].load
        ==
        0
    )
    ### line flow
    @constraint(m,
        line_flow[l in keys(lines), s in keys(scenarios)],
        F[l, s] == lines[l].susceptance * (δ[lines[l].from, s] - δ[lines[l].to, s])
    )
    ### line flow under outage upper
    @constraint(m,
        line_flow_under_outage_upper[b in keys(busses), l in [busses[b].incoming; busses[b].outgoing], s in keys(scenarios)],
        F[l, s] <= lines[l].capacity * z[b, s]
    )
    ### line flow under outage lower
    @constraint(m,
        line_flow_under_outage_lower[b in keys(busses), l in [busses[b].incoming; busses[b].outgoing], s in keys(scenarios)],
        -lines[l].capacity * z[b, s] <= F[l, s]
    )

    ### generator under outage lower
    @constraint(m,
        generator_under_outage_lower[g in keys(generators), s in keys(scenarios)],
        -generators[g].capacity * z[generators[g].bus, s] <= P[g, s]
    )
    ### generator under outage upper
    @constraint(m,
        generator_under_outage_upper[g in keys(generators), s in keys(scenarios)],
        P[g, s] <= generators[g].capacity * z[generators[g].bus, s]
    )

    ### reference angle
    @constraint(m,
        reference_angle[s in keys(scenarios)],
        δ[:B1, s] == 0
    )
    ### attacked busses
    @constraint(m,
        busses[s in keys(scenarios), b in keys(busses)],
        z[b, s] <= 1 - (b in scenarios[s].attacked_busses ? 1 : 0) + r[b]
    )

    constraints = Dict(
        :reinforcement_budget => reinforcement_budget,
        :power_balance => power_balance,
        :line_flow => line_flow,
        :line_flow_under_outage_upper => line_flow_under_outage_upper,
        :line_flow_under_outage_lower => line_flow_under_outage_lower,
        :generator_under_outage_lower => generator_under_outage_lower,
        :generator_under_outage_upper => generator_under_outage_upper,
        :reference_angle => reference_angle,
        :busses => busses
    )

    return DispatchModel(m, variables, constraints)
end

function solve!(model::DispatchModel)
    JuMP.optimize!(model.m)
    return JuMP.termination_status(model.m)
end