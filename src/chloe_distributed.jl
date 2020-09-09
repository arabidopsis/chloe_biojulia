include("annotate_genomes.jl")
include("ZMQLogger.jl")

import JuliaWebAPI: APIResponder, APIInvoker, apicall, ZMQTransport, JSONMsgFormat, register, process
import ArgParse: ArgParseSettings, @add_arg_table!, parse_args
import Dates: now, toms
import Distributed: addprocs, rmprocs, @spawnat, @everywhere
import Crayons: @crayon_str
import StringEncodings: encode

const success = crayon"bold green"
const ADDRESS = "tcp://127.0.0.1:9467"

# change this if you change the API!
const VERSION = "1.0"

function git_version()
    try
        strip(read(`git rev-parse HEAD`, String))
    catch
        "unknown"
    end
end

# from 
function exit_on_sigint(on::Bool)
    # from https://github.com/JuliaLang/julia/pull/29383
    # and https://github.com/JuliaLang/julia/pull/29411
    ccall(:jl_exit_on_sigint, Cvoid, (Cint,), on)
end

function create_responder(apispecs::Array{Function}, addr::String, ctx::ZMQ.Context)
    api = APIResponder(ZMQTransport(addr, ZMQ.REP, false, ctx), JSONMsgFormat(), "chloe", false)
    for func in apispecs
        register(api, func)
    end
    api
end

function chloe_distributed(;refsdir="reference_1116", address=ADDRESS,
    template="optimised_templates.v2.tsv", level="warn", workers=3,
    backend::MayBeString=nothing, broker::MayBeString=nothing)

    procs = addprocs(workers; topology=:master_worker)
    # sic! src/....
    @everywhere procs include("src/annotate_genomes.jl")
    @everywhere procs include("src/ZMQLogger.jl")
    # can't use rolling logger for procs because of file contentsion
    for p in procs
        @spawnat p set_global_logger(backend, level; topic="annotator")
    end
    set_global_logger(backend, level; topic="annotator")
    
    machine = gethostname()
    reference = readReferences(refsdir, template)
    git = git_version()[1:7]
    nannotations = 0
    nthreads = Threads.nthreads()

    @info "processes: $workers"
    @info reference
    @info "chloe version $VERSION (git: $git) threads=$nthreads on machine $machine"
    @info "connecting to $address"

    function chloe(fasta::String, fname::MayBeString, task_id::MayBeString=nothing)
        start = now()
        filename, target_id = fetch(@spawnat :any annotate_one_task(reference, fasta, fname, task_id))
        elapsed = now() - start
        @info success("finished $target_id after $elapsed")
        nannotations += 1
        return Dict("elapsed" => toms(elapsed), "filename" => filename, "ncid" => string(target_id))
    end

    function decompress(fasta::String)
        # decode a latin1 encoded binary string
        read(encode(fasta, "latin1") |> IOBuffer |> GzipDecompressorStream, String)
    end

    function annotate(fasta::String, task_id::MayBeString=nothing)
        start = now()
        if startswith(fasta, "\u1f\u8b")
            # assume latin1 encoded binary gzip file
            n = length(fasta)
            fasta = decompress(fasta)
            @info "decompressed fasta length $(n) -> $(length(fasta))"
        end

        input = IOContext(IOBuffer(fasta))

        io, target_id = fetch(@spawnat :any annotate_one_task(reference, input, task_id))
        sff = String(take!(io))
        elapsed = now() - start
        @info success("finished $target_id after $elapsed")
        nannotations += 1

        return Dict("elapsed" => toms(elapsed), "sff" => sff, "ncid" => string(target_id))
    end

    function ping()
        return "OK version=$VERSION git=$git #anno=$nannotations threads=$nthreads workers=$workers on $machine"
    end

    # `bin/chloe.py terminate` uses this to find out how many calls of :terminate
    # need to be made to stop all responders. It's hard to cleanly
    # stop process(APIResponder) from the outside since it is block wait on 
    # the zmq sockets.
    function nconn()
        return workers
    end

    function bgexit(endpoint)
        i = APIInvoker(endpoint)
        for w in 1:workers
            apicall(i, ":terminate")
            if workers == 0
                break
            end
        end
    end
    function exit(endpoint::MayBeString=nothing)
        # use broker url if any
        if endpoint === nothing
            endpoint = broker
        end
        if endpoint === nothing
            error("No endpoint!")
        end
        @async bgexit(endpoint)
        return "Done"
    end


    # we need to create separate ZMQ sockets to ensure strict
    # request/response (not e.g. request-request response-response)
    # we expect to *connect* to a ZMQ DEALER/ROUTER (see bin/broker.py)
    # that forms the actual front end.
    ctx = ZMQ.Context()

    function cleanup()
        close(ctx)
        try
            rmprocs(procs, waitfor=20)
        catch
        end
    end
   
    atexit(cleanup)

    done = Channel{Int}()

    function bg(workno::Int)
        process(
            create_responder([
                    chloe,
                    annotate,
                    ping,
                    nconn,
                    exit,
                ], address, ctx)
            )
        # :termiate called so process loop is finished
        put!(done, workno)
    end

    for workno in 1:workers
        @async bg(workno)
    end

    while workers > 0
        take!(done) # block here until listeners exit
        workers -= 1
    end
    # this creates #procs connections to the broker (in *this* process) each
    # handling a req/resp cycle and spawning jobs to complete them
    # @sync for p in procs
    #     @async process(
    #         create_responder([
    #                 chloe,
    #                 annotate,
    #                 ping,
    #                 nconn,
    #             ], address, ctx)
    #         )
    # end
    @info success("done: annotator exiting.....")

