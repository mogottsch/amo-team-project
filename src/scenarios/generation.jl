import Random
import StatsBase
using DataFrames
import Distributions

include("../types.jl")


Random.seed!(4711)

function generate_attack_scenarios(
    network::Network,
    n_attacks::Int,
    n_scenarios::Int,
)::DataFrame
    bus_ids = collect(keys(network.busses))

    weighted_busses = get_weighted_busses(network)

    df = create_bus_dataframe(bus_ids)
    for _ in 1:n_scenarios
        attacked_busses = sample_attacked_busses(
            weighted_busses,
            n_attacks,
        )
        one_hot = map(x -> x in attacked_busses, bus_ids)
        push!(df, one_hot)
    end

    return df
end

function get_weighted_busses(
    network::Network,
)::Vector{Tuple{Symbol,Float64}}
    weighted_busses = []

    for (bus_id, bus) in network.busses
        weight = determine_weight(bus, network)
        push!(weighted_busses, (bus_id, weight))
    end

    return weighted_busses
end

function determine_weight(bus::Bus, network::Network)::Float64
    lines = network.lines
    lines = filter(
        x -> x[2].from == bus.id || x[2].to == bus.id,
        lines,
    )

    weight = sum(map(x -> x.capacity, values(lines)))
    return weight
end

function create_bus_dataframe(bus_ids::Vector{Symbol})::DataFrame
    # dummy column to create DataFrame with correct datatypes & column names
    columns = map(x -> Pair(x, true), bus_ids)
    df = DataFrame(columns)
    # remove dummy column
    df = df[2:end, :]
end

function sample_attacked_busses(
    weighted_busses::Vector{Tuple{Symbol,Float64}},
    n_attacks::Int,
)::Set{Symbol}
    bus_ids = map(x -> x[1], weighted_busses)
    weights = StatsBase.weights(map(x -> x[2], weighted_busses))

    attacked_busses = StatsBase.sample(
        bus_ids,
        weights,
        n_attacks,
        replace=false,
    )

    return Set(attacked_busses)
end

si = 0.25
β = ((si * (1 + si) / (si / 10)) - 1) * (1 - si)
α = si * β / (1 - si)
σ = 6.5 * 1.128
function generate_weather_scenarios(
    n_scenarios::Int,
)::DataFrame
    solar_irradiance_dist = Distributions.Beta(α, β)
    wind_speed_dist = Distributions.Rayleigh(σ)

    dist_vec = [solar_irradiance_dist, wind_speed_dist]

    weather_scenarios = hcat(rand.(dist_vec, n_scenarios)...)'
    return DataFrame(solar=weather_scenarios[1, :], wind=weather_scenarios[2, :])
end