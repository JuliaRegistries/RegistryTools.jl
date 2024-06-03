const stdlibs = isdefined(Pkg.Types, :stdlib) ? Pkg.Types.stdlib : Pkg.Types.stdlibs
# Julia 1.8 changed from `name` to `(name, version)`.
get_stdlib_name(s::AbstractString) = s
get_stdlib_name(s::Tuple) = first(s)
if isdefined(Pkg.Types, :StdlibInfo)
get_stdlib_name(info::Pkg.Types.StdlibInfo) = info.name
end
const BUILTIN_PKGS = Dict(get_stdlib_name(v)=>string(k) for (k, v) in stdlibs())
