const TEST_TYPE = Float32

function assert_operators_defined_over_reals(T, options::Options)
    test_input = map(x -> convert(T, x), LinRange(-100, 100, 99))
    cur_op = nothing
    try
        for left in test_input
            for right in test_input
                for binop in options.operators.binops
                    cur_op = binop
                    test_output = binop.(left, right)
                end
            end
            for unaop in options.operators.unaops
                cur_op = unaop
                test_output = unaop.(left)
            end
        end
    catch error
        throw(
            AssertionError(
                "Your configuration is invalid - one of your operators ($cur_op) is not well-defined over the real line. You can get around this by returning `NaN` for invalid inputs.",
            ),
        )
    end
end

# Check for errors before they happen
function test_option_configuration(T, options::Options)
    for op in (options.operators.binops..., options.operators.unaops...)
        if is_anonymous_function(op)
            throw(
                AssertionError(
                    "Anonymous functions can't be used as operators for SymbolicRegression.jl",
                ),
            )
        end
    end

    assert_operators_defined_over_reals(T, options)

    operator_intersection = intersect(options.operators.binops, options.operators.unaops)
    if length(operator_intersection) > 0
        throw(
            AssertionError(
                "Your configuration is invalid - $(operator_intersection) appear in both the binary operators and unary operators.",
            ),
        )
    end
end

# Check for errors before they happen
function test_dataset_configuration(dataset::Dataset{T}, options::Options) where {T<:Real}
    n = dataset.n
    if n != size(dataset.X, 2) || n != size(dataset.y, 1)
        throw(
            AssertionError(
                "Dataset dimensions are invalid. Make sure X is of shape [features, rows], y is of shape [rows] and if there are weights, they are of shape [rows].",
            ),
        )
    end

    if size(dataset.X, 2) > 10000
        if !options.batching
            debug(
                (options.verbosity > 0 || options.progress),
                "Note: you are running with more than 10,000 datapoints. You should consider turning on batching (`options.batching`), and also if you need that many datapoints. Unless you have a large amount of noise (in which case you should smooth your dataset first), generally < 10,000 datapoints is enough to find a functional form.",
            )
        end
    end

    if !(typeof(options.elementwise_loss) <: SupervisedLoss)
        if dataset.weighted
            if !(3 in [m.nargs - 1 for m in methods(options.elementwise_loss)])
                throw(
                    AssertionError(
                        "When you create a custom loss function, and are using weights, you need to define your loss function with three scalar arguments: f(prediction, target, weight).",
                    ),
                )
            end
        end
    end
end

""" Move custom operators and loss functions to workers, if undefined """
function move_functions_to_workers(procs, options::Options, dataset::Dataset{T}) where {T}
    enable_autodiff =
        :diff_binops in fieldnames(typeof(options.operators)) &&
        :diff_unaops in fieldnames(typeof(options.operators)) &&
        (
            options.operators.diff_binops !== nothing ||
            options.operators.diff_unaops !== nothing
        )

    # All the types of functions we need to move to workers:
    function_sets = (
        :unaops,
        :binops,
        :diff_unaops,
        :diff_binops,
        :elementwise_loss,
        :early_stop_condition,
        :loss_function,
    )

    for function_set in function_sets
        if function_set == :unaops
            ops = options.operators.unaops
            example_inputs = (zero(T),)
        elseif function_set == :binops
            ops = options.operators.binops
            example_inputs = (zero(T), zero(T))
        elseif function_set == :diff_unaops
            if !enable_autodiff
                continue
            end
            ops = options.operators.diff_unaops
            example_inputs = (zero(T),)
        elseif function_set == :diff_binops
            if !enable_autodiff
                continue
            end
            ops = options.operators.diff_binops
            example_inputs = (zero(T), zero(T))
        elseif function_set == :elementwise_loss
            if typeof(options.elementwise_loss) <: SupervisedLoss
                continue
            end
            ops = (options.elementwise_loss,)
            example_inputs = if dataset.weighted
                (zero(T), zero(T), zero(T))
            else
                (zero(T), zero(T))
            end
        elseif function_set == :early_stop_condition
            if !(typeof(options.early_stop_condition) <: Function)
                continue
            end
            ops = (options.early_stop_condition,)
            example_inputs = (zero(T), 0)
        elseif function_set == :loss_function
            if options.loss_function === nothing
                continue
            end
            ops = (options.loss_function,)
            example_inputs = (Node(T; val=zero(T)), dataset, options)
        else
            error("Invalid function set: $function_set")
        end
        for op in ops
            try
                test_function_on_workers(example_inputs, op, procs)
            catch e
                undefined_on_workers = isa(e.captured.ex, UndefVarError)
                if undefined_on_workers
                    copy_definition_to_workers(op, procs, options)
                else
                    throw(e)
                end
            end
            test_function_on_workers(example_inputs, op, procs)
        end
    end
