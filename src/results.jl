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