using DataFrames
import Distances
import Clustering
import Statistics


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