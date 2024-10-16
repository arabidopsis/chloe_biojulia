
module CmdLine
export chloe_main

import ArgParse: ArgParseSettings, @add_arg_table!, parse_args
import Logging

import ..Annotator

include("globals.jl")

const LOGLEVELS = Dict("info" => Logging.Info, "debug" => Logging.Debug, "warn" => Logging.Warn, "error" => Logging.Error)

function quiet_metafmt(level, _module, group, id, file, line)
    color = Logging.default_logcolor(level)
    prefix = (level == Logging.Warn ? "Warning" : string(level)) * ':'
    return color, prefix, ""
end

function chloe(;
    reference_dir="cp",
    fasta_files=String[],
    sensitivity=DEFAULT_SENSITIVITY,
    output::String=pwd(),
    stet::Bool=false,
    gff::Bool=false,
    nofilter::Bool=false
)
    db = Annotator.ReferenceDb(reference_dir)
    config = Annotator.ChloeConfig(; stet=stet, sensitivity=sensitivity, to_gff3=gff, nofilter=nofilter, reference=reference_dir)
    Annotator.annotate_batch(db, fasta_files, config, output)
end

function getargs(args::Vector{String}=ARGS)
    cmd_args = ArgParseSettings(; prog="Chloë", autofix_names=true)  # turn "-" into "_" for arg names.
    #! format: off
    @add_arg_table! cmd_args begin
        "minhash"
        help = "minhash fasta files of reference genomes"
        action = :command
        "align"
        help = "align 2 chloroplast genomes"
        action = :command
        "annotate"
        help = "annotate fasta files"
        action = :command
        "--level", "-l"
        arg_type = String
        default = "info"
        help = "log level (info,warn,error,debug)"
    end

    @add_arg_table! cmd_args["minhash"] begin
        "fasta-files"
        arg_type = String
        nargs = '+'
        required = true
        action = :store_arg
        help = "fasta files to process (or directory of files)"
    end

    @add_arg_table! cmd_args["align"] begin
        "query"
        arg_type = String
        required = true
        action = :store_arg
        help = "query sequence (fasta format)"
        "target"
        arg_type = String
        nargs = '+'
        required = true
        action = :store_arg
        help = "target sequence(s): fasta file(s) to process (or directory of files)"
        "--output", "-o"
        arg_type = String
        help = "output file (default: write to stdout)"
    end

    @add_arg_table! cmd_args["annotate"] begin
        "fasta-files"
        arg_type = String
        nargs = '+'
        required = true
        action = :store_arg
        help = "fasta files to process"
        "--output", "-o"
        arg_type = String
        default = pwd()
        help = "output directory (default: present working directory)"
        "--reference", "-r"
        arg_type = String
        default = "cp"
        dest_name = "reference_dir"
        metavar = "cp|nr"
        help = "references and templates to use for annotations: cp for chloroplast, nr for nuclear rDNA"
        "--sensitivity", "-s"
        arg_type = Real
        default = DEFAULT_SENSITIVITY
        help = "probability threshold for reporting features"
        "--nofilter"
        action = :store_true
        help = "don't filter output"
        "--stet"
        action = :store_true
        help = "do not flip and orient sequence to standard configuration"
        "--gff"
        action = :store_true
        help = "save output in gff3 format instead of sff"
    end

    parse_args(args, cmd_args; as_symbols=true)
end

function chloe_main(args::Vector{String}=ARGS)
    parsed_args = getargs(args)
    level = lowercase(parsed_args[:level])
    Logging.with_logger(Logging.ConsoleLogger(stderr, get(LOGLEVELS, level, Logging.Warn); meta_formatter=quiet_metafmt)) do
        cmd = parsed_args[:_COMMAND_]
        a = parsed_args[cmd]
        if cmd == :minhash
            Annotator.minhash_references(; a...)
        elseif cmd == :align
            Annotator.align(; a...)
        elseif cmd == :annotate
            chloe(; a...)
        end
    end
end

end # module
