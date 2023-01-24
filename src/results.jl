import Statistics
import CSV
using DataFrames

"""
Returns a `DataFrame` with the values of the variables from the JuMP container `var`.
The column names of the `DataFrame` can be specified for the indexing columns in `dim_names`,
and the name of the data value column by a Symbol `value_col` e.g. :Value
"""
function convert_jump_container_to_df(
    var::JuMP.Containers.DenseAxisArray;
    dim_names::Vector{Symbol}=Vector{Symbol}(),
    value_col::Symbol=:Value
)

    if isempty(var)
        return DataFrame()
    end

    if length(dim_names) == 0
        dim_names = [Symbol("dim$i") for i in 1:length(var.axes)]
    end

    if length(dim_names) != length(var.axes)
        throw(ArgumentError("Length of given name list does not fit the number of variable dimensions"))
    end

    tup_dim = (dim_names...,)

    # With a product over all axis sets of size M, form an Mx1 Array of all indices to the JuMP container `var`
    ind = reshape([collect(k[i] for i in 1:length(dim_names)) for k in Base.Iterators.product(var.axes...)], :, 1)

    var_val = value.(var)

    df = DataFrame([merge(NamedTuple{tup_dim}(ind[i]), NamedTuple{(value_col,)}(var_val[(ind[i]...,)...])) for i in 1:length(ind)])

    # sort by :dim1

    df = df[sortperm(df[!, Symbol("dim1")]), :]

    return df
end

function reformat_2d_df(df::DataFrame)
    # sort dim 1 and 2
    df = df[sortperm(df[!, :dim1]), :]
    df = df[sortperm(df[!, :dim2]), :]
    return unstack(df, :dim1, :dim2, :Value)
end

function any_rows_greater_zero(df::DataFrame)
    return filter(x -> any(y -> y > 0.0, x[2:end]), eachrow(df))
end

function any_rows_equal_zero(df::DataFrame)
    return filter(x -> any(y -> y == 0.0, x[2:end]), eachrow(df))
end

function get_attacked_busses_df(scenarios::DataFrame)::DataFrame
    # get all columns that end with _attack from scenarios
    attack_columns = filter(col -> endswith(col, "_attack"), names(scenarios))
    attack_scenarios = scenarios[!, attack_columns]
    attack_scenarios[!, :scenario] = 1:size(attack_scenarios, 1)
    # prepend 'S' to all entries in :scenario column
    attack_scenarios[!, :scenario] = "S" .* string.(attack_scenarios[!, :scenario])
    transposed_scenarios = permutedims(attack_scenarios, :scenario)

    # replace false with 0 and true with 1 in all columns starting with 'S'
    for col in names(transposed_scenarios)
        if !startswith(col, "S")
            continue
        end

        transposed_scenarios[!, col] = replace(transposed_scenarios[!, col], false => 0)
        transposed_scenarios[!, col] = replace(transposed_scenarios[!, col], true => 1)
    end
    return transposed_scenarios
end

struct ResultsSummary
    termination_status::JuMP.TerminationStatusCode
    objective_value::Float64
    solve_time::Float64
    mean_load::Float64
end

function get_results_summary(dm::DispatchModel)::ResultsSummary
    scenario_dict = dm.data.scenarios

    mean_load = Statistics.mean([
        sum((collect(values(scenario_dict[scenario_key].loads))))
        for scenario_key in keys(scenario_dict)
    ])

    return ResultsSummary(
        JuMP.termination_status(dm.m),
        JuMP.objective_value(dm.m),
        JuMP.solve_time(dm.m),
        mean_load
    )
end

# --- meta results

function groupby_col(df::DataFrame, col::Symbol)::DataFrame
    gdf = groupby(df, [col])
    df = combine(gdf, [:objective_value => sum, :solve_time => sum, :mean_load => Statistics.mean])
    return sort(df, :objective_value_sum)
end


function save_df_to_csv(df::DataFrame, filename::String)
    CSV.write(filename, df)
end

function store_results_in_dir(results::DataFrame, dir_path::String)
    by_month = groupby_col(results, :month)
    by_source_path = groupby_col(results, :source_path)

    mkpath(dir_path)

    save_df_to_csv(by_month, joinpath(dir_path, "by_month.csv"))
    save_df_to_csv(by_source_path, joinpath(dir_path, "by_source_path.csv"))
    save_df_to_csv(results, joinpath(dir_path, "all_results.csv"))
end