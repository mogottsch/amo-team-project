include("types.jl")

TITLE_ROW_INDEX = 1
BUS_SECTION_START = "BUS DATA FOLLOWS"
BRANCH_SECTION_START = "BRANCH DATA FOLLOWS"
LOSS_ZONE_SECTION_START = "LOSS ZONES FOLLOWS"
INTERCHANGE_SECTION_START = "INTERCHANGE DATA FOLLOWS"
TIE_LINE_SECTION_START = "TIE LINES FOLLOWS"

END_SECTION_PREFIX = "-9"

# function read_IEEE_common_data_format(filepath::String)::Network
function read_IEEE_common_data_format(filepath::String)
    filelines = readlines(filepath)

    generators = Dict()
    busses = Dict()
    lines = Dict()

    (
        bus_section,
        branch_section,
        # loss_zone_section,
        # interchange_section,
        # tie_line_section
    ) = get_sections(filelines)

    busses, generators = parse_bus_section(bus_section)
    lines = parse_branch_section(branch_section, busses)

    return Network(generators, busses, lines)
end

function get_sections(
    filelines::Vector{String}
)::Tuple{Vector{String},Vector{String}}
    bus_section = get_section(filelines, BUS_SECTION_START)
    branch_section = get_section(filelines, BRANCH_SECTION_START)
    # loss_zone_section = get_section(filelines, LOSS_ZONE_SECTION_START)
    # interchange_section = get_section(filelines, INTERCHANGE_SECTION_START)
    # tie_line_section = get_section(filelines, TIE_LINE_SECTION_START)

    return (
        bus_section,
        branch_section,
        # loss_zone_section,
        # interchange_section,
        # tie_line_section
    )
end


HEADER_OFFSET = FOOTER_OFFSET = 1
function get_section(
    filelines::Vector{String},
    section_start::String
)::Vector{String}
    contains_section_start = x -> occursin(section_start, x)
    contains_section_end = x -> occursin(END_SECTION_PREFIX, x)

    section_start_index = findfirst(contains_section_start, filelines)
    if section_start_index === nothing
        error("Start of section $section_start not found")
    end

    section_end_index = findnext(contains_section_end, filelines, section_start_index)
    if section_end_index === nothing
        error("End of section $section_start not found")
    end

    return filelines[section_start_index+HEADER_OFFSET:section_end_index-FOOTER_OFFSET]
end


DEFAULT_REINFORCMENT_COST = 100.0
BUS_NUMBER_COLUMNS = 1:4
BUS_VOLTAGE_COLUMNS = 28:33
BUS_LOAD_COLUMNS = 41:49
BUS_GENERATION_COLUMNS = 60:67
function parse_bus_section(bus_section::Vector{String})::Tuple{Dict{Symbol,Bus},Dict{Symbol,Generator}}
    generators = Dict()
    busses = Dict()

    for fileline in bus_section
        bus, generator = parse_bus_section_fileline(fileline)
        if generator !== nothing
            generators[generator.id] = generator
        end
        busses[bus.id] = bus
    end

    return busses, generators
end

function parse_bus_section_fileline(fileline::String)
    bus_number = parse(Int, fileline[BUS_NUMBER_COLUMNS])
    bus_id = Symbol(:B, bus_number)
    bus_load = parse(Float64, fileline[BUS_LOAD_COLUMNS])
    bus_generation = parse(Float64, fileline[BUS_GENERATION_COLUMNS])
    bus_voltage = parse(Float64, fileline[BUS_VOLTAGE_COLUMNS])

    generator = nothing
    bus = Bus(
        bus_id,
        Symbol[],
        bus_load,
        Symbol[],
        Symbol[],
        DEFAULT_REINFORCMENT_COST,
        bus_voltage
    )

    if bus_generation > 0.0
        generator = append_generator!(bus_number, bus, bus_generation)
    end
    return bus, generator
end

function append_generator!(
    bus_number::Int,
    bus::Bus,
    bus_generation::Float64
)::Generator
    generator_id = Symbol(:G, bus_number)
    generator = Generator(
        generator_id,
        bus_generation,
        Symbol(bus.id)
    )
    push!(bus.generators, generator_id)

    return generator
end

function parse_branch_section(
    branch_section::Vector{String},
    busses::Dict{Symbol,Bus}
)::Dict{Symbol,Line}
    lines = Dict()

    for fileline in branch_section
        line = parse_branch_section_fileline(fileline, busses)
        lines[line.id] = line
    end

    return lines
end

DEFAULT_LINE_CAPACITY = 100.0

BRANCH_FROM_BUS_COLUMNS = 1:4
BRANCH_TO_BUS_COLUMNS = 6:9
BRANCH_RESISTANCE_COLUMNS = 20:29
BRANCH_REACTANCE_COLUMNS = 30:40

function parse_branch_section_fileline(
    fileline::String,
    busses::Dict{Symbol,Bus}
)
    from_bus_number = parse(Int, fileline[BRANCH_FROM_BUS_COLUMNS])
    to_bus_number = parse(Int, fileline[BRANCH_TO_BUS_COLUMNS])
    from_bus_id = Symbol(:B, from_bus_number)
    to_bus_id = Symbol(:B, to_bus_number)

    resistance = parse(Float64, fileline[BRANCH_RESISTANCE_COLUMNS])
    reactance = parse(Float64, fileline[BRANCH_REACTANCE_COLUMNS])
    susceptance = calculate_susceptance(reactance, resistance)

    line_id = Symbol(:LF, from_bus_number, :T, to_bus_number)
    line = Line(
        line_id,
        from_bus_id,
        to_bus_id,
        calculate_power_capacity_for_line(resistance, busses[from_bus_id], busses[to_bus_id]),
        susceptance,
    )

    push!(busses[from_bus_id].outgoing, line_id)
    push!(busses[to_bus_id].incoming, line_id)

    return line
end

function calculate_susceptance(reactance::Float64, resistance::Float64)::Float64
    impedance = resistance + reactance * im
    admittance = 1 / impedance
    susceptance = imag(admittance)
    return susceptance
end

function calculate_power_capacity_for_line(
    line_resistance::Float64,
    from_bus::Bus,
    to_bus::Bus
)::Float64
    from_bus_voltage = from_bus.voltage
    to_bus_voltage = to_bus.voltage

    if line_resistance == 0.0
        return 0.0
    end

    power_capacity_from_bus = from_bus_voltage^2 / line_resistance
    power_capacity_to_bus = to_bus_voltage^2 / line_resistance

    return min(power_capacity_from_bus, power_capacity_to_bus)
end
end