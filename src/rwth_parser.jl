include("types.jl")
import XLSX
import Dates


BUS_SHEET_NAME = "Bus"
BRANCH_SHEET_NAME = "Branch"
GENERATOR_SHEET_NAME = "Gen"
LOAD_SHEET_NAME = "hourly_BusLoadP (MW)"

DEFAULT_REINFORCMENT_COST = 1.0
DEFAULT_SUSCEPTANCE = 500

function read_data(filepath::String)::Tuple{Network,DataFrame}
    busses = parse_busses(filepath)
    lines = parse_lines!(filepath, busses)
    generators = parse_generators!(filepath, busses)
    loads = parse_loads(filepath)

    network = Network(generators, busses, lines)

    return network, loads
end


function read_sheet(filepath::String, sheet_name::String)::DataFrame
    df = DataFrame(XLSX.readtable(filepath, sheet_name))
    return df
end

BUS_ID_COL = Symbol("Number")
function parse_busses(filepath::String)::Dict{Symbol,Bus}
    df = read_sheet(filepath, BUS_SHEET_NAME)
    busses = Dict()
    for row in eachrow(df)
        bus = parse_bus(row)
        busses[bus.id] = bus
    end
    return busses
end

function parse_bus(row::DataFrameRow)::Bus
    bus_id = Symbol(:B, row[BUS_ID_COL])
    bus = Bus(
        bus_id,
        [],
        [],
        [],
        DEFAULT_REINFORCMENT_COST,
    )
    return bus
end

LINE_ID_COL = Symbol("BranchID")
LINE_FROM_COL = Symbol("From Bus No.")
LINE_TO_COL = Symbol("To Bus No.")
LINE_CAPACITY_COL = Symbol("Rating [MW]")

function parse_lines!(filepath::String, busses::Dict{Symbol,Bus})::Dict{Symbol,Line}
    df = read_sheet(filepath, BRANCH_SHEET_NAME)
    lines = Dict()
    for row in eachrow(df)
        line = parse_line(row)
        lines[line.id] = line

        push!(busses[line.from].outgoing, line.id)
        push!(busses[line.to].incoming, line.id)
    end
    return lines
end

function parse_line(row::DataFrameRow)::Line
    from_bus = Symbol(:B, row[LINE_FROM_COL])
    to_bus = Symbol(:B, row[LINE_TO_COL])
    line_id = Symbol(:LF, from_bus, :T, to_bus)
    line = Line(
        line_id,
        from_bus,
        to_bus,
        row[LINE_CAPACITY_COL],
        DEFAULT_SUSCEPTANCE,
    )
    return line
end


GENERATOR_ID_COL = Symbol("Generator Number")
GENERATOR_BUS_ID_COL = Symbol("On Bus No.")
GENERATOR_MAX_CAPACITY_COL = Symbol("Pmax [MW]")
GENERATOR_MIN_CAPACITY_COL = Symbol("Pmin [MW]")
GENERATOR_TYPE_COL = Symbol("Type")
GENERATOR_COSTS_COL = Symbol("Costs [€/MW]")

function parse_generators!(filepath::String, busses::Dict{Symbol,Bus})::Dict{Symbol,Generator}
    df = read_sheet(filepath, GENERATOR_SHEET_NAME)
    generators = Dict()
    for row in eachrow(df)
        generator = parse_generator(row)
        generators[generator.id] = generator

        push!(busses[generator.bus].generators, generator.id)
    end
    return generators
end

function parse_generator(row::DataFrameRow)::Generator
    generator_id = Symbol(:G, row[GENERATOR_ID_COL])
    bus_id = Symbol(:B, row[GENERATOR_BUS_ID_COL])
    generator = Generator(
        generator_id,
        Symbol(row[GENERATOR_TYPE_COL]),
        bus_id,
        row[GENERATOR_MAX_CAPACITY_COL],
        row[GENERATOR_MIN_CAPACITY_COL],
        row[GENERATOR_COSTS_COL],
    )
    return generator
end

LOAD_HOUR_COL = Symbol("Hour/Bus No.")
function parse_loads(filepath::String)::DataFrame
    df = read_sheet(filepath, LOAD_SHEET_NAME)
    df[!, :] = convert.(Float64, df[!, :])
    df[!, :DateTime] = [parse_date(row[LOAD_HOUR_COL]) for row in eachrow(df)]
    # add month column
    df[!, :Month] = [Dates.month(row[:DateTime]) for row in eachrow(df)]

    select!(df, Not(LOAD_HOUR_COL))

    colnames = names(df)
    new_colnames = [
        [Symbol("B", i) for i in colnames[1:end-2]]...,
        :DateTe,
        :Month,
    ]
    rename!(df, new_colnames)

    return df
end

function parse_date(hour::Float64)::DateTime
    datetime = DateTime(2023, 1, 1, 1)
    return datetime + Hour(hour)
end