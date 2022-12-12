module RegistryTools

export RegBranch
export register
export check_and_update_registry_files
export find_registered_version

using AutoHashEquals
using LibGit2
using Pkg: Pkg, TOML, GitTools
using UUIDs

const DEFAULT_REGISTRY_URL = "https://github.com/JuliaRegistries/General"
const PKG_HAS_WEAK = hasfield(Pkg.Types.Project, :_deps_weak)

function __init__()
    if !PKG_HAS_WEAK
        @warn "Running Registrator on a Julia version that does not support weak dependencies. " *
              "Weak dependencies will not be registered."
    end
end

include("Compress.jl")
include("builtin_pkgs.jl")
include("types.jl")
include("register.jl")
include("utils.jl")

end
