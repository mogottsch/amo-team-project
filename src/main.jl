using Pkg;
Pkg.activate(normpath(joinpath(@__DIR__, "..")));
Pkg.instantiate();


USAGE = """

Usage: julia main.jl <config_path> [<results_dir>]

config_path: path to the config file in JSON format with keys specified in
			 ./src/process.jl
results_dir: path to the directory where the results should be stored
			 if not specified, the results will be stored in the same
			 directory as the config file
"""

include("../src/process.jl")

if length(ARGS) == 0
    error("No config file specified.\n" * USAGE)
end

config_path = abspath(ARGS[1])

if length(ARGS) > 1
    results_dir = ARGS[2]
else
    config_dir = dirname(config_path)
    results_dir = config_dir
end

config = read_config(config_path)

results = run_simulation(config)

store_results_in_dir(results, results_dir)

println("Resuls stored in $(results_dir)")