end

function copy_definition_to_workers(op, procs, options::Options)
    name = nameof(op)
    debug_inline(
        (options.verbosity > 0 || options.progress),
        "Copying definition of $op to workers...",
    )
    src_ms = methods(op).ms
    # Thanks https://discourse.julialang.org/t/easy-way-to-send-custom-function-to-distributed-workers/22118/2
    @everywhere procs @eval function $name end
    for m in src_ms
        @everywhere procs @eval $m
    end
    return debug((options.verbosity > 0 || options.progress), "Finished!")
end

function test_function_on_workers(example_inputs, op, procs)
    futures = []
    for proc in procs
        push!(futures, @spawnat proc op(example_inputs...))
    end
    for future in futures
        fetch(future)
    end
end

function activate_env_on_workers(procs, project_path::String, options::Options)
    debug((options.verbosity > 0 || options.progress), "Activating environment on workers.")
    @everywhere procs begin
        Base.MainInclude.eval(
            quote
                using Pkg
                Pkg.activate($$project_path)
            end,
        )
    end
end

function import_module_on_workers(procs, filename::String, options::Options)
    included_local = !("SymbolicRegression" in [k.name for (k, v) in Base.loaded_modules])
    if included_local
        debug_inline(
            (options.verbosity > 0 || options.progress),
            "Importing local module ($filename) on workers...",
        )
        @everywhere procs begin
            # Parse functions on every worker node
            Base.MainInclude.eval(
                quote
                    include($$filename)
                    using .SymbolicRegression
                end,
            )
        end
        debug((options.verbosity > 0 || options.progress), "Finished!")
    else
        debug_inline(
            (options.verbosity > 0 || options.progress),
            "Importing installed module on workers...",
        )
        @everywhere procs begin
            Base.MainInclude.eval(using SymbolicRegression)
        end
        debug((options.verbosity > 0 || options.progress), "Finished!")
    end
end

function test_module_on_workers(procs, options::Options)
    debug_inline(
        (options.verbosity > 0 || options.progress), "Testing module on workers..."
    )
    futures = []
    for proc in procs
        push!(
            futures,
            @spawnat proc SymbolicRegression.gen_random_tree(3, options, 5, TEST_TYPE)
        )
    end
    for future in futures
        fetch(future)
    end
    return debug((options.verbosity > 0 || options.progress), "Finished!")
end

function test_entire_pipeline(procs, dataset::Dataset{T}, options::Options) where {T<:Real}
    futures = []
    debug_inline(
        (options.verbosity > 0 || options.progress), "Testing entire pipeline on workers..."
    )
    for proc in procs
        push!(
            futures,
            @spawnat proc begin
                tmp_pop = Population(
                    dataset;
                    npop=20,
                    nlength=3,
                    options=options,
                    nfeatures=dataset.nfeatures,
                )
                tmp_pop = s_r_cycle(
                    dataset,
                    tmp_pop,
                    5,
                    5,
                    RunningSearchStatistics(; options=options);
                    verbosity=options.verbosity,
                    options=options,
                    record=RecordType(),
                )[1]
                tmp_pop = optimize_and_simplify_population(
                    dataset, tmp_pop, options, options.maxsize, RecordType()
                )
            end
        )
    end
    for future in futures
        fetch(future)
    end
    return debug((options.verbosity > 0 || options.progress), "Finished!")
end
