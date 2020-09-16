module Chloe

export annotate_one, annotate, readReferences, Reference, MayBeString, MayBeIO, human
export create_mmaps, writesuffixarray
export writeallGFF3
export cmd_main
export distributed_main, chloe_distributed, run_broker
export set_global_logger, readDefaultReferences

include("ZMQLogger.jl")
include("annotate_genomes.jl")
# include("broker.jl")
include("sff2GFF3.jl")
include("WebAPI.jl")
include("SuffixArray.jl")
include("chloe_cmd.jl")

include("chloe_distributed.jl")

import .SuffixArray: create_mmaps, writesuffixarray
import .Sff2Gff: writeallGFF3
# import .ChloeDistributed: distributed_main, chloe_distributed, run_broker
import .Annotator: annotate, annotate_one, readReferences, Reference, MayBeIO, MayBeString, human
import .CmdLine: cmd_main
import .ZMQLogging: set_global_logger

end