end

function args()
    distributed_args = ArgParseSettings(prog="Chloë", autofix_names=true)  # turn "-" into "_" for arg names.

    @add_arg_table! distributed_args begin
        "--reference", "-r"
        arg_type = String
        default = "reference_1116"
        dest_name = "refsdir"
        metavar = "DIRECTORY"
        help = "reference directory"
        "--template", "-t"
        arg_type = String
        default = "optimised_templates.v2.tsv"
        metavar = "TSV"
        dest_name = "template"
        help = "template tsv"
        "--address", "-a"
        arg_type = String
        metavar = "URL"
        default = ADDRESS
        help = "ZMQ DEALER address to connect to"
        "--level", "-l"
        arg_type = String
        metavar = "LOGLEVEL"
        default = "info"
        help = "log level (warn,debug,info,error)"
        "--workers", "-w"
        arg_type = Int
        default = 3
        help = "number of distributed processes"
        "--broker"
            arg_type = String
            metavar = "URL"
            help = "run the broker in the background"
        "--backend"
            arg_type = String
            metavar = "URL"
            help = "log to zmq endpoint"
    end
    distributed_args.epilog = """
    Run Chloe as a ZMQ service with distributed annotation processes.
    Requires a ZMQ DEALER/ROUTER to connect to unless `--broker` specifies
    an endpoint in which case it runs its own broker.
    """
    parse_args(ARGS, distributed_args; as_symbols=true)

end

function run_broker(worker, client)
    #  see https://discourse.julialang.org/t/how-to-run-a-process-in-background-but-still-close-it-on-exit/27231
    src = dirname(@__FILE__)
    julia = joinpath(Sys.BINDIR, "julia")
    if !Sys.isexecutable(julia)
        error("Can't find julia executable to run broker, best guess: $julia")
    end
    cmd = `$julia -q --startup-file=no "$src/broker.jl" --worker=$worker --client=$client`
    # wait = false means stdout,stderr are connected to /dev/null
    task = run(cmd; wait=false)
    atexit(() -> kill(task))
    task
    # open(pipeline(cmd))
end

function run_broker2(worker, client)
    # ugh! `@spawnat :any annotate...` will block on this process... which
    # will never return.
    procs = addprocs(1; topology=:master_worker)
    @everywhere procs include("src/broker.jl")
    @async fetch(@spawnat procs[1] run_broker(worker, client))
end

function find_endpoint()
    endpoint = tmplt = "/tmp/chloe-worker"
    n = 0
    while isfile(endpoint)
        n += 1
        endpoint = "$(tmplt)$(n)"
    end
    "ipc://$(endpoint)"
end 
function main()
    # exit_on_sigint(false)
    Sys.set_process_title("chloe-distributed")
    distributed_args = args()
    client_url = get(distributed_args, :broker, nothing)


    if client_url !== nothing
        if distributed_args[:address] === client_url
            distributed_args[:address] = find_endpoint()
            @warn "broker and worker endpoints clash: redirecting worker to $(distributed_args[:address])"
        end
        @info "Starting broker. Connect to: $client_url"
        run_broker(distributed_args[:address], client_url)
    end
    chloe_distributed(;distributed_args...)

end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
