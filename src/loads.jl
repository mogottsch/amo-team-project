function filter_month(
    loads::DataFrame,
    month::Int,
)::DataFrame
    loads = loads[loads[:, :Month].==month, :]
    return loads
end

# removes all columns, which don't start with "B"
function remove_non_data_rows(
    loads::DataFrame,
)::DataFrame
    loads = loads[:, filter(x -> startswith(string(x), "B"), names(loads))]
    return loads
end