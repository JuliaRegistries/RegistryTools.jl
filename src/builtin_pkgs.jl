const stdlibs = isdefined(Pkg.Types, :stdlib) ? Pkg.Types.stdlib : Pkg.Types.stdlibs
const BUILTIN_PKGS = Dict(v=>string(k) for (k, v) in stdlibs())
