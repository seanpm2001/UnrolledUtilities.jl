"""
    UnrolledUtilities

A collection of generated functions in which all loops are unrolled and inlined.

The functions exported by this module are
- `unrolled_any(f, itr)`: similar to `any`
- `unrolled_all(f, itr)`: similar to `all`
- `unrolled_foreach(f, itrs...)`: similar to `foreach`
- `unrolled_map(f, itrs...)`: similar to `map`
- `unrolled_reduce(op, itr; [init])`: similar to `reduce`
- `unrolled_mapreduce(f, op, itrs...; [init])`: similar to `mapreduce`
- `unrolled_zip(itrs...)`: similar to `zip`
- `unrolled_in(item, itr)`: similar to `in`
- `unrolled_unique(itr)`: similar to `unique`
- `unrolled_filter(f, itr)`: similar to `filter`
- `unrolled_split(f, itr)`: similar to `(filter(f, itr), filter(!f, itr))`, but
  without duplicate calls to `f`
- `unrolled_flatten(itr)`: similar to `Iterators.flatten`
- `unrolled_flatmap(f, itrs...)`: similar to `Iterators.flatmap`
- `unrolled_product(itrs...)`: similar to `Iterators.product`
- `unrolled_take(itr, ::Val{N})`: similar to `Iterators.take`, but with the
  second argument wrapped in a `Val`
- `unrolled_drop(itr, ::Val{N})`: similar to `Iterators.drop`, but with the
  second argument wrapped in a `Val`

These functions are guaranteed to be type-stable whenever they are given
iterators with inferrable lengths and element types, including when
- the iterators have nonuniform element types (with the exception of `map`, all
  of the corresponding functions from `Base` encounter type-instabilities and
  allocations when this is the case)
- the iterators have many elements (e.g., more than 32, which is the threshold
  at which `map` becomes type-unstable for `Tuple`s)
- `f` and/or `op` recursively call the function to which they is passed, with an
  arbitrarily large recursion depth (e.g., if `f` calls `map(f, itrs)`, it will
  be type-unstable when the recursion depth exceeds 3, but this will not be the
  case with `unrolled_map`)

Moreover, these functions are very likely to be optimized out through constant
propagation when the iterators have singleton element types (and when the result
of calling `f` and/or `op` on these elements is inferrable).
"""
module UnrolledUtilities

export unrolled_any,
    unrolled_all,
    unrolled_foreach,
    unrolled_map,
    unrolled_reduce,
    unrolled_mapreduce,
    unrolled_zip,
    unrolled_in,
    unrolled_unique,
    unrolled_filter,
    unrolled_split,
    unrolled_flatten,
    unrolled_flatmap,
    unrolled_product,
    unrolled_take,
    unrolled_drop

inferred_length(itr_type::Type{<:Tuple}) = length(itr_type.types)
# We could also add support for statically-sized iterators that are not Tuples.

f_exprs(itr_type) = (:(f(itr[$n])) for n in 1:inferred_length(itr_type))
@inline @generated unrolled_any(f, itr) = Expr(:||, f_exprs(itr)...)
@inline @generated unrolled_all(f, itr) = Expr(:&&, f_exprs(itr)...)

function zipped_f_exprs(itr_types)
    L = length(itr_types)
    L == 0 && error("unrolled functions need at least one iterator as input")
    N = minimum(inferred_length, itr_types)
    return (:(f($((:(itrs[$l][$n]) for l in 1:L)...))) for n in 1:N)
end
@inline @generated unrolled_foreach(f, itrs...) =
    Expr(:block, zipped_f_exprs(itrs)...)
@inline @generated unrolled_map(f, itrs...) =
    Expr(:tuple, zipped_f_exprs(itrs)...)

function nested_op_expr(itr_type)
    N = inferred_length(itr_type)
    N == 0 && error("unrolled_reduce needs an `init` value for empty iterators")
    item_exprs = (:(itr[$n]) for n in 1:N)
    return reduce((expr1, expr2) -> :(op($expr1, $expr2)), item_exprs)
end
@inline @generated unrolled_reduce_without_init(op, itr) = nested_op_expr(itr)

struct NoInit end
@inline unrolled_reduce(op, itr; init = NoInit()) =
    unrolled_reduce_without_init(op, init isa NoInit ? itr : (init, itr...))

@inline unrolled_mapreduce(f, op, itrs...; init_kwarg...) =
    unrolled_reduce(op, unrolled_map(f, itrs...); init_kwarg...)

@inline unrolled_zip(itrs...) = unrolled_map(tuple, itrs...)

@inline unrolled_in(item, itr) = unrolled_any(Base.Fix1(===, item), itr)
# Using === instead of == or isequal improves type stability for singletons.

@inline unrolled_unique(itr) =
    unrolled_reduce(itr; init = ()) do unique_items, item
        @inline
        unrolled_in(item, unique_items) ? unique_items : (unique_items..., item)
    end

@inline unrolled_filter(f, itr) =
    unrolled_reduce(itr; init = ()) do filtered_items, item
        @inline
        f(item) ? (filtered_items..., item) : filtered_items
    end

@inline unrolled_split(f, itr) =
    unrolled_reduce(itr; init = ((), ())) do (f_items, not_f_items), item
        @inline
        f(item) ? ((f_items..., item), not_f_items) :
        (f_items, (not_f_items..., item))
    end

@inline unrolled_flatten(itr) =
    unrolled_reduce((item1, item2) -> (item1..., item2...), itr; init = ())

@inline unrolled_flatmap(f, itrs...) =
    unrolled_flatten(unrolled_map(f, itrs...))

@inline unrolled_product(itrs...) =
    unrolled_reduce(itrs; init = ((),)) do product_itr, itr
        @inline
        unrolled_flatmap(itr) do item
            @inline
            unrolled_map(product_tuple -> (product_tuple..., item), product_itr)
        end
    end

@inline unrolled_take(itr, ::Val{N}) where {N} = ntuple(i -> itr[i], Val(N))
@inline unrolled_drop(itr, ::Val{N}) where {N} =
    ntuple(i -> itr[N + i], Val(length(itr) - N))
# When its second argument is a Val, ntuple is unrolled via Base.@ntuple.

@static if hasfield(Method, :recursion_relation)
    # Remove recursion limits for functions whose arguments are also functions.
    for func in (
        unrolled_any,
        unrolled_all,
        unrolled_foreach,
        unrolled_map,
        unrolled_reduce_without_init,
        unrolled_reduce,
        unrolled_mapreduce,
        unrolled_filter,
        unrolled_split,
        unrolled_flatmap,
    )
        for method in methods(func)
            method.recursion_relation = (_...) -> true
        end
    end
end

end
