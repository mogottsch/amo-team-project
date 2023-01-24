using DataFrames

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

function translate_weather_to_capacity(
    scenarios::DataFrame,
    generators::Dict{Symbol,Generator},
)::DataFrame
    new_scenarios = copy(scenarios)
    solar_max = maximum(scenarios[!, :solar_weather])
    wind_max = maximum(scenarios[!, :wind_weather])
    for (generator_id, generator) in generators
        column_name = string(generator_id, "_capacity")
        if generator.type == fossil
            continue
        end
        if generator.type == solar
            new_scenarios[!, column_name] = new_scenarios[!, :solar_weather] .* generator.max_capacity ./ solar_max
        end
        if generator.type == wind
            new_scenarios[!, column_name] = new_scenarios[!, :wind_weather] .* generator.max_capacity ./ wind_max
        end
    end
    return new_scenarios
end

function convert_df_to_scenarios(scenario_df::DataFrame)::Dict{Symbol,Scenario}
    scenario_dict = Dict{Symbol,Scenario}()

    for (i, scenario) in enumerate(eachrow(scenario_df))
        scenario_id = Symbol("S", i)
        probability = scenario[:probability]
        attacked_busses = Set{Symbol}()
        loads = Dict{Symbol,Float64}()
        capacities = Dict{Symbol,Float64}()

        for (column_name, value) in pairs(scenario)
            str_column_name = string(column_name)
            if occursin("_attack", str_column_name)
                bus_id = Symbol(split(str_column_name, "_")[1])
                if value == 1
                    push!(attacked_busses, bus_id)
                end
            end
            if occursin("_load", str_column_name)
                bus_id = Symbol(split(str_column_name, "_")[1])
                loads[bus_id] = value
            end
            if occursin("_capacity", str_column_name)
                generator_id = Symbol(split(str_column_name, "_")[1])
                capacities[generator_id] = value
            end
        end

        scenario_dict[scenario_id] = Scenario(probability, attacked_busses, loads, capacities)
    end
    return scenario_dict
end