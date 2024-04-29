module MPIExt

############ Module dependencies ############
if isdefined(Base, :get_extension)
    using Experimenter
    using MPI
else
    using ..Experimenter
    using ..MPI
end

include("utils.jl")


############     Module Code     ############
function Experimenter.Cluster.init_mpi()
    # Setup SLURM
    MPI.Init(; threadlevel=:multiple)
    comm = MPI.COMM_WORLD
    rank = MPI.Comm_rank(comm)
    comm_size = MPI.Comm_size(comm)
    if comm_size < 2
        error("Not enough MPI processes were launched to run experiments in MPI mode. MPI mode requires at least two processes.")
        exit(1)
    end

    if rank == 0
        @info "Initialised MPI with $(comm_size-1) workers and 1 coordinator."
    end
end

function Experimenter._mpi_run_job(runner::Experimenter.Runner, trials::AbstractArray{Experimenter.Trial})
    @assert runner.execution_mode isa MPIMode
    comm = MPI.COMM_WORLD
    rank = MPI.Comm_rank(comm)
    if rank == 0
        coordinator_loop(runner.experiment, runner.database, trials)
    else
        @warn "[WORKER $(rank)] Reached a function that it should not be able to reach."
    end
end

function Experimenter._mpi_worker_loop(runner::Experimenter.Runner)
    batch_size = runner.execution_mode.batch_size
    trial_fn = Base.eval(Main, Meta.parse(runner.experiment.function_name))

    comm = MPI.COMM_WORLD
    rank = MPI.Comm_rank(comm)
    if rank == 0
        error("The first process is reserved for the coordinator and cannot be a worker.")
    end

    # Initialise the state of the worker
    worker = WorkerNode(
        comm,
        rank,
        false,
        0,
        trial_fn
    )

    job_request = JobRequest(worker.mpi_rank, batch_size)
    
    if !ismissing(runner.experiment.init_store_function_name)
        @debug "[WORKER $(rank)] Initialising the global store"
        init_fn_name = runner.experiment.init_store_function_name
        experiment_config = runner.experiment.configuration
        
        construct_store(init_fn_name, experiment_config)
    end


    @debug "[WORKER $(rank)] Loaded."

    while !worker.has_stopped
        @debug "[WORKER $(rank)] Loaded."
        send_variable_message(worker.comm, job_request, 0; should_block = true)
        response, source = recieve_variable_message(worker.comm)
        handle_response!(worker, response)
    end

    MPI.Finalize()
end

function coordinator_loop(experiment::Experiment, db::ExperimentDatabase, trials::AbstractArray{Experimenter.Trial})
    comm = MPI.COMM_WORLD
    rank = MPI.Comm_rank(comm)
    if rank != 0
        error("The coordinator job should be run on the first process.")
    end
    comm_size = MPI.Comm_size(comm)
    coordinator = Coordinator(
        comm,
        length(trials),
        1,
        0,
        0,
        comm_size-1,
        experiment,
        trials,
        db
    )

    @info "[COORDINATOR] $(comm_size - 1) workers ready. Starting experiment with $(length(trials)) trials."

    while coordinator.num_workers_closed != coordinator.num_workers
        # Listen for messages
        request, _ = recieve_variable_message(coordinator.comm)
        handle_request!(coordinator, request)
    end

    @info "[COORDINATOR] Finished."

    MPI.Finalize()
end

end