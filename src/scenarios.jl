import Random
import StatsBase
using DataFrames
import Distributions
import Distances
import LinearAlgebra
import Clustering
import Statistics

include("./types.jl")


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
        weight = determine_weight(bus, network.lines)
        push!(weighted_busses, (bus_id, weight))
    end

    return weighted_busses
end

# returns sum of the line capacities connected to the bus
function determine_weight(bus::Bus, lines::Dict{Symbol,Line})::Float64
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

function reduce_continous_scenarios(
    scenarios::DataFrame,
    n_scenarios::Int,
)
    normalized = copy(scenarios)
    μs, σs = normalize!(normalized)
    replace_nans!(normalized)

    kmn = Clustering.kmeans(Matrix(normalized)', n_scenarios)
    centers = kmn.centers
    denormalized = denormalize(centers, μs, σs)

    reduced_scenarios_df = DataFrame(denormalized', names(scenarios))
    reduced_scenarios_df[!, :probability] = Clustering.counts(kmn) / size(scenarios, 1)
    return reduced_scenarios_df
end

function normalize!(
    df::DataFrame,
)::Tuple{Vector{Float64},Vector{Float64}}
    μs = Statistics.mean.(eachcol(df))
    σs = Statistics.std.(eachcol(df))

    for (i, col) in enumerate(eachcol(df))
        df[!, i] = (df[!, i] .- μs[i]) ./ σs[i]
    end

    return (μs, σs)
end

function denormalize(
    m::Matrix{Float64},
    μs::Vector{Float64},
    σs::Vector{Float64},
)
    return m .* σs .+ μs
end

function replace_nans!(
    df::DataFrame,
)
    for (i, col) in enumerate(eachcol(df))
        if eltype(col) == Float64
            df[!, i] = replace(col, NaN => 0.0)
        end
    end
end

function reduce_binary_scenarios(
    scenarios::DataFrame,
    n_scenarios::Int,
)
    dist = Distances.pairwise(Distances.Hamming(), Matrix(scenarios)', dims=2)
    kmed = Clustering.kmedoids(dist, n_scenarios)

    reduced_scenarios_df = scenarios[kmed.medoids, :]
    reduced_scenarios_df[!, :probability] .= kmed.counts / sum(kmed.counts)
    return reduced_scenarios_df
end

function cartesian_scenarios(
    load_scenarios::DataFrame,
    attack_scenarios::DataFrame,
    weather_scenarios::DataFrame,
)::DataFrame
    load_scenarios = copy(load_scenarios)
    attack_scenarios = copy(attack_scenarios)
    weather_scenarios = copy(weather_scenarios)

    rename!(x -> string(x, "_load"), load_scenarios)
    rename!(x -> string(x, "_attack"), attack_scenarios)
    rename!(x -> string(x, "_weather"), weather_scenarios)

    scenarios = DataFrames.crossjoin(load_scenarios, attack_scenarios)
    scenarios = DataFrames.crossjoin(scenarios, weather_scenarios)

    scenarios[!, :probability] = scenarios[!, :probability_load] .* scenarios[!, :probability_weather] .* scenarios[!, :probability_attack]
    scenarios = scenarios[:, Not(:probability_load)]
    scenarios = scenarios[:, Not(:probability_weather)]
    scenarios = scenarios[:, Not(:probability_attack)]

    return scenarios
end