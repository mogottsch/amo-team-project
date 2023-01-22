using Dates

struct Generator
    id::Symbol
    type::Symbol
    bus::Symbol
    max_capacity::Float64
    min_capacity::Float64
    cost::Float64
end

struct Bus
    id::Symbol
    generators::Vector{Symbol}
    incoming::Vector{Symbol}
    outgoing::Vector{Symbol}
    reinforcement_cost::Float64
end

struct Line
    id::Symbol
    from::Symbol
    to::Symbol
    capacity::Float64
    susceptance::Float64
end

struct Scenario
    probability::Float64
    attacked_busses::Set{Symbol}
    loads::Dict{Symbol,Float64}
    capacities::Dict{Symbol,Float64}
end

struct Network
    generators::Dict{Symbol,Generator}
    busses::Dict{Symbol,Bus}
    lines::Dict{Symbol,Line}
end

struct Variables
    r::JuMP.Containers.DenseAxisArray
end