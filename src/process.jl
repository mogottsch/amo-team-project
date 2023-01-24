import Dates
import JSON
using ProgressMeter

struct Config
    data_source_paths::Vector{String}
    n_attacks::Int
    n_intermediate_attack_scenarios::Int
    n_intermediate_weather_scenarios::Int
    n_reduced_attack_scenarios::Int
    n_reduced_weather_scenarios::Int
    n_reduced_load_scenarios::Int
    reinforcment_budget::Float64
end

function create_config(d::Dict{String,Any})
    return Config(
        d["data_source_paths"],
        d["n_attacks"],
        d["n_intermediate_attack_scenarios"],
        d["n_intermediate_weather_scenarios"],
        d["n_reduced_attack_scenarios"],
        d["n_reduced_weather_scenarios"],
        d["n_reduced_load_scenarios"],
        d["reinforcment_budget"],
    )
end

function read_config(path::String)
    d = JSON.parsefile(path)

    d["data_source_paths"] = map(x -> normpath(joinpath(dirname(path), x)), d["data_source_paths"])

    return create_config(d)
end

MONTHS_PER_YEAR = 12

include("./rwth_parser.jl")
include("./loads.jl")
include("./scenarios/generation.jl")
include("./scenarios/reduction.jl")
include("./model.jl")
include("./scenarios/assemble.jl")
include("./results.jl")

GRB_ENV = Gurobi.Env()
function run_simulation(c::Config)
    println("Initializing environment")
    results_df = create_results_df()
    global_loads = read_loads(c.data_source_paths[1])


    weather_scenarios = generate_weather_scenarios(
        c.n_intermediate_weather_scenarios
    )
    reduced_weather_scenarios = reduce_continous_scenarios(
        weather_scenarios,
        c.n_reduced_weather_scenarios
    )

    loads_dict = Dict{Int,DataFrame}()
    for month in 1:MONTHS_PER_YEAR
        local_loads = remove_non_data_rows(filter_month(global_loads, month))
        reduced_load_scenarios = reduce_continous_scenarios(
            local_loads,
            c.n_reduced_load_scenarios
        )
        loads_dict[month] = reduced_load_scenarios
    end

    @showprogress for source_path in c.data_source_paths

        network = read_network(source_path)

        @showprogress source_path for month in 1:MONTHS_PER_YEAR
            reduced_load_scenarios = loads_dict[month]

            attack_scenarios = generate_attack_scenarios(
                network,
                c.n_attacks,
                c.n_intermediate_attack_scenarios
            )
            reduced_attack_scenarios = reduce_binary_scenarios(
                attack_scenarios,
                c.n_reduced_attack_scenarios
            )

            scenarios = cartesian_scenarios(
                reduced_load_scenarios,
                reduced_attack_scenarios,
                reduced_weather_scenarios,
            )
            scenarios = translate_weather_to_capacity(scenarios, network.generators)
            scenario_dict = convert_df_to_scenarios(scenarios)
            dispatch_model = DispatchModel(network, scenario_dict, 5.0)
            init_model!(dispatch_model)

            optimize!(dispatch_model.m)

            results_summary = get_results_summary(dispatch_model)
            push_results!(results_df, results_summary, source_path, month)

        end
    end

    return results_df
end

function log(msg)
    println("[$(Dates.now())] $(msg)")
end

function logOverwrite(msg)
    print("[$(Dates.now())] $(msg)\r")
end

function create_results_df()
    return DataFrame(
        source_path=String[],
        month=Int[],
        termination_status=String[],
        objective_value=Float64[],
        solve_time=Float64[],
        mean_load=Float64[],
    )
end

function push_results!(df::DataFrame, results::ResultsSummary, source_path::String, month::Int)
    push!(df, [
        source_path,
        month,
        string(results.termination_status),
        results.objective_value,
        results.solve_time,
        results.mean_load,
    ])
end